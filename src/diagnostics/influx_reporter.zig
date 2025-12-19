//! InfluxDB Metrics Reporter
//! 
//! Reports validator metrics to InfluxDB in the same format as Agave,
//! enabling compatibility with Solana Foundation dashboards like:
//! - https://solana.thevalidators.io
//! - metrics.solana.com
//!
//! Parses the SOLANA_METRICS_CONFIG environment variable:
//!   host=https://metrics.solana.com:8086,db=tds,u=user,p=password
//!
//! Metrics are sent using InfluxDB line protocol over HTTP POST.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

/// InfluxDB configuration parsed from SOLANA_METRICS_CONFIG
pub const InfluxConfig = struct {
    host: []const u8,
    db: []const u8,
    user: []const u8,
    password: []const u8,
    
    /// Parse from SOLANA_METRICS_CONFIG format:
    /// "host=https://...,db=...,u=...,p=..."
    pub fn parse(allocator: Allocator, config_str: []const u8) !InfluxConfig {
        var host: []const u8 = "";
        var db: []const u8 = "";
        var user: []const u8 = "";
        var password: []const u8 = "";
        
        var iter = std.mem.splitSequence(u8, config_str, ",");
        while (iter.next()) |part| {
            if (std.mem.startsWith(u8, part, "host=")) {
                host = try allocator.dupe(u8, part[5..]);
            } else if (std.mem.startsWith(u8, part, "db=")) {
                db = try allocator.dupe(u8, part[3..]);
            } else if (std.mem.startsWith(u8, part, "u=")) {
                user = try allocator.dupe(u8, part[2..]);
            } else if (std.mem.startsWith(u8, part, "p=")) {
                password = try allocator.dupe(u8, part[2..]);
            }
        }
        
        if (host.len == 0 or db.len == 0) {
            return error.InvalidConfig;
        }
        
        return InfluxConfig{
            .host = host,
            .db = db,
            .user = user,
            .password = password,
        };
    }
    
    /// Parse from environment variable
    pub fn fromEnv(allocator: Allocator) !?InfluxConfig {
        const config_str = std.posix.getenv("SOLANA_METRICS_CONFIG") orelse return null;
        return try parse(allocator, config_str);
    }
};

/// Metrics reporter that sends data to InfluxDB
pub const InfluxReporter = struct {
    allocator: Allocator,
    config: InfluxConfig,
    identity: []const u8,
    cluster: []const u8,
    
    // Accumulated metrics buffer
    buffer: std.ArrayList(u8),
    last_flush: i64,
    flush_interval_ms: i64,
    
    const Self = @This();
    
    /// Initialize the reporter
    pub fn init(allocator: Allocator, config: InfluxConfig, identity: []const u8, cluster: []const u8) !*Self {
        const reporter = try allocator.create(Self);
        reporter.* = .{
            .allocator = allocator,
            .config = config,
            .identity = try allocator.dupe(u8, identity),
            .cluster = try allocator.dupe(u8, cluster),
            .buffer = std.ArrayList(u8).init(allocator),
            .last_flush = std.time.milliTimestamp(),
            .flush_interval_ms = 10_000, // Flush every 10 seconds
        };
        return reporter;
    }
    
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.allocator.free(self.identity);
        self.allocator.free(self.cluster);
        self.allocator.destroy(self);
    }
    
    /// Record a datapoint in InfluxDB line protocol format
    /// measurement,tag1=value1,tag2=value2 field1=value1,field2=value2 timestamp
    pub fn datapoint(self: *Self, measurement: []const u8, fields: anytype) !void {
        const writer = self.buffer.writer();
        
        // Write measurement and common tags
        try writer.print("{s},host_id={s},cluster={s} ", .{ 
            measurement, 
            self.identity[0..@min(8, self.identity.len)], 
            self.cluster 
        });
        
        // Write fields from struct
        const T = @TypeOf(fields);
        const info = @typeInfo(T);
        
        if (info == .Struct) {
            var first = true;
            inline for (info.Struct.fields) |field| {
                if (!first) try writer.writeAll(",");
                first = false;
                
                const value = @field(fields, field.name);
                switch (@typeInfo(@TypeOf(value))) {
                    .Int, .ComptimeInt => try writer.print("{s}={d}i", .{ field.name, value }),
                    .Float, .ComptimeFloat => try writer.print("{s}={d}", .{ field.name, value }),
                    .Bool => try writer.print("{s}={s}", .{ field.name, if (value) "true" else "false" }),
                    .Pointer => try writer.print("{s}=\"{s}\"", .{ field.name, value }),
                    else => {},
                }
            }
        }
        
        // Add timestamp (nanoseconds)
        try writer.print(" {d}\n", .{std.time.nanoTimestamp()});
        
        // Check if we should flush
        const now = std.time.milliTimestamp();
        if (now - self.last_flush > self.flush_interval_ms) {
            try self.flush();
        }
    }
    
    /// Record a counter increment
    pub fn counter(self: *Self, name: []const u8, value: i64) !void {
        try self.datapoint(name, .{ .count = value });
    }
    
    /// Record a gauge value
    pub fn gauge(self: *Self, name: []const u8, value: i64) !void {
        try self.datapoint(name, .{ .value = value });
    }
    
    /// Record timing in milliseconds
    pub fn timing(self: *Self, name: []const u8, ms: i64) !void {
        try self.datapoint(name, .{ .ms = ms });
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // SOLANA-COMPATIBLE METRICS
    // These match the datapoints that Agave sends
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Report validator info (sent periodically)
    pub fn reportValidatorInfo(self: *Self, opts: struct {
        version: []const u8,
        shred_version: u16,
        feature_set: u32,
    }) !void {
        try self.datapoint("validator_info", .{
            .shred_version = opts.shred_version,
            .feature_set = opts.feature_set,
        });
        _ = opts.version;
    }
    
    /// Report current slot progress
    pub fn reportSlotStatus(self: *Self, opts: struct {
        slot: u64,
        root: u64,
        parent: u64,
        status: []const u8,
    }) !void {
        try self.datapoint("replay_slot", .{
            .slot = opts.slot,
            .root = opts.root,
            .parent = opts.parent,
        });
        _ = opts.status;
    }
    
    /// Report vote submission
    pub fn reportVote(self: *Self, opts: struct {
        slot: u64,
        vote_slot: u64,
        success: bool,
    }) !void {
        try self.datapoint("vote", .{
            .slot = opts.slot,
            .vote_slot = opts.vote_slot,
            .success = opts.success,
        });
    }
    
    /// Report transaction processing stats
    pub fn reportBankingStage(self: *Self, opts: struct {
        buffered_packets: u64,
        transactions_processed: u64,
        transactions_dropped: u64,
    }) !void {
        try self.datapoint("banking_stage", .{
            .buffered_packets = opts.buffered_packets,
            .transactions_processed = opts.transactions_processed,
            .transactions_dropped = opts.transactions_dropped,
        });
    }
    
    /// Report network stats
    pub fn reportGossipStats(self: *Self, opts: struct {
        packets_received: u64,
        packets_sent: u64,
        active_peers: u64,
    }) !void {
        try self.datapoint("gossip_stats", .{
            .packets_received = opts.packets_received,
            .packets_sent = opts.packets_sent,
            .active_peers = opts.active_peers,
        });
    }
    
    /// Report shred processing
    pub fn reportShredStats(self: *Self, opts: struct {
        shreds_received: u64,
        shreds_repaired: u64,
        slots_completed: u64,
    }) !void {
        try self.datapoint("shred_stats", .{
            .shreds_received = opts.shreds_received,
            .shreds_repaired = opts.shreds_repaired,
            .slots_completed = opts.slots_completed,
        });
    }
    
    /// Flush buffered metrics to InfluxDB
    pub fn flush(self: *Self) !void {
        if (self.buffer.items.len == 0) return;
        
        const data = try self.buffer.toOwnedSlice();
        defer self.allocator.free(data);
        
        self.last_flush = std.time.milliTimestamp();
        
        // Build URL: host/write?db=database
        const url = try std.fmt.allocPrint(self.allocator, "{s}/write?db={s}&u={s}&p={s}", .{
            self.config.host,
            self.config.db,
            self.config.user,
            self.config.password,
        });
        defer self.allocator.free(url);
        
        // Send HTTP POST (using child process for simplicity)
        // In production, use proper HTTP client
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "curl", "-s", "-X", "POST",
                "-H", "Content-Type: text/plain",
                "--data-binary", data,
                url,
            },
        }) catch |err| {
            std.log.warn("[Metrics] Failed to send to InfluxDB: {}", .{err});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        
        if (result.term.Exited != 0) {
            std.log.warn("[Metrics] InfluxDB returned error: {s}", .{result.stderr});
        }
    }
};

/// Global metrics reporter
pub var global_reporter: ?*InfluxReporter = null;

/// Initialize global reporter from environment
pub fn initFromEnv(allocator: Allocator, identity: []const u8, cluster: []const u8) !bool {
    const config = try InfluxConfig.fromEnv(allocator) orelse {
        std.log.info("[Metrics] SOLANA_METRICS_CONFIG not set, metrics disabled", .{});
        return false;
    };
    
    global_reporter = try InfluxReporter.init(allocator, config, identity, cluster);
    std.log.info("[Metrics] InfluxDB reporter initialized for {s}", .{config.host});
    return true;
}

/// Get global reporter
pub fn getReporter() ?*InfluxReporter {
    return global_reporter;
}

// ═══════════════════════════════════════════════════════════════════════════
// CONVENIENCE FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

/// Report a datapoint (if reporter is initialized)
pub fn datapoint(measurement: []const u8, fields: anytype) void {
    if (global_reporter) |r| {
        r.datapoint(measurement, fields) catch {};
    }
}

/// Shortcut for reporting slot
pub fn reportSlot(slot: u64, root: u64) void {
    if (global_reporter) |r| {
        r.reportSlotStatus(.{
            .slot = slot,
            .root = root,
            .parent = 0,
            .status = "confirmed",
        }) catch {};
    }
}

/// Shortcut for reporting a vote
pub fn reportVote(slot: u64, vote_slot: u64, success: bool) void {
    if (global_reporter) |r| {
        r.reportVote(.{
            .slot = slot,
            .vote_slot = vote_slot,
            .success = success,
        }) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "InfluxConfig: parse" {
    const config_str = "host=https://metrics.solana.com:8086,db=tds,u=testnet_write,p=secret123";
    const config = try InfluxConfig.parse(std.testing.allocator, config_str);
    defer std.testing.allocator.free(config.host);
    defer std.testing.allocator.free(config.db);
    defer std.testing.allocator.free(config.user);
    defer std.testing.allocator.free(config.password);
    
    try std.testing.expectEqualStrings("https://metrics.solana.com:8086", config.host);
    try std.testing.expectEqualStrings("tds", config.db);
    try std.testing.expectEqualStrings("testnet_write", config.user);
    try std.testing.expectEqualStrings("secret123", config.password);
}

