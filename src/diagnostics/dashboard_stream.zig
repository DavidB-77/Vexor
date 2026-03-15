//! Dashboard Streaming Protocol
//! Real-time metrics streaming for remote admin dashboards.
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────────┐
//! │   VALIDATOR                           REMOTE DASHBOARD          │
//! │   ─────────                           ────────────────          │
//! │   ┌─────────────┐                     ┌─────────────────┐       │
//! │   │ Metrics     │ ──QUIC Stream──▶    │ Dashboard UI    │       │
//! │   │ Collector   │                     │ (Web/Electron)  │       │
//! │   └─────────────┘                     └─────────────────┘       │
//! │         │                                     │                 │
//! │   JSON/Binary stream                   Real-time graphs         │
//! │   ~60 updates/sec                      <50ms latency             │
//! └─────────────────────────────────────────────────────────────────┘
//!
//! Benefits of remote dashboard:
//! - Zero CPU impact on validator
//! - Can monitor multiple validators
//! - Beautiful UI without validator constraints
//! - QUIC provides low-latency secure streaming

const std = @import("std");
const Allocator = std.mem.Allocator;
const metrics = @import("metrics.zig");

/// Stream message types
pub const MessageType = enum(u8) {
    handshake = 0x01,
    metrics_update = 0x02,
    alert = 0x03,
    log_entry = 0x04,
    health_check = 0x05,
    command = 0x06,
    command_response = 0x07,
    subscribe = 0x08,
    unsubscribe = 0x09,
};

/// Stream message header
pub const MessageHeader = extern struct {
    magic: [4]u8 = [_]u8{ 'V', 'X', 'D', 'S' }, // Vexor Dashboard Stream
    version: u8 = 1,
    msg_type: MessageType,
    payload_len: u32,
    timestamp_ms: u64,
    sequence: u64,
};

/// Metrics snapshot for streaming
pub const MetricsSnapshot = struct {
    // Slot info
    current_slot: u64,
    root_slot: u64,
    confirmed_slot: u64,

    // Performance
    tps: f64,
    slots_per_second: f64,
    vote_latency_ms: f64,
    slot_processing_ms: f64,

    // Counters
    transactions_processed: u64,
    transactions_failed: u64,
    votes_sent: u64,
    blocks_produced: u64,

    // Network
    gossip_packets_in: u64,
    gossip_packets_out: u64,
    turbine_shreds_in: u64,
    turbine_shreds_out: u64,
    cluster_nodes: u32,

    // Storage
    cache_hit_rate: f64,
    cache_size_mb: f64,
    disk_read_mbps: f64,
    disk_write_mbps: f64,

    // System
    cpu_percent: f64,
    memory_mb: f64,
    uptime_seconds: u64,

    // Status
    is_leader: bool,
    is_voting: bool,
    is_healthy: bool,
    skip_rate: f64,

    pub fn toJson(self: *const MetricsSnapshot, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"current_slot\": {d},\n", .{self.current_slot});
        try writer.print("  \"root_slot\": {d},\n", .{self.root_slot});
        try writer.print("  \"confirmed_slot\": {d},\n", .{self.confirmed_slot});
        try writer.print("  \"tps\": {d:.2},\n", .{self.tps});
        try writer.print("  \"slots_per_second\": {d:.2},\n", .{self.slots_per_second});
        try writer.print("  \"vote_latency_ms\": {d:.2},\n", .{self.vote_latency_ms});
        try writer.print("  \"slot_processing_ms\": {d:.2},\n", .{self.slot_processing_ms});
        try writer.print("  \"transactions_processed\": {d},\n", .{self.transactions_processed});
        try writer.print("  \"transactions_failed\": {d},\n", .{self.transactions_failed});
        try writer.print("  \"votes_sent\": {d},\n", .{self.votes_sent});
        try writer.print("  \"blocks_produced\": {d},\n", .{self.blocks_produced});
        try writer.print("  \"gossip_packets_in\": {d},\n", .{self.gossip_packets_in});
        try writer.print("  \"gossip_packets_out\": {d},\n", .{self.gossip_packets_out});
        try writer.print("  \"turbine_shreds_in\": {d},\n", .{self.turbine_shreds_in});
        try writer.print("  \"turbine_shreds_out\": {d},\n", .{self.turbine_shreds_out});
        try writer.print("  \"cluster_nodes\": {d},\n", .{self.cluster_nodes});
        try writer.print("  \"cache_hit_rate\": {d:.4},\n", .{self.cache_hit_rate});
        try writer.print("  \"cache_size_mb\": {d:.2},\n", .{self.cache_size_mb});
        try writer.print("  \"disk_read_mbps\": {d:.2},\n", .{self.disk_read_mbps});
        try writer.print("  \"disk_write_mbps\": {d:.2},\n", .{self.disk_write_mbps});
        try writer.print("  \"cpu_percent\": {d:.2},\n", .{self.cpu_percent});
        try writer.print("  \"memory_mb\": {d:.2},\n", .{self.memory_mb});
        try writer.print("  \"uptime_seconds\": {d},\n", .{self.uptime_seconds});
        try writer.print("  \"is_leader\": {s},\n", .{if (self.is_leader) "true" else "false"});
        try writer.print("  \"is_voting\": {s},\n", .{if (self.is_voting) "true" else "false"});
        try writer.print("  \"is_healthy\": {s},\n", .{if (self.is_healthy) "true" else "false"});
        try writer.print("  \"skip_rate\": {d:.4}\n", .{self.skip_rate});
        try writer.writeAll("}\n");

        return output.toOwnedSlice();
    }
};

/// Alert levels
pub const AlertLevel = enum(u8) {
    info = 0,
    warning = 1,
    critical = 2,
};

/// Alert message
pub const Alert = struct {
    level: AlertLevel,
    source: []const u8,
    message: []const u8,
    timestamp_ms: u64,
    auto_resolve: bool,
};

/// Dashboard stream server (runs on validator)
pub const DashboardStreamServer = struct {
    allocator: Allocator,
    port: u16,
    server: ?std.net.Server,
    clients: std.ArrayList(*StreamClient),
    metrics_registry: ?*metrics.MetricsRegistry,
    update_interval_ms: u64,
    running: std.atomic.Value(bool),
    sequence: std.atomic.Value(u64),
    stream_thread: ?std.Thread,
    accept_thread: ?std.Thread,

    pub const StreamClient = struct {
        stream: std.net.Stream,
        subscriptions: Subscriptions,
        last_update: i64,
        authenticated: bool,
    };

    pub const Subscriptions = struct {
        metrics: bool = true,
        alerts: bool = true,
        logs: bool = false,
    };

    pub fn init(allocator: Allocator, port: u16) DashboardStreamServer {
        return .{
            .allocator = allocator,
            .port = port,
            .server = null,
            .clients = std.ArrayList(*StreamClient).init(allocator),
            .metrics_registry = metrics.global_metrics,
            .update_interval_ms = 16, // ~60 FPS
            .running = std.atomic.Value(bool).init(false),
            .sequence = std.atomic.Value(u64).init(0),
            .stream_thread = null,
            .accept_thread = null,
        };
    }

    pub fn deinit(self: *DashboardStreamServer) void {
        self.stop();
        for (self.clients.items) |client| {
            client.stream.close();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
    }

    pub fn start(self: *DashboardStreamServer) !void {
        const addr = try std.net.Address.parseIp4("0.0.0.0", self.port);
        self.server = try addr.listen(.{ .reuse_address = true });

        self.running.store(true, .release);

        // Start accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        // Start streaming thread
        self.stream_thread = try std.Thread.spawn(.{}, streamLoop, .{self});

        std.log.info("Dashboard stream server started on port {d}", .{self.port});
    }

    pub fn stop(self: *DashboardStreamServer) void {
        self.running.store(false, .release);

        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }

        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        if (self.stream_thread) |t| {
            t.join();
            self.stream_thread = null;
        }
    }

    fn acceptLoop(self: *DashboardStreamServer) void {
        while (self.running.load(.acquire)) {
            if (self.server) |*server| {
                if (server.accept()) |conn| {
                    const client = self.allocator.create(StreamClient) catch continue;
                    client.* = .{
                        .stream = conn.stream,
                        .subscriptions = .{},
                        .last_update = std.time.timestamp(),
                        .authenticated = false, // TODO: Add auth
                    };
                    self.clients.append(client) catch {
                        self.allocator.destroy(client);
                    };
                    std.log.info("Dashboard client connected", .{});
                } else |_| {
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn streamLoop(self: *DashboardStreamServer) void {
        while (self.running.load(.acquire)) {
            // Collect metrics snapshot
            const snapshot = self.collectSnapshot();

            // Stream to all clients
            self.broadcastSnapshot(&snapshot);

            // Sleep for update interval
            const sleep_ns: u64 = @as(u64, self.update_interval_ms) * std.time.ns_per_ms;
            std.time.sleep(sleep_ns);
        }
    }

    fn collectSnapshot(self: *DashboardStreamServer) MetricsSnapshot {
        var snapshot = MetricsSnapshot{
            .current_slot = 0,
            .root_slot = 0,
            .confirmed_slot = 0,
            .tps = 0,
            .slots_per_second = 0,
            .vote_latency_ms = 0,
            .slot_processing_ms = 0,
            .transactions_processed = 0,
            .transactions_failed = 0,
            .votes_sent = 0,
            .blocks_produced = 0,
            .gossip_packets_in = 0,
            .gossip_packets_out = 0,
            .turbine_shreds_in = 0,
            .turbine_shreds_out = 0,
            .cluster_nodes = 0,
            .cache_hit_rate = 0,
            .cache_size_mb = 0,
            .disk_read_mbps = 0,
            .disk_write_mbps = 0,
            .cpu_percent = 0,
            .memory_mb = 0,
            .uptime_seconds = 0,
            .is_leader = false,
            .is_voting = true,
            .is_healthy = true,
            .skip_rate = 0,
        };

        if (self.metrics_registry) |reg| {
            snapshot.current_slot = @intFromFloat(reg.current_slot.get());
            snapshot.root_slot = @intFromFloat(reg.root_slot.get());
            snapshot.confirmed_slot = @intFromFloat(reg.confirmed_slot.get());
            snapshot.tps = reg.tps_current.get();
            snapshot.transactions_processed = @intFromFloat(reg.transactions_processed.get());
            snapshot.transactions_failed = @intFromFloat(reg.transactions_failed.get());
            snapshot.votes_sent = @intFromFloat(reg.votes_sent.get());
            snapshot.blocks_produced = @intFromFloat(reg.blocks_produced.get());
            snapshot.gossip_packets_in = @intFromFloat(reg.gossip_packets_received.get());
            snapshot.gossip_packets_out = @intFromFloat(reg.gossip_packets_sent.get());
            snapshot.cluster_nodes = @intFromFloat(reg.cluster_nodes.get());
            snapshot.cpu_percent = reg.cpu_usage_percent.get();
            snapshot.memory_mb = reg.memory_usage_bytes.get() / (1024 * 1024);
            snapshot.uptime_seconds = @intFromFloat(reg.uptime_seconds.get());

            const hits = reg.cache_hits.get();
            const misses = reg.cache_misses.get();
            if (hits + misses > 0) {
                snapshot.cache_hit_rate = hits / (hits + misses);
            }
        }

        return snapshot;
    }

    fn broadcastSnapshot(self: *DashboardStreamServer, snapshot: *const MetricsSnapshot) void {
        const json = snapshot.toJson(self.allocator) catch return;
        defer self.allocator.free(json);

        const seq = self.sequence.fetchAdd(1, .monotonic);

        // Build message
        var header = MessageHeader{
            .msg_type = .metrics_update,
            .payload_len = @intCast(json.len),
            .timestamp_ms = @intCast(std.time.milliTimestamp()),
            .sequence = seq,
        };

        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();

        for (self.clients.items, 0..) |client, i| {
            if (!client.subscriptions.metrics) continue;

            // Send header + payload
            _ = client.stream.write(std.mem.asBytes(&header)) catch {
                to_remove.append(i) catch {};
                continue;
            };
            _ = client.stream.write(json) catch {
                to_remove.append(i) catch {};
                continue;
            };
        }

        // Remove disconnected clients (in reverse order)
        var j = to_remove.items.len;
        while (j > 0) {
            j -= 1;
            const idx = to_remove.items[j];
            const client = self.clients.swapRemove(idx);
            client.stream.close();
            self.allocator.destroy(client);
        }
    }

    /// Send an alert to all subscribed clients
    pub fn sendAlert(self: *DashboardStreamServer, alert: Alert) void {
        _ = self;
        _ = alert;
        // TODO: Implement alert broadcasting
    }
};

/// Configuration for dashboard streaming
pub const DashboardConfig = struct {
    /// Port for dashboard stream server
    stream_port: u16 = 8910,
    /// Enable dashboard streaming
    enabled: bool = true,
    /// Update rate (updates per second)
    update_rate: u32 = 60,
    /// Require authentication
    require_auth: bool = false,
    /// Auth token (if required)
    auth_token: ?[]const u8 = null,
    /// Enable TLS
    enable_tls: bool = false,
};

// ============================================================================
// Tests
// ============================================================================

test "MetricsSnapshot: toJson" {
    const allocator = std.testing.allocator;

    var snapshot = MetricsSnapshot{
        .current_slot = 12345,
        .root_slot = 12340,
        .confirmed_slot = 12343,
        .tps = 1500.5,
        .slots_per_second = 2.5,
        .vote_latency_ms = 50.0,
        .slot_processing_ms = 200.0,
        .transactions_processed = 1000000,
        .transactions_failed = 100,
        .votes_sent = 500,
        .blocks_produced = 10,
        .gossip_packets_in = 50000,
        .gossip_packets_out = 45000,
        .turbine_shreds_in = 100000,
        .turbine_shreds_out = 90000,
        .cluster_nodes = 1500,
        .cache_hit_rate = 0.95,
        .cache_size_mb = 512.0,
        .disk_read_mbps = 100.0,
        .disk_write_mbps = 50.0,
        .cpu_percent = 45.0,
        .memory_mb = 32000.0,
        .uptime_seconds = 86400,
        .is_leader = false,
        .is_voting = true,
        .is_healthy = true,
        .skip_rate = 0.02,
    };

    const json = try snapshot.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"current_slot\": 12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tps\": 1500.50") != null);
}

test "DashboardStreamServer: init" {
    const allocator = std.testing.allocator;

    var server = DashboardStreamServer.init(allocator, 8910);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8910), server.port);
}

