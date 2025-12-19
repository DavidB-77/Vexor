//! Vexor Cluster Info
//!
//! Manages cluster topology, peer discovery, and contact information.
//! This is the central coordination point for gossip-based networking.
//!
//! Responsibilities:
//! - Entrypoint resolution and connection
//! - Peer discovery and management
//! - Contact info storage (CRDS table)
//! - Leader schedule tracking
//! - Shred version verification

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;
const net = std.net;

const crds = @import("crds.zig");
const socket = @import("socket.zig");
const packet = @import("packet.zig");

/// Cluster configuration
pub const ClusterConfig = struct {
    /// Our identity pubkey
    identity: [32]u8,
    /// Shred version for this cluster
    shred_version: u16,
    /// Expected genesis hash (for verification)
    expected_genesis_hash: ?[32]u8,
    /// Gossip port
    gossip_port: u16,
    /// RPC port
    rpc_port: u16,
    /// TVU port
    tvu_port: u16,
    /// TPU port  
    tpu_port: u16,
    /// Maximum peers to maintain
    max_peers: usize = 1000,
    /// Minimum peers for healthy operation
    min_peers: usize = 10,
    /// Gossip push fanout
    push_fanout: usize = 6,
    /// Contact refresh interval (ms)
    refresh_interval_ms: u64 = 10_000,
};

/// Peer state
pub const PeerState = enum {
    unknown,
    connecting,
    active,
    stale,
    dead,
};

/// Peer entry
pub const Peer = struct {
    pubkey: [32]u8,
    contact_info: ?crds.ContactInfo,
    legacy_contact_info: ?crds.LegacyContactInfo,
    state: PeerState,
    last_seen_ns: i128,
    last_ping_ns: i128,
    ping_count: u32,
    pong_received: bool,
    wallclock: u64,
    shred_version: u16,

    const Self = @This();

    pub fn isActive(self: *const Self) bool {
        return self.state == .active;
    }

    pub fn isHealthy(self: *const Self, current_time_ns: i128) bool {
        const age_ns = current_time_ns - self.last_seen_ns;
        const age_sec = @divTrunc(age_ns, 1_000_000_000);
        return self.state == .active and age_sec < 30;
    }

    pub fn gossipAddr(self: *const Self) ?crds.SocketAddr {
        if (self.contact_info) |ci| {
            // Would extract from modern contact info
            _ = ci;
            return null;
        } else if (self.legacy_contact_info) |lci| {
            return lci.gossip;
        }
        return null;
    }

    pub fn tvuAddr(self: *const Self) ?crds.SocketAddr {
        if (self.legacy_contact_info) |lci| {
            return lci.tvu;
        }
        return null;
    }

    pub fn tpuAddr(self: *const Self) ?crds.SocketAddr {
        if (self.legacy_contact_info) |lci| {
            return lci.tpu;
        }
        return null;
    }
};

/// CRDS table for storing gossip data
pub const CrdsTable = struct {
    allocator: Allocator,
    entries: std.AutoHashMap([32]u8, CrdsEntry),
    mutex: Mutex,

    const Self = @This();

    pub const CrdsEntry = struct {
        value: crds.CrdsValue,
        local_timestamp_ns: i128,
        ordinal: u64,
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = std.AutoHashMap([32]u8, CrdsEntry).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    /// Insert a CRDS value
    pub fn insert(self: *Self, value: crds.CrdsValue, ordinal: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pubkey = value.data.pubkey() orelse return error.NoPubkey;

        // Check if newer than existing
        if (self.entries.get(pubkey.*)) |existing| {
            // Compare wallclocks based on data type
            const existing_wc = getWallclock(&existing.value.data);
            const new_wc = getWallclock(&value.data);

            if (new_wc <= existing_wc) {
                return false; // Older or same, don't insert
            }
        }

        try self.entries.put(pubkey.*, CrdsEntry{
            .value = value,
            .local_timestamp_ns = std.time.nanoTimestamp(),
            .ordinal = ordinal,
        });

        return true;
    }

    /// Get entry by pubkey
    pub fn get(self: *Self, pubkey: [32]u8) ?*const CrdsEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.getPtr(pubkey);
    }

    /// Get all contact infos
    pub fn getAllContactInfos(self: *Self, allocator: Allocator) ![]Peer {
        self.mutex.lock();
        defer self.mutex.unlock();

        var peers = std.ArrayList(Peer).init(allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            const data = &entry.value_ptr.value.data;
            switch (data.*) {
                .LegacyContactInfo => |lci| {
                    try peers.append(Peer{
                        .pubkey = lci.pubkey,
                        .contact_info = null,
                        .legacy_contact_info = lci,
                        .state = .active,
                        .last_seen_ns = entry.value_ptr.local_timestamp_ns,
                        .last_ping_ns = 0,
                        .ping_count = 0,
                        .pong_received = false,
                        .wallclock = lci.wallclock,
                        .shred_version = lci.shred_version,
                    });
                },
                .ContactInfo => |ci| {
                    try peers.append(Peer{
                        .pubkey = ci.pubkey,
                        .contact_info = ci,
                        .legacy_contact_info = null,
                        .state = .active,
                        .last_seen_ns = entry.value_ptr.local_timestamp_ns,
                        .last_ping_ns = 0,
                        .ping_count = 0,
                        .pong_received = false,
                        .wallclock = ci.wallclock,
                        .shred_version = ci.shred_version,
                    });
                },
                else => {},
            }
        }

        return peers.toOwnedSlice();
    }

    pub fn count(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.count();
    }
};

fn getWallclock(data: *const crds.CrdsData) u64 {
    return switch (data.*) {
        .LegacyContactInfo => |ci| ci.wallclock,
        .ContactInfo => |ci| ci.wallclock,
        .Vote => |v| v.wallclock,
        .NodeInstance => |ni| ni.wallclock,
        .Version => |v| v.wallclock,
        .LegacyVersion => |v| v.wallclock,
        .SnapshotHashes => |sh| sh.wallclock,
        .LegacySnapshotHashes => |sh| sh.wallclock,
        .AccountsHashes => |ah| ah.wallclock,
        .LowestSlot => |ls| ls.wallclock,
        .EpochSlots => |es| es.wallclock,
        .DuplicateShred => |ds| ds.wallclock,
        .RestartLastVotedForkSlots => |r| r.wallclock,
        .RestartHeaviestFork => |r| r.wallclock,
    };
}

/// Cluster info manager
pub const ClusterInfo = struct {
    allocator: Allocator,
    config: ClusterConfig,

    // Our contact info
    my_contact_info: crds.LegacyContactInfo,

    // CRDS table
    crds_table: CrdsTable,

    // Peer management
    peers: std.AutoHashMap([32]u8, Peer),
    peers_mutex: Mutex,

    // Known validators (trusted)
    known_validators: std.AutoHashMap([32]u8, void),

    // Entrypoints
    entrypoints: std.ArrayList(Entrypoint),

    // Gossip socket
    gossip_socket: ?*socket.UdpSocket,

    // State
    running: Atomic(bool),
    crds_ordinal: Atomic(u64),

    // Statistics
    stats: ClusterStats,

    const Self = @This();

    pub fn init(allocator: Allocator, config: ClusterConfig) !*Self {
        const self = try allocator.create(Self);

        const my_contact = crds.LegacyContactInfo{
            .pubkey = config.identity,
            .wallclock = @intCast(std.time.milliTimestamp()),
            .gossip = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.gossip_port,
            },
            .tvu = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tvu_port,
            },
            .tvu_forwards = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tvu_port + 1,
            },
            .repair = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tvu_port + 2,
            },
            .tpu = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tpu_port,
            },
            .tpu_forwards = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tpu_port + 1,
            },
            .tpu_vote = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tpu_port + 2,
            },
            .rpc = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.rpc_port,
            },
            .rpc_pubsub = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.rpc_port + 1,
            },
            .serve_repair = crds.SocketAddr{
                .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } },
                .port = config.tvu_port + 3,
            },
            .shred_version = config.shred_version,
        };

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .my_contact_info = my_contact,
            .crds_table = CrdsTable.init(allocator),
            .peers = std.AutoHashMap([32]u8, Peer).init(allocator),
            .peers_mutex = .{},
            .known_validators = std.AutoHashMap([32]u8, void).init(allocator),
            .entrypoints = std.ArrayList(Entrypoint).init(allocator),
            .gossip_socket = null,
            .running = Atomic(bool).init(false),
            .crds_ordinal = Atomic(u64).init(0),
            .stats = ClusterStats{},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.crds_table.deinit();
        self.peers.deinit();
        self.known_validators.deinit();
        self.entrypoints.deinit();
        self.allocator.destroy(self);
    }

    /// Add an entrypoint
    pub fn addEntrypoint(self: *Self, host: []const u8, port: u16) !void {
        try self.entrypoints.append(Entrypoint{
            .host = try self.allocator.dupe(u8, host),
            .port = port,
            .resolved_addr = null,
            .last_contact_ns = 0,
            .contact_count = 0,
        });
    }

    /// Add known validator
    pub fn addKnownValidator(self: *Self, pubkey: [32]u8) !void {
        try self.known_validators.put(pubkey, {});
    }

    /// Start cluster info service
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .seq_cst)) return;

        // Resolve entrypoints
        for (self.entrypoints.items) |*ep| {
            try self.resolveEntrypoint(ep);
        }

        // Bind gossip socket
        self.gossip_socket = try socket.UdpSocket.bind(self.allocator, "0.0.0.0", self.config.gossip_port);

        self.stats.start_time_ns = std.time.nanoTimestamp();
    }

    /// Stop cluster info service
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .seq_cst)) return;

        if (self.gossip_socket) |sock| {
            sock.close();
            self.gossip_socket = null;
        }
    }

    /// Resolve entrypoint hostname
    fn resolveEntrypoint(self: *Self, ep: *Entrypoint) !void {
        // DNS resolution
        const list = try net.getAddressList(self.allocator, ep.host, ep.port);
        defer list.deinit();

        if (list.addrs.len > 0) {
            ep.resolved_addr = list.addrs[0];
        }
    }

    /// Contact entrypoints to bootstrap gossip
    pub fn contactEntrypoints(self: *Self) !void {
        const gossip_sock = self.gossip_socket orelse return error.NotStarted;

        for (self.entrypoints.items) |*ep| {
            if (ep.resolved_addr) |addr| {
                // Send pull request to entrypoint
                try self.sendPullRequest(gossip_sock, addr);
                ep.last_contact_ns = std.time.nanoTimestamp();
                ep.contact_count += 1;
                self.stats.entrypoint_contacts += 1;
            }
        }
    }

    /// Send a pull request
    fn sendPullRequest(self: *Self, sock: *socket.UdpSocket, addr: net.Address) !void {
        // Build our contact info as a CRDS value
        var sig: [64]u8 = undefined;
        @memset(&sig, 0); // Would be signed

        const my_value = crds.CrdsValue{
            .signature = sig,
            .data = .{ .LegacyContactInfo = self.my_contact_info },
        };

        // Build pull request
        const pull_request = crds.Protocol{
            .PullRequest = .{
                .filter = crds.CrdsFilter{
                    .filter = crds.BloomFilter{
                        .keys = &[_]u64{},
                        .bits = &[_]u64{},
                        .num_bits_set = 0,
                    },
                    .mask = 0,
                    .mask_bits = 0,
                },
                .value = my_value,
            },
        };

        // Serialize
        var buf: [packet.PACKET_DATA_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try pull_request.serialize(fbs.writer());

        // Send
        _ = try sock.sendTo(fbs.getWritten(), addr);
        self.stats.pull_requests_sent += 1;
    }

    /// Process incoming gossip packet
    pub fn processPacket(self: *Self, data: []const u8, from: net.Address) !void {
        var fbs = std.io.fixedBufferStream(data);
        const protocol = crds.Protocol.deserialize(fbs.reader()) catch return;

        switch (protocol) {
            .PullRequest => |pr| try self.handlePullRequest(pr, from),
            .PullResponse => |pr| try self.handlePullResponse(pr),
            .PushMessage => |pm| try self.handlePushMessage(pm),
            .PingMessage => |pm| try self.handlePing(pm, from),
            .PongMessage => |pm| try self.handlePong(pm),
            .PruneMessage => {},
        }

        self.stats.packets_received += 1;
    }

    fn handlePullRequest(self: *Self, request: crds.PullRequest, from: net.Address) !void {
        _ = from;
        // Insert the requester's contact info
        const ordinal = self.crds_ordinal.fetchAdd(1, .seq_cst);
        _ = try self.crds_table.insert(request.value, ordinal);

        self.stats.pull_requests_received += 1;

        // Would send pull response with our known values
    }

    fn handlePullResponse(self: *Self, response: crds.PullResponse) !void {
        // Insert all values from response
        for (response.values) |value| {
            const ordinal = self.crds_ordinal.fetchAdd(1, .seq_cst);
            if (try self.crds_table.insert(value, ordinal)) {
                self.stats.new_values_received += 1;
            }
        }
        self.stats.pull_responses_received += 1;
    }

    fn handlePushMessage(self: *Self, push: crds.PushMessage) !void {
        // Insert pushed values
        for (push.values) |value| {
            const ordinal = self.crds_ordinal.fetchAdd(1, .seq_cst);
            if (try self.crds_table.insert(value, ordinal)) {
                self.stats.new_values_received += 1;
            }
        }
        self.stats.push_messages_received += 1;
    }

    fn handlePing(self: *Self, ping: crds.PingMessage, from: net.Address) !void {
        const sock = self.gossip_socket orelse return;

        // Create pong response
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&ping.token, &hash, .{});

        var sig: [64]u8 = undefined;
        @memset(&sig, 0); // Would sign with identity key

        const pong = crds.Protocol{
            .PongMessage = .{
                .from = self.config.identity,
                .hash = hash,
                .signature = sig,
            },
        };

        var buf: [packet.PACKET_DATA_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try pong.serialize(fbs.writer());

        _ = try sock.sendTo(fbs.getWritten(), from);
        self.stats.pongs_sent += 1;
    }

    fn handlePong(self: *Self, pong: crds.PongMessage) !void {
        // Update peer state
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        if (self.peers.getPtr(pong.from)) |peer| {
            peer.pong_received = true;
            peer.state = .active;
            peer.last_seen_ns = std.time.nanoTimestamp();
        }

        self.stats.pongs_received += 1;
    }

    /// Get active peer count
    pub fn activePeerCount(self: *Self) usize {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        var count: usize = 0;
        const now = std.time.nanoTimestamp();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isHealthy(now)) {
                count += 1;
            }
        }

        return count;
    }

    /// Get all active peers
    pub fn getActivePeers(self: *Self, allocator: Allocator) ![]Peer {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        var result = std.ArrayList(Peer).init(allocator);
        const now = std.time.nanoTimestamp();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isHealthy(now)) {
                try result.append(entry.value_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    /// Get TVU peers for shred reception
    pub fn getTvuPeers(self: *Self, allocator: Allocator) ![]crds.SocketAddr {
        const peers = try self.getActivePeers(allocator);
        defer allocator.free(peers);

        var result = std.ArrayList(crds.SocketAddr).init(allocator);

        for (peers) |peer| {
            if (peer.tvuAddr()) |addr| {
                try result.append(addr);
            }
        }

        return result.toOwnedSlice();
    }

    /// Get TPU peers for transaction forwarding
    pub fn getTpuPeers(self: *Self, allocator: Allocator) ![]crds.SocketAddr {
        const peers = try self.getActivePeers(allocator);
        defer allocator.free(peers);

        var result = std.ArrayList(crds.SocketAddr).init(allocator);

        for (peers) |peer| {
            if (peer.tpuAddr()) |addr| {
                try result.append(addr);
            }
        }

        return result.toOwnedSlice();
    }

    /// Check if cluster is healthy
    pub fn isHealthy(self: *Self) bool {
        return self.activePeerCount() >= self.config.min_peers;
    }

    /// Get cluster statistics
    pub fn getStats(self: *Self) ClusterStats {
        var stats = self.stats;
        stats.active_peers = self.activePeerCount();
        stats.crds_table_size = self.crds_table.count();
        return stats;
    }
};

/// Entrypoint configuration
pub const Entrypoint = struct {
    host: []const u8,
    port: u16,
    resolved_addr: ?net.Address,
    last_contact_ns: i128,
    contact_count: u64,
};

/// Cluster statistics
pub const ClusterStats = struct {
    start_time_ns: i128 = 0,
    active_peers: usize = 0,
    crds_table_size: usize = 0,
    packets_received: u64 = 0,
    packets_sent: u64 = 0,
    pull_requests_sent: u64 = 0,
    pull_requests_received: u64 = 0,
    pull_responses_received: u64 = 0,
    push_messages_received: u64 = 0,
    pings_sent: u64 = 0,
    pongs_sent: u64 = 0,
    pongs_received: u64 = 0,
    new_values_received: u64 = 0,
    entrypoint_contacts: u64 = 0,

    pub fn uptime_sec(self: *const ClusterStats) i64 {
        if (self.start_time_ns == 0) return 0;
        return @intCast(@divTrunc(std.time.nanoTimestamp() - self.start_time_ns, 1_000_000_000));
    }
};

/// Leader schedule cache
pub const LeaderSchedule = struct {
    allocator: Allocator,
    epoch: u64,
    slot_leaders: std.AutoHashMap(u64, [32]u8),

    const Self = @This();

    pub fn init(allocator: Allocator, epoch: u64) Self {
        return Self{
            .allocator = allocator,
            .epoch = epoch,
            .slot_leaders = std.AutoHashMap(u64, [32]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.slot_leaders.deinit();
    }

    /// Get leader for a slot
    pub fn getLeader(self: *const Self, slot: u64) ?[32]u8 {
        return self.slot_leaders.get(slot);
    }

    /// Set leader for a slot
    pub fn setLeader(self: *Self, slot: u64, leader: [32]u8) !void {
        try self.slot_leaders.put(slot, leader);
    }

    /// Check if we are leader for a slot
    pub fn isLeader(self: *const Self, slot: u64, identity: [32]u8) bool {
        if (self.slot_leaders.get(slot)) |leader| {
            return std.mem.eql(u8, &leader, &identity);
        }
        return false;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "cluster info init" {
    const allocator = std.testing.allocator;

    const config = ClusterConfig{
        .identity = [_]u8{1} ** 32,
        .shred_version = 1234,
        .expected_genesis_hash = null,
        .gossip_port = 8001,
        .rpc_port = 8899,
        .tvu_port = 8000,
        .tpu_port = 8003,
    };

    const cluster = try ClusterInfo.init(allocator, config);
    defer cluster.deinit();

    try std.testing.expectEqual(@as(usize, 0), cluster.activePeerCount());
    try std.testing.expect(!cluster.isHealthy());
}

test "crds table insert" {
    const allocator = std.testing.allocator;

    var table = CrdsTable.init(allocator);
    defer table.deinit();

    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0x42);

    const contact = crds.LegacyContactInfo{
        .pubkey = pubkey,
        .wallclock = 1000,
        .gossip = crds.SocketAddr{
            .addr = .{ .v4 = .{ .addr = .{ 127, 0, 0, 1 } } },
            .port = 8001,
        },
        .tvu = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .tvu_forwards = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .repair = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .tpu = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .tpu_forwards = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .tpu_vote = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .rpc = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .rpc_pubsub = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .serve_repair = crds.SocketAddr{ .addr = .{ .v4 = .{ .addr = .{ 0, 0, 0, 0 } } }, .port = 0 },
        .shred_version = 1234,
    };

    var sig: [64]u8 = undefined;
    @memset(&sig, 0);

    const value = crds.CrdsValue{
        .signature = sig,
        .data = .{ .LegacyContactInfo = contact },
    };

    const inserted = try table.insert(value, 1);
    try std.testing.expect(inserted);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // Insert older value (should be rejected)
    var older_contact = contact;
    older_contact.wallclock = 500;
    const older_value = crds.CrdsValue{
        .signature = sig,
        .data = .{ .LegacyContactInfo = older_contact },
    };

    const not_inserted = try table.insert(older_value, 2);
    try std.testing.expect(!not_inserted);
}

test "leader schedule" {
    const allocator = std.testing.allocator;

    var schedule = LeaderSchedule.init(allocator, 100);
    defer schedule.deinit();

    var leader1: [32]u8 = undefined;
    @memset(&leader1, 0x11);

    var leader2: [32]u8 = undefined;
    @memset(&leader2, 0x22);

    try schedule.setLeader(1000, leader1);
    try schedule.setLeader(1001, leader2);

    try std.testing.expect(schedule.isLeader(1000, leader1));
    try std.testing.expect(!schedule.isLeader(1000, leader2));
    try std.testing.expectEqual(leader2, schedule.getLeader(1001).?);
}

