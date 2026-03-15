//! Discovery Mode
//!
//! Tests each networking tier to determine what works on this hardware.
//! After each test (pass or fail), the network is restored to its original state.
//!
//! Process:
//!   1. Save original network state
//!   2. For each tier (highest performance first):
//!      a. Try to initialize the tier
//!      b. Monitor for network failure (Guardian watches)
//!      c. If failure: restore network, mark tier as BROKEN
//!      d. If success: shut down cleanly, mark tier as WORKS
//!      e. Restore to original state (clean slate for next test)
//!   3. Save hardware profile with results
//!   4. Return with network in original state

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const guardian_mod = @import("guardian/root.zig");
const hardware_profile = @import("hardware_profile.zig");
const preflight = @import("preflight_check.zig");

const HardwareProfile = hardware_profile.HardwareProfile;
const NetworkTier = hardware_profile.NetworkTier;
const TierStatus = hardware_profile.TierStatus;
const NetworkSnapshot = guardian_mod.NetworkSnapshot;

/// Discovery configuration
pub const DiscoveryConfig = struct {
    /// Interface to test on
    interface: []const u8,
    
    /// How long to test each tier (milliseconds)
    test_duration_ms: u32 = 5000,
    
    /// How long to wait for network recovery after failure (ms)
    recovery_timeout_ms: u32 = 10000,
    
    /// Path to save hardware profile
    profile_path: []const u8 = hardware_profile.BACKUP_PROFILE_PATH,
    
    /// Whether to test all tiers or stop at first working one
    test_all_tiers: bool = true,
    
    /// Tiers to skip (already known to be broken)
    skip_tiers: []const NetworkTier = &.{},
    
    /// Whether to run pre-flight check before discovery
    run_preflight: bool = true,
    
    /// Skip risky tiers (AF_XDP) if pre-flight fails
    skip_risky_on_preflight_fail: bool = true,
};

/// Result of a single tier test
pub const SingleTierResult = struct {
    tier: NetworkTier,
    status: TierStatus,
    initialized: bool,
    caused_failure: bool,
    restored: bool,
    duration_ms: u64,
    error_message: []const u8,
};

/// Result of complete discovery
pub const DiscoveryResult = struct {
    success: bool,
    tiers_tested: u32,
    tiers_working: u32,
    tiers_broken: u32,
    best_tier: ?NetworkTier,
    network_restored: bool,
    profile_saved: bool,
    results: [6]SingleTierResult,
    
    pub fn print(self: *const DiscoveryResult) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              DISCOVERY RESULTS                            ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Tiers Tested:  {d}\n", .{self.tiers_tested});
        std.debug.print("║ Tiers Working: {d}\n", .{self.tiers_working});
        std.debug.print("║ Tiers Broken:  {d}\n", .{self.tiers_broken});
        std.debug.print("║ Network Restored: {s}\n", .{if (self.network_restored) "YES" else "NO"});
        std.debug.print("║ Profile Saved: {s}\n", .{if (self.profile_saved) "YES" else "NO"});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ INDIVIDUAL RESULTS:\n", .{});
        
        for (self.results[1..6]) |r| {
            if (r.status != .untested) {
                const marker = switch (r.status) {
                    .works => "✓",
                    .broken => "✗",
                    else => "?",
                };
                std.debug.print("║   {s} {s}: {s}", .{marker, r.tier.name(), r.status.toString()});
                if (r.caused_failure) {
                    std.debug.print(" (caused network failure)", .{});
                }
                std.debug.print("\n", .{});
            }
        }
        
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        if (self.best_tier) |best| {
            std.debug.print("║ BEST TIER TO USE: {s}\n", .{best.name()});
        } else {
            std.debug.print("║ BEST TIER TO USE: None found (use standard_naive)\n", .{});
        }
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
};

/// Discovery Mode Manager
pub const DiscoveryMode = struct {
    config: DiscoveryConfig,
    allocator: std.mem.Allocator,
    
    // Original network state (saved before any changes)
    original_snapshot: ?NetworkSnapshot,
    
    // Results
    profile: HardwareProfile,
    
    pub fn init(allocator: std.mem.Allocator, config: DiscoveryConfig) DiscoveryMode {
        return .{
            .config = config,
            .allocator = allocator,
            .original_snapshot = null,
            .profile = HardwareProfile.init(),
        };
    }
    
    /// Run complete discovery process
    pub fn runDiscovery(self: *DiscoveryMode) !DiscoveryResult {
        var result = DiscoveryResult{
            .success = false,
            .tiers_tested = 0,
            .tiers_working = 0,
            .tiers_broken = 0,
            .best_tier = null,
            .network_restored = false,
            .profile_saved = false,
            .results = undefined,
        };
        
        // Initialize results
        for (&result.results) |*r| {
            r.* = .{
                .tier = .standard_naive,
                .status = .untested,
                .initialized = false,
                .caused_failure = false,
                .restored = false,
                .duration_ms = 0,
                .error_message = "",
            };
        }
        
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║       VEXOR NETWORK DISCOVERY MODE                        ║\n", .{});
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("║  Testing each networking tier to find what works on      ║\n", .{});
        std.debug.print("║  this hardware. Network will be restored after each test.║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        
        // Step 1: Capture original network state
        std.debug.print("\n[Discovery] Step 1: Capturing original network state...\n", .{});
        self.original_snapshot = guardian_mod.captureSnapshot(self.config.interface) catch |err| {
            std.debug.print("[Discovery] ERROR: Could not capture snapshot: {}\n", .{err});
            return error.SnapshotFailed;
        };
        
        if (self.original_snapshot) |*snap| {
            snap.print();
        }
        
        // Populate hardware profile
        self.profile.populateMachineInfo(self.config.interface);
        
        // Step 1.5: Run pre-flight check (verifies restoration works)
        var preflight_passed = true;
        if (self.config.run_preflight) {
            std.debug.print("\n[Discovery] Step 1.5: Running pre-flight safety check...\n", .{});
            std.debug.print("           This verifies network restoration actually works.\n", .{});
            
            const preflight_result = preflight.runPreflightCheck(self.config.interface);
            preflight_passed = preflight_result.passed;
            
            if (!preflight_passed) {
                std.debug.print("\n[Discovery] ⚠️  PRE-FLIGHT FAILED!\n", .{});
                if (self.config.skip_risky_on_preflight_fail) {
                    std.debug.print("           Risky tiers (AF_XDP) will be SKIPPED.\n", .{});
                    std.debug.print("           Safe tiers (io_uring, sockets) will still be tested.\n", .{});
                } else {
                    std.debug.print("           Aborting discovery for safety.\n", .{});
                    return error.PreflightFailed;
                }
            } else {
                std.debug.print("\n[Discovery] ✓ Pre-flight passed! Safe to test all tiers.\n", .{});
            }
        }
        
        // Step 2: Test each tier
        std.debug.print("\n[Discovery] Step 2: Testing tiers...\n", .{});
        
        const tiers_to_test = [_]NetworkTier{
            .af_xdp_zero_copy,
            .af_xdp_copy,
            .io_uring,
            .standard_batched,
            .standard_naive,
        };
        
        for (tiers_to_test) |tier| {
            // Check if we should skip this tier
            var should_skip = false;
            for (self.config.skip_tiers) |skip| {
                if (skip == tier) {
                    should_skip = true;
                    break;
                }
            }
            
            // Skip risky tiers if pre-flight failed
            if (!preflight_passed and self.config.skip_risky_on_preflight_fail) {
                const is_risky = (tier == .af_xdp_zero_copy or tier == .af_xdp_copy);
                if (is_risky) {
                    std.debug.print("\n[Discovery] Skipping {s} (pre-flight failed, too risky)\n", .{tier.name()});
                    self.profile.markTier(tier, .broken);
                    result.results[@intFromEnum(tier)].status = .broken;
                    result.results[@intFromEnum(tier)].error_message = "Skipped: pre-flight failed";
                    result.tiers_broken += 1;
                    continue;
                }
            }
            
            if (should_skip) {
                std.debug.print("\n[Discovery] Skipping {s} (in skip list)\n", .{tier.name()});
                continue;
            }
            
            // Test this tier
            const tier_result = self.testSingleTier(tier);
            result.results[@intFromEnum(tier)] = tier_result;
            result.tiers_tested += 1;
            
            if (tier_result.status == .works) {
                result.tiers_working += 1;
            } else if (tier_result.status == .broken) {
                result.tiers_broken += 1;
            }
            
            // Update profile
            self.profile.markTier(tier, tier_result.status);
            
            // If not testing all tiers, stop at first working one
            if (!self.config.test_all_tiers and tier_result.status == .works) {
                std.debug.print("\n[Discovery] Found working tier, stopping (test_all_tiers=false)\n", .{});
                break;
            }
        }
        
        // Step 3: Final restore to original state
        std.debug.print("\n[Discovery] Step 3: Final restoration to original state...\n", .{});
        if (self.original_snapshot) |*snap| {
            const restore_result = guardian_mod.restoreFromSnapshot(snap);
            result.network_restored = restore_result.success;
        }
        
        // Step 4: Determine best tier and save profile
        std.debug.print("\n[Discovery] Step 4: Saving hardware profile...\n", .{});
        self.profile.discovery_count += 1;
        self.profile.determineBestTier();
        result.best_tier = self.profile.best_tier;
        
        self.profile.saveToFile(self.allocator, self.config.profile_path) catch |err| {
            std.debug.print("[Discovery] Warning: Could not save profile: {}\n", .{err});
        };
        result.profile_saved = true;
        
        result.success = result.tiers_working > 0 and result.network_restored;
        
        // Print final results
        result.print();
        self.profile.print();
        
        return result;
    }
    
    /// Test a single tier
    fn testSingleTier(self: *DiscoveryMode, tier: NetworkTier) SingleTierResult {
        var result = SingleTierResult{
            .tier = tier,
            .status = .untested,
            .initialized = false,
            .caused_failure = false,
            .restored = false,
            .duration_ms = 0,
            .error_message = "",
        };
        
        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  Testing: {s}\n", .{tier.name()});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        
        const start_time = std.time.milliTimestamp();
        
        // Try to initialize the tier
        std.debug.print("[Test] Initializing...\n", .{});
        
        const init_result = switch (tier) {
            .af_xdp_zero_copy => self.testAfXdp(true),
            .af_xdp_copy => self.testAfXdp(false),
            .io_uring => self.testIoUring(),
            .standard_batched => self.testBatchedSockets(),
            .standard_naive => self.testNaiveSockets(),
        };
        
        result.initialized = init_result.success;
        
        if (!init_result.success) {
            std.debug.print("[Test] Initialization failed: {s}\n", .{init_result.error_message});
            result.status = .unavailable;
            result.error_message = init_result.error_message;
            result.duration_ms = @intCast(std.time.milliTimestamp() - start_time);
            
            // Restore anyway (clean slate)
            self.restoreOriginalState(&result);
            return result;
        }
        
        std.debug.print("[Test] Initialized successfully\n", .{});
        
        // Monitor for problems
        std.debug.print("[Test] Monitoring for {d}ms...\n", .{self.config.test_duration_ms});
        
        const network_ok = self.monitorNetworkHealth(self.config.test_duration_ms);
        
        if (!network_ok) {
            std.debug.print("[Test] NETWORK FAILURE DETECTED!\n", .{});
            result.caused_failure = true;
            result.status = .broken;
            result.error_message = "Caused network failure during test";
            
            // CRITICAL: Restore network immediately
            std.debug.print("[Test] Restoring network...\n", .{});
            self.restoreOriginalState(&result);
        } else {
            std.debug.print("[Test] No problems detected - tier WORKS\n", .{});
            result.status = .works;
            
            // Clean shutdown and restore (clean slate for next test)
            self.restoreOriginalState(&result);
        }
        
        result.duration_ms = @intCast(std.time.milliTimestamp() - start_time);
        
        std.debug.print("[Test] Complete: {s} in {d}ms\n", .{
            result.status.toString(), result.duration_ms
        });
        
        return result;
    }
    
    const InitResult = struct { success: bool, error_message: []const u8 };
    
    /// Test AF_XDP initialization
    fn testAfXdp(self: *DiscoveryMode, zero_copy: bool) InitResult {
        _ = self;
        _ = zero_copy;
        
        // Check if running as root
        if (linux.getuid() != 0) {
            return .{ .success = false, .error_message = "Requires root privileges" };
        }
        
        // Try to create AF_XDP socket
        const AF_XDP = 44;
        const sock = posix.socket(AF_XDP, posix.SOCK.RAW, 0) catch {
            return .{ .success = false, .error_message = "Could not create AF_XDP socket" };
        };
        posix.close(sock);
        
        return .{ .success = true, .error_message = "" };
    }
    
    /// Test io_uring initialization
    fn testIoUring(self: *DiscoveryMode) InitResult {
        _ = self;
        
        var params = std.mem.zeroes(linux.io_uring_params);
        const fd = linux.io_uring_setup(64, &params);
        
        if (fd < 0) {
            return .{ .success = false, .error_message = "io_uring_setup failed" };
        }
        
        _ = linux.close(@intCast(fd));
        return .{ .success = true, .error_message = "" };
    }
    
    /// Test batched sockets
    fn testBatchedSockets(self: *DiscoveryMode) InitResult {
        _ = self;
        
        const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0) catch {
            return .{ .success = false, .error_message = "Could not create socket" };
        };
        posix.close(sock);
        
        return .{ .success = true, .error_message = "" };
    }
    
    /// Test naive sockets (always works)
    fn testNaiveSockets(self: *DiscoveryMode) InitResult {
        _ = self;
        
        const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
            return .{ .success = false, .error_message = "Could not create socket" };
        };
        posix.close(sock);
        
        return .{ .success = true, .error_message = "" };
    }
    
    /// Monitor network health for a duration
    fn monitorNetworkHealth(self: *DiscoveryMode, duration_ms: u32) bool {
        const check_interval_ms: u32 = 200;
        var elapsed: u32 = 0;
        
        while (elapsed < duration_ms) {
            // Check if network interface is still up
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/operstate", .{
                self.config.interface
            }) catch return false;
            
            const file = std.fs.openFileAbsolute(path, .{}) catch return false;
            defer file.close();
            
            var buf: [32]u8 = undefined;
            const bytes_read = file.read(&buf) catch return false;
            if (bytes_read == 0) return false;
            
            const state = std.mem.trim(u8, buf[0..bytes_read], " \n\t");
            const is_up = std.mem.eql(u8, state, "up") or std.mem.eql(u8, state, "unknown");
            
            if (!is_up) {
                std.debug.print("[Monitor] Network interface is DOWN!\n", .{});
                return false;
            }
            
            std.time.sleep(check_interval_ms * std.time.ns_per_ms);
            elapsed += check_interval_ms;
        }
        
        return true;
    }
    
    /// Restore to original network state
    fn restoreOriginalState(self: *DiscoveryMode, result: *SingleTierResult) void {
        if (self.original_snapshot) |*snap| {
            const restore_result = guardian_mod.restoreFromSnapshot(snap);
            result.restored = restore_result.success;
            
            if (restore_result.success) {
                std.debug.print("[Restore] Network restored to original state\n", .{});
            } else {
                std.debug.print("[Restore] WARNING: Restoration incomplete!\n", .{});
            }
        } else {
            std.debug.print("[Restore] No snapshot available\n", .{});
            result.restored = false;
        }
    }
};

/// Run discovery and return best tier
pub fn discoverBestTier(allocator: std.mem.Allocator, interface: []const u8) !?NetworkTier {
    var discovery = DiscoveryMode.init(allocator, .{
        .interface = interface,
        .test_all_tiers = true,
    });
    
    const result = try discovery.runDiscovery();
    return result.best_tier;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Network Discovery Mode\n", .{});
    std.debug.print("Interface: {s}\n", .{interface});
    std.debug.print("(Testing on loopback is safe)\n", .{});
    
    var discovery = DiscoveryMode.init(allocator, .{
        .interface = interface,
        .test_duration_ms = 2000, // Shorter for testing
        .test_all_tiers = true,
    });
    
    _ = try discovery.runDiscovery();
    
    std.debug.print("\nDiscovery complete!\n", .{});
}
