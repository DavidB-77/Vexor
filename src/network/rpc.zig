//! Vexor JSON-RPC Server
//!
//! HTTP JSON-RPC 2.0 server implementing Solana's RPC API.
//! Core methods for wallet/dapp interaction.

const std = @import("std");
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");

/// RPC Server configuration
pub const RpcConfig = struct {
    /// Bind address
    bind_address: []const u8 = "0.0.0.0",

    /// Port to listen on
    port: u16 = 8899,

    /// Maximum request body size
    max_body_size: usize = 50 * 1024 * 1024, // 50MB

    /// Enable rate limiting
    enable_rate_limiting: bool = true,

    /// Requests per second per IP
    rate_limit_rps: u32 = 100,
};

/// RPC Server
pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    config: RpcConfig,

    /// Reference to storage for queries
    accounts_db: ?*storage.AccountsDb,
    ledger_db: ?*storage.LedgerDb,

    /// Server state
    running: std.atomic.Value(bool),

    /// Statistics
    stats: RpcStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, port: u16) !*Self {
        const server = try allocator.create(Self);
        server.* = .{
            .allocator = allocator,
            .config = .{ .port = port },
            .accounts_db = null,
            .ledger_db = null,
            .running = std.atomic.Value(bool).init(false),
            .stats = .{},
        };
        return server;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }

    /// Start the RPC server
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);
        std.debug.print("RPC server listening on port {}\n", .{self.config.port});
    }

    /// Stop the RPC server
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
    }

    /// Handle a JSON-RPC request
    pub fn handleRequest(self: *Self, request_body: []const u8) ![]u8 {
        self.stats.total_requests += 1;

        // Parse JSON request
        const request = try self.parseRequest(request_body);

        // Route to handler
        const result = self.routeRequest(request);

        // Build response
        return self.buildResponse(request.id, result);
    }

    fn parseRequest(self: *Self, body: []const u8) !JsonRpcRequest {
        _ = self;
        // Simple JSON parsing for RPC request
        // In production, use a proper JSON parser

        var request = JsonRpcRequest{
            .jsonrpc = "2.0",
            .method = "",
            .params = null,
            .id = 1,
        };

        // Find method
        if (std.mem.indexOf(u8, body, "\"method\"")) |idx| {
            const quote1 = std.mem.indexOfPos(u8, body, idx, "\"") orelse return error.InvalidJson;
            const quote2 = std.mem.indexOfPos(u8, body, quote1 + 1, "\"") orelse return error.InvalidJson;
            if (std.mem.indexOfPos(u8, body, quote2 + 1, "\"")) |mstart| {
                if (std.mem.indexOfPos(u8, body, mstart + 1, "\"")) |mend| {
                    request.method = body[mstart + 1 .. mend];
                }
            }
        }

        return request;
    }

    fn routeRequest(self: *Self, request: JsonRpcRequest) RpcResult {
        // Route based on method name
        if (std.mem.eql(u8, request.method, "getHealth")) {
            return self.handleGetHealth();
        } else if (std.mem.eql(u8, request.method, "getVersion")) {
            return self.handleGetVersion();
        } else if (std.mem.eql(u8, request.method, "getSlot")) {
            return self.handleGetSlot();
        } else if (std.mem.eql(u8, request.method, "getBlockHeight")) {
            return self.handleGetBlockHeight();
        } else if (std.mem.eql(u8, request.method, "getBalance")) {
            return self.handleGetBalance(request.params);
        } else if (std.mem.eql(u8, request.method, "getAccountInfo")) {
            return self.handleGetAccountInfo(request.params);
        } else if (std.mem.eql(u8, request.method, "getLatestBlockhash")) {
            return self.handleGetLatestBlockhash();
        } else if (std.mem.eql(u8, request.method, "sendTransaction")) {
            return self.handleSendTransaction(request.params);
        } else if (std.mem.eql(u8, request.method, "getSignatureStatuses")) {
            return self.handleGetSignatureStatuses(request.params);
        } else if (std.mem.eql(u8, request.method, "getMinimumBalanceForRentExemption")) {
            return self.handleGetMinimumBalanceForRentExemption(request.params);
        } else {
            return .{ .err = .{ .code = -32601, .message = "Method not found" } };
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RPC METHOD HANDLERS
    // ═══════════════════════════════════════════════════════════════════════════

    fn handleGetHealth(self: *Self) RpcResult {
        _ = self;
        return .{ .result = "\"ok\"" };
    }

    fn handleGetVersion(self: *Self) RpcResult {
        _ = self;
        return .{ .result = "{\"solana-core\":\"0.1.0-vexor\",\"feature-set\":1}" };
    }

    fn handleGetSlot(self: *Self) RpcResult {
        if (self.ledger_db) |db| {
            const slot = db.latest_slot.load(.seq_cst);
            var buf: [32]u8 = undefined;
            const len = std.fmt.formatInt(slot, 10, .lower, .{}, &buf) catch return .{ .err = .{ .code = -32603, .message = "Internal error" } };
            return .{ .result = buf[0..len] };
        }
        return .{ .result = "0" };
    }

    fn handleGetBlockHeight(self: *Self) RpcResult {
        // Block height is same as slot for now
        return self.handleGetSlot();
    }

    fn handleGetBalance(self: *Self, params: ?[]const u8) RpcResult {
        _ = params;
        if (self.accounts_db) |_| {
            // TODO: Parse pubkey from params and look up balance
            return .{ .result = "{\"context\":{\"slot\":0},\"value\":0}" };
        }
        return .{ .result = "{\"context\":{\"slot\":0},\"value\":0}" };
    }

    fn handleGetAccountInfo(self: *Self, params: ?[]const u8) RpcResult {
        _ = params;
        _ = self;
        // TODO: Parse pubkey and return account data
        return .{ .result = "{\"context\":{\"slot\":0},\"value\":null}" };
    }

    fn handleGetLatestBlockhash(self: *Self) RpcResult {
        _ = self;
        // TODO: Return actual latest blockhash
        const fake_hash = "11111111111111111111111111111111";
        return .{ .result = "{\"context\":{\"slot\":0},\"value\":{\"blockhash\":\"" ++ fake_hash ++ "\",\"lastValidBlockHeight\":0}}" };
    }

    fn handleSendTransaction(self: *Self, params: ?[]const u8) RpcResult {
        _ = params;
        self.stats.transactions_received += 1;
        // TODO: Decode and forward to TPU
        return .{ .result = "\"sent\"" };
    }

    fn handleGetSignatureStatuses(self: *Self, params: ?[]const u8) RpcResult {
        _ = params;
        _ = self;
        return .{ .result = "{\"context\":{\"slot\":0},\"value\":[null]}" };
    }

    fn handleGetMinimumBalanceForRentExemption(self: *Self, params: ?[]const u8) RpcResult {
        _ = params;
        _ = self;
        // Calculate rent exemption for a given data size
        // Minimum is ~0.00089 SOL per byte
        return .{ .result = "890880" }; // ~0.00089 SOL for 0 bytes
    }

    fn buildResponse(self: *Self, id: u64, result: RpcResult) ![]u8 {
        var response = std.ArrayList(u8).init(self.allocator);
        errdefer response.deinit();

        try response.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":");
        var id_buf: [20]u8 = undefined;
        const id_len = std.fmt.formatInt(id, 10, .lower, .{}, &id_buf) catch unreachable;
        try response.appendSlice(id_buf[0..id_len]);

        switch (result) {
            .result => |r| {
                try response.appendSlice(",\"result\":");
                try response.appendSlice(r);
            },
            .err => |e| {
                try response.appendSlice(",\"error\":{\"code\":");
                var code_buf: [12]u8 = undefined;
                const code_len = std.fmt.formatInt(e.code, 10, .lower, .{}, &code_buf) catch unreachable;
                try response.appendSlice(code_buf[0..code_len]);
                try response.appendSlice(",\"message\":\"");
                try response.appendSlice(e.message);
                try response.appendSlice("\"}");
            },
        }

        try response.appendSlice("}");

        return try response.toOwnedSlice();
    }
};

/// JSON-RPC request
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: ?[]const u8,
    id: u64,
};

/// RPC result union
pub const RpcResult = union(enum) {
    result: []const u8,
    err: RpcError,
};

/// RPC error
pub const RpcError = struct {
    code: i32,
    message: []const u8,

    // Standard JSON-RPC errors
    pub const ParseError = RpcError{ .code = -32700, .message = "Parse error" };
    pub const InvalidRequest = RpcError{ .code = -32600, .message = "Invalid Request" };
    pub const MethodNotFound = RpcError{ .code = -32601, .message = "Method not found" };
    pub const InvalidParams = RpcError{ .code = -32602, .message = "Invalid params" };
    pub const InternalError = RpcError{ .code = -32603, .message = "Internal error" };
};

/// RPC statistics
pub const RpcStats = struct {
    total_requests: u64 = 0,
    transactions_received: u64 = 0,
    errors: u64 = 0,
};

/// Simple HTTP request parser for RPC
pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,

    pub fn parse(data: []const u8) !HttpRequest {
        // Find method
        const method_end = std.mem.indexOf(u8, data, " ") orelse return error.InvalidHttp;
        const method = data[0..method_end];

        // Find path
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfPos(u8, data, path_start, " ") orelse return error.InvalidHttp;
        const path = data[path_start..path_end];

        // Find body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidHttp;
        const body = data[body_start + 4 ..];

        return .{
            .method = method,
            .path = path,
            .body = body,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "rpc server init" {
    var server = try RpcServer.init(std.testing.allocator, 8899);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8899), server.config.port);
}

test "http request parse" {
    const raw = "POST /rpc HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"method\":\"getHealth\"}";
    const req = try HttpRequest.parse(raw);

    try std.testing.expectEqualSlices(u8, "POST", req.method);
    try std.testing.expectEqualSlices(u8, "/rpc", req.path);
}
