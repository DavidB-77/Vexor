//! QUIC Transport Module
//! Full QUIC implementation with automatic transport selection.
//!
//! This module provides a unified API where you NEVER need to worry about:
//! - Payload sizes (automatic stream/datagram selection)
//! - Fragmentation (handled internally)
//! - Reliability (configurable per-message)
//! - Encryption (built-in TLS 1.3)
//!
//! Just send your data and it works!
//!
//! Quick Start:
//! ```zig
//! const quic = @import("network/quic/root.zig");
//!
//! // Create transport
//! var transport = try quic.createTransport(allocator);
//! defer transport.deinit();
//!
//! // Connect to peer
//! var conn = try transport.connect("validator.solana.com", 8001);
//!
//! // Send ANY size data - automatically handled!
//! try conn.sendBytes(small_gossip_packet);     // Uses datagram
//! try conn.sendBytes(huge_snapshot_chunk);     // Uses stream
//! try conn.sendBytes(critical_vote);           // Uses stream (reliable)
//!
//! // Receive messages
//! if (try conn.receive()) |msg| {
//!     defer msg.deinit();
//!     processMessage(msg.data);
//! }
//! ```
//!
//! MASQUE Integration:
//! ```zig
//! // Connect through MASQUE proxy
//! var conn = try quic.connectThroughMasque(allocator, .{
//!     .proxy_host = "proxy.example.com",
//!     .target_host = "validator.solana.com",
//!     .target_port = 8001,
//! });
//! ```

const std = @import("std");

pub const transport = @import("transport.zig");
pub const masque_bridge = @import("masque_bridge.zig");

// Core types
pub const Transport = transport.Transport;
pub const Connection = transport.Connection;
pub const Stream = transport.Stream;
pub const Message = transport.Message;
pub const ReceivedMessage = transport.ReceivedMessage;
pub const Priority = transport.Priority;
pub const DeliveryMode = transport.DeliveryMode;
pub const ConnectionConfig = transport.ConnectionConfig;
pub const ConnectionStats = transport.ConnectionStats;
pub const WireHeader = transport.WireHeader;
pub const PeerAddress = transport.PeerAddress;

// MASQUE bridge types
pub const MasqueConfig = masque_bridge.MasqueConfig;
pub const MasqueConnection = masque_bridge.MasqueConnection;

// Size constants
pub const MAX_DATAGRAM_SIZE = transport.MAX_DATAGRAM_SIZE;

/// Create a transport with default configuration
pub fn createTransport(allocator: std.mem.Allocator) !*Transport {
    return transport.createTransport(allocator);
}

/// Create a transport with custom configuration
pub fn createTransportWithConfig(allocator: std.mem.Allocator, config: ConnectionConfig) !*Transport {
    return Transport.init(allocator, config);
}

/// Dial a peer directly (no transport manager)
pub fn dial(allocator: std.mem.Allocator, host: []const u8, port: u16) !*Connection {
    return transport.dial(allocator, host, port);
}

/// Connect through MASQUE proxy
pub fn connectThroughMasque(allocator: std.mem.Allocator, config: MasqueConfig) !*MasqueConnection {
    return masque_bridge.connect(allocator, config);
}

/// Send any data to a peer (size handled automatically)
pub fn sendTo(conn: *Connection, data: []const u8) !void {
    try conn.sendBytes(data);
}

/// Send with explicit delivery mode
pub fn sendReliable(conn: *Connection, data: []const u8) !void {
    try conn.send(.{
        .data = data,
        .delivery = .reliable,
    });
}

/// Send unreliable (best effort, lowest latency)
pub fn sendUnreliable(conn: *Connection, data: []const u8) !void {
    try conn.send(.{
        .data = data,
        .delivery = .unreliable,
    });
}

/// Send with priority
pub fn sendWithPriority(conn: *Connection, data: []const u8, priority: Priority) !void {
    try conn.send(.{
        .data = data,
        .priority = priority,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "module compiles" {
    _ = transport;
    _ = masque_bridge;
}

