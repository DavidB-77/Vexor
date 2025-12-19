//! Vexor Vote Transaction Module
//!
//! Creates and submits vote transactions for consensus.

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const vote_mod = @import("vote.zig");

const Vote = vote_mod.Vote;

/// Vote instruction types
pub const VoteInstruction = enum(u32) {
    /// Initialize a vote account
    initialize_account = 0,
    /// Authorize a key to vote or withdraw
    authorize = 1,
    /// Vote on a slot
    vote = 2,
    /// Withdraw from vote account
    withdraw = 3,
    /// Update validator identity
    update_validator_identity = 4,
    /// Update commission
    update_commission = 5,
    /// Vote with switch proof
    vote_switch = 6,
    /// Authorize with checked
    authorize_checked = 7,
    /// Update vote state
    update_vote_state = 8,
    /// Update vote state switch
    update_vote_state_switch = 9,
    /// Authorize with seed
    authorize_with_seed = 10,
    /// Withdraw with seed
    withdraw_with_seed = 11,
    /// Compact update vote state
    compact_update_vote_state = 12,
    /// Compact update vote state switch
    compact_update_vote_state_switch = 13,
};

/// Vote transaction builder
pub const VoteTransactionBuilder = struct {
    allocator: std.mem.Allocator,

    /// Validator identity keypair
    identity_pubkey: core.Pubkey,
    identity_secret: ?[64]u8,

    /// Vote account pubkey
    vote_account: core.Pubkey,

    /// Authorized voter (if different from identity)
    authorized_voter: ?core.Pubkey,
    authorized_voter_secret: ?[64]u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        identity_pubkey: core.Pubkey,
        vote_account: core.Pubkey,
    ) Self {
        return .{
            .allocator = allocator,
            .identity_pubkey = identity_pubkey,
            .identity_secret = null,
            .vote_account = vote_account,
            .authorized_voter = null,
            .authorized_voter_secret = null,
        };
    }

    /// Set identity secret key
    pub fn setIdentitySecret(self: *Self, secret: [64]u8) void {
        self.identity_secret = secret;
    }

    /// Set authorized voter
    pub fn setAuthorizedVoter(self: *Self, pubkey: core.Pubkey, secret: ?[64]u8) void {
        self.authorized_voter = pubkey;
        self.authorized_voter_secret = secret;
    }

    /// Build a vote transaction
    pub fn buildVoteTransaction(
        self: *Self,
        votes: []const Vote,
        recent_blockhash: core.Hash,
    ) !VoteTransaction {
        // Build vote state update instruction data
        var ix_data = std.ArrayList(u8).init(self.allocator);
        defer ix_data.deinit();

        // Instruction discriminator (compact_update_vote_state = 12)
        try ix_data.appendSlice(&std.mem.toBytes(@as(u32, 12)));

        // Lockout slots
        try ix_data.append(@intCast(votes.len)); // compact-u16 for small values
        for (votes) |v| {
            try ix_data.appendSlice(&std.mem.toBytes(v.slot));
            try ix_data.append(1); // confirmation count
        }

        // Root (optional)
        try ix_data.append(0); // None

        // Hash
        if (votes.len > 0) {
            try ix_data.append(1); // Some
            try ix_data.appendSlice(&votes[votes.len - 1].hash.data);
        } else {
            try ix_data.append(0); // None
        }

        // Timestamp (optional)
        try ix_data.append(1); // Some
        const timestamp = std.time.timestamp();
        try ix_data.appendSlice(&std.mem.toBytes(timestamp));

        const voter = self.authorized_voter orelse self.identity_pubkey;

        return VoteTransaction{
            .vote_account = self.vote_account,
            .authorized_voter = voter,
            .recent_blockhash = recent_blockhash,
            .instruction_data = try ix_data.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Sign and serialize a vote transaction
    pub fn signAndSerialize(
        self: *Self,
        tx: *const VoteTransaction,
    ) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        // Build message first
        var message = std.ArrayList(u8).init(self.allocator);
        defer message.deinit();

        // Message header
        try message.append(2); // num_required_signatures
        try message.append(0); // num_readonly_signed_accounts
        try message.append(2); // num_readonly_unsigned_accounts

        // Account keys (compact-u16 length)
        try message.append(4); // 4 accounts

        // 0: Vote authority (signer, writable)
        try message.appendSlice(&tx.authorized_voter.data);

        // 1: Vote account (writable)
        try message.appendSlice(&tx.vote_account.data);

        // 2: Slot hashes sysvar (readonly)
        const slot_hashes_sysvar = [_]u8{ 0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x6b, 0xcf, 0xbf, 0x67, 0x3a, 0x05, 0x82, 0x0d, 0x96, 0x5f, 0x86, 0x10, 0xc9, 0xea, 0x8e, 0xee, 0xfb, 0xdd, 0x17, 0x23, 0xbd, 0x00, 0x00, 0x00, 0x00 };
        try message.appendSlice(&slot_hashes_sysvar);

        // 3: Clock sysvar (readonly)
        const clock_sysvar = [_]u8{ 0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x6b, 0xcf, 0xbf, 0x67, 0x3a, 0x05, 0x82, 0x0d, 0x96, 0x5f, 0x86, 0x10, 0xc9, 0xea, 0x8e, 0xee, 0xfb, 0xdd, 0x17, 0x23, 0xbc, 0x00, 0x00, 0x00, 0x00 };
        try message.appendSlice(&clock_sysvar);

        // Recent blockhash
        try message.appendSlice(&tx.recent_blockhash.data);

        // Instructions (compact-u16 length)
        try message.append(1); // 1 instruction

        // Instruction
        try message.append(1); // program_id_index = vote program
        try message.append(2); // num accounts
        try message.append(1); // vote account index
        try message.append(0); // authority index

        // Instruction data
        const data_len: u8 = @intCast(tx.instruction_data.len);
        try message.append(data_len);
        try message.appendSlice(tx.instruction_data);

        // Now build full transaction

        // Signature count
        try result.append(2);

        // Sign the message
        if (self.identity_secret) |secret| {
            const sig = crypto.ed25519.sign(secret, message.items);
            try result.appendSlice(&sig.data);
        } else {
            // Placeholder signature
            try result.appendSlice(&([_]u8{0} ** 64));
        }

        // Second signature (if needed)
        if (self.authorized_voter_secret) |secret| {
            const sig = crypto.ed25519.sign(secret, message.items);
            try result.appendSlice(&sig.data);
        } else {
            try result.appendSlice(&([_]u8{0} ** 64));
        }

        // Append message
        try result.appendSlice(message.items);

        return try result.toOwnedSlice();
    }
};

/// Built vote transaction (before signing)
pub const VoteTransaction = struct {
    vote_account: core.Pubkey,
    authorized_voter: core.Pubkey,
    recent_blockhash: core.Hash,
    instruction_data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VoteTransaction) void {
        self.allocator.free(self.instruction_data);
    }
};

/// Tower sync transaction for updating vote state
pub const TowerSync = struct {
    /// Current lockouts
    lockouts: []const vote_mod.Lockout,

    /// Root slot
    root: ?core.Slot,

    /// Latest voted hash
    hash: core.Hash,

    /// Timestamp
    timestamp: i64,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "vote transaction builder" {
    const identity = core.Pubkey{ .data = [_]u8{1} ** 32 };
    const vote_account = core.Pubkey{ .data = [_]u8{2} ** 32 };

    const builder = VoteTransactionBuilder.init(std.testing.allocator, identity, vote_account);
    _ = builder;
}

