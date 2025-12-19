//! Vexor Cryptographic Hashing
//!
//! High-performance SHA256 and Blake3 hashing for Solana data structures.

const std = @import("std");
const core = @import("../core/root.zig");

/// SHA256 hash (standard for Solana)
pub const Sha256 = struct {
    hasher: std.crypto.hash.sha2.Sha256,

    pub fn init() Sha256 {
        return .{ .hasher = std.crypto.hash.sha2.Sha256.init(.{}) };
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        self.hasher.update(data);
    }

    pub fn final(self: *Sha256) core.Hash {
        return self.hasher.finalResult();
    }

    /// Hash data in one shot
    pub fn hash(data: []const u8) core.Hash {
        return std.crypto.hash.sha2.Sha256.hash(data, .{});
    }

    /// Hash multiple slices
    pub fn hashMulti(slices: []const []const u8) core.Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (slices) |slice| {
            hasher.update(slice);
        }
        return hasher.finalResult();
    }
};

/// Blake3 hash (faster alternative, used in some newer components)
pub const Blake3 = struct {
    hasher: std.crypto.hash.Blake3,

    pub fn init() Blake3 {
        return .{ .hasher = std.crypto.hash.Blake3.init(.{}) };
    }

    pub fn update(self: *Blake3, data: []const u8) void {
        self.hasher.update(data);
    }

    pub fn final(self: *Blake3) core.Hash {
        return self.hasher.finalResult()[0..32].*;
    }

    /// Hash data in one shot
    pub fn hash(data: []const u8) core.Hash {
        return std.crypto.hash.Blake3.hash(data, .{})[0..32].*;
    }
};

/// Merkle tree for efficient hash verification
pub const MerkleTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(core.Hash),
    leaf_count: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(core.Hash).init(allocator),
            .leaf_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit();
    }

    /// Build tree from leaf hashes
    pub fn buildFromLeaves(self: *Self, leaves: []const core.Hash) !void {
        self.nodes.clearRetainingCapacity();
        self.leaf_count = leaves.len;

        if (leaves.len == 0) return;

        // Add leaves
        try self.nodes.appendSlice(leaves);

        // Build internal nodes bottom-up
        var level_start: usize = 0;
        var level_size = leaves.len;

        while (level_size > 1) {
            const next_level_size = (level_size + 1) / 2;

            var i: usize = 0;
            while (i < level_size) : (i += 2) {
                const left = self.nodes.items[level_start + i];
                const right = if (i + 1 < level_size)
                    self.nodes.items[level_start + i + 1]
                else
                    left; // Duplicate last node if odd

                const parent = hashPair(left, right);
                try self.nodes.append(parent);
            }

            level_start += level_size;
            level_size = next_level_size;
        }
    }

    /// Get the root hash
    pub fn root(self: *const Self) ?core.Hash {
        if (self.nodes.items.len == 0) return null;
        return self.nodes.items[self.nodes.items.len - 1];
    }

    /// Hash two nodes together
    fn hashPair(left: core.Hash, right: core.Hash) core.Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&left);
        hasher.update(&right);
        return hasher.finalResult();
    }
};

/// Hash an account for accounts hash calculation
pub fn hashAccount(
    lamports: u64,
    owner: *const core.Pubkey,
    executable: bool,
    rent_epoch: u64,
    data: []const u8,
    pubkey: *const core.Pubkey,
) core.Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Account data hash format (same as Solana)
    hasher.update(std.mem.asBytes(&lamports));
    hasher.update(std.mem.asBytes(&rent_epoch));
    hasher.update(data);
    const exec_byte: u8 = if (executable) 1 else 0;
    hasher.update(&[_]u8{exec_byte});
    hasher.update(&owner.data);
    hasher.update(&pubkey.data);

    return hasher.finalResult();
}

/// Hash a transaction message
pub fn hashTransaction(message: []const u8) core.Hash {
    return Sha256.hash(message);
}

/// Bank hash - combines state hash with delta hash
pub fn hashBankState(
    parent_hash: core.Hash,
    accounts_delta_hash: core.Hash,
    num_signatures: u64,
    blockhash: core.Hash,
) core.Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&parent_hash.data);
    hasher.update(&accounts_delta_hash.data);
    hasher.update(std.mem.asBytes(&num_signatures));
    hasher.update(&blockhash.data);
    return core.Hash{ .data = hasher.finalResult() };
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "sha256 oneshot" {
    const hash = Sha256.hash("Hello, Vexor!");
    try std.testing.expect(hash[0] != 0);
}

test "sha256 incremental" {
    var h = Sha256.init();
    h.update("Hello, ");
    h.update("Vexor!");
    const hash = h.final();

    // Should match oneshot
    const expected = Sha256.hash("Hello, Vexor!");
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "blake3" {
    const hash = Blake3.hash("Hello, Vexor!");
    try std.testing.expect(hash[0] != 0);
}

test "merkle tree" {
    var tree = MerkleTree.init(std.testing.allocator);
    defer tree.deinit();

    const leaves = [_]core.Hash{
        Sha256.hash("leaf1"),
        Sha256.hash("leaf2"),
        Sha256.hash("leaf3"),
        Sha256.hash("leaf4"),
    };

    try tree.buildFromLeaves(&leaves);
    const root = tree.root();
    try std.testing.expect(root != null);
}

test "account hash" {
    const owner = core.Pubkey{ .data = [_]u8{0} ** 32 };
    const pubkey = core.Pubkey{ .data = [_]u8{1} ** 32 };

    const hash = hashAccount(
        1000000,
        &owner,
        false,
        0,
        "account data",
        &pubkey,
    );

    try std.testing.expect(hash[0] != 0);
}

