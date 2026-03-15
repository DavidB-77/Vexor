//! Vexor RPC Module
//!
//! JSON-RPC 2.0 API for Solana client interactions.
//!
//! Supported transports:
//! - HTTP/HTTPS (standard RPC)
//! - WebSocket (subscriptions)
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                       RPC LAYER                             │
//! ├────────────────────────┬────────────────────────────────────┤
//! │      HTTP Server       │        WebSocket Server            │
//! │      ──────────        │        ────────────────            │
//! │  - getAccountInfo      │  - accountSubscribe                │
//! │  - getBalance          │  - slotSubscribe                   │
//! │  - getSlot             │  - signatureSubscribe              │
//! │  - sendTransaction     │  - logsSubscribe                   │
//! │  - getTransaction      │  - programSubscribe                │
//! │  - getBlockHeight      │  - rootSubscribe                   │
//! │  - getHealth           │  - voteSubscribe                   │
//! └────────────────────────┴────────────────────────────────────┘

const std = @import("std");

// WebSocket subscriptions module
pub const websocket = @import("websocket/root.zig");

// WebSocket types
pub const WebSocketServer = websocket.WebSocketServer;
pub const ServerConfig = websocket.ServerConfig;
pub const SubscriptionManager = websocket.SubscriptionManager;
pub const SubscriptionType = websocket.SubscriptionType;
pub const Commitment = websocket.Commitment;
pub const Encoding = websocket.Encoding;

// Frame types
pub const Frame = websocket.Frame;
pub const Opcode = websocket.Opcode;
pub const CloseCode = websocket.CloseCode;

// Notification types
pub const Notification = websocket.Notification;
pub const AccountNotification = websocket.AccountNotification;
pub const SlotNotification = websocket.SlotNotification;
pub const SignatureNotification = websocket.SignatureNotification;

/// RPC server combining HTTP and WebSocket
pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    http_port: u16,
    ws_port: u16,
    ws_server: ?*WebSocketServer,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, config: RpcConfig) !*RpcServer {
        const server = try allocator.create(RpcServer);
        server.* = .{
            .allocator = allocator,
            .http_port = config.http_port,
            .ws_port = config.ws_port,
            .ws_server = null,
            .running = std.atomic.Value(bool).init(false),
        };

        // Initialize WebSocket server
        const ws = try allocator.create(WebSocketServer);
        ws.* = WebSocketServer.init(allocator, .{
            .port = config.ws_port,
        });
        server.ws_server = ws;

        return server;
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
        if (self.ws_server) |ws| {
            ws.deinit();
            self.allocator.destroy(ws);
        }
        self.allocator.destroy(self);
    }

    pub fn start(self: *RpcServer) !void {
        if (self.running.load(.acquire)) return;

        if (self.ws_server) |ws| {
            try ws.start();
        }

        self.running.store(true, .release);
        std.log.info("RPC server started (HTTP: {d}, WS: {d})", .{ self.http_port, self.ws_port });
    }

    pub fn stop(self: *RpcServer) void {
        if (!self.running.load(.acquire)) return;

        if (self.ws_server) |ws| {
            ws.stop();
        }

        self.running.store(false, .release);
    }

    pub fn getStats(self: *RpcServer) RpcStats {
        var stats = RpcStats{};

        if (self.ws_server) |ws| {
            const ws_stats = ws.getStats();
            stats.ws_connections = ws_stats.active_connections;
            stats.ws_subscriptions = ws_stats.total_subscriptions;
        }

        return stats;
    }
};

/// RPC configuration
pub const RpcConfig = struct {
    http_port: u16 = 8899,
    ws_port: u16 = 8900,
    max_connections: usize = 10000,
    enable_websocket: bool = true,
};

/// RPC statistics
pub const RpcStats = struct {
    http_requests: u64 = 0,
    ws_connections: usize = 0,
    ws_subscriptions: usize = 0,
};

// ============================================================================
// Tests
// ============================================================================

test "imports compile" {
    _ = websocket;
}

test "RpcConfig defaults" {
    const config = RpcConfig{};
    try std.testing.expectEqual(@as(u16, 8899), config.http_port);
    try std.testing.expectEqual(@as(u16, 8900), config.ws_port);
}

