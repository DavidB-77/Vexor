//! Vexor Consensus Module
//!
//! Implements Solana consensus mechanisms:
//! - Tower BFT (current production consensus)
//! - Alpenglow (upcoming consensus upgrade) - placeholder
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────┐
//! │                   CONSENSUS LAYER                       │
//! ├───────────────────────┬─────────────────────────────────┤
//! │      TOWER BFT        │        ALPENGLOW (future)       │
//! │   ───────────────     │       ─────────────────         │
//! │   Vote lockout        │       Votor (voting)            │
//! │   Fork choice         │       Rotor (dissemination)     │
//! │   Optimistic confirm  │       BLS signatures            │
//! └───────────────────────┴─────────────────────────────────┘

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const tower = @import("tower.zig");
pub const fork_choice = @import("fork_choice.zig");
pub const vote = @import("vote.zig");
pub const vote_tx = @import("vote_tx.zig");
pub const leader_schedule = @import("leader_schedule.zig");
pub const poh = @import("poh.zig");
pub const poh_verifier = @import("poh_verifier.zig");
pub const tower_storage = @import("tower_storage.zig");

// Alpenglow is behind a feature flag
pub const alpenglow = if (build_options.alpenglow_enabled)
    @import("alpenglow.zig")
else
    @import("alpenglow_stub.zig");

// Re-export main types
pub const TowerBft = tower.TowerBft;
pub const ForkChoice = fork_choice.ForkChoice;
pub const Vote = vote.Vote;
pub const PohVerifier = poh_verifier.PohVerifier;
pub const PohRecorder = poh_verifier.PohRecorder;
pub const TowerStorage = tower_storage.TowerStorage;
pub const LeaderScheduleGenerator = leader_schedule.LeaderScheduleGenerator;
pub const LeaderScheduleCache = leader_schedule.LeaderScheduleCache;

/// Consensus engine interface
pub const ConsensusEngine = struct {
    allocator: std.mem.Allocator,
    tower: TowerBft,
    fork_choice_strategy: ForkChoice,
    current_slot: std.atomic.Value(u64),
    root_slot: std.atomic.Value(u64),
    
    /// Validator identity pubkey
    identity: core.Pubkey,
    
    /// Vote account pubkey
    vote_account: core.Pubkey,
    
    /// Identity keypair secret (for signing votes)
    identity_secret: ?[64]u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, identity: core.Pubkey) !*Self {
        const engine = try allocator.create(Self);
        engine.* = .{
            .allocator = allocator,
            .tower = try TowerBft.init(allocator, identity),
            .fork_choice_strategy = ForkChoice.init(allocator),
            .current_slot = std.atomic.Value(u64).init(0),
            .root_slot = std.atomic.Value(u64).init(0),
            .identity = identity,
            .vote_account = core.Pubkey{ .data = [_]u8{0} ** 32 }, // Set via setVoteAccount
            .identity_secret = null,
        };
        return engine;
    }
    
    /// Set the vote account
    pub fn setVoteAccount(self: *Self, vote_account: core.Pubkey) void {
        self.vote_account = vote_account;
    }
    
    /// Set the identity secret for signing
    pub fn setIdentitySecret(self: *Self, secret: [64]u8) void {
        self.identity_secret = secret;
    }

    pub fn deinit(self: *Self) void {
        self.tower.deinit();
        self.fork_choice_strategy.deinit();
        self.allocator.destroy(self);
    }

    /// Process a new slot
    pub fn onSlot(self: *Self, slot: core.Slot) !void {
        self.current_slot.store(slot, .seq_cst);
        // TODO: Slot processing logic
    }

    /// Process a vote from another validator
    pub fn onVote(self: *Self, vote_info: *const Vote) !void {
        try self.tower.recordExternalVote(vote_info);
        try self.fork_choice_strategy.onVote(vote_info);
    }

    /// Generate our vote for a slot
    pub fn vote(self: *Self, slot: core.Slot, bank_hash: core.Hash) !Vote {
        return self.tower.vote(slot, bank_hash);
    }

    /// Get the best fork to build on
    pub fn selectFork(self: *Self) ?core.Slot {
        return self.fork_choice_strategy.bestSlot();
    }

    /// Check if a slot is finalized (rooted)
    pub fn isRooted(self: *Self, slot: core.Slot) bool {
        return slot <= self.root_slot.load(.seq_cst);
    }
};

test {
    std.testing.refAllDecls(@This());
}

