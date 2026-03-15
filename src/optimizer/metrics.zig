//! Vexor Metrics Module
//!
//! Prometheus-compatible metrics export for monitoring.
//! Exposes validator statistics via HTTP /metrics endpoint.

const std = @import("std");
const core = @import("../core/root.zig");

/// Metric types
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,
};

/// Metric value
pub const MetricValue = union(MetricType) {
    counter: u64,
    gauge: f64,
    histogram: Histogram,
    summary: Summary,
};

/// Histogram bucket
pub const Histogram = struct {
    buckets: []const HistogramBucket,
    sum: f64,
    count: u64,

    pub const HistogramBucket = struct {
        le: f64, // less than or equal
        count: u64,
    };
};

/// Summary quantile
pub const Summary = struct {
    quantiles: []const SummaryQuantile,
    sum: f64,
    count: u64,

    pub const SummaryQuantile = struct {
        quantile: f64,
        value: f64,
    };
};

/// Metric with labels
pub const Metric = struct {
    name: []const u8,
    help: []const u8,
    metric_type: MetricType,
    labels: []const Label,
    value: MetricValue,

    pub const Label = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Metrics registry
pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,

    /// All registered metrics
    metrics: std.StringHashMap(*MetricFamily),

    /// Lock for thread safety
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .metrics = std.StringHashMap(*MetricFamily).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.metrics.valueIterator();
        while (it.next()) |family| {
            self.allocator.destroy(family.*);
        }
        self.metrics.deinit();
    }

    /// Register a counter metric
    pub fn registerCounter(self: *Self, name: []const u8, help: []const u8) !*Counter {
        self.mutex.lock();
        defer self.mutex.unlock();

        const counter = try self.allocator.create(Counter);
        counter.* = .{
            .value = std.atomic.Value(u64).init(0),
        };

        const family = try self.allocator.create(MetricFamily);
        family.* = .{
            .name = name,
            .help = help,
            .metric_type = .counter,
            .data = .{ .counter = counter },
        };

        try self.metrics.put(name, family);
        return counter;
    }

    /// Register a gauge metric
    pub fn registerGauge(self: *Self, name: []const u8, help: []const u8) !*Gauge {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gauge = try self.allocator.create(Gauge);
        gauge.* = .{
            .value = std.atomic.Value(i64).init(0),
        };

        const family = try self.allocator.create(MetricFamily);
        family.* = .{
            .name = name,
            .help = help,
            .metric_type = .gauge,
            .data = .{ .gauge = gauge },
        };

        try self.metrics.put(name, family);
        return gauge;
    }

    /// Export metrics in Prometheus format
    pub fn exportPrometheus(self: *Self, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            const family = entry.value_ptr.*;

            // Write HELP line
            try writer.print("# HELP {s} {s}\n", .{ family.name, family.help });

            // Write TYPE line
            try writer.print("# TYPE {s} {s}\n", .{ family.name, @tagName(family.metric_type) });

            // Write value
            switch (family.data) {
                .counter => |c| {
                    try writer.print("{s} {d}\n", .{ family.name, c.value.load(.seq_cst) });
                },
                .gauge => |g| {
                    try writer.print("{s} {d}\n", .{ family.name, g.value.load(.seq_cst) });
                },
            }

            try writer.writeByte('\n');
        }
    }
};

/// Metric family
pub const MetricFamily = struct {
    name: []const u8,
    help: []const u8,
    metric_type: MetricType,
    data: union(enum) {
        counter: *Counter,
        gauge: *Gauge,
    },
};

/// Counter metric (monotonically increasing)
pub const Counter = struct {
    value: std.atomic.Value(u64),

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .seq_cst);
    }

    pub fn incBy(self: *Counter, amount: u64) void {
        _ = self.value.fetchAdd(amount, .seq_cst);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.seq_cst);
    }
};

/// Gauge metric (can go up or down)
pub const Gauge = struct {
    value: std.atomic.Value(i64),

    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .seq_cst);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .seq_cst);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .seq_cst);
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.seq_cst);
    }
};

/// Validator metrics
pub const ValidatorMetrics = struct {
    registry: MetricsRegistry,

    // Counters
    transactions_processed: *Counter,
    votes_sent: *Counter,
    blocks_produced: *Counter,
    shreds_received: *Counter,
    signatures_verified: *Counter,
    rpc_requests: *Counter,

    // Gauges
    current_slot: *Gauge,
    root_slot: *Gauge,
    cluster_nodes: *Gauge,
    active_stake: *Gauge,
    memory_used_bytes: *Gauge,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var registry = MetricsRegistry.init(allocator);

        return Self{
            .registry = registry,
            .transactions_processed = try registry.registerCounter(
                "vexor_transactions_total",
                "Total number of transactions processed",
            ),
            .votes_sent = try registry.registerCounter(
                "vexor_votes_total",
                "Total number of votes sent",
            ),
            .blocks_produced = try registry.registerCounter(
                "vexor_blocks_produced_total",
                "Total number of blocks produced",
            ),
            .shreds_received = try registry.registerCounter(
                "vexor_shreds_received_total",
                "Total number of shreds received",
            ),
            .signatures_verified = try registry.registerCounter(
                "vexor_signatures_verified_total",
                "Total number of signatures verified",
            ),
            .rpc_requests = try registry.registerCounter(
                "vexor_rpc_requests_total",
                "Total number of RPC requests",
            ),
            .current_slot = try registry.registerGauge(
                "vexor_slot_current",
                "Current slot being processed",
            ),
            .root_slot = try registry.registerGauge(
                "vexor_slot_root",
                "Current root (finalized) slot",
            ),
            .cluster_nodes = try registry.registerGauge(
                "vexor_cluster_nodes",
                "Number of known cluster nodes",
            ),
            .active_stake = try registry.registerGauge(
                "vexor_active_stake_lamports",
                "Total active stake in lamports",
            ),
            .memory_used_bytes = try registry.registerGauge(
                "vexor_memory_used_bytes",
                "Memory used by the validator process",
            ),
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
    }

    /// Export metrics for Prometheus scraping
    pub fn exportMetrics(self: *Self, writer: anytype) !void {
        try self.registry.exportPrometheus(writer);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "counter" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const counter = try registry.registerCounter("test_counter", "A test counter");
    counter.inc();
    counter.incBy(5);

    try std.testing.expectEqual(@as(u64, 6), counter.get());
}

test "gauge" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const gauge = try registry.registerGauge("test_gauge", "A test gauge");
    gauge.set(100);
    gauge.inc();
    gauge.dec();

    try std.testing.expectEqual(@as(i64, 100), gauge.get());
}

test "metrics export" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const counter = try registry.registerCounter("test_counter", "A test counter");
    counter.incBy(42);

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try registry.exportPrometheus(output.writer());

    try std.testing.expect(output.items.len > 0);
}

