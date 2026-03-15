//! Vexor TPU Client
//!
//! Transaction Processing Unit client for submitting transactions.
//! Reference: Firedancer src/disco/quic/fd_quic_tile.c
//!
//! The TPU client sends transactions to leader nodes using:
//! - UDP (legacy, simple but unreliable)
//! - QUIC (preferred, reliable with flow control)

const std = @import("std");
const core = @import("../core/root.zig");
const packet = @import("packet.zig");
const gossip = @import("gossip.zig");
const consensus = @import("../consensus/root.zig");
const solana_quic = @import("solana_quic.zig");

/// TPU port offset from gossip port (Solana convention)
pub const TPU_PORT_OFFSET: u16 = 6;

/// Maximum transaction size
pub const MAX_TX_SIZE: usize = 1232;

/// Maximum pending transactions
pub const MAX_PENDING_TXS: usize = 256;

/// Max transactions per QUIC batch
pub const MAX_TX_BATCH: usize = 32;

const LEADER_CACHE_TTL_SECS: i64 = 30;
const LEADER_NEGATIVE_CACHE_TTL_SECS: i64 = 5;
const QUIC_BACKOFF_BASE_MS: u64 = 200;
const QUIC_BACKOFF_MAX_MS: u64 = 4000;
const QUIC_BACKOFF_JITTER_MS: u64 = 50;
const QUIC_BATCH_LOG_EVERY: u64 = 50;

/// TPU connection type
pub const ConnectionType = enum {
    /// UDP connection (legacy, unreliable)
    udp,
    /// QUIC connection (reliable)
    quic,
};

/// TPU client for sending transactions
/// Reference: Firedancer fd_tpu_tile
pub const TpuClient = struct {
    allocator: std.mem.Allocator,

    /// UDP socket for legacy TPU
    udp_socket: ?std.posix.socket_t,

    /// QUIC client for modern TPU
    quic_client: ?*solana_quic.SolanaTpuQuic,
    enable_quic: bool,
    enable_h3_datagram: bool,
    force_quic: bool,
    enable_quic_coalesce: bool,
    quic_batch_size_override: u8,
    quic_batch_auto_cap: u8,
    quic_batch_success_streak: u8,
    quic_batch_fail_streak: u8,
    quic_batch_log_counter: u64,

    /// Reference to gossip service for peer discovery
    gossip_service: ?*gossip.GossipService,
    leader_schedule: ?*consensus.leader_schedule.LeaderScheduleCache,
    quic_insecure: bool,
    quic_port: u16,

    /// RPC URL for fallback leader lookup
    rpc_url: ?[]const u8 = null,
    /// QUIC target override for local testing
    quic_target_override: ?packet.SocketAddr = null,

    /// Leader TPU addresses (slot -> address)
    leader_tpu_cache: std.AutoHashMap(core.Slot, packet.SocketAddr),
    /// Leader TPU QUIC addresses (slot -> address)
    leader_tpu_quic_cache: std.AutoHashMap(core.Slot, packet.SocketAddr),
    leader_tpu_cache_ts: std.AutoHashMap(core.Slot, i64),
    leader_tpu_quic_cache_ts: std.AutoHashMap(core.Slot, i64),

    /// Negative lookup cache: tracks slots where leader lookup failed.
    /// Prevents repeated expensive gossip/RPC lookups for the same slot.
    /// Value is the timestamp of the failed lookup.
    failed_leader_lookups: std.AutoHashMap(core.Slot, i64),
    /// Counter for throttling "leader not found" log messages
    leader_miss_count: u64,

    /// Pending transactions waiting to be sent
    pending_txs: std.ArrayList(PendingTx),
    mutex: std.Thread.Mutex,

    /// Statistics
    stats: TpuStats,

    /// Buffer for HTTP responses (avoids curl FD inheritance issues)
    http_response_buf: [8192]u8 = undefined,

    const Self = @This();

    pub const PendingTx = struct {
        data: []u8,
        target_slot: core.Slot,
        attempts: u32,
        timestamp: i64,
        next_retry_at_ms: u64,
    };

    pub const TpuStats = struct {
        txs_sent_udp: u64 = 0,
        txs_sent_quic: u64 = 0,
        txs_sent_quic_batches: u64 = 0,
        txs_sent_quic_batched: u64 = 0,
        txs_failed: u64 = 0,
        txs_dropped: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,
        cache_refreshes: u64 = 0,
        quic_retries: u64 = 0,
        quic_backoffs: u64 = 0,
    };

    pub fn initDefault(allocator: std.mem.Allocator) !*Self {
        return init(allocator, true, true, false, true, 0, true, 8009);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        enable_quic: bool,
        enable_h3_datagram: bool,
        force_quic: bool,
        enable_quic_coalesce: bool,
        quic_batch_size_override: u8,
        quic_insecure: bool,
        quic_port: u16,
    ) !*Self {
        const self = try allocator.create(Self);

        // Create UDP socket
        const udp_sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        ) catch |err| blk: {
            std.debug.print("[TpuClient] Failed to create UDP socket: {}\n", .{err});
            break :blk null;
        };

        self.* = Self{
            .allocator = allocator,
            .udp_socket = udp_sock,
            .quic_client = null,
            .enable_quic = enable_quic,
            .enable_h3_datagram = enable_h3_datagram,
            .force_quic = force_quic,
            .enable_quic_coalesce = enable_quic_coalesce,
            .quic_batch_size_override = quic_batch_size_override,
            .quic_batch_auto_cap = MAX_TX_BATCH,
            .quic_batch_success_streak = 0,
            .quic_batch_fail_streak = 0,
            .quic_batch_log_counter = 0,
            .quic_insecure = quic_insecure,
            .quic_port = quic_port,
            .gossip_service = null,
            .leader_schedule = null,
            .leader_tpu_cache = std.AutoHashMap(core.Slot, packet.SocketAddr).init(allocator),
            .leader_tpu_quic_cache = std.AutoHashMap(core.Slot, packet.SocketAddr).init(allocator),
            .leader_tpu_cache_ts = std.AutoHashMap(core.Slot, i64).init(allocator),
            .leader_tpu_quic_cache_ts = std.AutoHashMap(core.Slot, i64).init(allocator),
            .failed_leader_lookups = std.AutoHashMap(core.Slot, i64).init(allocator),
            .leader_miss_count = 0,
            .pending_txs = std.ArrayList(PendingTx).init(allocator),
            .mutex = .{},
            .stats = TpuStats{},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.udp_socket) |sock| std.posix.close(sock);
        self.leader_tpu_cache.deinit();
        self.leader_tpu_quic_cache.deinit();
        self.leader_tpu_cache_ts.deinit();
        self.leader_tpu_quic_cache_ts.deinit();
        self.failed_leader_lookups.deinit();
        for (self.pending_txs.items) |*pending| {
            self.allocator.free(pending.data);
        }
        self.pending_txs.deinit();
        self.allocator.destroy(self);
    }

    pub fn setQuicClient(self: *Self, quic_client: *solana_quic.SolanaTpuQuic) void {
        self.quic_client = quic_client;
        self.enable_quic = true;
    }

    pub fn setGossipService(self: *Self, gs: *gossip.GossipService) void {
        self.gossip_service = gs;
    }

    pub fn setLeaderSchedule(self: *Self, schedule: *consensus.leader_schedule.LeaderScheduleCache) void {
        self.leader_schedule = schedule;
    }

    pub fn setRpcUrl(self: *Self, url: []const u8) void {
        self.rpc_url = self.allocator.dupe(u8, url) catch return;
    }

    /// Override QUIC target address (local testing)
    pub fn setQuicTargetOverride(self: *Self, addr: packet.SocketAddr) void {
        self.quic_target_override = addr;
    }

    /// Update leader TPU address for a slot
    pub fn updateLeaderTpu(self: *Self, slot: core.Slot, addr: packet.SocketAddr) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.cacheLeaderTpuNoLock(slot, addr);
    }

    /// Get TPU address for current leader (Public with lock)
    pub fn getLeaderTpu(self: *Self, slot: core.Slot) ?packet.SocketAddr {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getLeaderTpuNoLock(slot);
    }

    /// Internal non-locking TPU lookup
    fn getLeaderTpuNoLock(self: *Self, slot: core.Slot) ?packet.SocketAddr {
        // First check cache
        if (self.leader_tpu_cache.get(slot)) |addr| {
            if (self.isCacheFresh(self.leader_tpu_cache_ts.get(slot))) {
                return addr;
            }
            _ = self.leader_tpu_cache.remove(slot);
            _ = self.leader_tpu_cache_ts.remove(slot);
            self.stats.cache_refreshes += 1;
        }

        // Check negative cache — don't retry failed lookups within TTL
        if (self.failed_leader_lookups.get(slot)) |fail_ts| {
            const now = std.time.timestamp();
            if (now - fail_ts < LEADER_NEGATIVE_CACHE_TTL_SECS) {
                return null; // Still in cooldown, skip expensive lookup
            }
            // Expired — remove and try again
            _ = self.failed_leader_lookups.remove(slot);
        }

        // Try to look up leader TPU from gossip + leader schedule
        const leader_pubkey = self.getLeaderPubkey(slot);
        if (leader_pubkey) |lp| {
            if (self.gossip_service) |gs| {
                if (gs.table.getContact(lp)) |contact| {
                    const addr = contact.tpu_addr;
                    self.cacheLeaderTpuNoLock(slot, addr) catch {};
                    return addr;
                } else {
                    // Throttled: only log every 100th miss to avoid spam
                    self.leader_miss_count += 1;
                    if (self.leader_miss_count % 100 == 1) {
                        std.debug.print("[TPU] leader not in gossip (slot={d}, miss_count={d})\n", .{ slot, self.leader_miss_count });
                    }
                }
            } else {
                if (self.leader_miss_count % 100 == 1) {
                    std.debug.print("[TPU] gossip_service is null (slot={d})\n", .{slot});
                }
            }
        } else {
            self.leader_miss_count += 1;
            if (self.leader_miss_count % 100 == 1) {
                std.debug.print("[TPU] no leader pubkey (slot={d}, miss_count={d})\n", .{ slot, self.leader_miss_count });
            }
        }

        // Localnet fallback: try RPC cluster nodes for TPU_VOTE
        if (self.rpc_url) |rpc_url| {
            if (self.fetchTpuVoteFromRpc(rpc_url)) |addr| {
                self.cacheLeaderTpuNoLock(slot, addr) catch {};
                return addr;
            }
        }

        // Cache this failure to avoid repeated expensive lookups
        self.failed_leader_lookups.put(slot, std.time.timestamp()) catch {};
        return null;
    }

    /// Get QUIC TPU address for current leader (Public with lock)
    pub fn getLeaderTpuQuic(self: *Self, slot: core.Slot) ?packet.SocketAddr {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getLeaderTpuQuicNoLock(slot);
    }

    /// Internal non-locking QUIC TPU lookup
    fn getLeaderTpuQuicNoLock(self: *Self, slot: core.Slot) ?packet.SocketAddr {
        if (self.quic_target_override) |addr| {
            return addr;
        }
        if (self.leader_tpu_quic_cache.get(slot)) |addr| {
            if (self.isCacheFresh(self.leader_tpu_quic_cache_ts.get(slot))) {
                return addr;
            }
            _ = self.leader_tpu_quic_cache.remove(slot);
            _ = self.leader_tpu_quic_cache_ts.remove(slot);
            self.stats.cache_refreshes += 1;
        }

        // 1. Try to get explicit QUIC port from Gossip first
        const lp_opt = self.getLeaderPubkey(slot);
        if (lp_opt) |leader_pubkey| {
            if (self.gossip_service) |gs| {
                if (gs.table.getContact(leader_pubkey)) |contact| {
                    if (contact.tpu_quic_addr.port() != 0) {
                        const addr = contact.tpu_quic_addr;
                        self.cacheLeaderTpuQuicNoLock(slot, addr) catch {};
                        return addr;
                    }
                } else {
                    std.log.info("[TpuClient] No gossip contact for leader {any} at slot {d}", .{ leader_pubkey, slot });
                }
            }
        } else {
            std.log.info("[TpuClient] No leader pubkey for slot {d}", .{slot});
        }

        // 2. Fall back to RPC cluster-nodes lookup
        if (self.rpc_url) |rpc_url| {
            if (self.fetchTpuQuicFromRpc(rpc_url)) |addr| {
                self.cacheLeaderTpuQuicNoLock(slot, addr) catch {};
                return addr;
            }
        }

        // 3. Fall back to UDP+6 heuristic
        if (self.getLeaderTpuNoLock(slot)) |udp_addr| {
            if (udp_addr.port() <= std.math.maxInt(u16) - 6) {
                const quic_addr = packet.SocketAddr.ipv4(udp_addr.addr[0..4].*, @intCast(udp_addr.port() + 6));
                self.cacheLeaderTpuQuicNoLock(slot, quic_addr) catch {};
                return quic_addr;
            }
        }

        return null;
    }

    fn cacheLeaderTpuNoLock(self: *Self, slot: core.Slot, addr: packet.SocketAddr) !void {
        try self.leader_tpu_cache.put(slot, addr);
        try self.leader_tpu_cache_ts.put(slot, std.time.timestamp());
    }

    fn cacheLeaderTpuQuicNoLock(self: *Self, slot: core.Slot, addr: packet.SocketAddr) !void {
        try self.leader_tpu_quic_cache.put(slot, addr);
        try self.leader_tpu_quic_cache_ts.put(slot, std.time.timestamp());
    }

    fn isCacheFresh(self: *Self, ts: ?i64) bool {
        _ = self;
        const now = std.time.timestamp();
        return ts != null and (now - ts.?) <= LEADER_CACHE_TTL_SECS;
    }

    /// Get leader pubkey for a slot from leader schedule
    fn getLeaderPubkey(self: *Self, slot: core.Slot) ?core.Pubkey {
        if (self.leader_schedule) |schedule| {
            if (schedule.getSlotLeader(slot)) |leader| {
                return leader;
            }
        }
        return null;
    }

    fn fetchTpuVoteFromRpc(self: *Self, rpc_url: []const u8) ?packet.SocketAddr {
        const response = self.httpPost(rpc_url, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getClusterNodes\"}") orelse return null;
        if (self.parseAddrField(response, "\"tpuVote\":\"")) |addr| return addr;
        if (self.parseAddrField(response, "\"tpu\":\"")) |addr| return addr;
        return null;
    }

    fn fetchTpuQuicFromRpc(self: *Self, rpc_url: []const u8) ?packet.SocketAddr {
        const response = self.httpPost(rpc_url, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getClusterNodes\"}") orelse return null;
        if (self.parseAddrField(response, "\"tpuQuic\":\"")) |addr| return addr;
        return null;
    }

    fn httpPost(self: *Self, url: []const u8, body: []const u8) ?[]const u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return null;
        var server_header_buffer: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{ .server_header_buffer = &server_header_buffer }) catch return null;
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;
        const response_len = req.reader().readAll(&self.http_response_buf) catch return null;
        return self.http_response_buf[0..response_len];
    }

    fn parseAddrField(self: *Self, response: []const u8, field: []const u8) ?packet.SocketAddr {
        _ = self;
        const start_idx = std.mem.indexOf(u8, response, field) orelse return null;
        const addr_start = start_idx + field.len;
        const end_idx = std.mem.indexOf(u8, response[addr_start..], "\"") orelse return null;
        const addr_str = response[addr_start..][0..end_idx];
        const colon_idx = std.mem.indexOf(u8, addr_str, ":") orelse return null;
        const ip_str = addr_str[0..colon_idx];
        const port_str = addr_str[colon_idx + 1 ..];
        var ip: [4]u8 = undefined;
        var it = std.mem.split(u8, ip_str, ".");
        var idx: usize = 0;
        while (it.next()) |part| : (idx += 1) {
            if (idx >= 4) break;
            ip[idx] = std.fmt.parseInt(u8, part, 10) catch return null;
        }
        if (idx != 4) return null;
        const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
        return packet.SocketAddr.ipv4(ip, port);
    }

    /// Send a transaction to the current leader
    pub fn sendTransaction(self: *Self, tx_data: []const u8, target_slot: core.Slot, must_use_quic: bool) !void {
        if (tx_data.len > MAX_TX_SIZE) return error.TransactionTooLarge;

        const leader_addr = self.getLeaderTpu(target_slot) orelse {
            try self.queueTransaction(tx_data, target_slot);
            return;
        };

        if (self.enable_quic) {
            if (self.getLeaderTpuQuic(target_slot)) |quic_addr| {
                if (self.sendQuic(tx_data, quic_addr)) {
                    self.stats.txs_sent_quic += 1;
                    return;
                }
            } else if (self.force_quic) {
                try self.queueTransaction(tx_data, target_slot);
                return;
            }
        }

        if (must_use_quic) return error.QuicRequired;
        try self.sendUdp(tx_data, leader_addr);
        self.stats.txs_sent_udp += 1;
    }

    fn sendUdp(self: *Self, tx_data: []const u8, addr: packet.SocketAddr) !void {
        const sock = self.udp_socket orelse return error.NoSocket;
        const sockaddr = std.net.Address{ .in = .{ .sa = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, addr.port()),
            .addr = std.mem.nativeToBig(u32, (@as(u32, addr.addr[0]) << 24) | (@as(u32, addr.addr[1]) << 16) | (@as(u32, addr.addr[2]) << 8) | @as(u32, addr.addr[3])),
        } } };
        _ = try std.posix.sendto(sock, tx_data, 0, @ptrCast(&sockaddr.in.sa), @sizeOf(@TypeOf(sockaddr.in.sa)));
    }

    fn sendQuic(self: *Self, tx_data: []const u8, addr: packet.SocketAddr) bool {
        const quic_client = self.quic_client orelse return false;
        var ip_buf: [15]u8 = undefined;
        const ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ addr.addr[0], addr.addr[1], addr.addr[2], addr.addr[3] }) catch return false;
        quic_client.sendTransaction(ip, addr.port(), tx_data) catch |err| {
            std.log.debug("[TPU-QUIC] Send failed to {s}:{d}: {}", .{ ip, addr.port(), err });
            return false;
        };
        return true;
    }

    fn queueTransaction(self: *Self, tx_data: []const u8, target_slot: core.Slot) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_txs.items.len >= MAX_PENDING_TXS) {
            const oldest = self.pending_txs.orderedRemove(0);
            self.allocator.free(oldest.data);
            self.stats.txs_dropped += 1;
        }
        const data = try self.allocator.alloc(u8, tx_data.len);
        @memcpy(data, tx_data);
        try self.pending_txs.append(PendingTx{ .data = data, .target_slot = target_slot, .attempts = 0, .timestamp = std.time.timestamp(), .next_retry_at_ms = 0 });
    }

    pub fn processPending(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.pending_txs.items.len) {
            const pending = &self.pending_txs.items[i];
            if (@as(u64, @intCast(std.time.milliTimestamp())) < pending.next_retry_at_ms) {
                i += 1;
                continue;
            }
            if (self.enable_quic) {
                if (self.getLeaderTpuQuicNoLock(pending.target_slot)) |qaddr| {
                    var batch: [MAX_TX_BATCH][]const u8 = undefined;
                    var idxs: [MAX_TX_BATCH]usize = undefined;
                    var count: usize = 0;
                    const desired = self.computeBatchSize();
                    var j: usize = i;
                    while (j < self.pending_txs.items.len and count < desired) : (j += 1) {
                        const item = &self.pending_txs.items[j];
                        const addr = self.getLeaderTpuQuicNoLock(item.target_slot) orelse continue;
                        if (addr.port() == qaddr.port() and std.mem.eql(u8, addr.addr[0..4], qaddr.addr[0..4])) {
                            batch[count] = item.data;
                            idxs[count] = j;
                            count += 1;
                        }
                    }
                    if (count > 0) {
                        const sent = self.sendQuicBatch(batch[0..count], qaddr);
                        if (sent > 0) {
                            var k: usize = count;
                            while (k > 0) {
                                k -= 1;
                                const idx = idxs[k];
                                self.allocator.free(self.pending_txs.items[idx].data);
                                _ = self.pending_txs.orderedRemove(idx);
                            }
                            continue;
                        }
                    }
                }
            }
            i += 1;
        }
    }

    fn computeBatchSize(self: *Self) usize {
        if (self.quic_batch_size_override > 0) return self.quic_batch_size_override;
        return self.quic_batch_auto_cap;
    }

    fn sendQuicBatch(self: *Self, txs: [][]const u8, addr: packet.SocketAddr) usize {
        const quic_client = self.quic_client orelse return 0;
        var ip_buf: [15]u8 = undefined;
        const ip = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ addr.addr[0], addr.addr[1], addr.addr[2], addr.addr[3] }) catch return 0;
        return quic_client.sendTransactionBatchCoalesced(ip, addr.port(), txs) catch 0;
    }

    pub fn sendVote(self: *Self, vote_tx: []const u8, target_slot: core.Slot) !void {
        const slots_to_try = [_]core.Slot{ target_slot, target_slot + 1 };
        var sent_count: u32 = 0;
        for (slots_to_try) |slot| {
            if (self.enable_quic) {
                if (self.getLeaderTpuQuic(slot)) |qaddr| {
                    if (self.sendQuic(vote_tx, qaddr)) {
                        sent_count += 1;
                        self.stats.txs_sent_quic += 1;
                    }
                }
            }
            if (!self.force_quic) {
                if (self.getLeaderTpu(slot)) |addr| {
                    try self.sendUdp(vote_tx, addr);
                    sent_count += 1;
                    self.stats.txs_sent_udp += 1;
                }
            }
        }
        if (sent_count == 0) {
            try self.queueTransaction(vote_tx, target_slot);
            return error.VoteQueued;
        }
    }
};
