//! Vexor Blockstore
//!
//! Storage for shreds, slots, and block metadata.
//! Uses LSM-tree inspired design for efficient writes.

const std = @import("std");
const core = @import("../core/root.zig");

/// Blockstore for shred and slot data
pub const Blockstore = struct {
    allocator: std.mem.Allocator,
    ledger_path: []const u8,
    /// Slot metadata
    slot_meta: std.AutoHashMap(core.Slot, SlotMeta),
    /// Shred data by (slot, index)
    data_shreds: ShredStore,
    /// Coding shreds for repair
    coding_shreds: ShredStore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const bs = try allocator.create(Self);
        bs.* = .{
            .allocator = allocator,
            .ledger_path = path,
            .slot_meta = std.AutoHashMap(core.Slot, SlotMeta).init(allocator),
            .data_shreds = ShredStore.init(allocator),
            .coding_shreds = ShredStore.init(allocator),
        };
        return bs;
    }

    pub fn deinit(self: *Self) void {
        self.slot_meta.deinit();
        self.data_shreds.deinit();
        self.coding_shreds.deinit();
        self.allocator.destroy(self);
    }

    /// Insert a data shred
    pub fn insertDataShred(self: *Self, slot: core.Slot, index: u32, data: []const u8) !void {
        try self.data_shreds.insert(slot, index, data);

        // Update slot metadata
        const meta = try self.getOrCreateSlotMeta(slot);
        meta.received_count += 1;
        meta.last_index = @max(meta.last_index orelse 0, index);
    }

    /// Insert a coding shred
    pub fn insertCodingShred(self: *Self, slot: core.Slot, index: u32, data: []const u8) !void {
        try self.coding_shreds.insert(slot, index, data);
    }

    /// Get a data shred
    pub fn getDataShred(self: *Self, slot: core.Slot, index: u32) ?[]const u8 {
        return self.data_shreds.get(slot, index);
    }

    /// Check if a slot is complete
    pub fn isSlotComplete(self: *Self, slot: core.Slot) bool {
        if (self.slot_meta.get(slot)) |meta| {
            if (meta.last_index) |last| {
                return meta.received_count > last;
            }
        }
        return false;
    }

    /// Get missing shred indices for repair
    pub fn getMissingShreds(self: *Self, slot: core.Slot) ![]u32 {
        _ = self;
        _ = slot;
        // TODO: Calculate missing indices
        return &.{};
    }

    fn getOrCreateSlotMeta(self: *Self, slot: core.Slot) !*SlotMeta {
        const result = try self.slot_meta.getOrPut(slot);
        if (!result.found_existing) {
            result.value_ptr.* = SlotMeta.init(slot);
        }
        return result.value_ptr;
    }

    /// Get slot metadata
    pub fn getSlotMeta(self: *Self, slot: core.Slot) ?SlotMeta {
        return self.slot_meta.get(slot);
    }
};

/// Metadata for a slot
pub const SlotMeta = struct {
    slot: core.Slot,
    /// Parent slot
    parent_slot: ?core.Slot,
    /// Number of shreds received
    received_count: u32,
    /// Index of last shred (if known)
    last_index: ?u32,
    /// Is this slot complete
    is_complete: bool,
    /// Is this slot connected to genesis
    is_connected: bool,
    /// Timestamp when first shred received
    first_received_timestamp: i64,

    pub fn init(slot: core.Slot) SlotMeta {
        return .{
            .slot = slot,
            .parent_slot = null,
            .received_count = 0,
            .last_index = null,
            .is_complete = false,
            .is_connected = false,
            .first_received_timestamp = std.time.timestamp(),
        };
    }
};

/// Storage for shreds indexed by (slot, index)
pub const ShredStore = struct {
    allocator: std.mem.Allocator,
    shreds: std.AutoHashMap(ShredKey, []u8),

    const Self = @This();

    const ShredKey = struct {
        slot: core.Slot,
        index: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .shreds = std.AutoHashMap(ShredKey, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.shreds.valueIterator();
        while (iter.next()) |data| {
            self.allocator.free(data.*);
        }
        self.shreds.deinit();
    }

    pub fn insert(self: *Self, slot: core.Slot, index: u32, data: []const u8) !void {
        const key = ShredKey{ .slot = slot, .index = index };
        const copy = try self.allocator.dupe(u8, data);
        try self.shreds.put(key, copy);
    }

    pub fn get(self: *Self, slot: core.Slot, index: u32) ?[]const u8 {
        const key = ShredKey{ .slot = slot, .index = index };
        return self.shreds.get(key);
    }
};

/// Shred structure
pub const Shred = struct {
    /// Common header
    common: CommonHeader,
    /// Shred-specific data
    payload: []const u8,

    pub const CommonHeader = extern struct {
        signature: core.Signature,
        shred_variant: u8,
        slot: core.Slot,
        index: u32,
        version: u16,
        fec_set_index: u32,
    };

    pub const DATA_SHRED_SIZE: usize = 1228;
    pub const CODING_SHRED_SIZE: usize = 1228;
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "blockstore init" {
    var bs = try Blockstore.init(std.testing.allocator, "/tmp/test_ledger");
    defer bs.deinit();

    try std.testing.expect(!bs.isSlotComplete(100));
}

test "slot meta" {
    const meta = SlotMeta.init(100);
    try std.testing.expectEqual(@as(core.Slot, 100), meta.slot);
    try std.testing.expect(!meta.is_complete);
}

test "shred store" {
    var store = ShredStore.init(std.testing.allocator);
    defer store.deinit();

    const data = "test shred data";
    try store.insert(100, 5, data);

    const retrieved = store.get(100, 5);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualSlices(u8, data, retrieved.?);
}

