//! Network Guardian
//!
//! A watchdog system that monitors network health and automatically
//! restores the pre-Vexor network state if anything goes wrong.
//!
//! Features:
//!   - Takes a snapshot before any network changes
//!   - Monitors network health via heartbeat checks
//!   - Automatically restores snapshot if network fails
//!   - Configurable timeout and check intervals
//!
//! This prevents the need to use IPMI to recover from AF_XDP issues.

const std = @import("std");
const posix = std.posix;
const snapshot_mod = @import("snapshot.zig");
const restorer_mod = @import("restorer.zig");
const NetworkSnapshot = snapshot_mod.NetworkSnapshot;

/// Guardian configuration
pub const GuardianConfig = struct {
    /// Interface to monitor
    interface: []const u8,
    
    /// How often to check network health (milliseconds)
    check_interval_ms: u32 = 500,
    
    /// How long network must be down before triggering restore (milliseconds)
    failure_timeout_ms: u32 = 3000,
    
    /// IP to ping for health check (usually gateway or localhost)
    health_check_ip: [4]u8 = .{ 127, 0, 0, 1 },
    
    /// Port to check (usually SSH = 22)
    health_check_port: u16 = 22,
    
    /// Whether to automatically restore on failure
    auto_restore: bool = true,
    
    /// Path to save snapshot
    snapshot_path: []const u8 = "/tmp/vexor-network-snapshot.json",
};

/// Guardian state
pub const GuardianState = enum(u8) {
    not_started = 0,
    running = 1,
    network_degraded = 2,
    restoring = 3,
    restored = 4,
    stopped = 5,
    failed = 6,
};

/// Network Guardian
pub const NetworkGuardian = struct {
    config: GuardianConfig,
    snapshot: ?NetworkSnapshot,
    state: std.atomic.Value(GuardianState),
    running: std.atomic.Value(bool),
    last_success_time: std.atomic.Value(i64),
    failure_count: std.atomic.Value(u32),
    restore_count: u32,
    allocator: std.mem.Allocator,
    
    // Thread handle for watchdog
    watchdog_thread: ?std.Thread,
    
    pub fn init(allocator: std.mem.Allocator, config: GuardianConfig) NetworkGuardian {
        return .{
            .config = config,
            .snapshot = null,
            .state = std.atomic.Value(GuardianState).init(.not_started),
            .running = std.atomic.Value(bool).init(false),
            .last_success_time = std.atomic.Value(i64).init(0),
            .failure_count = std.atomic.Value(u32).init(0),
            .restore_count = 0,
            .allocator = allocator,
            .watchdog_thread = null,
        };
    }
    
    /// Take a snapshot of current network state
    pub fn takeSnapshot(self: *NetworkGuardian) !void {
        std.debug.print("\n", .{});
        std.debug.print("[Guardian] Taking network snapshot...\n", .{});
        
        self.snapshot = try snapshot_mod.captureSnapshot(self.config.interface);
        
        if (self.snapshot) |*snap| {
            // Save to file for persistence
            snap.saveToFile(self.allocator, self.config.snapshot_path) catch |err| {
                std.debug.print("[Guardian] Warning: Could not save snapshot to file: {}\n", .{err});
            };
            
            std.debug.print("[Guardian] Snapshot captured and saved\n", .{});
            snap.print();
        }
    }
    
    /// Check if network is healthy
    fn checkNetworkHealth(self: *NetworkGuardian) bool {
        // Method 1: Try to create a UDP socket and bind (basic check)
        const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
            return false;
        };
        defer posix.close(sock);
        
        // Method 2: Check if we can read from /sys/class/net/<iface>/operstate
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/operstate", .{
            self.config.interface
        }) catch return false;
        
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            return false;
        };
        defer file.close();
        
        var buf: [32]u8 = undefined;
        const bytes_read = file.read(&buf) catch return false;
        if (bytes_read == 0) return false;
        
        const state = std.mem.trim(u8, buf[0..bytes_read], " \n\t");
        
        // "up" or "unknown" (loopback) are acceptable
        const is_up = std.mem.eql(u8, state, "up") or std.mem.eql(u8, state, "unknown");
        
        return is_up;
    }
    
    /// Watchdog loop (runs in separate thread)
    fn watchdogLoop(self: *NetworkGuardian) void {
        std.debug.print("[Guardian] Watchdog started\n", .{});
        
        self.last_success_time.store(std.time.milliTimestamp(), .seq_cst);
        
        while (self.running.load(.seq_cst)) {
            const now = std.time.milliTimestamp();
            
            if (self.checkNetworkHealth()) {
                // Network is healthy
                self.last_success_time.store(now, .seq_cst);
                self.failure_count.store(0, .seq_cst);
                
                if (self.state.load(.seq_cst) == .network_degraded) {
                    std.debug.print("[Guardian] Network recovered\n", .{});
                    self.state.store(.running, .seq_cst);
                }
            } else {
                // Network check failed
                const fail_count = self.failure_count.fetchAdd(1, .seq_cst);
                
                if (fail_count == 0) {
                    std.debug.print("[Guardian] Network check failed, monitoring...\n", .{});
                    self.state.store(.network_degraded, .seq_cst);
                }
                
                const last_success = self.last_success_time.load(.seq_cst);
                const downtime = now - last_success;
                
                if (downtime >= self.config.failure_timeout_ms) {
                    std.debug.print("[Guardian] Network down for {d}ms, triggering restore!\n", .{downtime});
                    
                    if (self.config.auto_restore) {
                        self.triggerRestore();
                    }
                }
            }
            
            // Sleep until next check
            std.time.sleep(self.config.check_interval_ms * std.time.ns_per_ms);
        }
        
        std.debug.print("[Guardian] Watchdog stopped\n", .{});
    }
    
    /// Trigger network restoration
    fn triggerRestore(self: *NetworkGuardian) void {
        self.state.store(.restoring, .seq_cst);
        
        if (self.snapshot) |*snap| {
            std.debug.print("\n", .{});
            std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
            std.debug.print("║     GUARDIAN: AUTOMATIC NETWORK RESTORATION              ║\n", .{});
            std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
            
            const result = restorer_mod.restoreFromSnapshot(snap);
            
            if (result.success) {
                self.state.store(.restored, .seq_cst);
                self.restore_count += 1;
                self.last_success_time.store(std.time.milliTimestamp(), .seq_cst);
                
                std.debug.print("[Guardian] Restoration successful (count: {d})\n", .{self.restore_count});
            } else {
                self.state.store(.failed, .seq_cst);
                std.debug.print("[Guardian] Restoration FAILED - manual intervention may be needed\n", .{});
            }
        } else {
            std.debug.print("[Guardian] ERROR: No snapshot available for restoration!\n", .{});
            
            // Emergency fallback: just try to detach XDP
            _ = restorer_mod.emergencyXdpDetach(self.config.interface);
        }
    }
    
    /// Start the guardian
    pub fn start(self: *NetworkGuardian) !void {
        if (self.running.load(.seq_cst)) {
            return; // Already running
        }
        
        // Take snapshot if we don't have one
        if (self.snapshot == null) {
            try self.takeSnapshot();
        }
        
        self.running.store(true, .seq_cst);
        self.state.store(.running, .seq_cst);
        
        // Start watchdog in background thread
        self.watchdog_thread = try std.Thread.spawn(.{}, watchdogLoop, .{self});
        
        std.debug.print("[Guardian] Started monitoring interface: {s}\n", .{self.config.interface});
        std.debug.print("[Guardian] Check interval: {d}ms, Timeout: {d}ms\n", .{
            self.config.check_interval_ms,
            self.config.failure_timeout_ms,
        });
    }
    
    /// Stop the guardian
    pub fn stop(self: *NetworkGuardian) void {
        std.debug.print("[Guardian] Stopping...\n", .{});
        
        self.running.store(false, .seq_cst);
        
        if (self.watchdog_thread) |thread| {
            thread.join();
            self.watchdog_thread = null;
        }
        
        self.state.store(.stopped, .seq_cst);
        std.debug.print("[Guardian] Stopped\n", .{});
    }
    
    /// Force an immediate restore
    pub fn forceRestore(self: *NetworkGuardian) void {
        std.debug.print("[Guardian] Force restore requested\n", .{});
        self.triggerRestore();
    }
    
    /// Get current status
    pub fn getStatus(self: *NetworkGuardian) void {
        const state = self.state.load(.seq_cst);
        const failures = self.failure_count.load(.seq_cst);
        
        std.debug.print("\n", .{});
        std.debug.print("Guardian Status:\n", .{});
        std.debug.print("  State: {s}\n", .{@tagName(state)});
        std.debug.print("  Interface: {s}\n", .{self.config.interface});
        std.debug.print("  Failure count: {d}\n", .{failures});
        std.debug.print("  Restore count: {d}\n", .{self.restore_count});
        std.debug.print("  Has snapshot: {s}\n", .{if (self.snapshot != null) "YES" else "NO"});
    }
};

/// Convenience function to create and start a guardian
pub fn createAndStart(allocator: std.mem.Allocator, interface: []const u8) !*NetworkGuardian {
    const guardian = try allocator.create(NetworkGuardian);
    guardian.* = NetworkGuardian.init(allocator, .{
        .interface = interface,
    });
    try guardian.start();
    return guardian;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Network Guardian Test\n", .{});
    std.debug.print("Interface: {s}\n", .{interface});
    std.debug.print("(Testing on loopback is safe)\n", .{});
    
    var guardian = NetworkGuardian.init(allocator, .{
        .interface = interface,
        .check_interval_ms = 1000, // 1 second for testing
        .failure_timeout_ms = 5000, // 5 seconds for testing
        .auto_restore = false, // Don't auto-restore during test
    });
    
    // Take snapshot
    try guardian.takeSnapshot();
    
    // Start monitoring
    try guardian.start();
    
    // Run for a few seconds
    std.debug.print("\nMonitoring for 5 seconds...\n", .{});
    std.time.sleep(5 * std.time.ns_per_s);
    
    // Show status
    guardian.getStatus();
    
    // Stop
    guardian.stop();
    
    std.debug.print("\nGuardian test complete\n", .{});
}
