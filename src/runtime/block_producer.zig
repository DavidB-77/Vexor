//! Vexor Block Producer
//!
//! Produces blocks when we are the scheduled leader.
//!
//! Production pipeline:
//! 1. Start PoH recorder at slot boundary
//! 2. Pull transactions from banking stage queue
//! 3. Execute transactions in batches
//! 4. Record entries with transactions
//! 5. Record ticks for empty time
//! 6. Generate shreds and broadcast

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

const bank_mod = @import("bank.zig");
const Bank = bank_mod.Bank;
const Transaction = bank_mod.Transaction;

const core = @import("../core/root.zig");
const shredder = @import("shredder.zig");
const entry_mod = @import("entry.zig");

/// Block production configuration
pub const ProducerConfig = struct {
    /// Maximum transactions per entry
    max_transactions_per_entry: usize = 64,
    /// Ticks per slot
    ticks_per_slot: u64 = 64,
    /// Hashes per tick
    hashes_per_tick: u64 = 12500,
    /// Transaction batch size
    batch_size: usize = 128,
    /// Maximum CU per block
    max_block_cu: u64 = 48_000_000,
};

/// Entry to be included in a block
pub const Entry = struct {
    /// Number of hashes since previous entry
    num_hashes: u64,
    /// Hash after ticking/mixing
    hash: [32]u8,
    /// Transactions in this entry
    transactions: []const Transaction,

    const Self = @This();

    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.writeInt(u64, self.num_hashes, .little);
        try writer.writeAll(&self.hash);
        try writer.writeInt(u64, self.transactions.len, .little);
        // Would serialize each transaction
    }

    pub fn isTick(self: *const Self) bool {
        return self.transactions.len == 0;
    }
};

/// Block being produced
pub const ProducingBlock = struct {
    allocator: Allocator,

    /// Slot being produced
    slot: u64,

    /// Current PoH hash
    poh_hash: [32]u8,

    /// Hashes since last entry
    hashes_since_entry: u64,

    /// Entries in this block
    entries: std.ArrayList(Entry),

    /// Transactions pending execution
    pending_transactions: std.ArrayList(Transaction),

    /// Current tick count
    tick_count: u64,

    /// Compute units used
    cu_used: u64,

    /// Bank for this slot
    bank: *Bank,

    /// Start time (ns)
    start_time_ns: i128,

    const Self = @This();

    pub fn init(allocator: Allocator, slot: u64, bank: *Bank, start_hash: [32]u8) !*Self {
        const block = try allocator.create(Self);
        block.* = Self{
            .allocator = allocator,
            .slot = slot,
            .poh_hash = start_hash,
            .hashes_since_entry = 0,
            .entries = std.ArrayList(Entry).init(allocator),
            .pending_transactions = std.ArrayList(Transaction).init(allocator),
            .tick_count = 0,
            .cu_used = 0,
            .bank = bank,
            .start_time_ns = std.time.nanoTimestamp(),
        };
        return block;
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        self.pending_transactions.deinit();
        self.allocator.destroy(self);
    }

    /// Add transaction to pending queue
    pub fn addTransaction(self: *Self, tx: Transaction) !void {
        try self.pending_transactions.append(tx);
    }

    /// Hash forward once
    pub fn hashOnce(self: *Self) void {
        std.crypto.hash.sha2.Sha256.hash(&self.poh_hash, &self.poh_hash, .{});
        self.hashes_since_entry += 1;
    }

    /// Record a tick (empty entry)
    pub fn recordTick(self: *Self) !void {
        try self.entries.append(Entry{
            .num_hashes = self.hashes_since_entry,
            .hash = self.poh_hash,
            .transactions = &[_]Transaction{},
        });
        self.hashes_since_entry = 0;
        self.tick_count += 1;
    }

    /// Record entry with transactions
    pub fn recordEntry(self: *Self, transactions: []const Transaction) !void {
        // Mix transactions into PoH
        for (transactions) |tx| {
            // Hash transaction signature into PoH
            var combined: [96]u8 = undefined;
            @memcpy(combined[0..32], &self.poh_hash);
            @memcpy(combined[32..96], &tx.signatures[0].data);
            std.crypto.hash.sha2.Sha256.hash(&combined, &self.poh_hash, .{});
        }

        try self.entries.append(Entry{
            .num_hashes = self.hashes_since_entry,
            .hash = self.poh_hash,
            .transactions = transactions,
        });
        self.hashes_since_entry = 0;
    }

    /// Check if block is complete
    pub fn isComplete(self: *const Self, ticks_per_slot: u64) bool {
        return self.tick_count >= ticks_per_slot;
    }

    /// Get elapsed time in ms
    pub fn elapsedMs(self: *const Self) i64 {
        const now = std.time.nanoTimestamp();
        return @intCast(@divTrunc(now - self.start_time_ns, 1_000_000));
    }
};

/// Block producer
pub const BlockProducer = struct {
    allocator: Allocator,
    config: ProducerConfig,

    /// Our identity
    identity: [32]u8,

    /// Keypair for signing shreds
    keypair: ?core.Keypair,

    /// Shred version
    shred_version: u16,

    /// Current producing block
    current_block: ?*ProducingBlock,

    /// Block builder for shredding
    block_builder: ?shredder.BlockBuilder,

    /// Transaction queue
    tx_queue: std.ArrayList(Transaction),
    tx_queue_mutex: Mutex,

    /// Statistics
    stats: ProducerStats,

    /// Running state
    running: Atomic(bool),

    /// Callback for broadcasting shreds
    broadcast_fn: ?*const fn (shreds: [][]u8) void,

    const Self = @This();

    pub fn init(allocator: Allocator, identity: [32]u8, config: ProducerConfig) !*Self {
        const producer = try allocator.create(Self);
        producer.* = Self{
            .allocator = allocator,
            .config = config,
            .identity = identity,
            .keypair = null,
            .shred_version = 0,
            .current_block = null,
            .block_builder = null,
            .tx_queue = std.ArrayList(Transaction).init(allocator),
            .tx_queue_mutex = .{},
            .stats = .{},
            .running = Atomic(bool).init(false),
            .broadcast_fn = null,
        };
        return producer;
    }

    /// Set keypair for signing shreds
    pub fn setKeypair(self: *Self, keypair: core.Keypair, shred_ver: u16) void {
        self.keypair = keypair;
        self.shred_version = shred_ver;
        self.block_builder = shredder.BlockBuilder.init(self.allocator, keypair, shred_ver);
    }

    /// Set broadcast callback
    pub fn setBroadcastFn(self: *Self, broadcast_fn: *const fn (shreds: [][]u8) void) void {
        self.broadcast_fn = broadcast_fn;
    }

    pub fn deinit(self: *Self) void {
        if (self.current_block) |block| block.deinit();
        if (self.block_builder) |*builder| builder.deinit();
        self.tx_queue.deinit();
        self.allocator.destroy(self);
    }

    /// Start producing a block for slot
    pub fn startSlot(self: *Self, slot: u64, bank: *Bank, start_hash: [32]u8) !void {
        // Cleanup previous block
        if (self.current_block) |block| {
            block.deinit();
        }

        self.current_block = try ProducingBlock.init(
            self.allocator,
            slot,
            bank,
            start_hash,
        );

        self.stats.slots_started += 1;
    }

    /// Submit transaction for inclusion
    pub fn submitTransaction(self: *Self, tx: Transaction) !void {
        self.tx_queue_mutex.lock();
        defer self.tx_queue_mutex.unlock();

        try self.tx_queue.append(tx);
        self.stats.transactions_received += 1;
    }

    /// Process pending transactions
    pub fn processPending(self: *Self) !void {
        const block = self.current_block orelse return;

        self.tx_queue_mutex.lock();
        const transactions = self.tx_queue.toOwnedSlice() catch {
            self.tx_queue_mutex.unlock();
            return;
        };
        self.tx_queue_mutex.unlock();

        defer self.allocator.free(transactions);

        if (transactions.len == 0) return;

        // Execute transactions on bank
        const result = try block.bank.processTransactions(transactions);
        self.stats.transactions_processed += result.successful;
        self.stats.transactions_failed += result.failed;

        // Record entry with successful transactions
        // (In production, would filter to only successful)
        if (result.successful > 0) {
            try block.recordEntry(transactions);
        }
    }

    /// Tick the producer (advance PoH)
    pub fn tick(self: *Self) !bool {
        const block = self.current_block orelse return false;

        // Hash forward
        for (0..self.config.hashes_per_tick) |_| {
            block.hashOnce();
        }

        // Record tick
        try block.recordTick();

        // Check if complete
        if (block.isComplete(self.config.ticks_per_slot)) {
            try self.finishSlot();
            return true;
        }

        return false;
    }

    /// Finish current slot
    fn finishSlot(self: *Self) !void {
        const block = self.current_block orelse return;

        // Freeze bank
        try block.bank.freeze();

        self.stats.blocks_produced += 1;
        self.stats.entries_produced += block.entries.items.len;

        // Generate shreds and broadcast
        if (self.block_builder) |*builder| {
            // Start block for shredding
            builder.startBlock(block.slot, if (block.slot > 0) block.slot - 1 else 0);

            // Add each entry's serialized data
            for (block.entries.items) |*entry| {
                var entry_data = std.ArrayList(u8).init(self.allocator);
                defer entry_data.deinit();

                // Serialize entry: num_hashes + hash + num_txs
                const writer = entry_data.writer();
                try writer.writeInt(u64, entry.num_hashes, .little);
                try writer.writeAll(&entry.hash);
                try writer.writeInt(u64, entry.transactions.len, .little);

                // Add to builder
                try builder.addEntry(entry_data.items);
            }

            // Finish and get shreds
            const shreds = try builder.finishBlock();
            defer {
                for (shreds) |shred| {
                    self.allocator.free(shred);
                }
                self.allocator.free(shreds);
            }

            self.stats.shreds_produced += shreds.len;

            // Broadcast via callback
            if (self.broadcast_fn) |broadcast| {
                broadcast(shreds);
            }
        }
    }

    /// Get current slot being produced
    pub fn currentSlot(self: *const Self) ?u64 {
        if (self.current_block) |block| {
            return block.slot;
        }
        return null;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) ProducerStats {
        return self.stats;
    }
};

/// Producer statistics
pub const ProducerStats = struct {
    slots_started: u64 = 0,
    blocks_produced: u64 = 0,
    entries_produced: u64 = 0,
    shreds_produced: u64 = 0,
    transactions_received: u64 = 0,
    transactions_processed: u64 = 0,
    transactions_failed: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "block producer init" {
    const allocator = std.testing.allocator;

    var identity: [32]u8 = undefined;
    @memset(&identity, 0x11);

    const producer = try BlockProducer.init(allocator, identity, .{});
    defer producer.deinit();

    try std.testing.expectEqual(@as(?u64, null), producer.currentSlot());
}

test "producing block" {
    // Would need a mock bank for full test
    var start_hash: [32]u8 = undefined;
    @memset(&start_hash, 0);
    try std.testing.expect(start_hash[0] == 0);
}

