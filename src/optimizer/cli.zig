//! Vexor Optimizer CLI
//!
//! Command-line interface for the system optimizer.

const std = @import("std");
const root = @import("root.zig");
const detector = @import("detector.zig");
const tuner = @import("tuner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "info")) {
        try showSystemInfo(allocator);
    } else if (std.mem.eql(u8, command, "optimize")) {
        try runOptimization(allocator);
    } else if (std.mem.eql(u8, command, "recommend")) {
        try showRecommendations(allocator);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\
        \\Vexor System Optimizer
        \\
        \\Usage: vexor-optimize <command>
        \\
        \\Commands:
        \\  info       Show system information
        \\  recommend  Show optimization recommendations
        \\  optimize   Apply optimizations (requires root)
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn showSystemInfo(allocator: std.mem.Allocator) !void {
    std.debug.print("\n═══════════════════════════════════════════\n", .{});
    std.debug.print("         Vexor System Information\n", .{});
    std.debug.print("═══════════════════════════════════════════\n\n", .{});

    const cpu = try detector.detectCpu(allocator);
    defer allocator.free(cpu.model);
    const mem = try detector.detectMemory();

    std.debug.print("CPU:\n", .{});
    std.debug.print("  Model: {s}\n", .{cpu.model});
    std.debug.print("  Vendor: {s}\n", .{@tagName(cpu.vendor)});
    std.debug.print("  Cores: {d}\n", .{cpu.cores});
    std.debug.print("  Threads: {d}\n", .{cpu.threads});
    std.debug.print("  Features:\n", .{});
    std.debug.print("    AVX2: {}\n", .{cpu.features.avx2});
    std.debug.print("    AVX-512: {}\n", .{cpu.features.avx512});
    std.debug.print("    SHA-NI: {}\n", .{cpu.features.sha_ni});
    std.debug.print("    AES-NI: {}\n", .{cpu.features.aes_ni});

    std.debug.print("\nMemory:\n", .{});
    std.debug.print("  Total: {d:.1} GB\n", .{@as(f64, @floatFromInt(mem.total)) / (1024 * 1024 * 1024)});
    std.debug.print("  Available: {d:.1} GB\n", .{@as(f64, @floatFromInt(mem.available)) / (1024 * 1024 * 1024)});
    std.debug.print("  Swap: {d:.1} GB\n", .{@as(f64, @floatFromInt(mem.swap_total)) / (1024 * 1024 * 1024)});

    std.debug.print("\n", .{});
}

fn showRecommendations(allocator: std.mem.Allocator) !void {
    std.debug.print("\n═══════════════════════════════════════════\n", .{});
    std.debug.print("      Optimization Recommendations\n", .{});
    std.debug.print("═══════════════════════════════════════════\n\n", .{});

    const recs = try tuner.getRecommendations(allocator);
    defer {
        for (recs) |rec| {
            allocator.free(rec.description);
        }
        allocator.free(recs);
    }

    if (recs.len == 0) {
        std.debug.print("✓ No optimization recommendations - system looks good!\n\n", .{});
        return;
    }

    for (recs, 1..) |rec, i| {
        const priority_symbol = switch (rec.priority) {
            .critical => "🔴",
            .high => "🟠",
            .medium => "🟡",
            .low => "🟢",
        };
        std.debug.print("{d}. {s} [{s}] {s}\n", .{
            i,
            priority_symbol,
            @tagName(rec.category),
            rec.description,
        });
    }
    std.debug.print("\n", .{});
}

fn runOptimization(allocator: std.mem.Allocator) !void {
    std.debug.print("\n═══════════════════════════════════════════\n", .{});
    std.debug.print("         Running Optimizations\n", .{});
    std.debug.print("═══════════════════════════════════════════\n\n", .{});

    if (!try tuner.canModifySystem()) {
        std.debug.print("❌ Error: This command requires root privileges.\n", .{});
        std.debug.print("   Run with: sudo vexor-optimize optimize\n\n", .{});
        return;
    }

    std.debug.print("Applying kernel parameters...\n", .{});
    try tuner.optimizeKernel();
    std.debug.print("  ✓ Kernel parameters optimized\n", .{});

    std.debug.print("Setting CPU governor to performance...\n", .{});
    try tuner.optimizeCpuGovernor();
    std.debug.print("  ✓ CPU governor set\n", .{});

    std.debug.print("Optimizing network settings...\n", .{});
    try tuner.optimizeNetwork();
    std.debug.print("  ✓ Network optimized\n", .{});

    std.debug.print("\n✅ All optimizations applied successfully!\n\n", .{});

    // Show final recommendations
    try showRecommendations(allocator);
}

test "cli compiles" {
    // Just verify it compiles
}

