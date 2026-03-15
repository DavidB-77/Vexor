//! Vexor Testing Framework
//! Comprehensive testing and debugging infrastructure for development and QA.
//!
//! Features:
//! - Feature flags for toggling subsystems
//! - Mock data generators
//! - Performance profiling hooks
//! - Fault injection for resilience testing
//! - Test mode indicators
//!
//! Usage:
//! ```
//! vexor --test-mode --enable-feature=bpf --disable-feature=af_xdp
//! vexor --test-mode --inject-fault=network_delay:100ms
//! vexor --test-mode --mock-data --slots=1000
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Test mode configuration
pub const TestConfig = struct {
    /// Enable test mode (shows [TEST] in logs)
    test_mode: bool = false,

    /// Enable verbose debug logging
    verbose: bool = false,

    /// Enable performance profiling
    profiling: bool = false,

    /// Generate mock data instead of real network
    mock_data: bool = false,

    /// Number of mock slots to generate
    mock_slots: u64 = 100,

    /// Inject artificial delays (nanoseconds)
    inject_delay_ns: u64 = 0,

    /// Simulate network packet loss (0-100%)
    packet_loss_percent: u8 = 0,

    /// Simulate memory pressure
    memory_pressure: bool = false,

    /// Force specific code paths for testing
    force_path: ?ForcePath = null,

    /// Record all operations for replay
    record_ops: bool = false,

    /// Replay recorded operations
    replay_file: ?[]const u8 = null,

    pub const ForcePath = enum {
        leader_mode,
        validator_mode,
        catch_up_mode,
        snapshot_load,
        genesis_start,
    };
};

/// Feature flags for toggling subsystems
pub const FeatureFlags = struct {
    // Core features
    bpf_vm: bool = true,
    native_programs: bool = true,
    signature_verification: bool = true,
    poh_verification: bool = true,

    // Network features
    af_xdp: bool = true,
    quic: bool = true,
    masque: bool = false, // Experimental
    gossip: bool = true,
    turbine: bool = true,
    repair: bool = true,

    // Storage features
    ramdisk: bool = true,
    nvme_direct: bool = true,
    snapshot_compression: bool = true,

    // RPC features
    http_rpc: bool = true,
    websocket_rpc: bool = true,
    bigtable_upload: bool = false,

    // Consensus features
    tower_bft: bool = true,
    alpenglow: bool = false, // Future
    vote_signing: bool = true,

    // Performance features
    gpu_acceleration: bool = false,
    simd_crypto: bool = true,
    parallel_replay: bool = true,

    // Auto-optimizer
    auto_optimize: bool = true,

    /// Parse feature flags from CLI
    pub fn parseFromArgs(args: []const []const u8) FeatureFlags {
        var flags = FeatureFlags{};

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--enable-feature=")) {
                const feature = arg["--enable-feature=".len..];
                flags.setFeature(feature, true);
            } else if (std.mem.startsWith(u8, arg, "--disable-feature=")) {
                const feature = arg["--disable-feature=".len..];
                flags.setFeature(feature, false);
            }
        }

        return flags;
    }

    fn setFeature(self: *FeatureFlags, name: []const u8, enabled: bool) void {
        if (std.mem.eql(u8, name, "bpf")) self.bpf_vm = enabled
        else if (std.mem.eql(u8, name, "af_xdp")) self.af_xdp = enabled
        else if (std.mem.eql(u8, name, "quic")) self.quic = enabled
        else if (std.mem.eql(u8, name, "masque")) self.masque = enabled
        else if (std.mem.eql(u8, name, "gossip")) self.gossip = enabled
        else if (std.mem.eql(u8, name, "ramdisk")) self.ramdisk = enabled
        else if (std.mem.eql(u8, name, "gpu")) self.gpu_acceleration = enabled
        else if (std.mem.eql(u8, name, "alpenglow")) self.alpenglow = enabled
        else if (std.mem.eql(u8, name, "websocket")) self.websocket_rpc = enabled
        else if (std.mem.eql(u8, name, "auto_optimize")) self.auto_optimize = enabled;
    }

    /// Get list of enabled features
    pub fn listEnabled(self: *const FeatureFlags, allocator: Allocator) ![]const []const u8 {
        var list = std.ArrayList([]const u8).init(allocator);

        if (self.bpf_vm) try list.append("bpf_vm");
        if (self.af_xdp) try list.append("af_xdp");
        if (self.quic) try list.append("quic");
        if (self.masque) try list.append("masque");
        if (self.gossip) try list.append("gossip");
        if (self.ramdisk) try list.append("ramdisk");
        if (self.gpu_acceleration) try list.append("gpu");
        if (self.alpenglow) try list.append("alpenglow");
        if (self.websocket_rpc) try list.append("websocket");

        return list.toOwnedSlice();
    }
};

/// Fault injection for resilience testing
pub const FaultInjector = struct {
    /// Active faults
    faults: std.StringHashMap(Fault),
    /// Random generator for probabilistic faults
    prng: std.Random.DefaultPrng,
    /// Allocator
    allocator: Allocator,

    pub const Fault = struct {
        fault_type: FaultType,
        probability: f32, // 0.0 - 1.0
        duration_ns: ?u64,
        triggered_count: u64,
        max_triggers: ?u64,
    };

    pub const FaultType = enum {
        network_delay,
        network_drop,
        disk_slow,
        disk_error,
        memory_alloc_fail,
        cpu_spike,
        signature_invalid,
        hash_mismatch,
    };

    pub fn init(allocator: Allocator) FaultInjector {
        return .{
            .faults = std.StringHashMap(Fault).init(allocator),
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FaultInjector) void {
        self.faults.deinit();
    }

    /// Add a fault
    pub fn addFault(self: *FaultInjector, name: []const u8, fault: Fault) !void {
        try self.faults.put(name, fault);
    }

    /// Check if fault should trigger
    pub fn shouldTrigger(self: *FaultInjector, name: []const u8) bool {
        if (self.faults.getPtr(name)) |fault| {
            if (fault.max_triggers) |max| {
                if (fault.triggered_count >= max) return false;
            }

            if (self.prng.random().float(f32) < fault.probability) {
                fault.triggered_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Parse fault from CLI string (e.g., "network_delay:100ms:0.5")
    pub fn parseFault(spec: []const u8) ?Fault {
        var iter = std.mem.splitScalar(u8, spec, ':');
        const type_str = iter.next() orelse return null;

        const fault_type: FaultType = if (std.mem.eql(u8, type_str, "network_delay"))
            .network_delay
        else if (std.mem.eql(u8, type_str, "network_drop"))
            .network_drop
        else if (std.mem.eql(u8, type_str, "disk_slow"))
            .disk_slow
        else if (std.mem.eql(u8, type_str, "memory_fail"))
            .memory_alloc_fail
        else
            return null;

        var fault = Fault{
            .fault_type = fault_type,
            .probability = 1.0,
            .duration_ns = null,
            .triggered_count = 0,
            .max_triggers = null,
        };

        // Parse duration if present
        if (iter.next()) |dur_str| {
            fault.duration_ns = parseDuration(dur_str);
        }

        // Parse probability if present
        if (iter.next()) |prob_str| {
            fault.probability = std.fmt.parseFloat(f32, prob_str) catch 1.0;
        }

        return fault;
    }

    fn parseDuration(s: []const u8) ?u64 {
        if (std.mem.endsWith(u8, s, "ms")) {
            const num = std.fmt.parseInt(u64, s[0 .. s.len - 2], 10) catch return null;
            return num * std.time.ns_per_ms;
        } else if (std.mem.endsWith(u8, s, "us")) {
            const num = std.fmt.parseInt(u64, s[0 .. s.len - 2], 10) catch return null;
            return num * std.time.ns_per_us;
        } else if (std.mem.endsWith(u8, s, "s")) {
            const num = std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) catch return null;
            return num * std.time.ns_per_s;
        }
        return std.fmt.parseInt(u64, s, 10) catch null;
    }
};

/// Performance profiler
pub const Profiler = struct {
    /// Timing spans
    spans: std.StringHashMap(SpanStats),
    /// Start times for active spans
    active_spans: std.StringHashMap(i128),
    /// Allocator
    allocator: Allocator,
    /// Enabled
    enabled: bool,

    pub const SpanStats = struct {
        count: u64,
        total_ns: u64,
        min_ns: u64,
        max_ns: u64,
        last_ns: u64,

        pub fn avg(self: *const SpanStats) f64 {
            if (self.count == 0) return 0;
            return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.count));
        }
    };

    pub fn init(allocator: Allocator, enabled: bool) Profiler {
        return .{
            .spans = std.StringHashMap(SpanStats).init(allocator),
            .active_spans = std.StringHashMap(i128).init(allocator),
            .allocator = allocator,
            .enabled = enabled,
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.spans.deinit();
        self.active_spans.deinit();
    }

    /// Start a timing span
    pub fn startSpan(self: *Profiler, name: []const u8) void {
        if (!self.enabled) return;
        self.active_spans.put(name, std.time.nanoTimestamp()) catch {};
    }

    /// End a timing span
    pub fn endSpan(self: *Profiler, name: []const u8) void {
        if (!self.enabled) return;

        const end = std.time.nanoTimestamp();
        const start = self.active_spans.get(name) orelse return;
        const elapsed: u64 = @intCast(end - start);

        const result = self.spans.getOrPut(name) catch return;
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .count = 0,
                .total_ns = 0,
                .min_ns = std.math.maxInt(u64),
                .max_ns = 0,
                .last_ns = 0,
            };
        }

        result.value_ptr.count += 1;
        result.value_ptr.total_ns += elapsed;
        result.value_ptr.last_ns = elapsed;
        result.value_ptr.min_ns = @min(result.value_ptr.min_ns, elapsed);
        result.value_ptr.max_ns = @max(result.value_ptr.max_ns, elapsed);

        _ = self.active_spans.remove(name);
    }

    /// Get report
    pub fn getReport(self: *const Profiler, allocator: Allocator) ![]u8 {
        var report = std.ArrayList(u8).init(allocator);
        const writer = report.writer();

        try writer.writeAll("\n╔══════════════════════════════════════════════════════════════════╗\n");
        try writer.writeAll("║                    PERFORMANCE PROFILE                            ║\n");
        try writer.writeAll("╠══════════════════════════════════════════════════════════════════╣\n");
        try writer.print("║ {s:<20} │ {s:>8} │ {s:>10} │ {s:>10} │ {s:>10} ║\n", .{ "Span", "Count", "Avg (μs)", "Min (μs)", "Max (μs)" });
        try writer.writeAll("╠══════════════════════════════════════════════════════════════════╣\n");

        var iter = self.spans.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr;
            try writer.print("║ {s:<20} │ {d:>8} │ {d:>10.2} │ {d:>10} │ {d:>10} ║\n", .{
                entry.key_ptr.*,
                stats.count,
                stats.avg() / 1000.0,
                stats.min_ns / 1000,
                stats.max_ns / 1000,
            });
        }

        try writer.writeAll("╚══════════════════════════════════════════════════════════════════╝\n");

        return report.toOwnedSlice();
    }
};

/// Mock data generator for testing
pub const MockGenerator = struct {
    allocator: Allocator,
    rng: std.Random,
    slot_counter: u64,

    pub fn init(allocator: Allocator) MockGenerator {
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())).random(),
            .slot_counter = 0,
        };
    }

    /// Generate a mock transaction
    pub fn mockTransaction(self: *MockGenerator) ![64]u8 {
        var sig: [64]u8 = undefined;
        self.rng.bytes(&sig);
        return sig;
    }

    /// Generate a mock account
    pub fn mockAccount(self: *MockGenerator) MockAccount {
        var pubkey: [32]u8 = undefined;
        var owner: [32]u8 = undefined;
        self.rng.bytes(&pubkey);
        self.rng.bytes(&owner);

        return .{
            .pubkey = pubkey,
            .lamports = self.rng.int(u64) % 1_000_000_000_000,
            .owner = owner,
            .data_len = self.rng.int(u32) % 10240,
        };
    }

    pub const MockAccount = struct {
        pubkey: [32]u8,
        lamports: u64,
        owner: [32]u8,
        data_len: u32,
    };

    /// Generate mock slot data
    pub fn mockSlot(self: *MockGenerator) MockSlot {
        self.slot_counter += 1;

        var blockhash: [32]u8 = undefined;
        self.rng.bytes(&blockhash);

        return .{
            .slot = self.slot_counter,
            .parent = if (self.slot_counter > 0) self.slot_counter - 1 else 0,
            .blockhash = blockhash,
            .transaction_count = self.rng.int(u32) % 5000,
            .block_time = std.time.timestamp(),
        };
    }

    pub const MockSlot = struct {
        slot: u64,
        parent: u64,
        blockhash: [32]u8,
        transaction_count: u32,
        block_time: i64,
    };
};

/// Test mode indicator for logs
pub const TestIndicator = struct {
    test_mode: bool,
    test_name: ?[]const u8,

    pub fn prefix(self: *const TestIndicator) []const u8 {
        if (self.test_mode) {
            return "[TEST] ";
        }
        return "";
    }

    pub fn log(self: *const TestIndicator, comptime fmt: []const u8, args: anytype) void {
        if (self.test_mode) {
            std.log.info("[TEST] " ++ fmt, args);
        } else {
            std.log.info(fmt, args);
        }
    }

    pub fn warn(self: *const TestIndicator, comptime fmt: []const u8, args: anytype) void {
        if (self.test_mode) {
            std.log.warn("[TEST] " ++ fmt, args);
        } else {
            std.log.warn(fmt, args);
        }
    }
};

/// Global test context
pub var global_test_config: TestConfig = .{};
pub var global_features: FeatureFlags = .{};
pub var global_profiler: ?*Profiler = null;
pub var global_fault_injector: ?*FaultInjector = null;
pub var global_test_indicator: TestIndicator = .{ .test_mode = false, .test_name = null };

/// Initialize test mode from CLI
pub fn initTestMode(allocator: Allocator, args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--test-mode")) {
            global_test_config.test_mode = true;
            global_test_indicator.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            global_test_config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            global_test_config.profiling = true;
            global_profiler = try allocator.create(Profiler);
            global_profiler.?.* = Profiler.init(allocator, true);
        } else if (std.mem.eql(u8, arg, "--mock-data")) {
            global_test_config.mock_data = true;
        } else if (std.mem.startsWith(u8, arg, "--inject-fault=")) {
            const spec = arg["--inject-fault=".len..];
            if (global_fault_injector == null) {
                global_fault_injector = try allocator.create(FaultInjector);
                global_fault_injector.?.* = FaultInjector.init(allocator);
            }
            if (FaultInjector.parseFault(spec)) |fault| {
                try global_fault_injector.?.addFault(spec, fault);
            }
        }
    }

    global_features = FeatureFlags.parseFromArgs(args);

    if (global_test_config.test_mode) {
        std.log.info("═══════════════════════════════════════════════════════════════", .{});
        std.log.info("[TEST] Vexor running in TEST MODE", .{});
        std.log.info("[TEST] Mock data: {s}", .{if (global_test_config.mock_data) "enabled" else "disabled"});
        std.log.info("[TEST] Profiling: {s}", .{if (global_test_config.profiling) "enabled" else "disabled"});
        std.log.info("═══════════════════════════════════════════════════════════════", .{});
    }
}

/// Check if feature is enabled
pub fn isFeatureEnabled(feature: []const u8) bool {
    if (std.mem.eql(u8, feature, "bpf")) return global_features.bpf_vm;
    if (std.mem.eql(u8, feature, "af_xdp")) return global_features.af_xdp;
    if (std.mem.eql(u8, feature, "quic")) return global_features.quic;
    if (std.mem.eql(u8, feature, "masque")) return global_features.masque;
    if (std.mem.eql(u8, feature, "ramdisk")) return global_features.ramdisk;
    if (std.mem.eql(u8, feature, "gpu")) return global_features.gpu_acceleration;
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "FeatureFlags: parse from args" {
    const args = [_][]const u8{
        "--enable-feature=masque",
        "--disable-feature=af_xdp",
    };
    const flags = FeatureFlags.parseFromArgs(&args);

    try std.testing.expect(flags.masque);
    try std.testing.expect(!flags.af_xdp);
}

test "FaultInjector: parse fault spec" {
    const fault = FaultInjector.parseFault("network_delay:100ms:0.5");
    try std.testing.expect(fault != null);
    try std.testing.expectEqual(FaultInjector.FaultType.network_delay, fault.?.fault_type);
    try std.testing.expectEqual(@as(u64, 100_000_000), fault.?.duration_ns.?);
}

test "Profiler: basic timing" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator, true);
    defer profiler.deinit();

    profiler.startSpan("test");
    std.time.sleep(1_000_000); // 1ms
    profiler.endSpan("test");

    const stats = profiler.spans.get("test");
    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(u64, 1), stats.?.count);
}

