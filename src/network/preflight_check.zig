//! Pre-Flight Safety Check
//!
//! Before running discovery mode and testing risky tiers like AF_XDP,
//! this module verifies that the network restoration actually WORKS.
//!
//! Process:
//!   1. Take snapshot of current network state
//!   2. Make a SAFE, reversible change (add test IP alias)
//!   3. Verify the change took effect
//!   4. Restore from snapshot
//!   5. Verify restoration worked (test IP is gone)
//!   6. Only if ALL checks pass, allow discovery to proceed
//!
//! If pre-flight fails, discovery is blocked to prevent NIC breakage.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const guardian_mod = @import("guardian/root.zig");
const NetworkSnapshot = guardian_mod.NetworkSnapshot;

/// Pre-flight check result
pub const PreflightResult = struct {
    passed: bool,
    snapshot_ok: bool,
    test_change_ok: bool,
    restore_ok: bool,
    verify_ok: bool,
    error_message: []const u8,
    
    pub fn print(self: *const PreflightResult) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              PRE-FLIGHT SAFETY CHECK                      ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        
        const snapshot_mark = if (self.snapshot_ok) "✓" else "✗";
        const change_mark = if (self.test_change_ok) "✓" else "✗";
        const restore_mark = if (self.restore_ok) "✓" else "✗";
        const verify_mark = if (self.verify_ok) "✓" else "✗";
        
        std.debug.print("║ {s} Snapshot capture:     {s}\n", .{
            snapshot_mark, if (self.snapshot_ok) "OK" else "FAILED"
        });
        std.debug.print("║ {s} Test change applied:  {s}\n", .{
            change_mark, if (self.test_change_ok) "OK" else "FAILED"
        });
        std.debug.print("║ {s} Restoration:          {s}\n", .{
            restore_mark, if (self.restore_ok) "OK" else "FAILED"
        });
        std.debug.print("║ {s} Verification:         {s}\n", .{
            verify_mark, if (self.verify_ok) "OK" else "FAILED"
        });
        
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        
        if (self.passed) {
            std.debug.print("║ ✓ PRE-FLIGHT PASSED - Safe to proceed with discovery    ║\n", .{});
        } else {
            std.debug.print("║ ✗ PRE-FLIGHT FAILED - Discovery blocked for safety      ║\n", .{});
            if (self.error_message.len > 0) {
                std.debug.print("║   Error: {s}\n", .{self.error_message});
            }
        }
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
};

/// Pre-flight checker
pub const PreflightChecker = struct {
    interface: []const u8,
    test_ip: []const u8,
    original_snapshot: ?NetworkSnapshot,
    
    pub fn init(interface: []const u8) PreflightChecker {
        return .{
            .interface = interface,
            // Use a link-local IP that won't conflict with anything
            .test_ip = "169.254.99.99/32",
            .original_snapshot = null,
        };
    }
    
    /// Run the complete pre-flight check
    pub fn run(self: *PreflightChecker) PreflightResult {
        var result = PreflightResult{
            .passed = false,
            .snapshot_ok = false,
            .test_change_ok = false,
            .restore_ok = false,
            .verify_ok = false,
            .error_message = "",
        };
        
        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  PRE-FLIGHT SAFETY CHECK\n", .{});
        std.debug.print("  Interface: {s}\n", .{self.interface});
        std.debug.print("  Test IP: {s}\n", .{self.test_ip});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        
        // Check if running as root
        if (linux.getuid() != 0) {
            result.error_message = "Pre-flight requires root privileges";
            std.debug.print("[Pre-flight] ERROR: Requires root\n", .{});
            result.print();
            return result;
        }
        
        // Step 1: Capture snapshot
        std.debug.print("\n[Step 1/5] Capturing network snapshot...\n", .{});
        self.original_snapshot = guardian_mod.captureSnapshot(self.interface) catch |err| {
            std.debug.print("[Pre-flight] Snapshot failed: {}\n", .{err});
            result.error_message = "Could not capture network snapshot";
            result.print();
            return result;
        };
        result.snapshot_ok = true;
        std.debug.print("           ✓ Snapshot captured\n", .{});
        
        if (self.original_snapshot) |*snap| {
            snap.print();
        }
        
        // Step 2: Add test IP
        std.debug.print("\n[Step 2/5] Adding test IP {s}...\n", .{self.test_ip});
        const add_ok = self.addTestIp();
        if (!add_ok) {
            result.error_message = "Could not add test IP";
            // Try to clean up
            _ = self.removeTestIp();
            result.print();
            return result;
        }
        result.test_change_ok = true;
        std.debug.print("           ✓ Test IP added\n", .{});
        
        // Step 3: Verify test IP exists
        std.debug.print("\n[Step 3/5] Verifying test IP was added...\n", .{});
        const ip_exists = self.verifyTestIpExists();
        if (!ip_exists) {
            result.error_message = "Test IP not found after adding";
            _ = self.removeTestIp();
            result.print();
            return result;
        }
        std.debug.print("           ✓ Test IP verified\n", .{});
        
        // Step 4: Restore from snapshot (should remove test IP)
        std.debug.print("\n[Step 4/5] Restoring from snapshot...\n", .{});
        if (self.original_snapshot) |*snap| {
            const restore_result = guardian_mod.restoreFromSnapshot(snap);
            result.restore_ok = restore_result.success;
            if (!restore_result.success) {
                result.error_message = "Restoration failed";
                // Manual cleanup
                _ = self.removeTestIp();
                result.print();
                return result;
            }
        }
        std.debug.print("           ✓ Snapshot restored\n", .{});
        
        // Step 5: Verify test IP is GONE
        std.debug.print("\n[Step 5/5] Verifying test IP was removed...\n", .{});
        const ip_gone = !self.verifyTestIpExists();
        if (!ip_gone) {
            result.error_message = "Test IP still exists after restoration - UNSAFE";
            result.print();
            return result;
        }
        result.verify_ok = true;
        std.debug.print("           ✓ Test IP removed (restoration works!)\n", .{});
        
        // All checks passed
        result.passed = true;
        result.print();
        
        return result;
    }
    
    /// Add test IP using ip command
    fn addTestIp(self: *PreflightChecker) bool {
        var child = std.process.Child.init(&[_][]const u8{
            "ip", "addr", "add", self.test_ip, "dev", self.interface
        }, std.heap.page_allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        
        _ = child.spawnAndWait() catch return false;
        return true;
    }
    
    /// Remove test IP using ip command
    fn removeTestIp(self: *PreflightChecker) bool {
        var child = std.process.Child.init(&[_][]const u8{
            "ip", "addr", "del", self.test_ip, "dev", self.interface
        }, std.heap.page_allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        
        _ = child.spawnAndWait() catch return false;
        return true;
    }
    
    /// Check if test IP exists on interface
    fn verifyTestIpExists(self: *PreflightChecker) bool {
        // Parse the IP without prefix for checking
        var ip_only: [32]u8 = undefined;
        var ip_len: usize = 0;
        for (self.test_ip) |c| {
            if (c == '/') break;
            ip_only[ip_len] = c;
            ip_len += 1;
        }
        
        // Run: ip addr show <interface> | grep <ip>
        var child = std.process.Child.init(&[_][]const u8{
            "ip", "addr", "show", self.interface
        }, std.heap.page_allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        
        _ = child.spawn() catch return false;
        
        var stdout_reader = child.stdout.?.reader();
        var buf: [4096]u8 = undefined;
        const bytes_read = stdout_reader.readAll(&buf) catch return false;
        
        _ = child.wait() catch return false;
        
        // Check if IP appears in output
        const output = buf[0..bytes_read];
        return std.mem.indexOf(u8, output, ip_only[0..ip_len]) != null;
    }
};

/// Run pre-flight check for an interface
pub fn runPreflightCheck(interface: []const u8) PreflightResult {
    var checker = PreflightChecker.init(interface);
    return checker.run();
}

/// Pre-flight check that must pass before discovery
pub fn verifyReadyForDiscovery(interface: []const u8) !void {
    const result = runPreflightCheck(interface);
    if (!result.passed) {
        return error.PreflightFailed;
    }
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Pre-Flight Safety Check\n", .{});
    std.debug.print("Interface: {s}\n", .{interface});
    
    if (linux.getuid() != 0) {
        std.debug.print("\n⚠️  This check requires root privileges.\n", .{});
        std.debug.print("   Run with: sudo zig run src/network/preflight_check.zig -- {s}\n", .{interface});
        return;
    }
    
    const result = runPreflightCheck(interface);
    
    if (result.passed) {
        std.debug.print("\n✓ Pre-flight passed. Safe to run discovery.\n", .{});
    } else {
        std.debug.print("\n✗ Pre-flight failed. DO NOT run discovery.\n", .{});
    }
}
