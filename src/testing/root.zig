//! Vexor Testing Module
//!
//! Lightweight testing utilities for network and system capabilities.
//! Designed to use minimal resources (< 50 MB RAM).
//!
//! Components:
//!   - network_capability_test: Detects what networking features are available
//!   - traffic_simulator: Simulates Solana-like UDP traffic
//!   - tier_test_harness: Tests each networking tier implementation

const std = @import("std");

pub const network_capability_test = @import("network_capability_test.zig");
pub const traffic_simulator = @import("traffic_simulator.zig");
pub const tier_test_harness = @import("tier_test_harness.zig");

// Re-export commonly used types
pub const CapabilityReport = network_capability_test.CapabilityReport;
pub const NetworkTier = network_capability_test.NetworkTier;
pub const KernelVersion = network_capability_test.KernelVersion;
pub const TrafficSimulator = traffic_simulator.TrafficSimulator;
pub const TierTestHarness = tier_test_harness.TierTestHarness;

/// Detect network capabilities of the current system
pub fn detectNetworkCapabilities() CapabilityReport {
    return network_capability_test.detectCapabilities();
}

/// Run full diagnostics and print results
pub fn runDiagnostics() void {
    network_capability_test.runDiagnostics();
}

/// Run all network tests
pub fn runAllNetworkTests(allocator: std.mem.Allocator) !void {
    // Run capability detection
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║       VEXOR COMPREHENSIVE NETWORK TEST SUITE             ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    
    // Phase 1: Capability Detection
    std.debug.print("\n", .{});
    std.debug.print("Phase 1: Capability Detection\n", .{});
    std.debug.print("─────────────────────────────\n", .{});
    const caps = detectNetworkCapabilities();
    caps.print();
    
    // Phase 2: Traffic Simulation
    std.debug.print("\n", .{});
    std.debug.print("Phase 2: Traffic Simulation\n", .{});
    std.debug.print("────────────────────────────\n", .{});
    try traffic_simulator.runAllTests(allocator);
    
    // Phase 3: Tier Testing
    std.debug.print("\n", .{});
    std.debug.print("Phase 3: Tier-Specific Tests\n", .{});
    std.debug.print("─────────────────────────────\n", .{});
    var harness = TierTestHarness.init(allocator);
    defer harness.deinit();
    try harness.runAllTests();
    
    // Final Summary
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                    ALL TESTS COMPLETE                     ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Vexor networking is ready for development!\n", .{});
    std.debug.print("Recommended tier for this system: {s}\n", .{@tagName(caps.recommended_tier)});
    std.debug.print("\n", .{});
}

/// Entry point for standalone test runner
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try runAllNetworkTests(gpa.allocator());
}

test "testing module" {
    _ = network_capability_test;
    _ = traffic_simulator;
    _ = tier_test_harness;
}
