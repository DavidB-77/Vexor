//! Vexor Fork Manager
//!
//! Manages the fork tree during slot replay.
//! Tracks multiple concurrent forks and determines the heaviest/best fork.
//!
//! Key responsibilities:
//! - Track all active forks
//! - Calculate fork weights based on stake
//! - Determine best fork for voting
//! - Handle fork switching
//! - Prune finalized forks

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const bank_mod = @import("bank.zig");

const Bank = bank_mod.Bank;

/// Fork entry in the fork tree
pub const ForkEntry = struct {
    slot: core.Slot,
    parent_slot: ?core.Slot,
    bank: *Bank,
    stake_weight: u64,
    vote_count: u32,
    status: ForkStatus,
    created_at_ns: i128,
    children: std.ArrayList(core.Slot),

    const Self = @This();

    pub fn init(allocator: Allocator, slot: core.Slot, parent: ?core.Slot, bank: *Bank) !Self {
        return Self{
            .slot = slot,
            .parent_slot = parent,
            .bank = bank,
            .stake_weight = 0,
            .vote_count = 0,
            .status = .processing,
            .created_at_ns = std.time.nanoTimestamp(),
            .children = std.ArrayList(core.Slot).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }

    pub fn addChild(self: *Self, child_slot: core.Slot) !void {
        try self.children.append(child_slot);
    }

    pub fn isFrozen(self: *const Self) bool {
        return self.bank.is_frozen;
    }
};

pub const ForkStatus = enum {
    /// Fork is being processed
    processing,
    /// Fork is complete but not voted
    complete,
    /// Fork has been voted on
    voted,
    /// Fork is confirmed (supermajority)
    confirmed,
    /// Fork is finalized (rooted)
    finalized,
    /// Fork was orphaned (not in best chain)
    orphaned,
};

/// Fork manager for tracking the fork tree
pub const ForkManager = struct {
    allocator: Allocator,

    /// All forks indexed by slot
    forks: std.AutoHashMap(core.Slot, ForkEntry),

    /// Current root slot
    root_slot: core.Slot,

    /// Best fork tip (heaviest by stake weight)
    best_slot: core.Slot,

    /// Voted slots
    voted_slots: std.AutoHashMap(core.Slot, void),

    /// Fork weights cache
    weight_cache: std.AutoHashMap(core.Slot, u64),

    /// Statistics
    stats: ForkStats,

    const Self = @This();

    pub fn init(allocator: Allocator, root_slot: core.Slot) Self {
        return Self{
            .allocator = allocator,
            .forks = std.AutoHashMap(core.Slot, ForkEntry).init(allocator),
            .root_slot = root_slot,
            .best_slot = root_slot,
            .voted_slots = std.AutoHashMap(core.Slot, void).init(allocator),
            .weight_cache = std.AutoHashMap(core.Slot, u64).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.forks.valueIterator();
        while (iter.next()) |entry| {
            entry.deinit();
        }
        self.forks.deinit();
        self.voted_slots.deinit();
        self.weight_cache.deinit();
    }

    /// Add a new fork
    pub fn addFork(self: *Self, slot: core.Slot, parent: ?core.Slot, bank: *Bank) !void {
        // Create fork entry
        const entry = try ForkEntry.init(self.allocator, slot, parent, bank);
        try self.forks.put(slot, entry);

        // Update parent's children
        if (parent) |p| {
            if (self.forks.getPtr(p)) |parent_entry| {
                try parent_entry.addChild(slot);
            }
        }

        self.stats.forks_created += 1;

        // Invalidate weight cache for this branch
        self.weight_cache.clearRetainingCapacity();
    }

    /// Mark a fork as complete
    pub fn completeFork(self: *Self, slot: core.Slot) !void {
        if (self.forks.getPtr(slot)) |entry| {
            entry.status = .complete;
        }

        // Recalculate best fork
        try self.recalculateBestFork();
    }

    /// Record a vote for a slot
    pub fn recordVote(self: *Self, slot: core.Slot, stake: u64) !void {
        if (self.forks.getPtr(slot)) |entry| {
            entry.vote_count += 1;
            entry.stake_weight += stake;

            // Check for confirmation (2/3 stake)
            // Would need total stake info for this

            self.weight_cache.clearRetainingCapacity();
        }

        try self.voted_slots.put(slot, {});

        // Update best fork
        try self.recalculateBestFork();
    }

    /// Recalculate the best (heaviest) fork
    fn recalculateBestFork(self: *Self) !void {
        var best_slot = self.root_slot;
        var best_weight: u64 = 0;

        var iter = self.forks.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.status == .orphaned) continue;

            const weight = try self.getForkWeight(kv.key_ptr.*);
            if (weight > best_weight) {
                best_weight = weight;
                best_slot = kv.key_ptr.*;
            }
        }

        if (best_slot != self.best_slot) {
            self.stats.fork_switches += 1;
            self.best_slot = best_slot;
        }
    }

    /// Get weight of a fork (sum of stake votes on this fork and descendants)
    pub fn getForkWeight(self: *Self, slot: core.Slot) !u64 {
        // Check cache
        if (self.weight_cache.get(slot)) |cached| {
            return cached;
        }

        var weight: u64 = 0;

        // Add this slot's weight
        if (self.forks.get(slot)) |entry| {
            weight = entry.stake_weight;

            // Add children's weights
            for (entry.children.items) |child| {
                weight += try self.getForkWeight(child);
            }
        }

        try self.weight_cache.put(slot, weight);
        return weight;
    }

    /// Get the best fork to build on
    pub fn getBestFork(self: *const Self) core.Slot {
        return self.best_slot;
    }

    /// Get fork entry
    pub fn getFork(self: *Self, slot: core.Slot) ?*ForkEntry {
        return self.forks.getPtr(slot);
    }

    /// Check if slot is on the best fork chain
    pub fn isOnBestFork(self: *Self, slot: core.Slot) bool {
        var current = self.best_slot;
        while (current >= slot) {
            if (current == slot) return true;

            if (self.forks.get(current)) |entry| {
                if (entry.parent_slot) |parent| {
                    current = parent;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        return false;
    }

    /// Set new root (finalized slot)
    pub fn setRoot(self: *Self, new_root: core.Slot) !void {
        if (new_root <= self.root_slot) return;

        // Mark all slots not in root's ancestry as orphaned
        var slots_to_orphan = std.ArrayList(core.Slot).init(self.allocator);
        defer slots_to_orphan.deinit();

        var iter = self.forks.keyIterator();
        while (iter.next()) |slot| {
            if (slot.* < new_root and !self.isAncestorOf(slot.*, new_root)) {
                try slots_to_orphan.append(slot.*);
            }
        }

        // Orphan and remove old forks
        for (slots_to_orphan.items) |slot| {
            if (self.forks.getPtr(slot)) |entry| {
                entry.status = .orphaned;
                self.stats.forks_orphaned += 1;
            }
        }

        // Prune very old forks
        try self.pruneOldForks(new_root);

        self.root_slot = new_root;

        // Mark root as finalized
        if (self.forks.getPtr(new_root)) |entry| {
            entry.status = .finalized;
        }
    }

    fn isAncestorOf(self: *Self, ancestor: core.Slot, descendant: core.Slot) bool {
        var current = descendant;
        while (current > ancestor) {
            if (self.forks.get(current)) |entry| {
                if (entry.parent_slot) |parent| {
                    current = parent;
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }
        return current == ancestor;
    }

    /// Prune forks older than root
    fn pruneOldForks(self: *Self, root: core.Slot) !void {
        var slots_to_remove = std.ArrayList(core.Slot).init(self.allocator);
        defer slots_to_remove.deinit();

        var iter = self.forks.iterator();
        while (iter.next()) |kv| {
            // Keep forks for a while after they're orphaned (for debugging)
            if (kv.key_ptr.* + 1000 < root) {
                try slots_to_remove.append(kv.key_ptr.*);
            }
        }

        for (slots_to_remove.items) |slot| {
            if (self.forks.fetchRemove(slot)) |removed| {
                var entry = removed.value;
                entry.deinit();
                self.stats.forks_pruned += 1;
            }
        }
    }

    /// Get fork count
    pub fn forkCount(self: *const Self) usize {
        return self.forks.count();
    }

    /// Get active (non-orphaned) fork count
    pub fn activeForkCount(self: *Self) usize {
        var count: usize = 0;
        var iter = self.forks.valueIterator();
        while (iter.next()) |entry| {
            if (entry.status != .orphaned) {
                count += 1;
            }
        }
        return count;
    }
};

/// Fork statistics
pub const ForkStats = struct {
    forks_created: u64 = 0,
    forks_orphaned: u64 = 0,
    forks_pruned: u64 = 0,
    fork_switches: u64 = 0,
};

/// Fork choice result
pub const ForkChoice = struct {
    slot: core.Slot,
    weight: u64,
    is_new_best: bool,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "fork manager init" {
    const allocator = std.testing.allocator;

    var manager = ForkManager.init(allocator, 100);
    defer manager.deinit();

    try std.testing.expectEqual(@as(core.Slot, 100), manager.root_slot);
    try std.testing.expectEqual(@as(core.Slot, 100), manager.best_slot);
}

test "fork weight calculation" {
    const allocator = std.testing.allocator;

    var manager = ForkManager.init(allocator, 0);
    defer manager.deinit();

    // Create a simple chain: 0 -> 1 -> 2
    // Would need mock banks for full test

    try std.testing.expectEqual(@as(usize, 0), manager.forkCount());
}

