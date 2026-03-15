//! Vexor Transaction Forwarder
//!
//! Forwards transactions to the current slot leader.
//! Non-leaders forward incoming transactions to avoid dropping them.
//!
//! Features:
//! - Leader detection from schedule
//! - QUIC/UDP forwarding
//! - Deduplication
//! - Rate limiting

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

const socket = @import("socket.zig");
const packet = @import("packet.zig");
const cluster_info = @import("cluster_info.zig");

/// Forwarder configuration
pub const ForwarderConfig = struct {
    /// Maximum transactions to queue
    max_queue_size: usize = 10000,
    /// Forward batch size
    batch_size: usize = 64,
    /// Forward interval (ms)
    forward_interval_ms: u64 = 50,
    /// Dedup filter size
    dedup_filter_size: usize = 65536,
    /// Rate limit per leader (tx/sec)
    rate_limit_per_leader: u64 = 10000,
};

/// Transaction to forward
pub const ForwardTransaction = struct {
    /// Serialized transaction data
    data: []const u8,
    /// Transaction signature (for dedup)
    signature: [64]u8,
    /// Receive time
    received_at_ns: i128,
    /// Already forwarded
    forwarded: bool,
};

/// Transaction forwarder
pub const TxForwarder = struct {
    allocator: Allocator,
    config: ForwarderConfig,

    /// Our identity
    identity: [32]u8,

    /// Transaction queue
    tx_queue: std.ArrayList(ForwardTransaction),
    queue_mutex: Mutex,

    /// Deduplication filter
    seen_signatures: std.AutoHashMap([64]u8, void),
    seen_mutex: Mutex,

    /// UDP socket for forwarding
    forward_socket: ?*socket.UdpSocket,

    /// Cluster info for leader lookup
    cluster: ?*cluster_info.ClusterInfo,

    /// Statistics
    stats: ForwarderStats,

    /// Running state
    running: Atomic(bool),

    const Self = @This();

    pub fn init(allocator: Allocator, identity: [32]u8, config: ForwarderConfig) !*Self {
        const forwarder = try allocator.create(Self);
        forwarder.* = Self{
            .allocator = allocator,
            .config = config,
            .identity = identity,
            .tx_queue = std.ArrayList(ForwardTransaction).init(allocator),
            .queue_mutex = .{},
            .seen_signatures = std.AutoHashMap([64]u8, void).init(allocator),
            .seen_mutex = .{},
            .forward_socket = null,
            .cluster = null,
            .stats = .{},
            .running = Atomic(bool).init(false),
        };
        return forwarder;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.tx_queue.deinit();
        self.seen_signatures.deinit();
        self.allocator.destroy(self);
    }

    /// Set cluster info for leader lookup
    pub fn setClusterInfo(self: *Self, cluster: *cluster_info.ClusterInfo) void {
        self.cluster = cluster;
    }

    /// Start forwarder
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .seq_cst)) return;

        self.forward_socket = try socket.UdpSocket.bind(self.allocator, "0.0.0.0", 0);
    }

    /// Stop forwarder
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .seq_cst)) return;

        if (self.forward_socket) |sock| {
            sock.close();
            self.forward_socket = null;
        }
    }

    /// Queue transaction for forwarding
    pub fn queueTransaction(self: *Self, data: []const u8) !bool {
        if (data.len < 65) return error.TooShort;

        // Extract signature
        var signature: [64]u8 = undefined;
        @memcpy(&signature, data[1..65]);

        // Dedup check
        self.seen_mutex.lock();
        const already_seen = self.seen_signatures.contains(signature);
        if (!already_seen) {
            try self.seen_signatures.put(signature, {});
        }
        self.seen_mutex.unlock();

        if (already_seen) {
            self.stats.duplicates_dropped += 1;
            return false;
        }

        // Queue for forwarding
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.tx_queue.items.len >= self.config.max_queue_size) {
            self.stats.queue_full_drops += 1;
            return false;
        }

        const tx_data = try self.allocator.dupe(u8, data);
        try self.tx_queue.append(ForwardTransaction{
            .data = tx_data,
            .signature = signature,
            .received_at_ns = std.time.nanoTimestamp(),
            .forwarded = false,
        });

        self.stats.transactions_queued += 1;
        return true;
    }

    /// Forward queued transactions to leader
    pub fn forwardToLeader(self: *Self, current_slot: u64) !void {
        const cluster = self.cluster orelse return;
        const sock = self.forward_socket orelse return;

        // Get leader for current slot
        const leader_pubkey = cluster.cluster_info.LeaderSchedule.getLeader(current_slot) orelse return;

        // Don't forward to self
        if (std.mem.eql(u8, &leader_pubkey, &self.identity)) return;

        // Get leader's TPU address
        const leader_tpu = self.getLeaderTpu(leader_pubkey) orelse return;

        // Get transactions to forward
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        var forwarded_count: u64 = 0;
        for (self.tx_queue.items) |*tx| {
            if (tx.forwarded) continue;
            if (forwarded_count >= self.config.batch_size) break;

            // Send transaction
            _ = sock.sendTo(tx.data, leader_tpu) catch continue;

            tx.forwarded = true;
            forwarded_count += 1;
        }

        self.stats.transactions_forwarded += forwarded_count;

        // Remove old forwarded transactions
        try self.cleanupForwarded();
    }

    fn getLeaderTpu(self: *Self, pubkey: [32]u8) ?net.Address {
        const cluster = self.cluster orelse return null;

        cluster.peers_mutex.lock();
        defer cluster.peers_mutex.unlock();

        if (cluster.peers.get(pubkey)) |peer| {
            if (peer.tpuAddr()) |addr| {
                // Convert SocketAddr to net.Address
                return net.Address.initIp4(addr.addr.v4.addr, addr.port);
            }
        }
        return null;
    }

    fn cleanupForwarded(self: *Self) !void {
        const now = std.time.nanoTimestamp();
        const max_age_ns: i128 = 10 * 1_000_000_000; // 10 seconds

        var i: usize = 0;
        while (i < self.tx_queue.items.len) {
            const tx = &self.tx_queue.items[i];
            if (tx.forwarded and (now - tx.received_at_ns) > max_age_ns) {
                self.allocator.free(tx.data);
                _ = self.tx_queue.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Clear dedup filter (call periodically)
    pub fn clearDedupFilter(self: *Self) void {
        self.seen_mutex.lock();
        defer self.seen_mutex.unlock();
        self.seen_signatures.clearRetainingCapacity();
        self.stats.dedup_clears += 1;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) ForwarderStats {
        return self.stats;
    }
};

/// Forwarder statistics
pub const ForwarderStats = struct {
    transactions_queued: u64 = 0,
    transactions_forwarded: u64 = 0,
    duplicates_dropped: u64 = 0,
    queue_full_drops: u64 = 0,
    dedup_clears: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "forwarder init" {
    const allocator = std.testing.allocator;

    var identity: [32]u8 = undefined;
    @memset(&identity, 0x11);

    const forwarder = try TxForwarder.init(allocator, identity, .{});
    defer forwarder.deinit();

    try std.testing.expectEqual(@as(u64, 0), forwarder.stats.transactions_queued);
}

test "deduplication" {
    const allocator = std.testing.allocator;

    var identity: [32]u8 = undefined;
    @memset(&identity, 0x11);

    const forwarder = try TxForwarder.init(allocator, identity, .{});
    defer forwarder.deinit();

    // Create fake transaction data (needs at least 65 bytes)
    var tx_data: [100]u8 = undefined;
    @memset(&tx_data, 0x42);
    tx_data[0] = 1; // num signatures

    // First queue should succeed
    const first = try forwarder.queueTransaction(&tx_data);
    try std.testing.expect(first);

    // Second with same signature should be deduped
    const second = try forwarder.queueTransaction(&tx_data);
    try std.testing.expect(!second);

    try std.testing.expectEqual(@as(u64, 1), forwarder.stats.duplicates_dropped);
}

