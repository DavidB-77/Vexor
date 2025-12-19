//! Vexor Fork Choice
//!
//! Implements stake-weighted fork selection for determining
//! which chain to build on.
//!
//! The heaviest subtree fork choice rule selects the fork with
//! the most cumulative stake voting for it and its descendants.

const std = @import("std");
const core = @import("../core/root.zig");
const vote_mod = @import("vote.zig");

const Vote = vote_mod.Vote;

/// Fork node in the fork tree
pub const ForkNode = struct {
    slot: core.Slot,
    parent: ?core.Slot,
    bank_hash: core.Hash,
    /// Direct stake voting for this slot
    direct_stake: u64,
    /// Cumulative stake (this slot + all descendants)
    cumulative_stake: u64,
    /// Child slots
    children: std.ArrayList(core.Slot),
    /// Is this slot finalized?
    is_finalized: bool,
    /// Is this slot confirmed (>2/3 stake)?
    is_confirmed: bool,
    
    pub fn init(allocator: std.mem.Allocator, slot: core.Slot, parent: ?core.Slot, bank_hash: core.Hash) ForkNode {
        return .{
            .slot = slot,
            .parent = parent,
            .bank_hash = bank_hash,
            .direct_stake = 0,
            .cumulative_stake = 0,
            .children = std.ArrayList(core.Slot).init(allocator),
            .is_finalized = false,
            .is_confirmed = false,
        };
    }
    
    pub fn deinit(self: *ForkNode) void {
        self.children.deinit();
    }
};

/// Fork choice state
pub const ForkChoice = struct {
    allocator: std.mem.Allocator,
    
    /// Fork tree: slot -> ForkNode
    forks: std.AutoHashMap(core.Slot, ForkNode),
    
    /// Stake weight per slot
    slot_stakes: std.AutoHashMap(core.Slot, u64),
    
    /// Voter stake map: voter pubkey -> stake amount
    voter_stakes: std.AutoHashMap(core.Pubkey, u64),
    
    /// Best slot by stake (heaviest subtree)
    best_slot: ?core.Slot,
    
    /// Current root (finalized)
    root_slot: core.Slot,
    
    /// Total stake in the epoch
    total_stake: u64,
    
    /// Threshold for supermajority (2/3)
    supermajority_threshold: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .forks = std.AutoHashMap(core.Slot, ForkNode).init(allocator),
            .slot_stakes = std.AutoHashMap(core.Slot, u64).init(allocator),
            .voter_stakes = std.AutoHashMap(core.Pubkey, u64).init(allocator),
            .best_slot = null,
            .root_slot = 0,
            .total_stake = 0,
            .supermajority_threshold = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.forks.valueIterator();
        while (it.next()) |node| {
            node.deinit();
        }
        self.forks.deinit();
        self.slot_stakes.deinit();
        self.voter_stakes.deinit();
    }
    
    /// Set total stake for the epoch (needed for supermajority calculation)
    pub fn setTotalStake(self: *Self, total: u64) void {
        self.total_stake = total;
        self.supermajority_threshold = (total * 2) / 3 + 1;
    }
    
    /// Register a validator's stake weight
    pub fn registerVoter(self: *Self, voter: core.Pubkey, stake: u64) !void {
        try self.voter_stakes.put(voter, stake);
    }
    
    /// Add a new fork to the tree
    pub fn addFork(self: *Self, slot: core.Slot, parent: ?core.Slot, bank_hash: core.Hash) !void {
        if (self.forks.contains(slot)) return; // Already exists
        
        const node = ForkNode.init(self.allocator, slot, parent, bank_hash);
        try self.forks.put(slot, node);
        
        // Add to parent's children
        if (parent) |p| {
            if (self.forks.getPtr(p)) |parent_node| {
                try parent_node.children.append(slot);
            }
        }
    }

    /// Process a vote and update fork choice
    pub fn onVote(self: *Self, vote_info: *const Vote) !void {
        try self.onVoteWithVoter(vote_info, core.Pubkey{ .data = [_]u8{0} ** 32 });
    }
    
    /// Process a vote with known voter identity
    pub fn onVoteWithVoter(self: *Self, vote_info: *const Vote, voter: core.Pubkey) !void {
        // Get stake for voter (default to 1 if not registered)
        const stake: u64 = self.voter_stakes.get(voter) orelse 1;

        // Add slot to forks if not present
        if (!self.forks.contains(vote_info.slot)) {
            // Assume parent is slot-1 (simplified)
            const parent = if (vote_info.slot > 0) vote_info.slot - 1 else null;
            try self.addFork(vote_info.slot, parent, vote_info.hash);
        }

        // Update direct stake with overflow check
        if (self.forks.getPtr(vote_info.slot)) |node| {
            node.direct_stake = std.math.add(u64, node.direct_stake, stake) catch {
                // On overflow, saturate at max value
                node.direct_stake = std.math.maxInt(u64);
            };
        }

        // Update slot_stakes map with overflow check
        const entry = try self.slot_stakes.getOrPut(vote_info.slot);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* = std.math.add(u64, entry.value_ptr.*, stake) catch {
            // On overflow, saturate at max value
            entry.value_ptr.* = std.math.maxInt(u64);
        };

        // Propagate stake up the tree
        try self.propagateStake(vote_info.slot, stake);

        // Recompute best slot using heaviest subtree
        self.recomputeBestSlot();
        
        // Check for newly confirmed/finalized slots
        try self.checkConfirmation(vote_info.slot);
    }
    
    /// Propagate stake weight up the fork tree
    fn propagateStake(self: *Self, slot: core.Slot, stake: u64) !void {
        var current = slot;
        
        while (true) {
            if (self.forks.getPtr(current)) |node| {
                // Overflow-safe addition
                node.cumulative_stake = std.math.add(u64, node.cumulative_stake, stake) catch {
                    node.cumulative_stake = std.math.maxInt(u64);
                };
                
                if (node.parent) |p| {
                    current = p;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }
    
    /// Recompute the best slot using heaviest subtree rule
    fn recomputeBestSlot(self: *Self) void {
        // Start from root and follow heaviest child
        var current = self.root_slot;
        
        while (true) {
            if (self.forks.get(current)) |node| {
                if (node.children.items.len == 0) {
                    // Leaf node
                    break;
                }
                
                // Find heaviest child
                var heaviest: ?core.Slot = null;
                var heaviest_stake: u64 = 0;
                
                for (node.children.items) |child_slot| {
                    if (self.forks.get(child_slot)) |child| {
                        if (child.cumulative_stake > heaviest_stake) {
                            heaviest_stake = child.cumulative_stake;
                            heaviest = child_slot;
                        }
                    }
                }
                
                if (heaviest) |h| {
                    current = h;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        
        self.best_slot = current;
    }
    
    /// Check if a slot has become confirmed or finalized
    fn checkConfirmation(self: *Self, slot: core.Slot) !void {
        if (self.forks.getPtr(slot)) |node| {
            // Check supermajority
            if (node.cumulative_stake >= self.supermajority_threshold) {
                node.is_confirmed = true;
                
                // Check if we can finalize (advance root)
                // A slot is finalized when it's confirmed and all ancestors are finalized
                if (slot > self.root_slot + 32) { // Conservative: wait 32 slots after confirmation
                    try self.maybeAdvanceRoot(slot);
                }
            }
        }
    }
    
    /// Advance root if conditions are met
    fn maybeAdvanceRoot(self: *Self, confirmed_slot: core.Slot) !void {
        // Find the highest slot that:
        // 1. Has supermajority confirmation
        // 2. Is an ancestor of the confirmed slot
        // 3. Is old enough (32 slots behind tip)
        
        var new_root = self.root_slot;
        var current = confirmed_slot;
        
        while (current > self.root_slot) {
            if (self.forks.get(current)) |node| {
                if (node.is_confirmed and current < confirmed_slot - 32) {
                    new_root = current;
                }
                if (node.parent) |p| {
                    current = p;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        
        if (new_root > self.root_slot) {
            self.root_slot = new_root;
            // Prune old forks
            try self.pruneBelowRoot();
        }
    }
    
    /// Prune forks below the root
    fn pruneBelowRoot(self: *Self) !void {
        var to_remove = std.ArrayList(core.Slot).init(self.allocator);
        defer to_remove.deinit();
        
        var it = self.forks.keyIterator();
        while (it.next()) |slot| {
            if (slot.* < self.root_slot) {
                try to_remove.append(slot.*);
            }
        }
        
        for (to_remove.items) |slot| {
            if (self.forks.fetchRemove(slot)) |kv| {
                var node = kv.value;
                node.deinit();
            }
            _ = self.slot_stakes.remove(slot);
        }
    }

    /// Get the best slot to build on
    pub fn bestSlot(self: *const Self) ?core.Slot {
        return self.best_slot;
    }

    /// Get stake for a slot
    pub fn stakeForSlot(self: *const Self, slot: core.Slot) u64 {
        return self.slot_stakes.get(slot) orelse 0;
    }

    /// Check if a slot has supermajority stake
    pub fn hasSupermajority(self: *const Self, slot: core.Slot) bool {
        if (self.total_stake == 0) return false;
        const slot_stake = self.stakeForSlot(slot);
        return slot_stake >= self.supermajority_threshold;
    }
    
    /// Check if a slot is confirmed
    pub fn isConfirmed(self: *const Self, slot: core.Slot) bool {
        if (self.forks.get(slot)) |node| {
            return node.is_confirmed;
        }
        return false;
    }
    
    /// Check if a slot is finalized (rooted)
    pub fn isFinalized(self: *const Self, slot: core.Slot) bool {
        return slot <= self.root_slot;
    }
    
    /// Get root slot
    pub fn getRoot(self: *const Self) core.Slot {
        return self.root_slot;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "fork choice init" {
    var fc = ForkChoice.init(std.testing.allocator);
    defer fc.deinit();

    try std.testing.expect(fc.bestSlot() == null);
}

test "fork choice on vote" {
    var fc = ForkChoice.init(std.testing.allocator);
    defer fc.deinit();

    const vote1 = Vote{
        .slot = 100,
        .hash = core.Hash.ZERO,
        .timestamp = 0,
        .signature = core.Signature{ .data = [_]u8{0} ** 64 },
    };

    try fc.onVote(&vote1);
    try std.testing.expectEqual(@as(?core.Slot, 100), fc.bestSlot());
}

