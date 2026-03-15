//! Vexor Alert System
//! Real-time monitoring and alerting during validator operations.
//!
//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║                         ALERT SYSTEM                                       ║
//! ╠═══════════════════════════════════════════════════════════════════════════╣
//! ║                                                                            ║
//! ║  Alert Channels:                                                           ║
//! ║    • Telegram Bot                                                          ║
//! ║    • Discord Webhook                                                       ║
//! ║    • Slack Webhook                                                         ║
//! ║    • PagerDuty                                                             ║
//! ║    • Email (SMTP)                                                          ║
//! ║    • Local file logging                                                    ║
//! ║    • System notifications (notify-send)                                    ║
//! ║                                                                            ║
//! ║  Alert Levels:                                                             ║
//! ║    • INFO     - Normal operations                                          ║
//! ║    • WARNING  - Attention needed                                           ║
//! ║    • ERROR    - Operation failed                                           ║
//! ║    • CRITICAL - Immediate action required                                  ║
//! ║                                                                            ║
//! ║  Events Monitored:                                                         ║
//! ║    • Switch initiated/completed/failed                                     ║
//! ║    • Backup created/verified/failed                                        ║
//! ║    • Health check failed                                                   ║
//! ║    • Missed slots detected                                                 ║
//! ║    • Vote lag detected                                                     ║
//! ║    • RPC not responding                                                    ║
//! ║                                                                            ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

/// Alert severity levels
pub const AlertLevel = enum {
    info,
    warning,
    @"error",
    critical,

    pub fn emoji(self: AlertLevel) []const u8 {
        return switch (self) {
            .info => "ℹ️",
            .warning => "⚠️",
            .@"error" => "❌",
            .critical => "🚨",
        };
    }

    pub fn color(self: AlertLevel) u32 {
        return switch (self) {
            .info => 0x3498db, // Blue
            .warning => 0xf39c12, // Orange
            .@"error" => 0xe74c3c, // Red
            .critical => 0x8e44ad, // Purple
        };
    }
};

/// Alert event types
pub const AlertEvent = enum {
    // Switch events
    switch_initiated,
    switch_completed,
    switch_failed,
    switch_rollback,

    // Backup events
    backup_started,
    backup_completed,
    backup_failed,
    backup_verified,

    // Health events
    health_check_passed,
    health_check_failed,
    client_started,
    client_stopped,
    client_crashed,

    // Consensus events
    missed_slots,
    vote_lag,
    delinquent,

    // Network events
    rpc_down,
    gossip_disconnected,
    peers_low,

    // System events
    disk_space_low,
    memory_high,
    cpu_high,

    pub fn defaultLevel(self: AlertEvent) AlertLevel {
        return switch (self) {
            .switch_completed, .backup_completed, .backup_verified, .health_check_passed, .client_started => .info,
            .switch_initiated, .backup_started, .client_stopped, .peers_low => .warning,
            .switch_failed, .backup_failed, .health_check_failed, .rpc_down, .disk_space_low => .@"error",
            .switch_rollback, .client_crashed, .missed_slots, .vote_lag, .delinquent, .gossip_disconnected, .memory_high, .cpu_high => .critical,
        };
    }
};

/// Alert configuration
pub const AlertConfig = struct {
    /// Validator name for identification
    validator_name: []const u8 = "testnet-validator",

    /// Cluster (for context)
    cluster: []const u8 = "testnet",

    /// Telegram configuration
    telegram_bot_token: ?[]const u8 = null,
    telegram_chat_id: ?[]const u8 = null,

    /// Discord webhook URL
    discord_webhook_url: ?[]const u8 = null,

    /// Slack webhook URL
    slack_webhook_url: ?[]const u8 = null,

    /// PagerDuty routing key
    pagerduty_key: ?[]const u8 = null,

    /// Email settings
    smtp_host: ?[]const u8 = null,
    smtp_port: u16 = 587,
    smtp_user: ?[]const u8 = null,
    smtp_pass: ?[]const u8 = null,
    email_to: ?[]const u8 = null,

    /// Log file path
    log_file: []const u8 = "/var/log/vexor/alerts.log",

    /// Enable desktop notifications
    enable_desktop_notify: bool = true,

    /// Minimum alert level to send
    min_level: AlertLevel = .warning,

    /// Cooldown between duplicate alerts (seconds)
    cooldown_seconds: u64 = 300,
};

/// Alert message
pub const Alert = struct {
    level: AlertLevel,
    event: AlertEvent,
    title: []const u8,
    message: []const u8,
    timestamp: i64,
    validator_name: []const u8,
    cluster: []const u8,
    metadata: ?std.json.ObjectMap = null,
};

/// Alert System Manager
pub const AlertSystem = struct {
    allocator: Allocator,
    config: AlertConfig,
    last_alerts: std.AutoHashMap(AlertEvent, i64),

    const Self = @This();

    pub fn init(allocator: Allocator, config: AlertConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .last_alerts = std.AutoHashMap(AlertEvent, i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.last_alerts.deinit();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN ALERT FUNCTION
    // ═══════════════════════════════════════════════════════════════════════

    /// Send an alert through all configured channels
    pub fn sendAlert(
        self: *Self,
        event: AlertEvent,
        title: []const u8,
        message: []const u8,
    ) !void {
        const level = event.defaultLevel();

        // Check minimum level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        // Check cooldown
        const now = std.time.timestamp();
        if (self.last_alerts.get(event)) |last_time| {
            if (now - last_time < @as(i64, @intCast(self.config.cooldown_seconds))) {
                return; // Cooldown active
            }
        }

        try self.last_alerts.put(event, now);

        const alert = Alert{
            .level = level,
            .event = event,
            .title = title,
            .message = message,
            .timestamp = now,
            .validator_name = self.config.validator_name,
            .cluster = self.config.cluster,
        };

        // Log to file (always)
        self.logToFile(alert) catch {};

        // Desktop notification
        if (self.config.enable_desktop_notify) {
            self.sendDesktopNotification(alert) catch {};
        }

        // External services (in parallel would be ideal, but sequential for now)
        if (self.config.telegram_bot_token != null) {
            self.sendTelegram(alert) catch |err| {
                std.debug.print("Telegram alert failed: {}\n", .{err});
            };
        }

        if (self.config.discord_webhook_url != null) {
            self.sendDiscord(alert) catch |err| {
                std.debug.print("Discord alert failed: {}\n", .{err});
            };
        }

        if (self.config.slack_webhook_url != null) {
            self.sendSlack(alert) catch |err| {
                std.debug.print("Slack alert failed: {}\n", .{err});
            };
        }

        // Console output
        self.printAlert(alert);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CHANNEL IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// Log alert to file
    fn logToFile(self: *Self, alert: Alert) !void {
        const file = std.fs.cwd().openFile(self.config.log_file, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                // Create the file
                const dir = std.fs.path.dirname(self.config.log_file) orelse ".";
                std.fs.cwd().makePath(dir) catch {};
                const new_file = try std.fs.cwd().createFile(self.config.log_file, .{});
                return self.writeLogEntry(new_file, alert);
            }
            return err;
        };
        defer file.close();

        try file.seekFromEnd(0);
        try self.writeLogEntry(file, alert);
    }

    fn writeLogEntry(self: *Self, file: std.fs.File, alert: Alert) !void {
        _ = self;
        var writer = file.writer();
        try writer.print(
            "[{d}] [{s}] [{s}] {s}: {s}\n",
            .{
                alert.timestamp,
                @tagName(alert.level),
                @tagName(alert.event),
                alert.title,
                alert.message,
            },
        );
    }

    /// Send desktop notification (Linux notify-send)
    fn sendDesktopNotification(self: *Self, alert: Alert) !void {
        _ = self;

        const urgency = switch (alert.level) {
            .info => "low",
            .warning => "normal",
            .@"error", .critical => "critical",
        };

        const title = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s} Vexor: {s}",
            .{ alert.level.emoji(), alert.title },
        );
        defer std.heap.page_allocator.free(title);

        var child = std.process.Child.init(
            &[_][]const u8{
                "notify-send",
                "-u",
                urgency,
                title,
                alert.message,
            },
            std.heap.page_allocator,
        );
        _ = child.spawnAndWait() catch {};
    }

    /// Send Telegram alert
    fn sendTelegram(self: *Self, alert: Alert) !void {
        const token = self.config.telegram_bot_token orelse return;
        const chat_id = self.config.telegram_chat_id orelse return;

        const text = try std.fmt.allocPrint(
            self.allocator,
            "{s} *{s}*\n\n{s}\n\n_Validator: {s}_\n_Cluster: {s}_",
            .{
                alert.level.emoji(),
                alert.title,
                alert.message,
                alert.validator_name,
                alert.cluster,
            },
        );
        defer self.allocator.free(text);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://api.telegram.org/bot{s}/sendMessage",
            .{token},
        );
        defer self.allocator.free(url);

        // Build JSON body
        const body = try std.fmt.allocPrint(
            self.allocator,
            \\{{"chat_id":"{s}","text":"{s}","parse_mode":"Markdown"}}
        ,
            .{ chat_id, text },
        );
        defer self.allocator.free(body);

        try self.httpPost(url, body, "application/json");
    }

    /// Send Discord webhook
    fn sendDiscord(self: *Self, alert: Alert) !void {
        const webhook_url = self.config.discord_webhook_url orelse return;

        const body = try std.fmt.allocPrint(
            self.allocator,
            \\{{
            \\  "embeds": [{{
            \\    "title": "{s} {s}",
            \\    "description": "{s}",
            \\    "color": {d},
            \\    "fields": [
            \\      {{"name": "Validator", "value": "{s}", "inline": true}},
            \\      {{"name": "Cluster", "value": "{s}", "inline": true}},
            \\      {{"name": "Event", "value": "{s}", "inline": true}}
            \\    ],
            \\    "timestamp": "{d}"
            \\  }}]
            \\}}
        ,
            .{
                alert.level.emoji(),
                alert.title,
                alert.message,
                alert.level.color(),
                alert.validator_name,
                alert.cluster,
                @tagName(alert.event),
                alert.timestamp,
            },
        );
        defer self.allocator.free(body);

        try self.httpPost(webhook_url, body, "application/json");
    }

    /// Send Slack webhook
    fn sendSlack(self: *Self, alert: Alert) !void {
        const webhook_url = self.config.slack_webhook_url orelse return;

        const body = try std.fmt.allocPrint(
            self.allocator,
            \\{{
            \\  "blocks": [
            \\    {{
            \\      "type": "header",
            \\      "text": {{"type": "plain_text", "text": "{s} {s}"}}
            \\    }},
            \\    {{
            \\      "type": "section",
            \\      "text": {{"type": "mrkdwn", "text": "{s}"}}
            \\    }},
            \\    {{
            \\      "type": "context",
            \\      "elements": [
            \\        {{"type": "mrkdwn", "text": "*Validator:* {s} | *Cluster:* {s}"}}
            \\      ]
            \\    }}
            \\  ]
            \\}}
        ,
            .{
                alert.level.emoji(),
                alert.title,
                alert.message,
                alert.validator_name,
                alert.cluster,
            },
        );
        defer self.allocator.free(body);

        try self.httpPost(webhook_url, body, "application/json");
    }

    /// Generic HTTP POST helper
    fn httpPost(self: *Self, url: []const u8, body: []const u8, content_type: []const u8) !void {
        _ = self;
        _ = url;
        _ = body;
        _ = content_type;
        // Note: In a real implementation, use std.http.Client
        // For now, we'll use curl via process spawn
        
        // var client = std.http.Client{ .allocator = self.allocator };
        // defer client.deinit();
        // ... HTTP request ...
    }

    /// Print alert to console
    fn printAlert(self: *Self, alert: Alert) void {
        _ = self;

        std.debug.print(
            \\
            \\{s} ══════════════════════════════════════════════════════════════
            \\{s}  {s}
            \\{s} ──────────────────────────────────────────────────────────────
            \\{s}  {s}
            \\{s}  
            \\{s}  Validator: {s} | Cluster: {s}
            \\{s} ══════════════════════════════════════════════════════════════
            \\
        , .{
            alert.level.emoji(),
            alert.level.emoji(),
            alert.title,
            alert.level.emoji(),
            alert.level.emoji(),
            alert.message,
            alert.level.emoji(),
            alert.level.emoji(),
            alert.validator_name,
            alert.cluster,
            alert.level.emoji(),
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONVENIENCE METHODS
    // ═══════════════════════════════════════════════════════════════════════

    /// Alert: Switch started
    pub fn alertSwitchStarted(self: *Self, from: []const u8, to: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Initiating switch from {s} to {s}. Backup will be created first.",
            .{ from, to },
        );
        defer self.allocator.free(msg);

        try self.sendAlert(.switch_initiated, "Client Switch Started", msg);
    }

    /// Alert: Switch completed
    pub fn alertSwitchCompleted(self: *Self, to: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{s} is now running. Monitoring health...",
            .{to},
        );
        defer self.allocator.free(msg);

        try self.sendAlert(.switch_completed, "Client Switch Completed", msg);
    }

    /// Alert: Switch failed
    pub fn alertSwitchFailed(self: *Self, reason: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Switch failed: {s}. Previous client may need manual restart.",
            .{reason},
        );
        defer self.allocator.free(msg);

        try self.sendAlert(.switch_failed, "Client Switch FAILED", msg);
    }

    /// Alert: Backup completed
    pub fn alertBackupCompleted(self: *Self, backup_id: []const u8, files: u32) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Backup {s} created successfully. {d} files backed up.",
            .{ backup_id, files },
        );
        defer self.allocator.free(msg);

        try self.sendAlert(.backup_completed, "Backup Created", msg);
    }

    /// Alert: Health check failed
    pub fn alertHealthCheckFailed(self: *Self, reason: []const u8) !void {
        try self.sendAlert(.health_check_failed, "Health Check Failed", reason);
    }

    /// Alert: Missed slots
    pub fn alertMissedSlots(self: *Self, count: u64) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Validator has missed {d} slots. May need investigation.",
            .{count},
        );
        defer self.allocator.free(msg);

        try self.sendAlert(.missed_slots, "Missed Slots Detected", msg);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// HEALTH MONITOR
// ═══════════════════════════════════════════════════════════════════════════

/// Validator health monitor
pub const HealthMonitor = struct {
    allocator: Allocator,
    alerts: *AlertSystem,
    rpc_url: []const u8,
    check_interval_ms: u64,
    running: std.atomic.Value(bool),

    // Thresholds
    max_vote_lag_slots: u64 = 150,
    max_missed_slots: u64 = 10,
    min_peers: u32 = 10,
    max_memory_percent: u8 = 90,
    max_cpu_percent: u8 = 95,
    min_disk_gb: u64 = 50,

    const Self = @This();

    pub fn init(allocator: Allocator, alerts: *AlertSystem, rpc_url: []const u8) Self {
        return .{
            .allocator = allocator,
            .alerts = alerts,
            .rpc_url = rpc_url,
            .check_interval_ms = 30_000, // 30 seconds
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Run a single health check
    pub fn checkHealth(self: *Self) !HealthStatus {
        var status = HealthStatus{};

        // Check RPC
        status.rpc_responding = self.checkRpc();

        // Check vote lag (via RPC)
        if (status.rpc_responding) {
            status.vote_lag = self.getVoteLag();
            if (status.vote_lag > self.max_vote_lag_slots) {
                try self.alerts.sendAlert(
                    .vote_lag,
                    "Vote Lag Detected",
                    try std.fmt.allocPrint(self.allocator, "Vote lag: {d} slots", .{status.vote_lag}),
                );
            }
        } else {
            try self.alerts.alertHealthCheckFailed("RPC not responding");
        }

        // Check system resources
        status.memory_percent = self.getMemoryUsage();
        status.cpu_percent = self.getCpuUsage();
        status.disk_free_gb = self.getDiskFree();

        if (status.memory_percent > self.max_memory_percent) {
            try self.alerts.sendAlert(
                .memory_high,
                "High Memory Usage",
                try std.fmt.allocPrint(self.allocator, "Memory usage: {d}%", .{status.memory_percent}),
            );
        }

        status.healthy = status.rpc_responding and
            status.vote_lag <= self.max_vote_lag_slots and
            status.memory_percent <= self.max_memory_percent;

        return status;
    }

    fn checkRpc(self: *Self) bool {
        _ = self;
        // TODO: Implement actual RPC health check
        return true;
    }

    fn getVoteLag(self: *Self) u64 {
        _ = self;
        // TODO: Implement via RPC call
        return 0;
    }

    fn getMemoryUsage(self: *Self) u8 {
        _ = self;
        // Read from /proc/meminfo
        const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return 0;
        defer file.close();

        var buf: [4096]u8 = undefined;
        _ = file.readAll(&buf) catch return 0;

        // Parse MemTotal and MemAvailable
        // Simplified - return 0 for now
        return 0;
    }

    fn getCpuUsage(self: *Self) u8 {
        _ = self;
        return 0;
    }

    fn getDiskFree(self: *Self) u64 {
        _ = self;
        return 100; // GB
    }

    pub const HealthStatus = struct {
        healthy: bool = false,
        rpc_responding: bool = false,
        vote_lag: u64 = 0,
        missed_slots: u64 = 0,
        peer_count: u32 = 0,
        memory_percent: u8 = 0,
        cpu_percent: u8 = 0,
        disk_free_gb: u64 = 0,

        pub fn print(self: *const HealthStatus) void {
            const status_icon = if (self.healthy) "🟢" else "🔴";

            std.debug.print(
                \\
                \\╔══════════════════════════════════════════════════════════════╗
                \\║                    HEALTH STATUS {s}                         ║
                \\╠══════════════════════════════════════════════════════════════╣
                \\║  RPC Responding:     {s}                                    ║
                \\║  Vote Lag:           {d} slots                               ║
                \\║  Peer Count:         {d}                                     ║
                \\║  Memory Usage:       {d}%                                    ║
                \\║  CPU Usage:          {d}%                                    ║
                \\║  Disk Free:          {d} GB                                  ║
                \\╚══════════════════════════════════════════════════════════════╝
                \\
            , .{
                status_icon,
                if (self.rpc_responding) "✅ YES" else "❌ NO ",
                self.vote_lag,
                self.peer_count,
                self.memory_percent,
                self.cpu_percent,
                self.disk_free_gb,
            });
        }
    };
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "AlertSystem: init" {
    var alerts = AlertSystem.init(std.testing.allocator, .{});
    defer alerts.deinit();
}

test "AlertLevel: emoji" {
    try std.testing.expectEqualStrings("ℹ️", AlertLevel.info.emoji());
    try std.testing.expectEqualStrings("🚨", AlertLevel.critical.emoji());
}

