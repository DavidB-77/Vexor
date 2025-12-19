//! Vexor Benchmarks
//!
//! Performance benchmarks for critical validator components.

const std = @import("std");
const core = @import("core/root.zig");
const crypto = @import("crypto/root.zig");
const network = @import("network/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    printHeader();

    try benchEd25519(allocator);
    try benchSha256();
    try benchPacketProcessing(allocator);
    try benchMemoryAllocation(allocator);

    printFooter();
}

fn printHeader() void {
    std.debug.print(
        \\
        \\╔═══════════════════════════════════════════════════════════╗
        \\║                   VEXOR BENCHMARKS                        ║
        \\╚═══════════════════════════════════════════════════════════╝
        \\
        \\
    , .{});
}

fn printFooter() void {
    std.debug.print(
        \\
        \\═══════════════════════════════════════════════════════════
        \\                    Benchmarks complete
        \\═══════════════════════════════════════════════════════════
        \\
        \\
    , .{});
}

fn benchEd25519(allocator: std.mem.Allocator) !void {
    std.debug.print("📊 Ed25519 Signature Verification\n", .{});
    std.debug.print("─────────────────────────────────\n", .{});

    const iterations = 10_000;
    const keypair = crypto.ed25519.generateKeypair();
    const message = "Hello, Vexor benchmark!";
    const signature = crypto.ed25519.sign(keypair.secret, message);

    // Warm up
    for (0..100) |_| {
        _ = crypto.ed25519.verify(&signature, &keypair.public, message);
    }

    // Benchmark single verification
    const start_single = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = crypto.ed25519.verify(&signature, &keypair.public, message);
    }
    const end_single = std.time.nanoTimestamp();
    const single_ns = @divTrunc(end_single - start_single, iterations);
    const single_per_sec = 1_000_000_000 / @as(u64, @intCast(single_ns));

    std.debug.print("  Single verification:\n", .{});
    std.debug.print("    Time: {d} ns/op\n", .{single_ns});
    std.debug.print("    Rate: {d} verifications/sec\n", .{single_per_sec});

    // Benchmark batch verification
    const batch_size = 64;
    var signatures: [batch_size]core.Signature = undefined;
    var pubkeys: [batch_size]core.Pubkey = undefined;
    var messages: [batch_size][]const u8 = undefined;

    for (0..batch_size) |i| {
        signatures[i] = signature;
        pubkeys[i] = keypair.public;
        messages[i] = message;
    }

    const start_batch = std.time.nanoTimestamp();
    for (0..iterations / batch_size) |_| {
        const result = try crypto.ed25519.batchVerify(allocator, &signatures, &pubkeys, &messages);
        allocator.free(result.valid_bitmap);
    }
    const end_batch = std.time.nanoTimestamp();
    const batch_ns = @divTrunc(end_batch - start_batch, iterations / batch_size);
    const batch_per_sec = @as(u64, @intCast(batch_size)) * 1_000_000_000 / @as(u64, @intCast(batch_ns));

    std.debug.print("  Batch verification ({d}):\n", .{batch_size});
    std.debug.print("    Time: {d} ns/batch\n", .{batch_ns});
    std.debug.print("    Rate: {d} verifications/sec\n", .{batch_per_sec});
    std.debug.print("\n", .{});
}

fn benchSha256() !void {
    std.debug.print("📊 SHA-256 Hashing\n", .{});
    std.debug.print("──────────────────\n", .{});

    const iterations = 100_000;
    const data = "Hello, Vexor benchmark! This is a test message for hashing.";

    // Warm up
    for (0..1000) |_| {
        _ = crypto.sha256.hash(data);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = crypto.sha256.hash(data);
    }
    const end = std.time.nanoTimestamp();

    const ns_per_op = @divTrunc(end - start, iterations);
    const ops_per_sec = 1_000_000_000 / @as(u64, @intCast(ns_per_op));
    const throughput_mbps = @as(f64, @floatFromInt(data.len * ops_per_sec)) / (1024 * 1024);

    std.debug.print("  Data size: {d} bytes\n", .{data.len});
    std.debug.print("  Time: {d} ns/op\n", .{ns_per_op});
    std.debug.print("  Rate: {d} hashes/sec\n", .{ops_per_sec});
    std.debug.print("  Throughput: {d:.1} MB/s\n", .{throughput_mbps});
    std.debug.print("\n", .{});
}

fn benchPacketProcessing(allocator: std.mem.Allocator) !void {
    std.debug.print("📊 Packet Processing\n", .{});
    std.debug.print("────────────────────\n", .{});

    const iterations = 100_000;
    const batch_size = 64;

    // Create packet batch
    var batch = try network.packet.PacketBatch.init(allocator, batch_size);
    defer batch.deinit();

    // Fill with test data
    for (0..batch_size) |_| {
        if (batch.push()) |pkt| {
            pkt.len = 1000;
            @memset(pkt.data[0..1000], 0xAB);
        }
    }

    // Benchmark batch reset/refill
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        batch.clear();
        for (0..batch_size) |_| {
            _ = batch.push();
        }
    }
    const end = std.time.nanoTimestamp();

    const ns_per_batch = @divTrunc(end - start, iterations);
    const packets_per_sec = @as(u64, @intCast(batch_size)) * 1_000_000_000 / @as(u64, @intCast(ns_per_batch));

    std.debug.print("  Batch size: {d} packets\n", .{batch_size});
    std.debug.print("  Time: {d} ns/batch\n", .{ns_per_batch});
    std.debug.print("  Rate: {d} packets/sec\n", .{packets_per_sec});
    std.debug.print("\n", .{});
}

fn benchMemoryAllocation(allocator: std.mem.Allocator) !void {
    std.debug.print("📊 Memory Allocation\n", .{});
    std.debug.print("────────────────────\n", .{});

    const iterations = 100_000;

    // Arena allocator benchmark
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try arena.allocator().alloc(u8, 1024);
        }
        const end = std.time.nanoTimestamp();

        const ns_per_op = @divTrunc(end - start, iterations);
        std.debug.print("  Arena (1KB allocs): {d} ns/op\n", .{ns_per_op});
    }

    // General allocator benchmark
    {
        var ptrs: [1000]*[1024]u8 = undefined;
        var idx: usize = 0;

        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            ptrs[idx] = try allocator.create([1024]u8);
            idx = (idx + 1) % 1000;
            if (idx == 0) {
                for (ptrs) |ptr| {
                    allocator.destroy(ptr);
                }
            }
        }
        const end = std.time.nanoTimestamp();

        // Cleanup
        for (ptrs[0..idx]) |ptr| {
            allocator.destroy(ptr);
        }

        const ns_per_op = @divTrunc(end - start, iterations);
        std.debug.print("  GPA (1KB allocs): {d} ns/op\n", .{ns_per_op});
    }

    std.debug.print("\n", .{});
}

test "benchmarks compile" {
    // Just verify benchmarks compile
}

