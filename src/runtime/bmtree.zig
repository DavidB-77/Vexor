//! Vexor Binary Merkle Tree
//!
//! SHA256-based Merkle tree for shred verification.
//! Based on Firedancer: src/ballet/bmtree/fd_bmtree.h
//!
//! Used to verify the authenticity and integrity of shreds.
//! The root of the Merkle tree is signed by the block producer.

const std = @import("std");
const core = @import("../core/root.zig");

/// Merkle node size (SHA256 hash)
pub const NODE_SIZE: usize = 32;

/// Maximum tree depth (log2 of max leaves)
pub const MAX_DEPTH: usize = 20;

/// Maximum leaves in a tree (2^20 = ~1M)
pub const MAX_LEAVES: usize = 1 << MAX_DEPTH;

/// Merkle tree node (32-byte hash)
pub const Node = [NODE_SIZE]u8;

/// Merkle inclusion proof
/// Reference: Firedancer fd_bmtree_inc_proof
pub const InclusionProof = struct {
    /// Nodes on the path from leaf to root
    nodes: []Node,

    /// Positions (left=0, right=1) for each node in the path
    positions: []u1,

    /// Index of the leaf this proof is for
    leaf_index: usize,

    pub fn deinit(self: *InclusionProof, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.positions);
    }
};

/// Binary Merkle Tree
/// Reference: Firedancer fd_bmtree_commit
pub const MerkleTree = struct {
    allocator: std.mem.Allocator,

    /// All nodes in the tree (leaf and branch)
    /// Layout: leaves at bottom, branches above
    nodes: std.ArrayList(Node),

    /// Number of leaf nodes
    leaf_count: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = std.ArrayList(Node).init(allocator),
            .leaf_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit();
    }

    /// Hash a leaf blob to create a leaf node
    /// Reference: Firedancer fd_bmtree_hash_leaf
    pub fn hashLeaf(data: []const u8) Node {
        // Prefix with 0x00 to distinguish from branch nodes
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&[_]u8{0x00});
        hasher.update(data);
        return hasher.finalResult();
    }

    /// Hash two child nodes to create a branch node
    /// Reference: Firedancer fd_bmtree_hash_branch
    pub fn hashBranch(left: *const Node, right: *const Node) Node {
        // Prefix with 0x01 to distinguish from leaf nodes
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&[_]u8{0x01});
        hasher.update(left);
        hasher.update(right);
        return hasher.finalResult();
    }

    /// Add a leaf to the tree (must call finalize after all leaves added)
    pub fn addLeaf(self: *Self, data: []const u8) !void {
        const leaf_node = hashLeaf(data);
        try self.nodes.append(leaf_node);
        self.leaf_count += 1;
    }

    /// Add a pre-hashed leaf node directly
    pub fn addLeafNode(self: *Self, node: Node) !void {
        try self.nodes.append(node);
        self.leaf_count += 1;
    }

    /// Finalize the tree by computing all branch nodes up to root
    /// Reference: Firedancer fd_bmtree_commit_fini
    pub fn finalize(self: *Self) !void {
        if (self.leaf_count == 0) return;
        if (self.leaf_count == 1) {
            // Single leaf is also the root
            return;
        }

        // Build tree bottom-up
        var level_start: usize = 0;
        var level_count: usize = self.leaf_count;

        while (level_count > 1) {
            const next_level_count = (level_count + 1) / 2;

            var i: usize = 0;
            while (i < level_count) : (i += 2) {
                const left = &self.nodes.items[level_start + i];
                const right = if (i + 1 < level_count)
                    &self.nodes.items[level_start + i + 1]
                else
                    left; // Duplicate last node if odd count

                const branch = hashBranch(left, right);
                try self.nodes.append(branch);
            }

            level_start += level_count;
            level_count = next_level_count;
        }
    }

    /// Get the root hash of the tree
    pub fn root(self: *const Self) ?Node {
        if (self.nodes.items.len == 0) return null;
        return self.nodes.items[self.nodes.items.len - 1];
    }

    /// Create an inclusion proof for a leaf
    /// Reference: Firedancer fd_bmtree_inc_proof_from_tree
    pub fn createProof(self: *const Self, leaf_index: usize) !InclusionProof {
        if (leaf_index >= self.leaf_count) return error.InvalidLeafIndex;

        // Calculate tree depth
        var depth: usize = 0;
        var temp = self.leaf_count;
        while (temp > 1) : (temp = (temp + 1) / 2) {
            depth += 1;
        }

        var nodes = try self.allocator.alloc(Node, depth);
        errdefer self.allocator.free(nodes);
        var positions = try self.allocator.alloc(u1, depth);
        errdefer self.allocator.free(positions);

        var current_index = leaf_index;
        var level_start: usize = 0;
        var level_count = self.leaf_count;
        var proof_idx: usize = 0;

        while (level_count > 1 and proof_idx < depth) {
            // Find sibling
            const sibling_index = if (current_index % 2 == 0)
                current_index + 1
            else
                current_index - 1;

            // Position: 0 if we're on left, 1 if we're on right
            positions[proof_idx] = @intCast(current_index % 2);

            // Get sibling node (or self if at edge)
            if (sibling_index < level_count) {
                nodes[proof_idx] = self.nodes.items[level_start + sibling_index];
            } else {
                nodes[proof_idx] = self.nodes.items[level_start + current_index];
            }

            // Move to parent
            level_start += level_count;
            level_count = (level_count + 1) / 2;
            current_index = current_index / 2;
            proof_idx += 1;
        }

        return InclusionProof{
            .nodes = nodes[0..proof_idx],
            .positions = positions[0..proof_idx],
            .leaf_index = leaf_index,
        };
    }

    /// Verify an inclusion proof against a root
    /// Reference: Firedancer fd_bmtree_inc_proof_verify
    pub fn verifyProof(leaf: *const Node, proof: *const InclusionProof, expected_root: *const Node) bool {
        var current = leaf.*;

        for (proof.nodes, 0..) |sibling, i| {
            if (proof.positions[i] == 0) {
                // We're on left, sibling on right
                current = hashBranch(&current, &sibling);
            } else {
                // We're on right, sibling on left
                current = hashBranch(&sibling, &current);
            }
        }

        return std.mem.eql(u8, &current, expected_root);
    }
};

/// Shred Merkle tree for verifying shreds in an FEC set
/// Reference: Firedancer fd_bmtree_commit for shred verification
pub const ShredMerkleTree = struct {
    tree: MerkleTree,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .tree = MerkleTree.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.tree.deinit();
    }

    /// Add a shred to the tree (payload only, not signature)
    pub fn addShred(self: *Self, shred_data: []const u8) !void {
        // Hash the shred payload (skip the signature at offset 0..64)
        const payload = if (shred_data.len > 64) shred_data[64..] else shred_data;
        try self.tree.addLeaf(payload);
    }

    /// Finalize and get the root for signing
    pub fn finalize(self: *Self) !void {
        try self.tree.finalize();
    }

    /// Get the Merkle root that should be signed
    pub fn root(self: *const Self) ?MerkleTree.Node {
        return self.tree.root();
    }

    /// Verify that a shred is part of the signed tree
    pub fn verifyShred(
        self: *const Self,
        shred_data: []const u8,
        shred_index: usize,
        signed_root: *const MerkleTree.Node,
    ) !bool {
        // Hash the shred
        const payload = if (shred_data.len > 64) shred_data[64..] else shred_data;
        const leaf = MerkleTree.hashLeaf(payload);

        // Create and verify proof
        const proof = try self.tree.createProof(shred_index);
        defer @constCast(&proof).deinit(self.tree.allocator);

        return MerkleTree.verifyProof(&leaf, &proof, signed_root);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "merkle tree basic" {
    const allocator = std.testing.allocator;

    var tree = MerkleTree.init(allocator);
    defer tree.deinit();

    // Add some leaves
    try tree.addLeaf("leaf1");
    try tree.addLeaf("leaf2");
    try tree.addLeaf("leaf3");
    try tree.addLeaf("leaf4");

    try tree.finalize();

    const r = tree.root();
    try std.testing.expect(r != null);
}

test "merkle inclusion proof" {
    const allocator = std.testing.allocator;

    var tree = MerkleTree.init(allocator);
    defer tree.deinit();

    // Add 4 leaves
    try tree.addLeaf("leaf0");
    try tree.addLeaf("leaf1");
    try tree.addLeaf("leaf2");
    try tree.addLeaf("leaf3");

    try tree.finalize();

    const r = tree.root().?;

    // Create and verify proof for leaf 2
    var proof = try tree.createProof(2);
    defer proof.deinit(allocator);

    const leaf = MerkleTree.hashLeaf("leaf2");
    try std.testing.expect(MerkleTree.verifyProof(&leaf, &proof, &r));

    // Wrong leaf should fail
    const wrong_leaf = MerkleTree.hashLeaf("wrong");
    try std.testing.expect(!MerkleTree.verifyProof(&wrong_leaf, &proof, &r));
}

test "shred merkle tree" {
    const allocator = std.testing.allocator;

    var tree = ShredMerkleTree.init(allocator);
    defer tree.deinit();

    // Add some fake shreds (with 64-byte signature prefix)
    var shred1: [128]u8 = undefined;
    @memset(&shred1, 0xAA);
    try tree.addShred(&shred1);

    var shred2: [128]u8 = undefined;
    @memset(&shred2, 0xBB);
    try tree.addShred(&shred2);

    try tree.finalize();

    const r = tree.root().?;
    try std.testing.expect(try tree.verifyShred(&shred1, 0, &r));
    try std.testing.expect(try tree.verifyShred(&shred2, 1, &r));
}

