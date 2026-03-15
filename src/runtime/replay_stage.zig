//! Vexor Replay Stage
//!
//! The replay stage is responsible for:
//! - Receiving shreds from TVU
//! - Reconstructing blocks
//! - Replaying transactions to build bank state
//! - Voting on completed slots
//! - Producing blocks when we're the leader

const std = @import("std");
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const consensus = @import("../consensus/root.zig");
const crypto = @import("../crypto/root.zig");
const network = @import("../network/root.zig");
const bank_mod = @import("bank.zig");
const shred_mod = @import("shred.zig");
const transaction = @import("transaction.zig");
const shredder = @import("shredder.zig");
const merkle_diag_mod = @import("merkle_diagnostics.zig");

const Bank = bank_mod.Bank;
const Shred = shred_mod.Shred;
const ShredAssembler = shred_mod.ShredAssembler;
const LeaderSchedule = consensus.leader_schedule.LeaderSchedule;

/// Replay stage
pub const ReplayStage = struct {
    allocator: std.mem.Allocator,

    /// Our identity
    identity: core.Pubkey,

    /// Active banks by slot
    banks: std.AutoHashMap(core.Slot, *Bank),

    /// Root bank (finalized state)
    root_bank: ?*Bank,

    /// Shred assembler for reconstructing slots
    shred_assembler: *ShredAssembler,

    /// Transaction parser
    tx_parser: transaction.TransactionParser,

    /// Signature verifier
    sig_verifier: *crypto.SigVerifier,

    /// Reference to accounts DB
    accounts_db: *storage.AccountsDb,

    /// Reference to ledger DB
    ledger_db: *storage.LedgerDb,

    /// Consensus engine
    consensus_engine: *consensus.ConsensusEngine,

    /// Leader schedule cache
    leader_cache: consensus.leader_schedule.LeaderScheduleCache,

    /// TPU client for sending vote transactions
    tpu_client: ?*network.TpuClient,

    /// TVU service for shred broadcasting
    tvu_service: ?*network.tvu.TvuService,

    /// Block builder for shred creation (leader only)
    block_builder: ?shredder.BlockBuilder,

    /// Shred version for this validator
    shred_version: u16,

    /// Statistics
    stats: ReplayStats,

    /// Merkle root verification diagnostics
    merkle_diag: merkle_diag_mod.MerkleDiagnostics,

    /// Leader readiness gate
    leader_readiness: consensus.leader_readiness.LeaderReadiness,

    /// Banking stage (for block production)
    banking_stage: ?*@import("banking_stage.zig").BankingStage,

    /// Consensus tracker for diagnostic tracing
    consensus_tracker: ?*@import("../diagnostics/consensus_trace.zig").ConsensusTracker = null,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        identity: core.Pubkey,
        accounts_db: *storage.AccountsDb,
        ledger_db: *storage.LedgerDb,
        consensus_engine: *consensus.ConsensusEngine,
    ) !*Self {
        const stage = try allocator.create(Self);
        errdefer allocator.destroy(stage);

        const sig_verifier = try crypto.SigVerifier.init(allocator, .{});
        errdefer sig_verifier.deinit();

        stage.* = .{
            .allocator = allocator,
            .identity = identity,
            .banks = std.AutoHashMap(core.Slot, *Bank).init(allocator),
            .root_bank = null,
            .tpu_client = null,
            .shred_assembler = try ShredAssembler.init(allocator),
            .tx_parser = transaction.TransactionParser.init(allocator),
            .sig_verifier = sig_verifier,
            .accounts_db = accounts_db,
            .ledger_db = ledger_db,
            .consensus_engine = consensus_engine,
            .leader_cache = consensus.leader_schedule.LeaderScheduleCache.init(allocator),
            .tvu_service = null,
            .block_builder = null,
            .leader_readiness = consensus.leader_readiness.LeaderReadiness.init(allocator, identity),
            .shred_version = 0,
            .stats = .{},
            .merkle_diag = merkle_diag_mod.MerkleDiagnostics.init(),
            .banking_stage = null,
        };

        stage.leader_readiness.setAccountsDb(accounts_db);
        stage.leader_readiness.setLedgerDb(ledger_db);

        return stage;
    }

    pub fn deinit(self: *Self) void {
        var bank_iter = self.banks.valueIterator();
        while (bank_iter.next()) |bank| {
            bank.*.deinit();
        }
        self.banks.deinit();

        if (self.root_bank) |rb| rb.deinit();

        self.shred_assembler.deinit();
        self.allocator.destroy(self.shred_assembler);
        self.sig_verifier.deinit();
        self.leader_cache.deinit();

        self.allocator.destroy(self);
    }

    /// Set TPU client for sending vote transactions
    /// Reference: Firedancer fd_quic_tile.c - TPU client initialization
    pub fn setTpuClient(self: *Self, tpu: *network.TpuClient) void {
        self.tpu_client = tpu;
    }

    /// Set TVU service for shred broadcasting
    pub fn setTvuService(self: *Self, tvu: *network.tvu.TvuService) void {
        self.tvu_service = tvu;
    }

    /// Set keypair for shred signing (required for leader production)
    pub fn setKeypair(self: *Self, keypair: core.Keypair, shred_ver: u16) void {
        self.shred_version = shred_ver;
        self.block_builder = shredder.BlockBuilder.init(self.allocator, keypair, shred_ver);
        self.leader_readiness.setShredVersion(shred_ver);
        self.leader_cache.setIdentity(keypair.public);
    }

    /// Process incoming shreds
    pub fn onShreds(self: *Self, shreds: []const Shred) !void {
        for (shreds) |shred| {
            try self.processShred(shred);
        }
    }

    /// Process a completed slot directly (called from TVU when slot is already assembled)
    /// This skips re-inserting shreds into the replay_stage's own assembler
    pub fn onSlotCompleted(self: *Self, slot: core.Slot, assembled_data: []const u8) !void {
        // Update network tip for readiness gate
        self.leader_readiness.updateNetworkSlot(slot);

        // Verify we haven't already processed this slot
        if (self.banks.contains(slot)) {
            return; // Already processed
        }

        // Validate assembled data has minimum size
        if (assembled_data.len < 16) {
            std.debug.print("[REPLAY] Slot {d}: assembled data too short ({d} bytes)\n", .{ slot, assembled_data.len });
            return;
        }

        // Get or create bank for this slot
        const bank = self.getOrCreateBank(slot) catch |err| {
            std.debug.print("[REPLAY] Failed to create bank for slot {d}: {}\n", .{ slot, err });
            return;
        };

        // Parse and execute entries - catch ALL errors gracefully
        // The FEC-recovered data might not be immediately parsable as transactions
        const replay_start = std.time.milliTimestamp();
        self.replayEntries(bank, assembled_data) catch |err| {
            std.debug.print("[REPLAY] Failed to replay slot {d}: {} (data_len={d})\n", .{ slot, err, assembled_data.len });
            // Don't propagate error - just log and continue
            return;
        };
        std.debug.print("[REPLAY-TRACE] slot={d} replayEntries OK, blockhash_zero={}\n", .{
            slot,
            std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data),
        });

        // Freeze the bank — compute accounts delta hash + bank hash
        bank.freeze() catch |err| {
            std.debug.print("[REPLAY-TRACE] slot={d} freeze FAILED: {}\n", .{ slot, err });
            return;
        };
        std.debug.print("[REPLAY-TRACE] slot={d} freeze OK, bank_hash_zero={}\n", .{
            slot,
            std.mem.eql(u8, &bank.bank_hash.data, &core.Hash.ZERO.data),
        });

        // Update ledger
        const slot_meta = storage.ledger.SlotMeta.init(
            if (self.banks.get(slot - 1)) |_| slot - 1 else null,
        );
        self.ledger_db.insertSlotMeta(slot, slot_meta) catch {};

        // Update root_bank to point to this bank if it has a valid blockhash
        if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
            self.root_bank = bank;
            self.updateBankingBank(bank);
            std.debug.print("[REPLAY-TRACE] slot={d} root_bank UPDATED ← THIS IS THE GOAL\n", .{slot});
        }

        // Check if we should vote
        self.maybeVote(slot, bank) catch {};

        ReplayStats.inc(&self.stats.slots_replayed);

        const replay_end = std.time.milliTimestamp();
        const replay_duration = @max(1, replay_end - replay_start);
        const tps = (bank.transaction_count * 1000) / @as(usize, @intCast(replay_duration));

        std.log.info("[REPLAY] Slot {d} replayed. Txs: {d}, Time: {d}ms, TPS: {d}\n", .{ slot, bank.transaction_count, replay_duration, tps });

        // Check if we are the leader for the next slot
        if (self.leader_cache.getSlotLeader(slot + 1)) |leader_bytes| {
            if (leader_bytes.eql(&self.identity)) {
                self.onLeaderSlot(slot + 1) catch |err| {
                    std.log.err("[Leader] Failed to produce block for slot {d}: {}", .{ slot + 1, err });
                };
            }
        }
    }

    fn processShred(self: *Self, shred: Shred) !void {
        const slot = shred.slot();

        // Verify shred signature against leader (with full Merkle diagnostics)
        if (self.leader_cache.getSlotLeader(slot)) |leader_bytes| {
            if (!self.merkle_diag.traceAndVerify(&shred, &leader_bytes)) {
                ReplayStats.inc(&self.stats.invalid_shreds);
                return;
            }
        } else {
            self.merkle_diag.traceNoLeader(&shred);
        }

        // Insert into assembler
        const result = try self.shred_assembler.insert(shred);

        ReplayStats.inc(&self.stats.shreds_received);

        if (result == .completed_slot) {
            // Slot is complete, replay it
            try self.replaySlot(slot);
        }
    }

    /// Replay a completed slot
    fn replaySlot(self: *Self, slot: core.Slot) !void {
        ReplayStats.inc(&self.stats.slots_replayed);

        // Assemble slot data
        const data = try self.shred_assembler.assembleSlot(slot) orelse return;
        defer self.allocator.free(data);

        // CRITICAL: Remove slot from assembler to prevent memory leak
        defer self.shred_assembler.removeSlot(slot);

        // Get or create bank for this slot
        const bank = try self.getOrCreateBank(slot);

        // Parse and execute entries
        const replay_start = std.time.milliTimestamp();
        try self.replayEntries(bank, data);
        const replay_end = std.time.milliTimestamp();
        const replay_duration = @max(1, replay_end - replay_start);
        const tps = (bank.transaction_count * 1000) / @as(usize, @intCast(replay_duration));

        // Freeze the bank
        try bank.freeze();

        // Update ledger
        const slot_meta = storage.ledger.SlotMeta.init(
            if (self.banks.get(slot - 1)) |_| slot - 1 else null,
        );
        try self.ledger_db.insertSlotMeta(slot, slot_meta);

        // Update root_bank to point to this bank if it has a valid blockhash
        // This ensures getRecentBlockhash() in bootstrap can access the latest blockhash
        if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
            // Register with Fork Choice
            const parent_slot = if (slot > 0) slot - 1 else null;
            try self.consensus_engine.fork_choice_strategy.addFork(slot, parent_slot, bank.bank_hash);

            // Select heaviest fork
            if (self.consensus_engine.selectFork()) |best_slot| {
                if (self.banks.get(best_slot)) |best_bank| {
                    self.root_bank = best_bank;
                    self.updateBankingBank(best_bank);
                    std.log.info("[ForkChoice] Switched to best fork slot {d}", .{best_slot});
                } else {
                    // Fallback if locally missing
                    self.root_bank = bank;
                    self.updateBankingBank(bank);
                }
            } else {
                // No votes yet, default to current
                self.root_bank = bank;
                self.updateBankingBank(bank);
            }
        }

        // Check if we should vote
        try self.maybeVote(slot, bank);

        std.log.info("[REPLAY] Slot {d} replayed. Txs: {d}, Time: {d}ms, TPS: {d}\n", .{ slot, bank.transaction_count, replay_duration, tps });

        // Check if we are the leader for the next slot
        if (self.leader_cache.getSlotLeader(slot + 1)) |leader_bytes| {
            if (leader_bytes.eql(&self.identity)) {
                self.onLeaderSlot(slot + 1) catch |err| {
                    std.log.err("[Leader] Failed to produce block for slot {d}: {}", .{ slot + 1, err });
                };
            }
        }
    }

    fn getOrCreateBank(self: *Self, slot: core.Slot) !*Bank {
        if (self.banks.get(slot)) |existing| {
            return existing;
        }

        // Find parent bank
        const parent = if (slot > 0) self.banks.get(slot - 1) orelse self.root_bank else self.root_bank;

        // Create new bank
        const bank = try Bank.init(self.allocator, slot, parent, self.accounts_db);
        try self.banks.put(slot, bank);

        return bank;
    }

    fn replayEntries(self: *Self, bank: *Bank, data: []const u8) !void {
        self.replayEntriesInternal(bank, data) catch |err| {
            std.log.err("[REPLAY] Failed to replay slot {d}: {s} (data_len={d})", .{ bank.slot, @errorName(err), data.len });

            // Dump failed slot data for offline analysis
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/home/sol/vexor/slot_{d}_fail.bin", .{bank.slot}) catch "failed_slot.bin";
            const file = std.fs.cwd().createFile(path, .{}) catch |e| blk: {
                std.log.err("[REPLAY] Failed to create dump file: {}", .{e});
                break :blk null;
            };
            if (file) |f| {
                defer f.close();
                f.writeAll(data) catch {};
                std.log.err("[REPLAY] Dumped failed slot data to {s}", .{path});
            }

            if (data.len > 0) {
                const dump_len = @min(128, data.len);
                std.debug.print("[REPLAY] Data prefix: {x}\n", .{std.fmt.fmtSliceHexLower(data[0..dump_len])});
            }
            return err;
        };
    }

    fn replayEntriesInternal(self: *Self, bank: *Bank, data: []const u8) !void {
        // Parse entries from slot data
        // Solana entry format (sequential, NO batch wrapper):
        //   [num_hashes: u64] [hash: 32] [num_txs: u64] [transactions...]
        //   [num_hashes: u64] [hash: 32] [num_txs: u64] [transactions...]
        //   ...
        // Reference: solana-entry/src/entry.rs - Entry struct serialization

        // ══════════════════════════════════════════════════════════════
        // DIAGNOSTIC: Hex dump first 128 bytes to debug entry alignment
        // Expected at offset 0: num_hashes (u64 LE, usually 1-12500)
        // If we see something else, there's a prefix to skip.
        // ══════════════════════════════════════════════════════════════
        if (data.len >= 48) {
            const dump_len = @min(data.len, 128);
            std.debug.print("[REPLAY-HEXDUMP] slot={d} data_len={d} first {d} bytes:\n", .{ bank.slot, data.len, dump_len });
            std.debug.print("[REPLAY-HEXDUMP] ", .{});
            for (data[0..dump_len], 0..) |byte, idx| {
                std.debug.print("{x:0>2}", .{byte});
                if ((idx + 1) % 8 == 0) std.debug.print(" ", .{});
                if ((idx + 1) % 32 == 0) std.debug.print("\n[REPLAY-HEXDUMP] ", .{});
            }
            std.debug.print("\n", .{});

            // Decode the first 48 bytes as if they were an entry header
            const b0_num_hashes = std.mem.readInt(u64, data[0..8], .little);
            const b0_num_txs = std.mem.readInt(u64, data[40..48], .little);
            std.debug.print("[REPLAY-DECODE] @0: num_hashes={d}, hash={x:0>2}{x:0>2}..{x:0>2}{x:0>2}, num_txs={d}\n", .{
                b0_num_hashes,
                data[8], data[9], data[38], data[39],
                b0_num_txs,
            });

            // Also try reading at offset 8 in case there's a u64 length prefix
            if (data.len >= 56) {
                const b8_num_hashes = std.mem.readInt(u64, data[8..16], .little);
                const b8_num_txs = std.mem.readInt(u64, data[48..56], .little);
                std.debug.print("[REPLAY-DECODE] @8: num_hashes={d}, hash={x:0>2}{x:0>2}..{x:0>2}{x:0>2}, num_txs={d}\n", .{
                    b8_num_hashes,
                    data[16], data[17], data[46], data[47],
                    b8_num_txs,
                });
            }
        }

        var offset: usize = 0;
        var last_entry_hash: core.Hash = core.Hash.ZERO;
        var entry_count: usize = 0;
        var max_entries: usize = std.math.maxInt(usize); // unlimited by default

        // Diagnostic counters for transaction execution results
        var tx_diag_success: u64 = 0;
        var tx_diag_blockhash: u64 = 0;
        var tx_diag_sigfail: u64 = 0;
        var tx_diag_funds: u64 = 0;
        var tx_diag_acct: u64 = 0;
        var tx_diag_other: u64 = 0;

        // ══════════════════════════════════════════════════════════════
        // Bincode Vec<Entry> prefix detection:
        // Solana serializes entries as bincode Vec<Entry> = [count:u64][entries...]
        // The hex dump confirmed: bytes 0-7 = entry count, entries start at byte 8.
        // Heuristic: if first u64 is small (< 10000) AND reading at offset 8 gives
        // a valid-looking entry (num_hashes < 1M, num_txs < 100K), skip the prefix.
        // ══════════════════════════════════════════════════════════════
        if (data.len >= 56) {
            const prefix_val = std.mem.readInt(u64, data[0..8], .little);
            const at8_num_hashes = std.mem.readInt(u64, data[8..16], .little);
            const at8_num_txs = std.mem.readInt(u64, data[48..56], .little);

            if (prefix_val > 0 and prefix_val < 10000 and
                at8_num_hashes > 0 and at8_num_hashes <= 1_000_000 and
                at8_num_txs <= 100_000)
            {
                offset = 8; // Skip the bincode Vec length prefix
                max_entries = @intCast(prefix_val); // Only parse this many entries
                std.debug.print("[REPLAY] Detected bincode Vec<Entry> prefix: count={d}, skipping to offset 8\n", .{prefix_val});
            }
        }

        while (offset + 48 <= data.len and entry_count < max_entries) {
            entry_count += 1;

            // Parse entry header: num_hashes (8) + hash (32) + num_txs (8) = 48 bytes
            const h_start = offset;
            const num_hashes = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            // Sanity check: num_hashes should be reasonable (ticks are usually 1-12500)
            if (num_hashes > 1_000_000) {
                std.log.warn("[REPLAY] Entry {d}: suspicious num_hashes={d} at offset {d}, stopping", .{ entry_count, num_hashes, h_start });
                break;
            }

            @memcpy(&last_entry_hash.data, data[offset..][0..32]);
            offset += 32;

            const num_txs = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            // Sanity check: num_txs should be reasonable (max ~2000 per entry)
            if (num_txs > 10_000) {
                std.debug.print("[REPLAY-REJECT] Entry {d}: corrupt num_txs={d} at offset {d}, skipping\n", .{ entry_count, num_txs, h_start });
                break;
            }

            if (entry_count <= 5 or num_txs > 0) {
                std.log.debug("[REPLAY] Entry {d}: hashes={d} txs={d} offset={d}", .{
                    entry_count,
                    num_hashes,
                    num_txs,
                    h_start,
                });
            }

            // Parse transactions with offset-safe measurement
            var tx_idx: usize = 0;
            for (0..num_txs) |_| {
                tx_idx += 1;
                if (offset >= data.len) break;

                // ═════ GAP 2 FIX: Pre-measure transaction wire size ═════
                // measureTransaction() scans the wire format without allocating,
                // giving us the exact byte span. After parse (success or fail),
                // we ALWAYS advance offset by this amount.
                const tx_start = offset;
                const tx_size = transaction.measureTransaction(data, tx_start) catch {
                    // Can't even measure — remaining data is corrupt, stop this entry
                    if (ReplayStats.get(&self.stats.failed_txs) < 10) {
                        std.log.warn("[REPLAY] Cannot measure tx {d}/{d} at offset {d}/{d} (stopping entry)", .{
                            tx_idx, num_txs, tx_start, data.len,
                        });
                    }
                    ReplayStats.inc(&self.stats.failed_txs);
                    break;
                };

                // Parse the transaction (allocating)
                const tx = self.tx_parser.parse(data, &offset) catch |err| {
                    if (ReplayStats.get(&self.stats.failed_txs) < 10) {
                        std.log.warn("[REPLAY] Tx parse failed at entry {d} tx {d}/{d} offset {d} err={s} (skipping tx, offset safe)", .{
                            entry_count, tx_idx, num_txs, tx_start, @errorName(err),
                        });
                    }
                    ReplayStats.inc(&self.stats.failed_txs);
                    // Offset safety: advance to measured end regardless of parse failure
                    offset = tx_start + tx_size;
                    continue;
                };
                // Offset safety: ensure we land exactly at the measured end
                offset = tx_start + tx_size;
                defer tx.deinit(self.allocator);

                // ═════ STEP B: Resolve ALTs for v0 versioned transactions ═════
                var resolved_keys: ?[]core.Pubkey = null;
                defer if (resolved_keys) |rk| self.allocator.free(rk);

                if (tx.message.is_versioned and tx.message.address_lookups.len > 0) {
                    resolved_keys = transaction.resolveTransactionALTs(
                        self.allocator,
                        &tx,
                        bank.accounts_db,
                    ) catch |err| blk: {
                        if (ReplayStats.get(&self.stats.failed_txs) < 10) {
                            std.log.warn("[REPLAY] ALT resolution failed for entry {d} tx {d}: {s} (skipping tx)", .{
                                entry_count, tx_idx, @errorName(err),
                            });
                        }
                        ReplayStats.inc(&self.stats.failed_txs);
                        break :blk null;
                    };
                    if (resolved_keys == null) continue; // ALT failed, skip this tx
                }

                if (!tx.verifySignatures()) {
                    ReplayStats.inc(&self.stats.failed_txs);
                    continue;
                }

                // Convert to bank transaction, using resolved keys if available
                var bank_tx = tx.toBankTransaction(self.allocator) catch {
                    ReplayStats.inc(&self.stats.failed_txs);
                    continue;
                };
                defer {
                    self.allocator.free(bank_tx.instructions);
                    self.allocator.free(bank_tx.account_writability);
                }

                // Swap in resolved ALT keys if we have them
                if (resolved_keys) |rk| {
                    // Re-compute writability for the extended key set
                    self.allocator.free(bank_tx.account_writability);
                    const new_writability = self.allocator.alloc(bool, rk.len) catch {
                        ReplayStats.inc(&self.stats.failed_txs);
                        continue;
                    };
                    // Static keys: use original writability logic
                    for (0..tx.message.account_keys.len) |i| {
                        new_writability[i] = tx.message.isWritable(i);
                    }
                    // ALT writable keys are writable, readonly are not
                    var alt_idx = tx.message.account_keys.len;
                    for (tx.message.address_lookups) |*alt| {
                        for (0..alt.writable_indexes.len) |_| {
                            new_writability[alt_idx] = true;
                            alt_idx += 1;
                        }
                        for (0..alt.readonly_indexes.len) |_| {
                            new_writability[alt_idx] = false;
                            alt_idx += 1;
                        }
                    }
                    bank_tx.account_keys = rk;
                    bank_tx.account_writability = new_writability;
                }

                // ═══════════════════════════════════════════════════════════
                // PRE-FLIGHT VALIDATOR: Catch out-of-bounds indices that
                // would panic inside processTransaction (ReleaseSafe mode
                // turns OOB array access into "reached unreachable code")
                // ═══════════════════════════════════════════════════════════
                var is_safe = true;
                for (bank_tx.instructions) |ix| {
                    if (ix.program_id_index >= bank_tx.account_keys.len) {
                        std.debug.print("[PRE-FLIGHT] TX rejected: program_id_index {d} out of bounds (keys_len={d})\n", .{
                            ix.program_id_index, bank_tx.account_keys.len,
                        });
                        is_safe = false;
                        break;
                    }
                    for (ix.account_indices) |idx| {
                        if (idx >= bank_tx.account_keys.len) {
                            std.debug.print("[PRE-FLIGHT] TX rejected: account_index {d} out of bounds (keys_len={d})\n", .{
                                idx, bank_tx.account_keys.len,
                            });
                            is_safe = false;
                            break;
                        }
                    }
                    if (!is_safe) break;
                }

                if (!is_safe) {
                    ReplayStats.inc(&self.stats.failed_txs);
                    tx_diag_other += 1;
                    continue;
                }

                const result = bank.processTransaction(&bank_tx);
                if (result.success) {
                    ReplayStats.inc(&self.stats.successful_txs);
                    tx_diag_success += 1;
                } else {
                    ReplayStats.inc(&self.stats.failed_txs);
                    if (result.error_code) |ec| {
                        switch (ec) {
                            .BlockhashNotFound => tx_diag_blockhash += 1,
                            .SignatureFailure => tx_diag_sigfail += 1,
                            .InsufficientFundsForFee => tx_diag_funds += 1,
                            .AccountNotFound => tx_diag_acct += 1,
                            else => tx_diag_other += 1,
                        }
                    }
                }
            }
        }

        if (entry_count > 0) {
            std.log.info("[REPLAY] Parsed {d} entries from {d} bytes", .{ entry_count, data.len });
        }

        // Diagnostic summary: why are transactions failing?
        const tx_total = tx_diag_success + tx_diag_blockhash + tx_diag_sigfail + tx_diag_funds + tx_diag_acct + tx_diag_other;
        if (tx_total > 0) {
            std.debug.print("[BANK-DIAG] slot={d} txs={d} OK={d} BlockhashNotFound={d} SigFail={d} NoFunds={d} NoAcct={d} Other={d}\n", .{
                bank.slot, tx_total, tx_diag_success, tx_diag_blockhash,
                tx_diag_sigfail, tx_diag_funds, tx_diag_acct, tx_diag_other,
            });
        }

        // Update bank's blockhash with the last entry hash
        if (!std.mem.eql(u8, &last_entry_hash.data, &core.Hash.ZERO.data)) {
            bank.blockhash = last_entry_hash;
        }

        // Report replayed milestone
        if (self.consensus_tracker) |tracker| {
            tracker.report(bank.slot, .replayed);
        }
    }

    fn maybeVote(self: *Self, slot: core.Slot, bank: *Bank) !void {
        // Check if we should vote on this slot
        const tower = &self.consensus_engine.tower;

        if (!tower.vote_state.canVote(slot)) {
            return; // Still locked out
        }

        // Create vote
        const vote = try tower.vote(slot, bank.bank_hash);

        // Build and submit vote transaction
        try self.submitVoteTransaction(&vote, bank);

        // Report voted milestone
        if (self.consensus_tracker) |tracker| {
            tracker.report(slot, .voted);
        }

        ReplayStats.inc(&self.stats.votes_sent);
    }

    /// Submit a vote transaction to the cluster
    fn submitVoteTransaction(self: *Self, vote: *const consensus.vote.Vote, bank: *Bank) !void {
        // Get vote account and identity from consensus engine
        const vote_account = self.consensus_engine.vote_account;

        // Build vote transaction
        var vote_builder = consensus.vote_tx.VoteTransactionBuilder.init(
            self.allocator,
            self.identity,
            vote_account,
        );

        // Set identity and authorized voter secrets
        if (self.consensus_engine.identity_secret) |secret| {
            vote_builder.setIdentitySecret(secret);
        }
        if (self.consensus_engine.authorized_voter) |voter| {
            if (self.consensus_engine.authorized_voter_secret) |secret| {
                vote_builder.setAuthorizedVoter(voter, secret);
            }
        }

        // Build the vote transaction
        const votes = [_]consensus.vote.Vote{vote.*};
        var vote_tx = try vote_builder.buildVoteTransaction(&votes, bank.blockhash);
        defer vote_tx.deinit();

        // Sign and serialize
        const serialized = try vote_builder.signAndSerialize(&vote_tx);
        defer self.allocator.free(serialized);

        // Send to TPU (Transaction Processing Unit)
        try self.sendToTpu(serialized);
    }

    /// Send transaction to TPU
    /// Reference: Firedancer fd_quic_tile.c - TPU transaction sending
    fn sendToTpu(self: *Self, tx_data: []const u8) !void {
        if (self.tpu_client) |tpu| {
            const current_slot = self.root_bank.?.slot;

            if (self.leader_cache.getSlotLeader(current_slot)) |leader| {
                // Send transaction to leader's TPU port with retries
                var attempts: usize = 0;
                const max_attempts = 3;

                while (attempts < max_attempts) : (attempts += 1) {
                    tpu.sendTransaction(tx_data, current_slot, true) catch |err| {
                        std.log.warn("[Vote] sendTransaction failed (attempt {d}/{d}): {}", .{ attempts + 1, max_attempts, err });
                        if (attempts + 1 < max_attempts) {
                            std.time.sleep(50 * std.time.ns_per_ms);
                            continue;
                        }
                        return err;
                    };
                    break;
                }

                std.log.info("[Vote] Sent {d} byte vote tx to leader {} for slot {d}", .{
                    tx_data.len,
                    std.fmt.fmtSliceHexLower(&leader.data),
                    current_slot,
                });
            } else {
                std.log.warn("[Vote] No leader found for slot {d}, vote not sent", .{current_slot});
            }
        } else {
            std.log.warn("[Vote] TPU client not available, vote not sent", .{});
        }
    }

    /// Handle leader slot - produce a block
    pub fn onLeaderSlot(self: *Self, slot: core.Slot) !void {
        // Check readiness before producing
        const local_slot = if (self.root_bank) |rb| rb.slot else 0;
        const result = self.leader_readiness.canProduceBlock(
            slot,
            local_slot,
            &self.leader_cache,
            self.shred_version,
        );

        if (!result.ready) {
            // Only log if it's actually our slot but we're not ready
            if (result.reason != .not_our_slot) {
                std.log.warn("[Leader] Not ready to produce block for slot {d}: {s}", .{
                    slot, result.format(),
                });
            }
            return;
        }

        std.log.info("[Leader] Producing block for slot {}", .{slot});

        // Create bank for this slot
        const bank = try self.getOrCreateBank(slot);

        // Ensure bank has a blockhash so we can vote and build entries
        if (std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
            var dummy_hash: [32]u8 = [_]u8{0} ** 32;
            std.mem.writeInt(u64, dummy_hash[0..8], slot, .little);
            bank.blockhash = core.Hash{ .data = dummy_hash };
        }

        // Pull transactions from TPU queue and execute
        const txs = try self.pullTransactionsFromTpu();
        defer self.allocator.free(txs);

        // Create POH entries (at least one tick entry)
        const entries = try self.createEntries(bank, txs);
        defer self.allocator.free(entries);

        // Create shreds from entries
        const shreds = try self.createShreds(slot, entries);
        defer self.allocator.free(shreds);

        // Broadcast shreds via TVU/Turbine
        try self.broadcastShreds(shreds);

        // Freeze bank
        try bank.freeze();

        // Complete the slot locally so we can build on it
        const slot_meta = storage.ledger.SlotMeta.init(
            if (self.banks.get(slot - 1)) |_| slot - 1 else null,
        );
        try self.ledger_db.insertSlotMeta(slot, slot_meta);

        if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
            self.root_bank = bank;
            self.updateBankingBank(bank);
        }

        ReplayStats.inc(&self.stats.blocks_produced);
        std.log.info("[Leader] Block {} complete, {} txs processed", .{ slot, txs.len });

        // Vote on our own block
        try self.maybeVote(slot, bank);

        // After producing, check if we are also leader for the next slot
        if (self.leader_cache.amILeader(slot + 1)) {
            try self.onLeaderSlot(slot + 1);
        }
    }

    /// Pull pending transactions from TPU queue
    fn pullTransactionsFromTpu(self: *Self) ![]bank_mod.Transaction {
        const banking = self.banking_stage orelse {
            std.log.warn("[Leader] No banking_stage configured - block will be empty", .{});
            return try self.allocator.alloc(bank_mod.Transaction, 0);
        };

        // Drain up to 2000 transactions for the block
        // In full impl, this would respect compute limits
        banking.queue_mutex.lock();
        defer banking.queue_mutex.unlock();

        const count = @min(banking.tx_queue.count(), 2000);
        if (count == 0) return try self.allocator.alloc(bank_mod.Transaction, 0);

        const txs = try self.allocator.alloc(bank_mod.Transaction, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q_tx = banking.tx_queue.remove();
            txs[i] = q_tx.tx;
        }

        std.log.info("[Leader] Pulled {d} transactions from BankingStage for block production", .{count});
        return txs;
    }

    /// Create POH entries from transactions
    fn createEntries(self: *Self, bank: *Bank, txs: []const bank_mod.Transaction) ![]Entry {
        if (txs.len == 0) {
            const entries = try self.allocator.alloc(Entry, 1);
            entries[0] = Entry{
                .num_hashes = 1,
                .hash = bank.blockhash,
                .transactions = &.{},
                .tx_count = 0,
            };
            return entries;
        }

        // Group transactions into entries (max ~64 per entry)
        const max_txs_per_entry = 64;
        const num_entries = (txs.len + max_txs_per_entry - 1) / max_txs_per_entry;

        const entries = try self.allocator.alloc(Entry, num_entries);

        for (entries, 0..) |*entry, i| {
            const start = i * max_txs_per_entry;
            const end = @min(start + max_txs_per_entry, txs.len);
            const entry_txs = txs[start..end];

            var buf = std.ArrayList(u8).init(self.allocator);
            errdefer buf.deinit();

            const writer = buf.writer();
            for (entry_txs) |*tx| {
                try self.serializeTransaction(writer, tx);
            }

            entry.* = Entry{
                .num_hashes = 1,
                .hash = bank.blockhash,
                .transactions = try buf.toOwnedSlice(),
                .tx_count = @intCast(entry_txs.len),
            };
        }

        return entries;
    }

    fn serializeTransaction(self: *Self, writer: anytype, tx: *const bank_mod.Transaction) !void {
        _ = self;
        // 1. Signature count (compact-u16)
        try writeCompactU16(writer, @intCast(tx.signatures.len));

        // 2. Signatures
        for (tx.signatures) |sig| {
            try writer.writeAll(&sig.data);
        }

        // 3. Message
        try writer.writeAll(tx.message);
    }

    fn writeCompactU16(writer: anytype, value: u16) !void {
        var val = value;
        while (true) {
            var byte = @as(u8, @intCast(val & 0x7f));
            val >>= 7;
            if (val == 0) {
                try writer.writeByte(byte);
                return;
            }
            byte |= 0x80;
            try writer.writeByte(byte);
        }
    }

    /// Create shreds from entries using BlockBuilder
    fn createShreds(self: *Self, slot: core.Slot, entries: []const Entry) ![][]u8 {
        if (self.block_builder == null) {
            std.log.warn("[Leader] No block_builder configured - cannot create shreds", .{});
            return self.allocator.alloc([]u8, 0);
        }

        var builder = &self.block_builder.?;

        // Get parent slot (assume slot - 1 for simplicity)
        const parent_slot = if (slot > 0) slot - 1 else 0;
        builder.startBlock(slot, parent_slot);

        // Serialize entries and add to builder
        for (entries) |entry| {
            // Serialize entry: num_hashes (8) + hash (32) + num_txs (8) + tx_data
            var entry_data = std.ArrayList(u8).init(self.allocator);
            defer entry_data.deinit();

            const writer = entry_data.writer();
            try writer.writeInt(u64, entry.num_hashes, .little);
            try writer.writeAll(&entry.hash.data);
            try writer.writeInt(u64, entry.tx_count, .little);
            try writer.writeAll(entry.transactions);

            try builder.addEntry(entry_data.items);
        }

        // Finish block and get shreds
        const shreds = try builder.finishBlock();

        std.log.info("[Leader] Created {d} shreds for slot {d}", .{ shreds.len, slot });
        return shreds;
    }

    /// Broadcast shreds to cluster via TVU/Turbine
    fn broadcastShreds(self: *Self, shreds: []const []u8) !void {
        if (shreds.len == 0) return;

        if (self.tvu_service) |tvu| {
            // Use TVU's broadcast mechanism
            for (shreds) |shred_data| {
                tvu.broadcastShred(shred_data) catch |err| {
                    std.log.warn("[Leader] Failed to broadcast shred: {}", .{err});
                };
            }
            std.log.info("[Leader] Broadcasted {d} shreds via TVU", .{shreds.len});
        } else {
            std.log.warn("[Leader] No TVU service configured - shreds not broadcasted", .{});
        }
    }

    /// Entry structure for block production
    const Entry = struct {
        num_hashes: u64,
        hash: core.Hash,
        transactions: []const u8, // Serialized transactions
        tx_count: u64,
    };

    /// Get current root slot
    pub fn rootSlot(self: *const Self) ?core.Slot {
        if (self.root_bank) |rb| {
            return rb.slot;
        }
        return null;
    }

    /// Print statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print(
            \\
            \\═══ Replay Stage Stats ═══
            \\Shreds received:   {}
            \\Invalid shreds:    {}
            \\Slots replayed:    {}
            \\Successful TXs:    {}
            \\Failed TXs:        {}
            \\Votes sent:        {}
            \\Blocks produced:   {}
            \\══════════════════════════
            \\
        , .{
            ReplayStats.get(&self.stats.shreds_received),
            ReplayStats.get(&self.stats.invalid_shreds),
            ReplayStats.get(&self.stats.slots_replayed),
            ReplayStats.get(&self.stats.successful_txs),
            ReplayStats.get(&self.stats.failed_txs),
            ReplayStats.get(&self.stats.votes_sent),
            ReplayStats.get(&self.stats.blocks_produced),
        });

        // Dump Merkle diagnostics alongside replay stats
        self.merkle_diag.logStats();
    }

    fn updateBankingBank(self: *Self, bank: *Bank) void {
        if (self.banking_stage) |banking| {
            banking.setBank(bank);
        }
    }
};

/// Replay stage statistics (thread-safe)
pub const ReplayStats = struct {
    shreds_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    invalid_shreds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    slots_replayed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    successful_txs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_txs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    votes_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    blocks_produced: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Helper to increment a stat atomically
    pub fn inc(stat: *std.atomic.Value(u64)) void {
        _ = stat.fetchAdd(1, .seq_cst);
    }

    /// Helper to get a stat value
    pub fn get(stat: *const std.atomic.Value(u64)) u64 {
        return stat.load(.seq_cst);
    }
};

/// Slot status
pub const SlotStatus = enum {
    /// Slot is being processed
    processing,
    /// Slot processing complete
    complete,
    /// Slot is confirmed (2/3 stake voted)
    confirmed,
    /// Slot is finalized (rooted)
    finalized,
    /// Slot was skipped (no block produced)
    skipped,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "replay stats" {
    var stats = ReplayStats{};
    stats.shreds_received.store(100, .seq_cst);
    try std.testing.expectEqual(@as(u64, 100), stats.shreds_received.load(.seq_cst));
}
