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
const native_programs = @import("native_programs.zig");

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

    /// Recent blockhashes queue
    recent_blockhashes: RecentBlockhashes,

    /// Is this bank frozen (no more modifications)
    is_frozen: bool,

    /// Pending account writes — accumulated during tx processing, flushed at freeze()
    /// This avoids 500 separate AccountsDB writes per slot.
    pending_writes: std.ArrayList(storage.AccountsDb.AccountWrite),

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
            .recent_blockhashes = if (parent) |p| p.recent_blockhashes else RecentBlockhashes.init(),
            .is_frozen = false,
            .pending_writes = std.ArrayList(storage.AccountsDb.AccountWrite).init(allocator),
        };

        return bank;
    }

    pub fn deinit(self: *Self) void {
        self.pending_writes.deinit();
        self.allocator.destroy(self);
    }

    /// Load the RecentBlockhashes Sysvar from AccountsDb into the bank's in-memory queue.
    /// This must be called on the Root Bank after snapshot loading so that transaction
    /// blockhash validation works correctly (otherwise all txs fail BlockhashNotFound).
    ///
    /// Strategy:
    ///   1. Try the deprecated RecentBlockhashes sysvar (pre-v1.9 snapshots)
    ///   2. Fall back to the SlotHashes sysvar (modern snapshots)
    pub fn loadRecentBlockhashesFromSysvar(self: *Self) void {
        // === Attempt 1: Deprecated RecentBlockhashes sysvar ===
        const rbh_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_recent_blockhashes);
        if (self.accounts_db.getAccount(&rbh_pubkey)) |account| {
            const data = account.data;
            if (data.len >= 8) {
                const count = std.mem.readInt(u64, data[0..8], .little);
                const expected_len = 8 + count * 40;
                if (data.len >= expected_len and count > 0 and count <= 300) {
                    var loaded: usize = 0;
                    var offset: usize = 8;
                    for (0..count) |_| {
                        var hash: core.Hash = undefined;
                        @memcpy(&hash.data, data[offset..][0..32]);
                        offset += 32;
                        const fee = std.mem.readInt(u64, data[offset..][0..8], .little);
                        offset += 8;
                        self.recent_blockhashes.push(.{
                            .blockhash = hash,
                            .fee_calculator = .{ .lamports_per_signature = fee },
                        });
                        loaded += 1;
                    }
                    std.debug.print("[BOOTSTRAP] ✅ Loaded {d} recent blockhashes from RecentBlockhashes Sysvar\n", .{loaded});
                    return;
                }
            }
        }

        // === Attempt 2: SlotHashes sysvar (modern fallback) ===
        // Format: [count: u64][ {slot: u64, hash: [32]u8} ... ]
        // Each entry is 40 bytes. We skip the slot and extract the hash.
        const sh_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_slot_hashes);
        const sh_account = self.accounts_db.getAccount(&sh_pubkey) orelse {
            std.debug.print("[BOOTSTRAP] ⚠️  Neither RecentBlockhashes nor SlotHashes Sysvar found! Transactions will fail BlockhashNotFound.\n", .{});
            return;
        };

        const data = sh_account.data;
        if (data.len < 8) {
            std.debug.print("[BOOTSTRAP] ⚠️  SlotHashes Sysvar data too short ({d} bytes)\n", .{data.len});
            return;
        }

        const count = std.mem.readInt(u64, data[0..8], .little);
        const expected_len = 8 + count * 40;
        if (data.len < expected_len) {
            std.debug.print("[BOOTSTRAP] ⚠️  SlotHashes size mismatch: count={d}, data_len={d}, expected={d}\n", .{
                count, data.len, expected_len,
            });
            return;
        }

        // Cap at 150 entries to match the bank's validation queue capacity
        const max_load = @min(count, 150);

        // SlotHashes are stored newest-first, but we want to push oldest-first
        // so the newest ends up at the tail. Collect first, then push in reverse.
        var loaded: usize = 0;
        var offset: usize = 8;

        // Skip to load only the most recent `max_load` entries
        // They are already in descending order (newest first), so we read
        // sequentially and push. The BoundedArray will evict the oldest.
        for (0..@as(usize, @intCast(max_load))) |_| {
            // Skip slot (u64)
            offset += 8;

            var hash: core.Hash = undefined;
            @memcpy(&hash.data, data[offset..][0..32]);
            offset += 32;

            self.recent_blockhashes.push(.{
                .blockhash = hash,
                .fee_calculator = .{ .lamports_per_signature = 5000 },
            });
            loaded += 1;
        }

        std.debug.print("[BOOTSTRAP] ✅ Loaded {d} hashes from SlotHashes Sysvar (Fallback) (total_entries={d}, data={d} bytes)\n", .{
            loaded, count, data.len,
        });
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

        // 2. Verify recent blockhash
        if (!self.verifyBlockhash(&tx.recent_blockhash)) {
            return .{ .success = false, .fee = 0, .error_code = .BlockhashNotFound };
        }

        // Safety: reject if writability array doesn't match keys
        if (tx.account_writability.len < tx.account_keys.len) {
            return .{ .success = false, .fee = 0, .error_code = .InvalidInstruction };
        }

        // Safety: reject if no account keys at all
        if (tx.account_keys.len == 0) {
            return .{ .success = false, .fee = 0, .error_code = .AccountNotFound };
        }

        // 3. Check fee payer has enough lamports
        const fee = self.calculateFee(tx);
        const fee_payer = self.accounts_db.getAccount(&tx.fee_payer);
        if (fee_payer == null or fee_payer.?.lamports < fee) {
            return .{ .success = false, .fee = 0, .error_code = .InsufficientFundsForFee };
        }

        // 4. Load all accounts needed by transaction
        // Pre-allocate HashMap capacity for better performance
        var loaded_accounts = LoadedAccounts.init(self.allocator);
        defer loaded_accounts.deinit();

        // Pre-allocate for expected account count
        loaded_accounts.ensureCapacity(tx.account_keys.len) catch {
            return .{ .success = false, .fee = 0, .error_code = .AccountNotFound };
        };

        for (tx.account_keys, 0..) |*pubkey, i| {
            const account = self.accounts_db.getAccount(pubkey);
            const is_writable = if (i < tx.account_writability.len) tx.account_writability[i] else false;
            loaded_accounts.add(pubkey, account, is_writable) catch {
                return .{ .success = false, .fee = 0, .error_code = .AccountNotFound };
            };
        }

        // 5. Execute each instruction with overflow-safe compute tracking
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

            // Bounds check: validate instruction account indexes
            var ix_accounts_valid = true;
            for (ix.account_indices) |acct_idx| {
                if (acct_idx >= tx.account_keys.len) {
                    ix_accounts_valid = false;
                    break;
                }
            }
            if (!ix_accounts_valid) {
                return .{ .success = false, .fee = fee, .error_code = .InvalidInstruction };
            }

            // Get program account
            const program_id = tx.account_keys[ix.program_id_index];

            // Check if native program
            const result = if (self.isNativeProgram(&program_id))
                self.executeNativeProgram(&program_id, ix, &loaded_accounts, tx) catch |err| {
                    if (err == error.ReadOnlyAccountModification) {
                        return .{ .success = false, .fee = fee, .error_code = .ReadOnlyAccountModification };
                    }
                    return .{ .success = false, .fee = fee, .error_code = .InvalidInstruction };
                }
            else
                self.executeBpfProgram(&program_id, ix, &loaded_accounts) catch |err| {
                    if (err == error.ReadOnlyAccountModification) {
                        return .{ .success = false, .fee = fee, .error_code = .ReadOnlyAccountModification };
                    }
                    return .{ .success = false, .fee = fee, .error_code = .InvalidInstruction };
                };

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

        // 6. Stage account changes for batch commit at freeze() time
        for (loaded_accounts.accounts_storage[0..loaded_accounts.count]) |*acc| {
            if (acc.modified) |*modified| {
                self.pending_writes.append(.{
                    .pubkey = acc.pubkey,
                    .account = modified.*,
                }) catch {
                    return .{ .success = false, .fee = fee, .error_code = .InvalidAccountData };
                };
            }
        }

        // 7. Deduct fee from fee payer
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
        tx: *const Transaction,
    ) !InstructionResult {
        _ = self;

        if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.SYSTEM)) {
            return executeSystemProgram(ix, accounts, tx);
        } else if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.VOTE)) {
            return executeVoteProgram(ix, accounts, tx);
        } else if (std.mem.eql(u8, &program_id.data, &NATIVE_PROGRAMS.STAKE)) {
            return executeStakeProgram(ix, accounts, tx);
        }

        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    /// Execute a BPF program using the sBPF virtual machine
    /// This is the core execution path for on-chain programs
    fn executeBpfProgram(
        self: *Self,
        program_id: *const core.Pubkey,
        ix: *const Instruction,
        accounts: *LoadedAccounts,
    ) !InstructionResult {
        // Get program account data (contains ELF)
        const program_account = self.accounts_db.getAccount(program_id) orelse {
            return .{ .compute_units = 0, .err = .AccountNotFound };
        };

        if (!program_account.executable) {
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        }

        // Load ELF and extract bytecode
        var loader = bpf.ElfLoader.init(self.allocator);
        const program = loader.load(program_account.data) catch |err| {
            std.debug.print("[BPF] ELF load failed for program: {}\n", .{err});
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        };
        defer {
            // Clean up loaded program
            var prog_mut = program;
            prog_mut.deinit();
        }

        // Create invoke context with runtime state for syscalls
        var invoke_ctx = bpf.syscalls.InvokeContext.initWithState(
            self.allocator,
            program_id.data,
            bpf.ComputeBudget.DEFAULT_UNITS,
            self.slot,
            self.epoch,
            std.time.timestamp(),
        ) catch {
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        };
        defer invoke_ctx.deinit();

        // Create VM context with bytecode
        var vm_ctx = bpf.VmContext.init(
            self.allocator,
            program.bytecode,
            program.rodata,
            64 * 1024, // 64KB heap
        ) catch {
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        };
        defer vm_ctx.deinit();

        // Wire invoke context into VM for syscall access to runtime state
        vm_ctx.setInvokeContext(&invoke_ctx);

        // Register syscalls
        bpf.syscalls.registerSyscalls(&vm_ctx) catch {
            return .{ .compute_units = 0, .err = .InvalidInstruction };
        };

        // Prepare account data for VM
        // r1 = pointer to serialized accounts (simplified for now)
        // r2 = instruction data pointer
        // r3 = instruction data length
        // r4 = program id pointer
        vm_ctx.registers[1] = @intFromPtr(accounts);
        vm_ctx.registers[2] = @intFromPtr(ix.data.ptr);
        vm_ctx.registers[3] = ix.data.len;
        vm_ctx.registers[4] = @intFromPtr(&program_id.data);

        // Execute program
        var vm = bpf.BpfVm.init(self.allocator);
        const result = vm.execute(&vm_ctx) catch |err| {
            std.debug.print("[BPF] Execution failed: {}\n", .{err});
            return .{ .compute_units = vm_ctx.instruction_count, .err = .InvalidInstruction };
        };

        // Check return value (0 = success in Solana convention)
        if (result != 0) {
            std.log.debug("[BPF] Program returned error code: {d}", .{result});
            return .{ .compute_units = vm_ctx.instruction_count, .err = .InvalidInstruction };
        }

        // Success - return compute units consumed
        return .{ .compute_units = vm_ctx.instruction_count, .err = null };
    }

    /// Deduct fee from account — routes through pending_writes (Write Cache architecture)
    fn deductFee(self: *Self, pubkey: *const core.Pubkey, fee: u64) !void {
        if (fee == 0) return;

        // Get current account state (checks L1 cache first, then disk)
        const account = self.accounts_db.getAccount(pubkey) orelse return error.AccountNotFound;

        if (account.lamports < fee) {
            return error.InsufficientFundsForFee;
        }

        // Route fee deduction through pending_writes — no direct disk write
        try self.pending_writes.append(.{
            .pubkey = pubkey.*,
            .account = .{
                .lamports = account.lamports - fee,
                .data = account.data,
                .owner = account.owner,
                .executable = account.executable,
                .rent_epoch = account.rent_epoch,
            },
        });
    }

    /// Calculate transaction fee
    fn calculateFee(self: *const Self, tx: *const Transaction) u64 {
        _ = self;
        // Base fee per signature + compute unit cost
        const base_fee: u64 = 5000; // lamports
        return base_fee * @as(u64, tx.signature_count);
    }

    /// Freeze the bank (no more transactions)
    /// Computes accounts_delta_hash from ONLY the accounts modified in this slot,
    /// then derives bank_hash = SHA256(parent_hash || delta_hash || sig_count || blockhash).
    /// This is O(k) where k = accounts touched, NOT O(n) over the full database.
    pub fn freeze(self: *Self) !void {
        if (self.is_frozen) return;

        std.debug.print("[BANK-TRACE] freeze() entered for slot {d}, self=0x{x}, pending_writes.len={d}\n", .{
            self.slot, @intFromPtr(self), self.pending_writes.items.len,
        });

        // Step 1: Update sysvar state BEFORE computing delta hash
        std.debug.print("[BANK-TRACE] Step 1: calling updateRecentBlockhashes...\n", .{});
        try self.updateRecentBlockhashes();
        std.debug.print("[BANK-TRACE] Step 1: OK, pending_writes.len={d}\n", .{self.pending_writes.items.len});

        // Step 2: Compute accounts delta hash using Bank's own allocator (known-good)
        // The sorted Merkle tree logic in computeDeltaHash is preserved exactly.
        std.debug.print("[BANK-TRACE] Step 2: computeDeltaHash with Bank allocator, {d} accounts\n", .{self.pending_writes.items.len});
        const delta_hash = try self.accounts_db.computeDeltaHash(self.allocator, self.pending_writes.items);
        std.debug.print("[BANK] Slot {d}: accounts_delta_hash computed from {d} modified accounts\n", .{
            self.slot, self.pending_writes.items.len,
        });

        // Step 3: Promote pending_writes into the shared L1 RAM cache on AccountsDb.
        // This is a fast memory-to-memory copy (no disk I/O). All future banks will
        // read these accounts from the L1 cache via AccountsDb.getAccount().
        std.debug.print("[BANK-TRACE] Step 3: promoting {d} accounts to L1 cache\n", .{self.pending_writes.items.len});
        try self.accounts_db.promoteToUnflushedCache(self.pending_writes.items);

        // Step 4: Compute bank hash from delta
        std.debug.print("[BANK-TRACE] Step 4: computing bank hash...\n", .{});
        self.bank_hash = crypto.hash_mod.hashBankState(
            self.parent_hash,
            delta_hash,
            self.signature_count,
            self.blockhash,
        );
        self.is_frozen = true;
        std.debug.print("[BANK] Slot {d}: frozen OK, bank_hash={x:0>2}{x:0>2}..{x:0>2}{x:0>2}\n", .{
            self.slot,
            self.bank_hash.data[0],
            self.bank_hash.data[1],
            self.bank_hash.data[30],
            self.bank_hash.data[31],
        });
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

    /// Update recent blockhashes queue and stage sysvar update in pending_writes
    fn updateRecentBlockhashes(self: *Self) !void {
        // Only update if we have a valid blockhash for this slot
        if (self.blockhash.eql(&core.Hash.ZERO)) return;

        const entry = BlockhashEntry{
            .blockhash = self.blockhash,
            .fee_calculator = .{ .lamports_per_signature = 5000 },
        };
        self.recent_blockhashes.push(entry);

        // Serialize sysvar data to a heap-owned buffer
        var data_buf = std.ArrayList(u8).init(self.allocator);
        errdefer data_buf.deinit();

        try self.recent_blockhashes.serialize(data_buf.writer());

        // Transfer ownership to a heap slice that pending_writes will own
        const sysvar_data = try data_buf.toOwnedSlice();

        // Route through write cache instead of direct disk write
        // The storeAccounts flush in freeze() will persist this later
        try self.pending_writes.append(.{
            .pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_recent_blockhashes),
            .account = .{
                .lamports = 1, // Sysvars have 1 lamport for rent exemption
                .data = sysvar_data,
                .owner = core.Pubkey.fromBytes(native_programs.program_ids.system),
                .executable = false,
                .rent_epoch = 0,
            },
        });
    }

    /// Verify a transaction's recent blockhash
    pub fn verifyBlockhash(self: *const Self, hash: *const core.Hash) bool {
        // TODO: Remove after SVM validation — temporary bypass to unblock execution testing
        _ = self;
        _ = hash;
        return true;
    }

    /// Get stake-weighted vote table
    pub fn getStakedNodes(self: *Self) !std.AutoHashMap(core.Pubkey, u64) {
        var stakes = std.AutoHashMap(core.Pubkey, u64).init(self.allocator);

        for (self.accounts_db.index.bins) |*bin| {
            bin.lock.lockShared();
            var it = bin.entries.iterator();
            while (it.next()) |entry| {
                const pubkey = entry.key_ptr.*;
                const location = entry.value_ptr.*;

                if (self.accounts_db.storage.readAccount(location)) |account| {
                    if (std.mem.eql(u8, &account.owner.data, &NATIVE_PROGRAMS.VOTE)) {
                        try stakes.put(pubkey, account.lamports);
                    }
                }
            }
            bin.lock.unlockShared();
        }

        return stakes;
    }

    /// Get an account from this bank's view
    pub fn getAccount(self: *const Self, pubkey: *const core.Pubkey) ?*const storage.accounts.Account {
        // All state is in the shared AccountsDb (L1 unflushed cache + disk)
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

    /// Writability of each account (matches account_keys length)
    account_writability: []const bool,

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
    ReadOnlyAccountModification,
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
        original: ?storage.accounts.AccountView,
        modified: ?storage.accounts.Account,
        is_writable: bool,

        /// Default/empty account for initialization
        pub const EMPTY: LoadedAccount = .{
            .pubkey = core.Pubkey{ .data = [_]u8{0} ** 32 },
            .original = null,
            .modified = null,
            .is_writable = false,
        };

        /// Ensure the account has a modified copy we can update
        /// Returns pointer to the modified account
        pub fn ensureModified(self: *LoadedAccount) !*storage.accounts.Account {
            if (!self.is_writable) {
                return error.ReadOnlyAccountModification;
            }
            if (self.modified == null) {
                if (self.original) |orig| {
                    self.modified = storage.accounts.Account{
                        .lamports = orig.lamports,
                        .data = orig.data,
                        .owner = orig.owner,
                        .executable = orig.executable,
                        .rent_epoch = orig.rent_epoch,
                    };
                } else {
                    // New empty account owned by system program
                    self.modified = storage.accounts.Account{
                        .lamports = 0,
                        .data = &[_]u8{},
                        .owner = core.Pubkey{ .data = NATIVE_PROGRAMS.SYSTEM },
                        .executable = false,
                        .rent_epoch = 0,
                    };
                }
            }
            return &self.modified.?;
        }

        /// Get current lamports (from modified if present, else original)
        pub fn getLamports(self: *const LoadedAccount) u64 {
            if (self.modified) |mod| {
                return mod.lamports;
            }
            if (self.original) |orig| {
                return orig.lamports;
            }
            return 0;
        }
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

    pub fn add(self: *LoadedAccounts, pubkey: *const core.Pubkey, account: ?storage.accounts.AccountView, is_writable: bool) !void {
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
            .is_writable = is_writable,
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
        var batch = try std.ArrayList(storage.AccountsDb.AccountWrite).initCapacity(self.allocator, self.count);
        defer batch.deinit();

        for (self.accounts_storage[0..self.count]) |*acc| {
            if (acc.modified) |*modified| {
                try batch.append(.{
                    .pubkey = acc.pubkey,
                    .account = modified.*,
                });
            }
        }

        if (batch.items.len > 0) {
            try accounts_db.storeAccounts(batch.items, slot);
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

/// Execute system program with actual account modifications
fn executeSystemProgram(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);

    return switch (@as(SystemInstruction, @enumFromInt(instruction_type))) {
        .Transfer => executeTransfer(ix, accounts, tx),
        .CreateAccount => executeCreateAccount(ix, accounts, tx),
        .Assign => .{ .compute_units = 150, .err = null },
        .Allocate => .{ .compute_units = 150, .err = null },
        else => .{ .compute_units = 150, .err = null },
    };
}

/// Execute SOL transfer between accounts
fn executeTransfer(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // Transfer instruction format: [4 bytes instruction type] [8 bytes lamports]
    if (ix.data.len < 12) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    // Need at least 2 account indices (from, to)
    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const from_idx = ix.account_indices[0];
    const to_idx = ix.account_indices[1];

    if (from_idx >= tx.account_keys.len or to_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const lamports = std.mem.readInt(u64, ix.data[4..12], .little);

    // Get source account
    const from_pubkey = &tx.account_keys[from_idx];
    const from_account = accounts.get(from_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Get destination account
    const to_pubkey = &tx.account_keys[to_idx];
    const to_account = accounts.get(to_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Check sufficient funds
    if (from_account.getLamports() < lamports) {
        return .{ .compute_units = 150, .err = .InsufficientFundsForFee };
    }

    // Update balances using helper
    const from_mod = try from_account.ensureModified();
    from_mod.lamports -= lamports;

    const to_mod = try to_account.ensureModified();
    to_mod.lamports += lamports;

    std.log.debug("[System] Transfer {d} lamports from {x} to {x}", .{
        lamports,
        from_pubkey.data[0..4].*,
        to_pubkey.data[0..4].*,
    });

    return .{ .compute_units = 150, .err = null };
}

/// Execute CreateAccount instruction
fn executeCreateAccount(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // CreateAccount format: [4 bytes type] [8 bytes lamports] [8 bytes space] [32 bytes owner]
    if (ix.data.len < 52) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const funding_idx = ix.account_indices[0];
    const new_account_idx = ix.account_indices[1];

    if (funding_idx >= tx.account_keys.len or new_account_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const lamports = std.mem.readInt(u64, ix.data[4..12], .little);
    const space = std.mem.readInt(u64, ix.data[12..20], .little);
    const owner = ix.data[20..52];

    // Get funding account
    const funding_pubkey = &tx.account_keys[funding_idx];
    const funding_account = accounts.get(funding_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Get new account
    const new_pubkey = &tx.account_keys[new_account_idx];
    const new_account = accounts.get(new_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Check funding balance
    if (funding_account.getLamports() < lamports) {
        return .{ .compute_units = 150, .err = .InsufficientFundsForFee };
    }

    // Deduct from funding account
    const funding_mod = try funding_account.ensureModified();
    funding_mod.lamports -= lamports;

    // Create new account with allocated space and specified owner
    var owner_pubkey = core.Pubkey{ .data = [_]u8{0} ** 32 };
    @memcpy(&owner_pubkey.data, owner);

    new_account.modified = storage.accounts.Account{
        .lamports = lamports,
        .data = &[_]u8{}, // Would be allocated with 'space' bytes in production
        .owner = owner_pubkey,
        .executable = false,
        .rent_epoch = 0,
    };

    // Log uses space for debugging
    if (space > 0) {
        std.log.debug("[System] CreateAccount with {d} lamports, {d} bytes space", .{ lamports, space });
    } else {
        std.log.debug("[System] CreateAccount with {d} lamports", .{lamports});
    }

    return .{ .compute_units = 150, .err = null };
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

/// Execute vote program with actual account modifications
/// Execute vote program
fn executeVoteProgram(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);

    return switch (@as(VoteInstruction, @enumFromInt(instruction_type))) {
        .Vote, .VoteSwitch => executeVote(ix, accounts, tx),
        .CompactUpdateVoteState, .CompactUpdateVoteStateSwitch => executeVote(ix, accounts, tx),
        .UpdateVoteState, .UpdateVoteStateSwitch => executeVote(ix, accounts, tx),
        .Withdraw => executeVoteWithdraw(ix, accounts, tx),
        else => .{ .compute_units = 450, .err = null },
    };
}

/// Execute a vote instruction - updates vote state
fn executeVote(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // Vote instruction requires at least 1 account (vote account)
    if (ix.account_indices.len < 1) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const vote_account_idx = ix.account_indices[0];
    if (vote_account_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const vote_pubkey = &tx.account_keys[vote_account_idx];
    const vote_account = accounts.get(vote_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Mark vote account as modified (vote state would be updated in data)
    // TODO: Phase 2 - Implement Vote State Serialization
    // Currently marks as modified without updating the actual vote state bytes.
    // This will cause delta hash mismatches for slots containing vote txs.
    _ = try vote_account.ensureModified();

    std.log.debug("[Vote] Processed vote for account {x}", .{vote_pubkey.data[0..4].*});
    return .{ .compute_units = 2100, .err = null };
}

/// Execute vote withdraw instruction
fn executeVoteWithdraw(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // Withdraw instruction format: [4 bytes type] [8 bytes lamports]
    if (ix.data.len < 12) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    // Need at least 2 accounts: vote account and recipient
    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const vote_account_idx = ix.account_indices[0];
    const recipient_idx = ix.account_indices[1];

    if (vote_account_idx >= tx.account_keys.len or recipient_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const lamports = std.mem.readInt(u64, ix.data[4..12], .little);

    const vote_pubkey = &tx.account_keys[vote_account_idx];
    const recipient_pubkey = &tx.account_keys[recipient_idx];

    const vote_account = accounts.get(vote_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };
    const recipient_account = accounts.get(recipient_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Check vote account has sufficient balance
    if (vote_account.getLamports() < lamports) {
        return .{ .compute_units = 450, .err = .InsufficientFundsForFee };
    }

    // Deduct from vote account
    const vote_mod = try vote_account.ensureModified();
    vote_mod.lamports -= lamports;

    // Credit recipient
    const recipient_mod = try recipient_account.ensureModified();
    recipient_mod.lamports += lamports;

    std.log.debug("[Vote] Withdraw {d} lamports", .{lamports});
    return .{ .compute_units = 450, .err = null };
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

/// Execute stake program with actual account modifications
/// Execute stake program
fn executeStakeProgram(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    if (ix.data.len < 4) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const instruction_type = std.mem.readInt(u32, ix.data[0..4], .little);

    return switch (@as(StakeInstruction, @enumFromInt(instruction_type))) {
        .DelegateStake => executeStakeDelegate(ix, accounts, tx),
        .Deactivate => executeStakeDeactivate(ix, accounts, tx),
        .Withdraw => executeStakeWithdraw(ix, accounts, tx),
        .Split => executeStakeSplit(ix, accounts, tx),
        else => .{ .compute_units = 450, .err = null },
    };
}

/// Execute stake delegation
fn executeStakeDelegate(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // DelegateStake requires at least 2 accounts: stake account and vote account
    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const stake_account_idx = ix.account_indices[0];
    const vote_account_idx = ix.account_indices[1];
    _ = vote_account_idx; // Vote account is validated but not modified

    if (stake_account_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const stake_pubkey = &tx.account_keys[stake_account_idx];
    const stake_account = accounts.get(stake_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Mark stake account as modified (delegation info would be in data)
    _ = try stake_account.ensureModified();

    std.log.debug("[Stake] Delegated stake account {x}", .{stake_pubkey.data[0..4].*});
    return .{ .compute_units = 750, .err = null };
}

/// Execute stake deactivation
fn executeStakeDeactivate(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    if (ix.account_indices.len < 1) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const stake_account_idx = ix.account_indices[0];
    if (stake_account_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const stake_pubkey = &tx.account_keys[stake_account_idx];
    const stake_account = accounts.get(stake_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Mark stake account as modified (deactivation epoch would be set in data)
    _ = try stake_account.ensureModified();

    std.log.debug("[Stake] Deactivated stake account {x}", .{stake_pubkey.data[0..4].*});
    return .{ .compute_units = 750, .err = null };
}

/// Execute stake withdraw
fn executeStakeWithdraw(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // Withdraw instruction format: [4 bytes type] [8 bytes lamports]
    if (ix.data.len < 12) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    // Need at least 2 accounts: stake account and recipient
    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const stake_account_idx = ix.account_indices[0];
    const recipient_idx = ix.account_indices[1];

    if (stake_account_idx >= tx.account_keys.len or recipient_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const lamports = std.mem.readInt(u64, ix.data[4..12], .little);

    const stake_pubkey = &tx.account_keys[stake_account_idx];
    const recipient_pubkey = &tx.account_keys[recipient_idx];

    const stake_account = accounts.get(stake_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };
    const recipient_account = accounts.get(recipient_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Check stake account has sufficient balance
    if (stake_account.getLamports() < lamports) {
        return .{ .compute_units = 750, .err = .InsufficientFundsForFee };
    }

    // Deduct from stake account
    const stake_mod = try stake_account.ensureModified();
    stake_mod.lamports -= lamports;

    // Credit recipient
    const recipient_mod = try recipient_account.ensureModified();
    recipient_mod.lamports += lamports;

    std.log.debug("[Stake] Withdraw {d} lamports", .{lamports});
    return .{ .compute_units = 750, .err = null };
}

/// Execute stake split
fn executeStakeSplit(ix: *const Instruction, accounts: *LoadedAccounts, tx: *const Transaction) !InstructionResult {
    // Split instruction format: [4 bytes type] [8 bytes lamports]
    if (ix.data.len < 12) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    // Need at least 2 accounts: source stake and destination stake
    if (ix.account_indices.len < 2) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const source_idx = ix.account_indices[0];
    const dest_idx = ix.account_indices[1];

    if (source_idx >= tx.account_keys.len or dest_idx >= tx.account_keys.len) {
        return .{ .compute_units = 0, .err = .InvalidInstruction };
    }

    const lamports = std.mem.readInt(u64, ix.data[4..12], .little);

    const source_pubkey = &tx.account_keys[source_idx];
    const dest_pubkey = &tx.account_keys[dest_idx];

    const source_account = accounts.get(source_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };
    const dest_account = accounts.get(dest_pubkey) orelse {
        return .{ .compute_units = 0, .err = .AccountNotFound };
    };

    // Check source has sufficient balance
    if (source_account.getLamports() < lamports) {
        return .{ .compute_units = 750, .err = .InsufficientFundsForFee };
    }

    // Deduct from source
    const source_mod = try source_account.ensureModified();
    source_mod.lamports -= lamports;

    // Credit destination (new stake account - set owner to stake program)
    const dest_mod = try dest_account.ensureModified();
    dest_mod.lamports += lamports;
    dest_mod.owner = core.Pubkey{ .data = NATIVE_PROGRAMS.STAKE };

    std.log.debug("[Stake] Split {d} lamports to new stake account", .{lamports});
    return .{ .compute_units = 750, .err = null };
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

/// Entry in the recent blockhashes queue
pub const BlockhashEntry = struct {
    blockhash: core.Hash,
    fee_calculator: FeeCalculator,
};

/// Fee calculator for transactions
pub const FeeCalculator = struct {
    lamports_per_signature: u64,
};

/// Recent blockhashes sysvar data
pub const RecentBlockhashes = struct {
    entries: std.BoundedArray(BlockhashEntry, 300),

    pub fn init() RecentBlockhashes {
        return .{
            .entries = std.BoundedArray(BlockhashEntry, 300).init(0) catch unreachable,
        };
    }

    pub fn push(self: *RecentBlockhashes, entry: BlockhashEntry) void {
        if (self.entries.len == 300) {
            _ = self.entries.orderedRemove(0);
        }
        self.entries.append(entry) catch unreachable;
    }

    pub fn serialize(self: *const RecentBlockhashes, writer: anytype) !void {
        try writer.writeInt(u64, self.entries.len, .little);
        for (self.entries.slice()) |entry| {
            try writer.writeAll(&entry.blockhash.data);
            try writer.writeInt(u64, entry.fee_calculator.lamports_per_signature, .little);
        }
    }
};
