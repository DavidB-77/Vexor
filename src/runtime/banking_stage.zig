//! Vexor Banking Stage
//!
//! The banking stage is responsible for:
//! - Receiving transactions from TPU
//! - Scheduling transactions for parallel execution
//! - Managing transaction prioritization (fee market)
//! - Forwarding transactions to leader
//!
//! Pipeline:
//! TPU → SigVerify → Banking Stage → Execution → Confirmation

const std = @import("std");
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const crypto = @import("../crypto/root.zig");
const bank_mod = @import("bank.zig");

const Bank = bank_mod.Bank;
const Transaction = bank_mod.Transaction;

/// Banking stage configuration
pub const BankingConfig = struct {
    /// Number of banking threads
    num_threads: usize = 4,
    /// Maximum transactions per batch
    batch_size: usize = 128,
    /// Maximum queue size
    max_queue_size: usize = 10_000,
    /// Enable priority fees
    enable_priority_fees: bool = true,
    /// Minimum priority fee (microlamports per CU)
    min_priority_fee: u64 = 0,
    /// Forward transactions to next leader
    forward_to_leader: bool = true,
    /// Forward batch size
    forward_batch_size: usize = 64,
};

/// Transaction entry in the queue
pub const QueuedTransaction = struct {
    /// The transaction
    tx: Transaction,
    /// Priority score (higher = process first)
    priority: u64,
    /// Timestamp when received
    received_at: i64,
    /// Has signature been verified?
    signature_verified: bool,
    /// Source: TPU, gossip, RPC
    source: TransactionSource,
    
    pub const TransactionSource = enum {
        tpu,
        tpu_vote,
        gossip,
        rpc,
        forward,
    };
    
    /// Calculate priority from compute units and price
    pub fn calculatePriority(compute_units: u64, compute_unit_price: u64) u64 {
        // Priority = price per CU * base factor + time bonus
        return compute_unit_price * 1000 + (compute_units / 1000);
    }
};

/// Priority queue comparator (max heap - higher priority first)
fn queueCompare(a: QueuedTransaction, b: QueuedTransaction) std.math.Order {
    if (a.priority > b.priority) return .lt;
    if (a.priority < b.priority) return .gt;
    // Tie-breaker: older transactions first
    if (a.received_at < b.received_at) return .lt;
    if (a.received_at > b.received_at) return .gt;
    return .eq;
}

/// Banking stage service
pub const BankingStage = struct {
    allocator: std.mem.Allocator,
    config: BankingConfig,
    
    /// Transaction queue (priority sorted)
    tx_queue: std.PriorityQueue(QueuedTransaction, void, queueCompare),
    
    /// Vote transaction queue (separate, higher priority)
    vote_queue: std.PriorityQueue(QueuedTransaction, void, queueCompare),
    
    /// Reference to current bank
    bank: ?*Bank,
    
    /// Signature verifier
    sig_verifier: *crypto.SigVerifier,
    
    /// Statistics
    stats: Stats,
    
    /// Running state
    running: std.atomic.Value(bool),
    
    /// Queue mutex
    queue_mutex: std.Thread.Mutex,

    const Self = @This();
    
    pub const Stats = struct {
        transactions_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_forwarded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        votes_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        votes_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        signatures_verified: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        batches_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        queue_depth: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: std.mem.Allocator, config: BankingConfig) !*Self {
        const stage = try allocator.create(Self);
        errdefer allocator.destroy(stage);
        
        const sig_verifier = try crypto.SigVerifier.init(allocator, .{});
        errdefer sig_verifier.deinit();
        
        stage.* = .{
            .allocator = allocator,
            .config = config,
            .tx_queue = std.PriorityQueue(QueuedTransaction, void, queueCompare).init(allocator, {}),
            .vote_queue = std.PriorityQueue(QueuedTransaction, void, queueCompare).init(allocator, {}),
            .bank = null,
            .sig_verifier = sig_verifier,
            .stats = .{},
            .running = std.atomic.Value(bool).init(false),
            .queue_mutex = .{},
        };
        
        return stage;
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.tx_queue.deinit();
        self.vote_queue.deinit();
        self.sig_verifier.deinit();
        self.allocator.destroy(self);
    }
    
    /// Set the current bank for processing
    pub fn setBank(self: *Self, bank: *Bank) void {
        self.bank = bank;
    }
    
    /// Queue a transaction for processing
    pub fn queueTransaction(self: *Self, tx: Transaction, source: QueuedTransaction.TransactionSource) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        // Check queue size limit
        if (self.tx_queue.count() >= self.config.max_queue_size) {
            return error.QueueFull;
        }
        
        const priority = QueuedTransaction.calculatePriority(
            tx.compute_unit_limit,
            tx.compute_unit_price,
        );
        
        const queued = QueuedTransaction{
            .tx = tx,
            .priority = priority,
            .received_at = std.time.milliTimestamp(),
            .signature_verified = false,
            .source = source,
        };
        
        // Vote transactions go to separate queue
        if (source == .tpu_vote) {
            try self.vote_queue.add(queued);
            _ = self.stats.votes_received.fetchAdd(1, .monotonic);
        } else {
            try self.tx_queue.add(queued);
            _ = self.stats.transactions_received.fetchAdd(1, .monotonic);
        }
        
        _ = self.stats.queue_depth.store(@intCast(self.tx_queue.count() + self.vote_queue.count()), .monotonic);
    }
    
    /// Queue multiple transactions (batch)
    pub fn queueBatch(self: *Self, txs: []const Transaction, source: QueuedTransaction.TransactionSource) !usize {
        var queued: usize = 0;
        for (txs) |tx| {
            self.queueTransaction(tx, source) catch continue;
            queued += 1;
        }
        return queued;
    }
    
    /// Process transactions from the queue
    pub fn processBatch(self: *Self) !ProcessResult {
        if (self.bank == null) return ProcessResult{};
        
        var result = ProcessResult{};
        
        // Process vote transactions first (higher priority)
        result.votes_processed = try self.processVotes();
        
        // Then process regular transactions
        result.txs_processed = try self.processTransactions();
        
        _ = self.stats.batches_processed.fetchAdd(1, .monotonic);
        
        return result;
    }
    
    /// Process vote transactions
    fn processVotes(self: *Self) !usize {
        var processed: usize = 0;
        const batch_size = @min(self.config.batch_size, 64); // Votes have smaller batches
        
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        while (processed < batch_size) {
            const queued = self.vote_queue.removeOrNull() orelse break;
            
            // Verify signature if not already done
            if (!queued.signature_verified) {
                if (!self.verifySignature(&queued.tx)) {
                    _ = self.stats.transactions_failed.fetchAdd(1, .monotonic);
                    continue;
                }
                _ = self.stats.signatures_verified.fetchAdd(1, .monotonic);
            }
            
            // Process the vote
            const bank_result = self.bank.?.processTransaction(&queued.tx);
            if (bank_result.success) {
                _ = self.stats.votes_processed.fetchAdd(1, .monotonic);
                processed += 1;
            } else {
                _ = self.stats.transactions_failed.fetchAdd(1, .monotonic);
            }
        }
        
        return processed;
    }
    
    /// Process regular transactions
    fn processTransactions(self: *Self) !usize {
        var processed: usize = 0;
        
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        
        while (processed < self.config.batch_size) {
            const queued = self.tx_queue.removeOrNull() orelse break;
            
            // Verify signature if not already done
            if (!queued.signature_verified) {
                if (!self.verifySignature(&queued.tx)) {
                    _ = self.stats.transactions_failed.fetchAdd(1, .monotonic);
                    continue;
                }
                _ = self.stats.signatures_verified.fetchAdd(1, .monotonic);
            }
            
            // Process the transaction
            const bank_result = self.bank.?.processTransaction(&queued.tx);
            if (bank_result.success) {
                _ = self.stats.transactions_processed.fetchAdd(1, .monotonic);
                processed += 1;
            } else {
                _ = self.stats.transactions_failed.fetchAdd(1, .monotonic);
            }
        }
        
        _ = self.stats.queue_depth.store(@intCast(self.tx_queue.count() + self.vote_queue.count()), .monotonic);
        
        return processed;
    }
    
    /// Verify transaction signature
    fn verifySignature(self: *Self, tx: *const Transaction) bool {
        _ = self;
        // Signature verification would use sig_verifier
        // For now, trust the signatures_verified flag
        return tx.signatures_verified;
    }
    
    /// Run the banking stage loop
    pub fn run(self: *Self) void {
        self.running.store(true, .release);
        
        std.log.info("[Banking] Starting banking stage", .{});
        
        while (self.running.load(.acquire)) {
            // Process a batch
            _ = self.processBatch() catch |err| {
                std.log.warn("[Banking] Batch error: {}", .{err});
            };
            
            // Small sleep if queue is empty
            if (self.tx_queue.count() == 0 and self.vote_queue.count() == 0) {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
        
        std.log.info("[Banking] Banking stage stopped", .{});
    }
    
    /// Stop the banking stage
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
    
    /// Get queue depth
    pub fn queueDepth(self: *Self) usize {
        return self.tx_queue.count() + self.vote_queue.count();
    }
    
    /// Print statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print(
            \\
            \\═══ Banking Stage Stats ═══
            \\TXs received:     {}
            \\TXs processed:    {}
            \\TXs failed:       {}
            \\TXs forwarded:    {}
            \\Votes received:   {}
            \\Votes processed:  {}
            \\Sigs verified:    {}
            \\Batches:          {}
            \\Queue depth:      {}
            \\════════════════════════════
            \\
        , .{
            self.stats.transactions_received.load(.seq_cst),
            self.stats.transactions_processed.load(.seq_cst),
            self.stats.transactions_failed.load(.seq_cst),
            self.stats.transactions_forwarded.load(.seq_cst),
            self.stats.votes_received.load(.seq_cst),
            self.stats.votes_processed.load(.seq_cst),
            self.stats.signatures_verified.load(.seq_cst),
            self.stats.batches_processed.load(.seq_cst),
            self.stats.queue_depth.load(.seq_cst),
        });
    }
    
    pub const ProcessResult = struct {
        txs_processed: usize = 0,
        votes_processed: usize = 0,
    };
};

/// Transaction scheduler for parallel execution
pub const TransactionScheduler = struct {
    allocator: std.mem.Allocator,
    
    /// Account locks for parallel execution
    locked_accounts: std.AutoHashMap(core.Pubkey, LockState),
    
    /// Batches ready for parallel execution
    execution_batches: std.ArrayList(ExecutionBatch),
    
    const Self = @This();
    
    const LockState = struct {
        write_locked: bool,
        read_count: u32,
    };
    
    pub const ExecutionBatch = struct {
        transactions: std.ArrayList(*const Transaction),
        /// Accounts that will be written by this batch
        write_set: std.AutoHashMap(core.Pubkey, void),
        /// Accounts that will be read by this batch
        read_set: std.AutoHashMap(core.Pubkey, void),
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .locked_accounts = std.AutoHashMap(core.Pubkey, LockState).init(allocator),
            .execution_batches = std.ArrayList(ExecutionBatch).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.locked_accounts.deinit();
        for (self.execution_batches.items) |*batch| {
            batch.transactions.deinit();
            batch.write_set.deinit();
            batch.read_set.deinit();
        }
        self.execution_batches.deinit();
    }
    
    /// Schedule transactions into parallel batches
    /// Transactions with conflicting account access go in different batches
    pub fn schedule(self: *Self, transactions: []const *const Transaction) !void {
        self.locked_accounts.clearRetainingCapacity();
        
        for (self.execution_batches.items) |*batch| {
            batch.transactions.clearRetainingCapacity();
            batch.write_set.clearRetainingCapacity();
            batch.read_set.clearRetainingCapacity();
        }
        
        for (transactions) |tx| {
            // Try to add to existing batch
            var added = false;
            for (self.execution_batches.items) |*batch| {
                if (try self.canAddToBatch(batch, tx)) {
                    try batch.transactions.append(tx);
                    try self.addAccountsToBatch(batch, tx);
                    added = true;
                    break;
                }
            }
            
            // Create new batch if needed
            if (!added) {
                var new_batch = ExecutionBatch{
                    .transactions = std.ArrayList(*const Transaction).init(self.allocator),
                    .write_set = std.AutoHashMap(core.Pubkey, void).init(self.allocator),
                    .read_set = std.AutoHashMap(core.Pubkey, void).init(self.allocator),
                };
                try new_batch.transactions.append(tx);
                try self.addAccountsToBatch(&new_batch, tx);
                try self.execution_batches.append(new_batch);
            }
        }
    }
    
    /// Check if transaction can be added to batch without conflicts
    fn canAddToBatch(self: *Self, batch: *const ExecutionBatch, tx: *const Transaction) !bool {
        _ = self;
        
        // Check for write-write or write-read conflicts
        for (tx.account_keys) |key| {
            // If batch writes to this account, we can't add
            if (batch.write_set.contains(key)) {
                return false;
            }
            
            // If we want to write and batch reads, we can't add
            // (Simplified - real impl would check writable flag)
            if (batch.read_set.contains(key)) {
                return false;
            }
        }
        
        return true;
    }
    
    /// Add transaction's accounts to batch's lock sets
    fn addAccountsToBatch(self: *Self, batch: *ExecutionBatch, tx: *const Transaction) !void {
        _ = self;
        
        for (tx.account_keys, 0..) |key, i| {
            // First account is always fee payer (writable)
            // Simplified - real impl would use message header
            if (i == 0) {
                try batch.write_set.put(key, {});
            } else {
                try batch.read_set.put(key, {});
            }
        }
    }
    
    /// Get batches for parallel execution
    pub fn getBatches(self: *Self) []ExecutionBatch {
        return self.execution_batches.items;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "banking config defaults" {
    const config = BankingConfig{};
    try std.testing.expectEqual(@as(usize, 4), config.num_threads);
    try std.testing.expectEqual(@as(usize, 128), config.batch_size);
}

test "priority calculation" {
    const priority1 = QueuedTransaction.calculatePriority(200_000, 1000); // Standard tx
    const priority2 = QueuedTransaction.calculatePriority(200_000, 10000); // High priority
    
    try std.testing.expect(priority2 > priority1);
}

test "scheduler init" {
    var scheduler = TransactionScheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), scheduler.execution_batches.items.len);
}

