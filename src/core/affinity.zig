//! CPU Core Affinity Management
//!
//! Provides utilities for pinning threads to specific CPU cores,
//! inspired by Firedancer's tile-based architecture.
//!
//! Key concepts:
//! - Critical tiles (PoH, AF_XDP) get isolated cores
//! - Verification and banking tiles get pooled cores
//! - Background tasks float on remaining cores

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// Types of tiles that can be pinned
pub const TileType = enum {
    poh,           // PoH hashing - CRITICAL isolated
    af_xdp_rx,     // Packet receive - isolated
    af_xdp_tx,     // Packet transmit - isolated
    verify,        // Signature verification (pooled)
    bank,          // Transaction execution (pooled)
    quic,          // QUIC connections
    gossip,        // Gossip protocol
    tvu,           // Shred handling
    replay,        // Replay stage
    ledger,        // Ledger I/O
    metrics,       // Metrics collection
    background,    // Low priority tasks

    pub fn priority(self: TileType) Priority {
        return switch (self) {
            .poh, .af_xdp_rx, .af_xdp_tx => .critical,
            .verify, .bank, .quic => .high,
            .gossip, .tvu, .replay => .medium,
            .ledger, .metrics, .background => .low,
        };
    }

    pub fn name(self: TileType) []const u8 {
        return @tagName(self);
    }
};

pub const Priority = enum(u8) {
    critical = 99, // SCHED_FIFO priority
    high = 50,
    medium = 25,
    low = 10,
};

/// CPU information detected from the system
pub const CpuInfo = struct {
    total_cores: u32,
    online_cores: u32,
    numa_nodes: u32,
    has_hyperthreading: bool,
    vendor: CpuVendor,
    model_name: [128]u8,
    model_name_len: usize,

    /// Cores that are siblings (hyperthreads) of each core
    /// hyperthread_pairs[i] = j means core i and core j are siblings
    hyperthread_pairs: [128]?u8,

    /// Which NUMA node each core belongs to
    numa_node_of_core: [128]u8,

    pub fn format(self: CpuInfo, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("CPU: {s} ({d} cores", .{
            self.model_name[0..self.model_name_len],
            self.total_cores,
        });
        if (self.has_hyperthreading) {
            try writer.print(", HT enabled", .{});
        }
        if (self.numa_nodes > 1) {
            try writer.print(", {d} NUMA nodes", .{self.numa_nodes});
        }
        try writer.print(")", .{});
    }
};

pub const CpuVendor = enum {
    amd,
    intel,
    arm,
    unknown,
};

/// Recommended core assignment based on hardware
pub const CoreLayout = struct {
    allocator: Allocator,

    // Critical isolated cores (must not share with hyperthreads)
    poh_core: ?u8 = null,
    af_xdp_rx_core: ?u8 = null,
    af_xdp_tx_core: ?u8 = null,

    // Pooled cores (can share hyperthreads)
    verify_cores: []u8 = &.{},
    bank_cores: []u8 = &.{},

    // Shared cores
    quic_core: ?u8 = null,
    gossip_core: ?u8 = null,
    tvu_core: ?u8 = null,
    replay_core: ?u8 = null,
    ledger_core: ?u8 = null,

    // Floating (OS scheduled)
    floating_cores: []u8 = &.{},

    // Cores whose hyperthreads should be disabled
    hyperthreads_to_disable: []u8 = &.{},

    pub fn deinit(self: *CoreLayout) void {
        if (self.verify_cores.len > 0) self.allocator.free(self.verify_cores);
        if (self.bank_cores.len > 0) self.allocator.free(self.bank_cores);
        if (self.floating_cores.len > 0) self.allocator.free(self.floating_cores);
        if (self.hyperthreads_to_disable.len > 0) self.allocator.free(self.hyperthreads_to_disable);
    }

    pub fn totalPinnedCores(self: CoreLayout) u32 {
        var count: u32 = 0;
        if (self.poh_core != null) count += 1;
        if (self.af_xdp_rx_core != null) count += 1;
        if (self.af_xdp_tx_core != null) count += 1;
        count += @intCast(self.verify_cores.len);
        count += @intCast(self.bank_cores.len);
        if (self.quic_core != null) count += 1;
        if (self.gossip_core != null) count += 1;
        if (self.tvu_core != null) count += 1;
        if (self.replay_core != null) count += 1;
        if (self.ledger_core != null) count += 1;
        return count;
    }

    pub fn format(self: CoreLayout, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("CoreLayout ({d} pinned cores):\n", .{self.totalPinnedCores()});
        if (self.poh_core) |c| try writer.print("  PoH:       Core {d} (ISOLATED)\n", .{c});
        if (self.af_xdp_rx_core) |c| try writer.print("  AF_XDP RX: Core {d} (ISOLATED)\n", .{c});
        if (self.af_xdp_tx_core) |c| try writer.print("  AF_XDP TX: Core {d} (ISOLATED)\n", .{c});
        if (self.verify_cores.len > 0) {
            try writer.print("  Verify:    Cores ", .{});
            for (self.verify_cores, 0..) |c, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{d}", .{c});
            }
            try writer.print("\n", .{});
        }
        if (self.bank_cores.len > 0) {
            try writer.print("  Bank:      Cores ", .{});
            for (self.bank_cores, 0..) |c, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{d}", .{c});
            }
            try writer.print("\n", .{});
        }
        if (self.quic_core) |c| try writer.print("  QUIC:      Core {d}\n", .{c});
        if (self.gossip_core) |c| try writer.print("  Gossip:    Core {d}\n", .{c});
    }
};

/// Detect CPU information from the system
pub fn detectCpuInfo() !CpuInfo {
    var info = CpuInfo{
        .total_cores = 0,
        .online_cores = 0,
        .numa_nodes = 1,
        .has_hyperthreading = false,
        .vendor = .unknown,
        .model_name = undefined,
        .model_name_len = 0,
        .hyperthread_pairs = [_]?u8{null} ** 128,
        .numa_node_of_core = [_]u8{0} ** 128,
    };

    // Get total CPU count
    info.total_cores = @intCast(try std.Thread.getCpuCount());
    info.online_cores = info.total_cores;

    // Read /proc/cpuinfo for vendor and model
    const cpuinfo_file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch {
        // Fallback to just the count
        @memcpy(info.model_name[0..7], "Unknown");
        info.model_name_len = 7;
        return info;
    };
    defer cpuinfo_file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = cpuinfo_file.read(&buf) catch 0;
    const cpuinfo = buf[0..bytes_read];

    // Parse vendor
    if (std.mem.indexOf(u8, cpuinfo, "vendor_id")) |idx| {
        const line_end = std.mem.indexOfPos(u8, cpuinfo, idx, "\n") orelse bytes_read;
        const line = cpuinfo[idx..line_end];
        if (std.mem.indexOf(u8, line, "AMD") != null) {
            info.vendor = .amd;
        } else if (std.mem.indexOf(u8, line, "Intel") != null) {
            info.vendor = .intel;
        }
    }

    // Parse model name
    if (std.mem.indexOf(u8, cpuinfo, "model name")) |idx| {
        const colon_idx = std.mem.indexOfPos(u8, cpuinfo, idx, ":") orelse idx;
        const line_end = std.mem.indexOfPos(u8, cpuinfo, idx, "\n") orelse bytes_read;
        const name_start = @min(colon_idx + 2, line_end);
        const name = cpuinfo[name_start..line_end];
        const copy_len = @min(name.len, info.model_name.len);
        @memcpy(info.model_name[0..copy_len], name[0..copy_len]);
        info.model_name_len = copy_len;
    }

    // Check for hyperthreading by looking at siblings
    // A core with siblings != 1 has hyperthreading
    if (std.mem.indexOf(u8, cpuinfo, "siblings")) |idx| {
        const colon_idx = std.mem.indexOfPos(u8, cpuinfo, idx, ":") orelse idx;
        const line_end = std.mem.indexOfPos(u8, cpuinfo, idx, "\n") orelse bytes_read;
        const value_start = @min(colon_idx + 2, line_end);
        const value = std.mem.trim(u8, cpuinfo[value_start..line_end], &std.ascii.whitespace);
        const siblings = std.fmt.parseInt(u32, value, 10) catch 1;

        if (std.mem.indexOf(u8, cpuinfo, "cpu cores")) |cores_idx| {
            const cores_colon = std.mem.indexOfPos(u8, cpuinfo, cores_idx, ":") orelse cores_idx;
            const cores_end = std.mem.indexOfPos(u8, cpuinfo, cores_idx, "\n") orelse bytes_read;
            const cores_start = @min(cores_colon + 2, cores_end);
            const cores_value = std.mem.trim(u8, cpuinfo[cores_start..cores_end], &std.ascii.whitespace);
            const physical_cores = std.fmt.parseInt(u32, cores_value, 10) catch siblings;
            info.has_hyperthreading = siblings > physical_cores;
        }
    }

    // TODO: Read hyperthread pairs from /sys/devices/system/cpu/cpu*/topology/thread_siblings_list
    // TODO: Read NUMA topology from /sys/devices/system/node/

    return info;
}

/// Generate recommended core layout based on detected CPU
pub fn generateLayout(allocator: Allocator, cpu_info: CpuInfo) !CoreLayout {
    var layout = CoreLayout{ .allocator = allocator };
    const cores = cpu_info.online_cores;

    // Minimum viable: 4 cores
    if (cores < 4) {
        // Everything floats
        layout.floating_cores = try allocator.alloc(u8, cores);
        for (0..cores) |i| {
            layout.floating_cores[i] = @intCast(i);
        }
        return layout;
    }

    // Small system: 4-7 cores
    if (cores < 8) {
        layout.poh_core = 1;
        layout.af_xdp_rx_core = 2;
        layout.verify_cores = try allocator.alloc(u8, 1);
        layout.verify_cores[0] = 3;
        if (cores > 4) {
            layout.bank_cores = try allocator.alloc(u8, @min(cores - 4, 2));
            for (0..layout.bank_cores.len) |i| {
                layout.bank_cores[i] = @intCast(4 + i);
            }
        }
        return layout;
    }

    // Medium system: 8-15 cores
    if (cores < 16) {
        layout.poh_core = 1;
        layout.af_xdp_rx_core = 2;
        layout.af_xdp_tx_core = 3;
        layout.verify_cores = try allocator.alloc(u8, 2);
        layout.verify_cores[0] = 4;
        layout.verify_cores[1] = 5;
        layout.bank_cores = try allocator.alloc(u8, 2);
        layout.bank_cores[0] = 6;
        layout.bank_cores[1] = 7;
        if (cores > 8) {
            layout.quic_core = 8;
            layout.gossip_core = 9;
        }
        if (cores > 10) {
            layout.tvu_core = 10;
            layout.replay_core = 11;
        }
        return layout;
    }

    // Large system: 16+ cores (consumer high-end or server)
    layout.poh_core = 1;
    layout.af_xdp_rx_core = 2;
    layout.af_xdp_tx_core = 3;

    const verify_count: usize = @min((cores - 8) / 2, 6);
    layout.verify_cores = try allocator.alloc(u8, verify_count);
    for (0..verify_count) |i| {
        layout.verify_cores[i] = @intCast(4 + i);
    }

    const bank_start = 4 + verify_count;
    const bank_count: usize = @min((cores - bank_start - 4), 6);
    layout.bank_cores = try allocator.alloc(u8, bank_count);
    for (0..bank_count) |i| {
        layout.bank_cores[i] = @intCast(bank_start + i);
    }

    const shared_start = bank_start + bank_count;
    layout.quic_core = @intCast(shared_start);
    layout.gossip_core = @intCast(shared_start + 1);
    layout.tvu_core = @intCast(shared_start + 2);
    layout.replay_core = @intCast(shared_start + 3);
    layout.ledger_core = @intCast(@min(shared_start + 4, cores - 1));

    return layout;
}

/// Pin the current thread to a specific CPU core
pub fn pinToCore(core: u8) !void {
    var mask = std.mem.zeroes(linux.cpu_set_t);

    // Set the bit for the specified core
    const word_idx = core / 64;
    const bit_idx: u6 = @intCast(core % 64);
    mask.__bits[word_idx] |= @as(usize, 1) << bit_idx;

    const rc = linux.sched_setaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.AffinityFailed;
    }
}

/// Set real-time priority for the current thread
pub fn setRealtimePriority(priority: Priority) !void {
    const param = linux.sched_param{ .sched_priority = @intFromEnum(priority) };
    const rc = linux.sched_setscheduler(0, linux.SCHED.FIFO, &param);
    if (@as(isize, @bitCast(rc)) < 0) {
        // SCHED_FIFO requires CAP_SYS_NICE
        return error.PriorityFailed;
    }
}

/// Pin and set priority for a tile
pub fn setupTile(tile_type: TileType, core: u8) !void {
    try pinToCore(core);

    // Only set realtime priority for critical tiles
    if (tile_type.priority() == .critical) {
        setRealtimePriority(tile_type.priority()) catch {
            // Not fatal - continue without realtime priority
            std.log.warn("Could not set realtime priority for {s} tile (need CAP_SYS_NICE)", .{tile_type.name()});
        };
    }

    std.log.info("{s} tile pinned to core {d}", .{ tile_type.name(), core });
}

/// Disable a CPU core (for hyperthreads of critical cores)
pub fn disableCore(core: u8) !void {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "/sys/devices/system/cpu/cpu{d}/online", .{core});
    defer std.heap.page_allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
        std.log.warn("Could not disable core {d}: {}", .{ core, err });
        return error.DisableFailed;
    };
    defer file.close();

    _ = file.write("0") catch return error.DisableFailed;
    std.log.info("Disabled core {d} (hyperthread of critical tile)", .{core});
}

/// Check if system supports realtime scheduling
pub fn canUseRealtimePriority() bool {
    // Try to set and immediately restore
    const param = linux.sched_param{ .sched_priority = 1 };
    const rc = linux.sched_setscheduler(0, linux.SCHED.FIFO, &param);
    if (@as(isize, @bitCast(rc)) >= 0) {
        // Restore normal scheduling
        const normal = linux.sched_param{ .sched_priority = 0 };
        _ = linux.sched_setscheduler(0, linux.SCHED.OTHER, &normal);
        return true;
    }
    return false;
}

// Tests
test "detect cpu info" {
    const info = try detectCpuInfo();
    try std.testing.expect(info.total_cores > 0);
}

test "generate layout" {
    const allocator = std.testing.allocator;
    const info = try detectCpuInfo();
    var layout = try generateLayout(allocator, info);
    defer layout.deinit();

    // Should generate some layout
    try std.testing.expect(layout.totalPinnedCores() > 0 or layout.floating_cores.len > 0);
}

