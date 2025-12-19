//! WebSocket RPC Server
//! Handles WebSocket connections for real-time Solana RPC subscriptions.
//!
//! Connection lifecycle:
//! 1. HTTP Upgrade request
//! 2. WebSocket handshake
//! 3. Subscription management
//! 4. Real-time notifications
//! 5. Graceful close

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const protocol = @import("protocol.zig");
const subscriptions = @import("subscriptions.zig");

const Frame = protocol.Frame;
const Opcode = protocol.Opcode;
const CloseCode = protocol.CloseCode;
const Handshake = protocol.Handshake;
const ConnectionState = protocol.ConnectionState;
const SubscriptionManager = subscriptions.SubscriptionManager;
const Notification = subscriptions.Notification;

/// WebSocket server configuration
pub const ServerConfig = struct {
    /// Bind address
    host: []const u8 = "0.0.0.0",
    /// Bind port
    port: u16 = 8900,
    /// Maximum connections
    max_connections: usize = 10000,
    /// Read buffer size
    read_buffer_size: usize = 64 * 1024,
    /// Write buffer size
    write_buffer_size: usize = 64 * 1024,
    /// Ping interval (ms)
    ping_interval_ms: u64 = 30_000,
    /// Connection timeout (ms)
    connection_timeout_ms: u64 = 120_000,
    /// Maximum message size
    max_message_size: usize = 16 * 1024 * 1024,
};

/// WebSocket connection
pub const Connection = struct {
    id: u64,
    stream: std.net.Stream,
    state: ConnectionState,
    read_buffer: []u8,
    write_buffer: []u8,
    last_activity: i64,
    last_ping: i64,
    pending_pong: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, stream: std.net.Stream, id: u64, config: ServerConfig) !Connection {
        return .{
            .id = id,
            .stream = stream,
            .state = .connecting,
            .read_buffer = try allocator.alloc(u8, config.read_buffer_size),
            .write_buffer = try allocator.alloc(u8, config.write_buffer_size),
            .last_activity = std.time.timestamp(),
            .last_ping = 0,
            .pending_pong = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close();
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
    }

    /// Send a WebSocket frame
    pub fn sendFrame(self: *Connection, frame: *const Frame) !void {
        const encoded = try frame.encode(self.allocator);
        defer self.allocator.free(encoded);

        _ = try self.stream.write(encoded);
        self.last_activity = std.time.timestamp();
    }

    /// Send JSON message
    pub fn sendJson(self: *Connection, json: []const u8) !void {
        var frame = try Frame.text(self.allocator, json);
        defer frame.deinit();
        try self.sendFrame(&frame);
    }

    /// Send notification
    pub fn sendNotification(self: *Connection, sub_id: u64, result: anytype) !void {
        var buffer: [16384]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        try std.json.stringify(.{
            .jsonrpc = "2.0",
            .method = "notification",
            .params = .{
                .subscription = sub_id,
                .result = result,
            },
        }, .{}, stream.writer());

        try self.sendJson(stream.getWritten());
    }

    /// Send ping
    pub fn sendPing(self: *Connection) !void {
        var frame = try Frame.ping(self.allocator, "ping");
        defer frame.deinit();
        try self.sendFrame(&frame);
        self.pending_pong = true;
        self.last_ping = std.time.timestamp();
    }

    /// Send close
    pub fn sendClose(self: *Connection, code: CloseCode, reason: []const u8) !void {
        var frame = try Frame.close(self.allocator, code, reason);
        defer frame.deinit();
        try self.sendFrame(&frame);
        self.state = .closing;
    }
};

/// WebSocket RPC server
pub const WebSocketServer = struct {
    /// Configuration
    config: ServerConfig,
    /// Subscription manager
    subscriptions: SubscriptionManager,
    /// Active connections
    connections: std.AutoHashMap(u64, *Connection),
    /// Server socket
    server: ?std.net.Server,
    /// Next connection ID
    next_conn_id: std.atomic.Value(u64),
    /// Shutdown flag
    shutdown: std.atomic.Value(bool),
    /// Mutex
    mutex: Mutex,
    /// Allocator
    allocator: Allocator,
    /// Accept thread
    accept_thread: ?std.Thread,
    /// Ping thread
    ping_thread: ?std.Thread,

    pub fn init(allocator: Allocator, config: ServerConfig) WebSocketServer {
        var server = WebSocketServer{
            .config = config,
            .subscriptions = SubscriptionManager.init(allocator),
            .connections = std.AutoHashMap(u64, *Connection).init(allocator),
            .server = null,
            .next_conn_id = std.atomic.Value(u64).init(1),
            .shutdown = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .allocator = allocator,
            .accept_thread = null,
            .ping_thread = null,
        };

        // Set up notification callback
        server.subscriptions.notify_fn = notificationCallback;

        return server;
    }

    pub fn deinit(self: *WebSocketServer) void {
        self.stop();

        var iter = self.connections.valueIterator();
        while (iter.next()) |conn| {
            conn.*.deinit();
            self.allocator.destroy(conn.*);
        }
        self.connections.deinit();
        self.subscriptions.deinit();
    }

    /// Start the server
    pub fn start(self: *WebSocketServer) !void {
        const addr = try std.net.Address.parseIp4(self.config.host, self.config.port);
        self.server = try addr.listen(.{
            .reuse_address = true,
        });

        std.log.info("WebSocket RPC server listening on ws://{s}:{d}", .{
            self.config.host,
            self.config.port,
        });

        // Start accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        // Start ping thread
        self.ping_thread = try std.Thread.spawn(.{}, pingLoop, .{self});
    }

    /// Stop the server
    pub fn stop(self: *WebSocketServer) void {
        self.shutdown.store(true, .release);

        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        if (self.ping_thread) |thread| {
            thread.join();
            self.ping_thread = null;
        }
    }

    fn acceptLoop(self: *WebSocketServer) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.server) |*server| {
                const conn_result = server.accept();
                if (conn_result) |conn| {
                    self.handleNewConnection(conn.stream) catch |err| {
                        std.log.warn("Failed to handle new connection: {}", .{err});
                    };
                } else |_| {
                    // Accept failed, likely shutting down
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn pingLoop(self: *WebSocketServer) void {
        while (!self.shutdown.load(.acquire)) {
            const sleep_ns: u64 = @as(u64, self.config.ping_interval_ms) * std.time.ns_per_ms;
            std.time.sleep(sleep_ns);

            self.mutex.lock();
            defer self.mutex.unlock();

            const now = std.time.timestamp();
            var to_remove = std.ArrayList(u64).init(self.allocator);
            defer to_remove.deinit();

            var iter = self.connections.iterator();
            while (iter.next()) |entry| {
                const conn = entry.value_ptr.*;

                // Check for timeout
                const inactive_ms: u64 = @intCast(now - conn.last_activity);
                if (inactive_ms * 1000 > self.config.connection_timeout_ms) {
                    to_remove.append(entry.key_ptr.*) catch continue;
                    continue;
                }

                // Send ping
                conn.sendPing() catch {
                    to_remove.append(entry.key_ptr.*) catch continue;
                };
            }

            // Remove dead connections
            for (to_remove.items) |id| {
                self.removeConnection(id);
            }
        }
    }

    fn handleNewConnection(self: *WebSocketServer, stream: std.net.Stream) !void {
        const id = self.next_conn_id.fetchAdd(1, .monotonic);

        // Check connection limit
        self.mutex.lock();
        if (self.connections.count() >= self.config.max_connections) {
            self.mutex.unlock();
            stream.close();
            return error.TooManyConnections;
        }
        self.mutex.unlock();

        // Create connection
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);

        conn.* = try Connection.init(self.allocator, stream, id, self.config);
        errdefer conn.deinit();

        // Perform handshake
        try self.performHandshake(conn);

        // Add to connections
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.put(id, conn);

        std.log.debug("WebSocket connection {d} established", .{id});

        // Start handling messages
        // In production, this would be handled by a worker thread pool
        _ = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch |err| {
            std.log.warn("Failed to spawn connection handler: {}", .{err});
            self.removeConnection(id);
        };
    }

    fn performHandshake(self: *WebSocketServer, conn: *Connection) !void {
        _ = self;

        // Read HTTP upgrade request
        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) return error.ConnectionClosed;

        const request = buf[0..n];

        // Extract Sec-WebSocket-Key
        var key: ?[]const u8 = null;
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Sec-WebSocket-Key:")) {
                key = std.mem.trim(u8, line["Sec-WebSocket-Key:".len..], " ");
                break;
            }
        }

        if (key == null) return error.InvalidHandshake;

        // Send handshake response
        const response = try Handshake.buildResponse(conn.allocator, key.?);
        defer conn.allocator.free(response);

        _ = try conn.stream.write(response);
        conn.state = .open;
    }

    fn handleConnection(self: *WebSocketServer, conn: *Connection) void {
        defer {
            self.mutex.lock();
            _ = self.subscriptions.removeConnectionSubscriptions(conn.id) catch 0;
            _ = self.connections.remove(conn.id);
            self.mutex.unlock();

            conn.deinit();
            self.allocator.destroy(conn);
        }

        while (!self.shutdown.load(.acquire) and conn.state == .open) {
            // Read data
            const n = conn.stream.read(conn.read_buffer) catch break;
            if (n == 0) break;

            conn.last_activity = std.time.timestamp();

            // Parse frame
            const result = Frame.decode(conn.allocator, conn.read_buffer[0..n]) catch continue;
            var frame = result.frame;
            defer frame.deinit();

            // Handle frame
            self.handleFrame(conn, &frame) catch break;
        }
    }

    fn handleFrame(self: *WebSocketServer, conn: *Connection, frame: *const Frame) !void {
        switch (frame.opcode) {
            .text => try self.handleMessage(conn, frame.payload),
            .binary => try self.handleMessage(conn, frame.payload),
            .close => {
                conn.state = .closing;
                try conn.sendClose(.normal, "goodbye");
            },
            .ping => {
                var pong = try Frame.pong(conn.allocator, frame.payload);
                defer pong.deinit();
                try conn.sendFrame(&pong);
            },
            .pong => {
                conn.pending_pong = false;
            },
            else => {},
        }
    }

    fn handleMessage(self: *WebSocketServer, conn: *Connection, data: []const u8) !void {
        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(std.json.Value, conn.allocator, data, .{}) catch {
            try self.sendError(conn, null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try self.sendError(conn, null, -32600, "Invalid Request");
            return;
        }

        const obj = root.object;
        const id = obj.get("id");
        const method = obj.get("method");
        const params = obj.get("params");

        if (method == null or method.? != .string) {
            try self.sendError(conn, id, -32600, "Invalid Request");
            return;
        }

        const method_str = method.?.string;

        // Route to handler
        if (std.mem.eql(u8, method_str, "accountSubscribe")) {
            try self.handleAccountSubscribe(conn, id, params);
        } else if (std.mem.eql(u8, method_str, "accountUnsubscribe")) {
            try self.handleUnsubscribe(conn, id, params);
        } else if (std.mem.eql(u8, method_str, "slotSubscribe")) {
            try self.handleSlotSubscribe(conn, id);
        } else if (std.mem.eql(u8, method_str, "slotUnsubscribe")) {
            try self.handleUnsubscribe(conn, id, params);
        } else if (std.mem.eql(u8, method_str, "signatureSubscribe")) {
            try self.handleSignatureSubscribe(conn, id, params);
        } else if (std.mem.eql(u8, method_str, "signatureUnsubscribe")) {
            try self.handleUnsubscribe(conn, id, params);
        } else if (std.mem.eql(u8, method_str, "rootSubscribe")) {
            try self.handleRootSubscribe(conn, id);
        } else if (std.mem.eql(u8, method_str, "rootUnsubscribe")) {
            try self.handleUnsubscribe(conn, id, params);
        } else {
            try self.sendError(conn, id, -32601, "Method not found");
        }
    }

    fn handleAccountSubscribe(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value, params: ?std.json.Value) !void {
        _ = params; // TODO: parse params

        // For now, just return a subscription ID
        const sub_id = try self.subscriptions.subscribeAccount(conn.id, .{
            .pubkey = [_]u8{0} ** 32, // TODO: parse from params
        });

        try self.sendResult(conn, id, sub_id);
    }

    fn handleSlotSubscribe(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value) !void {
        const sub_id = try self.subscriptions.subscribeSlot(conn.id);
        try self.sendResult(conn, id, sub_id);
    }

    fn handleSignatureSubscribe(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value, params: ?std.json.Value) !void {
        _ = params; // TODO: parse params

        const sub_id = try self.subscriptions.subscribeSignature(conn.id, .{
            .signature = [_]u8{0} ** 64, // TODO: parse from params
        });

        try self.sendResult(conn, id, sub_id);
    }

    fn handleRootSubscribe(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value) !void {
        const sub_id = try self.subscriptions.subscribeRoot(conn.id);
        try self.sendResult(conn, id, sub_id);
    }

    fn handleUnsubscribe(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value, params: ?std.json.Value) !void {
        var success = false;

        if (params) |p| {
            if (p == .array and p.array.items.len > 0) {
                if (p.array.items[0] == .integer) {
                    const sub_id: u64 = @intCast(p.array.items[0].integer);
                    success = self.subscriptions.unsubscribe(sub_id);
                }
            }
        }

        try self.sendResult(conn, id, success);
    }

    fn sendResult(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value, result: anytype) !void {
        _ = self;
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        const id_val: i64 = if (id) |i| (if (i == .integer) i.integer else 0) else 0;

        try std.json.stringify(.{
            .jsonrpc = "2.0",
            .id = id_val,
            .result = result,
        }, .{}, stream.writer());

        try conn.sendJson(stream.getWritten());
    }

    fn sendError(self: *WebSocketServer, conn: *Connection, id: ?std.json.Value, code: i32, message: []const u8) !void {
        _ = self;
        var buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        const id_val: i64 = if (id) |i| (if (i == .integer) i.integer else 0) else 0;

        try std.json.stringify(.{
            .jsonrpc = "2.0",
            .id = id_val,
            .@"error" = .{
                .code = code,
                .message = message,
            },
        }, .{}, stream.writer());

        try conn.sendJson(stream.getWritten());
    }

    fn notificationCallback(mgr: *SubscriptionManager, conn_id: u64, notification: Notification) void {
        _ = mgr;
        _ = conn_id;
        _ = notification;
        // TODO: Look up connection and send notification
        // This is a static callback, need to get server reference
    }

    fn removeConnection(self: *WebSocketServer, id: u64) void {
        if (self.connections.fetchRemove(id)) |kv| {
            _ = self.subscriptions.removeConnectionSubscriptions(id) catch 0;
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Get server statistics
    pub fn getStats(self: *WebSocketServer) ServerStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .active_connections = self.connections.count(),
            .total_subscriptions = self.subscriptions.getSubscriptionCount(),
        };
    }
};

/// Server statistics
pub const ServerStats = struct {
    active_connections: usize,
    total_subscriptions: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "WebSocketServer: init" {
    const allocator = std.testing.allocator;

    var server = WebSocketServer.init(allocator, .{});
    defer server.deinit();

    const stats = server.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.active_connections);
}

test "Connection: create frame" {
    const allocator = std.testing.allocator;

    var frame = try Frame.text(allocator, "test message");
    defer frame.deinit();

    try std.testing.expectEqual(Opcode.text, frame.opcode);
}

