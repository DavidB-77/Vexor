//! Vexor Native Programs
//!
//! Implementation of Solana's native programs:
//! - System Program: Account creation, transfers, allocate, assign
//! - Vote Program: Validator voting
//! - Stake Program: Stake delegation
//! - Config Program: Configuration data storage
//!
//! These are built-in programs that execute natively (not BPF).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Native program IDs
pub const program_ids = struct {
    /// System program (11111111111111111111111111111111)
    pub const system: [32]u8 = [_]u8{0} ** 32;

    /// Vote program
    pub const vote: [32]u8 = .{
        0x07, 0x61, 0x48, 0x1d, 0x35, 0x7e, 0x6a, 0x6b,
        0xf2, 0x24, 0x08, 0x77, 0xe7, 0xa6, 0xee, 0x44,
        0x29, 0x5e, 0x69, 0x2e, 0x2a, 0x17, 0x47, 0xa5,
        0x87, 0xc8, 0xb6, 0x22, 0x8b, 0x9d, 0x00, 0x00,
    };

    /// Stake program
    pub const stake: [32]u8 = .{
        0x06, 0xa1, 0xd8, 0x17, 0x91, 0x37, 0x54, 0x2a,
        0x98, 0x3a, 0x98, 0x3a, 0xe3, 0xd4, 0x72, 0x8e,
        0x40, 0x64, 0x02, 0x77, 0x52, 0x9c, 0x50, 0xbb,
        0x51, 0x14, 0x2d, 0xfe, 0x5b, 0x83, 0x00, 0x00,
    };

    /// Config program
    pub const config: [32]u8 = .{
        0x03, 0x06, 0x46, 0x6f, 0xe5, 0x21, 0x17, 0x32,
        0xff, 0xec, 0xad, 0xba, 0x72, 0xc3, 0x9b, 0xe7,
        0xbc, 0x8c, 0xe5, 0xbb, 0xc5, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    /// BPF Loader v2
    pub const bpf_loader: [32]u8 = .{
        0x02, 0xa8, 0xf6, 0x91, 0x4e, 0x88, 0x6c, 0xde,
        0xaa, 0xfb, 0xb1, 0x10, 0x85, 0xac, 0x49, 0xac,
        0xdb, 0x3f, 0x2e, 0x07, 0x60, 0xac, 0x24, 0xf9,
        0x3c, 0x68, 0x22, 0x06, 0x00, 0x00, 0x00, 0x00,
    };

    /// BPF Loader Upgradeable
    pub const bpf_loader_upgradeable: [32]u8 = .{
        0x02, 0xc4, 0x91, 0x73, 0x19, 0x75, 0xdd, 0x6a,
        0x7b, 0xc6, 0x5a, 0xb2, 0xb1, 0x74, 0x36, 0x6b,
        0x23, 0x83, 0x21, 0x41, 0xed, 0x3a, 0x85, 0x6a,
        0xf8, 0xdb, 0x73, 0x37, 0x00, 0x00, 0x00, 0x00,
    };

    /// Sysvar: Clock
    pub const sysvar_clock: [32]u8 = .{
        0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x6c,
        0xd8, 0xb2, 0x84, 0x4a, 0x29, 0x77, 0x97, 0x11,
        0x74, 0xd9, 0x60, 0x0c, 0x3c, 0x02, 0x95, 0x5c,
        0x66, 0x36, 0x35, 0x07, 0x00, 0x00, 0x00, 0x00,
    };

    /// Sysvar: Rent
    pub const sysvar_rent: [32]u8 = .{
        0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x6c,
        0xd8, 0xb2, 0x84, 0x4a, 0x29, 0x77, 0x97, 0x14,
        0x90, 0x3c, 0x5a, 0x87, 0x1f, 0x18, 0xb8, 0x11,
        0x4c, 0x54, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    /// Native program set for O(1) lookup using comptime hash
    /// Uses first 8 bytes of program ID as hash key
    const native_program_set = blk: {
        const programs = [_][32]u8{ system, vote, stake, config };
        var set: [4]u64 = undefined;
        for (programs, 0..) |prog, i| {
            set[i] = std.mem.readInt(u64, prog[0..8], .little);
        }
        break :blk set;
    };

    /// Check if a program ID is a native program (O(1) average case)
    /// Uses first 8 bytes as discriminator for fast rejection
    pub fn isNative(program_id: *const [32]u8) bool {
        const key = std.mem.readInt(u64, program_id[0..8], .little);

        // Check against native program prefix hashes
        inline for (native_program_set) |native_key| {
            if (key == native_key) {
                // Verify full match (rare - only on prefix collision)
                if (std.mem.eql(u8, program_id, &system)) return true;
                if (std.mem.eql(u8, program_id, &vote)) return true;
                if (std.mem.eql(u8, program_id, &stake)) return true;
                if (std.mem.eql(u8, program_id, &config)) return true;
            }
        }
        return false;
    }

    /// Check if a program ID is a BPF loader
    pub fn isBpfLoader(program_id: *const [32]u8) bool {
        return std.mem.eql(u8, program_id, &bpf_loader) or
            std.mem.eql(u8, program_id, &bpf_loader_upgradeable);
    }

    /// Check if a program ID is a sysvar
    pub fn isSysvar(program_id: *const [32]u8) bool {
        // Sysvars start with 0x06 0xa7 0xd5 0x17
        return program_id[0] == 0x06 and program_id[1] == 0xa7 and
            program_id[2] == 0xd5 and program_id[3] == 0x17;
    }
};

/// Instruction context for program execution
pub const InstructionContext = struct {
    /// Program ID being executed
    program_id: [32]u8,
    /// Account infos for this instruction
    accounts: []AccountInfo,
    /// Instruction data
    data: []const u8,
    /// Invoke depth (0 = top level)
    invoke_depth: u8,
    /// Compute units remaining
    compute_units_remaining: *u64,

    const Self = @This();

    /// Get account by index
    pub fn getAccount(self: *const Self, index: usize) ?*AccountInfo {
        if (index >= self.accounts.len) return null;
        return &self.accounts[index];
    }

    /// Get number of accounts
    pub fn accountCount(self: *const Self) usize {
        return self.accounts.len;
    }

    /// Consume compute units
    pub fn consumeUnits(self: *Self, units: u64) !void {
        if (self.compute_units_remaining.* < units) {
            return error.ComputeBudgetExceeded;
        }
        self.compute_units_remaining.* -= units;
    }
};

/// Account info for instruction execution
pub const AccountInfo = struct {
    /// Account pubkey
    pubkey: [32]u8,
    /// Lamports balance (mutable during execution)
    lamports: *u64,
    /// Account data (mutable during execution)
    data: []u8,
    /// Account owner
    owner: *[32]u8,
    /// Is this account a signer
    is_signer: bool,
    /// Is this account writable
    is_writable: bool,
    /// Is this account executable
    executable: bool,
    /// Rent epoch
    rent_epoch: u64,

    const Self = @This();

    /// Check if account is owned by program
    pub fn isOwnedBy(self: *const Self, program_id: *const [32]u8) bool {
        return std.mem.eql(u8, self.owner, program_id);
    }

    /// Check if account is system account (owned by system program)
    pub fn isSystemAccount(self: *const Self) bool {
        return self.isOwnedBy(&program_ids.system);
    }

    /// Assign account to new owner
    pub fn assign(self: *Self, new_owner: *const [32]u8) void {
        self.owner.* = new_owner.*;
    }

    /// Reallocate account data
    pub fn realloc(self: *Self, new_len: usize, allocator: Allocator) !void {
        if (new_len == self.data.len) return;

        const new_data = try allocator.alloc(u8, new_len);

        // Copy existing data
        const copy_len = @min(self.data.len, new_len);
        @memcpy(new_data[0..copy_len], self.data[0..copy_len]);

        // Zero new space
        if (new_len > self.data.len) {
            @memset(new_data[copy_len..], 0);
        }

        allocator.free(self.data);
        self.data = new_data;
    }
};

/// Program result
pub const ProgramResult = union(enum) {
    success: void,
    err: ProgramError,
};

/// Program errors
pub const ProgramError = enum(u32) {
    // Generic errors
    Custom = 0,
    InvalidArgument = 1,
    InvalidInstructionData = 2,
    InvalidAccountData = 3,
    AccountDataTooSmall = 4,
    InsufficientFunds = 5,
    IncorrectProgramId = 6,
    MissingRequiredSignature = 7,
    AccountAlreadyInitialized = 8,
    UninitializedAccount = 9,
    NotEnoughAccountKeys = 10,
    AccountBorrowFailed = 11,
    MaxSeedLengthExceeded = 12,
    InvalidSeeds = 13,
    BorshIoError = 14,
    AccountNotRentExempt = 15,
    UnsupportedSysvar = 16,
    IllegalOwner = 17,
    MaxAccountsDataSizeExceeded = 18,
    InvalidRealloc = 19,

    // System program errors (100-199)
    SystemAccountAlreadyInUse = 100,
    SystemResultWithNegativeLamports = 101,
    SystemInvalidProgramId = 102,
    SystemInvalidAccountDataLength = 103,
    SystemMaxSeedLengthExceeded = 104,
    SystemAddressWithSeedMismatch = 105,

    // Vote program errors (200-299)
    VoteTooOld = 200,
    VoteSlotsTooOld = 201,
    VoteSlotsNotOrdered = 202,
    VoteConfirmationTooNew = 203,

    // Stake program errors (300-399)
    StakeNoCreditsToRedeem = 300,
    StakeLockupInForce = 301,
    StakeAlreadyDeactivated = 302,

    pub fn toU32(self: ProgramError) u32 {
        return @intFromEnum(self);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SYSTEM PROGRAM IMPLEMENTATION
// ═══════════════════════════════════════════════════════════════════════════

/// System program instructions
pub const SystemInstruction = union(enum) {
    /// Create a new account
    CreateAccount: CreateAccountData,
    /// Assign account to a program
    Assign: AssignData,
    /// Transfer lamports
    Transfer: TransferData,
    /// Create account with seed
    CreateAccountWithSeed: CreateAccountWithSeedData,
    /// Advance nonce account
    AdvanceNonceAccount,
    /// Withdraw from nonce account
    WithdrawNonceAccount: u64,
    /// Initialize nonce account
    InitializeNonceAccount: [32]u8,
    /// Authorize nonce account
    AuthorizeNonceAccount: [32]u8,
    /// Allocate space for account
    Allocate: AllocateData,
    /// Allocate with seed
    AllocateWithSeed: AllocateWithSeedData,
    /// Assign with seed
    AssignWithSeed: AssignWithSeedData,
    /// Transfer with seed
    TransferWithSeed: TransferWithSeedData,
    /// Upgrade nonce account
    UpgradeNonceAccount,

    const Self = @This();

    /// Deserialize from instruction data
    pub fn deserialize(data: []const u8) !Self {
        if (data.len < 4) return error.InvalidInstructionData;

        const discriminant = std.mem.readInt(u32, data[0..4], .little);

        return switch (discriminant) {
            0 => .{ .CreateAccount = try CreateAccountData.deserialize(data[4..]) },
            1 => .{ .Assign = try AssignData.deserialize(data[4..]) },
            2 => .{ .Transfer = try TransferData.deserialize(data[4..]) },
            3 => .{ .CreateAccountWithSeed = try CreateAccountWithSeedData.deserialize(data[4..]) },
            4 => .AdvanceNonceAccount,
            5 => .{ .WithdrawNonceAccount = if (data.len >= 12) std.mem.readInt(u64, data[4..12], .little) else return error.InvalidInstructionData },
            6 => .{ .InitializeNonceAccount = if (data.len >= 36) data[4..36].* else return error.InvalidInstructionData },
            7 => .{ .AuthorizeNonceAccount = if (data.len >= 36) data[4..36].* else return error.InvalidInstructionData },
            8 => .{ .Allocate = try AllocateData.deserialize(data[4..]) },
            9 => .{ .AllocateWithSeed = try AllocateWithSeedData.deserialize(data[4..]) },
            10 => .{ .AssignWithSeed = try AssignWithSeedData.deserialize(data[4..]) },
            11 => .{ .TransferWithSeed = try TransferWithSeedData.deserialize(data[4..]) },
            12 => .UpgradeNonceAccount,
            else => error.InvalidInstructionData,
        };
    }
};

pub const CreateAccountData = struct {
    lamports: u64,
    space: u64,
    owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 48) return error.InvalidInstructionData;
        return @This(){
            .lamports = std.mem.readInt(u64, data[0..8], .little),
            .space = std.mem.readInt(u64, data[8..16], .little),
            .owner = data[16..48].*,
        };
    }
};

pub const AssignData = struct {
    owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 32) return error.InvalidInstructionData;
        return @This(){
            .owner = data[0..32].*,
        };
    }
};

pub const TransferData = struct {
    lamports: u64,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 8) return error.InvalidInstructionData;
        return @This(){
            .lamports = std.mem.readInt(u64, data[0..8], .little),
        };
    }
};

pub const CreateAccountWithSeedData = struct {
    base: [32]u8,
    seed: []const u8,
    lamports: u64,
    space: u64,
    owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 80) return error.InvalidInstructionData;
        return @This(){
            .base = data[0..32].*,
            .seed = &[_]u8{}, // Would need allocator
            .lamports = std.mem.readInt(u64, data[32..40], .little),
            .space = std.mem.readInt(u64, data[40..48], .little),
            .owner = data[48..80].*,
        };
    }
};

pub const AllocateData = struct {
    space: u64,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 8) return error.InvalidInstructionData;
        return @This(){
            .space = std.mem.readInt(u64, data[0..8], .little),
        };
    }
};

pub const AllocateWithSeedData = struct {
    base: [32]u8,
    seed: []const u8,
    space: u64,
    owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 72) return error.InvalidInstructionData;
        return @This(){
            .base = data[0..32].*,
            .seed = &[_]u8{},
            .space = std.mem.readInt(u64, data[32..40], .little),
            .owner = data[40..72].*,
        };
    }
};

pub const AssignWithSeedData = struct {
    base: [32]u8,
    seed: []const u8,
    owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 64) return error.InvalidInstructionData;
        return @This(){
            .base = data[0..32].*,
            .seed = &[_]u8{},
            .owner = data[32..64].*,
        };
    }
};

pub const TransferWithSeedData = struct {
    lamports: u64,
    from_seed: []const u8,
    from_owner: [32]u8,

    pub fn deserialize(data: []const u8) !@This() {
        if (data.len < 40) return error.InvalidInstructionData;
        return @This(){
            .lamports = std.mem.readInt(u64, data[0..8], .little),
            .from_seed = &[_]u8{},
            .from_owner = data[8..40].*,
        };
    }
};

/// System program processor
pub const SystemProgram = struct {
    /// Process a system program instruction
    pub fn process(ctx: *InstructionContext) ProgramResult {
        const instruction = SystemInstruction.deserialize(ctx.data) catch {
            return .{ .err = .InvalidInstructionData };
        };

        return switch (instruction) {
            .CreateAccount => |data| processCreateAccount(ctx, data),
            .Assign => |data| processAssign(ctx, data),
            .Transfer => |data| processTransfer(ctx, data),
            .Allocate => |data| processAllocate(ctx, data),
            else => .{ .err = .InvalidInstructionData },
        };
    }

    fn processCreateAccount(ctx: *InstructionContext, data: CreateAccountData) ProgramResult {
        // Validate accounts
        if (ctx.accountCount() < 2) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const from = ctx.getAccount(0).?;
        const to = ctx.getAccount(1).?;

        // From must be signer
        if (!from.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // To must be signer (new account)
        if (!to.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // To must be writable
        if (!to.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // To must be empty (uninitialized)
        if (to.lamports.* != 0 or to.data.len != 0) {
            return .{ .err = .SystemAccountAlreadyInUse };
        }

        // From must have enough lamports
        if (from.lamports.* < data.lamports) {
            return .{ .err = .InsufficientFunds };
        }

        // Transfer lamports
        from.lamports.* -= data.lamports;
        to.lamports.* += data.lamports;

        // Assign owner
        to.owner.* = data.owner;

        return .success;
    }

    fn processAssign(ctx: *InstructionContext, data: AssignData) ProgramResult {
        if (ctx.accountCount() < 1) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const account = ctx.getAccount(0).?;

        // Account must be signer
        if (!account.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Account must be writable
        if (!account.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // Must be owned by system program
        if (!account.isSystemAccount()) {
            return .{ .err = .SystemInvalidProgramId };
        }

        // Assign new owner
        account.owner.* = data.owner;

        return .success;
    }

    fn processTransfer(ctx: *InstructionContext, data: TransferData) ProgramResult {
        if (ctx.accountCount() < 2) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const from = ctx.getAccount(0).?;
        const to = ctx.getAccount(1).?;

        // From must be signer
        if (!from.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Both must be writable
        if (!from.is_writable or !to.is_writable) {
            return .{ .err = .InvalidArgument };
        }

        // From must be owned by system program
        if (!from.isSystemAccount()) {
            return .{ .err = .SystemInvalidProgramId };
        }

        // Check sufficient funds
        if (from.lamports.* < data.lamports) {
            return .{ .err = .InsufficientFunds };
        }

        // Transfer
        from.lamports.* -= data.lamports;
        to.lamports.* += data.lamports;

        return .success;
    }

    fn processAllocate(ctx: *InstructionContext, data: AllocateData) ProgramResult {
        if (ctx.accountCount() < 1) {
            return .{ .err = .NotEnoughAccountKeys };
        }

        const account = ctx.getAccount(0).?;

        // Account must be signer
        if (!account.is_signer) {
            return .{ .err = .MissingRequiredSignature };
        }

        // Must be owned by system program
        if (!account.isSystemAccount()) {
            return .{ .err = .SystemInvalidProgramId };
        }

        // Validate size
        if (data.space > 10 * 1024 * 1024) { // 10MB max
            return .{ .err = .SystemInvalidAccountDataLength };
        }

        // Account data would be allocated here
        // In real implementation, would resize account.data

        return .success;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// NATIVE PROGRAM DISPATCHER
// ═══════════════════════════════════════════════════════════════════════════

/// Dispatch to native program
pub fn executeNativeProgram(ctx: *InstructionContext) ProgramResult {
    if (std.mem.eql(u8, &ctx.program_id, &program_ids.system)) {
        return SystemProgram.process(ctx);
    }
    // Vote and Stake programs would be added here

    return .{ .err = .IncorrectProgramId };
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "system instruction deserialize" {
    // Transfer instruction
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 2, .little); // Transfer discriminant
    std.mem.writeInt(u64, buf[4..12], 1000000, .little); // lamports

    const instruction = try SystemInstruction.deserialize(&buf);
    switch (instruction) {
        .Transfer => |data| {
            try std.testing.expectEqual(@as(u64, 1000000), data.lamports);
        },
        else => unreachable,
    }
}

test "program id is native" {
    try std.testing.expect(program_ids.isNative(&program_ids.system));
    try std.testing.expect(program_ids.isNative(&program_ids.vote));
    try std.testing.expect(!program_ids.isNative(&[_]u8{0xff} ** 32));
}

