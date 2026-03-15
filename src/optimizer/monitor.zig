//! Vexor Performance Monitor
//!
//! Real-time performance monitoring and metrics collection.

const std = @import("std");

/// Performance metrics snapshot
pub const Metrics = struct {
    timestamp_ns: i128,
    
    // CPU metrics
    cpu_user_percent: f32,
    cpu_system_percent: f32,
    cpu_idle_percent: f32,
    
    // Memory metrics
    memory_used_bytes: u64,
    memory_cached_bytes: u64,
    
    // Network metrics
    packets_received: u64,
    packets_sent: u64,
    bytes_received: u64,
    bytes_sent: u64,
    
    // Validator-specific metrics
    slots_processed: u64,
    transactions_processed: u64,
    signatures_verified: u64,
    votes_sent: u64,
    
    pub fn init() Metrics {
        return .{
            .timestamp_ns = std.time.nanoTimestamp(),
            .cpu_user_percent = 0,
            .cpu_system_percent = 0,
            .cpu_idle_percent = 100,
            .memory_used_bytes = 0,
            .memory_cached_bytes = 0,
            .packets_received = 0,
            .packets_sent = 0,
            .bytes_received = 0,
            .bytes_sent = 0,
            .slots_processed = 0,
            .transactions_processed = 0,
            .signatures_verified = 0,
            .votes_sent = 0,
        };
    }
};

/// Performance monitor
pub const Monitor = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(Metrics),
    max_history: usize,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .history = std.ArrayList(Metrics).init(allocator),
            .max_history = 3600, // Keep 1 hour at 1 sample/sec
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.history.deinit();
    }
    
    /// Collect current metrics
    pub fn collect(self: *Self) !Metrics {
        const metrics = Metrics.init();
        
        // TODO: Collect actual system metrics
        
        // Store in history
        if (self.history.items.len >= self.max_history) {
            _ = self.history.orderedRemove(0);
        }
        try self.history.append(metrics);
        
        return metrics;
    }
    
    /// Get average metrics over a time window
    pub fn average(self: *const Self, window_samples: usize) Metrics {
        if (self.history.items.len == 0) return Metrics.init();
        
        const samples = @min(window_samples, self.history.items.len);
        const start = self.history.items.len - samples;
        
        // Accumulate values
        var cpu_user_sum: f32 = 0;
        var cpu_sys_sum: f32 = 0;
        var tx_sum: u64 = 0;
        
        for (self.history.items[start..]) |m| {
            cpu_user_sum += m.cpu_user_percent;
            cpu_sys_sum += m.cpu_system_percent;
            tx_sum += m.transactions_processed;
        }
        
        const n = @as(f32, @floatFromInt(samples));
        
        var avg = Metrics.init();
        avg.cpu_user_percent = cpu_user_sum / n;
        avg.cpu_system_percent = cpu_sys_sum / n;
        avg.transactions_processed = tx_sum / samples;
        
        return avg;
    }
};

/// Prometheus-compatible metrics exporter
pub const PrometheusExporter = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Format metrics in Prometheus exposition format
    pub fn format(self: *Self, metrics: *const Metrics) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\# HELP vexor_cpu_user_percent CPU user time percentage
            \\# TYPE vexor_cpu_user_percent gauge
            \\vexor_cpu_user_percent {d:.2}
            \\# HELP vexor_transactions_total Total transactions processed
            \\# TYPE vexor_transactions_total counter
            \\vexor_transactions_total {d}
            \\# HELP vexor_signatures_total Total signatures verified
            \\# TYPE vexor_signatures_total counter
            \\vexor_signatures_total {d}
            \\
        , .{
            metrics.cpu_user_percent,
            metrics.transactions_processed,
            metrics.signatures_verified,
        });
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "metrics init" {
    const m = Metrics.init();
    try std.testing.expectEqual(@as(f32, 100), m.cpu_idle_percent);
}

test "monitor collect" {
    var monitor = Monitor.init(std.testing.allocator);
    defer monitor.deinit();
    
    _ = try monitor.collect();
    try std.testing.expectEqual(@as(usize, 1), monitor.history.items.len);
}

