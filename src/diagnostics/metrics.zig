//! Prometheus-Compatible Metrics Exporter
//! Exports validator metrics in Prometheus format for Grafana dashboards.
//!
//! Endpoints:
//! - /metrics - Prometheus text format
//! - /metrics/json - JSON format for custom dashboards
//! - /health - Health check endpoint
//!
//! Metrics Categories:
//! - Slot processing (rate, latency, errors)
//! - Transaction processing (TPS, success rate)
//! - Network (packets in/out, connections)
//! - Storage (cache hit rate, disk usage)
//! - Consensus (votes, leader slots)
//! - System (CPU, memory, disk I/O)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

/// Metric types
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,
};

/// Single metric
pub const Metric = struct {
    name: []const u8,
    help: []const u8,
    metric_type: MetricType,
    value: std.atomic.Value(f64),
    labels: ?std.StringHashMap([]const u8),

    pub fn inc(self: *Metric) void {
        _ = self.value.fetchAdd(1.0, .monotonic);
    }

    pub fn incBy(self: *Metric, v: f64) void {
        _ = self.value.fetchAdd(v, .monotonic);
    }

    pub fn dec(self: *Metric) void {
        _ = self.value.fetchSub(1.0, .monotonic);
    }

    pub fn set(self: *Metric, v: f64) void {
        self.value.store(v, .release);
    }

    pub fn get(self: *const Metric) f64 {
        return self.value.load(.acquire);
    }
};

/// Histogram bucket
pub const HistogramBucket = struct {
    le: f64, // Upper bound
    count: std.atomic.Value(u64),
};

/// Histogram metric
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []HistogramBucket,
    sum: std.atomic.Value(f64),
    count: std.atomic.Value(u64),
    allocator: Allocator,

    /// Default latency buckets (in seconds)
    pub const DEFAULT_BUCKETS = [_]f64{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    pub fn init(allocator: Allocator, name: []const u8, help: []const u8, bucket_bounds: []const f64) !Histogram {
        const buckets = try allocator.alloc(HistogramBucket, bucket_bounds.len);
        for (bucket_bounds, 0..) |bound, i| {
            buckets[i] = .{
                .le = bound,
                .count = std.atomic.Value(u64).init(0),
            };
        }

        return .{
            .name = name,
            .help = help,
            .buckets = buckets,
            .sum = std.atomic.Value(f64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.buckets);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        _ = self.sum.fetchAdd(value, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);

        for (self.buckets) |*bucket| {
            if (value <= bucket.le) {
                _ = bucket.count.fetchAdd(1, .monotonic);
            }
        }
    }
};

/// Metrics registry
pub const MetricsRegistry = struct {
    metrics: std.StringHashMap(*Metric),
    histograms: std.StringHashMap(*Histogram),
    allocator: Allocator,
    mutex: Mutex,

    // Pre-defined Vexor metrics
    slots_processed: *Metric,
    slot_processing_time: *Histogram,
    transactions_processed: *Metric,
    transactions_failed: *Metric,
    tps_current: *Metric,
    votes_sent: *Metric,
    vote_latency: *Histogram,
    blocks_produced: *Metric,
    gossip_packets_received: *Metric,
    gossip_packets_sent: *Metric,
    turbine_shreds_received: *Metric,
    turbine_shreds_sent: *Metric,
    repair_requests: *Metric,
    rpc_requests: *Metric,
    rpc_latency: *Histogram,
    ws_connections: *Metric,
    ws_subscriptions: *Metric,
    cache_hits: *Metric,
    cache_misses: *Metric,
    cache_size_bytes: *Metric,
    accounts_loaded: *Metric,
    signature_verifications: *Metric,
    poh_verifications: *Metric,
    cluster_nodes: *Metric,
    stake_activated: *Metric,
    cpu_usage_percent: *Metric,
    memory_usage_bytes: *Metric,
    disk_read_bytes: *Metric,
    disk_write_bytes: *Metric,
    uptime_seconds: *Metric,
    current_slot: *Metric,
    root_slot: *Metric,
    confirmed_slot: *Metric,
    leader_slots_total: *Metric,
    skip_rate: *Metric,

    pub fn init(allocator: Allocator) !*MetricsRegistry {
        const registry = try allocator.create(MetricsRegistry);
        registry.* = .{
            .metrics = std.StringHashMap(*Metric).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
            .allocator = allocator,
            .mutex = .{},
            // Initialize all metrics below
            .slots_processed = undefined,
            .slot_processing_time = undefined,
            .transactions_processed = undefined,
            .transactions_failed = undefined,
            .tps_current = undefined,
            .votes_sent = undefined,
            .vote_latency = undefined,
            .blocks_produced = undefined,
            .gossip_packets_received = undefined,
            .gossip_packets_sent = undefined,
            .turbine_shreds_received = undefined,
            .turbine_shreds_sent = undefined,
            .repair_requests = undefined,
            .rpc_requests = undefined,
            .rpc_latency = undefined,
            .ws_connections = undefined,
            .ws_subscriptions = undefined,
            .cache_hits = undefined,
            .cache_misses = undefined,
            .cache_size_bytes = undefined,
            .accounts_loaded = undefined,
            .signature_verifications = undefined,
            .poh_verifications = undefined,
            .cluster_nodes = undefined,
            .stake_activated = undefined,
            .cpu_usage_percent = undefined,
            .memory_usage_bytes = undefined,
            .disk_read_bytes = undefined,
            .disk_write_bytes = undefined,
            .uptime_seconds = undefined,
            .current_slot = undefined,
            .root_slot = undefined,
            .confirmed_slot = undefined,
            .leader_slots_total = undefined,
            .skip_rate = undefined,
        };

        // Register standard metrics
        registry.slots_processed = try registry.registerCounter("vexor_slots_processed_total", "Total slots processed");
        registry.transactions_processed = try registry.registerCounter("vexor_transactions_processed_total", "Total transactions processed");
        registry.transactions_failed = try registry.registerCounter("vexor_transactions_failed_total", "Total failed transactions");
        registry.tps_current = try registry.registerGauge("vexor_tps_current", "Current transactions per second");
        registry.votes_sent = try registry.registerCounter("vexor_votes_sent_total", "Total votes sent");
        registry.blocks_produced = try registry.registerCounter("vexor_blocks_produced_total", "Total blocks produced as leader");
        registry.gossip_packets_received = try registry.registerCounter("vexor_gossip_packets_received_total", "Gossip packets received");
        registry.gossip_packets_sent = try registry.registerCounter("vexor_gossip_packets_sent_total", "Gossip packets sent");
        registry.turbine_shreds_received = try registry.registerCounter("vexor_turbine_shreds_received_total", "Turbine shreds received");
        registry.turbine_shreds_sent = try registry.registerCounter("vexor_turbine_shreds_sent_total", "Turbine shreds sent");
        registry.repair_requests = try registry.registerCounter("vexor_repair_requests_total", "Shred repair requests");
        registry.rpc_requests = try registry.registerCounter("vexor_rpc_requests_total", "RPC requests handled");
        registry.ws_connections = try registry.registerGauge("vexor_websocket_connections", "Active WebSocket connections");
        registry.ws_subscriptions = try registry.registerGauge("vexor_websocket_subscriptions", "Active WebSocket subscriptions");
        registry.cache_hits = try registry.registerCounter("vexor_cache_hits_total", "Cache hits");
        registry.cache_misses = try registry.registerCounter("vexor_cache_misses_total", "Cache misses");
        registry.cache_size_bytes = try registry.registerGauge("vexor_cache_size_bytes", "Cache size in bytes");
        registry.accounts_loaded = try registry.registerCounter("vexor_accounts_loaded_total", "Accounts loaded from storage");
        registry.signature_verifications = try registry.registerCounter("vexor_signature_verifications_total", "Ed25519 signatures verified");
        registry.poh_verifications = try registry.registerCounter("vexor_poh_verifications_total", "PoH hashes verified");
        registry.cluster_nodes = try registry.registerGauge("vexor_cluster_nodes", "Known cluster nodes");
        registry.stake_activated = try registry.registerGauge("vexor_stake_activated_lamports", "Activated stake in lamports");
        registry.cpu_usage_percent = try registry.registerGauge("vexor_cpu_usage_percent", "CPU usage percentage");
        registry.memory_usage_bytes = try registry.registerGauge("vexor_memory_usage_bytes", "Memory usage in bytes");
        registry.disk_read_bytes = try registry.registerCounter("vexor_disk_read_bytes_total", "Disk bytes read");
        registry.disk_write_bytes = try registry.registerCounter("vexor_disk_write_bytes_total", "Disk bytes written");
        registry.uptime_seconds = try registry.registerGauge("vexor_uptime_seconds", "Validator uptime in seconds");
        registry.current_slot = try registry.registerGauge("vexor_current_slot", "Current slot being processed");
        registry.root_slot = try registry.registerGauge("vexor_root_slot", "Current root slot");
        registry.confirmed_slot = try registry.registerGauge("vexor_confirmed_slot", "Latest confirmed slot");
        registry.leader_slots_total = try registry.registerCounter("vexor_leader_slots_total", "Total leader slots assigned");
        registry.skip_rate = try registry.registerGauge("vexor_skip_rate", "Leader slot skip rate");

        // Register histograms
        registry.slot_processing_time = try registry.registerHistogram("vexor_slot_processing_seconds", "Slot processing time", &Histogram.DEFAULT_BUCKETS);
        registry.vote_latency = try registry.registerHistogram("vexor_vote_latency_seconds", "Vote submission latency", &Histogram.DEFAULT_BUCKETS);
        registry.rpc_latency = try registry.registerHistogram("vexor_rpc_latency_seconds", "RPC request latency", &Histogram.DEFAULT_BUCKETS);

        return registry;
    }

    pub fn deinit(self: *MetricsRegistry) void {
        var metric_iter = self.metrics.valueIterator();
        while (metric_iter.next()) |m| {
            self.allocator.destroy(m.*);
        }
        self.metrics.deinit();

        var hist_iter = self.histograms.valueIterator();
        while (hist_iter.next()) |h| {
            h.*.deinit();
            self.allocator.destroy(h.*);
        }
        self.histograms.deinit();

        self.allocator.destroy(self);
    }

    fn registerCounter(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Metric {
        return self.registerMetric(name, help, .counter);
    }

    fn registerGauge(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Metric {
        return self.registerMetric(name, help, .gauge);
    }

    fn registerMetric(self: *MetricsRegistry, name: []const u8, help: []const u8, metric_type: MetricType) !*Metric {
        const metric = try self.allocator.create(Metric);
        metric.* = .{
            .name = name,
            .help = help,
            .metric_type = metric_type,
            .value = std.atomic.Value(f64).init(0),
            .labels = null,
        };
        try self.metrics.put(name, metric);
        return metric;
    }

    fn registerHistogram(self: *MetricsRegistry, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram {
        const hist = try self.allocator.create(Histogram);
        hist.* = try Histogram.init(self.allocator, name, help, buckets);
        try self.histograms.put(name, hist);
        return hist;
    }

    /// Export metrics in Prometheus text format
    pub fn exportPrometheus(self: *MetricsRegistry, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();

        // Export counters and gauges
        var metric_iter = self.metrics.iterator();
        while (metric_iter.next()) |entry| {
            const m = entry.value_ptr.*;
            const type_str = switch (m.metric_type) {
                .counter => "counter",
                .gauge => "gauge",
                else => "untyped",
            };

            try writer.print("# HELP {s} {s}\n", .{ m.name, m.help });
            try writer.print("# TYPE {s} {s}\n", .{ m.name, type_str });
            try writer.print("{s} {d}\n\n", .{ m.name, m.get() });
        }

        // Export histograms
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            const h = entry.value_ptr.*;

            try writer.print("# HELP {s} {s}\n", .{ h.name, h.help });
            try writer.print("# TYPE {s} histogram\n", .{h.name});

            for (h.buckets) |bucket| {
                try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{
                    h.name,
                    bucket.le,
                    bucket.count.load(.acquire),
                });
            }
            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ h.name, h.count.load(.acquire) });
            try writer.print("{s}_sum {d}\n", .{ h.name, h.sum.load(.acquire) });
            try writer.print("{s}_count {d}\n\n", .{ h.name, h.count.load(.acquire) });
        }

        return output.toOwnedSlice();
    }

    /// Export metrics as JSON for custom dashboards
    pub fn exportJson(self: *MetricsRegistry, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();

        try writer.writeAll("{\n  \"metrics\": {\n");

        var first = true;
        var metric_iter = self.metrics.iterator();
        while (metric_iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const m = entry.value_ptr.*;
            try writer.print("    \"{s}\": {d}", .{ m.name, m.get() });
        }

        try writer.writeAll("\n  },\n  \"histograms\": {\n");

        first = true;
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const h = entry.value_ptr.*;
            try writer.print("    \"{s}\": {{\"sum\": {d}, \"count\": {d}}}", .{
                h.name,
                h.sum.load(.acquire),
                h.count.load(.acquire),
            });
        }

        try writer.writeAll("\n  }\n}\n");

        return output.toOwnedSlice();
    }
};

/// Global metrics registry
pub var global_metrics: ?*MetricsRegistry = null;

/// Initialize global metrics
pub fn initMetrics(allocator: Allocator) !void {
    if (global_metrics == null) {
        global_metrics = try MetricsRegistry.init(allocator);
    }
}

/// Get global metrics
pub fn getMetrics() ?*MetricsRegistry {
    return global_metrics;
}

/// Cleanup global metrics (call on shutdown)
pub fn deinitMetrics() void {
    if (global_metrics) |metrics| {
        metrics.deinit();
        global_metrics = null;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "MetricsRegistry: basic counter" {
    const allocator = std.testing.allocator;

    const registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    registry.slots_processed.inc();
    registry.slots_processed.inc();

    try std.testing.expectEqual(@as(f64, 2), registry.slots_processed.get());
}

test "MetricsRegistry: histogram" {
    const allocator = std.testing.allocator;

    const registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    registry.slot_processing_time.observe(0.05);
    registry.slot_processing_time.observe(0.1);
    registry.slot_processing_time.observe(0.5);

    try std.testing.expectEqual(@as(u64, 3), registry.slot_processing_time.count.load(.acquire));
}

test "MetricsRegistry: export prometheus" {
    const allocator = std.testing.allocator;

    const registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    registry.tps_current.set(1000);

    const output = try registry.exportPrometheus(allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "vexor_tps_current") != null);
}

