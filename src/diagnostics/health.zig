//! Vexor Health Monitoring
//!
//! Continuous health checks for all validator subsystems.
//! Detects issues before they become critical failures.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

/// Health check result
pub const HealthStatus = struct {
    healthy: bool,
    score: u8, // 0-100
    issues: []const HealthIssue,
    last_check_ns: i128,
    checks_run: u32,
    checks_passed: u32,
};

/// Individual health issue
pub const HealthIssue = struct {
    component: root.Component,
    error_code: root.ErrorCode,
    message: []const u8,
    severity: root.Severity,
    metric_value: ?f64,
    threshold: ?f64,
};

/// Threshold configuration for health checks
pub const HealthThresholds = struct {
    // Memory
    memory_usage_warning_pct: f64 = 80.0,
    memory_usage_critical_pct: f64 = 95.0,

    // CPU
    cpu_usage_warning_pct: f64 = 85.0,
    cpu_usage_critical_pct: f64 = 98.0,

    // Disk
    disk_usage_warning_pct: f64 = 80.0,
    disk_usage_critical_pct: f64 = 95.0,
    disk_io_latency_warning_ms: f64 = 50.0,
    disk_io_latency_critical_ms: f64 = 200.0,

    // Network
    packet_loss_warning_pct: f64 = 1.0,
    packet_loss_critical_pct: f64 = 5.0,
    connection_count_min: u32 = 10,
    gossip_peers_min: u32 = 5,

    // Consensus
    poh_drift_warning_ms: f64 = 100.0,
    poh_drift_critical_ms: f64 = 500.0,
    slot_lag_warning: u64 = 10,
    slot_lag_critical: u64 = 50,
    vote_success_rate_min_pct: f64 = 95.0,

    // Performance
    tps_min: f64 = 100.0,
    transaction_latency_warning_ms: f64 = 100.0,
    transaction_latency_critical_ms: f64 = 500.0,
};

/// Health check categories
pub const HealthCheckCategory = enum {
    system_memory,
    system_cpu,
    system_disk,
    network_connectivity,
    network_gossip,
    consensus_poh,
    consensus_voting,
    consensus_slot,
    storage_ledger,
    storage_accounts,
    performance_tps,
};

/// Health monitor state
pub const HealthMonitor = struct {
    allocator: Allocator,
    thresholds: HealthThresholds,
    current_status: HealthStatus,
    issues_buffer: [64]HealthIssue,
    issue_count: usize,

    // Metrics collectors (function pointers for extensibility)
    metric_collectors: MetricCollectors,

    const Self = @This();

    pub const MetricCollectors = struct {
        get_memory_usage: ?*const fn () f64 = null,
        get_cpu_usage: ?*const fn () f64 = null,
        get_disk_usage: ?*const fn () f64 = null,
        get_peer_count: ?*const fn () u32 = null,
        get_current_slot: ?*const fn () u64 = null,
        get_cluster_slot: ?*const fn () u64 = null,
        get_poh_drift_ms: ?*const fn () f64 = null,
        get_vote_success_rate: ?*const fn () f64 = null,
        get_tps: ?*const fn () f64 = null,
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .thresholds = HealthThresholds{},
            .current_status = HealthStatus{
                .healthy = true,
                .score = 100,
                .issues = &[_]HealthIssue{},
                .last_check_ns = 0,
                .checks_run = 0,
                .checks_passed = 0,
            },
            .issues_buffer = undefined,
            .issue_count = 0,
            .metric_collectors = MetricCollectors{},
        };
    }

    /// Register custom metric collector
    pub fn registerCollector(self: *Self, comptime field: []const u8, collector: anytype) void {
        @field(self.metric_collectors, field) = collector;
    }

    /// Run all health checks
    pub fn runChecks(self: *Self) HealthStatus {
        self.issue_count = 0;
        var checks_run: u32 = 0;
        var checks_passed: u32 = 0;
        var total_score: u32 = 0;

        // System checks
        const mem_result = self.checkMemory();
        checks_run += 1;
        if (mem_result.passed) checks_passed += 1;
        total_score += mem_result.score;

        const cpu_result = self.checkCPU();
        checks_run += 1;
        if (cpu_result.passed) checks_passed += 1;
        total_score += cpu_result.score;

        const disk_result = self.checkDisk();
        checks_run += 1;
        if (disk_result.passed) checks_passed += 1;
        total_score += disk_result.score;

        // Network checks
        const network_result = self.checkNetwork();
        checks_run += 1;
        if (network_result.passed) checks_passed += 1;
        total_score += network_result.score;

        // Consensus checks
        const consensus_result = self.checkConsensus();
        checks_run += 1;
        if (consensus_result.passed) checks_passed += 1;
        total_score += consensus_result.score;

        // Calculate overall health
        const avg_score: u8 = if (checks_run > 0)
            @intCast(total_score / checks_run)
        else
            100;

        self.current_status = HealthStatus{
            .healthy = self.issue_count == 0 or avg_score >= 70,
            .score = avg_score,
            .issues = self.issues_buffer[0..self.issue_count],
            .last_check_ns = std.time.nanoTimestamp(),
            .checks_run = checks_run,
            .checks_passed = checks_passed,
        };

        return self.current_status;
    }

    /// Get current status without running checks
    pub fn getCurrentStatus(self: *Self) HealthStatus {
        return self.current_status;
    }

    const CheckResult = struct {
        passed: bool,
        score: u32,
    };

    fn checkMemory(self: *Self) CheckResult {
        const usage = if (self.metric_collectors.get_memory_usage) |f|
            f()
        else
            getSystemMemoryUsage();

        if (usage >= self.thresholds.memory_usage_critical_pct) {
            self.addIssue(.{
                .component = .system_memory,
                .error_code = .memory_pressure,
                .message = "Memory usage critical",
                .severity = .critical,
                .metric_value = usage,
                .threshold = self.thresholds.memory_usage_critical_pct,
            });
            return .{ .passed = false, .score = 20 };
        } else if (usage >= self.thresholds.memory_usage_warning_pct) {
            self.addIssue(.{
                .component = .system_memory,
                .error_code = .memory_pressure,
                .message = "Memory usage high",
                .severity = .warning,
                .metric_value = usage,
                .threshold = self.thresholds.memory_usage_warning_pct,
            });
            return .{ .passed = true, .score = 60 };
        }

        return .{ .passed = true, .score = 100 };
    }

    fn checkCPU(self: *Self) CheckResult {
        const usage = if (self.metric_collectors.get_cpu_usage) |f|
            f()
        else
            getSystemCPUUsage();

        if (usage >= self.thresholds.cpu_usage_critical_pct) {
            self.addIssue(.{
                .component = .system_cpu,
                .error_code = .internal_error,
                .message = "CPU usage critical",
                .severity = .critical,
                .metric_value = usage,
                .threshold = self.thresholds.cpu_usage_critical_pct,
            });
            return .{ .passed = false, .score = 20 };
        } else if (usage >= self.thresholds.cpu_usage_warning_pct) {
            self.addIssue(.{
                .component = .system_cpu,
                .error_code = .internal_error,
                .message = "CPU usage high",
                .severity = .warning,
                .metric_value = usage,
                .threshold = self.thresholds.cpu_usage_warning_pct,
            });
            return .{ .passed = true, .score = 60 };
        }

        return .{ .passed = true, .score = 100 };
    }

    fn checkDisk(self: *Self) CheckResult {
        const usage = if (self.metric_collectors.get_disk_usage) |f|
            f()
        else
            getSystemDiskUsage();

        if (usage >= self.thresholds.disk_usage_critical_pct) {
            self.addIssue(.{
                .component = .system_disk,
                .error_code = .disk_full,
                .message = "Disk usage critical",
                .severity = .critical,
                .metric_value = usage,
                .threshold = self.thresholds.disk_usage_critical_pct,
            });
            return .{ .passed = false, .score = 10 };
        } else if (usage >= self.thresholds.disk_usage_warning_pct) {
            self.addIssue(.{
                .component = .system_disk,
                .error_code = .disk_full,
                .message = "Disk usage high",
                .severity = .warning,
                .metric_value = usage,
                .threshold = self.thresholds.disk_usage_warning_pct,
            });
            return .{ .passed = true, .score = 50 };
        }

        return .{ .passed = true, .score = 100 };
    }

    fn checkNetwork(self: *Self) CheckResult {
        const peers = if (self.metric_collectors.get_peer_count) |f|
            f()
        else
            0; // No collector = assume unknown

        if (peers < self.thresholds.gossip_peers_min) {
            self.addIssue(.{
                .component = .network_gossip,
                .error_code = .network_unreachable,
                .message = "Insufficient gossip peers",
                .severity = if (peers == 0) .critical else .warning,
                .metric_value = @floatFromInt(peers),
                .threshold = @floatFromInt(self.thresholds.gossip_peers_min),
            });
            return .{ .passed = peers > 0, .score = if (peers == 0) 0 else 50 };
        }

        return .{ .passed = true, .score = 100 };
    }

    fn checkConsensus(self: *Self) CheckResult {
        // Check slot lag
        if (self.metric_collectors.get_current_slot != null and
            self.metric_collectors.get_cluster_slot != null)
        {
            const our_slot = self.metric_collectors.get_current_slot.?();
            const cluster_slot = self.metric_collectors.get_cluster_slot.?();

            if (cluster_slot > our_slot) {
                const lag = cluster_slot - our_slot;
                if (lag >= self.thresholds.slot_lag_critical) {
                    self.addIssue(.{
                        .component = .consensus_tower,
                        .error_code = .slot_skipped,
                        .message = "Slot lag critical - falling behind cluster",
                        .severity = .critical,
                        .metric_value = @floatFromInt(lag),
                        .threshold = @floatFromInt(self.thresholds.slot_lag_critical),
                    });
                    return .{ .passed = false, .score = 20 };
                } else if (lag >= self.thresholds.slot_lag_warning) {
                    self.addIssue(.{
                        .component = .consensus_tower,
                        .error_code = .slot_skipped,
                        .message = "Slot lag warning",
                        .severity = .warning,
                        .metric_value = @floatFromInt(lag),
                        .threshold = @floatFromInt(self.thresholds.slot_lag_warning),
                    });
                    return .{ .passed = true, .score = 70 };
                }
            }
        }

        // Check PoH drift
        if (self.metric_collectors.get_poh_drift_ms) |f| {
            const drift = f();
            if (drift >= self.thresholds.poh_drift_critical_ms) {
                self.addIssue(.{
                    .component = .consensus_poh,
                    .error_code = .poh_drift,
                    .message = "PoH clock drift critical",
                    .severity = .critical,
                    .metric_value = drift,
                    .threshold = self.thresholds.poh_drift_critical_ms,
                });
                return .{ .passed = false, .score = 30 };
            } else if (drift >= self.thresholds.poh_drift_warning_ms) {
                self.addIssue(.{
                    .component = .consensus_poh,
                    .error_code = .poh_drift,
                    .message = "PoH clock drift detected",
                    .severity = .warning,
                    .metric_value = drift,
                    .threshold = self.thresholds.poh_drift_warning_ms,
                });
                return .{ .passed = true, .score = 70 };
            }
        }

        return .{ .passed = true, .score = 100 };
    }

    fn addIssue(self: *Self, issue: HealthIssue) void {
        if (self.issue_count < self.issues_buffer.len) {
            self.issues_buffer[self.issue_count] = issue;
            self.issue_count += 1;
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SYSTEM METRICS (Linux-specific)
// ═══════════════════════════════════════════════════════════════════════════

fn getSystemMemoryUsage() f64 {
    // Read /proc/meminfo
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.read(&buf) catch return 0;
    const content = buf[0..bytes_read];

    var total: u64 = 0;
    var available: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total = parseMemValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available = parseMemValue(line);
        }
    }

    if (total == 0) return 0;
    const used = total - available;
    return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total)) * 100.0;
}

fn parseMemValue(line: []const u8) u64 {
    // Format: "MemTotal:       16384000 kB"
    var it = std.mem.tokenizeAny(u8, line, ": \t");
    _ = it.next(); // Skip label
    if (it.next()) |val| {
        return std.fmt.parseInt(u64, val, 10) catch 0;
    }
    return 0;
}

fn getSystemCPUUsage() f64 {
    // Read /proc/stat - this gives cumulative values
    // For accurate usage, would need to sample twice
    // For now, return a placeholder
    return 0; // Would need stateful sampling
}

fn getSystemDiskUsage() f64 {
    // Use statfs on root partition
    // Placeholder - would use std.os.linux.statfs
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "health monitor basic" {
    const allocator = std.testing.allocator;
    var monitor = HealthMonitor.init(allocator);

    const status = monitor.runChecks();
    try std.testing.expect(status.checks_run > 0);
}

test "health thresholds" {
    const thresholds = HealthThresholds{};
    try std.testing.expect(thresholds.memory_usage_warning_pct < thresholds.memory_usage_critical_pct);
    try std.testing.expect(thresholds.disk_usage_warning_pct < thresholds.disk_usage_critical_pct);
}

