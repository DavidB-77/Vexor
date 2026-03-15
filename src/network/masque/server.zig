//! MASQUE Server Implementation
//! Provides MASQUE proxy services for UDP and IP tunneling.
//!
//! Can be used to:
//! - Allow dashboard connections through firewalls
//! - Provide secure relay for validator metrics
//! - Enable validator-to-validator communication through NAT
//!
//! Usage:
//! ```zig
//! var server = try MasqueServer.init(allocator, .{
//!     .bind_address = "0.0.0.0",
//!     .bind_port = 443,
//! });
//! try server.start();
//! defer server.stop();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

/// MASQUE server configuration
pub const ServerConfig = struct {
    /// Address to bind to
    bind_address: []const u8 = "0.0.0.0",
    /// Port to bind to
    bind_port: u16 = 443,
    /// Maximum concurrent clients
    max_clients: u32 = 1000,
    /// Maximum tunnels per client
    max_tunnels_per_client: u32 = 100,
    /// Enable authentication
    require_auth: bool = false,
    /// Valid auth tokens (if auth required)
    auth_tokens: ?[]const []const u8 = null,
    /// Allowed target patterns (for security)
    allowed_targets: ?[]const TargetPattern = null,
    /// Maximum datagram size
    max_datagram_size: u16 = 1350,
    /// Idle timeout (seconds)
    idle_timeout_s: u32 = 300,
    /// Enable CONNECT-IP (requires elevated privileges)
    enable_connect_ip: bool = false,
    /// TLS certificate path
    tls_cert_path: ?[]const u8 = null,
    /// TLS key path
    tls_key_path: ?[]const u8 = null,
};

/// Target pattern for access control
pub const TargetPattern = struct {
    host_pattern: []const u8, // "*" for wildcard, or specific host/IP
    port_min: u16 = 0,
    port_max: u16 = 65535,
    allow: bool = true,

    pub fn matches(self: *const TargetPattern, host: []const u8, port: u16) bool {
        // Check port range
        if (port < self.port_min or port > self.port_max) return false;

        // Check host pattern
        if (std.mem.eql(u8, self.host_pattern, "*")) return true;
        if (std.mem.eql(u8, self.host_pattern, host)) return true;

        // Wildcard suffix match (e.g., *.solana.com)
        if (std.mem.startsWith(u8, self.host_pattern, "*.")) {
            const suffix = self.host_pattern[1..]; // .solana.com
            if (std.mem.endsWith(u8, host, suffix)) return true;
        }

        return false;
    }
};

/// Connected client state
pub const ClientConnection = struct {
    allocator: Allocator,
    id: u64,
    stream: std.net.Stream,
    address: std.net.Address,
    authenticated: bool,
    tunnels: std.AutoHashMap(u64, *ServerTunnel),
    created_at: i64,
    last_activity: i64,
    stats: ClientStats,

    pub const ClientStats = struct {
        datagrams_forwarded: u64 = 0,
        bytes_forwarded: u64 = 0,
        tunnels_created: u64 = 0,
    };

    pub fn init(allocator: Allocator, id: u64, stream: std.net.Stream, address: std.net.Address) !*ClientConnection {
        const client = try allocator.create(ClientConnection);
        const now = std.time.timestamp();
        client.* = .{
            .allocator = allocator,
            .id = id,
            .stream = stream,
            .address = address,
            .authenticated = false,
            .tunnels = std.AutoHashMap(u64, *ServerTunnel).init(allocator),
            .created_at = now,
            .last_activity = now,
            .stats = .{},
        };
        return client;
    }

    pub fn deinit(self: *ClientConnection) void {
        var tunnel_iter = self.tunnels.valueIterator();
        while (tunnel_iter.next()) |tunnel_ptr| {
            tunnel_ptr.*.deinit();
            self.allocator.destroy(tunnel_ptr.*);
        }
        self.tunnels.deinit();
        self.stream.close();
        self.allocator.destroy(self);
    }
};

/// Server-side tunnel (forwards to target)
pub const ServerTunnel = struct {
    allocator: Allocator,
    context_id: u64,
    client_id: u64,
    target_host: []const u8,
    target_port: u16,
    target_socket: ?std.posix.socket_t,
    target_address: ?std.net.Address,
    state: TunnelState,
    created_at: i64,
    stats: TunnelStats,

    pub const TunnelState = enum {
        connecting,
        connected,
        draining,
        closed,
    };

    pub const TunnelStats = struct {
        datagrams_to_target: u64 = 0,
        datagrams_from_target: u64 = 0,
        bytes_to_target: u64 = 0,
        bytes_from_target: u64 = 0,
    };

    pub fn init(allocator: Allocator, context_id: u64, client_id: u64, host: []const u8, port: u16) !*ServerTunnel {
        const tunnel = try allocator.create(ServerTunnel);
        tunnel.* = .{
            .allocator = allocator,
            .context_id = context_id,
            .client_id = client_id,
            .target_host = try allocator.dupe(u8, host),
            .target_port = port,
            .target_socket = null,
            .target_address = null,
            .state = .connecting,
            .created_at = std.time.timestamp(),
            .stats = .{},
        };
        return tunnel;
    }

    /// Connect to target
    pub fn connectTarget(self: *ServerTunnel) !void {
        // Resolve target address
        self.target_address = try std.net.Address.resolveIp(self.target_host, self.target_port);

        // Create UDP socket
        self.target_socket = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        );

        self.state = .connected;
    }

    /// Forward datagram to target
    pub fn forwardToTarget(self: *ServerTunnel, data: []const u8) !void {
        if (self.target_socket == null or self.target_address == null) {
            try self.connectTarget();
        }

        _ = try std.posix.sendto(
            self.target_socket.?,
            data,
            0,
            &self.target_address.?.any,
            self.target_address.?.getOsSockLen(),
        );

        self.stats.datagrams_to_target += 1;
        self.stats.bytes_to_target += data.len;
    }

    /// Receive datagram from target (non-blocking)
    pub fn receiveFromTarget(self: *ServerTunnel, buffer: []u8) !?usize {
        if (self.target_socket == null) return null;

        // Set non-blocking
        const flags = try std.posix.fcntl(self.target_socket.?, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(self.target_socket.?, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);

        var src_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes = std.posix.recvfrom(
            self.target_socket.?,
            buffer,
            0,
            &src_addr,
            &addr_len,
        ) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (bytes > 0) {
            self.stats.datagrams_from_target += 1;
            self.stats.bytes_from_target += bytes;
        }

        return bytes;
    }

    pub fn deinit(self: *ServerTunnel) void {
        if (self.target_socket) |sock| {
            std.posix.close(sock);
        }
        self.allocator.free(self.target_host);
        self.allocator.destroy(self);
    }
};

/// MASQUE proxy server
pub const MasqueServer = struct {
    allocator: Allocator,
    config: ServerConfig,
    state: ServerState,

    // Server socket
    server: ?std.net.Server,

    // Connected clients
    clients: std.AutoHashMap(u64, *ClientConnection),
    next_client_id: u64,

    // Statistics
    stats: ServerStats,

    // Threads
    accept_thread: ?std.Thread,
    forward_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub const ServerState = enum {
        stopped,
        starting,
        running,
        stopping,
    };

    pub const ServerStats = struct {
        clients_connected: u64 = 0,
        clients_total: u64 = 0,
        tunnels_active: u64 = 0,
        tunnels_total: u64 = 0,
        datagrams_forwarded: u64 = 0,
        bytes_forwarded: u64 = 0,
        auth_failures: u64 = 0,
        target_denials: u64 = 0,
        uptime_seconds: u64 = 0,
        start_time: i64 = 0,
    };

    /// Initialize MASQUE server
    pub fn init(allocator: Allocator, config: ServerConfig) !*MasqueServer {
        const server = try allocator.create(MasqueServer);
        server.* = .{
            .allocator = allocator,
            .config = config,
            .state = .stopped,
            .server = null,
            .clients = std.AutoHashMap(u64, *ClientConnection).init(allocator),
            .next_client_id = 1,
            .stats = .{},
            .accept_thread = null,
            .forward_thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
        return server;
    }

    pub fn deinit(self: *MasqueServer) void {
        self.stop();

        var client_iter = self.clients.valueIterator();
        while (client_iter.next()) |client_ptr| {
            client_ptr.*.deinit();
        }
        self.clients.deinit();

        self.allocator.destroy(self);
    }

    /// Start the server
    pub fn start(self: *MasqueServer) !void {
        if (self.state != .stopped) return error.ServerAlreadyRunning;

        self.state = .starting;

        // Bind server socket
        const addr = try std.net.Address.parseIp4(self.config.bind_address, self.config.bind_port);
        self.server = try addr.listen(.{
            .reuse_address = true,
        });

        self.running.store(true, .release);
        self.stats.start_time = std.time.timestamp();

        // Start accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        // Start forwarding thread
        self.forward_thread = try std.Thread.spawn(.{}, forwardLoop, .{self});

        self.state = .running;

        std.log.info("[MASQUE] Server started on {s}:{d}", .{
            self.config.bind_address,
            self.config.bind_port,
        });
    }

    /// Stop the server
    pub fn stop(self: *MasqueServer) void {
        if (self.state == .stopped) return;

        self.state = .stopping;
        self.running.store(false, .release);

        // Close server socket
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        // Wait for threads
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        if (self.forward_thread) |t| {
            t.join();
            self.forward_thread = null;
        }

        self.state = .stopped;

        std.log.info("[MASQUE] Server stopped", .{});
    }

    /// Accept loop
    fn acceptLoop(self: *MasqueServer) void {
        while (self.running.load(.acquire)) {
            if (self.server) |*server| {
                if (server.accept()) |conn| {
                    self.handleNewConnection(conn) catch |err| {
                        std.log.err("[MASQUE] Accept error: {}", .{err});
                        conn.stream.close();
                    };
                } else |_| {
                    break;
                }
            } else {
                break;
            }
        }
    }

    /// Handle new client connection
    fn handleNewConnection(self: *MasqueServer, conn: std.net.Server.Connection) !void {
        // Check client limit
        if (self.clients.count() >= self.config.max_clients) {
            conn.stream.close();
            return;
        }

        const client_id = self.next_client_id;
        self.next_client_id += 1;

        const client = try ClientConnection.init(
            self.allocator,
            client_id,
            conn.stream,
            conn.address,
        );

        // If auth not required, mark as authenticated
        if (!self.config.require_auth) {
            client.authenticated = true;
        }

        try self.clients.put(client_id, client);
        self.stats.clients_connected += 1;
        self.stats.clients_total += 1;

        std.log.info("[MASQUE] Client connected: {d} from {}", .{ client_id, conn.address });
    }

    /// Forwarding loop (reads from clients, forwards to targets, and back)
    fn forwardLoop(self: *MasqueServer) void {
        var buffer: [4096]u8 = undefined;

        while (self.running.load(.acquire)) {
            var client_iter = self.clients.iterator();
            while (client_iter.next()) |entry| {
                const client = entry.value_ptr.*;

                // Read from client
                const bytes_read = client.stream.read(&buffer) catch |err| {
                    if (err == error.WouldBlock) continue;
                    // Client disconnected
                    self.removeClient(entry.key_ptr.*);
                    continue;
                };

                if (bytes_read == 0) {
                    // Client disconnected
                    self.removeClient(entry.key_ptr.*);
                    continue;
                }

                client.last_activity = std.time.timestamp();

                // Process request
                self.processClientData(client, buffer[0..bytes_read]) catch |err| {
                    std.log.warn("[MASQUE] Process error for client {d}: {}", .{ client.id, err });
                };
            }

            // Forward responses from targets back to clients
            self.forwardResponses() catch {};

            // Small sleep to prevent busy-waiting
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn removeClient(self: *MasqueServer, client_id: u64) void {
        if (self.clients.fetchRemove(client_id)) |entry| {
            entry.value.deinit();
            self.stats.clients_connected -= 1;
            std.log.info("[MASQUE] Client disconnected: {d}", .{client_id});
        }
    }

    fn processClientData(self: *MasqueServer, client: *ClientConnection, data: []const u8) !void {
        // Parse HTTP request or datagram
        // For simplicity, assuming HTTP/2 CONNECT request format

        if (std.mem.startsWith(u8, data, "CONNECT ")) {
            // Parse CONNECT request
            try self.handleConnectRequest(client, data);
        } else {
            // Assume it's a datagram for existing tunnel
            try self.handleDatagram(client, data);
        }
    }

    fn handleConnectRequest(self: *MasqueServer, client: *ClientConnection, data: []const u8) !void {
        // Parse target from path
        // Expected format: CONNECT /.well-known/masque/udp/{host}/{port}/ HTTP/2.0

        var lines = std.mem.splitSequence(u8, data, "\r\n");
        const first_line = lines.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        _ = parts.next(); // CONNECT
        const path = parts.next() orelse return error.InvalidRequest;

        // Check for CONNECT-UDP
        if (protocol.ConnectUdpTarget.fromPath(path)) |target| {
            // Check target against allow list
            if (!self.isTargetAllowed(target.host, target.port)) {
                self.stats.target_denials += 1;
                return error.TargetNotAllowed;
            }

            // Check tunnel limit
            if (client.tunnels.count() >= self.config.max_tunnels_per_client) {
                return error.TooManyTunnels;
            }

            // Create tunnel
            const context_id = client.tunnels.count() + 1;
            const tunnel = try ServerTunnel.init(
                self.allocator,
                context_id,
                client.id,
                target.host,
                target.port,
            );

            try tunnel.connectTarget();
            try client.tunnels.put(context_id, tunnel);

            client.stats.tunnels_created += 1;
            self.stats.tunnels_active += 1;
            self.stats.tunnels_total += 1;

            // Send success response
            const response = "HTTP/2.0 200 OK\r\n\r\n";
            _ = try client.stream.write(response);

            std.log.info("[MASQUE] Tunnel created for client {d}: {s}:{d}", .{
                client.id,
                target.host,
                target.port,
            });
        }
    }

    fn handleDatagram(self: *MasqueServer, client: *ClientConnection, data: []const u8) !void {
        // Parse HTTP/3 datagram
        const datagram = try protocol.Http3Datagram.decode(self.allocator, data);
        defer self.allocator.free(datagram.payload);

        const context_id = datagram.quarter_stream_id;

        if (client.tunnels.get(context_id)) |tunnel| {
            try tunnel.forwardToTarget(datagram.payload);
            client.stats.datagrams_forwarded += 1;
            client.stats.bytes_forwarded += datagram.payload.len;
            self.stats.datagrams_forwarded += 1;
            self.stats.bytes_forwarded += datagram.payload.len;
        }
    }

    fn forwardResponses(self: *MasqueServer) !void {
        var buffer: [4096]u8 = undefined;

        var client_iter = self.clients.valueIterator();
        while (client_iter.next()) |client_ptr| {
            const client = client_ptr.*;

            var tunnel_iter = client.tunnels.valueIterator();
            while (tunnel_iter.next()) |tunnel_ptr| {
                const tunnel = tunnel_ptr.*;

                // Try to receive from target
                if (try tunnel.receiveFromTarget(&buffer)) |bytes| {
                    // Wrap in HTTP/3 datagram
                    const datagram = protocol.Http3Datagram{
                        .quarter_stream_id = tunnel.context_id,
                        .payload = buffer[0..bytes],
                    };

                    const encoded = try datagram.encode(self.allocator);
                    defer self.allocator.free(encoded);

                    _ = try client.stream.write(encoded);
                }
            }
        }
    }

    fn isTargetAllowed(self: *MasqueServer, host: []const u8, port: u16) bool {
        if (self.config.allowed_targets == null) return true;

        for (self.config.allowed_targets.?) |pattern| {
            if (pattern.matches(host, port)) {
                return pattern.allow;
            }
        }

        return false; // Default deny if patterns defined but none matched
    }

    /// Get server statistics
    pub fn getStats(self: *MasqueServer) ServerStats {
        var stats = self.stats;
        if (stats.start_time > 0) {
            stats.uptime_seconds = @intCast(std.time.timestamp() - stats.start_time);
        }
        return stats;
    }

    /// Check if server is running
    pub fn isRunning(self: *const MasqueServer) bool {
        return self.state == .running;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MasqueServer: initialization" {
    const allocator = std.testing.allocator;

    const server = try MasqueServer.init(allocator, .{
        .bind_address = "127.0.0.1",
        .bind_port = 8443,
    });
    defer server.deinit();

    try std.testing.expectEqual(MasqueServer.ServerState.stopped, server.state);
}

test "TargetPattern: matching" {
    const pattern_wildcard = TargetPattern{
        .host_pattern = "*",
        .port_min = 8000,
        .port_max = 9000,
        .allow = true,
    };

    try std.testing.expect(pattern_wildcard.matches("any.host.com", 8500));
    try std.testing.expect(!pattern_wildcard.matches("any.host.com", 7000));

    const pattern_suffix = TargetPattern{
        .host_pattern = "*.solana.com",
        .port_min = 0,
        .port_max = 65535,
        .allow = true,
    };

    try std.testing.expect(pattern_suffix.matches("validator.mainnet.solana.com", 8001));
    try std.testing.expect(!pattern_suffix.matches("other.example.com", 8001));
}

