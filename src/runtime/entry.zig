//! Vexor Entry Module
//!
//! Entries are the fundamental unit of a Solana block.
//! Each entry contains:
//! - PoH hashes (proof that time has passed)
//! - Transactions to execute
//!
//! Entry format:
//! [num_hashes: u64] [hash: 32] [num_txs: u64] [transactions...]

const std = @import("std");
const core = @import("../core/root.zig");
const transaction = @import("transaction.zig");
const crypto = @import("../crypto/root.zig");

/// A single entry in a block
pub const Entry = struct {
    /// Number of PoH hashes since last entry
    num_hashes: u64,

    /// Final PoH hash for this entry
    hash: core.Hash,

    /// Transactions in this entry
    transactions: []const transaction.ParsedTransaction,

    pub fn isEmpty(self: *const Entry) bool {
        return self.transactions.len == 0 and self.num_hashes == 0;
    }

    /// Verify the PoH chain
    pub fn verifyHash(self: *const Entry, prev_hash: core.Hash) bool {
        var hash = prev_hash;

        for (0..self.num_hashes) |_| {
            hash = crypto.hash(&hash);
        }

        // Mix in transaction hashes if any
        if (self.transactions.len > 0) {
            var hasher = crypto.Sha256.init();
            hasher.update(&hash);
            for (self.transactions) |tx| {
                hasher.update(tx.message_bytes);
            }
            hash = hasher.final();
        }

        return std.mem.eql(u8, &hash, &self.hash);
    }
};

/// Parse entries from raw slot data
pub const EntryParser = struct {
    allocator: std.mem.Allocator,
    tx_parser: transaction.TransactionParser,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tx_parser = transaction.TransactionParser.init(allocator),
        };
    }

    /// Parse all entries from slot data
    pub fn parseSlot(self: *Self, data: []const u8) ![]Entry {
        var entries = std.ArrayList(Entry).init(self.allocator);
        errdefer entries.deinit();

        var offset: usize = 0;

        while (offset < data.len) {
            const entry = try self.parseEntry(data, &offset);
            try entries.append(entry);
        }

        return try entries.toOwnedSlice();
    }

    /// Maximum transactions per entry to prevent excessive allocation
    const MAX_TXS_PER_ENTRY: u64 = 64 * 1024; // 64K transactions max

    fn parseEntry(self: *Self, data: []const u8, offset: *usize) !Entry {
        if (offset.* + 48 > data.len) return error.UnexpectedEndOfData;

        // Parse num_hashes
        const num_hashes = std.mem.readInt(u64, data[offset.*..][0..8], .little);
        offset.* += 8;

        // Parse hash - initialize to zero to avoid undefined memory
        var hash: core.Hash = [_]u8{0} ** 32;
        @memcpy(&hash, data[offset.*..][0..32]);
        offset.* += 32;

        // Parse num_txs
        const num_txs = std.mem.readInt(u64, data[offset.*..][0..8], .little);
        offset.* += 8;

        // Validate num_txs to prevent excessive allocation
        if (num_txs > MAX_TXS_PER_ENTRY) {
            return error.TooManyTransactions;
        }

        // Parse transactions
        const transactions = try self.allocator.alloc(transaction.ParsedTransaction, @intCast(num_txs));
        errdefer self.allocator.free(transactions);

        for (0..@intCast(num_txs)) |i| {
            // Get transaction length (compact-u16)
            const tx_len = try self.tx_parser.parseCompactU16(data[offset.*..], offset);

            if (offset.* + tx_len > data.len) return error.UnexpectedEndOfData;

            const tx_data = data[offset.*..][0..tx_len];
            offset.* += tx_len;

            transactions[i] = try self.tx_parser.parse(tx_data);
        }

        return Entry{
            .num_hashes = num_hashes,
            .hash = hash,
            .transactions = transactions,
        };
    }

    /// Free parsed entries
    pub fn freeEntries(self: *Self, entries: []Entry) void {
        for (entries) |entry| {
            self.allocator.free(entry.transactions);
        }
        self.allocator.free(entries);
    }
};

/// Entry tick represents time passing with no transactions
pub const TickEntry = struct {
    num_hashes: u64,
    hash: core.Hash,

    pub fn asEntry(self: TickEntry) Entry {
        return Entry{
            .num_hashes = self.num_hashes,
            .hash = self.hash,
            .transactions = &[_]transaction.ParsedTransaction{},
        };
    }
};

/// Entry with transactions
pub const TransactionEntry = struct {
    /// PoH hashes since last entry
    num_hashes: u64,

    /// Mixin hash (for entries with txs, this is tx hash mixin)
    mixin: core.Hash,

    /// Transactions
    transactions: []const []const u8,

    /// Compute final hash
    pub fn computeHash(self: *const TransactionEntry, prev_hash: core.Hash) core.Hash {
        var hash = prev_hash;

        // Apply PoH hashes
        for (0..self.num_hashes) |_| {
            hash = crypto.hash(&hash);
        }

        // Mix in transaction hashes
        var hasher = crypto.Sha256.init();
        hasher.update(&hash);
        hasher.update(&self.mixin);
        return hasher.final();
    }
};

/// Entry serializer for block production
pub const EntrySerializer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Serialize an entry to bytes
    pub fn serialize(self: *Self, entry: *const Entry) ![]u8 {
        var data = std.ArrayList(u8).init(self.allocator);
        errdefer data.deinit();

        // Write num_hashes
        try data.appendSlice(&std.mem.toBytes(entry.num_hashes));

        // Write hash
        try data.appendSlice(&entry.hash);

        // Write num_txs
        const num_txs: u64 = entry.transactions.len;
        try data.appendSlice(&std.mem.toBytes(num_txs));

        // Write transactions
        for (entry.transactions) |tx| {
            // Write tx length (compact-u16)
            const len: u16 = @intCast(tx.message_bytes.len + tx.signatures.len * 64 + 1);
            try self.writeCompactU16(&data, len);

            // Write signature count
            try data.append(@intCast(tx.signatures.len));

            // Write signatures
            for (tx.signatures) |sig| {
                try data.appendSlice(&sig.data);
            }

            // Write message
            try data.appendSlice(tx.message_bytes);
        }

        return try data.toOwnedSlice();
    }

    fn writeCompactU16(self: *Self, data: *std.ArrayList(u8), value: u16) !void {
        _ = self;
        if (value < 0x80) {
            try data.append(@intCast(value));
        } else if (value < 0x4000) {
            try data.append(@intCast((value & 0x7F) | 0x80));
            try data.append(@intCast(value >> 7));
        } else {
            try data.append(@intCast((value & 0x7F) | 0x80));
            try data.append(@intCast(((value >> 7) & 0x7F) | 0x80));
            try data.append(@intCast(value >> 14));
        }
    }
};

/// Statistics about entries
pub const EntryStats = struct {
    total_entries: u64 = 0,
    tick_entries: u64 = 0,
    tx_entries: u64 = 0,
    total_transactions: u64 = 0,
    total_hashes: u64 = 0,
};

/// Calculate entry statistics
pub fn calculateStats(entries: []const Entry) EntryStats {
    var stats = EntryStats{};

    for (entries) |entry| {
        stats.total_entries += 1;
        stats.total_hashes += entry.num_hashes;

        if (entry.transactions.len == 0) {
            stats.tick_entries += 1;
        } else {
            stats.tx_entries += 1;
            stats.total_transactions += entry.transactions.len;
        }
    }

    return stats;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "entry empty check" {
    const entry = Entry{
        .num_hashes = 0,
        .hash = core.Hash.ZERO,
        .transactions = &[_]transaction.ParsedTransaction{},
    };

    try std.testing.expect(entry.isEmpty());
}

test "entry stats" {
    const entries = [_]Entry{
        Entry{
            .num_hashes = 100,
            .hash = core.Hash.ZERO,
            .transactions = &[_]transaction.ParsedTransaction{},
        },
        Entry{
            .num_hashes = 50,
            .hash = core.Hash.ZERO,
            .transactions = &[_]transaction.ParsedTransaction{},
        },
    };

    const stats = calculateStats(&entries);
    try std.testing.expectEqual(@as(u64, 2), stats.total_entries);
    try std.testing.expectEqual(@as(u64, 150), stats.total_hashes);
}

