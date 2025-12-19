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

    /// Start the TPU service
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;

        // Bind UDP socket (legacy clients)
        var udp = try socket.UdpSocket.init();
        errdefer udp.deinit();
        try udp.bindPort(self.tpu_port);
        self.udp_socket = udp;

        // Start QUIC endpoint (modern clients)
        if (self.quic_endpoint) |qe| {
            try qe.listen(self.tpu_quic_port);
            std.debug.print("TPU QUIC endpoint started on port {}\n", .{self.tpu_quic_port});
        }

        self.running.store(true, .seq_cst);

        std.debug.print("TPU service started - UDP:{} QUIC:{}\n", .{ self.tpu_port, self.tpu_quic_port });
    }

    /// Stop the TPU service
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
    }

    /// Process incoming packets (call in main loop)
    pub fn processPackets(self: *Self) !usize {
        if (!self.running.load(.seq_cst)) return 0;

        var batch = try packet.PacketBatch.init(self.allocator, self.config.batch_size);
        defer batch.deinit();

        // Receive packets
        const received = try self.udp_socket.?.recvBatch(&batch);
        if (received == 0) return 0;

        // Process each packet
        var processed: usize = 0;
        for (batch.slice()) |*pkt| {
            if (self.processTransaction(pkt)) {
                processed += 1;
            }
        }

        return processed;
    }

    /// Process a single transaction packet
    fn processTransaction(self: *Self, pkt: *const packet.Packet) bool {
        _ = self.stats.transactions_received.fetchAdd(1, .monotonic);

        // Parse transaction
        const tx = self.tx_parser.parse(pkt.payload()) catch {
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
        const queued_tx = QueuedTransaction{
            .signature = tx.signatures[0],
            .fee_payer = tx.feePayer(),
            .priority = self.calculatePriority(&tx),
            .received_at = @intCast(std.time.nanoTimestamp()),
            .raw_data = pkt.payload(),
        };

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
            @memcpy(pkt.data[0..tx.raw_data.len], tx.raw_data);
            pkt.len = @intCast(tx.raw_data.len);
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
        const tx = self.tx_parser.parse(tx_data) catch {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return error.ParseError;
        };

        if (!tx.verifySignatures()) {
            _ = self.stats.invalid_signatures.fetchAdd(1, .monotonic);
            return error.InvalidSignature;
        }

        _ = self.stats.transactions_verified.fetchAdd(1, .monotonic);

        // Add to queue with high priority (votes are important!)
        const queued_tx = QueuedTransaction{
            .signature = tx.signatures[0],
            .fee_payer = tx.feePayer(),
            .priority = std.math.maxInt(u64), // Max priority for internal submissions
            .received_at = @intCast(std.time.nanoTimestamp()),
            .raw_data = tx_data,
        };

        try self.tx_queue.push(queued_tx);
        
        std.log.debug("[TPU] Transaction submitted: {x}", .{tx.signatures[0].data[0..8]});
    }

    /// Submit a raw vote transaction (bypasses parsing for speed)
    pub fn submitVoteTransaction(self: *Self, vote_tx: []const u8) !void {
        // For votes, we trust the internal VoteSubmitter
        const queued_tx = QueuedTransaction{
            .signature = core.Signature{ .data = vote_tx[1..65].* }, // Extract signature
            .fee_payer = core.Pubkey{ .data = vote_tx[65..97].* },   // Approximate
            .priority = std.math.maxInt(u64), // Votes always high priority
            .received_at = @intCast(std.time.nanoTimestamp()),
            .raw_data = vote_tx,
        };

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

    /// Raw transaction data
    raw_data: []const u8,
};

/// Priority queue for transactions
pub const TransactionQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(QueuedTransaction),
    max_size: usize,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(QueuedTransaction).init(allocator),
            .max_size = max_size,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }

    /// Push a transaction (maintains priority order)
    pub fn push(self: *Self, tx: QueuedTransaction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len >= self.max_size) {
            // Drop lowest priority if full
            if (self.items.items.len > 0) {
                const last = self.items.items[self.items.items.len - 1];
                if (tx.priority <= last.priority) {
                    return error.QueueFull;
                }
                _ = self.items.pop();
            }
        }

        // Insert in priority order (highest first)
        var insert_idx: usize = 0;
        for (self.items.items, 0..) |item, i| {
            if (tx.priority > item.priority) {
                insert_idx = i;
                break;
            }
            insert_idx = i + 1;
        }

        try self.items.insert(insert_idx, tx);
    }

    /// Drain up to max_count transactions
    pub fn drain(self: *Self, max_count: usize) ![]QueuedTransaction {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = @min(max_count, self.items.items.len);
        if (count == 0) return &[_]QueuedTransaction{};

        const result = try self.allocator.alloc(QueuedTransaction, count);
        @memcpy(result, self.items.items[0..count]);

        // Remove drained items
        for (0..count) |_| {
            _ = self.items.orderedRemove(0);
        }

        return result;
    }

    /// Get current queue length
    pub fn len(self: *const Self) usize {
        return self.items.items.len;
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
        .raw_data = &[_]u8{},
    });

    try queue.push(.{
        .signature = core.Signature{ .data = [_]u8{2} ** 64 },
        .fee_payer = core.Pubkey{ .data = [_]u8{0} ** 32 },
        .priority = 200,
        .received_at = 0,
        .raw_data = &[_]u8{},
    });

    try std.testing.expectEqual(@as(usize, 2), queue.len());

    // Higher priority should be first
    const drained = try queue.drain(1);
    defer std.testing.allocator.free(drained);

    try std.testing.expectEqual(@as(u64, 200), drained[0].priority);
}
