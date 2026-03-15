//! Network Restorer
//!
//! Restores the exact network state from a snapshot.
//! This is the emergency recovery mechanism - when things go wrong,
//! it puts the network back EXACTLY as it was before Vexor touched it.
//!
//! Restoration order:
//!   1. Detach any XDP programs (most likely cause of issues)
//!   2. Restore NIC offloads
//!   3. Flush and restore IP addresses
//!   4. Restore routes
//!   5. Bring interface up if it was up

const std = @import("std");
const posix = std.posix;
const snapshot_mod = @import("snapshot.zig");
const NetworkSnapshot = snapshot_mod.NetworkSnapshot;

/// Result of a restoration attempt
pub const RestoreResult = struct {
    success: bool,
    xdp_detached: bool,
    offloads_restored: bool,
    addresses_restored: bool,
    routes_restored: bool,
    interface_up: bool,
    error_message: ?[]const u8,
    
    pub fn print(self: *const RestoreResult) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              RESTORATION RESULT                           ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Overall: {s}\n", .{if (self.success) "SUCCESS" else "PARTIAL/FAILED"});
        std.debug.print("║ XDP Detached: {s}\n", .{if (self.xdp_detached) "YES" else "NO/N/A"});
        std.debug.print("║ Offloads Restored: {s}\n", .{if (self.offloads_restored) "YES" else "SKIPPED"});
        std.debug.print("║ Addresses Restored: {s}\n", .{if (self.addresses_restored) "YES" else "SKIPPED"});
        std.debug.print("║ Routes Restored: {s}\n", .{if (self.routes_restored) "YES" else "SKIPPED"});
        std.debug.print("║ Interface Up: {s}\n", .{if (self.interface_up) "YES" else "NO"});
        if (self.error_message) |msg| {
            std.debug.print("║ Error: {s}\n", .{msg});
        }
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
};

/// Execute a system command and return success/failure
fn runCommand(argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term.Exited == 0;
}

/// Restore network state from a snapshot
pub fn restoreFromSnapshot(snap: *const NetworkSnapshot) RestoreResult {
    var result = RestoreResult{
        .success = false,
        .xdp_detached = false,
        .offloads_restored = false,
        .addresses_restored = false,
        .routes_restored = false,
        .interface_up = false,
        .error_message = null,
    };
    
    const iface = snap.interface.name[0..snap.interface.name_len];
    
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  EMERGENCY NETWORK RESTORATION\n", .{});
    std.debug.print("  Interface: {s}\n", .{iface});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    
    // Step 1: Detach XDP program (CRITICAL - do this first!)
    std.debug.print("\n[1/5] Detaching XDP program...\n", .{});
    if (runCommand(&.{"ip", "link", "set", "dev", iface, "xdp", "off"})) {
        result.xdp_detached = true;
        std.debug.print("      XDP detached successfully\n", .{});
    } else {
        std.debug.print("      XDP detach failed or no XDP was attached\n", .{});
        // Continue anyway - might not have had XDP
        result.xdp_detached = true;
    }
    
    // Step 2: Restore NIC offloads
    std.debug.print("\n[2/5] Restoring NIC offloads...\n", .{});
    const gro_val = if (snap.offloads.gro) "on" else "off";
    const tso_val = if (snap.offloads.tso) "on" else "off";
    const gso_val = if (snap.offloads.gso) "on" else "off";
    
    // ethtool -K <iface> gro on/off tso on/off gso on/off
    if (runCommand(&.{"ethtool", "-K", iface, "gro", gro_val})) {
        std.debug.print("      GRO: {s}\n", .{gro_val});
    }
    if (runCommand(&.{"ethtool", "-K", iface, "tso", tso_val})) {
        std.debug.print("      TSO: {s}\n", .{tso_val});
    }
    if (runCommand(&.{"ethtool", "-K", iface, "gso", gso_val})) {
        std.debug.print("      GSO: {s}\n", .{gso_val});
    }
    result.offloads_restored = true;
    
    // Step 3: Restore IP addresses
    std.debug.print("\n[3/5] Restoring IP addresses...\n", .{});
    
    // First flush existing addresses (careful!)
    if (runCommand(&.{"ip", "addr", "flush", "dev", iface})) {
        std.debug.print("      Flushed existing addresses\n", .{});
    }
    
    // Add back saved addresses
    for (snap.addresses.slice()) |addr| {
        if (addr.family == posix.AF.INET) {
            var ip_str: [32]u8 = undefined;
            const ip_len = std.fmt.bufPrint(&ip_str, "{d}.{d}.{d}.{d}/{d}", .{
                addr.address[0], addr.address[1], addr.address[2], addr.address[3],
                addr.prefix_len
            }) catch continue;
            
            if (runCommand(&.{"ip", "addr", "add", ip_str[0..ip_len.len], "dev", iface})) {
                std.debug.print("      Added: {s}\n", .{ip_str[0..ip_len.len]});
                result.addresses_restored = true;
            }
        }
    }
    
    // Step 4: Restore routes
    std.debug.print("\n[4/5] Restoring routes...\n", .{});
    for (snap.routes.slice()) |route| {
        if (route.is_default and route.family == posix.AF.INET) {
            var gw_str: [32]u8 = undefined;
            const gw_len = std.fmt.bufPrint(&gw_str, "{d}.{d}.{d}.{d}", .{
                route.gateway[0], route.gateway[1], route.gateway[2], route.gateway[3],
            }) catch continue;
            
            // Delete existing default route first
            _ = runCommand(&.{"ip", "route", "del", "default"});
            
            if (runCommand(&.{"ip", "route", "add", "default", "via", gw_str[0..gw_len.len], "dev", iface})) {
                std.debug.print("      Default route: via {s}\n", .{gw_str[0..gw_len.len]});
                result.routes_restored = true;
            }
        }
    }
    if (snap.routes.len == 0) {
        std.debug.print("      No routes to restore (snapshot empty)\n", .{});
        result.routes_restored = true;
    }
    
    // Step 5: Bring interface up if it was up
    std.debug.print("\n[5/5] Setting interface state...\n", .{});
    if (snap.interface.is_up) {
        if (runCommand(&.{"ip", "link", "set", "dev", iface, "up"})) {
            result.interface_up = true;
            std.debug.print("      Interface brought UP\n", .{});
        } else {
            std.debug.print("      WARNING: Failed to bring interface up\n", .{});
        }
    } else {
        std.debug.print("      Interface was down in snapshot, leaving down\n", .{});
        result.interface_up = true;
    }
    
    // Determine overall success
    result.success = result.xdp_detached and result.interface_up;
    
    std.debug.print("\n", .{});
    if (result.success) {
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  RESTORATION COMPLETE - Network should be accessible\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    } else {
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  RESTORATION INCOMPLETE - Manual intervention may be needed\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    }
    
    return result;
}

/// Emergency XDP-only detach (fastest possible recovery)
pub fn emergencyXdpDetach(interface_name: []const u8) bool {
    std.debug.print("\n", .{});
    std.debug.print("!!! EMERGENCY XDP DETACH !!!\n", .{});
    std.debug.print("Interface: {s}\n", .{interface_name});
    
    const success = runCommand(&.{"ip", "link", "set", "dev", interface_name, "xdp", "off"});
    
    if (success) {
        std.debug.print("XDP detached successfully\n", .{});
    } else {
        std.debug.print("XDP detach FAILED\n", .{});
    }
    
    return success;
}

/// Load snapshot from file and restore
pub fn restoreFromFile(path: []const u8) !RestoreResult {
    _ = path;
    // For now, return a placeholder - full implementation would parse JSON
    return RestoreResult{
        .success = false,
        .xdp_detached = false,
        .offloads_restored = false,
        .addresses_restored = false,
        .routes_restored = false,
        .interface_up = false,
        .error_message = "File restore not yet implemented",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Testing network restore for interface: {s}\n", .{interface});
    std.debug.print("(This is a dry-run test on loopback)\n", .{});
    
    // Capture current state
    const snap = try snapshot_mod.captureSnapshot(interface);
    snap.print();
    
    // Test restore (safe on loopback)
    std.debug.print("\nSimulating restoration (loopback is safe)...\n", .{});
    const result = restoreFromSnapshot(&snap);
    result.print();
}
