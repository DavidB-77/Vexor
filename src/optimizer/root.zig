//! Vexor Auto-Optimizer Module
//!
//! Automatic system detection and optimization for validator performance:
//! - Hardware detection (CPU, GPU, RAM, NIC)
//! - System tuning (kernel parameters, CPU governor, IRQ affinity)
//! - Performance monitoring
//! - LLM integration placeholder for future AI-assisted optimization
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────┐
//! │                   AUTO-OPTIMIZER                        │
//! ├──────────────┬──────────────┬───────────────────────────┤
//! │   DETECTOR   │    TUNER     │        LLM (future)       │
//! │   ────────   │    ─────     │        ───────────        │
//! │   CPU/GPU    │   sysctl     │     Diagnostics           │
//! │   RAM/NIC    │   IRQ aff    │     Recommendations       │
//! │   Storage    │   Governor   │     Auto-fix              │
//! └──────────────┴──────────────┴───────────────────────────┘

const std = @import("std");
const build_options = @import("build_options");

pub const detector = @import("detector.zig");
pub const tuner = @import("tuner.zig");
pub const monitor = @import("monitor.zig");
pub const metrics = @import("metrics.zig");

// Re-exports
pub const detectCpu = detector.detectCpu;
pub const detectMemory = detector.detectMemory;
pub const detectGpu = detector.detectGpu;
pub const detectNetwork = detector.detectNetwork;

/// Run full auto-optimization suite
pub fn autoOptimize(allocator: std.mem.Allocator) !void {
    std.debug.print("  Detecting hardware...\n", .{});

    // Detect hardware
    const cpu_info = try detector.detectCpu(allocator);
    defer allocator.free(cpu_info.model);
    const mem_info = try detector.detectMemory();

    std.debug.print("    CPU: {s} ({d} cores)\n", .{ cpu_info.model, cpu_info.cores });
    std.debug.print("    RAM: {d:.1} GB\n", .{@as(f64, @floatFromInt(mem_info.total)) / (1024 * 1024 * 1024)});

    // Apply optimizations
    std.debug.print("  Applying optimizations...\n", .{});

    if (try tuner.canModifySystem()) {
        try tuner.optimizeKernel();
        try tuner.optimizeCpuGovernor();
        try tuner.optimizeNetwork();
        std.debug.print("    System optimizations applied ✓\n", .{});
    } else {
        std.debug.print("    Skipping system optimizations (requires root)\n", .{});
    }
}

/// Run interactive optimizer
pub fn runInteractive(allocator: std.mem.Allocator) !void {
    // Display current system status
    std.debug.print("Scanning system...\n\n", .{});

    const cpu = try detector.detectCpu(allocator);
    defer allocator.free(cpu.model);
    const mem = try detector.detectMemory();

    std.debug.print("Hardware Detected:\n", .{});
    std.debug.print("  CPU: {s}\n", .{cpu.model});
    std.debug.print("  Cores: {d} physical, {d} threads\n", .{ cpu.cores, cpu.threads });
    std.debug.print("  Memory: {d:.1} GB total, {d:.1} GB available\n", .{
        @as(f64, @floatFromInt(mem.total)) / (1024 * 1024 * 1024),
        @as(f64, @floatFromInt(mem.available)) / (1024 * 1024 * 1024),
    });

    // Show recommendations
    std.debug.print("\nRecommendations:\n", .{});

    const recommendations = try tuner.getRecommendations(allocator);
    defer {
        for (recommendations) |rec| {
            allocator.free(rec.description);
        }
        allocator.free(recommendations);
    }

    for (recommendations, 1..) |rec, i| {
        std.debug.print("  {d}. [{s}] {s}\n", .{
            i,
            @tagName(rec.priority),
            rec.description,
        });
    }
}

test {
    std.testing.refAllDecls(@This());
}

