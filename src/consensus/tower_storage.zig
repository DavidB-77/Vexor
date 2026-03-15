//! Vexor Tower Storage
//!
//! Persists tower state to disk for crash recovery.
//! Ensures vote safety across restarts.
//!
//! Storage format:
//! - Binary serialized tower state
//! - Versioned for upgrades
//! - Atomic writes with temp file + rename

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const tower = @import("tower.zig");
const Tower = tower.Tower;

/// Tower storage version
pub const TOWER_VERSION: u32 = 1;

/// Magic number for tower files
pub const TOWER_MAGIC: [8]u8 = .{ 'V', 'E', 'X', 'T', 'O', 'W', 'E', 'R' };

/// Tower file header
pub const TowerHeader = struct {
    magic: [8]u8,
    version: u32,
    identity: [32]u8,
    timestamp: i64,
    data_len: u32,
};

/// Saved tower state
pub const SavedTower = struct {
    /// Validator identity
    identity: [32]u8,
    /// Vote account pubkey
    vote_pubkey: [32]u8,
    /// Last voted slot
    last_voted_slot: u64,
    /// Last voted hash
    last_voted_hash: [32]u8,
    /// Root slot
    root: u64,
    /// Lockout stack (slot, confirmation_count pairs)
    lockouts: [31]Lockout,
    lockout_count: u8,
    /// Last timestamp
    last_timestamp: i64,
    /// Stray votes restored
    stray_restored_slot: ?u64,

    pub const Lockout = struct {
        slot: u64,
        confirmation_count: u32,
    };

    /// Serialize to bytes
    pub fn serialize(self: *const SavedTower, writer: anytype) !void {
        try writer.writeAll(&self.identity);
        try writer.writeAll(&self.vote_pubkey);
        try writer.writeInt(u64, self.last_voted_slot, .little);
        try writer.writeAll(&self.last_voted_hash);
        try writer.writeInt(u64, self.root, .little);

        // Lockouts
        try writer.writeByte(self.lockout_count);
        for (0..self.lockout_count) |i| {
            try writer.writeInt(u64, self.lockouts[i].slot, .little);
            try writer.writeInt(u32, self.lockouts[i].confirmation_count, .little);
        }

        try writer.writeInt(i64, self.last_timestamp, .little);

        // Stray restored slot
        if (self.stray_restored_slot) |slot| {
            try writer.writeByte(1);
            try writer.writeInt(u64, slot, .little);
        } else {
            try writer.writeByte(0);
        }
    }

    /// Deserialize from bytes
    pub fn deserialize(reader: anytype) !SavedTower {
        var saved: SavedTower = undefined;

        _ = try reader.readAll(&saved.identity);
        _ = try reader.readAll(&saved.vote_pubkey);
        saved.last_voted_slot = try reader.readInt(u64, .little);
        _ = try reader.readAll(&saved.last_voted_hash);
        saved.root = try reader.readInt(u64, .little);

        // Lockouts
        saved.lockout_count = try reader.readByte();
        if (saved.lockout_count > 31) return error.InvalidData;

        for (0..saved.lockout_count) |i| {
            saved.lockouts[i].slot = try reader.readInt(u64, .little);
            saved.lockouts[i].confirmation_count = try reader.readInt(u32, .little);
        }

        saved.last_timestamp = try reader.readInt(i64, .little);

        // Stray restored slot
        const has_stray = try reader.readByte();
        if (has_stray == 1) {
            saved.stray_restored_slot = try reader.readInt(u64, .little);
        } else {
            saved.stray_restored_slot = null;
        }

        return saved;
    }
};

/// Tower storage manager
pub const TowerStorage = struct {
    allocator: Allocator,
    tower_path: []const u8,
    backup_path: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, base_path: []const u8) !*Self {
        const storage = try allocator.create(Self);

        const tower_path = try std.fmt.allocPrint(allocator, "{s}/tower.bin", .{base_path});
        const backup_path = try std.fmt.allocPrint(allocator, "{s}/tower.bin.bak", .{base_path});

        storage.* = Self{
            .allocator = allocator,
            .tower_path = tower_path,
            .backup_path = backup_path,
        };

        return storage;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.tower_path);
        self.allocator.free(self.backup_path);
        self.allocator.destroy(self);
    }

    /// Save tower state to disk
    pub fn save(self: *Self, saved: *const SavedTower) !void {
        // Create temp file
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.tower_path});
        defer self.allocator.free(temp_path);

        const file = try fs.cwd().createFile(temp_path, .{});
        defer file.close();

        var buf_writer = std.io.bufferedWriter(file.writer());
        const writer = buf_writer.writer();

        // Write header
        try writer.writeAll(&TOWER_MAGIC);
        try writer.writeInt(u32, TOWER_VERSION, .little);
        try writer.writeAll(&saved.identity);
        try writer.writeInt(i64, std.time.timestamp(), .little);

        // Calculate data length (approximate)
        try writer.writeInt(u32, 500, .little); // Placeholder

        // Write tower data
        try saved.serialize(writer);

        try buf_writer.flush();

        // Atomic rename
        // Backup existing file
        fs.cwd().rename(self.tower_path, self.backup_path) catch {};

        // Move temp to final
        try fs.cwd().rename(temp_path, self.tower_path);
    }

    /// Load tower state from disk
    pub fn load(self: *Self) !SavedTower {
        const file = fs.cwd().openFile(self.tower_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Try backup
                return self.loadBackup();
            }
            return err;
        };
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();

        // Read and verify header
        var magic: [8]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &TOWER_MAGIC)) {
            return error.InvalidMagic;
        }

        const version = try reader.readInt(u32, .little);
        if (version != TOWER_VERSION) {
            return error.UnsupportedVersion;
        }

        // Skip identity and timestamp (we'll get from data)
        var skip_buf: [44]u8 = undefined; // 32 + 8 + 4
        _ = try reader.readAll(&skip_buf);

        // Read tower data
        return SavedTower.deserialize(reader);
    }

    fn loadBackup(self: *Self) !SavedTower {
        const file = try fs.cwd().openFile(self.backup_path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();

        // Read and verify header
        var magic: [8]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, &TOWER_MAGIC)) {
            return error.InvalidMagic;
        }

        const version = try reader.readInt(u32, .little);
        if (version != TOWER_VERSION) {
            return error.UnsupportedVersion;
        }

        // Skip header
        var skip_buf: [44]u8 = undefined;
        _ = try reader.readAll(&skip_buf);

        return SavedTower.deserialize(reader);
    }

    /// Check if tower file exists
    pub fn exists(self: *Self) bool {
        fs.cwd().access(self.tower_path, .{}) catch return false;
        return true;
    }

    /// Delete tower files
    pub fn delete(self: *Self) void {
        fs.cwd().deleteFile(self.tower_path) catch {};
        fs.cwd().deleteFile(self.backup_path) catch {};
    }
};

/// Convert Tower to SavedTower
pub fn towerToSaved(t: *const Tower) SavedTower {
    var saved = SavedTower{
        .identity = t.identity,
        .vote_pubkey = t.vote_pubkey,
        .last_voted_slot = t.vote_state.last_voted_slot orelse 0,
        .last_voted_hash = t.vote_state.last_voted_hash,
        .root = t.vote_state.root orelse 0,
        .lockouts = undefined,
        .lockout_count = @intCast(t.vote_state.lockouts.items.len),
        .last_timestamp = 0,
        .stray_restored_slot = null,
    };

    // Copy lockouts
    for (t.vote_state.lockouts.items, 0..) |lockout, i| {
        if (i >= 31) break;
        saved.lockouts[i] = .{
            .slot = lockout.slot,
            .confirmation_count = lockout.confirmation_count,
        };
    }

    return saved;
}

/// Restore Tower from SavedTower
pub fn savedToTower(allocator: Allocator, saved: *const SavedTower) !*Tower {
    const t = try Tower.init(allocator, saved.identity, saved.vote_pubkey);

    // Restore vote state
    t.vote_state.last_voted_slot = if (saved.last_voted_slot > 0) saved.last_voted_slot else null;
    t.vote_state.last_voted_hash = saved.last_voted_hash;
    t.vote_state.root = if (saved.root > 0) saved.root else null;

    // Restore lockouts
    for (0..saved.lockout_count) |i| {
        try t.vote_state.lockouts.append(.{
            .slot = saved.lockouts[i].slot,
            .confirmation_count = saved.lockouts[i].confirmation_count,
        });
    }

    return t;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "saved tower serialization" {
    var saved = SavedTower{
        .identity = [_]u8{0x11} ** 32,
        .vote_pubkey = [_]u8{0x22} ** 32,
        .last_voted_slot = 12345,
        .last_voted_hash = [_]u8{0x33} ** 32,
        .root = 12000,
        .lockouts = undefined,
        .lockout_count = 2,
        .last_timestamp = 1234567890,
        .stray_restored_slot = null,
    };

    saved.lockouts[0] = .{ .slot = 12340, .confirmation_count = 5 };
    saved.lockouts[1] = .{ .slot = 12345, .confirmation_count = 1 };

    // Serialize
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try saved.serialize(fbs.writer());

    // Deserialize
    fbs.pos = 0;
    const restored = try SavedTower.deserialize(fbs.reader());

    try std.testing.expectEqual(saved.last_voted_slot, restored.last_voted_slot);
    try std.testing.expectEqual(saved.root, restored.root);
    try std.testing.expectEqual(saved.lockout_count, restored.lockout_count);
}

