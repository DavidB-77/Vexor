//! Vexor Stake Program
//!
//! Implementation of the Solana Stake Program for:
//! - Stake account management
//! - Delegation to validators
//! - Rewards distribution
//! - Deactivation and withdrawal
//!
//! Program ID: Stake11111111111111111111111111111111111111

const std = @import("std");
const Allocator = std.mem.Allocator;
const native = @import("native_programs.zig");

/// Stake program ID
pub const STAKE_PROGRAM_ID: [32]u8 = native.program_ids.stake;

/// Stake state versions
pub const StakeStateVersion = enum(u32) {
    uninitialized = 0,
    initialized = 1,
    stake = 2,
    rewards_pool = 3,
};

/// Stake state
pub const StakeState = union(StakeStateVersion) {
    uninitialized: void,
    initialized: Initialized,
    stake: StakeData,
    rewards_pool: void,

    const Self = @This();

    /// Deserialize stake state from account data
    pub fn deserialize(data: []const u8) !Self {
        if (data.len < 4) return error.InvalidData;

        const version = std.mem.readInt(u32, data[0..4], .little);
        const state_type = std.meta.intToEnum(StakeStateVersion, version) catch return error.InvalidData;

        return switch (state_type) {
            .uninitialized => .uninitialized,
            .initialized => .{ .initialized = try Initialized.deserialize(data[4..]) },
            .stake => .{ .stake = try StakeData.deserialize(data[4..]) },
            .rewards_pool => .rewards_pool,
        };
    }

    /// Serialize stake state to bytes
    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.writeInt(u32, @intFromEnum(std.meta.activeTag(self.*)), .little);
        switch (self.*) {
            .uninitialized, .rewards_pool => {},
            .initialized => |init| try init.serialize(writer),
            .stake => |stake| try stake.serialize(writer),
        }
    }

    /// Get size of stake state
    pub fn size(self: *const Self) usize {
        return switch (self.*) {
            .uninitialized => 4,
            .initialized => 4 + Initialized.SIZE,
            .stake => 4 + StakeData.SIZE,
            .rewards_pool => 4,
        };
    }
};

/// Initialized stake state (no delegation yet)
pub const Initialized = struct {
    meta: Meta,

    pub const SIZE: usize = Meta.SIZE;

    pub fn deserialize(data: []const u8) !@This() {
        return @This(){
            .meta = try Meta.deserialize(data),
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.meta.serialize(writer);
    }
};

/// Active stake state
pub const StakeData = struct {
    meta: Meta,
    stake: Stake,

    pub const SIZE: usize = Meta.SIZE + Stake.SIZE;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        return @This(){
            .meta = try Meta.deserialize(data[0..Meta.SIZE]),
            .stake = try Stake.deserialize(data[Meta.SIZE..]),
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.meta.serialize(writer);
        try self.stake.serialize(writer);
    }
};

/// Stake metadata
pub const Meta = struct {
    rent_exempt_reserve: u64,
    authorized: Authorized,
    lockup: Lockup,

    pub const SIZE: usize = 8 + Authorized.SIZE + Lockup.SIZE;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        var offset: usize = 0;

        const rent_exempt = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const authorized = try Authorized.deserialize(data[offset..]);
        offset += Authorized.SIZE;

        const lockup = try Lockup.deserialize(data[offset..]);

        return @This(){
            .rent_exempt_reserve = rent_exempt,
            .authorized = authorized,
            .lockup = lockup,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(u64, self.rent_exempt_reserve, .little);
        try self.authorized.serialize(writer);
        try self.lockup.serialize(writer);
    }
};

/// Authorized stake operators
pub const Authorized = struct {
    staker: [32]u8,
    withdrawer: [32]u8,

    pub const SIZE: usize = 64;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        return @This(){
            .staker = data[0..32].*,
            .withdrawer = data[32..64].*,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeAll(&self.staker);
        try writer.writeAll(&self.withdrawer);
    }
};

/// Stake lockup
pub const Lockup = struct {
    unix_timestamp: i64,
    epoch: u64,
    custodian: [32]u8,

    pub const SIZE: usize = 8 + 8 + 32;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        return @This(){
            .unix_timestamp = std.mem.readInt(i64, data[0..8], .little),
            .epoch = std.mem.readInt(u64, data[8..16], .little),
            .custodian = data[16..48].*,
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeInt(i64, self.unix_timestamp, .little);
        try writer.writeInt(u64, self.epoch, .little);
        try writer.writeAll(&self.custodian);
    }

    pub fn isInForce(self: *const @This(), clock: *const Clock) bool {
        return self.unix_timestamp > clock.unix_timestamp or self.epoch > clock.epoch;
    }
};

/// Active stake delegation
pub const Stake = struct {
    delegation: Delegation,
    credits_observed: u64,

    pub const SIZE: usize = Delegation.SIZE + 8;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        return @This(){
            .delegation = try Delegation.deserialize(data[0..Delegation.SIZE]),
            .credits_observed = std.mem.readInt(u64, data[Delegation.SIZE..][0..8], .little),
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try self.delegation.serialize(writer);
        try writer.writeInt(u64, self.credits_observed, .little);
    }
};

/// Stake delegation to a validator
pub const Delegation = struct {
    /// Validator vote account
    voter_pubkey: [32]u8,
    /// Amount delegated
    stake: u64,
    /// Epoch when delegation became active
    activation_epoch: u64,
    /// Epoch when delegation was deactivated (u64::MAX if active)
    deactivation_epoch: u64,
    /// Historical warmup/cooldown rate
    warmup_cooldown_rate: f64,

    pub const SIZE: usize = 32 + 8 + 8 + 8 + 8;

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < SIZE) return error.InvalidData;
        return @This(){
            .voter_pubkey = data[0..32].*,
            .stake = std.mem.readInt(u64, data[32..40], .little),
            .activation_epoch = std.mem.readInt(u64, data[40..48], .little),
            .deactivation_epoch = std.mem.readInt(u64, data[48..56], .little),
            .warmup_cooldown_rate = @bitCast(std.mem.readInt(u64, data[56..64], .little)),
        };
    }

    pub fn serialize(self: *const @This(), writer: anytype) !void {
        try writer.writeAll(&self.voter_pubkey);
        try writer.writeInt(u64, self.stake, .little);
        try writer.writeInt(u64, self.activation_epoch, .little);
        try writer.writeInt(u64, self.deactivation_epoch, .little);
        try writer.writeInt(u64, @bitCast(self.warmup_cooldown_rate), .little);
    }

    pub fn isActive(self: *const @This(), epoch: u64) bool {
        return self.activation_epoch <= epoch and epoch < self.deactivation_epoch;
    }

    pub fn isDeactivating(self: *const @This(), epoch: u64) bool {
        return self.deactivation_epoch != std.math.maxInt(u64) and epoch >= self.deactivation_epoch;
    }
};

/// Clock sysvar for lockup checks
pub const Clock = struct {
    slot: u64,
    epoch_start_timestamp: i64,
    epoch: u64,
    leader_schedule_epoch: u64,
    unix_timestamp: i64,
};

/// Stake instruction types
pub const StakeInstruction = union(enum) {
    /// Initialize a stake account
    Initialize: InitializeData,
    /// Authorize a new staker or withdrawer
    Authorize: AuthorizeData,
    /// Delegate stake to a vote account
    DelegateStake,
    /// Split stake
    Split: u64,
    /// Withdraw from stake account
    Withdraw: u64,
    /// Deactivate stake
    Deactivate,
    /// Set lockup
    SetLockup: SetLockupData,
    /// Merge stake accounts
    Merge,
    /// Authorize with seed
    AuthorizeWithSeed: AuthorizeWithSeedData,
    /// Initialize checked
    InitializeChecked,
    /// Authorize checked
    AuthorizeChecked: AuthorizeType,
    /// Authorize checked with seed
    AuthorizeCheckedWithSeed: AuthorizeCheckedWithSeedData,
    /// Set lockup checked
    SetLockupChecked: SetLockupCheckedData,
    /// Get minimum delegation
    GetMinimumDelegation,
    /// Deactivate delinquent
    DeactivateDelinquent,
    /// Redelegate
    Redelegate,

    const Self = @This();

    pub fn deserialize(data: []const u8) !Self {
        if (data.len < 4) return error.InvalidData;

        const discriminant = std.mem.readInt(u32, data[0..4], .little);

        return switch (discriminant) {
            0 => .{ .Initialize = try InitializeData.deserialize(data[4..]) },
            1 => .{ .Authorize = try AuthorizeData.deserialize(data[4..]) },
            2 => .DelegateStake,
            3 => .{ .Split = if (data.len >= 12) std.mem.readInt(u64, data[4..12], .little) else return error.InvalidData },
            4 => .{ .Withdraw = if (data.len >= 12) std.mem.readInt(u64, data[4..12], .little) else return error.InvalidData },
            5 => .Deactivate,
            6 => .{ .SetLockup = try SetLockupData.deserialize(data[4..]) },
            7 => .Merge,
            14 => .GetMinimumDelegation,
            else => error.InvalidData,
        };
    }
};

pub const InitializeData = struct {
    authorized: Authorized,
    lockup: Lockup,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < Authorized.SIZE + Lockup.SIZE) return error.InvalidData;
        return @This(){
            .authorized = try Authorized.deserialize(data[0..Authorized.SIZE]),
            .lockup = try Lockup.deserialize(data[Authorized.SIZE..]),
        };
    }
};

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
};

pub const AuthorizeType = enum(u8) {
    staker = 0,
    withdrawer = 1,
};

pub const SetLockupData = struct {
    unix_timestamp: ?i64,
    epoch: ?u64,
    custodian: ?[32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        _ = data;
        return @This(){
            .unix_timestamp = null,
            .epoch = null,
            .custodian = null,
        };
    }
};

pub const AuthorizeWithSeedData = struct {
    new_authorized_pubkey: [32]u8,
    authorize_type: AuthorizeType,
    authority_seed: []const u8,
    authority_owner: [32]u8,
};

pub const AuthorizeCheckedWithSeedData = struct {
    authorize_type: AuthorizeType,
    authority_seed: []const u8,
    authority_owner: [32]u8,
};

pub const SetLockupCheckedData = struct {
    unix_timestamp: ?i64,
    epoch: ?u64,
};

/// Stake program processor
pub const StakeProgram = struct {
    /// Process a stake instruction
    pub fn process(ctx: *native.InstructionContext) native.ProgramResult {
        const instruction = StakeInstruction.deserialize(ctx.data) catch {
            return .{ .err = .InvalidInstructionData };
        };

        return switch (instruction) {
            .Initialize => |data| processInitialize(ctx, data),
            .DelegateStake => processDelegate(ctx),
            .Deactivate => processDeactivate(ctx),
            .Withdraw => |lamports| processWithdraw(ctx, lamports),
            .Merge => processMerge(ctx),
            .GetMinimumDelegation => .success,
            else => .{ .err = .InvalidInstructionData },
        };
    }

    fn processInitialize(ctx: *native.InstructionContext, data: InitializeData) native.ProgramResult {
        if (ctx.accountCount() < 2) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const stake_account = ctx.getAccount(0).?;
        // Rent sysvar account at index 1

        if (!stake_account.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // Check if already initialized
        if (stake_account.data.len > 0) {
            const state = StakeState.deserialize(stake_account.data) catch {
                return .{ .err = .InvalidAccountData };
            };
            switch (state) {
                .uninitialized => {},
                else => return .{ .err = .AccountAlreadyInitialized },
            }
        }

        // Initialize stake state
        const meta = Meta{
            .rent_exempt_reserve = 0, // Would calculate from rent sysvar
            .authorized = data.authorized,
            .lockup = data.lockup,
        };

        // Write initialized state
        var state_buf: [4 + Meta.SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&state_buf);
        const initialized = StakeState{ .initialized = Initialized{ .meta = meta } };
        initialized.serialize(fbs.writer()) catch {
            return .{ .err = .InvalidAccountData };
        };

        if (state_buf.len <= stake_account.data.len) {
            @memcpy(stake_account.data[0..state_buf.len], &state_buf);
        }

        return .success;
    }

    fn processDelegate(ctx: *native.InstructionContext) native.ProgramResult {
        if (ctx.accountCount() < 6) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const stake_account = ctx.getAccount(0).?;
        const vote_account = ctx.getAccount(1).?;
        // Clock sysvar at index 2
        // Stake history at index 3
        // Config at index 4
        // Stake authority at index 5

        if (!stake_account.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // Verify stake authority signed
        const authority = ctx.getAccount(5).?;
        if (!authority.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Vote account must exist and be valid
        if (vote_account.data.len == 0) {
            return .{ .err = .InvalidAccountData };
        }

        // Would update stake state with delegation to vote_account.pubkey

        return .success;
    }

    fn processDeactivate(ctx: *native.InstructionContext) native.ProgramResult {
        if (ctx.accountCount() < 3) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const stake_account = ctx.getAccount(0).?;
        // Clock sysvar at index 1
        // Stake authority at index 2

        if (!stake_account.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        const authority = ctx.getAccount(2).?;
        if (!authority.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Would set deactivation_epoch in stake state

        return .success;
    }

    fn processWithdraw(ctx: *native.InstructionContext, lamports: u64) native.ProgramResult {
        if (ctx.accountCount() < 5) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const stake_account = ctx.getAccount(0).?;
        const recipient = ctx.getAccount(1).?;
        // Clock at index 2
        // Stake history at index 3
        // Withdrawer at index 4

        if (!stake_account.is_writable or !recipient.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        const withdrawer = ctx.getAccount(4).?;
        if (!withdrawer.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Check sufficient balance
        if (stake_account.lamports.* < lamports) {
            return .{ .err = .InsufficientFunds };
        }

        // Transfer
        stake_account.lamports.* -= lamports;
        recipient.lamports.* += lamports;

        return .success;
    }

    fn processMerge(ctx: *native.InstructionContext) native.ProgramResult {
        if (ctx.accountCount() < 5) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const destination = ctx.getAccount(0).?;
        const source = ctx.getAccount(1).?;
        // Clock at index 2
        // Stake history at index 3
        // Authority at index 4

        if (!destination.is_writable or !source.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // Would merge stake accounts

        return .success;
    }
};

/// Calculate rewards for a stake account
pub const StakeRewards = struct {
    /// Calculate epoch rewards
    pub fn calculate(
        stake: u64,
        vote_state_credits: u64,
        stake_credits_observed: u64,
        point_value: f64,
        commission: u8,
    ) RewardInfo {
        // Credits earned since last observation
        const credits_delta = vote_state_credits -| stake_credits_observed;

        if (credits_delta == 0) {
            return RewardInfo{
                .staker_reward = 0,
                .voter_reward = 0,
                .new_credits_observed = stake_credits_observed,
            };
        }

        // Total points = stake * credits
        const points: f64 = @floatFromInt(stake * credits_delta);

        // Total reward = points * point_value
        const total_reward: u64 = @intFromFloat(points * point_value);

        // Voter commission
        const voter_reward = (total_reward * commission) / 100;
        const staker_reward = total_reward - voter_reward;

        return RewardInfo{
            .staker_reward = staker_reward,
            .voter_reward = voter_reward,
            .new_credits_observed = vote_state_credits,
        };
    }
};

pub const RewardInfo = struct {
    staker_reward: u64,
    voter_reward: u64,
    new_credits_observed: u64,
};

/// Minimum stake delegation (5 SOL)
pub const MINIMUM_DELEGATION: u64 = 5_000_000_000;

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "stake delegation active check" {
    const delegation = Delegation{
        .voter_pubkey = [_]u8{0} ** 32,
        .stake = 1_000_000_000,
        .activation_epoch = 100,
        .deactivation_epoch = std.math.maxInt(u64),
        .warmup_cooldown_rate = 0.25,
    };

    try std.testing.expect(!delegation.isActive(99)); // Before activation
    try std.testing.expect(delegation.isActive(100)); // At activation
    try std.testing.expect(delegation.isActive(200)); // After activation
    try std.testing.expect(!delegation.isDeactivating(200)); // Not deactivated
}

test "stake rewards calculation" {
    const reward = StakeRewards.calculate(
        1_000_000_000, // 1 SOL stake
        100, // Current vote credits
        50, // Last observed credits
        0.001, // Point value
        10, // 10% commission
    );

    try std.testing.expect(reward.staker_reward > 0);
    try std.testing.expect(reward.voter_reward > 0);
    try std.testing.expectEqual(@as(u64, 100), reward.new_credits_observed);
}

test "lockup check" {
    const lockup = Lockup{
        .unix_timestamp = 1700000000,
        .epoch = 100,
        .custodian = [_]u8{0} ** 32,
    };

    const clock_before = Clock{
        .slot = 0,
        .epoch_start_timestamp = 0,
        .epoch = 50,
        .leader_schedule_epoch = 51,
        .unix_timestamp = 1600000000,
    };

    const clock_after = Clock{
        .slot = 0,
        .epoch_start_timestamp = 0,
        .epoch = 150,
        .leader_schedule_epoch = 151,
        .unix_timestamp = 1800000000,
    };

    try std.testing.expect(lockup.isInForce(&clock_before));
    try std.testing.expect(!lockup.isInForce(&clock_after));
}

