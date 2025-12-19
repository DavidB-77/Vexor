//! Vexor Tower BFT Implementation
//!
//! Tower BFT is Solana's optimized PBFT-like consensus with:
//! - Exponential lockouts for vote stability
//! - Optimistic confirmation
//! - Fork choice based on stake-weighted votes

const std = @import("std");
const core = @import("../core/root.zig");
const vote_mod = @import("vote.zig");

const Vote = vote_mod.Vote;
const Lockout = vote_mod.Lockout;

/// Maximum vote history depth
pub const MAX_LOCKOUT_HISTORY: usize = 31;

/// Tower BFT state machine
pub const TowerBft = struct {
    allocator: std.mem.Allocator,
    identity: core.Pubkey,
    identity_keypair: ?core.Keypair,  // For signing votes
    vote_state: VoteState,
    last_vote: ?Vote,
    last_vote_slot: core.Slot,

    const Self = @This();

    pub const VoteState = struct {
        votes: std.BoundedArray(Lockout, MAX_LOCKOUT_HISTORY),
        root_slot: ?core.Slot,
        epoch: core.Epoch,
        credits: u64,

        pub fn init() VoteState {
            return .{
                .votes = std.BoundedArray(Lockout, MAX_LOCKOUT_HISTORY).init(0) catch unreachable,
                .root_slot = null,
                .epoch = 0,
                .credits = 0,
            };
        }

        /// Get the last voted slot
        pub fn lastVotedSlot(self: *const VoteState) ?core.Slot {
            if (self.votes.len == 0) return null;
            return self.votes.get(self.votes.len - 1).slot;
        }

        /// Check if we can vote for a slot
        pub fn canVote(self: *const VoteState, slot: core.Slot) bool {
            // Must be greater than last voted slot
            const last = self.lastVotedSlot() orelse return true;
            if (slot <= last) return false;

            // Check lockout expiration
            for (self.votes.slice()) |lockout| {
                if (!lockout.isExpired(slot)) {
                    // Still locked out, can only vote if this extends the fork
                    if (slot <= lockout.slot) return false;
                }
            }

            return true;
        }

        /// Record a vote
        pub fn recordVote(self: *VoteState, slot: core.Slot) void {
            // Pop expired lockouts
            while (self.votes.len > 0) {
                const last = self.votes.get(self.votes.len - 1);
                if (last.isExpired(slot)) {
                    _ = self.votes.pop();
                } else {
                    break;
                }
            }

            // Double lockouts for votes that are being confirmed
            for (self.votes.slice()) |*lockout| {
                lockout.confirmation_count += 1;
            }

            // Add new vote with lockout of 2
            self.votes.append(.{
                .slot = slot,
                .confirmation_count = 1,
            }) catch {
                // Stack is full, root the oldest vote
                if (self.votes.len > 0) {
                    self.root_slot = self.votes.get(0).slot;
                    _ = self.votes.orderedRemove(0);
                    self.votes.append(.{
                        .slot = slot,
                        .confirmation_count = 1,
                    }) catch unreachable;
                }
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, identity: core.Pubkey) !TowerBft {
        return .{
            .allocator = allocator,
            .identity = identity,
            .identity_keypair = null,
            .vote_state = VoteState.init(),
            .last_vote = null,
            .last_vote_slot = 0,
        };
    }
    
    /// Initialize with keypair for vote signing
    pub fn initWithKeypair(allocator: std.mem.Allocator, keypair: core.Keypair) !TowerBft {
        return .{
            .allocator = allocator,
            .identity = keypair.public,
            .identity_keypair = keypair,
            .vote_state = VoteState.init(),
            .last_vote = null,
            .last_vote_slot = 0,
        };
    }
    
    /// Set keypair for vote signing
    pub fn setKeypair(self: *Self, keypair: core.Keypair) void {
        self.identity_keypair = keypair;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Generate a vote for a slot
    /// Note: timestamp is computed once per vote; if called frequently,
    /// consider passing in a cached timestamp for better performance
    pub fn vote(self: *Self, slot: core.Slot, bank_hash: core.Hash) !Vote {
        return self.voteWithTimestamp(slot, bank_hash, @as(i64, @intCast(std.time.timestamp())));
    }

    /// Generate a vote for a slot with a provided timestamp (avoids syscall)
    pub fn voteWithTimestamp(self: *Self, slot: core.Slot, bank_hash: core.Hash, timestamp: i64) !Vote {
        if (!self.vote_state.canVote(slot)) {
            return error.LockedOut;
        }

        self.vote_state.recordVote(slot);
        self.last_vote_slot = slot;

        // Build message to sign: [slot (8 bytes)][hash (32 bytes)][timestamp (8 bytes)]
        var msg_buf: [48]u8 = undefined;
        std.mem.writeInt(u64, msg_buf[0..8], slot, .little);
        @memcpy(msg_buf[8..40], &bank_hash.data);
        std.mem.writeInt(i64, msg_buf[40..48], timestamp, .little);
        
        // Sign the vote
        const signature = if (self.identity_keypair) |kp|
            kp.sign(&msg_buf)
        else
            core.Signature{ .data = [_]u8{0} ** 64 }; // Unsigned if no keypair

        const new_vote = Vote{
            .slot = slot,
            .hash = bank_hash,
            .timestamp = timestamp,
            .signature = signature,
        };

        self.last_vote = new_vote;
        return new_vote;
    }

    /// Record a vote from another validator
    pub fn recordExternalVote(self: *Self, external_vote: *const Vote) !void {
        _ = self;
        _ = external_vote;
        // TODO: Track external votes for fork choice
    }

    /// Get current root slot
    pub fn rootSlot(self: *const Self) ?core.Slot {
        return self.vote_state.root_slot;
    }

    /// Get threshold for optimistic confirmation
    pub fn optimisticConfirmationThreshold() f64 {
        return 0.67; // 2/3 + 1 stake
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "vote state init" {
    var state = TowerBft.VoteState.init();
    try std.testing.expect(state.lastVotedSlot() == null);
    try std.testing.expect(state.canVote(100));
}

test "vote lockout" {
    var state = TowerBft.VoteState.init();

    state.recordVote(100);
    try std.testing.expectEqual(@as(?core.Slot, 100), state.lastVotedSlot());

    // Can vote for higher slot
    try std.testing.expect(state.canVote(101));

    // Cannot vote for same or lower slot
    try std.testing.expect(!state.canVote(100));
    try std.testing.expect(!state.canVote(99));
}

test "tower bft" {
    const identity = core.Pubkey{ .data = [_]u8{1} ** 32 };
    var tower = try TowerBft.init(std.testing.allocator, identity);
    defer tower.deinit();

    const hash = core.Hash{ .data = [_]u8{2} ** 32 };
    const first_vote = try tower.vote(100, hash);
    try std.testing.expectEqual(@as(core.Slot, 100), first_vote.slot);

    // Should fail for same slot
    const result = tower.vote(100, hash);
    try std.testing.expectError(error.LockedOut, result);
}

