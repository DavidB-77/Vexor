//! MASQUE Protocol Module
//! Multiplexed Application Substrate over QUIC Encryption
//!
//! Implements RFC 9298 (CONNECT-UDP) and RFC 9484 (CONNECT-IP) for
//! tunneling UDP and IP traffic through QUIC/HTTP3 proxies.
//!
//! Use Cases for Vexor:
//! ┌─────────────────────────────────────────────────────────────────────┐
//! │ 1. Dashboard Streaming Through Firewalls                            │
//! │    Dashboard ──MASQUE──▶ Proxy ──UDP──▶ Validator                   │
//! │                                                                      │
//! │ 2. Secure Validator Metrics Collection                              │
//! │    Metrics Aggregator ──MASQUE──▶ Multiple Validators               │
//! │                                                                      │
//! │ 3. NAT Traversal for Gossip                                         │
//! │    Validator (NAT) ──MASQUE──▶ Relay ──▶ Cluster                    │
//! │                                                                      │
//! │ 4. RPC Access Through Corporate Networks                            │
//! │    Client ──MASQUE (HTTPS/443)──▶ Proxy ──▶ Validator RPC          │
//! └─────────────────────────────────────────────────────────────────────┘
//!
//! Performance:
//! - Overhead: ~1-2ms per packet
//! - Encryption: TLS 1.3 (when using QUIC)
//! - Multiplexing: Multiple tunnels over single connection
//!
//! Example - Client:
//! ```zig
//! var client = try MasqueClient.init(allocator, .{
//!     .proxy_host = "proxy.example.com",
//!     .proxy_port = 443,
//! });
//! defer client.deinit();
//!
//! // Open UDP tunnel to validator
//! const tunnel = try client.connectUdp("validator.solana.com", 8001);
//!
//! // Send gossip packets
//! try tunnel.send(gossip_packet);
//! ```
//!
//! Example - Server:
//! ```zig
//! var server = try MasqueServer.init(allocator, .{
//!     .bind_port = 443,
//!     .allowed_targets = &[_]TargetPattern{
//!         .{ .host_pattern = "*.solana.com", .port_min = 8000, .port_max = 9000 },
//!     },
//! });
//! try server.start();
//! ```

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");

// Re-export main types
pub const MasqueClient = client.MasqueClient;
pub const MasqueServer = server.MasqueServer;
pub const ClientConfig = client.ClientConfig;
pub const ServerConfig = server.ServerConfig;
pub const UdpTunnel = client.UdpTunnel;
pub const IpTunnel = client.IpTunnel;
pub const TunnelState = client.TunnelState;
pub const TunnelStats = client.TunnelStats;
pub const TargetPattern = server.TargetPattern;

// Protocol types
pub const Http3Datagram = protocol.Http3Datagram;
pub const Capsule = protocol.Capsule;
pub const CapsuleType = protocol.CapsuleType;
pub const ConnectUdpTarget = protocol.ConnectUdpTarget;
pub const ConnectIpTarget = protocol.ConnectIpTarget;

/// Check if MASQUE is enabled at build time
pub fn isEnabled() bool {
    const build_options = @import("build_options");
    return build_options.masque_enabled;
}

/// Create a MASQUE client for connecting to a proxy
pub fn createClient(allocator: std.mem.Allocator, proxy_host: []const u8, proxy_port: u16) !*MasqueClient {
    return MasqueClient.init(allocator, .{
        .proxy_host = proxy_host,
        .proxy_port = proxy_port,
    });
}

/// Create a MASQUE server for proxying connections
pub fn createServer(allocator: std.mem.Allocator, port: u16) !*MasqueServer {
    return MasqueServer.init(allocator, .{
        .bind_port = port,
    });
}

// ============================================================================
// Integration helpers for Vexor
// ============================================================================

/// Configuration for dashboard streaming via MASQUE
pub const DashboardMasqueConfig = struct {
    /// Enable MASQUE for dashboard connections
    enabled: bool = false,
    /// MASQUE proxy host (for client mode)
    proxy_host: ?[]const u8 = null,
    /// MASQUE proxy port
    proxy_port: u16 = 443,
    /// Run local MASQUE server for incoming connections
    run_server: bool = false,
    /// Server bind port (if running server)
    server_port: u16 = 8443,
};

/// Create tunneled connection for dashboard streaming
pub fn createDashboardTunnel(
    allocator: std.mem.Allocator,
    config: DashboardMasqueConfig,
    validator_host: []const u8,
    validator_port: u16,
) !*UdpTunnel {
    if (!config.enabled) return error.MasqueNotEnabled;
    if (config.proxy_host == null) return error.NoProxyConfigured;

    const masque_client = try createClient(allocator, config.proxy_host.?, config.proxy_port);
    return masque_client.connectUdp(validator_host, validator_port);
}

// ============================================================================
// Tests
// ============================================================================

test "module compiles" {
    _ = protocol;
    _ = client;
    _ = server;
}

test "create client" {
    const allocator = std.testing.allocator;

    const masque_client = try MasqueClient.init(allocator, .{
        .proxy_host = "localhost",
        .proxy_port = 8443,
    });
    defer masque_client.deinit();

    try std.testing.expect(!masque_client.isConnected());
}

test "create server" {
    const allocator = std.testing.allocator;

    const masque_server = try MasqueServer.init(allocator, .{
        .bind_port = 18443,
    });
    defer masque_server.deinit();

    try std.testing.expect(!masque_server.isRunning());
}

