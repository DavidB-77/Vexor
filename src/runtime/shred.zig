//! Vexor Shred Module
//!
//! Shreds are the fundamental unit of data propagation in Solana.
//! A slot is divided into shreds which are individually erasure-coded.
//!
//! Two types:
//! - Data shreds: Contain actual block data (entries/transactions)
//! - Coding shreds: Reed-Solomon erasure codes for recovery
//!
//! Shred format (1228 bytes payload):
//! [signature: 64] [common_header: 83] [payload: ~1081]

const std = @import("std");
const core = @import("../core/root.zig");
const fec = @import("fec_resolver.zig");
const crypto = @import("../crypto/root.zig");

/// Maximum shred payload size
pub const SHRED_PAYLOAD_SIZE: usize = 1228;

/// Data shred payload size after headers
pub const DATA_SHRED_PAYLOAD: usize = 1051;

/// Shred header size
pub const SHRED_HEADER_SIZE: usize = 88;

/// Legacy shred version
pub const LEGACY_SHRED_VERSION: u16 = 0x8000;

/// Shred type discriminator
pub const ShredType = enum(u8) {
    data = 0b1010_0101,
    code = 0b0101_1010,

    pub fn isData(self: ShredType) bool {
        return self == .data;
    }

    pub fn isCode(self: ShredType) bool {
        return self == .code;
    }
};

/// Common shred header (present in all shreds)
pub const ShredCommonHeader = struct {
    /// Signature over the shred
    signature: core.Signature,

    /// Shred type variant
    shred_type: ShredType,

    /// Slot this shred belongs to
    slot: core.Slot,

    /// Index of this shred within the slot
    index: u32,

    /// Shred version (compatibility)
    version: u16,

    /// Forward error correction set index
    fec_set_index: u32,

    pub fn fromBytes(data: []const u8) !ShredCommonHeader {
        if (data.len < SHRED_HEADER_SIZE) return error.ShredTooShort;

        // Initialize to zero first to avoid undefined memory
        var sig: core.Signature = .{ .data = [_]u8{0} ** 64 };
        @memcpy(&sig.data, data[0..64]);

        // Parse shred type with validation
        // Modern Solana has multiple shred variants (legacy + merkle)
        const shred_type_raw = data[64];
        const shred_type: ShredType = switch (shred_type_raw) {
            // Legacy shreds
            0b1010_0101 => .data,  // 0xA5 - Legacy data
            0b0101_1010 => .code,  // 0x5A - Legacy code
            // Merkle shreds (data variants: 0x80-0xBF range)
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
            0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
            0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa6, 0xa7, // skip 0xa5 (legacy)
            0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf,
            0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
            0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf => .data,
            // Merkle shreds (code variants: 0x60-0x6F, 0x70-0x7F with chained bit)
            0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
            0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f,
            0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
            0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f => .code,
            else => {
                // Log unrecognized type for debugging
                std.debug.print("[SHRED] Unknown type byte: 0x{x:0>2}\n", .{shred_type_raw});
                return error.InvalidShredType;
            },
        };

        return ShredCommonHeader{
            .signature = sig,
            .shred_type = shred_type,
            .slot = std.mem.readInt(u64, data[65..73], .little),
            .index = std.mem.readInt(u32, data[73..77], .little),
            .version = std.mem.readInt(u16, data[77..79], .little),
            .fec_set_index = std.mem.readInt(u32, data[79..83], .little),
        };
    }
};

/// Data shred specific header
pub const DataShredHeader = struct {
    /// Parent slot offset
    parent_offset: u16,

    /// Flags (last in slot, etc.)
    flags: DataShredFlags,

    /// Size of data in this shred
    size: u16,

    pub const DataShredFlags = packed struct {
        /// Last shred in the FEC set
        last_in_fec_set: bool = false,
        /// Last shred in the slot
        last_in_slot: bool = false,
        /// Reference tick
        reference_tick: u6 = 0,
    };
};

/// Coding shred specific header
pub const CodingShredHeader = struct {
    /// Number of data shreds in FEC set
    num_data_shreds: u16,

    /// Number of coding shreds in FEC set
    num_coding_shreds: u16,

    /// Position in the FEC set
    position: u16,
};

/// Parsed shred
pub const Shred = struct {
    /// Common header
    common: ShredCommonHeader,

    /// Type-specific data
    variant: union(ShredType) {
        data: DataShred,
        code: CodingShred,
    },

    /// Raw payload bytes
    payload: []const u8,

    pub fn slot(self: *const Shred) core.Slot {
        return self.common.slot;
    }

    pub fn index(self: *const Shred) u32 {
        return self.common.index;
    }

    pub fn isData(self: *const Shred) bool {
        return self.common.shred_type.isData();
    }

    pub fn isCode(self: *const Shred) bool {
        return self.common.shred_type.isCode();
    }

    pub fn isLastInSlot(self: *const Shred) bool {
        if (self.isData()) {
            return self.variant.data.header.flags.last_in_slot;
        }
        return false;
    }

    /// Verify the shred signature
    pub fn verifySignature(self: *const Shred, leader_pubkey: *const core.Pubkey) bool {
        // The signature covers everything after the signature itself
        const signed_data = self.payload[64..];
        return crypto.verify(&self.common.signature, leader_pubkey, signed_data);
    }

    /// Get raw shred data for FEC processing
    pub fn rawData(self: *const Shred) []const u8 {
        return self.payload;
    }
};

/// Data shred content
pub const DataShred = struct {
    header: DataShredHeader,
    data: []const u8,

    pub fn parentSlot(self: *const DataShred, slot: core.Slot) core.Slot {
        if (self.header.parent_offset == 0) return slot;
        return slot - @as(core.Slot, self.header.parent_offset);
    }
};

/// Coding shred content
pub const CodingShred = struct {
    header: CodingShredHeader,
    data: []const u8,
};

/// Parse a shred from raw bytes
pub fn parseShred(data: []const u8) !Shred {
    const common = try ShredCommonHeader.fromBytes(data);

    var shred = Shred{
        .common = common,
        .variant = undefined,
        .payload = data,
    };

    switch (common.shred_type) {
        .data => {
            if (data.len < SHRED_HEADER_SIZE + 5) return error.ShredTooShort;

            const header = DataShredHeader{
                .parent_offset = std.mem.readInt(u16, data[83..85], .little),
                .flags = @bitCast(data[85]),
                .size = std.mem.readInt(u16, data[86..88], .little),
            };

            const data_start: usize = 88;
            const data_end = @min(data_start + header.size, data.len);

            shred.variant = .{
                .data = .{
                    .header = header,
                    .data = data[data_start..data_end],
                },
            };
        },
        .code => {
            if (data.len < SHRED_HEADER_SIZE + 6) return error.ShredTooShort;

            shred.variant = .{
                .code = .{
                    .header = .{
                        .num_data_shreds = std.mem.readInt(u16, data[83..85], .little),
                        .num_coding_shreds = std.mem.readInt(u16, data[85..87], .little),
                        .position = std.mem.readInt(u16, data[87..89], .little),
                    },
                    .data = data[89..],
                },
            };
        },
    }

    return shred;
}

/// Shred assembler - reconstructs entries from shreds
/// Now includes FEC recovery for missing shreds
/// Reference: Firedancer src/disco/shred/fd_fec_resolver.c
pub const ShredAssembler = struct {
    allocator: std.mem.Allocator,

    /// Shreds by slot and index
    slots: std.AutoHashMap(core.Slot, SlotShreds),

    /// FEC resolver for recovering missing shreds
    fec_resolver: fec.FecResolver,

    const Self = @This();

    pub const SlotShreds = struct {
        data_shreds: std.AutoHashMap(u32, Shred),
        coding_shreds: std.AutoHashMap(u32, Shred),
        highest_data_index: u32,
        is_complete: bool,

        pub fn init(allocator: std.mem.Allocator) SlotShreds {
            return .{
                .data_shreds = std.AutoHashMap(u32, Shred).init(allocator),
                .coding_shreds = std.AutoHashMap(u32, Shred).init(allocator),
                .highest_data_index = 0,
                .is_complete = false,
            };
        }

        pub fn deinit(self: *SlotShreds) void {
            self.data_shreds.deinit();
            self.coding_shreds.deinit();
        }

        /// Check if all data shreds received
        pub fn hasAllDataShreds(self: *const SlotShreds) bool {
            if (!self.is_complete) return false;
            return self.data_shreds.count() == self.highest_data_index + 1;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self.initWithShredVersion(allocator, 0);
    }

    pub fn initWithShredVersion(allocator: std.mem.Allocator, shred_version: u16) Self {
        return .{
            .allocator = allocator,
            .slots = std.AutoHashMap(core.Slot, SlotShreds).init(allocator),
            .fec_resolver = fec.FecResolver.init(allocator, 128, shred_version),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.slots.valueIterator();
        while (it.next()) |slot_shreds| {
            slot_shreds.deinit();
        }
        self.slots.deinit();
        self.fec_resolver.deinit();
    }

    /// Insert a shred with FEC recovery support
    /// Reference: Firedancer fd_fec_resolver_add_shred
    pub fn insert(self: *Self, shred: Shred) !InsertResult {
        const slot = shred.slot();

        var slot_shreds = self.slots.getPtr(slot) orelse blk: {
            try self.slots.put(slot, SlotShreds.init(self.allocator));
            std.debug.print("[ASSEMBLER] New slot {d} started\n", .{slot});
            break :blk self.slots.getPtr(slot).?;
        };

        if (shred.isData()) {
            const existing = slot_shreds.data_shreds.get(shred.index());
            if (existing != null) {
                return .duplicate;
            }

            try slot_shreds.data_shreds.put(shred.index(), shred);

            if (shred.index() > slot_shreds.highest_data_index) {
                slot_shreds.highest_data_index = shred.index();
            }

            if (shred.isLastInSlot()) {
                slot_shreds.is_complete = true;
                std.debug.print("[ASSEMBLER] Slot {d} marked complete (last_idx={d})\n", .{
                    slot, shred.index(),
                });
            }
            
            // Log progress every 10 shreds per slot
            const count = slot_shreds.data_shreds.count();
            if (@mod(count, 10) == 0) {
                std.debug.print("[ASSEMBLER] Slot {d}: {d}/{d} shreds (complete={})\n", .{
                    slot, count, slot_shreds.highest_data_index + 1, slot_shreds.is_complete,
                });
            }

            // Add to FEC resolver for recovery tracking
            _ = self.fec_resolver.addShred(
                slot,
                shred.index(),
                shred.common.fec_set_index,
                true, // is_data
                shred.rawData(),
                shred.common.version,
                0, 0, 0, // parity fields unused for data shreds
            ) catch {};
        } else {
            try slot_shreds.coding_shreds.put(shred.index(), shred);

            // Add parity shred to FEC resolver
            const code_header = shred.variant.code.header;
            const fec_result = self.fec_resolver.addShred(
                slot,
                shred.index(),
                shred.common.fec_set_index,
                false, // is_data
                shred.rawData(),
                shred.common.version,
                code_header.num_data_shreds,
                code_header.num_coding_shreds,
                code_header.position,
            ) catch return .inserted;

            // If FEC set is complete, we may have recovered missing data shreds
            if (fec_result == .complete) {
                return try self.handleFecComplete(slot, shred.common.fec_set_index, slot_shreds);
            }
        }

        // Check if slot is complete
        if (slot_shreds.hasAllDataShreds()) {
            return .completed_slot;
        }

        return .inserted;
    }

    /// Handle FEC recovery completion - copy recovered shreds into slot
    fn handleFecComplete(self: *Self, slot: core.Slot, fec_set_idx: u32, slot_shreds: *SlotShreds) !InsertResult {
        // Get the FEC set key
        const key = fec.FecResolver.FecSetKey{ .slot = slot, .fec_set_idx = fec_set_idx };
        const set = self.fec_resolver.active_sets.get(key) orelse return .inserted;

        // Copy any recovered data shreds that we don't have
        for (0..set.data_shred_cnt) |i| {
            if (set.data_shreds[i]) |shred_data| {
                const shred = parseShred(shred_data) catch continue;
                const idx = shred.index();

                if (slot_shreds.data_shreds.get(idx) == null) {
                    try slot_shreds.data_shreds.put(idx, shred);

                    if (idx > slot_shreds.highest_data_index) {
                        slot_shreds.highest_data_index = idx;
                    }

                    if (shred.isLastInSlot()) {
                        slot_shreds.is_complete = true;
                    }
                }
            }
        }

        // Check if slot is now complete
        if (slot_shreds.hasAllDataShreds()) {
            return .completed_slot;
        }

        return .inserted;
    }

    /// Assemble data from a completed slot
    pub fn assembleSlot(self: *Self, slot: core.Slot) !?[]u8 {
        const slot_shreds = self.slots.get(slot) orelse return null;

        if (!slot_shreds.hasAllDataShreds()) return null;

        // Calculate total size
        var total_size: usize = 0;
        var i: u32 = 0;
        while (i <= slot_shreds.highest_data_index) : (i += 1) {
            if (slot_shreds.data_shreds.get(i)) |shred| {
                total_size += shred.variant.data.data.len;
            } else {
                return error.MissingShred;
            }
        }

        // Allocate and copy
        var result = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;

        i = 0;
        while (i <= slot_shreds.highest_data_index) : (i += 1) {
            const shred = slot_shreds.data_shreds.get(i).?;
            const data = shred.variant.data.data;
            @memcpy(result[offset..][0..data.len], data);
            offset += data.len;
        }

        return result;
    }

    /// Get list of slots currently being assembled (not yet complete)
    /// Caller owns the returned slice and must free it with allocator.free()
    pub fn getInProgressSlots(self: *Self) ![]core.Slot {
        // Return slots that have some shreds but aren't complete
        var result = std.ArrayList(core.Slot).init(self.allocator);
        errdefer result.deinit();
        
        var it = self.slots.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_complete or !entry.value_ptr.hasAllDataShreds()) {
                try result.append(entry.key_ptr.*);
            }
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Get missing shred indices for a slot
    pub fn getMissingIndices(self: *Self, slot: core.Slot) ![]const u32 {
        const slot_shreds = self.slots.get(slot) orelse return &[_]u32{};
        
        // If we don't know the last index yet, we can't determine what's missing
        if (!slot_shreds.is_complete) {
            // Request indices after what we have
            var missing = std.ArrayList(u32).init(self.allocator);
            errdefer missing.deinit();
            
            // Check for gaps in what we have
            var i: u32 = 0;
            while (i <= slot_shreds.highest_data_index) : (i += 1) {
                if (slot_shreds.data_shreds.get(i) == null) {
                    try missing.append(i);
                }
            }
            
            return try missing.toOwnedSlice();
        }
        
        // We know the slot is complete, find missing indices
        var missing = std.ArrayList(u32).init(self.allocator);
        errdefer missing.deinit();
        
        var i: u32 = 0;

    /// Get all data shreds for a slot (for replay)
    pub fn getShredsForSlot(self: *Self, slot: core.Slot) ![]Shred {
        const slot_shreds = self.slots.get(slot) orelse return &[_]Shred{};
        
        var shreds = std.ArrayList(Shred).init(self.allocator);
        errdefer shreds.deinit();
        
        // Collect all data shreds
        var it = slot_shreds.data_shreds.valueIterator();
        while (it.next()) |shred| {
            try shreds.append(shred.*);
        }
        
        return try shreds.toOwnedSlice();
    }
        while (i <= slot_shreds.highest_data_index) : (i += 1) {
            if (slot_shreds.data_shreds.get(i) == null) {
                try missing.append(i);
            }
        }
        
        return try missing.toOwnedSlice();
    }
    
    /// Remove a completed slot from memory
    pub fn removeSlot(self: *Self, slot: core.Slot) void {
        if (self.slots.fetchRemove(slot)) |kv| {
            var slot_shreds = kv.value;
            slot_shreds.deinit();
        }
    }
    
    /// Get the highest slot that has been marked complete
    pub fn getHighestCompletedSlot(self: *Self) core.Slot {
        var highest: core.Slot = 0;
        var iter = self.slots.iterator();
        while (iter.next()) |entry| {
            const slot = entry.key_ptr.*;
            const slot_shreds = entry.value_ptr.*;
            if (slot_shreds.is_complete and slot > highest) {
                highest = slot;
            }
        }
        return highest;
    }

    pub const InsertResult = enum {
        inserted,
        duplicate,
        completed_slot,
    };
};

/// Shred creator for block production
pub const ShredCreator = struct {
    allocator: std.mem.Allocator,
    slot: core.Slot,
    parent_slot: core.Slot,
    shred_version: u16,
    next_data_index: u32,
    next_code_index: u32,
    fec_set_index: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot: core.Slot, parent_slot: core.Slot, shred_version: u16) Self {
        return .{
            .allocator = allocator,
            .slot = slot,
            .parent_slot = parent_slot,
            .shred_version = shred_version,
            .next_data_index = 0,
            .next_code_index = 0,
            .fec_set_index = 0,
        };
    }

    /// Create data shreds from entries
    pub fn createDataShreds(self: *Self, entries: []const u8, is_last: bool) ![][]u8 {
        const num_shreds = (entries.len + DATA_SHRED_PAYLOAD - 1) / DATA_SHRED_PAYLOAD;
        var shreds = try self.allocator.alloc([]u8, num_shreds);

        var offset: usize = 0;
        for (0..num_shreds) |i| {
            const chunk_size = @min(DATA_SHRED_PAYLOAD, entries.len - offset);
            const last_shred = is_last and (i == num_shreds - 1);

            shreds[i] = try self.createDataShred(
                entries[offset..][0..chunk_size],
                last_shred,
            );

            offset += chunk_size;
            self.next_data_index += 1;
        }

        return shreds;
    }

    fn createDataShred(self: *Self, data: []const u8, is_last: bool) ![]u8 {
        var shred = try self.allocator.alloc(u8, SHRED_PAYLOAD_SIZE);

        // Leave space for signature (filled later)
        @memset(shred[0..64], 0);

        // Shred type
        shred[64] = @intFromEnum(ShredType.data);

        // Slot (little-endian u64)
        std.mem.writeInt(u64, shred[65..73], self.slot, .little);

        // Index
        std.mem.writeInt(u32, shred[73..77], self.next_data_index, .little);

        // Version
        std.mem.writeInt(u16, shred[77..79], self.shred_version, .little);

        // FEC set index
        std.mem.writeInt(u32, shred[79..83], self.fec_set_index, .little);

        // Parent offset
        const parent_offset: u16 = @intCast(self.slot - self.parent_slot);
        std.mem.writeInt(u16, shred[83..85], parent_offset, .little);

        // Flags
        var flags: u8 = 0;
        if (is_last) flags |= 0x02; // last_in_slot
        shred[85] = flags;

        // Size
        std.mem.writeInt(u16, shred[86..88], @intCast(data.len), .little);

        // Data
        @memcpy(shred[88..][0..data.len], data);

        return shred;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "shred type" {
    try std.testing.expect(ShredType.data.isData());
    try std.testing.expect(!ShredType.data.isCode());
    try std.testing.expect(ShredType.code.isCode());
}

test "shred assembler" {
    var assembler = ShredAssembler.init(std.testing.allocator);
    defer assembler.deinit();

    try std.testing.expectEqual(@as(usize, 0), assembler.slots.count());
}

