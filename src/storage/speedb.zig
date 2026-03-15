//! Speedb drop-in adapter (via rocksdb-zig bindings).

const std = @import("std");
const rocksdb = @import("rocksdb_zig");

pub const SpeedbStore = struct {
    allocator: std.mem.Allocator,
    db: rocksdb.DB,
    cf_list: []const rocksdb.ColumnFamily,
    default_cf: rocksdb.ColumnFamilyHandle,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        return initWithPath(allocator, path);
    }

    pub fn initWithDir(allocator: std.mem.Allocator, dir: std.fs.Dir) !*Self {
        const path = try dir.realpathAlloc(allocator, ".");
        defer allocator.free(path);
        return initWithPath(allocator, path);
    }

    fn initWithPath(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const store = try allocator.create(Self);
        errdefer allocator.destroy(store);

        var err_str: ?rocksdb.Data = null;
        const opts = rocksdb.DBOptions{
            .create_if_missing = true,
        };
        const result = rocksdb.DB.open(
            allocator,
            path,
            opts,
            null,
            false,
            &err_str,
        ) catch |err| {
            return err;
        };
        const db = result[0];
        const cf_list = result[1];
        const default_cf = if (cf_list.len > 0) cf_list[0].handle else return error.MissingColumnFamily;

        store.* = .{
            .allocator = allocator,
            .db = db,
            .cf_list = cf_list,
            .default_cf = default_cf,
        };

        return store;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cf_list);
        self.db.deinit();
        self.allocator.destroy(self);
    }

    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        var err_str: ?rocksdb.Data = null;
        try self.db.put(self.default_cf, key, value, &err_str);
    }

    pub fn get(self: *Self, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        var err_str: ?rocksdb.Data = null;
        const value = try self.db.get(self.default_cf, key, &err_str) orelse return null;
        defer value.deinit();
        const out = try allocator.dupe(u8, value.data);
        return out;
    }

    pub fn delete(self: *Self, key: []const u8) !void {
        var err_str: ?rocksdb.Data = null;
        try self.db.delete(self.default_cf, key, &err_str);
    }
};

test "speedb store put/get/delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path, "db" });
    defer std.testing.allocator.free(db_path);

    var store = try SpeedbStore.initWithPath(std.testing.allocator, db_path);
    defer store.deinit();

    try store.put("k1", "v1");
    const got = try store.get(std.testing.allocator, "k1");
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, "v1", got.?);

    try store.delete("k1");
    const missing = try store.get(std.testing.allocator, "k1");
    try std.testing.expect(missing == null);
}
