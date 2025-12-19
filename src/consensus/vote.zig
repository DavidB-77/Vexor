//! Vexor Vote Types
//!
//! Vote structures and lockout calculations for consensus.

const std = @import("std");
const core = @import("../core/root.zig");

/// A vote for a slot
pub const Vote = struct {
    slot: core.Slot,
    hash: core.Hash,
    timestamp: i64,
    signature: core.Signature,
};

/// Vote lockout state
pub const Lockout = struct {
    slot: core.Slot,
    confirmation_count: u32,

    const Self = @This();

    /// Calculate lockout duration (exponential: 2^confirmation_count)
    pub fn lockoutDuration(self: *const Self) u64 {
        if (self.confirmation_count >= 64) return std.math.maxInt(u64);
        return @as(u64, 1) << @intCast(self.confirmation_count);
    }

    /// Check if lockout has expired for a given slot
    pub fn isExpired(self: *const Self, current_slot: core.Slot) bool {
        return current_slot >= self.slot + self.lockoutDuration();
    }

    /// Slot at which this lockout expires
    pub fn expirationSlot(self: *const Self) u64 {
        const duration = self.lockoutDuration();
        if (duration == std.math.maxInt(u64)) return std.math.maxInt(u64);
        return self.slot + duration;
    }
};

/// Vote transaction
pub const VoteTransaction = struct {
    /// Vote account being updated
    vote_account: core.Pubkey,
    /// Slots being voted on (can batch)
    slots: []const core.Slot,
    /// Bank hash for the latest slot
    hash: core.Hash,
    /// Timestamp
    timestamp: ?i64,
};

/// Vote state stored on-chain
pub const VoteStateVersions = union(enum) {
    v0_23_5: VoteState0_23_5,
    current: VoteStateCurrent,
};

pub const VoteState0_23_5 = struct {
    node_pubkey: core.Pubkey,
    authorized_voter: core.Pubkey,
    authorized_voter_epoch: core.Epoch,
    prior_voters: [32]struct { pubkey: core.Pubkey, epoch: core.Epoch },
    authorized_withdrawer: core.Pubkey,
    commission: u8,
    votes: std.BoundedArray(Lockout, 31),
    root_slot: ?core.Slot,
    epoch_credits: std.ArrayList(EpochCredit),
    last_timestamp: BlockTimestamp,
};

pub const VoteStateCurrent = struct {
    node_pubkey: core.Pubkey,
    authorized_withdrawer: core.Pubkey,
    commission: u8,
    votes: std.BoundedArray(LandedVote, 31),
    root_slot: ?core.Slot,
    authorized_voters: AuthorizedVoters,
    prior_voters: PriorVoters,
    epoch_credits: std.ArrayList(EpochCredit),
    last_timestamp: BlockTimestamp,
};

pub const LandedVote = struct {
    latency: u8,
    lockout: Lockout,
};

pub const EpochCredit = struct {
    epoch: core.Epoch,
    credits: u64,
    prev_credits: u64,
};

pub const BlockTimestamp = struct {
    slot: core.Slot,
    timestamp: i64,
};

pub const AuthorizedVoters = struct {
    authorized_voters: std.AutoHashMap(core.Epoch, core.Pubkey),
};

pub const PriorVoters = struct {
    buf: [32]struct { pubkey: core.Pubkey, epoch_start: core.Epoch, epoch_end: core.Epoch },
    idx: usize,
    is_empty: bool,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "lockout duration" {
    const lockout = Lockout{
        .slot = 100,
        .confirmation_count = 5,
    };

    try std.testing.expectEqual(@as(u64, 32), lockout.lockoutDuration()); // 2^5
    try std.testing.expectEqual(@as(u64, 132), lockout.expirationSlot()); // 100 + 32
}

test "lockout expiration" {
    const lockout = Lockout{
        .slot = 100,
        .confirmation_count = 3, // Duration = 8
    };

    try std.testing.expect(!lockout.isExpired(100));
    try std.testing.expect(!lockout.isExpired(107));
    try std.testing.expect(lockout.isExpired(108));
    try std.testing.expect(lockout.isExpired(200));
}

