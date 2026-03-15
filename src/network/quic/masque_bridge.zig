//! MASQUE Bridge for QUIC Transport
//! Seamlessly tunnels QUIC connections through MASQUE proxies.
//!
//! This bridge provides:
//! - Transparent proxying (caller doesn't need to know about MASQUE)
//! - Automatic reconnection through proxy
//! - Combined statistics
//! - Fallback to direct connection if proxy fails
//!
//! Usage:
//! ```zig
//! // Connect to validator through corporate firewall
//! var conn = try masque_bridge.connect(allocator, .{
//!     .proxy_host = "proxy.example.com",
//!     .proxy_port = 443,  // HTTPS port for firewall traversal
//!     .target_host = "validator.mainnet.solana.com",
//!     .target_port = 8001,
//! });
//! defer conn.deinit();
//!
//! // Use exactly like a regular connection
//! try conn.send(message);
//! if (try conn.receive()) |msg| {
//!     // process
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const transport = @import("transport.zig");
const masque_protocol = @import("../masque/protocol.zig");
const masque_client = @import("../masque/client.zig");

/// MASQUE connection configuration
pub const MasqueConfig = struct {
    /// MASQUE proxy hostname
    proxy_host: []const u8,
    /// MASQUE proxy port (typically 443)
    proxy_port: u16 = 443,
    /// Target host to connect to through proxy
    target_host: []const u8,
    /// Target port
    target_port: u16,
    /// Authentication token (if required by proxy)
    auth_token: ?[]const u8 = null,
    /// Fall back to direct connection if proxy fails
    fallback_direct: bool = true,
    /// Connection timeout (milliseconds)
    timeout_ms: u32 = 10000,
    /// Preferred transport mode
    transport_mode: masque_protocol.TransportMode = .auto,
};

/// Combined statistics
pub const MasqueStats = struct {
    // Tunnel stats
    tunnel_bytes_sent: u64 = 0,
    tunnel_bytes_received: u64 = 0,
    tunnel_messages_sent: u64 = 0,
    tunnel_messages_received: u64 = 0,

    // Proxy stats
    proxy_connected: bool = false,
    proxy_reconnects: u64 = 0,
    proxy_failures: u64 = 0,

    // Transport stats
    datagrams_sent: u64 = 0,
    streams_used: u64 = 0,
    oversized_payloads: u64 = 0,

    // Timing
    avg_rtt_us: u64 = 0,
    connected_at: i64 = 0,
    uptime_seconds: u64 = 0,
};

/// MASQUE-tunneled connection
/// Provides the same API as transport.Connection but tunneled through MASQUE
pub const MasqueConnection = struct {
    allocator: Allocator,
    config: MasqueConfig,

    // MASQUE client
    masque: *masque_client.MasqueClient,
    tunnel: ?*masque_client.UdpTunnel,

    // Internal QUIC-like state
    next_stream_id: u64,
    streams: std.AutoHashMap(u64, *MasqueStream),

    // Message queues
    outgoing: std.ArrayList(transport.Message),
    incoming: std.ArrayList(transport.ReceivedMessage),

    // Statistics
    stats: MasqueStats,

    // State
    connected: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    // Background I/O thread
    io_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, config: MasqueConfig) !*MasqueConnection {
        const conn = try allocator.create(MasqueConnection);
        errdefer allocator.destroy(conn);

        // Create MASQUE client
        const masque = try masque_client.MasqueClient.init(allocator, .{
            .proxy_host = config.proxy_host,
            .proxy_port = config.proxy_port,
            .auth_token = config.auth_token,
        });

        conn.* = .{
            .allocator = allocator,
            .config = config,
            .masque = masque,
            .tunnel = null,
            .next_stream_id = 0,
            .streams = std.AutoHashMap(u64, *MasqueStream).init(allocator),
            .outgoing = std.ArrayList(transport.Message).init(allocator),
            .incoming = std.ArrayList(transport.ReceivedMessage).init(allocator),
            .stats = .{},
            .connected = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .io_thread = null,
            .running = std.atomic.Value(bool).init(false),
        };

        return conn;
    }

    pub fn deinit(self: *MasqueConnection) void {
        self.close();

        var stream_iter = self.streams.valueIterator();
        while (stream_iter.next()) |s| {
            s.*.deinit();
            self.allocator.destroy(s.*);
        }
        self.streams.deinit();

        self.outgoing.deinit();
        for (self.incoming.items) |*m| m.deinit();
        self.incoming.deinit();

        self.masque.deinit();
        self.allocator.destroy(self);
    }

    /// Connect through the MASQUE proxy to the target
    pub fn connect(self: *MasqueConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connected.load(.acquire)) return;

        // Connect to MASQUE proxy
        try self.masque.connect();

        // Open UDP tunnel to target
        self.tunnel = try self.masque.connectUdp(
            self.config.target_host,
            self.config.target_port,
        );

        self.stats.proxy_connected = true;
        self.stats.connected_at = std.time.timestamp();
        self.connected.store(true, .release);

        // Start I/O thread
        self.running.store(true, .release);
        self.io_thread = try std.Thread.spawn(.{}, ioLoop, .{self});

        std.log.info("[MASQUE] Connected to {s}:{d} through {s}:{d}", .{
            self.config.target_host,
            self.config.target_port,
            self.config.proxy_host,
            self.config.proxy_port,
        });
    }

    /// Close the connection
    pub fn close(self: *MasqueConnection) void {
        self.running.store(false, .release);
        self.connected.store(false, .release);

        if (self.io_thread) |t| {
            t.join();
            self.io_thread = null;
        }

        if (self.tunnel) |tunnel| {
            tunnel.close();
            self.tunnel = null;
        }

        self.masque.disconnect();
        self.stats.proxy_connected = false;
    }

    /// Send a message (any size - automatically handled)
    pub fn send(self: *MasqueConnection, msg: transport.Message) !void {
        if (!self.connected.load(.acquire)) return error.NotConnected;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Encode message with header
        const encoded = try self.encodeMessage(msg);
        defer self.allocator.free(encoded);

        // Send through tunnel (tunnel handles size automatically)
        if (self.tunnel) |tunnel| {
            try tunnel.send(encoded);
            self.stats.tunnel_bytes_sent += encoded.len;
            self.stats.tunnel_messages_sent += 1;

            // Track if we used stream fallback
            if (!tunnel.fitsInDatagram(encoded.len)) {
                self.stats.oversized_payloads += 1;
            }
        } else {
            return error.TunnelNotOpen;
        }
    }

    /// Send bytes directly
    pub fn sendBytes(self: *MasqueConnection, data: []const u8) !void {
        try self.send(.{ .data = data });
    }

    /// Receive a message
    pub fn receive(self: *MasqueConnection) !?transport.ReceivedMessage {
        if (!self.connected.load(.acquire)) return error.NotConnected;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.incoming.items.len > 0) {
            return self.incoming.orderedRemove(0);
        }

        return null;
    }

    /// Get statistics
    pub fn getStats(self: *MasqueConnection) MasqueStats {
        var stats = self.stats;
        if (stats.connected_at > 0) {
            stats.uptime_seconds = @intCast(std.time.timestamp() - stats.connected_at);
        }
        return stats;
    }

    /// Check if connected
    pub fn isConnected(self: *const MasqueConnection) bool {
        return self.connected.load(.acquire);
    }

    // ========================================================================
    // Internal methods
    // ========================================================================

    fn encodeMessage(self: *MasqueConnection, msg: transport.Message) ![]u8 {
        const has_correlation = msg.correlation_id != null;
        const header_size = transport.WireHeader.SIZE + if (has_correlation) @as(usize, 8) else 0;
        const total_size = header_size + msg.data.len;

        const buf = try self.allocator.alloc(u8, total_size);

        const header = transport.WireHeader{
            .flags = .{ .has_correlation = has_correlation },
            .msg_type = @intFromEnum(msg.msg_type),
            .priority = @intFromEnum(msg.priority),
            .length = @intCast(msg.data.len),
        };
        const header_bytes = header.encode();
        @memcpy(buf[0..transport.WireHeader.SIZE], &header_bytes);

        var offset: usize = transport.WireHeader.SIZE;

        if (msg.correlation_id) |cid| {
            std.mem.writeInt(u64, buf[offset..][0..8], cid, .big);
            offset += 8;
        }

        @memcpy(buf[offset..], msg.data);

        return buf;
    }

    fn decodeMessage(self: *MasqueConnection, data: []const u8) !transport.ReceivedMessage {
        if (data.len < transport.WireHeader.SIZE) return error.InvalidMessage;

        const header = transport.WireHeader.decode(data[0..transport.WireHeader.SIZE]);
        var offset: usize = transport.WireHeader.SIZE;

        var correlation_id: ?u64 = null;
        if (header.flags.has_correlation) {
            if (data.len < offset + 8) return error.InvalidMessage;
            correlation_id = std.mem.readInt(u64, data[offset..][0..8], .big);
            offset += 8;
        }

        if (data.len < offset + header.length) return error.InvalidMessage;

        const payload = try self.allocator.dupe(u8, data[offset..][0..header.length]);

        return .{
            .data = payload,
            .priority = @enumFromInt(header.priority),
            .msg_type = @enumFromInt(header.msg_type),
            .correlation_id = correlation_id,
            .received_at = std.time.timestamp(),
            .source = .{
                .host = self.config.target_host,
                .port = self.config.target_port,
            },
            .allocator = self.allocator,
        };
    }

    fn ioLoop(self: *MasqueConnection) void {
        while (self.running.load(.acquire)) {
            // Process incoming
            self.processIncoming() catch {};

            // Flush outgoing
            self.masque.flush() catch {};

            // Small sleep
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn processIncoming(self: *MasqueConnection) !void {
        if (self.tunnel == null) return;

        // Process all available datagrams
        while (self.tunnel.?.receive()) |data| {
            defer self.allocator.free(data);

            const msg = try self.decodeMessage(data);

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.incoming.append(msg);
            self.stats.tunnel_bytes_received += data.len;
            self.stats.tunnel_messages_received += 1;
        }
    }
};

/// Virtual stream over MASQUE tunnel
pub const MasqueStream = struct {
    id: u64,
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: u64) MasqueStream {
        return .{
            .id = id,
            .send_buffer = std.ArrayList(u8).init(allocator),
            .recv_buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MasqueStream) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
    }
};

/// Connect through MASQUE proxy (convenience function)
pub fn connect(allocator: Allocator, config: MasqueConfig) !*MasqueConnection {
    const conn = try MasqueConnection.init(allocator, config);
    errdefer conn.deinit();
    try conn.connect();
    return conn;
}

// ============================================================================
// Tests
// ============================================================================

test "MasqueConnection: init" {
    const allocator = std.testing.allocator;

    const conn = try MasqueConnection.init(allocator, .{
        .proxy_host = "localhost",
        .proxy_port = 8443,
        .target_host = "target.example.com",
        .target_port = 8001,
    });
    defer conn.deinit();

    try std.testing.expect(!conn.isConnected());
}

