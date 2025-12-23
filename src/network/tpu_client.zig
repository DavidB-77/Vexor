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

/// TPU port offset from gossip port (Solana convention)
pub const TPU_PORT_OFFSET: u16 = 6;

/// Maximum transaction size
pub const MAX_TX_SIZE: usize = 1232;

/// Maximum pending transactions
pub const MAX_PENDING_TXS: usize = 256;

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

    /// Reference to gossip service for peer discovery
    gossip_service: ?*gossip.GossipService,

    /// Reference to leader schedule for slot->leader lookup
    leader_schedule: ?*consensus.leader_schedule.LeaderScheduleCache,

    /// Leader TPU addresses (slot -> address)
    leader_tpu_cache: std.AutoHashMap(core.Slot, packet.SocketAddr),

    /// Pending transactions waiting to be sent
    pending_txs: std.ArrayList(PendingTx),

    /// Statistics
    stats: TpuStats,

    const Self = @This();

    pub const PendingTx = struct {
        data: []u8,
        target_slot: core.Slot,
        attempts: u32,
        timestamp: i64,
    };

    pub const TpuStats = struct {
        txs_sent_udp: u64 = 0,
        txs_sent_quic: u64 = 0,
        txs_failed: u64 = 0,
        txs_dropped: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create UDP socket
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        ) catch null;

        // Set non-blocking
        if (sock) |s| {
            const flags = std.posix.fcntl(s, std.posix.F.GETFL, 0) catch 0;
            // O_NONBLOCK = 0x800 on Linux
            _ = std.posix.fcntl(s, std.posix.F.SETFL, flags | 0x800) catch {};
        }

        self.* = Self{
            .allocator = allocator,
            .udp_socket = sock,
            .gossip_service = null,
            .leader_schedule = null,
            .leader_tpu_cache = std.AutoHashMap(core.Slot, packet.SocketAddr).init(allocator),
            .pending_txs = std.ArrayList(PendingTx).init(allocator),
            .stats = TpuStats{},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.udp_socket) |sock| {
            std.posix.close(sock);
        }

        for (self.pending_txs.items) |*pending| {
            self.allocator.free(pending.data);
        }
        self.pending_txs.deinit();
        self.leader_tpu_cache.deinit();

        self.allocator.destroy(self);
    }

    /// Set gossip service reference for peer discovery
    pub fn setGossipService(self: *Self, gossip_svc: *gossip.GossipService) void {
        self.gossip_service = gossip_svc;
    }

    /// Set leader schedule reference for slot->leader lookup
    pub fn setLeaderSchedule(self: *Self, schedule: *consensus.leader_schedule.LeaderScheduleCache) void {
        self.leader_schedule = schedule;
    }

    /// Update leader TPU address for a slot
    pub fn updateLeaderTpu(self: *Self, slot: core.Slot, addr: packet.SocketAddr) !void {
        try self.leader_tpu_cache.put(slot, addr);
    }

    /// Get TPU address for current leader
    pub fn getLeaderTpu(self: *Self, slot: core.Slot) ?packet.SocketAddr {
        // First check cache
        if (self.leader_tpu_cache.get(slot)) |addr| {
            return addr;
        }

        // Try to look up leader TPU from gossip + leader schedule
        const leader_pubkey = self.getLeaderPubkey(slot) orelse {
            return null;
        };
        
        if (self.gossip_service) |gs| {
            // Look up leader's contact info from gossip table
            if (gs.table.getContact(leader_pubkey)) |contact| {
                // Prefer tpu_vote_addr for vote transactions (dedicated vote port)
                // Fall back to regular tpu_addr if vote port not available
                const vote_addr = if (contact.tpu_vote_addr.port() != 0)
                    contact.tpu_vote_addr
                else
                    contact.tpu_addr;
                
                // Validate address before using
                if (vote_addr.port() == 0) {
                    std.debug.print("[TpuClient] Leader found but has no valid port! tpu_vote={d}, tpu={d}\n", .{
                        contact.tpu_vote_addr.port(), contact.tpu_addr.port(),
                    });
                    return null;
                }
                // Cache the result for future lookups
                self.leader_tpu_cache.put(slot, vote_addr) catch {};
                std.debug.print("[TpuClient] Found leader TPU_VOTE for slot {d}: {d}.{d}.{d}.{d}:{d} (vote_port={d})\n", .{
                    slot,
                    vote_addr.addr[0], vote_addr.addr[1],
                    vote_addr.addr[2], vote_addr.addr[3],
                    vote_addr.port(),
                    contact.tpu_vote_addr.port(),
                });
                return vote_addr;
            } else {
                // Leader not found in gossip table - log diagnostics
                const contact_count = gs.table.contactCount();
                std.debug.print("[TpuClient] Leader NOT FOUND in gossip! Looking for: {x:0>2}{x:0>2}{x:0>2}{x:0>2}... ({d} contacts)\n", .{
                    leader_pubkey.data[0], leader_pubkey.data[1],
                    leader_pubkey.data[2], leader_pubkey.data[3],
                    contact_count,
                });
                // Log first few contacts for comparison (only occasionally to avoid spam)
                const S = struct {
                    var miss_count: u32 = 0;
                };
                S.miss_count += 1;
                if (S.miss_count <= 5 or S.miss_count % 100 == 0) {
                    var iter = gs.table.contacts.iterator();
                    var i: usize = 0;
                    while (iter.next()) |entry| {
                        if (i < 3) {
                            std.debug.print("[TpuClient]   Contact[{d}]: {x:0>2}{x:0>2}{x:0>2}{x:0>2}...\n", .{
                                i,
                                entry.key_ptr.data[0], entry.key_ptr.data[1],
                                entry.key_ptr.data[2], entry.key_ptr.data[3],
                            });
                        }
                        i += 1;
                    }
                }
            }
        }

        return null;
    }
    
    /// Get leader pubkey for a slot from leader schedule
    fn getLeaderPubkey(self: *Self, slot: core.Slot) ?core.Pubkey {
        if (self.leader_schedule) |schedule| {
            std.debug.print("[TpuClient] getLeaderPubkey: slot={d}, calling getSlotLeader\n", .{slot});
            if (schedule.getSlotLeader(slot)) |leader_bytes| {
                return core.Pubkey{ .data = leader_bytes };
            }
            std.debug.print("[TpuClient] getSlotLeader returned null\n", .{});
        } else {
            std.debug.print("[TpuClient] leader_schedule is NULL!\n", .{});
        }
        return null;
    }

    /// Send a transaction to the current leader
    pub fn sendTransaction(self: *Self, tx_data: []const u8, target_slot: core.Slot) !void {
        if (tx_data.len > MAX_TX_SIZE) {
            return error.TransactionTooLarge;
        }

        // Get leader TPU address
        const leader_addr = self.getLeaderTpu(target_slot) orelse {
            // Queue for later
            try self.queueTransaction(tx_data, target_slot);
            return;
        };

        // Send via UDP
        try self.sendUdp(tx_data, leader_addr);
        self.stats.txs_sent_udp += 1;
    }

    /// Send transaction via UDP
    fn sendUdp(self: *Self, tx_data: []const u8, addr: packet.SocketAddr) !void {
        const sock = self.udp_socket orelse return error.NoSocket;

        const sockaddr = std.net.Address{
            .in = .{
                .sa = .{
                    .family = std.posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, addr.port()),
                    .addr = std.mem.nativeToBig(u32, (@as(u32, addr.addr[0]) << 24) |
                        (@as(u32, addr.addr[1]) << 16) |
                        (@as(u32, addr.addr[2]) << 8) |
                        @as(u32, addr.addr[3])),
                },
            },
        };

        _ = std.posix.sendto(
            sock,
            tx_data,
            0,
            @ptrCast(&sockaddr.in.sa),
            @sizeOf(@TypeOf(sockaddr.in.sa)),
        ) catch |err| {
            self.stats.txs_failed += 1;
            return err;
        };
    }

    /// Queue a transaction for later sending
    fn queueTransaction(self: *Self, tx_data: []const u8, target_slot: core.Slot) !void {
        if (self.pending_txs.items.len >= MAX_PENDING_TXS) {
            // Drop oldest
            const oldest = self.pending_txs.orderedRemove(0);
            self.allocator.free(oldest.data);
            self.stats.txs_dropped += 1;
        }

        const copy = try self.allocator.alloc(u8, tx_data.len);
        @memcpy(copy, tx_data);

        try self.pending_txs.append(PendingTx{
            .data = copy,
            .target_slot = target_slot,
            .attempts = 0,
            .timestamp = std.time.timestamp(),
        });
    }

    /// Process pending transactions
    pub fn processPending(self: *Self) void {
        var i: usize = 0;
        while (i < self.pending_txs.items.len) {
            const pending = &self.pending_txs.items[i];

            // Check if we have leader address now
            if (self.getLeaderTpu(pending.target_slot)) |addr| {
                // Try to send
                self.sendUdp(pending.data, addr) catch {
                    pending.attempts += 1;
                    if (pending.attempts < 3) {
                        i += 1;
                        continue;
                    }
                    // Too many attempts, drop
                };

                // Remove from pending
                self.allocator.free(pending.data);
                _ = self.pending_txs.orderedRemove(i);
                self.stats.txs_sent_udp += 1;
            } else {
                // Still no leader, check if too old
                const age = std.time.timestamp() - pending.timestamp;
                if (age > 60) {
                    // Too old, drop
                    self.allocator.free(pending.data);
                    _ = self.pending_txs.orderedRemove(i);
                    self.stats.txs_dropped += 1;
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Send a vote transaction (high priority)
    /// VEXOR approach: Send to current + next leader for efficient redundancy.
    /// This balances reliability with lightweight network overhead.
    pub fn sendVote(self: *Self, vote_tx: []const u8, target_slot: core.Slot) !void {
        // Send to current leader + next leader for redundancy
        // VEXOR philosophy: Efficient redundancy (2 leaders) vs heavyweight (4 leaders)
        const slots_to_try = [_]core.Slot{
            target_slot,
            target_slot + 1,
        };

        var sent_count: u32 = 0;
        for (slots_to_try) |slot| {
            if (self.getLeaderTpu(slot)) |addr| {
                self.sendUdp(vote_tx, addr) catch continue;
                sent_count += 1;
            }
        }

        if (sent_count == 0) {
            // No leaders found - queue for later retry
            try self.queueTransaction(vote_tx, target_slot);
            std.debug.print("[TpuClient] Vote queued - no leaders found for slot {d}\n", .{target_slot});
        } else {
            self.stats.txs_sent_udp += sent_count;
            std.debug.print("[TpuClient] Vote sent to {d} leader(s) for slot {d}\n", .{ sent_count, target_slot });
        }
    }
};

/// TPU forward proxy for block producers
/// Accepts transactions from other validators and forwards to leader
pub const TpuForward = struct {
    allocator: std.mem.Allocator,
    client: *TpuClient,

    /// Receive socket for incoming forwards
    recv_socket: ?std.posix.socket_t,

    /// Buffer for receiving
    recv_buffer: [MAX_TX_SIZE]u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, client: *TpuClient, port: u16) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create receive socket
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        );
        errdefer std.posix.close(sock);

        // Bind to port
        const bind_addr = std.net.Address{
            .in = .{
                .sa = .{
                    .family = std.posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, port),
                    .addr = 0, // INADDR_ANY
                },
            },
        };
        try std.posix.bind(sock, &bind_addr.in.sa, @sizeOf(@TypeOf(bind_addr.in.sa)));

        // Set non-blocking
        _ = std.posix.fcntl(sock, .F_SETFL, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))) catch {};

        self.* = Self{
            .allocator = allocator,
            .client = client,
            .recv_socket = sock,
            .recv_buffer = undefined,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.recv_socket) |sock| {
            std.posix.close(sock);
        }
        self.allocator.destroy(self);
    }

    /// Receive and forward transactions
    pub fn poll(self: *Self, current_slot: core.Slot) !void {
        const sock = self.recv_socket orelse return;

        while (true) {
            var src_addr: std.posix.sockaddr = undefined;
            var src_len: std.posix.socklen_t = @sizeOf(@TypeOf(src_addr));

            const len = std.posix.recvfrom(
                sock,
                &self.recv_buffer,
                0,
                &src_addr,
                &src_len,
            ) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };

            if (len > 0) {
                // Forward to leader
                self.client.sendTransaction(self.recv_buffer[0..len], current_slot) catch {};
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "tpu client init" {
    const allocator = std.testing.allocator;

    const client = try TpuClient.init(allocator);
    defer client.deinit();

    try std.testing.expect(client.udp_socket != null);
}

test "tpu client queue" {
    const allocator = std.testing.allocator;

    const client = try TpuClient.init(allocator);
    defer client.deinit();

    // Queue a transaction
    const tx = [_]u8{ 1, 2, 3, 4 };
    try client.queueTransaction(&tx, 12345);

    try std.testing.expectEqual(@as(usize, 1), client.pending_txs.items.len);
}

