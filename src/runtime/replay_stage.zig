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
    shred_assembler: ShredAssembler,

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

    /// Statistics
    stats: ReplayStats,

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
            .shred_assembler = ShredAssembler.init(allocator),
            .tx_parser = transaction.TransactionParser.init(allocator),
            .sig_verifier = sig_verifier,
            .accounts_db = accounts_db,
            .ledger_db = ledger_db,
            .consensus_engine = consensus_engine,
            .leader_cache = consensus.leader_schedule.LeaderScheduleCache.init(allocator),
            .stats = .{},
        };

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
        self.sig_verifier.deinit();
        self.leader_cache.deinit();

        self.allocator.destroy(self);
    }

    /// Set TPU client for sending vote transactions
    /// Reference: Firedancer fd_quic_tile.c - TPU client initialization
    pub fn setTpuClient(self: *Self, tpu: *network.TpuClient) void {
        self.tpu_client = tpu;
    }

    /// Process incoming shreds
    pub fn onShreds(self: *Self, shreds: []const Shred) !void {
        for (shreds) |shred| {
            try self.processShred(shred);
        }
    }

    fn processShred(self: *Self, shred: Shred) !void {
        const slot = shred.slot();

        // Verify shred signature against leader
        if (self.leader_cache.getSlotLeader(slot)) |leader_bytes| {
            const leader = core.Pubkey{ .data = leader_bytes };
            if (!shred.verifySignature(&leader)) {
                ReplayStats.inc(&self.stats.invalid_shreds);
                return;
            }
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

        // Get or create bank for this slot
        const bank = try self.getOrCreateBank(slot);

        // Parse and execute entries
        try self.replayEntries(bank, data);

        // Freeze the bank
        try bank.freeze();

        // Update ledger
        const slot_meta = storage.ledger.SlotMeta.init(
            if (self.banks.get(slot - 1)) |_| slot - 1 else null,
        );
        try self.ledger_db.insertSlotMeta(slot, slot_meta);

        // Check if we should vote
        try self.maybeVote(slot, bank);
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
        // Parse entries from slot data
        // Entry format: [num_hashes: u64] [hash: 32] [num_txs: u64] [transactions...]

        var offset: usize = 0;

        while (offset < data.len) {
            // Parse entry header
            if (offset + 48 > data.len) break;

            const num_hashes = std.mem.readInt(u64, data[offset..][0..8], .little);
            _ = num_hashes;
            offset += 8;

            // Skip hash
            offset += 32;

            const num_txs = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;

            // Parse transactions
            for (0..num_txs) |_| {
                if (offset >= data.len) break;

                // Get transaction length
                const tx_len = try self.tx_parser.parseCompactU16(data[offset..], &offset);
                if (offset + tx_len > data.len) break;

                const tx_data = data[offset..][0..tx_len];
                offset += tx_len;

                // Parse and execute transaction
                const tx = self.tx_parser.parse(tx_data) catch {
                    ReplayStats.inc(&self.stats.failed_txs);
                    continue;
                };

                // Verify signatures
                if (!tx.verifySignatures()) {
                    ReplayStats.inc(&self.stats.failed_txs);
                    continue;
                }

                // Execute transaction
                const bank_tx = bank_mod.Transaction{
                    .fee_payer = tx.feePayer(),
                    .signatures = tx.signatures,
                    .signature_count = @intCast(tx.signatures.len),
                    .signatures_verified = true,
                    .message = tx.message_bytes,
                    .recent_blockhash = tx.message.recent_blockhash,
                    .compute_unit_limit = 200_000,
                    .compute_unit_price = 0,
                    .account_keys = tx.message.account_keys,
                    .instructions = &.{}, // Parsed from message
                };

                const result = bank.processTransaction(&bank_tx);
                if (result.success) {
                    ReplayStats.inc(&self.stats.successful_txs);
                } else {
                    ReplayStats.inc(&self.stats.failed_txs);
                }
            }
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
        
        // Set identity secret if we have it
        if (self.consensus_engine.identity_secret) |secret| {
            vote_builder.setIdentitySecret(secret);
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
                // Send transaction to leader's TPU port
                // TPU port is typically gossip_port + 6 (Solana convention)
                // For now, use UDP send - will be enhanced with QUIC later
                try tpu.sendTransaction(tx_data, current_slot);
                std.log.info("[Vote] Sent {d} byte vote tx to leader {} for slot {d}", .{
                    tx_data.len,
                    std.fmt.fmtSliceHexLower(&leader),
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
        // Check if we're actually the leader
        if (self.leader_cache.getSlotLeader(slot)) |leader| {
            if (!std.mem.eql(u8, &leader, &self.identity.data)) {
                return; // Not our slot
            }
        } else {
            return; // Unknown leader
        }

        std.log.info("[Leader] Producing block for slot {}", .{slot});

        // Create bank for this slot
        const bank = try self.getOrCreateBank(slot);
        
        // Pull transactions from TPU queue and execute
        const txs = try self.pullTransactionsFromTpu();
        defer self.allocator.free(txs);
        
        if (txs.len > 0) {
            // Create POH entries for transactions
            const entries = try self.createEntries(bank, txs);
            defer self.allocator.free(entries);
            
            // Create shreds from entries
            const shreds = try self.createShreds(slot, entries);
            defer self.allocator.free(shreds);
            
            // Broadcast shreds via TVU/Turbine
            try self.broadcastShreds(shreds);
        }
        
        // Freeze bank
        try bank.freeze();
        
        ReplayStats.inc(&self.stats.blocks_produced);
        std.log.info("[Leader] Block {} complete, {} txs processed", .{slot, txs.len});
    }
    
    /// Pull pending transactions from TPU queue
    fn pullTransactionsFromTpu(self: *Self) ![]bank_mod.Transaction {
        // In full impl, would interface with TPU service
        // Return empty slice for now
        return try self.allocator.alloc(bank_mod.Transaction, 0);
    }
    
    /// Create POH entries from transactions
    fn createEntries(self: *Self, bank: *Bank, txs: []const bank_mod.Transaction) ![]Entry {
        _ = bank;
        
        if (txs.len == 0) {
            return try self.allocator.alloc(Entry, 0);
        }
        
        // Group transactions into entries (max ~64 per entry)
        const max_txs_per_entry = 64;
        const num_entries = (txs.len + max_txs_per_entry - 1) / max_txs_per_entry;
        
        const entries = try self.allocator.alloc(Entry, num_entries);
        
        for (entries, 0..) |*entry, i| {
            // In full impl, would serialize txs[start..end] 
            _ = i;
            
            entry.* = Entry{
                .num_hashes = 1,
                .hash = core.Hash.ZERO, // Would come from POH
                .transactions = &.{}, // Would serialize txs
            };
        }
        
        return entries;
    }
    
    /// Create shreds from entries
    fn createShreds(self: *Self, slot: core.Slot, entries: []const Entry) ![]Shred {
        // In full impl, would use ShredBuilder
        // For now return empty
        _ = slot;
        _ = entries;
        const shreds = try self.allocator.alloc(Shred, 0);
        return shreds;
    }
    
    /// Broadcast shreds to cluster via Turbine
    fn broadcastShreds(self: *Self, shreds: []const Shred) !void {
        // In full impl, would send via TVU broadcast service
        _ = self;
        _ = shreds;
    }
    
    /// Entry structure for block production
    const Entry = struct {
        num_hashes: u64,
        hash: core.Hash,
        transactions: []const u8, // Serialized transactions
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
    stats.shreds_received = 100;
    try std.testing.expectEqual(@as(u64, 100), stats.shreds_received);
}

