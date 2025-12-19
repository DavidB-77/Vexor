//! Vexor RPC Server - TCP HTTP Server
//!
//! Full HTTP server implementation for JSON-RPC 2.0.
//! Handles connection management, request parsing, and response generation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const rpc_methods = @import("rpc_methods.zig");
const ResponseBuilder = rpc_methods.ResponseBuilder;
const RpcContext = rpc_methods.RpcContext;

/// RPC Server configuration
pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 8899,
    max_connections: usize = 1000,
    max_request_size: usize = 50 * 1024 * 1024, // 50MB
    request_timeout_ms: u64 = 30_000,
    enable_cors: bool = true,
    enable_websocket: bool = false,
};

/// HTTP RPC Server
pub const RpcHttpServer = struct {
    allocator: Allocator,
    config: ServerConfig,
    listener: ?net.Server,
    running: Atomic(bool),
    context: RpcContext,

    // Statistics
    stats: ServerStats,

    // Worker threads
    workers: std.ArrayList(Thread),

    const Self = @This();

    pub fn init(allocator: Allocator, config: ServerConfig) !*Self {
        const server = try allocator.create(Self);
        server.* = Self{
            .allocator = allocator,
            .config = config,
            .listener = null,
            .running = Atomic(bool).init(false),
            .context = RpcContext{
                .allocator = allocator,
                .accounts_db = null,
                .ledger_db = null,
                .bank = null,
                .current_slot = 0,
                .current_epoch = 0,
                .cluster = "testnet",
            },
            .stats = .{},
            .workers = std.ArrayList(Thread).init(allocator),
        };
        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.workers.deinit();
        self.allocator.destroy(self);
    }

    /// Start the HTTP server
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .seq_cst)) return;

        // Parse bind address
        const address = try net.Address.parseIp4(self.config.bind_address, self.config.port);

        // Create server
        self.listener = try address.listen(.{
            .reuse_address = true,
        });
        
        // Set socket to non-blocking mode so accept() doesn't block the main loop
        if (self.listener) |*listener| {
            const sock = listener.stream.handle;
            const flags = std.posix.fcntl(sock, std.posix.F.GETFL, 0) catch 0;
            // O_NONBLOCK = 0x800 on Linux
            _ = std.posix.fcntl(sock, std.posix.F.SETFL, flags | 0x800) catch {};
        }

        std.log.info("RPC server listening on {s}:{d}", .{ self.config.bind_address, self.config.port });
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .seq_cst)) return;

        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    /// Accept and handle one connection (call in loop)
    pub fn acceptConnection(self: *Self) !void {
        if (self.listener == null) return error.NotStarted;
        var listener = &self.listener.?;

        const conn = listener.accept() catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        self.stats.connections_accepted += 1;

        // Handle connection
        self.handleConnection(conn) catch |err| {
            self.stats.errors += 1;
            std.log.warn("Connection error: {}", .{err});
        };
    }

    fn handleConnection(self: *Self, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        // Read HTTP request
        while (total_read < buf.len) {
            const n = conn.stream.read(buf[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;

            // Check for end of HTTP headers
            if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |_| {
                break;
            }
        }

        if (total_read == 0) return;

        // Parse HTTP request
        const request_data = buf[0..total_read];

        // Find body
        const header_end = std.mem.indexOf(u8, request_data, "\r\n\r\n") orelse return;
        const body = request_data[header_end + 4 ..];

        // Check if it's a POST to /
        const first_line_end = std.mem.indexOf(u8, request_data, "\r\n") orelse return;
        const first_line = request_data[0..first_line_end];

        // Handle CORS preflight
        if (std.mem.startsWith(u8, first_line, "OPTIONS")) {
            try self.sendCorsResponse(conn);
            return;
        }

        // Must be POST
        if (!std.mem.startsWith(u8, first_line, "POST")) {
            try self.sendError(conn, 405, "Method Not Allowed");
            return;
        }

        // Process JSON-RPC request
        const response = self.processJsonRpc(body) catch |err| {
            std.log.warn("RPC error: {}", .{err});
            try self.sendJsonRpcError(conn, -32603, "Internal error");
            return;
        };
        defer self.allocator.free(response);

        // Send response
        try self.sendHttpResponse(conn, response);
        self.stats.requests_processed += 1;
    }

    fn processJsonRpc(self: *Self, body: []const u8) ![]u8 {
        // Parse JSON-RPC request
        const method = self.extractMethod(body) orelse return error.InvalidRequest;
        const id = self.extractId(body);
        const params = self.extractParams(body);

        // Build response - methods write only the result value (not the envelope)
        var response = ResponseBuilder.init(self.allocator);
        defer response.deinit();

        // Dispatch to method handler
        if (try rpc_methods.dispatch(method, &self.context, params, &response)) {
            // Method found and executed - build complete response
            var result = std.ArrayList(u8).init(self.allocator);
            try result.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
            try result.writer().print("{d}", .{id});
            try result.appendSlice(",\"result\":");
            try result.appendSlice(response.getWritten());
            try result.appendSlice("}");
            return result.toOwnedSlice();
        } else {
            // Method not found
            var result = std.ArrayList(u8).init(self.allocator);
            try result.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
            try result.writer().print("{d}", .{id});
            try result.appendSlice(",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
            return result.toOwnedSlice();
        }
    }

    fn extractMethod(self: *Self, body: []const u8) ?[]const u8 {
        _ = self;
        // Find "method":"..."
        const method_key = "\"method\"";
        const idx = std.mem.indexOf(u8, body, method_key) orelse return null;
        const after_key = body[idx + method_key.len ..];

        // Skip to value
        const colon = std.mem.indexOf(u8, after_key, ":") orelse return null;
        const after_colon = after_key[colon + 1 ..];

        // Find opening quote
        const quote1 = std.mem.indexOf(u8, after_colon, "\"") orelse return null;
        const after_quote1 = after_colon[quote1 + 1 ..];

        // Find closing quote
        const quote2 = std.mem.indexOf(u8, after_quote1, "\"") orelse return null;

        return after_quote1[0..quote2];
    }

    fn extractId(self: *Self, body: []const u8) u64 {
        _ = self;
        // Find "id":...
        const id_key = "\"id\"";
        const idx = std.mem.indexOf(u8, body, id_key) orelse return 1;
        const after_key = body[idx + id_key.len ..];

        const colon = std.mem.indexOf(u8, after_key, ":") orelse return 1;
        var after_colon = after_key[colon + 1 ..];

        // Skip whitespace
        while (after_colon.len > 0 and (after_colon[0] == ' ' or after_colon[0] == '\t')) {
            after_colon = after_colon[1..];
        }

        // Parse number or quoted string
        if (after_colon.len > 0 and after_colon[0] == '"') {
            // String ID - find end quote
            const end = std.mem.indexOfPos(u8, after_colon, 1, "\"") orelse return 1;
            return std.fmt.parseInt(u64, after_colon[1..end], 10) catch 1;
        } else {
            // Numeric ID
            var end: usize = 0;
            while (end < after_colon.len and after_colon[end] >= '0' and after_colon[end] <= '9') {
                end += 1;
            }
            if (end == 0) return 1;
            return std.fmt.parseInt(u64, after_colon[0..end], 10) catch 1;
        }
    }

    fn extractParams(self: *Self, body: []const u8) ?[]const u8 {
        _ = self;
        // Find "params":...
        const params_key = "\"params\"";
        const idx = std.mem.indexOf(u8, body, params_key) orelse return null;
        const after_key = body[idx + params_key.len ..];

        const colon = std.mem.indexOf(u8, after_key, ":") orelse return null;
        return after_key[colon + 1 ..];
    }

    fn sendHttpResponse(self: *Self, conn: net.Server.Connection, body: []const u8) !void {
        _ = self;
        var response_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&response_buf,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Content-Length: {d}
            \\Access-Control-Allow-Origin: *
            \\Connection: close
            \\
            \\
        , .{body.len}) catch unreachable;

        _ = try conn.stream.write(header);
        _ = try conn.stream.write(body);
    }

    fn sendError(self: *Self, conn: net.Server.Connection, code: u16, message: []const u8) !void {
        _ = self;
        var response_buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: text/plain
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\{s}
        , .{ code, message, message.len, message }) catch unreachable;

        _ = try conn.stream.write(response);
    }

    fn sendCorsResponse(self: *Self, conn: net.Server.Connection) !void {
        _ = self;
        const response =
            \\HTTP/1.1 204 No Content
            \\Access-Control-Allow-Origin: *
            \\Access-Control-Allow-Methods: POST, GET, OPTIONS
            \\Access-Control-Allow-Headers: Content-Type
            \\Access-Control-Max-Age: 86400
            \\Connection: close
            \\
            \\
        ;
        _ = try conn.stream.write(response);
    }

    fn sendJsonRpcError(self: *Self, conn: net.Server.Connection, code: i32, message: []const u8) !void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"jsonrpc":"2.0","id":null,"error":{{"code":{d},"message":"{s}"}}}}
        , .{ code, message }) catch unreachable;

        try self.sendHttpResponse(conn, body);
    }

    /// Update context (called when bank state changes)
    pub fn updateContext(self: *Self, slot: u64, epoch: u64) void {
        self.context.current_slot = slot;
        self.context.current_epoch = epoch;
    }

    pub fn getStats(self: *const Self) ServerStats {
        return self.stats;
    }
};

/// Server statistics
pub const ServerStats = struct {
    connections_accepted: u64 = 0,
    requests_processed: u64 = 0,
    errors: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "server init" {
    const allocator = std.testing.allocator;

    const server = try RpcHttpServer.init(allocator, .{});
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8899), server.config.port);
}

test "extract method" {
    const allocator = std.testing.allocator;

    const server = try RpcHttpServer.init(allocator, .{});
    defer server.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"getHealth\",\"id\":1}";
    const method = server.extractMethod(body);
    try std.testing.expect(method != null);
    try std.testing.expectEqualStrings("getHealth", method.?);
}

test "extract id" {
    const allocator = std.testing.allocator;

    const server = try RpcHttpServer.init(allocator, .{});
    defer server.deinit();

    const body = "{\"jsonrpc\":\"2.0\",\"method\":\"getHealth\",\"id\":42}";
    const id = server.extractId(body);
    try std.testing.expectEqual(@as(u64, 42), id);
}

