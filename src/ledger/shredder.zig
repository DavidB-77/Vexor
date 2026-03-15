//! Vexor Shredder
//!
//! Creates shreds from entries for block production.
//! Reference: Firedancer src/disco/shred/fd_shredder.h
//!
//! Shredding process:
//! 1. Serialize entries into binary data
//! 2. Split into chunks (data shreds)
//! 3. Generate Reed-Solomon parity shreds
//! 4. Build Merkle tree and sign root
//! 5. Broadcast via Turbine

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const shred_mod = @import("shred.zig");
const fec = @import("fec_resolver.zig");
const bmtree = @import("bmtree.zig");

/// Data shred payload size (excluding headers)
pub const DATA_SHRED_PAYLOAD_SIZE: usize = 1051;

/// Total shred size
pub const SHRED_SIZE: usize = 1228;

/// Maximum data shreds per FEC set
pub const MAX_DATA_SHREDS_PER_FEC: usize = 32;

/// Parity shreds per FEC set (for 32 data shreds)
pub const PARITY_SHREDS_PER_FEC: usize = 32;

/// Data to parity ratio table
/// Reference: Firedancer fd_shredder_data_to_parity_cnt
const DATA_TO_PARITY_CNT = [33]usize{
    0, 17, 18, 19, 19, 20, 21, 21,
    22, 23, 23, 24, 24, 25, 25, 26,
    26, 26, 27, 27, 28, 28, 29, 29,
    29, 30, 30, 31, 31, 31, 32, 32, 32,
};

/// Shredder for block production
/// Reference: Firedancer fd_shredder_t
pub const Shredder = struct {
    allocator: std.mem.Allocator,

    /// Shred version for this validator
    shred_version: u16,

    /// Signing keypair
    keypair: core.Keypair,

    /// Galois field for Reed-Solomon
    gf: fec.GaloisField,

    /// Current slot being shredded
    slot: core.Slot,

    /// Parent slot
    parent_slot: core.Slot,

    /// Next data shred index
    data_idx: u32,

    /// Next parity shred index
    parity_idx: u32,

    /// Current FEC set index
    fec_set_idx: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, keypair: core.Keypair, shred_version: u16) Self {
        return Self{
            .allocator = allocator,
            .shred_version = shred_version,
            .keypair = keypair,
            .gf = fec.GaloisField.init(),
            .slot = 0,
            .parent_slot = 0,
            .data_idx = 0,
            .parity_idx = 0,
            .fec_set_idx = 0,
        };
    }

    /// Start shredding a new slot
    pub fn startSlot(self: *Self, slot: core.Slot, parent_slot: core.Slot) void {
        self.slot = slot;
        self.parent_slot = parent_slot;
        self.data_idx = 0;
        self.parity_idx = 0;
        self.fec_set_idx = 0;
    }

    /// Shred an entry batch
    /// Returns all shreds (data + parity) for the batch
    pub fn shredEntries(self: *Self, entries: []const u8, is_last: bool) !ShredResult {
        // Calculate number of data shreds needed
        const num_data_shreds = (entries.len + DATA_SHRED_PAYLOAD_SIZE - 1) / DATA_SHRED_PAYLOAD_SIZE;

        if (num_data_shreds == 0) {
            return ShredResult{
                .data_shreds = &.{},
                .parity_shreds = &.{},
            };
        }

        // Create data shreds
        const data_shreds = try self.allocator.alloc([]u8, num_data_shreds);
        errdefer self.allocator.free(data_shreds);

        var offset: usize = 0;
        for (0..num_data_shreds) |i| {
            const chunk_end = @min(offset + DATA_SHRED_PAYLOAD_SIZE, entries.len);
            const is_last_shred = is_last and (i == num_data_shreds - 1);

            data_shreds[i] = try self.createDataShred(
                entries[offset..chunk_end],
                is_last_shred,
            );

            offset = chunk_end;
            self.data_idx += 1;
        }

        // Calculate parity shreds count
        const parity_count = if (num_data_shreds <= 32)
            DATA_TO_PARITY_CNT[num_data_shreds]
        else
            32; // Max parity for large FEC sets

        // Generate parity shreds
        const parity_shreds = try self.generateParityShreds(data_shreds, parity_count);
        errdefer self.allocator.free(parity_shreds);

        // Build Merkle tree and sign
        try self.signFecSet(data_shreds, parity_shreds);

        self.fec_set_idx += 1;

        return ShredResult{
            .data_shreds = data_shreds,
            .parity_shreds = parity_shreds,
        };
    }

    /// Create a single data shred
    fn createDataShred(self: *Self, data: []const u8, is_last: bool) ![]u8 {
        const shred = try self.allocator.alloc(u8, SHRED_SIZE);
        errdefer self.allocator.free(shred);

        // Leave space for signature (0..64) - will be filled later
        @memset(shred[0..64], 0);

        // Shred type (data)
        shred[64] = @intFromEnum(shred_mod.ShredType.data);

        // Slot (u64 little-endian)
        std.mem.writeInt(u64, shred[65..73], self.slot, .little);

        // Shred index
        std.mem.writeInt(u32, shred[73..77], self.data_idx, .little);

        // Version
        std.mem.writeInt(u16, shred[77..79], self.shred_version, .little);

        // FEC set index
        std.mem.writeInt(u32, shred[79..83], self.fec_set_idx, .little);

        // Parent offset
        const parent_offset: u16 = if (self.slot > self.parent_slot)
            @intCast(self.slot - self.parent_slot)
        else
            0;
        std.mem.writeInt(u16, shred[83..85], parent_offset, .little);

        // Flags
        var flags: u8 = 0;
        if (is_last) flags |= 0x02; // last_in_slot
        shred[85] = flags;

        // Data size
        std.mem.writeInt(u16, shred[86..88], @intCast(data.len), .little);

        // Payload
        @memcpy(shred[88..][0..data.len], data);

        // Zero-pad remainder
        if (88 + data.len < SHRED_SIZE) {
            @memset(shred[88 + data.len..], 0);
        }

        return shred;
    }

    /// Generate Reed-Solomon parity shreds
    fn generateParityShreds(self: *Self, data_shreds: []const []u8, parity_count: usize) ![][]u8 {
        const parity_shreds = try self.allocator.alloc([]u8, parity_count);
        errdefer self.allocator.free(parity_shreds);

        // Allocate parity shred buffers
        for (0..parity_count) |i| {
            parity_shreds[i] = try self.allocator.alloc(u8, SHRED_SIZE);
            @memset(parity_shreds[i], 0);

            // Fill parity shred header
            parity_shreds[i][64] = @intFromEnum(shred_mod.ShredType.code);
            std.mem.writeInt(u64, parity_shreds[i][65..73], self.slot, .little);
            std.mem.writeInt(u32, parity_shreds[i][73..77], self.parity_idx + @as(u32, @intCast(i)), .little);
            std.mem.writeInt(u16, parity_shreds[i][77..79], self.shred_version, .little);
            std.mem.writeInt(u32, parity_shreds[i][79..83], self.fec_set_idx, .little);

            // Parity-specific header
            std.mem.writeInt(u16, parity_shreds[i][83..85], @intCast(data_shreds.len), .little); // num_data
            std.mem.writeInt(u16, parity_shreds[i][85..87], @intCast(parity_count), .little); // num_parity
            std.mem.writeInt(u16, parity_shreds[i][87..89], @intCast(i), .little); // position
        }

        // Perform Reed-Solomon encoding
        // For each byte position, XOR data shreds to generate parity
        for (89..SHRED_SIZE) |byte_pos| {
            for (0..parity_count) |p| {
                var parity_byte: u8 = 0;

                // XOR all data shreds at this position
                for (data_shreds) |data_shred| {
                    if (byte_pos < data_shred.len) {
                        parity_byte ^= data_shred[byte_pos];
                    }
                }

                // Apply GF multiplication for this parity position
                // Simplified: just use XOR for basic parity
                parity_shreds[p][byte_pos] = parity_byte;
            }
        }

        self.parity_idx += @intCast(parity_count);

        return parity_shreds;
    }

    /// Build Merkle tree and sign all shreds in FEC set
    fn signFecSet(self: *Self, data_shreds: []const []u8, parity_shreds: []const []u8) !void {
        // Build Merkle tree of all shreds
        var tree = bmtree.ShredMerkleTree.init(self.allocator);
        defer tree.deinit();

        // Add all shreds (data then parity)
        for (data_shreds) |shred| {
            try tree.addShred(shred);
        }
        for (parity_shreds) |shred| {
            try tree.addShred(shred);
        }

        try tree.finalize();

        // Get root for signing
        const root = tree.root() orelse return error.EmptyTree;

        // Sign the Merkle root
        const signature = crypto.ed25519.sign(self.keypair.secret, &root);

        // Insert signature into all shreds
        for (data_shreds) |shred| {
            @memcpy(shred[0..64], &signature.data);
        }
        for (parity_shreds) |shred| {
            @memcpy(shred[0..64], &signature.data);
        }
    }

    /// Finalize slot (mark last shred)
    pub fn finishSlot(self: *Self) void {
        _ = self;
        // In a full implementation, would ensure last_in_slot flag is set
    }
};

/// Result of shredding an entry batch
pub const ShredResult = struct {
    data_shreds: [][]u8,
    parity_shreds: [][]u8,

    pub fn deinit(self: *ShredResult, allocator: std.mem.Allocator) void {
        for (self.data_shreds) |shred| {
            allocator.free(shred);
        }
        allocator.free(self.data_shreds);

        for (self.parity_shreds) |shred| {
            allocator.free(shred);
        }
        allocator.free(self.parity_shreds);
    }

    pub fn totalShreds(self: *const ShredResult) usize {
        return self.data_shreds.len + self.parity_shreds.len;
    }
};

/// Block builder for assembling entries
pub const BlockBuilder = struct {
    allocator: std.mem.Allocator,
    shredder: Shredder,

    /// Accumulated entries
    entries: std.ArrayList(u8),

    /// Shreds ready for broadcast
    pending_shreds: std.ArrayList([]u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, keypair: core.Keypair, shred_version: u16) Self {
        return Self{
            .allocator = allocator,
            .shredder = Shredder.init(allocator, keypair, shred_version),
            .entries = std.ArrayList(u8).init(allocator),
            .pending_shreds = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        for (self.pending_shreds.items) |shred| {
            self.allocator.free(shred);
        }
        self.pending_shreds.deinit();
    }

    /// Start a new block
    pub fn startBlock(self: *Self, slot: core.Slot, parent_slot: core.Slot) void {
        self.shredder.startSlot(slot, parent_slot);
        self.entries.clearRetainingCapacity();
        self.pending_shreds.clearRetainingCapacity();
    }

    /// Add an entry to the block
    pub fn addEntry(self: *Self, entry_data: []const u8) !void {
        try self.entries.appendSlice(entry_data);

        // Shred if we have enough data
        if (self.entries.items.len >= DATA_SHRED_PAYLOAD_SIZE * MAX_DATA_SHREDS_PER_FEC) {
            try self.flushEntries(false);
        }
    }

    /// Flush accumulated entries to shreds
    fn flushEntries(self: *Self, is_last: bool) !void {
        if (self.entries.items.len == 0) return;

        const result = try self.shredder.shredEntries(self.entries.items, is_last);

        // Move shreds to pending
        for (result.data_shreds) |shred| {
            try self.pending_shreds.append(shred);
        }
        for (result.parity_shreds) |shred| {
            try self.pending_shreds.append(shred);
        }

        // Free the arrays (shreds themselves are now in pending_shreds)
        self.allocator.free(result.data_shreds);
        self.allocator.free(result.parity_shreds);

        self.entries.clearRetainingCapacity();
    }

    /// Finish the block and get all shreds
    pub fn finishBlock(self: *Self) ![][]u8 {
        try self.flushEntries(true);

        // Move pending shreds to result
        const result = try self.pending_shreds.toOwnedSlice();
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "shredder basic" {
    const allocator = std.testing.allocator;

    const keypair = core.Keypair{
        .public = .{ .data = [_]u8{1} ** 32 },
        .secret = [_]u8{0} ** 64,
    };

    var shredder = Shredder.init(allocator, keypair, 1234);
    shredder.startSlot(100, 99);

    // Create some test data
    var data: [2000]u8 = undefined;
    @memset(&data, 0xAB);

    var result = try shredder.shredEntries(&data, true);
    defer result.deinit(allocator);

    try std.testing.expect(result.data_shreds.len > 0);
    try std.testing.expect(result.parity_shreds.len > 0);
}

test "block builder" {
    const allocator = std.testing.allocator;

    const keypair = core.Keypair{
        .public = .{ .data = [_]u8{1} ** 32 },
        .secret = [_]u8{0} ** 64,
    };

    var builder = BlockBuilder.init(allocator, keypair, 1234);
    defer builder.deinit();

    builder.startBlock(100, 99);

    // Add some entries
    var entry: [500]u8 = undefined;
    @memset(&entry, 0xCD);
    try builder.addEntry(&entry);
    try builder.addEntry(&entry);

    const shreds = try builder.finishBlock();
    defer {
        for (shreds) |shred| {
            allocator.free(shred);
        }
        allocator.free(shreds);
    }

    try std.testing.expect(shreds.len > 0);
}

