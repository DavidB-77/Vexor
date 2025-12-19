//! Vexor Diagnostics Engine
//!
//! Self-monitoring, error collection, and auto-remediation system.
//! This module provides live auditing of validator health and can
//! automatically address common failure modes.
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                    Diagnostics Engine                           │
//! ├─────────────────────────────────────────────────────────────────┤
//! │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
//! │  │   Health    │  │   Audit     │  │     Remediation         │ │
//! │  │   Monitor   │──│   Logger    │──│     Engine              │ │
//! │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
//! │         │                │                    │                 │
//! │         ▼                ▼                    ▼                 │
//! │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
//! │  │  Metrics    │  │  Error DB   │  │   Action Queue          │ │
//! │  │  Collector  │  │  (Ring buf) │  │   (Priority heap)       │ │
//! │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
//! │                          │                                      │
//! │                          ▼                                      │
//! │              ┌─────────────────────────┐                       │
//! │              │   LLM Bridge (Future)   │                       │
//! │              │   AI-assisted analysis  │                       │
//! │              └─────────────────────────┘                       │
//! └─────────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

pub const health = @import("health.zig");
pub const audit = @import("audit.zig");
pub const remediation = @import("remediation.zig");
pub const llm_bridge = @import("llm_bridge.zig");

// Testing and profiling infrastructure
pub const testing = @import("testing.zig");
pub const metrics = @import("metrics.zig");
pub const dashboard_stream = @import("dashboard_stream.zig");
pub const influx_reporter = @import("influx_reporter.zig");

// InfluxDB reporter types (Solana Foundation compatible)
pub const InfluxReporter = influx_reporter.InfluxReporter;
pub const InfluxConfig = influx_reporter.InfluxConfig;

// Testing types
pub const TestConfig = testing.TestConfig;
pub const FeatureFlags = testing.FeatureFlags;
pub const FaultInjector = testing.FaultInjector;
pub const Profiler = testing.Profiler;
pub const MockGenerator = testing.MockGenerator;
pub const TestIndicator = testing.TestIndicator;

// Metrics types
pub const MetricsRegistry = metrics.MetricsRegistry;
pub const Metric = metrics.Metric;
pub const Histogram = metrics.Histogram;

// Dashboard types
pub const DashboardStreamServer = dashboard_stream.DashboardStreamServer;
pub const MetricsSnapshot = dashboard_stream.MetricsSnapshot;
pub const DashboardConfig = dashboard_stream.DashboardConfig;

/// Global diagnostics instance (singleton for validator-wide access)
var global_diagnostics: ?*DiagnosticsEngine = null;
var global_mutex: Mutex = .{};

/// Severity levels for diagnostic events
pub const Severity = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warning = 3,
    @"error" = 4,
    critical = 5,
    fatal = 6,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warning => "WARN",
            .@"error" => "ERROR",
            .critical => "CRIT",
            .fatal => "FATAL",
        };
    }

    pub fn toColor(self: Severity) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // gray
            .debug => "\x1b[36m", // cyan
            .info => "\x1b[32m", // green
            .warning => "\x1b[33m", // yellow
            .@"error" => "\x1b[31m", // red
            .critical => "\x1b[35m", // magenta
            .fatal => "\x1b[41m", // red background
        };
    }
};

/// Component identifiers for error categorization
pub const Component = enum(u16) {
    // Core
    core_init = 0x0100,
    core_config = 0x0101,
    core_keypair = 0x0102,

    // Network
    network_socket = 0x0200,
    network_gossip = 0x0201,
    network_tpu = 0x0202,
    network_tvu = 0x0203,
    network_repair = 0x0204,
    network_quic = 0x0205,

    // Consensus
    consensus_tower = 0x0300,
    consensus_poh = 0x0301,
    consensus_vote = 0x0302,
    consensus_leader = 0x0303,

    // Runtime
    runtime_bank = 0x0400,
    runtime_accounts = 0x0401,
    runtime_ledger = 0x0402,
    runtime_entry = 0x0403,
    runtime_transaction = 0x0404,

    // Storage
    storage_snapshot = 0x0500,
    storage_ramdisk = 0x0501,
    storage_nvme = 0x0502,
    storage_compaction = 0x0503,

    // System
    system_memory = 0x0600,
    system_cpu = 0x0601,
    system_disk = 0x0602,
    system_network = 0x0603,

    // Diagnostics (meta)
    diagnostics = 0x0700,

    pub fn toString(self: Component) []const u8 {
        return @tagName(self);
    }

    pub fn category(self: Component) []const u8 {
        const code = @intFromEnum(self);
        return switch (code >> 8) {
            0x01 => "CORE",
            0x02 => "NETWORK",
            0x03 => "CONSENSUS",
            0x04 => "RUNTIME",
            0x05 => "STORAGE",
            0x06 => "SYSTEM",
            0x07 => "DIAGNOSTICS",
            else => "UNKNOWN",
        };
    }
};

/// Error codes with semantic meaning for auto-remediation
pub const ErrorCode = enum(u32) {
    // Success
    ok = 0,

    // Network errors (1xxx)
    network_unreachable = 1001,
    connection_refused = 1002,
    connection_timeout = 1003,
    socket_bind_failed = 1004,
    packet_too_large = 1005,
    gossip_peer_rejected = 1006,
    quic_handshake_failed = 1007,

    // Consensus errors (2xxx)
    fork_detected = 2001,
    vote_failed = 2002,
    poh_drift = 2003,
    slot_skipped = 2004,
    leader_timeout = 2005,
    lockout_violation = 2006,

    // Storage errors (3xxx)
    disk_full = 3001,
    io_error = 3002,
    corruption_detected = 3003,
    snapshot_invalid = 3004,
    ledger_mismatch = 3005,
    compaction_failed = 3006,

    // Memory errors (4xxx)
    out_of_memory = 4001,
    memory_pressure = 4002,
    allocation_failed = 4003,
    cache_full = 4004,

    // Config errors (5xxx)
    invalid_config = 5001,
    missing_keypair = 5002,
    invalid_entrypoint = 5003,

    // Internal errors (9xxx)
    internal_error = 9001,
    assertion_failed = 9002,
    unknown_error = 9999,

    pub fn isRecoverable(self: ErrorCode) bool {
        return switch (self) {
            .ok => true,
            // Network issues are usually transient
            .network_unreachable, .connection_refused, .connection_timeout => true,
            .gossip_peer_rejected, .quic_handshake_failed => true,
            // Some consensus issues can recover
            .slot_skipped, .leader_timeout => true,
            // Memory pressure can be addressed
            .memory_pressure, .cache_full => true,
            // Storage can sometimes recover
            .compaction_failed => true,
            // These are not easily recoverable
            .disk_full, .corruption_detected, .out_of_memory => false,
            .lockout_violation, .snapshot_invalid => false,
            .internal_error, .assertion_failed, .unknown_error => false,
            else => false,
        };
    }

    pub fn suggestedAction(self: ErrorCode) remediation.ActionType {
        return switch (self) {
            .network_unreachable, .connection_refused => .reconnect,
            .connection_timeout => .retry_with_backoff,
            .gossip_peer_rejected => .rotate_peers,
            .memory_pressure, .cache_full => .evict_cache,
            .disk_full => .cleanup_old_data,
            .compaction_failed => .force_compaction,
            .poh_drift => .resync_clock,
            else => .log_and_alert,
        };
    }
};

/// Diagnostic event with full context
pub const DiagnosticEvent = struct {
    timestamp_ns: i128,
    severity: Severity,
    component: Component,
    error_code: ErrorCode,
    message: []const u8,
    context: ?[]const u8,
    stack_trace: ?[]const u8,
    correlation_id: u64,
    slot: ?u64,
    remediation_attempted: bool,
    remediation_succeeded: bool,

    pub fn format(self: *const DiagnosticEvent, allocator: Allocator) ![]u8 {
        const time_sec = @as(i64, @intCast(@divTrunc(self.timestamp_ns, 1_000_000_000)));
        _ = time_sec;

        return try std.fmt.allocPrint(allocator, "[{s}] {s}/{s} ({d}): {s}{s}", .{
            self.severity.toString(),
            self.component.category(),
            self.component.toString(),
            @intFromEnum(self.error_code),
            self.message,
            if (self.context) |ctx| ctx else "",
        });
    }
};

/// Configuration for the diagnostics engine
pub const DiagnosticsConfig = struct {
    /// Minimum severity to log
    min_severity: Severity = .info,
    /// Maximum events to keep in memory
    max_events: usize = 10_000,
    /// Enable automatic remediation
    auto_remediate: bool = true,
    /// Health check interval in milliseconds
    health_check_interval_ms: u64 = 5_000,
    /// Enable LLM-assisted diagnostics (future)
    enable_llm_assist: bool = false,
    /// Path to write audit log
    audit_log_path: ?[]const u8 = null,
    /// Enable console output
    console_output: bool = true,
    /// Enable colored output
    colored_output: bool = true,
    /// Alert webhook URL (optional)
    alert_webhook: ?[]const u8 = null,
    /// Maximum remediation attempts per error
    max_remediation_attempts: u32 = 3,
};

/// Main diagnostics engine
pub const DiagnosticsEngine = struct {
    allocator: Allocator,
    config: DiagnosticsConfig,

    // Event storage (ring buffer)
    events: []DiagnosticEvent,
    event_write_idx: Atomic(usize),
    event_count: Atomic(usize),

    // Health monitoring
    health_monitor: health.HealthMonitor,

    // Audit logger
    audit_logger: audit.AuditLogger,

    // Remediation engine
    remediation_engine: remediation.RemediationEngine,

    // LLM bridge (placeholder)
    llm: llm_bridge.LLMBridge,

    // Statistics
    stats: DiagnosticsStats,

    // State
    running: Atomic(bool),
    health_thread: ?Thread,

    const Self = @This();

    pub fn init(allocator: Allocator, config: DiagnosticsConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Allocate event ring buffer
        const events = try allocator.alloc(DiagnosticEvent, config.max_events);
        errdefer allocator.free(events);

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .events = events,
            .event_write_idx = Atomic(usize).init(0),
            .event_count = Atomic(usize).init(0),
            .health_monitor = health.HealthMonitor.init(allocator),
            .audit_logger = try audit.AuditLogger.init(allocator, config.audit_log_path),
            .remediation_engine = remediation.RemediationEngine.init(allocator, config.max_remediation_attempts),
            .llm = llm_bridge.LLMBridge.init(allocator, config.enable_llm_assist),
            .stats = DiagnosticsStats{},
            .running = Atomic(bool).init(false),
            .health_thread = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.audit_logger.deinit();
        self.allocator.free(self.events);
        self.allocator.destroy(self);
    }

    /// Start the diagnostics engine
    pub fn start(self: *Self) !void {
        if (self.running.swap(true, .seq_cst)) {
            return; // Already running
        }

        self.logInternal(.info, .diagnostics, .ok, "Diagnostics engine starting", null);

        // Start health monitoring thread
        self.health_thread = try Thread.spawn(.{}, healthMonitorLoop, .{self});
    }

    /// Stop the diagnostics engine
    pub fn stop(self: *Self) void {
        if (!self.running.swap(false, .seq_cst)) {
            return; // Already stopped
        }

        if (self.health_thread) |thread| {
            thread.join();
            self.health_thread = null;
        }

        self.logInternal(.info, .diagnostics, .ok, "Diagnostics engine stopped", null);
    }

    /// Log a diagnostic event
    pub fn log(
        self: *Self,
        severity: Severity,
        component: Component,
        error_code: ErrorCode,
        message: []const u8,
        context: ?[]const u8,
    ) void {
        self.logInternal(severity, component, error_code, message, context);
    }

    fn logInternal(
        self: *Self,
        severity: Severity,
        component: Component,
        error_code: ErrorCode,
        message: []const u8,
        context: ?[]const u8,
    ) void {
        // Check severity filter
        if (@intFromEnum(severity) < @intFromEnum(self.config.min_severity)) {
            return;
        }

        const timestamp = std.time.nanoTimestamp();
        const correlation_id = generateCorrelationId();

        const event = DiagnosticEvent{
            .timestamp_ns = timestamp,
            .severity = severity,
            .component = component,
            .error_code = error_code,
            .message = message,
            .context = context,
            .stack_trace = null,
            .correlation_id = correlation_id,
            .slot = null,
            .remediation_attempted = false,
            .remediation_succeeded = false,
        };

        // Store in ring buffer
        self.storeEvent(event);

        // Update stats
        self.updateStats(severity);

        // Write to audit log
        self.audit_logger.logEvent(&event);

        // Console output
        if (self.config.console_output) {
            self.printEvent(&event);
        }

        // Auto-remediation for errors
        if (self.config.auto_remediate and
            @intFromEnum(severity) >= @intFromEnum(Severity.@"error") and
            error_code.isRecoverable())
        {
            self.attemptRemediation(error_code, component, correlation_id);
        }

        // Critical/Fatal alerts
        if (@intFromEnum(severity) >= @intFromEnum(Severity.critical)) {
            self.sendAlert(&event);
        }
    }

    fn storeEvent(self: *Self, event: DiagnosticEvent) void {
        const idx = self.event_write_idx.fetchAdd(1, .seq_cst) % self.config.max_events;
        self.events[idx] = event;
        _ = self.event_count.fetchAdd(1, .seq_cst);
    }

    fn updateStats(self: *Self, severity: Severity) void {
        self.stats.total_events += 1;
        switch (severity) {
            .trace, .debug => self.stats.debug_count += 1,
            .info => self.stats.info_count += 1,
            .warning => self.stats.warning_count += 1,
            .@"error" => self.stats.error_count += 1,
            .critical, .fatal => self.stats.critical_count += 1,
        }
    }

    fn printEvent(self: *Self, event: *const DiagnosticEvent) void {
        const writer = std.io.getStdErr().writer();
        const reset = "\x1b[0m";

        if (self.config.colored_output) {
            writer.print("{s}[{s}]{s} ", .{
                event.severity.toColor(),
                event.severity.toString(),
                reset,
            }) catch return;
        } else {
            writer.print("[{s}] ", .{event.severity.toString()}) catch return;
        }

        writer.print("{s}/{s}: {s}", .{
            event.component.category(),
            event.component.toString(),
            event.message,
        }) catch return;

        if (event.context) |ctx| {
            writer.print(" | {s}", .{ctx}) catch return;
        }

        writer.print("\n", .{}) catch return;
    }

    fn attemptRemediation(self: *Self, error_code: ErrorCode, component: Component, correlation_id: u64) void {
        const action = error_code.suggestedAction();

        self.logInternal(
            .info,
            .diagnostics,
            .ok,
            "Attempting auto-remediation",
            @tagName(action),
        );

        const success = self.remediation_engine.execute(action, component, correlation_id);

        if (success) {
            self.stats.remediations_succeeded += 1;
            self.logInternal(.info, .diagnostics, .ok, "Remediation succeeded", null);
        } else {
            self.stats.remediations_failed += 1;
            self.logInternal(.warning, .diagnostics, .ok, "Remediation failed", null);
        }
    }

    fn sendAlert(self: *Self, event: *const DiagnosticEvent) void {
        _ = event;
        // Placeholder for webhook/alerting integration
        if (self.config.alert_webhook) |_| {
            // Would send HTTP POST to webhook
            self.stats.alerts_sent += 1;
        }
    }

    fn healthMonitorLoop(self: *Self) void {
        while (self.running.load(.seq_cst)) {
            // Run health checks
            const health_status = self.health_monitor.runChecks();

            if (!health_status.healthy) {
                for (health_status.issues) |issue| {
                    self.log(
                        .warning,
                        issue.component,
                        issue.error_code,
                        issue.message,
                        null,
                    );
                }
            }

            // Sleep until next check
            const sleep_ns: u64 = @as(u64, self.config.health_check_interval_ms) * std.time.ns_per_ms;
            std.time.sleep(sleep_ns);
        }
    }

    /// Get recent events matching criteria
    pub fn queryEvents(
        self: *Self,
        min_severity: ?Severity,
        component: ?Component,
        max_results: usize,
    ) []const DiagnosticEvent {
        var results: [1000]DiagnosticEvent = undefined;
        var count: usize = 0;
        const total = @min(self.event_count.load(.seq_cst), self.config.max_events);

        var i: usize = 0;
        while (i < total and count < max_results and count < 1000) : (i += 1) {
            const idx = (self.event_write_idx.load(.seq_cst) - 1 - i) % self.config.max_events;
            const event = self.events[idx];

            const severity_match = min_severity == null or
                @intFromEnum(event.severity) >= @intFromEnum(min_severity.?);
            const component_match = component == null or event.component == component.?;

            if (severity_match and component_match) {
                results[count] = event;
                count += 1;
            }
        }

        return results[0..count];
    }

    /// Get current health status
    pub fn getHealthStatus(self: *Self) health.HealthStatus {
        return self.health_monitor.getCurrentStatus();
    }

    /// Get diagnostic statistics
    pub fn getStats(self: *Self) DiagnosticsStats {
        return self.stats;
    }

    /// Request LLM analysis of recent errors (future)
    pub fn requestLLMAnalysis(self: *Self, query: []const u8) ![]const u8 {
        return self.llm.analyze(query, self.queryEvents(.@"error", null, 100));
    }
};

/// Statistics tracked by diagnostics
pub const DiagnosticsStats = struct {
    total_events: u64 = 0,
    debug_count: u64 = 0,
    info_count: u64 = 0,
    warning_count: u64 = 0,
    error_count: u64 = 0,
    critical_count: u64 = 0,
    remediations_attempted: u64 = 0,
    remediations_succeeded: u64 = 0,
    remediations_failed: u64 = 0,
    alerts_sent: u64 = 0,
};

/// Generate unique correlation ID
fn generateCorrelationId() u64 {
    const timestamp: u64 = @intCast(@as(i64, @truncate(std.time.nanoTimestamp())));
    var prng = std.Random.DefaultPrng.init(timestamp);
    return prng.random().int(u64);
}

// ═══════════════════════════════════════════════════════════════════════════
// GLOBAL ACCESS API
// ═══════════════════════════════════════════════════════════════════════════

/// Initialize global diagnostics (call once at startup)
pub fn initGlobal(allocator: Allocator, config: DiagnosticsConfig) !void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_diagnostics != null) {
        return error.AlreadyInitialized;
    }

    global_diagnostics = try DiagnosticsEngine.init(allocator, config);
    try global_diagnostics.?.start();
}

/// Shutdown global diagnostics
pub fn deinitGlobal() void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_diagnostics) |diag| {
        diag.deinit();
        global_diagnostics = null;
    }
}

/// Log an event to global diagnostics
pub fn log(
    severity: Severity,
    component: Component,
    error_code: ErrorCode,
    message: []const u8,
    context: ?[]const u8,
) void {
    if (global_diagnostics) |diag| {
        diag.log(severity, component, error_code, message, context);
    }
}

/// Convenience functions
pub fn logError(component: Component, code: ErrorCode, message: []const u8) void {
    log(.@"error", component, code, message, null);
}

pub fn logWarning(component: Component, message: []const u8) void {
    log(.warning, component, .ok, message, null);
}

pub fn logInfo(component: Component, message: []const u8) void {
    log(.info, component, .ok, message, null);
}

pub fn logDebug(component: Component, message: []const u8) void {
    log(.debug, component, .ok, message, null);
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "diagnostics engine basic" {
    const allocator = std.testing.allocator;

    const config = DiagnosticsConfig{
        .console_output = false,
        .auto_remediate = false,
    };

    const engine = try DiagnosticsEngine.init(allocator, config);
    defer engine.deinit();

    engine.log(.info, .core_init, .ok, "Test message", null);
    engine.log(.@"error", .network_socket, .connection_refused, "Connection failed", "peer=1.2.3.4:8001");

    const stats = engine.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.total_events);
    try std.testing.expectEqual(@as(u64, 1), stats.info_count);
    try std.testing.expectEqual(@as(u64, 1), stats.error_count);
}

test "error code properties" {
    try std.testing.expect(ErrorCode.connection_timeout.isRecoverable());
    try std.testing.expect(!ErrorCode.disk_full.isRecoverable());
    try std.testing.expectEqual(remediation.ActionType.reconnect, ErrorCode.network_unreachable.suggestedAction());
}

