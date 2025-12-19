//! Vexor Bank Implementation
//!
//! A Bank represents the state at a specific slot.
//! It manages:
//! - Account state
//! - Transaction execution
//! - Fee collection
//! - Hash computation
//!
//! Reference: Solana's Bank is the core state machine

const std = @import("std");
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const crypto = @import("../crypto/root.zig");
const bpf = @import("bpf/root.zig");

/// Known native program IDs
const NATIVE_PROGRAMS = struct {
    /// System program
    pub const SYSTEM: [32]u8 = [_]u8{0} ** 32;
    /// Vote program
    pub const VOTE: [32]u8 = blk: {
        var id = [_]u8{0} ** 32;
        id[0] = 0x07;
        id[1] = 0x61;
        id[2] = 0x48;
        id[3] = 0x1d;
        break :blk id;
    };
    /// Stake program
    pub const STAKE: [32]u8 = blk: {
        var id = [_]u8{0} ** 32;
        id[0] = 0x06;
        id[1] = 0xa1;
        id[2] = 0xd8;
        id[3] = 0x17;
        break :blk id;
    };
    /// BPF loader
    pub const BPF_LOADER: [32]u8 = blk: {
        var id = [_]u8{0} ** 32;
        id[0] = 0x02;
        id[1] = 0xc8;
        id[2] = 0x06;
        break :blk id;
    };
};

/// Bank representing state at a specific slot
pub const Bank = struct {
    allocator: std.mem.Allocator,

    /// Slot this bank represents
    slot: core.Slot,

    /// Parent slot
    parent_slot: ?core.Slot,

    /// Block height (slots since genesis)
    block_height: u64,

    /// Recent blockhash
    blockhash: core.Hash,

    /// Parent's bank hash
    parent_hash: core.Hash,

    /// Current bank hash (updated after processing)
    bank_hash: core.Hash,

    /// Reference to accounts database
    accounts_db: *storage.AccountsDb,

    /// Transaction count in this slot
    transaction_count: u64,

    /// Signature count
    signature_count: u64,

    /// Collected fees
    collected_fees: u64,

    /// Epoch information
    epoch: core.Epoch,
    epoch_schedule: EpochSchedule,

    /// Rent collector state
    rent_collector: RentCollector,

    /// Is this bank frozen (no more modifications)
    is_frozen: bool,

    const Self = @This();

    /// Create a new bank for a slot
    pub fn init(
        allocator: std.mem.Allocator,
        slot: core.Slot,
        parent: ?*const Bank,
        accounts_db: *storage.AccountsDb,
    ) !*Self {
        const bank = try allocator.create(Self);

        const parent_hash = if (parent) |p| p.bank_hash else core.Hash.ZERO;
        const parent_slot = if (parent) |p| p.slot else null;
        const block_height = if (parent) |p| p.block_height + 1 else 0;

        bank.* = .{
            .allocator = allocator,
            .slot = slot,
            .parent_slot = parent_slot,
            .block_height = block_height,
            .blockhash = core.Hash.ZERO, // Computed from leader
            .parent_hash = parent_hash,
            .bank_hash = core.Hash.ZERO, // Computed when frozen
            .accounts_db = accounts_db,
            .transaction_count = 0,
            .signature_count = 0,
            .collected_fees = 0,
            .epoch = 0, // TODO: Calculate from slot
            .epoch_schedule = EpochSchedule.default(),
            .rent_collector = RentCollector.init(),
            .is_frozen = false,
        };

        return bank;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Process a batch of transactions
    pub fn processTransactions(self: *Self, txs: []const Transaction) !BatchResult {
        if (self.is_frozen) return error.BankFrozen;

        var successful: u64 = 0;
        var failed: u64 = 0;
        var total_fees: u64 = 0;

        for (txs) |*tx| {
            const result = self.processTransaction(tx);
            if (result.success) {
                successful += 1;
                total_fees += result.fee;
            } else {
                failed += 1;
            }
        }

        self.transaction_count += successful + failed;
        self.collected_fees += total_fees;

        return BatchResult{
            .successful = successful,
            .failed = failed,
            .fees_collected = total_fees,
        };
    }

    /// Process a single transaction
    /// Optimized with pre-allocated account loading and overflow-safe compute tracking
    pub fn processTransaction(self: *Self, tx: *const Transaction) TransactionResult {
        // 1. Verify signatures (should already be done by sigverify)
        if (!tx.signatures_verified) {
            return .{ .success = false, .fee = 0, .error_code = .SignatureFailure };
        }

        // 2. Check fee payer has enough lamports
        const fee = self.calculateFee(tx);
        const fee_payer = self.accounts_db.getAccount(&tx.fee_payer);
        if (fee_payer == null or fee_payer.?.lamports < fee) {
            return .{ .success = false, .fee = 0, .error_code = .InsufficientFundsForFee };
        }

        // 3. Load all accounts needed by transaction
        // Pre-allocate HashMap capacity for better performance
        var loaded_accounts = LoadedAccounts.init(self.allocator);
        defer loaded_accounts.deinit();
        
        // Pre-allocate for expected account count
        loaded_accounts.ensureCapacity(tx.account_keys.len) catch {
            return .{ .success = false, .fee = 0, .error_code = .AccountNotFound };
        };
        
        for (tx.account_keys) |*pubkey| {
            const account = self.accounts_db.getAccount(pubkey);
            loaded_accounts.add(pubkey, account) catch {
                return .{ .success = false, .fee = 0, .error_code = .AccountNotFound };
            };
        }

        // 4. Execute each instruction with overflow-safe compute tracking
        var compute_units_used: u64 = 0;
        const compute_limit = if (tx.compute_unit_limit > 0) 
            @as(u64, tx.compute_unit_limit) 
        else 
            bpf.ComputeBudget.DEFAULT_UNITS;

        for (tx.instructions) |*ix| {
            // Bounds check: validate program_id_index
            if (ix.program_id_index >= tx.account_keys.len) {
                return .{ .success = false, .fee = fee, .error_code = .InvalidInstruction };
            }
            
            // Get program account
            const program_id = tx.account_keys[ix.program_id_index];
            
            // Check if native program
            const result = if (self.isNativeProgram(&program_id))
                self.executeNativeProgram(&program_id, ix, &loaded_accounts)
            else
                self.executeBpfProgram(&program_id, ix, &loaded_accounts);
            
            if (result.err) |err| {
                return .{ .success = false, .fee = fee, .error_code = err };
            }
            
            // Overflow-safe compute unit accumulation
            const new_compute = @addWithOverflow(compute_units_used, result.compute_units);
            if (new_compute[1] != 0) {
                // Overflow occurred - treat as exceeding budget
                return .{ .success = false, .fee = fee, .error_code = .ComputeBudgetExceeded };
            }
            compute_units_used = new_compute[0];
            
            // Check compute budget
            if (compute_units_used > compute_limit) {
                return .{ .success = false, .fee = fee, .error_code = .ComputeBudgetExceeded };
            }
        }

        // 5. Commit account changes
        loaded_accounts.commit(self.accounts_db, self.slot) catch {
            return .{ .success = false, .fee = fee, .error_code = .InvalidAccountData };
        };

        // 6. Deduct fee from fee payer
        self.deductFee(&tx.fee_payer, fee) catch {};

        self.signature_count += tx.signature_count;

        return .{ .success = true, .fee = fee, .error_code = null };
    }
    
    /// Check if program is a native program
    fn isNativeProgram(_: *Self, program_id: *const core.Pubkey) bool {
        return std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.SYSTEM) or
               std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.VOTE) or
               std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.STAKE);
    }
    
    /// Execute a native program
    fn executeNativeProgram(
        self: *Self,
        program_id: *const core.Pubkey,
        ix: *const Instruction,
        accounts: *LoadedAccounts,
    ) InstructionResult {
        _ = self;
        _ = accounts;
        
        if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.SYSTEM)) {
            return executeSystemProgram(ix);
        } else if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.VOTE)) {
            return executeVoteProgram(ix);
        } else if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.STAKE)) {
            return executeStakeProgram(ix);
        }
        
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }
    
    /// Execute a BPF program
    fn executeBpfProgram(
        self: *Self,
        program_id: *const core.Pubkey,
        ix: *const Instruction,
        accounts: *LoadedAccounts,
    ) InstructionResult {
        // Get program account data (contains ELF)
        const program_account = self.accounts_db.getAccount(program_id);
        if (program_account == null) {
            return .{ .compute_units = 0, .err = .AccountNotFound };
        }
        
        if (!program_account.?.executable) {
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        }
        
        // For now, return success with estimated compute units
        // Full BPF execution would use the bpf.executeProgram function
        _ = ix;
        _ = accounts;
        
        return .{ .compute_units = 1000, .err = null };
    }
    
    /// Deduct fee from account
    fn deductFee(self: *Self, pubkey: *const core.Pubkey, fee: u64) !void {
        // In full implementation, would modify account in accounts_db
        _ = self;
        _ = pubkey;
        _ = fee;
    }

    /// Calculate transaction fee
    fn calculateFee(self: *const Self, tx: *const Transaction) u64 {
        _ = self;
        // Base fee per signature + compute unit cost
        const base_fee: u64 = 5000; // lamports
        return base_fee * @as(u64, tx.signature_count);
    }

    /// Freeze the bank (no more transactions)
    pub fn freeze(self: *Self) !void {
        if (self.is_frozen) return;

        // Compute bank hash
        self.bank_hash = try self.computeBankHash();
        self.is_frozen = true;
    }

    /// Compute bank hash from state
    fn computeBankHash(self: *Self) !core.Hash {
        // Bank hash = SHA256(parent_hash || accounts_delta_hash || signature_count || blockhash)
        const accounts_hash = try self.accounts_db.computeHash();
        return crypto.hash_mod.hashBankState(
            self.parent_hash,
            accounts_hash,
            self.signature_count,
            self.blockhash,
        );
    }

    /// Get an account from this bank's view
    pub fn getAccount(self: *const Self, pubkey: *const core.Pubkey) ?*const storage.accounts.Account {
        return self.accounts_db.getAccount(pubkey);
    }

    /// Get account balance
    pub fn getBalance(self: *const Self, pubkey: *const core.Pubkey) u64 {
        if (self.getAccount(pubkey)) |account| {
            return account.lamports;
        }
        return 0;
    }
};

/// Transaction to be processed
pub const Transaction = struct {
    /// Fee payer pubkey
    fee_payer: core.Pubkey,

    /// All signatures on this transaction
    signatures: []const core.Signature,

    /// Number of signatures
    signature_count: u8,

    /// Whether signatures have been verified
    signatures_verified: bool,

    /// Transaction message (serialized instructions)
    message: []const u8,

    /// Recent blockhash used
    recent_blockhash: core.Hash,

    /// Compute unit limit requested
    compute_unit_limit: u32,

    /// Compute unit price (priority fee)
    compute_unit_price: u64,
    
    /// Account keys referenced by this transaction
    account_keys: []const core.Pubkey,
    
    /// Instructions to execute
    instructions: []const Instruction,
};

/// Result of processing a single transaction
pub const TransactionResult = struct {
    success: bool,
    fee: u64,
    error_code: ?TransactionError,
};

/// Result of processing a batch
pub const BatchResult = struct {
    successful: u64,
    failed: u64,
    fees_collected: u64,
};

/// Transaction error codes
pub const TransactionError = enum {
    SignatureFailure,
    InsufficientFundsForFee,
    InsufficientFundsForRent,
    AccountNotFound,
    AccountInUse,
    InvalidAccountData,
    InvalidInstruction,
    ComputeBudgetExceeded,
    DuplicateInstruction,
    BlockhashNotFound,
    AlreadyProcessed,
};

/// Instruction within a transaction
pub const Instruction = struct {
    /// Index of program account in account_keys
    program_id_index: u8,
    /// Indices into account_keys for accounts to pass
    account_indices: []const u8,
    /// Instruction data
    data: []const u8,
};

/// Result of executing a single instruction
pub const InstructionResult = struct {
    compute_units: u64,
    err: ?TransactionError,
};

/// Maximum accounts per transaction (Solana limit is 64)
const MAX_TX_ACCOUNTS: usize = 64;

/// Loaded accounts for transaction execution
/// Optimized with fixed-size array + HashMap for O(1) lookup on hot path
pub const LoadedAccounts = struct {
    allocator: std.mem.Allocator,
    
    /// Fixed-size storage to avoid heap allocation on hot path
    accounts_storage: [MAX_TX_ACCOUNTS]LoadedAccount,
    count: usize,
    
    /// HashMap for O(1) pubkey -> index lookup
    index_map: std.AutoHashMap([32]u8, usize),
    
    pub const LoadedAccount = struct {
        pubkey: core.Pubkey,
        original: ?*const storage.accounts.Account,
        modified: ?storage.accounts.Account,
        is_writable: bool,
        
        /// Default/empty account for initialization
        pub const EMPTY: LoadedAccount = .{
            .pubkey = core.Pubkey{ .data = [_]u8{0} ** 32 },
            .original = null,
            .modified = null,
            .is_writable = false,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) LoadedAccounts {
        return .{
            .allocator = allocator,
            .accounts_storage = [_]LoadedAccount{LoadedAccount.EMPTY} ** MAX_TX_ACCOUNTS,
            .count = 0,
            .index_map = std.AutoHashMap([32]u8, usize).init(allocator),
        };
    }
    
    pub fn deinit(self: *LoadedAccounts) void {
        self.index_map.deinit();
    }
    
    /// Pre-allocate HashMap capacity for expected number of accounts
    /// Call this before adding accounts for better performance
    pub fn ensureCapacity(self: *LoadedAccounts, expected_count: usize) !void {
        try self.index_map.ensureTotalCapacity(@intCast(@min(expected_count, MAX_TX_ACCOUNTS)));
    }
    
    pub fn add(self: *LoadedAccounts, pubkey: *const core.Pubkey, account: ?*const storage.accounts.Account) !void {
        if (self.count >= MAX_TX_ACCOUNTS) {
            return error.TooManyAccounts;
        }
        
        // Check for duplicate (return early if already present)
        if (self.index_map.get(pubkey.data)) |_| {
            return; // Already added, skip
        }
        
        const index = self.count;
        self.accounts_storage[index] = .{
            .pubkey = pubkey.*,
            .original = account,
            .modified = null,
            .is_writable = true,
        };
        
        // Add to index map for O(1) lookup
        try self.index_map.put(pubkey.data, index);
        self.count += 1;
    }
    
    /// O(1) lookup using HashMap
    pub fn get(self: *LoadedAccounts, pubkey: *const core.Pubkey) ?*LoadedAccount {
        if (self.index_map.get(pubkey.data)) |index| {
            return &self.accounts_storage[index];
        }
        return null;
    }
    
    /// Get account by index (for iteration)
    pub fn getByIndex(self: *LoadedAccounts, index: usize) ?*LoadedAccount {
        if (index < self.count) {
            return &self.accounts_storage[index];
        }
        return null;
    }
    
    /// Iterator over loaded accounts
    pub fn items(self: *LoadedAccounts) []LoadedAccount {
        return self.accounts_storage[0..self.count];
    }
    
    pub fn commit(self: *LoadedAccounts, accounts_db: *storage.AccountsDb, slot: core.Slot) !void {
        for (self.accounts_storage[0..self.count]) |*acc| {
            if (acc.modified) |*modified| {
                try accounts_db.storeAccount(&acc.pubkey, modified, slot);
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// NATIVE PROGRAM IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// System program instruction types
const SystemInstruction = enum(u32) {
    CreateAccount = 0,
    Assign = 1,
    Transfer = 2,
    CreateAccountWithSeed = 3,
    AdvanceNonceAccount = 4,
    WithdrawNonceAccount = 5,
    InitializeNonceAccount = 6,
    AuthorizeNonceAccount = 7,
    Allocate = 8,
    AllocateWithSeed = 9,
    AssignWithSeed = 10,
    TransferWithSeed = 11,
    UpgradeNonceAccount = 12,
};

/// Execute system program
fn executeSystemProgram(ix: *const Instruction) InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }
    
    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);
    
    return switch (@as(SystemInstruction, @enumFromInt(instruction_type))) {
        .Transfer => .{ .compute_units = 150, .err = null },
        .CreateAccount => .{ .compute_units = 150, .err = null },
        .Assign => .{ .compute_units = 150, .err = null },
        .Allocate => .{ .compute_units = 150, .err = null },
        else => .{ .compute_units = 150, .err = null },
    };
}

/// Vote program instruction types
const VoteInstruction = enum(u32) {
    InitializeAccount = 0,
    Authorize = 1,
    Vote = 2,
    Withdraw = 3,
    UpdateValidatorIdentity = 4,
    UpdateCommission = 5,
    VoteSwitch = 6,
    AuthorizeChecked = 7,
    UpdateVoteState = 8,
    UpdateVoteStateSwitch = 9,
    AuthorizeWithSeed = 10,
    WithdrawWithSeed = 11,
    CompactUpdateVoteState = 12,
    CompactUpdateVoteStateSwitch = 13,
};

/// Execute vote program
fn executeVoteProgram(ix: *const Instruction) InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }
    
    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);
    
    return switch (@as(VoteInstruction, @enumFromInt(instruction_type))) {
        .Vote, .VoteSwitch => .{ .compute_units = 2100, .err = null },
        .CompactUpdateVoteState, .CompactUpdateVoteStateSwitch => .{ .compute_units = 2100, .err = null },
        .UpdateVoteState, .UpdateVoteStateSwitch => .{ .compute_units = 2100, .err = null },
        else => .{ .compute_units = 450, .err = null },
    };
}

/// Stake program instruction types  
const StakeInstruction = enum(u32) {
    Initialize = 0,
    Authorize = 1,
    DelegateStake = 2,
    Split = 3,
    Withdraw = 4,
    Deactivate = 5,
    SetLockup = 6,
    Merge = 7,
    AuthorizeWithSeed = 8,
    InitializeChecked = 9,
    AuthorizeChecked = 10,
    AuthorizeCheckedWithSeed = 11,
    SetLockupChecked = 12,
    GetMinimumDelegation = 13,
    DeactivateDelinquent = 14,
    Redelegate = 15,
};

/// Execute stake program
fn executeStakeProgram(ix: *const Instruction) InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }
    
    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);
    
    return switch (@as(StakeInstruction, @enumFromInt(instruction_type))) {
        .DelegateStake => .{ .compute_units = 750, .err = null },
        .Deactivate => .{ .compute_units = 750, .err = null },
        .Withdraw => .{ .compute_units = 750, .err = null },
        else => .{ .compute_units = 450, .err = null },
    };
}

/// Epoch schedule configuration
pub const EpochSchedule = struct {
    /// Slots per epoch
    slots_per_epoch: u64,

    /// Leader schedule epoch offset
    leader_schedule_slot_offset: u64,

    /// Whether epochs are warmed up
    warmup: bool,

    /// First normal epoch
    first_normal_epoch: u64,

    /// First normal slot
    first_normal_slot: u64,

    pub fn default() EpochSchedule {
        return .{
            .slots_per_epoch = 432000, // ~2 days at 400ms/slot
            .leader_schedule_slot_offset = 432000,
            .warmup = false,
            .first_normal_epoch = 0,
            .first_normal_slot = 0,
        };
    }

    /// Get epoch for a slot
    pub fn getEpoch(self: *const EpochSchedule, slot: core.Slot) core.Epoch {
        return @intCast(slot / self.slots_per_epoch);
    }

    /// Get first slot of an epoch
    pub fn getFirstSlotInEpoch(self: *const EpochSchedule, epoch: core.Epoch) core.Slot {
        return epoch * self.slots_per_epoch;
    }

    /// Get last slot of an epoch
    pub fn getLastSlotInEpoch(self: *const EpochSchedule, epoch: core.Epoch) core.Slot {
        return self.getFirstSlotInEpoch(epoch + 1) - 1;
    }
};

/// Rent collector
pub const RentCollector = struct {
    /// Rent rate (lamports per byte per epoch)
    lamports_per_byte_year: u64,

    /// Minimum balance for rent exemption (2 years)
    exemption_threshold: f64,

    /// Burn percentage
    burn_percent: u8,

    pub fn init() RentCollector {
        return .{
            .lamports_per_byte_year = 3480,
            .exemption_threshold = 2.0,
            .burn_percent = 50,
        };
    }

    /// Calculate minimum balance for rent exemption
    pub fn minimumBalance(self: *const RentCollector, data_len: usize) u64 {
        const bytes: u64 = @intCast(data_len + 128); // Account overhead
        return @intFromFloat(@as(f64, @floatFromInt(bytes * self.lamports_per_byte_year)) * self.exemption_threshold);
    }

    /// Calculate rent due
    pub fn rentDue(self: *const RentCollector, account: *const storage.accounts.Account, epochs_elapsed: u64) u64 {
        // Check if rent exempt
        if (account.lamports >= self.minimumBalance(account.data.len)) {
            return 0;
        }

        const bytes: u64 = @intCast(account.data.len + 128);
        return (bytes * self.lamports_per_byte_year * epochs_elapsed) / 365;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "epoch schedule" {
    const schedule = EpochSchedule.default();
    try std.testing.expectEqual(@as(core.Epoch, 0), schedule.getEpoch(0));
    try std.testing.expectEqual(@as(core.Epoch, 0), schedule.getEpoch(431999));
    try std.testing.expectEqual(@as(core.Epoch, 1), schedule.getEpoch(432000));
}

test "rent collector" {
    const collector = RentCollector.init();
    const min = collector.minimumBalance(100);
    try std.testing.expect(min > 0);
}

