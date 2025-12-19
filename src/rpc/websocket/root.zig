//! WebSocket RPC Module
//! Real-time subscription support for Solana RPC API.
//!
//! Features:
//! - RFC 6455 compliant WebSocket protocol
//! - JSON-RPC 2.0 subscription methods
//! - Account change notifications
//! - Slot update notifications
//! - Signature confirmation notifications
//! - Program account change notifications
//! - Root update notifications
//! - Vote notifications
//!
//! Usage:
//! ```
//! const ws = @import("websocket/root.zig");
//!
//! var server = ws.WebSocketServer.init(allocator, .{
//!     .port = 8900,
//! });
//! defer server.deinit();
//!
//! try server.start();
//! ```
//!
//! Client subscription example (JavaScript):
//! ```javascript
//! const ws = new WebSocket('ws://localhost:8900');
//!
//! ws.onopen = () => {
//!     // Subscribe to slot updates
//!     ws.send(JSON.stringify({
//!         jsonrpc: '2.0',
//!         id: 1,
//!         method: 'slotSubscribe'
//!     }));
//! };
//!
//! ws.onmessage = (event) => {
//!     const msg = JSON.parse(event.data);
//!     if (msg.method === 'notification') {
//!         console.log('Subscription update:', msg.params);
//!     }
//! };
//! ```

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const subscriptions = @import("subscriptions.zig");
pub const server = @import("server.zig");

// Protocol types
pub const Frame = protocol.Frame;
pub const Opcode = protocol.Opcode;
pub const CloseCode = protocol.CloseCode;
pub const Handshake = protocol.Handshake;
pub const ConnectionState = protocol.ConnectionState;

// Subscription types
pub const SubscriptionManager = subscriptions.SubscriptionManager;
pub const SubscriptionType = subscriptions.SubscriptionType;
pub const SubscriptionId = subscriptions.SubscriptionId;
pub const Subscription = subscriptions.Subscription;
pub const Notification = subscriptions.Notification;
pub const NotificationPayload = subscriptions.NotificationPayload;

// Subscription configs
pub const AccountConfig = subscriptions.AccountConfig;
pub const ProgramConfig = subscriptions.ProgramConfig;
pub const SignatureConfig = subscriptions.SignatureConfig;
pub const LogsConfig = subscriptions.LogsConfig;
pub const LogsFilter = subscriptions.LogsFilter;
pub const Encoding = subscriptions.Encoding;
pub const Commitment = subscriptions.Commitment;
pub const DataSlice = subscriptions.DataSlice;
pub const Filter = subscriptions.Filter;

// Notification payloads
pub const AccountNotification = subscriptions.AccountNotification;
pub const SlotNotification = subscriptions.SlotNotification;
pub const SignatureNotification = subscriptions.SignatureNotification;
pub const LogsNotification = subscriptions.LogsNotification;
pub const ProgramNotification = subscriptions.ProgramNotification;
pub const BlockNotification = subscriptions.BlockNotification;
pub const VoteNotification = subscriptions.VoteNotification;

// Server types
pub const WebSocketServer = server.WebSocketServer;
pub const ServerConfig = server.ServerConfig;
pub const Connection = server.Connection;
pub const ServerStats = server.ServerStats;

// ============================================================================
// Tests
// ============================================================================

test "imports compile" {
    _ = protocol;
    _ = subscriptions;
    _ = server;
}

test "Frame encoding" {
    const allocator = std.testing.allocator;

    var frame = try Frame.text(allocator, "Hello, WebSocket!");
    defer frame.deinit();

    const encoded = try frame.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);
}

test "SubscriptionManager basic" {
    const allocator = std.testing.allocator;

    var mgr = SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const id = try mgr.subscribeSlot(1);
    try std.testing.expect(id > 0);

    try std.testing.expect(mgr.unsubscribe(id));
}

