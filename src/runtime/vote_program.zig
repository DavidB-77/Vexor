//! Vexor Vote Program
//!
//! Implementation of the Solana Vote Program for consensus participation.
//! This program manages vote accounts and processes vote instructions.
//!
//! Key Structures:
//! - VoteState: Current state of a vote account
//! - Vote: Individual vote for a slot
//! - VoteInstruction: Instructions supported by the vote program
//!
//! Program ID: Vote111111111111111111111111111111111111111

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("../crypto/root.zig");

/// Vote program ID (base58: Vote111111111111111111111111111111111111111)
pub const VOTE_PROGRAM_ID: [32]u8 = .{
    0x07, 0x61, 0x48, 0x1d, 0x35, 0x7e, 0x6a, 0x6b,
    0xf2, 0x24, 0x08, 0x77, 0xe7, 0xa6, 0xee, 0x44,
    0x29, 0x5e, 0x69, 0x2e, 0x2a, 0x17, 0x47, 0xa5,
    0x87, 0xc8, 0xb6, 0x22, 0x8b, 0x9d, 0x00, 0x00,
};

/// Maximum recent votes in vote state
pub const MAX_LOCKOUT_HISTORY: usize = 31;

/// Maximum epoch credits in vote state
pub const MAX_EPOCH_CREDITS_HISTORY: usize = 64;

/// Slot hashes sysvar max entries
pub const MAX_SLOT_HASHES: usize = 512;

/// Vote instruction types
pub const VoteInstruction = union(enum) {
    /// Initialize a vote account
    InitializeAccount: InitializeAccountData,
    /// Vote on slots
    Vote: VoteData,
    /// Authorize a new voter
    Authorize: AuthorizeData,
    /// Withdraw from vote account
    Withdraw: WithdrawData,
    /// Update validator identity
    UpdateValidatorIdentity,
    /// Update commission
    UpdateCommission: u8,
    /// Vote switch (vote on a different fork)
    VoteSwitch: VoteSwitchData,
    /// Authorize with seed
    AuthorizeWithSeed: AuthorizeWithSeedData,
    /// Authorize checked (requires signer)
    AuthorizeChecked: AuthorizeCheckedData,
    /// Update vote state
    UpdateVoteState: VoteStateUpdateData,
    /// Update vote state switch
    UpdateVoteStateSwitch: VoteStateUpdateSwitchData,
    /// Compact update vote state
    CompactUpdateVoteState: CompactVoteStateUpdateData,
    /// Compact update vote state switch
    CompactUpdateVoteStateSwitch: CompactVoteStateUpdateSwitchData,
    /// Tower sync
    TowerSync: TowerSyncData,
    /// Tower sync switch
    TowerSyncSwitch: TowerSyncSwitchData,

    const Self = @This();

    /// Deserialize from instruction data
    pub fn deserialize(data: []const u8) !Self {
        if (data.len < 4) return error.InvalidData;

        const discriminant = std.mem.readInt(u32, data[0..4], .little);

        return switch (discriminant) {
            0 => .{ .InitializeAccount = try InitializeAccountData.deserialize(data[4..]) },
            2 => .{ .Vote = try VoteData.deserialize(data[4..]) },
            1 => .{ .Authorize = try AuthorizeData.deserialize(data[4..]) },
            3 => .{ .Withdraw = try WithdrawData.deserialize(data[4..]) },
            4 => .UpdateValidatorIdentity,
            5 => .{ .UpdateCommission = if (data.len > 4) data[4] else return error.InvalidData },
            6 => .{ .VoteSwitch = try VoteSwitchData.deserialize(data[4..]) },
            10 => .{ .AuthorizeWithSeed = try AuthorizeWithSeedData.deserialize(data[4..]) },
            11 => .{ .AuthorizeChecked = try AuthorizeCheckedData.deserialize(data[4..]) },
            12 => .{ .UpdateVoteState = try VoteStateUpdateData.deserialize(data[4..]) },
            13 => .{ .UpdateVoteStateSwitch = try VoteStateUpdateSwitchData.deserialize(data[4..]) },
            14 => .{ .CompactUpdateVoteState = try CompactVoteStateUpdateData.deserialize(data[4..]) },
            15 => .{ .CompactUpdateVoteStateSwitch = try CompactVoteStateUpdateSwitchData.deserialize(data[4..]) },
            16 => .{ .TowerSync = try TowerSyncData.deserialize(data[4..]) },
            17 => .{ .TowerSyncSwitch = try TowerSyncSwitchData.deserialize(data[4..]) },
            else => error.UnknownInstruction,
        };
    }

    /// Serialize to instruction data
    pub fn serialize(self: *const Self, writer: anytype) !void {
        switch (self.*) {
            .InitializeAccount => |data| {
                try writer.writeInt(u32, 0, .little);
                try data.serialize(writer);
            },
            .Vote => |data| {
                try writer.writeInt(u32, 2, .little);
                try data.serialize(writer);
            },
            .Authorize => |data| {
                try writer.writeInt(u32, 1, .little);
                try data.serialize(writer);
            },
            .Withdraw => |data| {
                try writer.writeInt(u32, 3, .little);
                try data.serialize(writer);
            },
            .UpdateValidatorIdentity => {
                try writer.writeInt(u32, 4, .little);
            },
            .UpdateCommission => |commission| {
                try writer.writeInt(u32, 5, .little);
                try writer.writeByte(commission);
            },
            .VoteSwitch => |data| {
                try writer.writeInt(u32, 6, .little);
                try data.serialize(writer);
            },
            .CompactUpdateVoteState => |data| {
                try writer.writeInt(u32, 14, .little);
                try data.serialize(writer);
            },
            .TowerSync => |data| {
                try writer.writeInt(u32, 16, .little);
                try data.serialize(writer);
            },
            else => return error.NotImplemented,
        }
    }
};

/// Initialize account instruction data
pub const InitializeAccountData = struct {
    node_pubkey: [32]u8,
    authorized_voter: [32]u8,
    authorized_withdrawer: [32]u8,
    commission: u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 97) return error.InvalidData;
        return @This(){
            .node_pubkey = data[0..32].*,
            .authorized_voter = data[32..64].*,
            .authorized_withdrawer = data[64..96].*,
            .commission = data[96],
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeAll(&self.node_pubkey);
        try writer.writeAll(&self.authorized_voter);
        try writer.writeAll(&self.authorized_withdrawer);
        try writer.writeByte(self.commission);
    }
};

/// Vote instruction data
pub const VoteData = struct {
    slots: []const u64,
    hash: [32]u8,
    timestamp: ?i64,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 8) return error.InvalidData;

        var offset: usize = 0;

        // Read slots array
        const num_slots = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        if (offset + num_slots * 8 + 32 > data.len) return error.InvalidData;

        // Skip slots (would need allocator for dynamic array)
        offset += @intCast(num_slots * 8);

        // Read hash
        const hash = data[offset..][0..32].*;
        offset += 32;

        // Read optional timestamp
        const timestamp: ?i64 = if (offset + 1 <= data.len and data[offset] == 1)
            std.mem.readInt(i64, data[offset + 1 ..][0..8], .little)
        else
            null;

        return @This(){
            .slots = &[_]u64{},
            .hash = hash,
            .timestamp = timestamp,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.slots.len, .little);
        for (self.slots) |slot| {
            try writer.writeInt(u64, slot, .little);
        }
        try writer.writeAll(&self.hash);
        if (self.timestamp) |ts| {
            try writer.writeByte(1);
            try writer.writeInt(i64, ts, .little);
        } else {
            try writer.writeByte(0);
        }
    }
};

/// Authorize instruction data
pub const AuthorizeData = struct {
    pubkey: [32]u8,
    authorize_type: AuthorizeType,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 33) return error.InvalidData;
        return @This(){
            .pubkey = data[0..32].*,
            .authorize_type = std.meta.intToEnum(AuthorizeType, data[32]) catch return error.InvalidData,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeAll(&self.pubkey);
        try writer.writeByte(@intFromEnum(self.authorize_type));
    }
};

pub const AuthorizeType = enum(u8) {
    voter = 0,
    withdrawer = 1,
};

/// Withdraw instruction data
pub const WithdrawData = struct {
    lamports: u64,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 8) return error.InvalidData;
        return @This(){
            .lamports = std.mem.readInt(u64, data[0..8], .little),
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.lamports, .little);
    }
};

/// Vote switch instruction data
pub const VoteSwitchData = struct {
    vote: VoteData,
    hash: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        const vote = try VoteData.deserialize(data);
        // hash would follow vote data
        return @This(){
            .vote = vote,
            .hash = [_]u8{0} ** 32,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.vote.serialize(writer);
        try writer.writeAll(&self.hash);
    }
};

/// Authorize with seed instruction data
pub const AuthorizeWithSeedData = struct {
    authorization_type: AuthorizeType,
    current_authority_derived_key_owner: [32]u8,
    current_authority_derived_key_seed: []const u8,
    new_authority: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 65) return error.InvalidData;
        return @This(){
            .authorization_type = std.meta.intToEnum(AuthorizeType, data[0]) catch return error.InvalidData,
            .current_authority_derived_key_owner = data[1..33].*,
            .current_authority_derived_key_seed = &[_]u8{},
            .new_authority = data[33..65].*,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.authorization_type));
        try writer.writeAll(&self.current_authority_derived_key_owner);
        try writer.writeInt(u64, self.current_authority_derived_key_seed.len, .little);
        try writer.writeAll(self.current_authority_derived_key_seed);
        try writer.writeAll(&self.new_authority);
    }
};

/// Authorize checked instruction data
pub const AuthorizeCheckedData = struct {
    authorize_type: AuthorizeType,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 1) return error.InvalidData;
        return @This(){
            .authorize_type = std.meta.intToEnum(AuthorizeType, data[0]) catch return error.InvalidData,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.authorize_type));
    }
};

/// Vote state update data
pub const VoteStateUpdateData = struct {
    lockouts: []const Lockout,
    root: ?u64,
    hash: [32]u8,
    timestamp: ?i64,

    pub fn deserialize(data: []const u8) !@This() {
        _ = data;
        return @This(){
            .lockouts = &[_]Lockout{},
            .root = null,
            .hash = [_]u8{0} ** 32,
            .timestamp = null,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.lockouts.len, .little);
        for (self.lockouts) |lockout| {
            try lockout.serialize(writer);
        }
        if (self.root) |r| {
            try writer.writeByte(1);
            try writer.writeInt(u64, r, .little);
        } else {
            try writer.writeByte(0);
        }
        try writer.writeAll(&self.hash);
        if (self.timestamp) |ts| {
            try writer.writeByte(1);
            try writer.writeInt(i64, ts, .little);
        } else {
            try writer.writeByte(0);
        }
    }
};

/// Vote state update switch data
pub const VoteStateUpdateSwitchData = struct {
    vote_state_update: VoteStateUpdateData,
    hash: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        return @This(){
            .vote_state_update = try VoteStateUpdateData.deserialize(data),
            .hash = [_]u8{0} ** 32,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.vote_state_update.serialize(writer);
        try writer.writeAll(&self.hash);
    }
};

/// Compact vote state update data
pub const CompactVoteStateUpdateData = struct {
    root: u64,
    lockouts: []const CompactLockout,
    hash: [32]u8,
    timestamp: ?i64,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 8) return error.InvalidData;
        const root = std.mem.readInt(u64, data[0..8], .little);
        return @This(){
            .root = root,
            .lockouts = &[_]CompactLockout{},
            .hash = [_]u8{0} ** 32,
            .timestamp = null,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.root, .little);
        try writer.writeInt(u16, @intCast(self.lockouts.len), .little);
        for (self.lockouts) |lockout| {
            try lockout.serialize(writer);
        }
        try writer.writeAll(&self.hash);
        if (self.timestamp) |ts| {
            try writer.writeByte(1);
            try writer.writeInt(i64, ts, .little);
        } else {
            try writer.writeByte(0);
        }
    }
};

/// Compact vote state update switch data
pub const CompactVoteStateUpdateSwitchData = struct {
    compact_vote_state_update: CompactVoteStateUpdateData,
    hash: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        return @This(){
            .compact_vote_state_update = try CompactVoteStateUpdateData.deserialize(data),
            .hash = [_]u8{0} ** 32,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.compact_vote_state_update.serialize(writer);
        try writer.writeAll(&self.hash);
    }
};

/// Tower sync data
pub const TowerSyncData = struct {
    lockouts: []const Lockout,
    root: ?u64,
    hash: [32]u8,
    timestamp: ?i64,
    block_id: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        _ = data;
        return @This(){
            .lockouts = &[_]Lockout{},
            .root = null,
            .hash = [_]u8{0} ** 32,
            .timestamp = null,
            .block_id = [_]u8{0} ** 32,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.lockouts.len, .little);
        for (self.lockouts) |lockout| {
            try lockout.serialize(writer);
        }
        if (self.root) |r| {
            try writer.writeByte(1);
            try writer.writeInt(u64, r, .little);
        } else {
            try writer.writeByte(0);
        }
        try writer.writeAll(&self.hash);
        if (self.timestamp) |ts| {
            try writer.writeByte(1);
            try writer.writeInt(i64, ts, .little);
        } else {
            try writer.writeByte(0);
        }
        try writer.writeAll(&self.block_id);
    }
};

/// Tower sync switch data
pub const TowerSyncSwitchData = struct {
    tower_sync: TowerSyncData,
    hash: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        return @This(){
            .tower_sync = try TowerSyncData.deserialize(data),
            .hash = [_]u8{0} ** 32,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.tower_sync.serialize(writer);
        try writer.writeAll(&self.hash);
    }
};

/// Vote lockout
pub const Lockout = struct {
    slot: u64,
    confirmation_count: u32,

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.slot, .little);
        try writer.writeInt(u32, self.confirmation_count, .little);
    }

    pub fn deserialize(reader: anytype) !@This() {
        return @This(){
            .slot = try reader.readInt(u64, .little),
            .confirmation_count = try reader.readInt(u32, .little),
        };
    }

    /// Calculate lockout period (2^confirmation_count slots)
    pub fn lockoutPeriod(self: *const @This()) u64 {
        return std.math.shl(u64, 1, @min(self.confirmation_count, 63));
    }

    /// Calculate when this lockout expires
    pub fn expiration(self: *const @This()) u64 {
        return self.slot + self.lockoutPeriod();
    }

    /// Check if lockout has expired
    pub fn isExpired(self: *const @This(), current_slot: u64) bool {
        return current_slot >= self.expiration();
    }
};

/// Compact lockout (slot offset from previous)
pub const CompactLockout = struct {
    slot_offset: u8, // Offset from previous lockout
    confirmation_count: u8,

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeByte(self.slot_offset);
        try writer.writeByte(self.confirmation_count);
    }
};

/// Vote state stored in vote account
pub const VoteState = struct {
    /// The node that votes in this account
    node_pubkey: [32]u8,

    /// The authorized voter for this account
    authorized_voter: AuthorizedVoters,

    /// The authorized withdrawer for this account
    authorized_withdrawer: [32]u8,

    /// Commission percentage (0-100)
    commission: u8,

    /// Recent votes (ring buffer)
    votes: [MAX_LOCKOUT_HISTORY]Lockout,
    votes_count: usize,

    /// Root slot (last finalized slot)
    root_slot: ?u64,

    /// History of how many credits earned per epoch
    epoch_credits: [MAX_EPOCH_CREDITS_HISTORY]EpochCredits,
    epoch_credits_count: usize,

    /// Last timestamp submitted
    last_timestamp: BlockTimestamp,

    const Self = @This();

    pub fn init(node_pubkey: [32]u8, authorized_voter: [32]u8, authorized_withdrawer: [32]u8, commission: u8) Self {
        var state = Self{
            .node_pubkey = node_pubkey,
            .authorized_voter = AuthorizedVoters.init(authorized_voter),
            .authorized_withdrawer = authorized_withdrawer,
            .commission = commission,
            .votes = undefined,
            .votes_count = 0,
            .root_slot = null,
            .epoch_credits = undefined,
            .epoch_credits_count = 0,
            .last_timestamp = BlockTimestamp{ .slot = 0, .timestamp = 0 },
        };
        // Initialize arrays to known state (zeroed lockouts/credits)
        for (&state.votes) |*v| {
            v.* = Lockout{ .slot = 0, .confirmation_count = 0 };
        }
        for (&state.epoch_credits) |*ec| {
            ec.* = EpochCredits{ .epoch = 0, .credits = 0, .prev_credits = 0 };
        }
        return state;
    }

    /// Process a vote
    pub fn processVote(self: *Self, vote: VoteData, slot: u64) !void {
        // Basic validation
        if (vote.slots.len == 0) return error.EmptyVote;

        // Add votes
        for (vote.slots) |voted_slot| {
            if (voted_slot > slot) return error.VoteForFutureSlot;

            // Check lockout
            if (self.votes_count > 0) {
                const last_vote = self.votes[self.votes_count - 1];
                if (!last_vote.isExpired(voted_slot)) {
                    return error.VoteTooSoon;
                }
            }

            // Add to votes
            try self.addVote(voted_slot);
        }

        // Update timestamp
        if (vote.timestamp) |ts| {
            self.last_timestamp = BlockTimestamp{
                .slot = slot,
                .timestamp = ts,
            };
        }
    }

    fn addVote(self: *Self, slot: u64) !void {
        // Pop expired lockouts from back
        while (self.votes_count > 0) {
            const idx = self.votes_count - 1;
            if (self.votes[idx].confirmation_count >= MAX_LOCKOUT_HISTORY) {
                // This lockout would expire root
                if (self.root_slot == null or self.votes[idx].slot > self.root_slot.?) {
                    self.root_slot = self.votes[idx].slot;
                }
                self.votes_count -= 1;
            } else {
                break;
            }
        }

        // Double confirmation counts for existing votes
        for (0..self.votes_count) |i| {
            if (self.votes[i].confirmation_count < MAX_LOCKOUT_HISTORY) {
                self.votes[i].confirmation_count += 1;
            }
        }

        // Add new vote
        if (self.votes_count < MAX_LOCKOUT_HISTORY) {
            self.votes[self.votes_count] = Lockout{
                .slot = slot,
                .confirmation_count = 1,
            };
            self.votes_count += 1;
        }
    }

    /// Get the last voted slot
    pub fn lastVotedSlot(self: *const Self) ?u64 {
        if (self.votes_count == 0) return null;
        return self.votes[self.votes_count - 1].slot;
    }

    /// Get total credits earned
    pub fn credits(self: *const Self) u64 {
        var total: u64 = 0;
        for (0..self.epoch_credits_count) |i| {
            total += self.epoch_credits[i].credits - self.epoch_credits[i].prev_credits;
        }
        return total;
    }

    /// Serialize vote state
    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.writeAll(&self.node_pubkey);
        try writer.writeAll(&self.authorized_withdrawer);
        try writer.writeByte(self.commission);

        // Votes
        try writer.writeInt(u64, self.votes_count, .little);
        for (0..self.votes_count) |i| {
            try self.votes[i].serialize(writer);
        }

        // Root slot
        if (self.root_slot) |root| {
            try writer.writeByte(1);
            try writer.writeInt(u64, root, .little);
        } else {
            try writer.writeByte(0);
        }

        // Epoch credits
        try writer.writeInt(u64, self.epoch_credits_count, .little);
        for (0..self.epoch_credits_count) |i| {
            try writer.writeInt(u64, self.epoch_credits[i].epoch, .little);
            try writer.writeInt(u64, self.epoch_credits[i].credits, .little);
            try writer.writeInt(u64, self.epoch_credits[i].prev_credits, .little);
        }

        // Last timestamp
        try writer.writeInt(u64, self.last_timestamp.slot, .little);
        try writer.writeInt(i64, self.last_timestamp.timestamp, .little);
    }
};

/// Authorized voters (can change per epoch)
pub const AuthorizedVoters = struct {
    /// Current authorized voter
    current: [32]u8,
    /// Epoch when current became authorized
    epoch: u64,

    pub fn init(voter: [32]u8) @This() {
        return @This(){
            .current = voter,
            .epoch = 0,
        };
    }

    pub fn getVoter(self: *const @This(), epoch: u64) [32]u8 {
        _ = epoch;
        return self.current;
    }
};

/// Epoch credits
pub const EpochCredits = struct {
    epoch: u64,
    credits: u64,
    prev_credits: u64,
};

/// Block timestamp
pub const BlockTimestamp = struct {
    slot: u64,
    timestamp: i64,
};

/// Vote transaction builder
pub const VoteTransactionBuilder = struct {
    allocator: Allocator,
    vote_pubkey: [32]u8,
    authorized_voter: [32]u8,
    node_pubkey: [32]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, vote_pubkey: [32]u8, authorized_voter: [32]u8, node_pubkey: [32]u8) Self {
        return Self{
            .allocator = allocator,
            .vote_pubkey = vote_pubkey,
            .authorized_voter = authorized_voter,
            .node_pubkey = node_pubkey,
        };
    }

    /// Build a vote transaction
    pub fn buildVote(self: *Self, slots: []const u64, hash: [32]u8, timestamp: ?i64, recent_blockhash: [32]u8) ![]u8 {
        var tx_buf = std.ArrayList(u8).init(self.allocator);
        const writer = tx_buf.writer();

        // Transaction header
        try writer.writeByte(1); // num_required_signatures
        try writer.writeByte(0); // num_readonly_signed
        try writer.writeByte(1); // num_readonly_unsigned

        // Account keys (3 accounts: vote account, authorized voter, vote program)
        try writer.writeByte(3); // num_accounts
        try writer.writeAll(&self.vote_pubkey);
        try writer.writeAll(&self.authorized_voter);
        try writer.writeAll(&VOTE_PROGRAM_ID);

        // Recent blockhash
        try writer.writeAll(&recent_blockhash);

        // Instructions (1 instruction)
        try writer.writeByte(1); // num_instructions

        // Vote instruction
        try writer.writeByte(2); // program_id_index (vote program)
        try writer.writeByte(2); // num_accounts
        try writer.writeByte(0); // vote account index
        try writer.writeByte(1); // authorized voter index

        // Instruction data
        const vote_data = VoteData{
            .slots = slots,
            .hash = hash,
            .timestamp = timestamp,
        };

        const instruction = VoteInstruction{ .Vote = vote_data };

        var instr_buf: [256]u8 = undefined;
        var instr_fbs = std.io.fixedBufferStream(&instr_buf);
        try instruction.serialize(instr_fbs.writer());
        const instr_data = instr_fbs.getWritten();

        try writer.writeInt(u16, @intCast(instr_data.len), .little);
        try writer.writeAll(instr_data);

        return tx_buf.toOwnedSlice();
    }

    /// Build a compact vote state update transaction (modern voting)
    pub fn buildCompactVoteStateUpdate(
        self: *Self,
        root: u64,
        lockouts: []const CompactLockout,
        hash: [32]u8,
        timestamp: ?i64,
        recent_blockhash: [32]u8,
    ) ![]u8 {
        var tx_buf = std.ArrayList(u8).init(self.allocator);
        const writer = tx_buf.writer();

        // Transaction header
        try writer.writeByte(1); // num_required_signatures
        try writer.writeByte(0); // num_readonly_signed
        try writer.writeByte(1); // num_readonly_unsigned

        // Account keys
        try writer.writeByte(3);
        try writer.writeAll(&self.vote_pubkey);
        try writer.writeAll(&self.authorized_voter);
        try writer.writeAll(&VOTE_PROGRAM_ID);

        // Recent blockhash
        try writer.writeAll(&recent_blockhash);

        // Instructions
        try writer.writeByte(1);
        try writer.writeByte(2); // program_id_index
        try writer.writeByte(2); // num_accounts
        try writer.writeByte(0);
        try writer.writeByte(1);

        // Instruction data
        const update_data = CompactVoteStateUpdateData{
            .root = root,
            .lockouts = lockouts,
            .hash = hash,
            .timestamp = timestamp,
        };

        const instruction = VoteInstruction{ .CompactUpdateVoteState = update_data };

        var instr_buf: [512]u8 = undefined;
        var instr_fbs = std.io.fixedBufferStream(&instr_buf);
        try instruction.serialize(instr_fbs.writer());
        const instr_data = instr_fbs.getWritten();

        try writer.writeInt(u16, @intCast(instr_data.len), .little);
        try writer.writeAll(instr_data);

        return tx_buf.toOwnedSlice();
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "lockout period calculation" {
    const lockout = Lockout{
        .slot = 100,
        .confirmation_count = 5,
    };

    try std.testing.expectEqual(@as(u64, 32), lockout.lockoutPeriod()); // 2^5 = 32
    try std.testing.expectEqual(@as(u64, 132), lockout.expiration()); // 100 + 32
    try std.testing.expect(!lockout.isExpired(110));
    try std.testing.expect(lockout.isExpired(140));
}

test "vote state init" {
    const pubkey: [32]u8 = [_]u8{0x11} ** 32;
    const voter: [32]u8 = [_]u8{0x22} ** 32;
    const withdrawer: [32]u8 = [_]u8{0x33} ** 32;

    const state = VoteState.init(pubkey, voter, withdrawer, 10);

    try std.testing.expectEqual(@as(usize, 0), state.votes_count);
    try std.testing.expectEqual(@as(?u64, null), state.root_slot);
    try std.testing.expectEqual(@as(u8, 10), state.commission);
}

test "vote instruction serialization" {
    const vote_data = VoteData{
        .slots = &[_]u64{ 100, 101, 102 },
        .hash = [_]u8{0xab} ** 32,
        .timestamp = 1234567890,
    };

    const instruction = VoteInstruction{ .Vote = vote_data };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try instruction.serialize(fbs.writer());

    // Verify discriminant
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[0..4], .little));
}

test "vote program id" {
    // Verify program ID matches expected format
    try std.testing.expectEqual(@as(u8, 0x07), VOTE_PROGRAM_ID[0]);
    try std.testing.expectEqual(@as(u8, 0x61), VOTE_PROGRAM_ID[1]);
}

