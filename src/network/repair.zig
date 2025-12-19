//! Vexor Shred Repair Protocol
//!
//! Requests and serves missing shreds to maintain data availability.
//!
//! Request types:
//! - WindowIndex: Request shred at (slot, index)
//! - HighestWindowIndex: Request highest shred index for slot
//! - Orphan: Request parent shred for orphaned slot
//! - AncestorHashes: Request hash chain for fork verification

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

const packet = @import("packet.zig");
const socket = @import("socket.zig");

/// Repair request types
pub const RepairType = enum(u8) {
    /// Request shred at specific slot and index
    WindowIndex = 0,
    /// Request highest shred index for slot
    HighestWindowIndex = 1,
    /// Request parent slot's shred (for orphans)
    Orphan = 2,
    /// Request ancestor hashes
    AncestorHashes = 3,
};

/// Repair request
pub const RepairRequest = struct {
    /// Type of repair
    repair_type: RepairType,
    /// Slot to repair
    slot: u64,
    /// Shred index (for WindowIndex)
    shred_index: u64,
    /// Nonce for request/response matching
    nonce: u32,
    /// Requester identity
    from: [32]u8,

    const Self = @This();

    pub const SERIALIZED_SIZE: usize = 1 + 8 + 8 + 4 + 32;

    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.repair_type));
        try writer.writeInt(u64, self.slot, .little);
        try writer.writeInt(u64, self.shred_index, .little);
        try writer.writeInt(u32, self.nonce, .little);
        try writer.writeAll(&self.from);
    }

    pub fn deserialize(reader: anytype) !Self {
        return Self{
            .repair_type = std.meta.intToEnum(RepairType, try reader.readByte()) catch return error.InvalidRepairType,
            .slot = try reader.readInt(u64, .little),
            .shred_index = try reader.readInt(u64, .little),
            .nonce = try reader.readInt(u32, .little),
            .from = blk: {
                var buf: [32]u8 = undefined;
                _ = try reader.readAll(&buf);
                break :blk buf;
            },
        };
    }
};

/// Repair response
pub const RepairResponse = struct {
    /// Nonce matching the request
    nonce: u32,
    /// Shred data (if found)
    shred_data: ?[]const u8,

    const Self = @This();

    pub fn serialize(self: *const Self, writer: anytype) !void {
        try writer.writeInt(u32, self.nonce, .little);
        if (self.shred_data) |data| {
            try writer.writeByte(1);
            try writer.writeInt(u32, @intCast(data.len), .little);
            try writer.writeAll(data);
        } else {
            try writer.writeByte(0);
        }
    }
};

/// Outstanding repair request tracker
pub const OutstandingRepair = struct {
    request: RepairRequest,
    sent_at_ns: i128,
    retries: u8,
    destination: net.Address,
};

/// Repair service configuration
pub const RepairConfig = struct {
    /// Maximum outstanding repair requests
    max_outstanding: usize = 1000,
    /// Request timeout (ms)
    timeout_ms: u64 = 5000,
    /// Maximum retries per request
    max_retries: u8 = 3,
    /// Repair socket port offset from TPU
    port_offset: u16 = 2,
};

/// Repair service
pub const RepairService = struct {
    allocator: Allocator,
    config: RepairConfig,

    /// Our identity
    identity: [32]u8,

    /// Repair socket
    repair_socket: ?*socket.UdpSocket,

    /// Outstanding requests
    outstanding: std.AutoHashMap(u32, OutstandingRepair),
    outstanding_mutex: Mutex,

    /// Nonce generator
    next_nonce: Atomic(u32),

    /// Statistics
    stats: RepairStats,

    /// Running state
    running: Atomic(bool),

    const Self = @This();

    pub fn init(allocator: Allocator, identity: [32]u8, config: RepairConfig) !*Self {
        const service = try allocator.create(Self);
        service.* = Self{
            .allocator = allocator,
            .config = config,
            .identity = identity,
            .repair_socket = null,
            .outstanding = std.AutoHashMap(u32, OutstandingRepair).init(allocator),
            .outstanding_mutex = .{},
            .next_nonce = Atomic(u32).init(1),
            .stats = .{},
            .running = Atomic(bool).init(false),
        };
        return service;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.outstanding.deinit();
        self.allocator.destroy(self);
    }

    /// Start repair service
    pub fn start(self: *Self, bind_port: u16) !void {
        if (self.running.swap(true, .seq_cst)) return;

        self.repair_socket = try socket.UdpSocket.bind(
            self.allocator,
            "0.0.0.0",
            bind_port + self.config.port_offset,
        );
    }

    /// Stop repair service
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .seq_cst)) return;

        if (self.repair_socket) |sock| {
            sock.close();
            self.repair_socket = null;
        }
    }

    /// Request a specific shred
    pub fn requestShred(self: *Self, slot: u64, shred_index: u64, destination: net.Address) !void {
        const nonce = self.next_nonce.fetchAdd(1, .seq_cst);

        const request = RepairRequest{
            .repair_type = .WindowIndex,
            .slot = slot,
            .shred_index = shred_index,
            .nonce = nonce,
            .from = self.identity,
        };

        try self.sendRequest(request, destination);

        // Track outstanding request
        self.outstanding_mutex.lock();
        defer self.outstanding_mutex.unlock();

        try self.outstanding.put(nonce, OutstandingRepair{
            .request = request,
            .sent_at_ns = std.time.nanoTimestamp(),
            .retries = 0,
            .destination = destination,
        });

        self.stats.requests_sent += 1;
    }

    /// Request highest shred for slot
    pub fn requestHighestShred(self: *Self, slot: u64, destination: net.Address) !void {
        const nonce = self.next_nonce.fetchAdd(1, .seq_cst);

        const request = RepairRequest{
            .repair_type = .HighestWindowIndex,
            .slot = slot,
            .shred_index = 0,
            .nonce = nonce,
            .from = self.identity,
        };

        try self.sendRequest(request, destination);
        self.stats.requests_sent += 1;
    }

    /// Request orphan repair (parent slot)
    pub fn requestOrphan(self: *Self, slot: u64, destination: net.Address) !void {
        const nonce = self.next_nonce.fetchAdd(1, .seq_cst);

        const request = RepairRequest{
            .repair_type = .Orphan,
            .slot = slot,
            .shred_index = 0,
            .nonce = nonce,
            .from = self.identity,
        };

        try self.sendRequest(request, destination);
        self.stats.orphan_requests += 1;
    }

    fn sendRequest(self: *Self, request: RepairRequest, destination: net.Address) !void {
        const sock = self.repair_socket orelse return error.NotStarted;

        var buf: [packet.PACKET_DATA_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try request.serialize(fbs.writer());

        _ = try sock.sendTo(fbs.getWritten(), destination);
    }

    /// Process incoming repair packets
    pub fn processPacket(self: *Self, data: []const u8, from: net.Address) !void {
        if (data.len < 1) return;

        // Check if response or request
        // Responses start with nonce (u32), requests start with type (u8)
        if (data.len >= RepairRequest.SERIALIZED_SIZE) {
            // Try to parse as request
            var fbs = std.io.fixedBufferStream(data);
            if (RepairRequest.deserialize(fbs.reader())) |request| {
                try self.handleRequest(request, from);
                return;
            } else |_| {}
        }

        // Try to parse as response
        if (data.len >= 5) {
            const nonce = std.mem.readInt(u32, data[0..4], .little);
            try self.handleResponse(nonce, data[4..]);
        }
    }

    fn handleRequest(self: *Self, request: RepairRequest, from: net.Address) !void {
        self.stats.requests_received += 1;

        // Would look up shred in blockstore and send response
        _ = from;
        _ = request;
    }

    fn handleResponse(self: *Self, nonce: u32, data: []const u8) !void {
        self.outstanding_mutex.lock();
        defer self.outstanding_mutex.unlock();

        if (self.outstanding.fetchRemove(nonce)) |_| {
            self.stats.responses_received += 1;

            // Process shred data
            if (data.len > 1 and data[0] == 1) {
                self.stats.shreds_received += 1;
                // Would insert shred into blockstore
            }
        }
    }

    /// Retry timed-out requests
    pub fn retryTimeouts(self: *Self) !void {
        const now = std.time.nanoTimestamp();
        const timeout_ns: i128 = @as(i128, self.config.timeout_ms) * 1_000_000;

        self.outstanding_mutex.lock();
        defer self.outstanding_mutex.unlock();

        var to_retry = std.ArrayList(u32).init(self.allocator);
        defer to_retry.deinit();

        var iter = self.outstanding.iterator();
        while (iter.next()) |kv| {
            if (now - kv.value_ptr.sent_at_ns > timeout_ns) {
                try to_retry.append(kv.key_ptr.*);
            }
        }

        for (to_retry.items) |nonce| {
            if (self.outstanding.getPtr(nonce)) |repair| {
                if (repair.retries >= self.config.max_retries) {
                    _ = self.outstanding.remove(nonce);
                    self.stats.timeouts += 1;
                } else {
                    repair.retries += 1;
                    repair.sent_at_ns = now;
                    try self.sendRequest(repair.request, repair.destination);
                    self.stats.retries += 1;
                }
            }
        }
    }

    /// Get repair statistics
    pub fn getStats(self: *const Self) RepairStats {
        return self.stats;
    }
};

/// Repair statistics
pub const RepairStats = struct {
    requests_sent: u64 = 0,
    requests_received: u64 = 0,
    responses_received: u64 = 0,
    shreds_received: u64 = 0,
    orphan_requests: u64 = 0,
    timeouts: u64 = 0,
    retries: u64 = 0,
};

/// Repair peer selector
pub const RepairPeerSelector = struct {
    allocator: Allocator,
    peers: std.ArrayList(RepairPeer),
    rng: std.rand.DefaultPrng,

    const Self = @This();

    pub const RepairPeer = struct {
        pubkey: [32]u8,
        repair_addr: net.Address,
        stake: u64,
        successful_repairs: u64,
        failed_repairs: u64,
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .peers = std.ArrayList(RepairPeer).init(allocator),
            .rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp())),
        };
    }

    pub fn deinit(self: *Self) void {
        self.peers.deinit();
    }

    pub fn addPeer(self: *Self, peer: RepairPeer) !void {
        try self.peers.append(peer);
    }

    /// Select peer for repair (weighted by stake and success rate)
    pub fn selectPeer(self: *Self) ?*RepairPeer {
        if (self.peers.items.len == 0) return null;

        // Simple random selection for now
        // Could be weighted by stake + success rate
        const idx = self.rng.random().uintLessThan(usize, self.peers.items.len);
        return &self.peers.items[idx];
    }

    /// Mark repair success
    pub fn recordSuccess(self: *Self, pubkey: [32]u8) void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, &peer.pubkey, &pubkey)) {
                peer.successful_repairs += 1;
                return;
            }
        }
    }

    /// Mark repair failure
    pub fn recordFailure(self: *Self, pubkey: [32]u8) void {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, &peer.pubkey, &pubkey)) {
                peer.failed_repairs += 1;
                return;
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "repair request serialization" {
    const request = RepairRequest{
        .repair_type = .WindowIndex,
        .slot = 12345,
        .shred_index = 42,
        .nonce = 999,
        .from = [_]u8{0x11} ** 32,
    };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try request.serialize(fbs.writer());

    fbs.pos = 0;
    const restored = try RepairRequest.deserialize(fbs.reader());

    try std.testing.expectEqual(request.repair_type, restored.repair_type);
    try std.testing.expectEqual(request.slot, restored.slot);
    try std.testing.expectEqual(request.shred_index, restored.shred_index);
    try std.testing.expectEqual(request.nonce, restored.nonce);
}

test "repair service init" {
    const allocator = std.testing.allocator;

    var identity: [32]u8 = undefined;
    @memset(&identity, 0x11);

    const service = try RepairService.init(allocator, identity, .{});
    defer service.deinit();

    try std.testing.expectEqual(@as(u64, 0), service.stats.requests_sent);
}

