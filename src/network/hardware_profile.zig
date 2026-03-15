//! Hardware Profile
//!
//! Stores the results of network tier discovery for a specific machine.
//! This profile is saved to disk and loaded on subsequent runs to avoid
//! re-testing tiers that are known to fail on this hardware.
//!
//! The profile includes:
//!   - Machine identification (hostname, interface, driver)
//!   - Status of each networking tier (WORKS, BROKEN, UNTESTED)
//!   - The best working tier to use
//!   - Timestamps and failure reasons

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Status of a networking tier for this hardware
pub const TierStatus = enum {
    untested,    // Never tested on this hardware
    works,       // Tested and works correctly
    broken,      // Tested and caused problems (don't use)
    unavailable, // System doesn't support it (missing capabilities)
    
    pub fn toString(self: TierStatus) []const u8 {
        return switch (self) {
            .untested => "UNTESTED",
            .works => "WORKS",
            .broken => "BROKEN",
            .unavailable => "UNAVAILABLE",
        };
    }
};

/// Network tier identifiers
pub const NetworkTier = enum(u8) {
    af_xdp_zero_copy = 1,
    af_xdp_copy = 2,
    io_uring = 3,
    standard_batched = 4,
    standard_naive = 5,
    
    pub fn name(self: NetworkTier) []const u8 {
        return switch (self) {
            .af_xdp_zero_copy => "AF_XDP Zero-Copy",
            .af_xdp_copy => "AF_XDP Copy Mode",
            .io_uring => "io_uring",
            .standard_batched => "Batched Sockets",
            .standard_naive => "Standard Sockets",
        };
    }
};

/// Result of testing a single tier
pub const TierTestResult = struct {
    tier: NetworkTier,
    status: TierStatus,
    tested_at: i64,
    test_duration_ms: u64,
    error_message: ?[]const u8,
    caused_network_failure: bool,
    restored_successfully: bool,
};

/// Complete hardware profile for a machine
pub const HardwareProfile = struct {
    // Machine identification
    hostname: [64]u8,
    hostname_len: usize,
    interface: [32]u8,
    interface_len: usize,
    nic_driver: [32]u8,
    nic_driver_len: usize,
    kernel_version: [32]u8,
    kernel_version_len: usize,
    
    // Profile metadata
    created_at: i64,
    last_updated: i64,
    discovery_count: u32,
    
    // Tier status (indexed by NetworkTier enum value)
    tier_status: [6]TierStatus,
    tier_last_tested: [6]i64,
    tier_failure_count: [6]u32,
    
    // Best tier to use
    best_tier: ?NetworkTier,
    
    /// Initialize an empty profile
    pub fn init() HardwareProfile {
        return .{
            .hostname = undefined,
            .hostname_len = 0,
            .interface = undefined,
            .interface_len = 0,
            .nic_driver = undefined,
            .nic_driver_len = 0,
            .kernel_version = undefined,
            .kernel_version_len = 0,
            .created_at = std.time.timestamp(),
            .last_updated = std.time.timestamp(),
            .discovery_count = 0,
            .tier_status = .{ .untested, .untested, .untested, .untested, .untested, .untested },
            .tier_last_tested = .{ 0, 0, 0, 0, 0, 0 },
            .tier_failure_count = .{ 0, 0, 0, 0, 0, 0 },
            .best_tier = null,
        };
    }
    
    /// Populate machine info
    pub fn populateMachineInfo(self: *HardwareProfile, interface: []const u8) void {
        // Hostname
        var uts: linux.utsname = undefined;
        _ = linux.uname(&uts);
        const nodename = std.mem.sliceTo(&uts.nodename, 0);
        @memcpy(self.hostname[0..nodename.len], nodename);
        self.hostname_len = nodename.len;
        
        // Kernel version
        const release = std.mem.sliceTo(&uts.release, 0);
        const kv_len = @min(release.len, 32);
        @memcpy(self.kernel_version[0..kv_len], release[0..kv_len]);
        self.kernel_version_len = kv_len;
        
        // Interface
        const if_len = @min(interface.len, 32);
        @memcpy(self.interface[0..if_len], interface[0..if_len]);
        self.interface_len = if_len;
        
        // NIC driver (from /sys/class/net/<iface>/device/driver)
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/device/driver", .{interface}) catch {
            @memcpy(self.nic_driver[0..7], "unknown");
            self.nic_driver_len = 7;
            return;
        };
        
        // Read the driver symlink
        var link_buf: [256]u8 = undefined;
        const link = std.posix.readlink(path, &link_buf) catch {
            @memcpy(self.nic_driver[0..7], "unknown");
            self.nic_driver_len = 7;
            return;
        };
        if (std.mem.lastIndexOfScalar(u8, link, '/')) |idx| {
            const driver = link[idx + 1 ..];
            const drv_len = @min(driver.len, 32);
            @memcpy(self.nic_driver[0..drv_len], driver[0..drv_len]);
            self.nic_driver_len = drv_len;
        } else {
            @memcpy(self.nic_driver[0..7], "unknown");
            self.nic_driver_len = 7;
        }
    }
    
    /// Mark a tier's test result
    pub fn markTier(self: *HardwareProfile, tier: NetworkTier, status: TierStatus) void {
        const idx = @intFromEnum(tier);
        self.tier_status[idx] = status;
        self.tier_last_tested[idx] = std.time.timestamp();
        if (status == .broken) {
            self.tier_failure_count[idx] += 1;
        }
        self.last_updated = std.time.timestamp();
    }
    
    /// Get status of a tier
    pub fn getTierStatus(self: *const HardwareProfile, tier: NetworkTier) TierStatus {
        return self.tier_status[@intFromEnum(tier)];
    }
    
    /// Determine the best working tier
    pub fn determineBestTier(self: *HardwareProfile) void {
        // Check tiers in order of performance (best first)
        const tiers = [_]NetworkTier{
            .af_xdp_zero_copy,
            .af_xdp_copy,
            .io_uring,
            .standard_batched,
            .standard_naive,
        };
        
        for (tiers) |tier| {
            if (self.getTierStatus(tier) == .works) {
                self.best_tier = tier;
                return;
            }
        }
        
        // Fallback to naive (should always work)
        self.best_tier = .standard_naive;
    }
    
    /// Convert to JSON for saving
    pub fn toJson(self: *const HardwareProfile, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        const writer = buffer.writer();
        
        try writer.writeAll("{\n");
        try std.fmt.format(writer, "  \"hostname\": \"{s}\",\n", .{self.hostname[0..self.hostname_len]});
        try std.fmt.format(writer, "  \"interface\": \"{s}\",\n", .{self.interface[0..self.interface_len]});
        try std.fmt.format(writer, "  \"nic_driver\": \"{s}\",\n", .{self.nic_driver[0..self.nic_driver_len]});
        try std.fmt.format(writer, "  \"kernel_version\": \"{s}\",\n", .{self.kernel_version[0..self.kernel_version_len]});
        try std.fmt.format(writer, "  \"created_at\": {d},\n", .{self.created_at});
        try std.fmt.format(writer, "  \"last_updated\": {d},\n", .{self.last_updated});
        try std.fmt.format(writer, "  \"discovery_count\": {d},\n", .{self.discovery_count});
        
        try writer.writeAll("  \"tiers\": {\n");
        const tiers = [_]NetworkTier{
            .af_xdp_zero_copy,
            .af_xdp_copy,
            .io_uring,
            .standard_batched,
            .standard_naive,
        };
        for (tiers, 0..) |tier, i| {
            const status = self.getTierStatus(tier);
            const comma = if (i < tiers.len - 1) "," else "";
            try std.fmt.format(writer, "    \"{s}\": \"{s}\"{s}\n", .{
                @tagName(tier), status.toString(), comma
            });
        }
        try writer.writeAll("  },\n");
        
        if (self.best_tier) |best| {
            try std.fmt.format(writer, "  \"best_tier\": \"{s}\"\n", .{@tagName(best)});
        } else {
            try writer.writeAll("  \"best_tier\": null\n");
        }
        
        try writer.writeAll("}\n");
        
        return buffer.toOwnedSlice();
    }
    
    /// Save profile to file
    pub fn saveToFile(self: *const HardwareProfile, allocator: std.mem.Allocator, path: []const u8) !void {
        const json_data = try self.toJson(allocator);
        defer allocator.free(json_data);
        
        // Ensure directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch {};
        }
        
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json_data);
    }
    
    /// Print profile summary
    pub fn print(self: *const HardwareProfile) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              HARDWARE PROFILE                             ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Hostname:    {s}\n", .{self.hostname[0..self.hostname_len]});
        std.debug.print("║ Interface:   {s}\n", .{self.interface[0..self.interface_len]});
        std.debug.print("║ NIC Driver:  {s}\n", .{self.nic_driver[0..self.nic_driver_len]});
        std.debug.print("║ Kernel:      {s}\n", .{self.kernel_version[0..self.kernel_version_len]});
        std.debug.print("║ Discoveries: {d}\n", .{self.discovery_count});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ TIER STATUS:\n", .{});
        std.debug.print("║ ──────────────────────────────────────────────────────\n", .{});
        
        const tiers = [_]NetworkTier{
            .af_xdp_zero_copy,
            .af_xdp_copy,
            .io_uring,
            .standard_batched,
            .standard_naive,
        };
        
        for (tiers) |tier| {
            const status = self.getTierStatus(tier);
            const failures = self.tier_failure_count[@intFromEnum(tier)];
            const marker = switch (status) {
                .works => "✓",
                .broken => "✗",
                .untested => "?",
                .unavailable => "-",
            };
            
            std.debug.print("║   {s} {s}: {s}", .{marker, tier.name(), status.toString()});
            if (failures > 0) {
                std.debug.print(" (failed {d}x)", .{failures});
            }
            std.debug.print("\n", .{});
        }
        
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        if (self.best_tier) |best| {
            std.debug.print("║ BEST TIER: {s}\n", .{best.name()});
        } else {
            std.debug.print("║ BEST TIER: Not determined (run discovery)\n", .{});
        }
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
};

/// Default path for hardware profile
pub const DEFAULT_PROFILE_PATH = "/var/lib/vexor/hardware-profile.json";
pub const BACKUP_PROFILE_PATH = "/tmp/vexor-hardware-profile.json";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Hardware Profile Test\n", .{});
    std.debug.print("Interface: {s}\n", .{interface});
    
    var profile = HardwareProfile.init();
    profile.populateMachineInfo(interface);
    
    // Simulate some test results
    profile.markTier(.af_xdp_zero_copy, .broken);
    profile.markTier(.af_xdp_copy, .broken);
    profile.markTier(.io_uring, .works);
    profile.markTier(.standard_batched, .works);
    profile.markTier(.standard_naive, .works);
    profile.discovery_count = 1;
    profile.determineBestTier();
    
    profile.print();
    
    // Save to file
    profile.saveToFile(allocator, BACKUP_PROFILE_PATH) catch |err| {
        std.debug.print("Warning: Could not save profile: {}\n", .{err});
    };
    
    std.debug.print("\nProfile saved to: {s}\n", .{BACKUP_PROFILE_PATH});
}
