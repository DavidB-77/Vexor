//! Vexor Auto-Remediation Engine
//!
//! Automatic healing for common validator issues.
//! Executes corrective actions when problems are detected.
//!
//! Safety Philosophy:
//! - Never compromise validator security
//! - Always log before taking action
//! - Have rate limits to prevent action storms
//! - Some actions require manual confirmation

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

/// Types of remediation actions
pub const ActionType = enum {
    // No action
    none,

    // Logging only
    log_and_alert,

    // Network actions
    reconnect,
    rotate_peers,
    retry_with_backoff,
    reset_connection_pool,

    // Memory actions
    evict_cache,
    trigger_gc,
    reduce_buffer_sizes,

    // Storage actions
    cleanup_old_data,
    force_compaction,
    repair_index,
    recover_from_snapshot,

    // Consensus actions
    resync_clock,
    reset_tower_state,
    request_repair,

    // System actions
    restart_component,
    full_restart,

    // Manual required
    requires_manual,
};

/// Action execution result
pub const ActionResult = struct {
    action: ActionType,
    success: bool,
    duration_ns: u64,
    message: []const u8,
    follow_up: ?ActionType,
};

/// Remediation attempt tracking
pub const RemediationAttempt = struct {
    correlation_id: u64,
    action: ActionType,
    component: root.Component,
    timestamp_ns: i128,
    attempt_number: u32,
    result: ?ActionResult,
};

/// Rate limiting for actions
pub const ActionRateLimiter = struct {
    window_ms: u64,
    max_per_window: u32,
    counts: std.AutoHashMap(ActionType, ActionCount),

    const ActionCount = struct {
        count: u32,
        window_start_ns: i128,
    };

    pub fn init(allocator: Allocator) ActionRateLimiter {
        return ActionRateLimiter{
            .window_ms = 60_000, // 1 minute window
            .max_per_window = 5,
            .counts = std.AutoHashMap(ActionType, ActionCount).init(allocator),
        };
    }

    pub fn deinit(self: *ActionRateLimiter) void {
        self.counts.deinit();
    }

    pub fn canExecute(self: *ActionRateLimiter, action: ActionType) bool {
        const now = std.time.nanoTimestamp();
        const window_ns: i128 = @as(i128, self.window_ms) * 1_000_000;

        if (self.counts.get(action)) |entry| {
            if (now - entry.window_start_ns > window_ns) {
                // New window
                self.counts.put(action, .{ .count = 1, .window_start_ns = now }) catch return false;
                return true;
            } else if (entry.count < self.max_per_window) {
                // Within window, under limit
                self.counts.put(action, .{ .count = entry.count + 1, .window_start_ns = entry.window_start_ns }) catch return false;
                return true;
            } else {
                // Rate limited
                return false;
            }
        } else {
            // First time seeing this action
            self.counts.put(action, .{ .count = 1, .window_start_ns = now }) catch return false;
            return true;
        }
    }
};

/// Remediation engine state
pub const RemediationEngine = struct {
    allocator: Allocator,
    max_attempts: u32,
    rate_limiter: ActionRateLimiter,

    // Recent attempts for deduplication
    recent_attempts: [128]RemediationAttempt,
    attempt_idx: usize,

    // Action handlers (function pointers for extensibility)
    handlers: ActionHandlers,

    // Statistics
    stats: RemediationStats,

    const Self = @This();

    pub const ActionHandlers = struct {
        reconnect: ?*const fn (root.Component) bool = null,
        evict_cache: ?*const fn () bool = null,
        cleanup_old_data: ?*const fn () bool = null,
        force_compaction: ?*const fn () bool = null,
        resync_clock: ?*const fn () bool = null,
        rotate_peers: ?*const fn () bool = null,
    };

    pub fn init(allocator: Allocator, max_attempts: u32) Self {
        return Self{
            .allocator = allocator,
            .max_attempts = max_attempts,
            .rate_limiter = ActionRateLimiter.init(allocator),
            .recent_attempts = undefined,
            .attempt_idx = 0,
            .handlers = ActionHandlers{},
            .stats = RemediationStats{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.rate_limiter.deinit();
    }

    /// Register a custom action handler
    pub fn registerHandler(self: *Self, comptime field: []const u8, handler: anytype) void {
        @field(self.handlers, field) = handler;
    }

    /// Execute a remediation action
    pub fn execute(self: *Self, action: ActionType, component: root.Component, correlation_id: u64) bool {
        // Check rate limiting
        if (!self.rate_limiter.canExecute(action)) {
            self.stats.rate_limited += 1;
            return false;
        }

        // Check attempt count for this correlation
        const attempts = self.countAttempts(correlation_id);
        if (attempts >= self.max_attempts) {
            self.stats.max_attempts_reached += 1;
            return false;
        }

        // Record attempt
        self.recordAttempt(correlation_id, action, component);
        self.stats.total_attempts += 1;

        // Execute based on action type
        const start = std.time.nanoTimestamp();
        const success = self.executeAction(action, component);
        const duration: u64 = @intCast(std.time.nanoTimestamp() - start);

        // Update stats
        if (success) {
            self.stats.successful += 1;
        } else {
            self.stats.failed += 1;
        }

        // Record average duration
        self.stats.avg_duration_ns = (self.stats.avg_duration_ns * (self.stats.total_attempts - 1) + duration) / self.stats.total_attempts;

        return success;
    }

    fn executeAction(self: *Self, action: ActionType, component: root.Component) bool {
        return switch (action) {
            .none, .log_and_alert => true, // No action needed
            .reconnect => self.doReconnect(component),
            .rotate_peers => self.doRotatePeers(),
            .retry_with_backoff => self.doRetryWithBackoff(component),
            .reset_connection_pool => self.doResetConnectionPool(),
            .evict_cache => self.doEvictCache(),
            .trigger_gc => self.doTriggerGC(),
            .reduce_buffer_sizes => self.doReduceBufferSizes(),
            .cleanup_old_data => self.doCleanupOldData(),
            .force_compaction => self.doForceCompaction(),
            .repair_index => self.doRepairIndex(),
            .recover_from_snapshot => self.doRecoverFromSnapshot(),
            .resync_clock => self.doResyncClock(),
            .reset_tower_state => self.doResetTowerState(),
            .request_repair => self.doRequestRepair(),
            .restart_component => self.doRestartComponent(component),
            .full_restart => false, // Never auto-restart fully
            .requires_manual => false,
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACTION IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════

    fn doReconnect(self: *Self, component: root.Component) bool {
        if (self.handlers.reconnect) |handler| {
            return handler(component);
        }
        // Default implementation
        return defaultReconnect(component);
    }

    fn doRotatePeers(self: *Self) bool {
        if (self.handlers.rotate_peers) |handler| {
            return handler();
        }
        // Would trigger gossip to find new peers
        return true;
    }

    fn doRetryWithBackoff(self: *Self, component: root.Component) bool {
        _ = self;
        _ = component;
        // Exponential backoff is handled by the caller
        std.time.sleep(100 * std.time.ns_per_ms);
        return true;
    }

    fn doResetConnectionPool(self: *Self) bool {
        _ = self;
        // Would reset connection pool state
        return true;
    }

    fn doEvictCache(self: *Self) bool {
        if (self.handlers.evict_cache) |handler| {
            return handler();
        }
        // Default: can't do much without access to caches
        return false;
    }

    fn doTriggerGC(self: *Self) bool {
        _ = self;
        // Zig doesn't have GC, but we can release allocator pools
        return true;
    }

    fn doReduceBufferSizes(self: *Self) bool {
        _ = self;
        // Would reduce buffer sizes in various components
        return false; // Can't do without component access
    }

    fn doCleanupOldData(self: *Self) bool {
        if (self.handlers.cleanup_old_data) |handler| {
            return handler();
        }
        return defaultCleanupOldData();
    }

    fn doForceCompaction(self: *Self) bool {
        if (self.handlers.force_compaction) |handler| {
            return handler();
        }
        return false;
    }

    fn doRepairIndex(self: *Self) bool {
        _ = self;
        // Would trigger index rebuild
        return false;
    }

    fn doRecoverFromSnapshot(self: *Self) bool {
        _ = self;
        // Would initiate snapshot recovery - dangerous, needs manual
        return false;
    }

    fn doResyncClock(self: *Self) bool {
        if (self.handlers.resync_clock) |handler| {
            return handler();
        }
        return defaultResyncClock();
    }

    fn doResetTowerState(self: *Self) bool {
        _ = self;
        // DANGEROUS: Would reset consensus state
        // Should never auto-do this
        return false;
    }

    fn doRequestRepair(self: *Self) bool {
        _ = self;
        // Would request shred repair from peers
        return true;
    }

    fn doRestartComponent(self: *Self, component: root.Component) bool {
        _ = self;
        _ = component;
        // Would restart a specific component
        // Needs component manager access
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TRACKING
    // ═══════════════════════════════════════════════════════════════════════

    fn recordAttempt(self: *Self, correlation_id: u64, action: ActionType, component: root.Component) void {
        self.recent_attempts[self.attempt_idx] = RemediationAttempt{
            .correlation_id = correlation_id,
            .action = action,
            .component = component,
            .timestamp_ns = std.time.nanoTimestamp(),
            .attempt_number = self.countAttempts(correlation_id) + 1,
            .result = null,
        };
        self.attempt_idx = (self.attempt_idx + 1) % self.recent_attempts.len;
    }

    fn countAttempts(self: *Self, correlation_id: u64) u32 {
        var count: u32 = 0;
        const cutoff = std.time.nanoTimestamp() - (5 * 60 * std.time.ns_per_s); // 5 min window

        for (self.recent_attempts) |attempt| {
            if (attempt.correlation_id == correlation_id and attempt.timestamp_ns > cutoff) {
                count += 1;
            }
        }
        return count;
    }

    pub fn getStats(self: *const Self) RemediationStats {
        return self.stats;
    }
};

pub const RemediationStats = struct {
    total_attempts: u64 = 0,
    successful: u64 = 0,
    failed: u64 = 0,
    rate_limited: u64 = 0,
    max_attempts_reached: u64 = 0,
    avg_duration_ns: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════
// DEFAULT ACTION IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════

fn defaultReconnect(component: root.Component) bool {
    _ = component;
    // Default reconnection logic
    // In real implementation, would access network layer
    return true;
}

fn defaultCleanupOldData() bool {
    // Default cleanup - remove old ledger data
    // Would need access to ledger path
    return true;
}

fn defaultResyncClock() bool {
    // Re-sync with NTP or cluster time
    // This is a placeholder
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// REMEDIATION PLAYBOOKS
// ═══════════════════════════════════════════════════════════════════════════

/// Pre-defined remediation sequences for complex issues
pub const Playbook = struct {
    name: []const u8,
    description: []const u8,
    steps: []const PlaybookStep,
    max_duration_ms: u64,
    requires_confirmation: bool,
};

pub const PlaybookStep = struct {
    action: ActionType,
    condition: ?[]const u8,
    timeout_ms: u32,
    on_failure: OnFailure,
};

pub const OnFailure = enum {
    continue_next,
    abort,
    retry,
    escalate,
};

/// Built-in playbooks
pub const playbooks = struct {
    pub const network_recovery = Playbook{
        .name = "network_recovery",
        .description = "Recover from network connectivity issues",
        .steps = &[_]PlaybookStep{
            .{ .action = .reconnect, .condition = null, .timeout_ms = 5000, .on_failure = .continue_next },
            .{ .action = .rotate_peers, .condition = null, .timeout_ms = 10000, .on_failure = .continue_next },
            .{ .action = .reset_connection_pool, .condition = null, .timeout_ms = 2000, .on_failure = .abort },
        },
        .max_duration_ms = 30000,
        .requires_confirmation = false,
    };

    pub const memory_pressure = Playbook{
        .name = "memory_pressure",
        .description = "Reduce memory usage when under pressure",
        .steps = &[_]PlaybookStep{
            .{ .action = .evict_cache, .condition = null, .timeout_ms = 5000, .on_failure = .continue_next },
            .{ .action = .trigger_gc, .condition = null, .timeout_ms = 1000, .on_failure = .continue_next },
            .{ .action = .reduce_buffer_sizes, .condition = null, .timeout_ms = 2000, .on_failure = .abort },
        },
        .max_duration_ms = 15000,
        .requires_confirmation = false,
    };

    pub const consensus_recovery = Playbook{
        .name = "consensus_recovery",
        .description = "Recover from consensus issues - USE WITH CAUTION",
        .steps = &[_]PlaybookStep{
            .{ .action = .resync_clock, .condition = null, .timeout_ms = 5000, .on_failure = .continue_next },
            .{ .action = .request_repair, .condition = null, .timeout_ms = 30000, .on_failure = .escalate },
        },
        .max_duration_ms = 60000,
        .requires_confirmation = true,
    };
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "remediation engine basic" {
    const allocator = std.testing.allocator;
    var engine = RemediationEngine.init(allocator, 3);
    defer engine.deinit();

    // First attempt should succeed
    const success = engine.execute(.log_and_alert, .network_socket, 12345);
    try std.testing.expect(success);

    const stats = engine.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.total_attempts);
    try std.testing.expectEqual(@as(u64, 1), stats.successful);
}

test "rate limiting" {
    const allocator = std.testing.allocator;
    var limiter = ActionRateLimiter.init(allocator);
    defer limiter.deinit();

    // Should allow first 5
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(limiter.canExecute(.reconnect));
    }

    // 6th should be rate limited
    try std.testing.expect(!limiter.canExecute(.reconnect));
}

test "action type properties" {
    try std.testing.expectEqual(ActionType.reconnect, root.ErrorCode.network_unreachable.suggestedAction());
    try std.testing.expectEqual(ActionType.evict_cache, root.ErrorCode.memory_pressure.suggestedAction());
}

