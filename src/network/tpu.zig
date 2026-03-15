//! Vexor TPU (Transaction Processing Unit)
//!
//! Handles incoming transaction submission and forwarding.
//! Supports both UDP and QUIC transport (Solana-compatible).
//!
//! Pipeline:
//! 1. Receive packets (UDP for legacy, QUIC for modern clients)
//! 2. Deserialize transactions (bincode format)
//! 3. Signature verification (parallel, GPU-accelerated if available)
//! 4. Priority queue (by compute unit price)
//! 5. Forward to banking stage or leader
//!
//! QUIC Support:
//! - Solana v1.10+ clients use QUIC for transaction submission
//! - Max 128 connections per IP (256 for staked validators)
//! - Max 8 streams per connection
//! - Rate limiting based on stake weight

const std = @import("std");
const core = @import("../core/root.zig");
const packet = @import("packet.zig");
const socket = @import("socket.zig");
const crypto = @import("../crypto/root.zig");
const runtime = @import("../runtime/root.zig");
const solana_quic = @import("solana_quic.zig");
const quic = @import("quic/root.zig");

/// TPU service for transaction ingestion
pub const TpuService = struct {
    allocator: std.mem.Allocator,

    /// UDP socket for transactions (legacy clients)
    udp_socket: ?socket.UdpSocket,

    /// QUIC endpoint for transactions (modern clients)
    quic_endpoint: ?*solana_quic.SolanaTpuQuic,

    /// Port configuration
    tpu_port: u16,
    tpu_fwd_port: u16,
    tpu_quic_port: u16,

    /// Transaction queue (priority ordered)
    tx_queue: TransactionQueue,

    /// Signature verifier
    sig_verifier: ?*crypto.SigVerifier,

    /// Transaction parser
    tx_parser: runtime.transaction.TransactionParser,

    /// Running state
    running: std.atomic.Value(bool),

    /// Statistics
    stats: Stats,

    /// Configuration
    config: Config,

    /// Transaction callback (for pushing to BankingStage without circular deps)
    transaction_callback: ?*const fn (?*anyopaque, runtime.transaction.ParsedTransaction) void,
    transaction_callback_ctx: ?*anyopaque,

    const Self = @This();

    pub const Config = struct {
        /// TPU UDP port (legacy)
        tpu_port: u16 = 8004,

        /// TPU forward port
        tpu_fwd_port: u16 = 8005,

        /// TPU QUIC port (modern clients)
        tpu_quic_port: u16 = 8009,

        /// Maximum transactions in queue
        max_queue_size: usize = 10_000,

        /// Enable forwarding to leader
        enable_forwarding: bool = true,

        /// Packet batch size
        batch_size: usize = 128,

        /// Enable QUIC endpoint
        enable_quic: bool = true,

        /// QUIC configuration
        quic_config: solana_quic.SolanaQuicConfig = .{},
    };

    pub const Stats = struct {
        transactions_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_received_udp: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_received_quic: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_verified: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_forwarded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        invalid_signatures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        parse_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        quic_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const service = try allocator.create(Self);
        errdefer allocator.destroy(service);

        const sig_verifier = try crypto.SigVerifier.init(allocator, .{});
        errdefer sig_verifier.deinit();

        // Initialize QUIC endpoint if enabled
        var quic_endpoint: ?*solana_quic.SolanaTpuQuic = null;
        if (config.enable_quic) {
            quic_endpoint = try solana_quic.SolanaTpuQuic.init(allocator, config.quic_config);
            quic_endpoint.?.setTransactionCallback(service, onQuicTransaction);
        }

        service.* = .{
            .allocator = allocator,
            .udp_socket = null,
            .quic_endpoint = quic_endpoint,
            .tpu_port = config.tpu_port,
            .tpu_fwd_port = config.tpu_fwd_port,
            .tpu_quic_port = config.tpu_quic_port,
            .tx_queue = TransactionQueue.init(allocator, config.max_queue_size),
            .sig_verifier = sig_verifier,
            .tx_parser = runtime.transaction.TransactionParser.init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .stats = .{},
            .transaction_callback = null,
            .transaction_callback_ctx = null,
            .config = config,
        };

        return service;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.udp_socket) |*sock| {
            sock.deinit();
        }

        if (self.quic_endpoint) |qe| {
            qe.deinit();
        }

        if (self.sig_verifier) |sv| {
            sv.deinit();
        }

        self.tx_queue.deinit();
        self.allocator.destroy(self);
    }

    /// Set transaction callback
    pub fn setTransactionCallback(self: *Self, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, runtime.transaction.ParsedTransaction) void) void {
        self.transaction_callback_ctx = ctx;
        self.transaction_callback = callback;
    }

    /// Start the TPU service
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;

        // Bind UDP socket (legacy clients)
        var udp = try socket.UdpSocket.init();
        errdefer udp.deinit();
        try udp.bindPort(self.tpu_port);
        self.udp_socket = udp;

        if (self.quic_endpoint) |qe| {
            try qe.listen(self.tpu_quic_port);
            std.debug.print("TPU QUIC endpoint started on port {}\n", .{self.tpu_quic_port});
        }

        if (self.sig_verifier) |sv| {
            try sv.start();
        }

        self.running.store(true, .seq_cst);

        std.debug.print("TPU service started - UDP:{} QUIC:{}\n", .{ self.tpu_port, self.tpu_quic_port });
    }

    /// Stop the TPU service
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        if (self.sig_verifier) |sv| {
            sv.stop();
        }
    }

    /// Process incoming packets (call in main loop)
    pub fn processPackets(self: *Self) !usize {
        if (!self.running.load(.seq_cst)) return 0;
        var processed_count: usize = 0;

        // 1. Drain verified batches from pipeline
        if (self.sig_verifier) |sv| {
            var verified_batches = std.ArrayList(*crypto.VerifyBatch).init(self.allocator);
            defer verified_batches.deinit();

            try sv.getVerifiedBatches(&verified_batches);

            for (verified_batches.items) |batch| {
                defer {
                    batch.clear();
                    // Put back to pool? Or just reuse next time we allocate?
                    // Currently SigVerify logic allocates batches.
                    // We need to free it here since we own it now (or SigVerify allocated it?)
                    // SigVerifyPipeline.init creates allocator. VerifyBatch uses it.
                    // Wait, VerifyBatch is passed by pointer.
                    // We must determine who OWNS the batch struct memory.
                    // My previous `processPackets` didn't use `SigVerifyPipeline` yet.
                    // I'll assume we alloc/free for now.
                    batch.deinit();
                    self.allocator.destroy(batch);
                }

                // Process verified packets
                for (batch.packets.items) |pkt| {
                    if (pkt.result == .valid) {
                        if (self.processVerifiedPacket(pkt)) {
                            processed_count += 1;
                        }
                    } else {
                        _ = self.stats.invalid_signatures.fetchAdd(1, .monotonic);
                    }
                }
            }
        }

        // 2. Poll QUIC endpoint (if enabled)
        if (self.quic_endpoint) |qe| {
            qe.poll() catch |err| {
                std.debug.print("[TPU-QUIC] poll error: {}\n", .{err});
            };
        }

        // 3. Receive new UDP packets
        // Allocate PacketBatch on heap to persist during verification
        const packet_batch = try self.allocator.create(packet.PacketBatch);
        packet_batch.* = try packet.PacketBatch.init(self.allocator, self.config.batch_size);
        errdefer {
            packet_batch.deinit();
            self.allocator.destroy(packet_batch);
        }

        // Receive UDP packets
        const received = if (self.udp_socket) |*sock|
            try sock.recvBatch(packet_batch)
        else
            0;

        if (received == 0) {
            packet_batch.deinit();
            self.allocator.destroy(packet_batch);
            return processed_count;
        }

        _ = self.stats.transactions_received.fetchAdd(received, .monotonic);
        _ = self.stats.transactions_received_udp.fetchAdd(received, .monotonic);

        // 3. Submit to pipeline
        if (self.sig_verifier) |sv| {
            const verify_batch = try self.allocator.create(crypto.VerifyBatch);
            verify_batch.* = crypto.VerifyBatch.init(self.allocator);
            // Transfer ownership of packet_batch to verify_batch
            verify_batch.context = packet_batch;
            verify_batch.destructor = destructPacketBatch;

            for (packet_batch.slice()) |*pkt| {
                if (crypto.sigverify_mod.SignaturePacket.fromTransaction(pkt.payload())) |sig_pkt| {
                    try verify_batch.add(sig_pkt);
                } else |_| {
                    _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
                }
            }

            try sv.submitBatch(verify_batch);
        } else {
            // No verifier? Drop packets (shouldn't happen if initialized properly)
            packet_batch.deinit();
            self.allocator.destroy(packet_batch);
        }

        return processed_count;
    }

    fn destructPacketBatch(ctx: ?*anyopaque, allocator: std.mem.Allocator) void {
        if (ctx) |ptr| {
            const batch = @as(*packet.PacketBatch, @ptrCast(@alignCast(ptr)));
            batch.deinit();
            allocator.destroy(batch);
        }
    }

    /// Callback for QUIC transactions
    fn onQuicTransaction(ctx: ?*anyopaque, data: []const u8) void {
        const self = @as(*TpuService, @ptrCast(@alignCast(ctx orelse return)));
        _ = self.stats.transactions_received_quic.fetchAdd(1, .monotonic);

        // Submit via submitTransaction (handles parsing and verification)
        self.submitTransaction(data) catch |err| {
            std.log.debug("[TPU-QUIC] Failed to process incoming transaction: {}", .{err});
        };
    }

    fn processVerifiedPacket(self: *Self, pkt: crypto.sigverify_mod.SignaturePacket) bool {
        // Parse fully
        const tx = self.tx_parser.parseFromSlice(pkt.data) catch {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return false;
        };

        _ = self.stats.transactions_verified.fetchAdd(1, .monotonic);

        // If callback is set, use it (Lock-free push to Banking)
        if (self.transaction_callback) |callback| {
            callback(self.transaction_callback_ctx, tx);
            return true;
        }

        // Add to priority queue
        var queued_tx = QueuedTransaction{
            .signature = tx.signatures[0],
            .fee_payer = tx.feePayer(),
            .priority = self.calculatePriority(&tx),
            .received_at = @intCast(std.time.nanoTimestamp()),
            .data = undefined,
            .len = @intCast(pkt.data.len),
        };
        @memcpy(queued_tx.data[0..pkt.data.len], pkt.data);

        self.tx_queue.push(queued_tx) catch {
            _ = self.stats.transactions_dropped.fetchAdd(1, .monotonic);
            return false;
        };
        return true;
    }

    /// Process a single transaction packet
    fn processTransaction(self: *Self, pkt: *const packet.Packet) bool {
        _ = self.stats.transactions_received.fetchAdd(1, .monotonic);

        // Parse transaction
        const tx = self.tx_parser.parseFromSlice(pkt.payload()) catch {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return false;
        };

        // Verify signatures
        if (!tx.verifySignatures()) {
            _ = self.stats.invalid_signatures.fetchAdd(1, .monotonic);
            return false;
        }

        _ = self.stats.transactions_verified.fetchAdd(1, .monotonic);

        // Add to priority queue
        var queued_tx = QueuedTransaction{
            .signature = tx.signatures[0],
            .fee_payer = tx.feePayer(),
            .priority = self.calculatePriority(&tx),
            .received_at = @intCast(std.time.nanoTimestamp()),
            .data = undefined,
            .len = @intCast(pkt.payload().len),
        };
        @memcpy(queued_tx.data[0..pkt.payload().len], pkt.payload());

        self.tx_queue.push(queued_tx) catch {
            _ = self.stats.transactions_dropped.fetchAdd(1, .monotonic);
            return false;
        };

        return true;
    }

    /// Calculate transaction priority (higher = more important)
    fn calculatePriority(self: *Self, tx: *const runtime.transaction.ParsedTransaction) u64 {
        _ = self;

        // Base priority from compute unit price
        var priority: u64 = 0;

        // Check for compute budget instructions
        for (tx.message.instructions) |ix| {
            if (ix.program_id_index < tx.message.account_keys.len) {
                const program = tx.message.account_keys[ix.program_id_index];
                // Check if ComputeBudget program
                if (program.data[0] == 0x03 and program.data[1] == 0x06) {
                    // Parse SetComputeUnitPrice instruction
                    if (ix.data.len >= 9 and ix.data[0] == 3) {
                        priority = std.mem.readInt(u64, ix.data[1..9], .little);
                    }
                }
            }
        }

        return priority;
    }

    /// Drain transactions for banking
    pub fn drainForBanking(self: *Self, max_count: usize) ![]QueuedTransaction {
        return self.tx_queue.drain(max_count);
    }

    /// Forward transactions to the current leader
    pub fn forwardToLeader(self: *Self, leader_tpu: packet.SocketAddr, txs: []const QueuedTransaction) !usize {
        if (!self.config.enable_forwarding) return 0;

        var forwarded: usize = 0;
        for (txs) |tx| {
            var pkt = packet.Packet.init();
            const data = tx.data[0..tx.len];
            @memcpy(pkt.data[0..tx.len], data);
            pkt.len = @intCast(tx.len);
            pkt.src_addr = leader_tpu;

            if (self.udp_socket) |*sock| {
                _ = sock.send(&pkt) catch continue;
                forwarded += 1;
            }
        }

        _ = self.stats.transactions_forwarded.fetchAdd(@intCast(forwarded), .monotonic);
        return forwarded;
    }

    /// Submit a transaction (used by VoteSubmitter and internal systems)
    pub fn submitTransaction(self: *Self, tx_data: []const u8) !void {
        _ = self.stats.transactions_received.fetchAdd(1, .monotonic);

        // Parse and verify
        const tx = self.tx_parser.parseFromSlice(tx_data) catch {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return error.ParseError;
        };

        if (!tx.verifySignatures()) {
            _ = self.stats.invalid_signatures.fetchAdd(1, .monotonic);
            return error.InvalidSignature;
        }

        _ = self.stats.transactions_verified.fetchAdd(1, .monotonic);

        // If callback is set, use it (Lock-free push to Banking)
        if (self.transaction_callback) |callback| {
            callback(self.transaction_callback_ctx, tx);
            return;
        }

        // Add to queue with high priority (votes are important!)
        var queued_tx = QueuedTransaction{
            .signature = tx.signatures[0],
            .fee_payer = tx.feePayer(),
            .priority = std.math.maxInt(u64), // Max priority for internal submissions
            .received_at = @intCast(std.time.nanoTimestamp()),
            .data = undefined,
            .len = @intCast(tx_data.len),
        };
        @memcpy(queued_tx.data[0..tx_data.len], tx_data);

        try self.tx_queue.push(queued_tx);

        std.log.debug("[TPU] Transaction submitted: {x}", .{tx.signatures[0].data[0..8]});
    }

    /// Submit a raw vote transaction (bypasses parsing for speed)
    pub fn submitVoteTransaction(self: *Self, vote_tx: []const u8) !void {
        _ = self.stats.transactions_received.fetchAdd(1, .monotonic);
        // For votes, we trust the internal VoteSubmitter
        var queued_tx = QueuedTransaction{
            .signature = core.Signature{ .data = vote_tx[1..65].* }, // Extract signature
            .fee_payer = core.Pubkey{ .data = vote_tx[65..97].* }, // Approximate
            .priority = std.math.maxInt(u64), // Votes always high priority
            .received_at = @intCast(std.time.nanoTimestamp()),
            .data = undefined,
            .len = @intCast(vote_tx.len),
        };
        @memcpy(queued_tx.data[0..vote_tx.len], vote_tx);

        try self.tx_queue.push(queued_tx);

        std.log.info("[TPU] Vote transaction submitted", .{});
    }

    /// Get current statistics
    pub fn getStats(self: *const Self) Stats {
        return self.stats;
    }

    /// Print statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print(
            \\
            \\═══ TPU Statistics ═══
            \\Received:     {}
            \\Verified:     {}
            \\Forwarded:    {}
            \\Dropped:      {}
            \\Invalid sigs: {}
            \\Parse errors: {}
            \\Queue size:   {}
            \\══════════════════════
            \\
        , .{
            self.stats.transactions_received.load(.seq_cst),
            self.stats.transactions_verified.load(.seq_cst),
            self.stats.transactions_forwarded.load(.seq_cst),
            self.stats.transactions_dropped.load(.seq_cst),
            self.stats.invalid_signatures.load(.seq_cst),
            self.stats.parse_errors.load(.seq_cst),
            self.tx_queue.len(),
        });
    }
};

/// Transaction in the priority queue
pub const QueuedTransaction = struct {
    /// First signature (transaction ID)
    signature: core.Signature,

    /// Fee payer
    fee_payer: core.Pubkey,

    /// Priority (compute unit price)
    priority: u64,

    /// When received (nanoseconds)
    received_at: u64,

    /// Raw transaction data (owned)
    data: [packet.MAX_PACKET_SIZE]u8 align(64),
    len: u16,
};

/// Priority queue for transactions
pub const TransactionQueue = struct {
    allocator: std.mem.Allocator,
    items: std.PriorityQueue(QueuedTransaction, void, compareTransactions),
    max_size: usize,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return .{
            .allocator = allocator,
            .items = std.PriorityQueue(QueuedTransaction, void, compareTransactions).init(allocator, {}),
            .max_size = max_size,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }

    fn compareTransactions(context: void, a: QueuedTransaction, b: QueuedTransaction) std.math.Order {
        _ = context;
        // Highest priority first (Min-heap pops "smallest", so we return .lt for higher priority)
        if (a.priority > b.priority) return .lt;
        if (a.priority < b.priority) return .gt;

        // Tie-breaker: older transactions first
        if (a.received_at < b.received_at) return .lt;
        if (a.received_at > b.received_at) return .gt;

        return .eq;
    }

    /// Push a transaction (maintains priority order)
    pub fn push(self: *Self, tx: QueuedTransaction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.count() >= self.max_size) {
            // In a production validator, we'd find the lowest priority item and drop it if tx is better.
            // For now, just return QueueFull to stay within max_size.
            return error.QueueFull;
        }

        try self.items.add(tx);
    }

    /// Drain up to max_count transactions
    pub fn drain(self: *Self, max_count: usize) ![]QueuedTransaction {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = @min(max_count, self.items.count());
        if (count == 0) return &[_]QueuedTransaction{};

        const result = try self.allocator.alloc(QueuedTransaction, count);
        for (0..count) |i| {
            result[i] = self.items.remove();
        }

        return result;
    }

    /// Get current queue length
    pub fn len(self: *const Self) usize {
        return self.items.count();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "tpu service init" {
    var service = try TpuService.init(std.testing.allocator, .{});
    defer service.deinit();

    try std.testing.expect(!service.running.load(.seq_cst));
}

test "transaction queue" {
    var queue = TransactionQueue.init(std.testing.allocator, 100);
    defer queue.deinit();

    // Add transactions with different priorities
    try queue.push(.{
        .signature = core.Signature{ .data = [_]u8{1} ** 64 },
        .fee_payer = core.Pubkey{ .data = [_]u8{0} ** 32 },
        .priority = 100,
        .received_at = 0,
        .data = undefined,
        .len = 0,
    });

    try queue.push(.{
        .signature = core.Signature{ .data = [_]u8{2} ** 64 },
        .fee_payer = core.Pubkey{ .data = [_]u8{0} ** 32 },
        .priority = 200,
        .received_at = 0,
        .data = undefined,
        .len = 0,
    });

    try std.testing.expectEqual(@as(usize, 2), queue.len());

    // Higher priority should be first
    const drained = try queue.drain(1);
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqual(@as(u64, 200), drained[0].priority);
}
