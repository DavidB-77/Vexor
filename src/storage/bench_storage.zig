//! Storage microbench harness (guarded by env var).

const std = @import("std");
const storage = @import("root.zig");

const BenchResult = struct {
    puts: usize,
    gets: usize,
    put_ns: u64,
    get_ns: u64,
};

fn runVexStoreBench(allocator: std.mem.Allocator, entries: usize, value_size: usize) !BenchResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try storage.VexStore.initWithDir(allocator, tmp.dir, null);
    defer store.deinit();

    var key: [32]u8 = [_]u8{0} ** 32;
    const value = try allocator.alloc(u8, value_size);
    defer allocator.free(value);
    @memset(value, 0x5a);

    const start_put = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        std.mem.writeInt(u32, key[0..4], @intCast(i), .little);
        try store.put(key, value);
    }
    const put_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_put));

    const start_get = std.time.nanoTimestamp();
    i = 0;
    while (i < entries) : (i += 1) {
        std.mem.writeInt(u32, key[0..4], @intCast(i), .little);
        const got = try store.get(key);
        if (got) |buf| {
            allocator.free(buf);
        } else {
            return error.MissingValue;
        }
    }
    const get_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_get));

    return .{
        .puts = entries,
        .gets = entries,
        .put_ns = put_ns,
        .get_ns = get_ns,
    };
}

fn runSpeedbBench(allocator: std.mem.Allocator, entries: usize, value_size: usize) !BenchResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try storage.SpeedbStore.initWithDir(allocator, tmp.dir);
    defer store.deinit();

    var key_buf: [32]u8 = [_]u8{0} ** 32;
    const value = try allocator.alloc(u8, value_size);
    defer allocator.free(value);
    @memset(value, 0x5a);

    const start_put = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < entries) : (i += 1) {
        std.mem.writeInt(u32, key_buf[0..4], @intCast(i), .little);
        try store.put(key_buf[0..4], value);
    }
    const put_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_put));

    const start_get = std.time.nanoTimestamp();
    i = 0;
    while (i < entries) : (i += 1) {
        std.mem.writeInt(u32, key_buf[0..4], @intCast(i), .little);
        const got = try store.get(allocator, key_buf[0..4]);
        if (got) |buf| {
            allocator.free(buf);
        } else {
            return error.MissingValue;
        }
    }
    const get_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_get));

    return .{
        .puts = entries,
        .gets = entries,
        .put_ns = put_ns,
        .get_ns = get_ns,
    };
}

test "vexstore microbench" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(allocator, "VEXSTORE_BENCH") catch return;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;

    const result = try runVexStoreBench(allocator, 10_000, 512);
    std.debug.print("[VexStoreBench] puts={d} gets={d} put_ms={d} get_ms={d}\n", .{
        result.puts,
        result.gets,
        result.put_ns / std.time.ns_per_ms,
        result.get_ns / std.time.ns_per_ms,
    });
}

test "speedb microbench" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(allocator, "SPEEDB_BENCH") catch return;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;

    const result = try runSpeedbBench(allocator, 10_000, 512);
    std.debug.print("[SpeedbBench] puts={d} gets={d} put_ms={d} get_ms={d}\n", .{
        result.puts,
        result.gets,
        result.put_ns / std.time.ns_per_ms,
        result.get_ns / std.time.ns_per_ms,
    });
}
