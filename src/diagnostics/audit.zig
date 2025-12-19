//! Vexor Audit Logger
//!
//! Structured logging with persistent storage for error analysis
//! and compliance. Provides queryable error history.

const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const root = @import("root.zig");

/// Audit log format
pub const LogFormat = enum {
    json,
    jsonl, // JSON Lines (one JSON object per line)
    text,
    binary, // Compact binary format
};

/// Audit logger configuration
pub const AuditConfig = struct {
    format: LogFormat = .jsonl,
    max_file_size_mb: u32 = 100,
    max_files: u32 = 10,
    flush_interval_ms: u32 = 1000,
    include_stack_traces: bool = true,
    compress_rotated: bool = true,
};

/// Audit logger state
pub const AuditLogger = struct {
    allocator: Allocator,
    config: AuditConfig,
    log_path: ?[]const u8,
    file: ?File,
    buffer: std.ArrayList(u8),
    events_since_flush: u32,
    bytes_written: u64,

    // Statistics
    total_events_logged: u64,
    total_bytes_written: u64,
    files_rotated: u32,

    const Self = @This();

    pub fn init(allocator: Allocator, log_path: ?[]const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .config = AuditConfig{},
            .log_path = log_path,
            .file = null,
            .buffer = std.ArrayList(u8).init(allocator),
            .events_since_flush = 0,
            .bytes_written = 0,
            .total_events_logged = 0,
            .total_bytes_written = 0,
            .files_rotated = 0,
        };

        // Open log file if path provided
        if (log_path) |path| {
            self.file = try std.fs.cwd().createFile(path, .{
                .truncate = false,
            });
            // Seek to end for append mode
            if (self.file) |f| {
                const stat = try f.stat();
                try f.seekTo(stat.size);
                self.bytes_written = stat.size;
            }
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.flush() catch {};
        if (self.file) |f| {
            f.close();
        }
        self.buffer.deinit();
    }

    /// Log a diagnostic event
    pub fn logEvent(self: *Self, event: *const root.DiagnosticEvent) void {
        switch (self.config.format) {
            .jsonl => self.logJsonLine(event),
            .json => self.logJsonLine(event), // Same for now
            .text => self.logText(event),
            .binary => self.logBinary(event),
        }

        self.events_since_flush += 1;
        self.total_events_logged += 1;

        // Auto-flush periodically
        if (self.events_since_flush >= 100) {
            self.flush() catch {};
        }

        // Check for rotation
        if (self.bytes_written >= @as(u64, self.config.max_file_size_mb) * 1024 * 1024) {
            self.rotateLog() catch {};
        }
    }

    fn logJsonLine(self: *Self, event: *const root.DiagnosticEvent) void {
        const writer = self.buffer.writer();

        // Manual JSON construction (no json library needed)
        writer.print("{{\"ts\":{d},\"sev\":\"{s}\",\"comp\":\"{s}\",\"code\":{d},\"msg\":\"{s}\"", .{
            event.timestamp_ns,
            event.severity.toString(),
            event.component.toString(),
            @intFromEnum(event.error_code),
            event.message,
        }) catch return;

        if (event.context) |ctx| {
            writer.print(",\"ctx\":\"{s}\"", .{ctx}) catch return;
        }

        if (event.slot) |slot| {
            writer.print(",\"slot\":{d}", .{slot}) catch return;
        }

        writer.print(",\"cid\":{d}", .{event.correlation_id}) catch return;

        if (event.remediation_attempted) {
            writer.print(",\"rem\":{{\"attempted\":true,\"success\":{}}}", .{event.remediation_succeeded}) catch return;
        }

        writer.writeAll("}\n") catch return;
    }

    fn logText(self: *Self, event: *const root.DiagnosticEvent) void {
        const writer = self.buffer.writer();

        // ISO-ish timestamp from nanoseconds
        const sec: i64 = @intCast(@divTrunc(event.timestamp_ns, 1_000_000_000));
        _ = sec;

        writer.print("[{d}] [{s}] {s}/{s}: {s}", .{
            event.timestamp_ns,
            event.severity.toString(),
            event.component.category(),
            event.component.toString(),
            event.message,
        }) catch return;

        if (event.context) |ctx| {
            writer.print(" | {s}", .{ctx}) catch return;
        }

        writer.writeAll("\n") catch return;
    }

    fn logBinary(self: *Self, event: *const root.DiagnosticEvent) void {
        const writer = self.buffer.writer();

        // Compact binary format:
        // [8 bytes timestamp][1 byte severity][2 bytes component][4 bytes error_code]
        // [2 bytes message_len][message][2 bytes context_len][context]

        writer.writeInt(i128, event.timestamp_ns, .little) catch return;
        writer.writeByte(@intFromEnum(event.severity)) catch return;
        writer.writeInt(u16, @intFromEnum(event.component), .little) catch return;
        writer.writeInt(u32, @intFromEnum(event.error_code), .little) catch return;

        const msg_len: u16 = @intCast(@min(event.message.len, 65535));
        writer.writeInt(u16, msg_len, .little) catch return;
        writer.writeAll(event.message[0..msg_len]) catch return;

        if (event.context) |ctx| {
            const ctx_len: u16 = @intCast(@min(ctx.len, 65535));
            writer.writeInt(u16, ctx_len, .little) catch return;
            writer.writeAll(ctx[0..ctx_len]) catch return;
        } else {
            writer.writeInt(u16, 0, .little) catch return;
        }
    }

    /// Flush buffer to file
    pub fn flush(self: *Self) !void {
        if (self.buffer.items.len == 0) return;

        if (self.file) |f| {
            try f.writeAll(self.buffer.items);
            self.bytes_written += self.buffer.items.len;
            self.total_bytes_written += self.buffer.items.len;
        }

        self.buffer.clearRetainingCapacity();
        self.events_since_flush = 0;
    }

    /// Rotate log file
    fn rotateLog(self: *Self) !void {
        if (self.log_path == null) return;

        // Close current file
        if (self.file) |f| {
            f.close();
            self.file = null;
        }

        // Rename existing files (shift indices)
        var i: u32 = self.config.max_files - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.log_path.?, i - 1 });
            defer self.allocator.free(old_name);

            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.log_path.?, i });
            defer self.allocator.free(new_name);

            std.fs.cwd().rename(old_name, new_name) catch {};
        }

        // Rename current to .0
        const rotated_name = try std.fmt.allocPrint(self.allocator, "{s}.0", .{self.log_path.?});
        defer self.allocator.free(rotated_name);

        std.fs.cwd().rename(self.log_path.?, rotated_name) catch {};

        // Open new file
        self.file = try std.fs.cwd().createFile(self.log_path.?, .{});
        self.bytes_written = 0;
        self.files_rotated += 1;
    }

    /// Query recent events from log file
    pub fn queryRecent(self: *Self, max_events: usize) ![]root.DiagnosticEvent {
        _ = self;
        _ = max_events;
        // Would need to parse log file - complex for binary/json
        // Placeholder for now
        return &[_]root.DiagnosticEvent{};
    }

    /// Export events to a specific format
    pub fn exportToFile(self: *Self, format: LogFormat, output_path: []const u8) !void {
        _ = self;
        _ = format;
        _ = output_path;
        // Would iterate through stored events and write in requested format
    }

    /// Get statistics
    pub fn getStats(self: *const Self) AuditStats {
        return AuditStats{
            .total_events = self.total_events_logged,
            .total_bytes = self.total_bytes_written,
            .files_rotated = self.files_rotated,
            .current_file_bytes = self.bytes_written,
        };
    }
};

pub const AuditStats = struct {
    total_events: u64,
    total_bytes: u64,
    files_rotated: u32,
    current_file_bytes: u64,
};

/// Audit trail entry for important actions
pub const AuditTrailEntry = struct {
    timestamp_ns: i128,
    action: AuditAction,
    actor: []const u8, // Component or external
    target: []const u8,
    details: ?[]const u8,
    success: bool,
};

pub const AuditAction = enum {
    // Startup/shutdown
    validator_start,
    validator_stop,
    validator_restart,

    // Configuration
    config_change,
    identity_load,
    vote_account_load,

    // Network
    peer_connected,
    peer_disconnected,
    entrypoint_contact,

    // Consensus
    vote_submitted,
    block_produced,
    fork_switch,

    // Storage
    snapshot_download,
    snapshot_load,
    ledger_cleanup,
    account_update,

    // Remediation
    auto_remediation,
    manual_intervention,

    // Security
    auth_attempt,
    rate_limit_triggered,
};

/// Audit trail logger (separate from diagnostic events)
pub const AuditTrail = struct {
    allocator: Allocator,
    entries: std.ArrayList(AuditTrailEntry),
    max_entries: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, max_entries: usize) Self {
        return Self{
            .allocator = allocator,
            .entries = std.ArrayList(AuditTrailEntry).init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    pub fn record(self: *Self, action: AuditAction, actor: []const u8, target: []const u8, details: ?[]const u8, success: bool) !void {
        const entry = AuditTrailEntry{
            .timestamp_ns = std.time.nanoTimestamp(),
            .action = action,
            .actor = actor,
            .target = target,
            .details = details,
            .success = success,
        };

        if (self.entries.items.len >= self.max_entries) {
            // Remove oldest entry
            _ = self.entries.orderedRemove(0);
        }

        try self.entries.append(entry);
    }

    pub fn getRecent(self: *Self, count: usize) []const AuditTrailEntry {
        const start = if (self.entries.items.len > count)
            self.entries.items.len - count
        else
            0;
        return self.entries.items[start..];
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "audit logger init" {
    const allocator = std.testing.allocator;
    var logger = try AuditLogger.init(allocator, null);
    defer logger.deinit();

    const event = root.DiagnosticEvent{
        .timestamp_ns = std.time.nanoTimestamp(),
        .severity = .info,
        .component = .core_init,
        .error_code = .ok,
        .message = "Test event",
        .context = null,
        .stack_trace = null,
        .correlation_id = 12345,
        .slot = null,
        .remediation_attempted = false,
        .remediation_succeeded = false,
    };

    logger.logEvent(&event);
    try std.testing.expectEqual(@as(u64, 1), logger.total_events_logged);
}

test "audit trail" {
    const allocator = std.testing.allocator;
    var trail = AuditTrail.init(allocator, 100);
    defer trail.deinit();

    try trail.record(.validator_start, "main", "vexor", null, true);
    try trail.record(.identity_load, "main", "/path/to/identity.json", null, true);

    const recent = trail.getRecent(10);
    try std.testing.expectEqual(@as(usize, 2), recent.len);
}

