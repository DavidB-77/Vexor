//! Vexor Turbine Tree
//!
//! Implements the Solana Turbine protocol for shred propagation.
//! Based on Sig (Zig) and Firedancer (C) implementations.
//!
//! The Turbine tree is a stake-weighted broadcast tree that determines
//! which validators should receive shreds and in what order.
//!
//! Key concepts:
//! - Nodes are sorted by (stake, pubkey) in descending order
//! - A deterministic weighted shuffle is computed for each shred
//! - The seed is SHA256(slot || shred_type || index || leader_pubkey)
//! - Children are computed based on position in the shuffled tree
//!
//! Reference: https://github.com/Syndica/sig/blob/main/src/shred_network/transmitter/turbine_tree.zig
//! Reference: https://github.com/firedancer-io/firedancer/blob/main/src/disco/shred/fd_shred_dest.c

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const gossip = @import("gossip.zig");
const packet = @import("packet.zig");

/// Maximum fanout (number of children per node)
pub const DATA_PLANE_FANOUT: usize = 200;

/// Maximum depth of the turbine tree
pub const MAX_TURBINE_TREE_DEPTH: usize = 4;

/// Maximum nodes per IP address (for Sybil protection)
pub const MAX_NODES_PER_IP_ADDRESS: usize = 10;

/// A node in the Turbine tree
pub const TurbineNode = struct {
    pubkey: core.Pubkey,
    stake: u64,
    tvu_addr: ?packet.SocketAddr,

    /// Compare nodes for sorting (descending by stake, then by pubkey)
    pub fn lessThan(_: void, a: TurbineNode, b: TurbineNode) bool {
        if (a.stake != b.stake) {
            return a.stake > b.stake; // Higher stake first
        }
        // Tie-break by pubkey (descending lexicographic)
        return std.mem.order(u8, &a.pubkey.data, &b.pubkey.data) == .gt;
    }
};

/// Shred identifier for seeding the shuffle
pub const ShredId = struct {
    slot: u64,
    index: u32,
    shred_type: ShredType,

    pub const ShredType = enum(u8) {
        data = 0xA5,
        code = 0x5A,
    };
};

/// Result of tree search/placement
pub const TurbineSearchResult = struct {
    my_index: usize,
    root_distance: usize,
};

/// Turbine Tree for computing shred destinations
pub const TurbineTree = struct {
    allocator: std.mem.Allocator,
    my_pubkey: core.Pubkey,

    /// All nodes sorted by (stake, pubkey) descending
    nodes: std.ArrayList(TurbineNode),

    /// Pubkey -> index in nodes
    index_map: std.AutoHashMap([32]u8, usize),

    /// Stakes for weighted shuffle
    stakes: std.ArrayList(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, my_pubkey: core.Pubkey) Self {
        return .{
            .allocator = allocator,
            .my_pubkey = my_pubkey,
            .nodes = std.ArrayList(TurbineNode).init(allocator),
            .index_map = std.AutoHashMap([32]u8, usize).init(allocator),
            .stakes = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit();
        self.index_map.deinit();
        self.stakes.deinit();
    }

    /// Build the tree from gossip peers and stake information
    pub fn build(
        self: *Self,
        gossip_peers: []const gossip.ContactInfo,
        staked_nodes: *const std.AutoHashMap([32]u8, u64),
    ) !void {
        self.nodes.clearRetainingCapacity();
        self.index_map.clearRetainingCapacity();
        self.stakes.clearRetainingCapacity();

        // Track seen pubkeys to avoid duplicates
        var seen = std.AutoHashMap([32]u8, void).init(self.allocator);
        defer seen.deinit();

        // Add ourselves first
        const my_stake = staked_nodes.get(self.my_pubkey.data) orelse 0;
        try self.nodes.append(.{
            .pubkey = self.my_pubkey,
            .stake = my_stake,
            .tvu_addr = null, // We don't send to ourselves
        });
        try seen.put(self.my_pubkey.data, {});

        // Add gossip peers with TVU addresses
        for (gossip_peers) |peer| {
            if (seen.contains(peer.pubkey.data)) continue;

            const stake = staked_nodes.get(peer.pubkey.data) orelse 0;
            try self.nodes.append(.{
                .pubkey = peer.pubkey,
                .stake = stake,
                .tvu_addr = peer.tvu_addr,
            });
            try seen.put(peer.pubkey.data, {});
        }

        // Add staked nodes without contact info (for deterministic shuffle)
        var stake_iter = staked_nodes.iterator();
        while (stake_iter.next()) |entry| {
            if (seen.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.* == 0) continue; // Skip zero-stake

            try self.nodes.append(.{
                .pubkey = .{ .data = entry.key_ptr.* },
                .stake = entry.value_ptr.*,
                .tvu_addr = null,
            });
        }

        // Sort by (stake desc, pubkey desc)
        std.mem.sort(TurbineNode, self.nodes.items, {}, TurbineNode.lessThan);

        // Build index map and stakes array
        for (self.nodes.items, 0..) |node, i| {
            try self.index_map.put(node.pubkey.data, i);
            try self.stakes.append(node.stake);
        }
    }

    /// Compute the seed for the weighted shuffle
    /// seed = SHA256(slot || shred_type || index || leader_pubkey)
    fn computeSeed(slot: u64, shred_id: ShredId, leader: core.Pubkey) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Slot (little-endian)
        var slot_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &slot_bytes, slot, .little);
        hasher.update(&slot_bytes);

        // Shred type
        hasher.update(&[_]u8{@intFromEnum(shred_id.shred_type)});

        // Index (little-endian)
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, shred_id.index, .little);
        hasher.update(&index_bytes);

        // Leader pubkey
        hasher.update(&leader.data);

        return hasher.finalResult();
    }

    /// Get my position and children in the shuffled tree for a specific shred
    /// Returns: (my_index, root_distance, children)
    ///
    /// Uses proper ChaChaRng + WeightedShuffle matching Sig/Agave for deterministic
    /// stake-weighted shuffling that matches the network.
    pub fn getRetransmitChildren(
        self: *Self,
        children: *std.ArrayList(TurbineNode),
        leader: core.Pubkey,
        shred_id: ShredId,
        fanout: usize,
    ) !TurbineSearchResult {
        children.clearRetainingCapacity();

        if (self.nodes.items.len == 0) {
            return TurbineSearchResult{ .my_index = 0, .root_distance = 0 };
        }

        // Compute the shuffle seed (same as Sig/Agave)
        const seed = computeSeed(shred_id.slot, shred_id, leader);

        // Create ChaChaRng from seed (matches rand_chacha behavior)
        var chacha_rng = crypto.ChaChaRng.fromSeed(seed);
        const random = chacha_rng.random();

        // Create weighted shuffle from stakes
        var weighted_shuffle = try crypto.WeightedShuffle(u64).init(self.allocator, self.stakes.items);
        defer weighted_shuffle.deinit();

        // Remove leader from shuffle if present (leader doesn't participate in retransmit)
        if (self.index_map.get(leader.data)) |leader_idx| {
            weighted_shuffle.removeIndex(leader_idx);
        }

        // Perform the weighted shuffle and collect indices
        var shuffled = try std.ArrayList(usize).initCapacity(self.allocator, self.nodes.items.len);
        defer shuffled.deinit();

        var shuffle_iter = weighted_shuffle.shuffle(random);
        while (shuffle_iter.next()) |idx| {
            try shuffled.append(idx);
        }

        // Find my position in the shuffled list
        // Logical indices: Leader = 0, Retransmitters = 1..N
        var my_index: usize = 0;
        var found_self = false;

        if (std.mem.eql(u8, &leader.data, &self.my_pubkey.data)) {
            my_index = 0;
            found_self = true;
        } else {
            for (shuffled.items, 0..) |idx, pos| {
                if (std.mem.eql(u8, &self.nodes.items[idx].pubkey.data, &self.my_pubkey.data)) {
                    my_index = pos + 1;
                    found_self = true;
                    break;
                }
            }
        }

        if (!found_self) {
            // We're not in the shuffle and not the leader (shouldn't happen)
            return TurbineSearchResult{ .my_index = 0, .root_distance = 0 };
        }

        // Compute root distance
        // root (0) -> layer 1 [1, fanout] -> layer 2 [fanout+1, fanout*(fanout+1)] -> layer 3+
        const root_distance: usize = if (my_index == 0)
            0
        else if (my_index <= fanout)
            1
        else if (my_index <= (fanout +| 1) *| fanout)
            2
        else
            3;

        // Compute retransmit children based on position in tree
        // Tree structure:
        // root (0) -> children [1, 2, ..., fanout]
        // node k in layer 1 -> children [fanout + k, 2*fanout + k, ..., fanout*fanout + k]
        try children.ensureTotalCapacity(fanout);

        computeRetransmitChildrenFromShuffled(children, fanout, my_index, shuffled.items, self.nodes.items);

        return TurbineSearchResult{ .my_index = my_index, .root_distance = root_distance };
    }

    /// Compute retransmit children from shuffled node list
    /// This matches Sig's computeRetransmitChildren function
    fn computeRetransmitChildrenFromShuffled(
        children: *std.ArrayList(TurbineNode),
        fanout: usize,
        index: usize,
        shuffled: []const usize,
        nodes: []const TurbineNode,
    ) void {
        const offset = if (index == 0) 0 else (index -| 1) % fanout;
        const anchor = index - offset;
        const step: usize = if (index == 0) 1 else fanout;
        var curr = anchor * fanout + offset + 1;
        var steps: usize = 0;

        while (curr <= shuffled.len and steps < fanout) {
            const node_idx = shuffled[curr - 1];
            const node = nodes[node_idx];
            // Only add nodes with valid TVU addresses
            if (node.tvu_addr != null) {
                children.appendAssumeCapacity(node);
            }
            curr += step;
            steps += 1;
        }
    }

    /// Get the number of nodes in the tree
    pub fn nodeCount(self: *const Self) usize {
        return self.nodes.items.len;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "turbine tree init" {
    const allocator = std.testing.allocator;
    const my_pubkey: core.Pubkey = .{ .data = [_]u8{0x11} ** 32 };

    var tree = TurbineTree.init(allocator, my_pubkey);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 0), tree.nodeCount());
}

test "turbine node sorting" {
    const nodes = [_]TurbineNode{
        .{ .pubkey = .{ .data = [_]u8{0x01} ** 32 }, .stake = 100, .tvu_addr = null },
        .{ .pubkey = .{ .data = [_]u8{0x02} ** 32 }, .stake = 200, .tvu_addr = null },
        .{ .pubkey = .{ .data = [_]u8{0x03} ** 32 }, .stake = 100, .tvu_addr = null },
    };

    var sorted = nodes;
    std.mem.sort(TurbineNode, &sorted, {}, TurbineNode.lessThan);

    // Highest stake first
    try std.testing.expectEqual(@as(u64, 200), sorted[0].stake);
    // Then by pubkey descending for equal stakes
    try std.testing.expectEqual(@as(u8, 0x03), sorted[1].pubkey.data[0]);
    try std.testing.expectEqual(@as(u8, 0x01), sorted[2].pubkey.data[0]);
}

test "compute seed deterministic" {
    const leader = core.Pubkey{ .data = [_]u8{0xAA} ** 32 };
    const shred_id = ShredId{
        .slot = 12345,
        .index = 42,
        .shred_type = .data,
    };

    const seed1 = TurbineTree.computeSeed(12345, shred_id, leader);
    const seed2 = TurbineTree.computeSeed(12345, shred_id, leader);

    try std.testing.expectEqualSlices(u8, &seed1, &seed2);
}
