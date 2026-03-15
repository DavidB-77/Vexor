//! Network Guardian Module
//!
//! Provides network snapshot, restoration, and watchdog capabilities.
//! This module ensures Vexor can never permanently break network connectivity.
//!
//! Components:
//!   - snapshot: Captures exact network state
//!   - restorer: Restores network to captured state
//!   - guardian: Watchdog that monitors and auto-restores

pub const snapshot = @import("snapshot.zig");
pub const restorer = @import("restorer.zig");
pub const guardian = @import("guardian.zig");

// Re-export main types
pub const NetworkSnapshot = snapshot.NetworkSnapshot;
pub const RestoreResult = restorer.RestoreResult;
pub const NetworkGuardian = guardian.NetworkGuardian;
pub const GuardianConfig = guardian.GuardianConfig;
pub const GuardianState = guardian.GuardianState;

// Re-export functions
pub const captureSnapshot = snapshot.captureSnapshot;
pub const restoreFromSnapshot = restorer.restoreFromSnapshot;
pub const emergencyXdpDetach = restorer.emergencyXdpDetach;
pub const createAndStartGuardian = guardian.createAndStart;

/// Quick helper to protect a network operation
pub fn withNetworkProtection(
    _: std.mem.Allocator,
    interface: []const u8,
    comptime operation: fn () anyerror!void,
) !void {
    // Capture snapshot first
    const snap = try captureSnapshot(interface);
    
    std.debug.print("[Protection] Network snapshot captured\n", .{});
    
    // Try the operation
    operation() catch |err| {
        std.debug.print("[Protection] Operation failed: {}, restoring network...\n", .{err});
        
        const result = restoreFromSnapshot(&snap);
        if (!result.success) {
            std.debug.print("[Protection] WARNING: Restoration incomplete\n", .{});
        }
        
        return err;
    };
}

const std = @import("std");

test "guardian module" {
    _ = snapshot;
    _ = restorer;
    _ = guardian;
}
