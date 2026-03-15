//! MASQUE Client Implementation
//! Connects to a MASQUE proxy server to tunnel UDP/IP traffic.
//!
//! Usage:
//! ```zig
//! var client = try MasqueClient.init(allocator, .{
//!     .proxy_host = "proxy.example.com",
//!     .proxy_port = 443,
//! });
//! defer client.deinit();
//!
//! // Open UDP tunnel
//! const tunnel = try client.connectUdp("validator.mainnet.solana.com", 8001);
//!
//! // Send/receive datagrams
//! try tunnel.send(datagram);
//! const response = try tunnel.receive();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

/// MASQUE client configuration
pub const ClientConfig = struct {
    /// Proxy server hostname
    proxy_host: []const u8,
    /// Proxy server port (typically 443 for HTTPS)
    proxy_port: u16 = 443,
    /// Authentication token (if required)
    auth_token: ?[]const u8 = null,
    /// Enable certificate verification
    verify_certs: bool = true,
    /// Connection timeout (milliseconds)
    connect_timeout_ms: u32 = 10000,
    /// Idle timeout (milliseconds)
    idle_timeout_ms: u32 = 30000,
    /// Maximum datagram size
    max_datagram_size: u16 = 1350,
    /// Enable HTTP/3 (QUIC) - otherwise falls back to HTTP/2
    use_http3: bool = true,
};

/// MASQUE tunnel state
pub const TunnelState = enum {
    connecting,
    connected,
    draining,
    closed,
    failed,
};

/// Statistics for a tunnel
pub const TunnelStats = struct {
    datagrams_sent: u64 = 0,
    datagrams_received: u64 = 0,
    stream_messages_sent: u64 = 0,
    stream_messages_received: u64 = 0,
    chunks_sent: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    oversized_payloads: u64 = 0,
    created_at: i64 = 0,
    last_activity: i64 = 0,
    rtt_us: u64 = 0,
};

/// UDP tunnel through MASQUE proxy
pub const UdpTunnel = struct {
    allocator: Allocator,
    context_id: u64,
    target_host: []const u8,
    target_port: u16,
    state: TunnelState,
    stats: TunnelStats,

    // Transport configuration
    max_datagram_size: usize = protocol.MAX_DATAGRAM_PAYLOAD,
    transport_mode: protocol.TransportMode = .auto,

    // Internal buffer for datagrams
    recv_buffer: std.ArrayList([]u8),
    send_buffer: std.ArrayList([]u8),

    // Stream buffer for large payloads
    stream_buffer: std.ArrayList([]u8),

    // Chunk reassembler for incoming chunked data
    reassembler: protocol.ChunkReassembler,
    next_payload_id: u64 = 1,

    /// Send a datagram through the tunnel
    /// Automatically handles payloads larger than the datagram limit
    pub fn send(self: *UdpTunnel, data: []const u8) !void {
        if (self.state != .connected) return error.TunnelNotConnected;

        const mode = if (self.transport_mode == .auto)
            protocol.selectTransportMode(data.len, self.max_datagram_size)
        else
            self.transport_mode;

        switch (mode) {
            .datagram => {
                // Small enough for datagram - send directly
                const datagram = protocol.Http3Datagram{
                    .quarter_stream_id = self.context_id,
                    .payload = data,
                };

                const encoded = try datagram.encode(self.allocator);
                defer self.allocator.free(encoded);

                const copy = try self.allocator.dupe(u8, encoded);
                try self.send_buffer.append(copy);

                self.stats.datagrams_sent += 1;
            },
            .stream => {
                // Too large for datagram - send as chunked stream
                try self.sendChunked(data);
                self.stats.stream_messages_sent += 1;
                self.stats.oversized_payloads += 1;
            },
            .auto => unreachable, // Handled above
        }

        self.stats.bytes_sent += data.len;
        self.stats.last_activity = std.time.timestamp();
    }

    /// Send large payload as chunks
    fn sendChunked(self: *UdpTunnel, data: []const u8) !void {
        const payload_id = self.next_payload_id;
        self.next_payload_id += 1;

        const chunk_data_size = self.max_datagram_size - protocol.ChunkedPayload.CHUNK_HEADER_SIZE - 16;
        const total_chunks = protocol.ChunkedPayload.calculateChunkCount(data.len, self.max_datagram_size);

        var offset: usize = 0;
        var chunk_index: u32 = 0;

        while (offset < data.len) : (chunk_index += 1) {
            const end = @min(offset + chunk_data_size, data.len);
            const chunk = protocol.ChunkedPayload{
                .payload_id = payload_id,
                .total_chunks = total_chunks,
                .chunk_index = chunk_index,
                .total_size = data.len,
                .data = data[offset..end],
            };

            const chunk_data = try chunk.encode(self.allocator);
            try self.stream_buffer.append(chunk_data);

            self.stats.chunks_sent += 1;
            offset = end;
        }
    }

    /// Send with explicit size check (returns error if too large and not using stream mode)
    pub fn sendDatagram(self: *UdpTunnel, data: []const u8) !void {
        if (data.len > self.max_datagram_size) {
            return error.PayloadTooLarge;
        }

        const datagram = protocol.Http3Datagram{
            .quarter_stream_id = self.context_id,
            .payload = data,
        };

        const encoded = try datagram.encode(self.allocator);
        defer self.allocator.free(encoded);

        const copy = try self.allocator.dupe(u8, encoded);
        try self.send_buffer.append(copy);

        self.stats.datagrams_sent += 1;
        self.stats.bytes_sent += data.len;
        self.stats.last_activity = std.time.timestamp();
    }

    /// Check if a payload will fit in a single datagram
    pub fn fitsInDatagram(self: *const UdpTunnel, payload_size: usize) bool {
        return payload_size <= self.max_datagram_size;
    }

    /// Receive a datagram from the tunnel (non-blocking)
    pub fn receive(self: *UdpTunnel) ?[]u8 {
        if (self.recv_buffer.items.len == 0) return null;

        const data = self.recv_buffer.orderedRemove(0);
        self.stats.datagrams_received += 1;
        self.stats.bytes_received += data.len;
        self.stats.last_activity = std.time.timestamp();

        return data;
    }

    /// Close the tunnel
    pub fn close(self: *UdpTunnel) void {
        self.state = .draining;
        // Send close context capsule
        // (handled by client)
    }

    pub fn deinit(self: *UdpTunnel) void {
        for (self.recv_buffer.items) |buf| {
            self.allocator.free(buf);
        }
        self.recv_buffer.deinit();

        for (self.send_buffer.items) |buf| {
            self.allocator.free(buf);
        }
        self.send_buffer.deinit();

        for (self.stream_buffer.items) |buf| {
            self.allocator.free(buf);
        }
        self.stream_buffer.deinit();

        self.reassembler.deinit();

        self.allocator.free(self.target_host);
    }

    /// Initialize tunnel (for creating outside of client)
    pub fn initStandalone(allocator: Allocator, context_id: u64, host: []const u8, port: u16) !*UdpTunnel {
        const tunnel = try allocator.create(UdpTunnel);
        tunnel.* = .{
            .allocator = allocator,
            .context_id = context_id,
            .target_host = try allocator.dupe(u8, host),
            .target_port = port,
            .state = .connecting,
            .stats = .{ .created_at = std.time.timestamp() },
            .recv_buffer = std.ArrayList([]u8).init(allocator),
            .send_buffer = std.ArrayList([]u8).init(allocator),
            .stream_buffer = std.ArrayList([]u8).init(allocator),
            .reassembler = protocol.ChunkReassembler.init(allocator),
        };
        return tunnel;
    }
};

/// IP tunnel through MASQUE proxy (CONNECT-IP)
pub const IpTunnel = struct {
    allocator: Allocator,
    assigned_ip: ?protocol.AddressAssign.IpAddress,
    routes: std.ArrayList(protocol.RouteAdvertisement.Route),
    state: TunnelState,
    stats: TunnelStats,

    /// Send an IP packet through the tunnel
    pub fn sendPacket(self: *IpTunnel, packet: []const u8) !void {
        if (self.state != .connected) return error.TunnelNotConnected;
        _ = packet;
        // Encapsulate IP packet in capsule and send
    }

    /// Receive an IP packet from the tunnel
    pub fn receivePacket(self: *IpTunnel) ?[]u8 {
        _ = self;
        return null;
    }

    pub fn deinit(self: *IpTunnel) void {
        self.routes.deinit();
    }
};

/// MASQUE client
pub const MasqueClient = struct {
    allocator: Allocator,
    config: ClientConfig,
    state: ClientState,

    // Connection state
    stream: ?std.net.Stream,
    udp_tunnels: std.AutoHashMap(u64, *UdpTunnel),
    ip_tunnel: ?*IpTunnel,
    next_context_id: u64,

    // Statistics
    stats: ClientStats,

    pub const ClientState = enum {
        disconnected,
        connecting,
        connected,
        draining,
        failed,
    };

    pub const ClientStats = struct {
        connect_attempts: u64 = 0,
        successful_connects: u64 = 0,
        total_tunnels_created: u64 = 0,
        active_tunnels: u64 = 0,
        bytes_sent: u64 = 0,
        bytes_received: u64 = 0,
    };

    /// Initialize MASQUE client
    pub fn init(allocator: Allocator, config: ClientConfig) !*MasqueClient {
        const client = try allocator.create(MasqueClient);
        client.* = .{
            .allocator = allocator,
            .config = config,
            .state = .disconnected,
            .stream = null,
            .udp_tunnels = std.AutoHashMap(u64, *UdpTunnel).init(allocator),
            .ip_tunnel = null,
            .next_context_id = 1,
            .stats = .{},
        };
        return client;
    }

    pub fn deinit(self: *MasqueClient) void {
        self.disconnect();

        var tunnel_iter = self.udp_tunnels.valueIterator();
        while (tunnel_iter.next()) |tunnel_ptr| {
            tunnel_ptr.*.deinit();
            self.allocator.destroy(tunnel_ptr.*);
        }
        self.udp_tunnels.deinit();

        if (self.ip_tunnel) |tunnel| {
            tunnel.deinit();
            self.allocator.destroy(tunnel);
        }

        self.allocator.destroy(self);
    }

    /// Connect to the MASQUE proxy server
    pub fn connect(self: *MasqueClient) !void {
        if (self.state == .connected) return;

        self.state = .connecting;
        self.stats.connect_attempts += 1;

        // Resolve proxy address
        const addr = try std.net.Address.resolveIp(self.config.proxy_host, self.config.proxy_port);

        // Connect TCP (for HTTP/2) or start QUIC (for HTTP/3)
        self.stream = try std.net.tcpConnectToAddress(addr);

        if (self.config.use_http3) {
            // Would perform QUIC handshake here
            // For now, using TCP with ALPN for HTTP/2
            try self.performHttp2Handshake();
        }

        self.state = .connected;
        self.stats.successful_connects += 1;

        std.log.info("[MASQUE] Connected to proxy {s}:{d}", .{ self.config.proxy_host, self.config.proxy_port });
    }

    /// Disconnect from proxy
    pub fn disconnect(self: *MasqueClient) void {
        if (self.stream) |*stream| {
            stream.close();
            self.stream = null;
        }
        self.state = .disconnected;
    }

    /// Open a CONNECT-UDP tunnel
    pub fn connectUdp(self: *MasqueClient, target_host: []const u8, target_port: u16) !*UdpTunnel {
        if (self.state != .connected) {
            try self.connect();
        }

        const context_id = self.next_context_id;
        self.next_context_id += 1;

        // Create tunnel
        const tunnel = try self.allocator.create(UdpTunnel);
        tunnel.* = .{
            .allocator = self.allocator,
            .context_id = context_id,
            .target_host = try self.allocator.dupe(u8, target_host),
            .target_port = target_port,
            .state = .connecting,
            .stats = .{ .created_at = std.time.timestamp() },
            .recv_buffer = std.ArrayList([]u8).init(self.allocator),
            .send_buffer = std.ArrayList([]u8).init(self.allocator),
            .stream_buffer = std.ArrayList([]u8).init(self.allocator),
            .reassembler = protocol.ChunkReassembler.init(self.allocator),
        };

        // Send CONNECT-UDP request
        try self.sendConnectUdpRequest(tunnel);

        // Store tunnel
        try self.udp_tunnels.put(context_id, tunnel);
        self.stats.total_tunnels_created += 1;
        self.stats.active_tunnels += 1;

        tunnel.state = .connected;

        std.log.info("[MASQUE] UDP tunnel opened: {s}:{d} (context={d})", .{
            target_host,
            target_port,
            context_id,
        });

        return tunnel;
    }

    /// Open a CONNECT-IP tunnel
    pub fn connectIp(self: *MasqueClient, target_host: ?[]const u8) !*IpTunnel {
        if (self.state != .connected) {
            try self.connect();
        }

        if (self.ip_tunnel != null) {
            return error.IpTunnelAlreadyOpen;
        }

        const tunnel = try self.allocator.create(IpTunnel);
        tunnel.* = .{
            .allocator = self.allocator,
            .assigned_ip = null,
            .routes = std.ArrayList(protocol.RouteAdvertisement.Route).init(self.allocator),
            .state = .connecting,
            .stats = .{ .created_at = std.time.timestamp() },
        };

        // Send CONNECT-IP request
        try self.sendConnectIpRequest(target_host);

        self.ip_tunnel = tunnel;
        tunnel.state = .connected;

        std.log.info("[MASQUE] IP tunnel opened", .{});

        return tunnel;
    }

    /// Close a UDP tunnel
    pub fn closeTunnel(self: *MasqueClient, context_id: u64) void {
        if (self.udp_tunnels.fetchRemove(context_id)) |entry| {
            const tunnel = entry.value;
            tunnel.state = .closed;
            tunnel.deinit();
            self.allocator.destroy(tunnel);
            self.stats.active_tunnels -= 1;

            std.log.info("[MASQUE] UDP tunnel closed (context={d})", .{context_id});
        }
    }

    /// Process incoming data from proxy
    pub fn processIncoming(self: *MasqueClient) !void {
        if (self.stream == null) return;

        var buffer: [4096]u8 = undefined;
        const bytes_read = self.stream.?.read(&buffer) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (bytes_read == 0) {
            // Connection closed
            self.state = .disconnected;
            return;
        }

        // Process HTTP/3 datagrams
        try self.processDatagrams(buffer[0..bytes_read]);
    }

    /// Flush pending sends
    pub fn flush(self: *MasqueClient) !void {
        if (self.stream == null) return;

        var tunnel_iter = self.udp_tunnels.valueIterator();
        while (tunnel_iter.next()) |tunnel_ptr| {
            const tunnel = tunnel_ptr.*;
            while (tunnel.send_buffer.items.len > 0) {
                const data = tunnel.send_buffer.orderedRemove(0);
                defer self.allocator.free(data);

                _ = try self.stream.?.write(data);
                self.stats.bytes_sent += data.len;
            }
        }
    }

    // ========================================================================
    // Internal methods
    // ========================================================================

    fn performHttp2Handshake(self: *MasqueClient) !void {
        // HTTP/2 connection preface
        const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        if (self.stream) |stream| {
            _ = try stream.write(preface);
            // Would exchange SETTINGS frames here
        }
    }

    fn sendConnectUdpRequest(self: *MasqueClient, tunnel: *UdpTunnel) !void {
        // Build CONNECT-UDP request
        // :method = CONNECT
        // :protocol = connect-udp
        // :authority = proxy:port
        // :path = /.well-known/masque/udp/{host}/{port}/

        const target = protocol.ConnectUdpTarget{
            .host = tunnel.target_host,
            .port = tunnel.target_port,
        };

        const path = try target.toPath(self.allocator);
        defer self.allocator.free(path);

        // In a real implementation, this would be proper HTTP/3 CONNECT request
        // For now, we're simulating the protocol structure
        const request = try std.fmt.allocPrint(self.allocator,
            \\CONNECT {s} HTTP/2.0
            \\:authority: {s}:{d}
            \\:protocol: connect-udp
            \\
            \\
        , .{ path, self.config.proxy_host, self.config.proxy_port });
        defer self.allocator.free(request);

        if (self.stream) |stream| {
            _ = try stream.write(request);
        }
    }

    fn sendConnectIpRequest(self: *MasqueClient, target_host: ?[]const u8) !void {
        const target = protocol.ConnectIpTarget{ .host = target_host };
        const path = try target.toPath(self.allocator);
        defer self.allocator.free(path);

        const request = try std.fmt.allocPrint(self.allocator,
            \\CONNECT {s} HTTP/2.0
            \\:authority: {s}:{d}
            \\:protocol: connect-ip
            \\
            \\
        , .{ path, self.config.proxy_host, self.config.proxy_port });
        defer self.allocator.free(request);

        if (self.stream) |stream| {
            _ = try stream.write(request);
        }
    }

    fn processDatagrams(self: *MasqueClient, data: []const u8) !void {
        // Parse HTTP/3 datagrams and route to tunnels
        const datagram = try protocol.Http3Datagram.decode(self.allocator, data);
        defer self.allocator.free(datagram.payload);

        const context_id = datagram.quarter_stream_id;

        if (self.udp_tunnels.get(context_id)) |tunnel| {
            const payload_copy = try self.allocator.dupe(u8, datagram.payload);
            try tunnel.recv_buffer.append(payload_copy);
            self.stats.bytes_received += datagram.payload.len;
        }
    }

    /// Get client statistics
    pub fn getStats(self: *const MasqueClient) ClientStats {
        return self.stats;
    }

    /// Check if connected
    pub fn isConnected(self: *const MasqueClient) bool {
        return self.state == .connected;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MasqueClient: initialization" {
    const allocator = std.testing.allocator;

    const client = try MasqueClient.init(allocator, .{
        .proxy_host = "proxy.example.com",
        .proxy_port = 443,
    });
    defer client.deinit();

    try std.testing.expectEqual(MasqueClient.ClientState.disconnected, client.state);
}

test "UdpTunnel: create and stats" {
    const allocator = std.testing.allocator;

    var tunnel = UdpTunnel{
        .allocator = allocator,
        .context_id = 42,
        .target_host = try allocator.dupe(u8, "test.com"),
        .target_port = 8001,
        .state = .connected,
        .stats = .{},
        .recv_buffer = std.ArrayList([]u8).init(allocator),
        .send_buffer = std.ArrayList([]u8).init(allocator),
    };
    defer tunnel.deinit();

    try tunnel.send("test data");

    try std.testing.expectEqual(@as(u64, 1), tunnel.stats.datagrams_sent);
    try std.testing.expectEqual(@as(u64, 9), tunnel.stats.bytes_sent);
}

