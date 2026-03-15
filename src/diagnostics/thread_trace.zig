//! Comprehensive Thread Leak Detector
//!
//! EXTREMELY DETAILED thread spawn tracking with:
//! - Full stack traces on every spawn
//! - Real-time spawn rate monitoring
//! - Emergency thread limit with automatic abort
//! - Process-level thread count from /proc/self/status
//! - Spawn location tracking with active thread counts
//! - Pool creation tracking (std.Thread.Pool)
//! - Child process tracking (std.process.Child)
//!
//! USAGE:
//! 1. Call `initGlobal()` at program start
//! 2. Replace `std.Thread.spawn` with `thread_trace.spawn`
//! 3. Call `checkThreadLimit()` periodically in main loop
//! 4. Call `printReport()` or `printDetailedReport()` for diagnostics

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// CONFIGURATION - Tune these for your debugging needs
// ============================================================================

/// Maximum allowed threads before emergency abort
pub const EMERGENCY_THREAD_LIMIT: u64 = 10_000;

/// Thread count at which we start printing warnings
pub const WARNING_THREAD_LIMIT: u64 = 500;

/// Print stack trace every N spawns (0 = disabled, 1 = every spawn)
pub const STACK_TRACE_INTERVAL: u64 = 1;

/// Maximum stack frames to capture
pub const MAX_STACK_FRAMES: usize = 32;

/// How often to check /proc/self/status (every N spawns)
pub const PROC_CHECK_INTERVAL: u64 = 100;

// ============================================================================
// SPAWN RECORD - Tracks each unique spawn location
// ============================================================================

pub const SpawnRecord = struct {
    /// Source file path
    file: []const u8,
    /// Function name
    func_name: []const u8,
    /// Line number
    line: u32,
    /// Column number
    column: u32,
    /// Number of times spawn was called from this location
    spawn_count: std.atomic.Value(u64),
    /// Number of times join was called
    join_count: std.atomic.Value(u64),
    /// Number of times detach was called
    detach_count: std.atomic.Value(u64),
    /// Currently active (spawned - joined - detached)
    active_count: std.atomic.Value(i64),
    /// First spawn timestamp (nanoseconds)
    first_spawn_ns: i128,
    /// Last spawn timestamp (nanoseconds)
    last_spawn_ns: std.atomic.Value(i128),
    /// Category of spawn
    category: SpawnCategory,

    pub const SpawnCategory = enum {
        direct_thread, // std.Thread.spawn
        thread_pool, // std.Thread.Pool.spawn (queued task, not new OS thread)
        child_process, // std.process.Child (spawns process with threads)
        io_worker, // I/O completion threads
        unknown,
    };

    pub fn getLeakScore(self: *const SpawnRecord) f64 {
        const spawned = self.spawn_count.load(.monotonic);
        _ = self.join_count.load(.monotonic); // tracked for reporting
        _ = self.detach_count.load(.monotonic); // tracked for reporting
        const active = self.active_count.load(.monotonic);

        if (spawned == 0) return 0;

        // Leak score: active threads / total spawned (higher = worse)
        // Detached threads are OK (they're managed), so we only count truly leaked
        const truly_leaked = @as(f64, @floatFromInt(active));
        const total = @as(f64, @floatFromInt(spawned));

        // Weight by active count (more active = worse)
        return (truly_leaked / total) * @as(f64, @floatFromInt(@max(1, active)));
    }
};

// ============================================================================
// SPAWN EVENT - Individual spawn with full context
// ============================================================================

pub const SpawnEvent = struct {
    timestamp_ns: i128,
    location_hash: u64,
    thread_id: u64,
    stack_trace: [MAX_STACK_FRAMES]usize,
    stack_len: usize,
    proc_thread_count: u64,
};

// ============================================================================
// THREAD TRACER - Main tracking structure
// ============================================================================

pub const ThreadTracer = struct {
    /// Map of source location hash -> SpawnRecord
    records: std.AutoHashMap(u64, *SpawnRecord),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    /// Total counts
    total_spawns: std.atomic.Value(u64),
    total_joins: std.atomic.Value(u64),
    total_detaches: std.atomic.Value(u64),
    total_active: std.atomic.Value(i64),

    /// Pool-specific tracking
    pool_creates: std.atomic.Value(u64),
    pool_destroys: std.atomic.Value(u64),
    pool_task_spawns: std.atomic.Value(u64),

    /// Child process tracking
    child_spawns: std.atomic.Value(u64),
    child_waits: std.atomic.Value(u64),

    /// Timestamps
    start_time_ns: i128,
    last_report_ns: std.atomic.Value(i128),

    /// Peak thread count seen from /proc
    peak_proc_threads: std.atomic.Value(u64),
    last_proc_threads: std.atomic.Value(u64),

    /// Recent spawn events for detailed analysis
    recent_events: [256]SpawnEvent,
    event_index: std.atomic.Value(usize),

    /// Emergency abort flag
    emergency_triggered: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const now = std.time.nanoTimestamp();
        return .{
            .records = std.AutoHashMap(u64, *SpawnRecord).init(allocator),
            .allocator = allocator,
            .mutex = .{},
            .total_spawns = std.atomic.Value(u64).init(0),
            .total_joins = std.atomic.Value(u64).init(0),
            .total_detaches = std.atomic.Value(u64).init(0),
            .total_active = std.atomic.Value(i64).init(0),
            .pool_creates = std.atomic.Value(u64).init(0),
            .pool_destroys = std.atomic.Value(u64).init(0),
            .pool_task_spawns = std.atomic.Value(u64).init(0),
            .child_spawns = std.atomic.Value(u64).init(0),
            .child_waits = std.atomic.Value(u64).init(0),
            .start_time_ns = now,
            .last_report_ns = std.atomic.Value(i128).init(now),
            .peak_proc_threads = std.atomic.Value(u64).init(0),
            .last_proc_threads = std.atomic.Value(u64).init(0),
            .recent_events = undefined,
            .event_index = std.atomic.Value(usize).init(0),
            .emergency_triggered = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.records.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.records.deinit();
    }

    /// Record a thread spawn with full context
    pub fn recordSpawn(
        self: *Self,
        file: []const u8,
        func_name: []const u8,
        line: u32,
        column: u32,
        category: SpawnRecord.SpawnCategory,
    ) void {
        const now = std.time.nanoTimestamp();
        const spawn_num = self.total_spawns.fetchAdd(1, .monotonic);
        _ = self.total_active.fetchAdd(1, .monotonic);

        const location_hash = computeHash(file, line, column);

        // Update or create record
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.get(location_hash)) |record| {
            _ = record.spawn_count.fetchAdd(1, .monotonic);
            _ = record.active_count.fetchAdd(1, .monotonic);
            record.last_spawn_ns.store(now, .monotonic);
        } else {
            const record = self.allocator.create(SpawnRecord) catch return;
            record.* = .{
                .file = file,
                .func_name = func_name,
                .line = line,
                .column = column,
                .spawn_count = std.atomic.Value(u64).init(1),
                .join_count = std.atomic.Value(u64).init(0),
                .detach_count = std.atomic.Value(u64).init(0),
                .active_count = std.atomic.Value(i64).init(1),
                .first_spawn_ns = now,
                .last_spawn_ns = std.atomic.Value(i128).init(now),
                .category = category,
            };
            self.records.put(location_hash, record) catch {
                self.allocator.destroy(record);
            };
        }

        // Store event with stack trace
        if (STACK_TRACE_INTERVAL > 0 and @mod(spawn_num, STACK_TRACE_INTERVAL) == 0) {
            self.captureEvent(location_hash, spawn_num);
        }

        // Check /proc thread count periodically
        if (@mod(spawn_num, PROC_CHECK_INTERVAL) == 0) {
            self.updateProcThreadCount();
        }

        // Print warning on first spawn from new location
        if (spawn_num == 0 or @mod(spawn_num + 1, 1000) == 0) {
            const active = self.total_active.load(.monotonic);
            const proc_threads = self.last_proc_threads.load(.monotonic);
            std.debug.print(
                \\[THREAD-TRACE] spawn #{d} from {s}:{d} ({s})
                \\               active_tracked={d} proc_threads={d}
                \\
            , .{ spawn_num + 1, file, line, func_name, active, proc_threads });
        }

        // Emergency check
        self.checkEmergencyLimit();
    }

    fn captureEvent(self: *Self, location_hash: u64, spawn_num: u64) void {
        var event: SpawnEvent = .{
            .timestamp_ns = std.time.nanoTimestamp(),
            .location_hash = location_hash,
            .thread_id = spawn_num,
            .stack_trace = undefined,
            .stack_len = 0,
            .proc_thread_count = self.last_proc_threads.load(.monotonic),
        };

        // Capture stack trace
        var stack_trace = std.builtin.StackTrace{
            .instruction_addresses = &event.stack_trace,
            .index = 0,
        };
        std.debug.captureStackTrace(@returnAddress(), &stack_trace);
        event.stack_len = stack_trace.index;

        // Store in circular buffer
        const idx = self.event_index.fetchAdd(1, .monotonic) % self.recent_events.len;
        self.recent_events[idx] = event;
    }

    fn updateProcThreadCount(self: *Self) void {
        const count = readProcThreadCount();
        self.last_proc_threads.store(count, .monotonic);

        // Update peak
        var peak = self.peak_proc_threads.load(.monotonic);
        while (count > peak) {
            const result = self.peak_proc_threads.cmpxchgWeak(peak, count, .monotonic, .monotonic);
            if (result) |new_peak| {
                peak = new_peak;
            } else {
                break;
            }
        }

        // Print warning if high
        if (count > WARNING_THREAD_LIMIT and @mod(count, 1000) < PROC_CHECK_INTERVAL) {
            std.debug.print(
                \\
                \\🚨🚨🚨 THREAD WARNING: /proc reports {d} threads! 🚨🚨🚨
                \\    Tracked spawns: {d}
                \\    Tracked active: {d}
                \\    Peak seen: {d}
                \\
                \\
            , .{
                count,
                self.total_spawns.load(.monotonic),
                self.total_active.load(.monotonic),
                self.peak_proc_threads.load(.monotonic),
            });
        }
    }

    fn checkEmergencyLimit(self: *Self) void {
        const proc_threads = self.last_proc_threads.load(.monotonic);
        if (proc_threads >= EMERGENCY_THREAD_LIMIT) {
            if (!self.emergency_triggered.swap(true, .seq_cst)) {
                std.debug.print(
                    \\
                    \\💀💀💀 EMERGENCY THREAD LIMIT REACHED: {d} >= {d} 💀💀💀
                    \\
                    \\PRINTING FULL DIAGNOSTIC REPORT BEFORE ABORT:
                    \\
                , .{ proc_threads, EMERGENCY_THREAD_LIMIT });

                self.printDetailedReport();
                self.printRecentEvents(20);

                std.debug.print("\n\n💀 ABORTING TO PREVENT SYSTEM CRASH 💀\n\n", .{});
                std.process.abort();
            }
        }
    }

    /// Record a thread join
    pub fn recordJoin(self: *Self, file: []const u8, line: u32, column: u32) void {
        const location_hash = computeHash(file, line, column);

        _ = self.total_joins.fetchAdd(1, .monotonic);
        _ = self.total_active.fetchSub(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.get(location_hash)) |record| {
            _ = record.join_count.fetchAdd(1, .monotonic);
            _ = record.active_count.fetchSub(1, .monotonic);
        }
    }

    /// Record a thread detach
    pub fn recordDetach(self: *Self, file: []const u8, line: u32, column: u32) void {
        const location_hash = computeHash(file, line, column);

        _ = self.total_detaches.fetchAdd(1, .monotonic);
        _ = self.total_active.fetchSub(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.get(location_hash)) |record| {
            _ = record.detach_count.fetchAdd(1, .monotonic);
            _ = record.active_count.fetchSub(1, .monotonic);
        }
    }

    /// Record thread pool creation
    pub fn recordPoolCreate(self: *Self) void {
        _ = self.pool_creates.fetchAdd(1, .monotonic);
    }

    /// Record thread pool destruction
    pub fn recordPoolDestroy(self: *Self) void {
        _ = self.pool_destroys.fetchAdd(1, .monotonic);
    }

    /// Record task spawn to pool (not an OS thread, just tracking)
    pub fn recordPoolTaskSpawn(self: *Self) void {
        _ = self.pool_task_spawns.fetchAdd(1, .monotonic);
    }

    /// Record child process spawn
    pub fn recordChildSpawn(self: *Self, file: []const u8, line: u32, column: u32) void {
        _ = self.child_spawns.fetchAdd(1, .monotonic);
        self.recordSpawn(file, "", line, column, .child_process);
    }

    /// Record child process wait
    pub fn recordChildWait(self: *Self) void {
        _ = self.child_waits.fetchAdd(1, .monotonic);
    }

    /// Print summary report
    pub fn printReport(self: *Self) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_time_ns;
        const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        const total_spawns = self.total_spawns.load(.monotonic);
        const total_joins = self.total_joins.load(.monotonic);
        const total_detaches = self.total_detaches.load(.monotonic);
        const total_active = self.total_active.load(.monotonic);
        const proc_threads = readProcThreadCount();

        std.debug.print(
            \\
            \\╔══════════════════════════════════════════════════════════════════════╗
            \\║                    🔍 THREAD TRACE REPORT 🔍                         ║
            \\╠══════════════════════════════════════════════════════════════════════╣
            \\║  Elapsed:        {d:.1}s                                             
            \\║  /proc threads:  {d:<10} (ACTUAL OS THREADS)                         
            \\║  Peak threads:   {d:<10}                                              
            \\╠══════════════════════════════════════════════════════════════════════╣
            \\║  Tracked spawns: {d:<10}                                              
            \\║  Tracked joins:  {d:<10}                                              
            \\║  Tracked detach: {d:<10}                                              
            \\║  Tracked active: {d:<10}                                              
            \\║  Spawn rate:     {d:.1}/sec                                           
            \\╠══════════════════════════════════════════════════════════════════════╣
            \\║  Pool creates:   {d:<10}                                              
            \\║  Pool destroys:  {d:<10}                                              
            \\║  Pool tasks:     {d:<10}                                              
            \\║  Child spawns:   {d:<10}                                              
            \\║  Child waits:    {d:<10}                                              
            \\╚══════════════════════════════════════════════════════════════════════╝
            \\
        , .{
            elapsed_sec,
            proc_threads,
            self.peak_proc_threads.load(.monotonic),
            total_spawns,
            total_joins,
            total_detaches,
            total_active,
            if (elapsed_sec > 0) @as(f64, @floatFromInt(total_spawns)) / elapsed_sec else 0,
            self.pool_creates.load(.monotonic),
            self.pool_destroys.load(.monotonic),
            self.pool_task_spawns.load(.monotonic),
            self.child_spawns.load(.monotonic),
            self.child_waits.load(.monotonic),
        });

        self.last_report_ns.store(now, .monotonic);
    }

    /// Print detailed report with per-location breakdown
    pub fn printDetailedReport(self: *Self) void {
        self.printReport();

        std.debug.print(
            \\
            \\╔══════════════════════════════════════════════════════════════════════╗
            \\║              📍 SPAWN LOCATIONS (sorted by leak score)               ║
            \\╠══════════════════════════════════════════════════════════════════════╣
            \\
        , .{});

        // Collect records and sort by leak score
        self.mutex.lock();
        defer self.mutex.unlock();

        var records_list = std.ArrayList(struct { hash: u64, record: *SpawnRecord, score: f64 }).init(self.allocator);
        defer records_list.deinit();

        var iter = self.records.iterator();
        while (iter.next()) |entry| {
            const record = entry.value_ptr.*;
            records_list.append(.{
                .hash = entry.key_ptr.*,
                .record = record,
                .score = record.getLeakScore(),
            }) catch continue;
        }

        // Sort by leak score descending
        std.mem.sort(@TypeOf(records_list.items[0]), records_list.items, {}, struct {
            fn lessThan(_: void, a: anytype, b: anytype) bool {
                return a.score > b.score;
            }
        }.lessThan);

        var printed: usize = 0;
        for (records_list.items) |item| {
            const record = item.record;
            const spawned = record.spawn_count.load(.monotonic);
            const joined = record.join_count.load(.monotonic);
            const detached = record.detach_count.load(.monotonic);
            const active = record.active_count.load(.monotonic);

            const leak_indicator: []const u8 = if (active > 100)
                "🚨 CRITICAL LEAK"
            else if (active > 10)
                "⚠️  POSSIBLE LEAK"
            else if (active > 0)
                "📋 ACTIVE"
            else
                "✅ OK";

            std.debug.print(
                \\║  {s}
                \\║  📍 {s}:{d}:{d}
                \\║     fn: {s}
                \\║     category: {s}
                \\║     spawned={d} joined={d} detached={d} ACTIVE={d}
                \\║     leak_score={d:.2}
                \\╠──────────────────────────────────────────────────────────────────────
                \\
            , .{
                leak_indicator,
                record.file,
                record.line,
                record.column,
                record.func_name,
                @tagName(record.category),
                spawned,
                joined,
                detached,
                active,
                item.score,
            });

            printed += 1;
            if (printed >= 20) {
                std.debug.print("║  ... ({d} more locations)\n", .{records_list.items.len - printed});
                break;
            }
        }

        std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    }

    /// Print recent spawn events with stack traces
    pub fn printRecentEvents(self: *Self, count: usize) void {
        std.debug.print(
            \\
            \\╔══════════════════════════════════════════════════════════════════════╗
            \\║                    📜 RECENT SPAWN EVENTS                            ║
            \\╠══════════════════════════════════════════════════════════════════════╣
            \\
        , .{});

        const current_idx = self.event_index.load(.monotonic);
        const start_idx = if (current_idx > count) current_idx - count else 0;

        var i: usize = start_idx;
        while (i < current_idx and i - start_idx < count) : (i += 1) {
            const event = self.recent_events[i % self.recent_events.len];
            const elapsed_ns = std.time.nanoTimestamp() - event.timestamp_ns;
            const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

            std.debug.print(
                \\║  Event #{d} ({d:.1}ms ago) proc_threads={d}
                \\║  Stack trace:
                \\
            , .{ event.thread_id, elapsed_ms, event.proc_thread_count });

            // Print stack trace
            if (event.stack_len > 0) {
                const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                    std.debug.print("║    (failed to get debug info: {})\n", .{err});
                    continue;
                };

                for (event.stack_trace[0..event.stack_len]) |addr| {
                    std.debug.printSourceAtAddress(debug_info, @ptrFromInt(addr), addr, null) catch {};
                }
            } else {
                std.debug.print("║    (no stack trace captured)\n", .{});
            }

            std.debug.print("╠──────────────────────────────────────────────────────────────────────\n", .{});
        }

        std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    }

    fn computeHash(file: []const u8, line: u32, column: u32) u64 {
        var hash: u64 = 0xcbf29ce484222325; // FNV-1a offset
        for (file) |c| {
            hash ^= c;
            hash *%= 0x100000001b3;
        }
        hash ^= @as(u64, line) << 16 | @as(u64, column);
        hash *%= 0x100000001b3;
        return hash;
    }
};

// ============================================================================
// GLOBAL TRACER INSTANCE
// ============================================================================

var global_tracer: ?*ThreadTracer = null;
var global_tracer_mutex: std.Thread.Mutex = .{};

/// Initialize global thread tracer - CALL THIS FIRST IN MAIN
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_tracer_mutex.lock();
    defer global_tracer_mutex.unlock();

    if (global_tracer != null) return;

    const tracer = try allocator.create(ThreadTracer);
    tracer.* = ThreadTracer.init(allocator);
    global_tracer = tracer;

    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════════════╗
        \\║            🔍 THREAD TRACER INITIALIZED 🔍                           ║
        \\║  Emergency limit: {d} threads                                        
        \\║  Warning limit:   {d} threads                                        
        \\║  Stack trace interval: every {d} spawns                              
        \\╚══════════════════════════════════════════════════════════════════════╝
        \\
    , .{ EMERGENCY_THREAD_LIMIT, WARNING_THREAD_LIMIT, STACK_TRACE_INTERVAL });
}

/// Get global tracer
pub fn getGlobal() ?*ThreadTracer {
    return global_tracer;
}

// ============================================================================
// TRACKED THREAD WRAPPER - Use instead of std.Thread
// ============================================================================

/// Tracked thread handle that records joins/detaches
pub fn TrackedThread(comptime F: type) type {
    return struct {
        thread: std.Thread,
        file: []const u8,
        line: u32,
        column: u32,

        const Self = @This();

        pub fn join(self: Self) F {
            const result = self.thread.join();
            if (global_tracer) |tracer| {
                tracer.recordJoin(self.file, self.line, self.column);
            }
            return result;
        }

        pub fn detach(self: Self) void {
            self.thread.detach();
            if (global_tracer) |tracer| {
                tracer.recordDetach(self.file, self.line, self.column);
            }
        }
    };
}

/// Spawn a tracked thread - USE THIS INSTEAD OF std.Thread.spawn
pub fn spawn(
    src: std.builtin.SourceLocation,
    comptime function: anytype,
    args: anytype,
) !TrackedThread(@typeInfo(@TypeOf(function)).Fn.return_type orelse void) {
    if (global_tracer) |tracer| {
        tracer.recordSpawn(src.file, src.fn_name, src.line, src.column, .direct_thread);
    }

    const thread = try std.Thread.spawn(.{}, function, args);

    return .{
        .thread = thread,
        .file = src.file,
        .line = src.line,
        .column = src.column,
    };
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Read actual thread count from /proc/self/status
pub fn readProcThreadCount() u64 {
    const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.read(&buf) catch return 0;
    const content = buf[0..bytes_read];

    // Find "Threads:\t<number>"
    if (std.mem.indexOf(u8, content, "Threads:")) |idx| {
        var num_start = idx + 8;
        while (num_start < content.len and (content[num_start] == ' ' or content[num_start] == '\t')) {
            num_start += 1;
        }
        var num_end = num_start;
        while (num_end < content.len and content[num_end] >= '0' and content[num_end] <= '9') {
            num_end += 1;
        }
        if (num_end > num_start) {
            return std.fmt.parseInt(u64, content[num_start..num_end], 10) catch 0;
        }
    }
    return 0;
}

/// Check thread limit - call this periodically in main loop
pub fn checkThreadLimit() void {
    if (global_tracer) |tracer| {
        tracer.updateProcThreadCount();
        tracer.checkEmergencyLimit();
    }
}

/// Print summary report
pub fn printReport() void {
    if (global_tracer) |tracer| {
        tracer.printReport();
    } else {
        std.debug.print("[ThreadTrace] Tracer not initialized\n", .{});
    }
}

/// Print detailed report with all locations
pub fn printDetailedReport() void {
    if (global_tracer) |tracer| {
        tracer.printDetailedReport();
    } else {
        std.debug.print("[ThreadTrace] Tracer not initialized\n", .{});
    }
}

/// Print recent events with stack traces
pub fn printRecentEvents(count: usize) void {
    if (global_tracer) |tracer| {
        tracer.printRecentEvents(count);
    }
}

/// Get current stats
pub fn getStats() ?struct {
    total_spawns: u64,
    total_joins: u64,
    total_active: i64,
    proc_threads: u64,
    peak_threads: u64,
    elapsed_seconds: f64,
} {
    if (global_tracer) |tracer| {
        const elapsed_ns = std.time.nanoTimestamp() - tracer.start_time_ns;
        return .{
            .total_spawns = tracer.total_spawns.load(.monotonic),
            .total_joins = tracer.total_joins.load(.monotonic),
            .total_active = tracer.total_active.load(.monotonic),
            .proc_threads = tracer.last_proc_threads.load(.monotonic),
            .peak_threads = tracer.peak_proc_threads.load(.monotonic),
            .elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0,
        };
    }
    return null;
}

// ============================================================================
// KERNEL THREAD DETECTION (io_uring workers, etc.)
// ============================================================================

/// Thread classification for kernel-created threads
pub const KernelThreadType = enum {
    userland, // Normal std.Thread.spawn threads
    io_uring_worker, // iou-wrk-* (io_uring bounded workers)
    io_uring_sqpoll, // iou-sqp-* (SQPOLL threads)
    kworker, // kworker/* (kernel work queues)
    other_kernel, // Other kernel threads
};

/// Info about a thread from /proc/self/task
pub const ThreadInfo = struct {
    tid: u32,
    name: [16]u8,
    name_len: usize,
    thread_type: KernelThreadType,

    pub fn getName(self: *const ThreadInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Kernel thread statistics
pub const KernelThreadStats = struct {
    total_threads: u64,
    userland_threads: u64,
    io_uring_workers: u64,
    io_uring_sqpoll: u64,
    kworkers: u64,
    other_kernel: u64,
};

/// Enumerate all threads in /proc/self/task and classify them
/// Returns statistics about kernel vs userland threads
pub fn enumerateKernelThreads(allocator: std.mem.Allocator) !KernelThreadStats {
    var stats = KernelThreadStats{
        .total_threads = 0,
        .userland_threads = 0,
        .io_uring_workers = 0,
        .io_uring_sqpoll = 0,
        .kworkers = 0,
        .other_kernel = 0,
    };

    var dir = std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true }) catch |err| {
        std.debug.print("[ThreadTrace] Failed to open /proc/self/task: {}\n", .{err});
        return stats;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Parse TID from directory name
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        stats.total_threads += 1;

        // Read thread name from /proc/self/task/[tid]/comm
        var path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "/proc/self/task/{s}/comm", .{entry.name}) catch continue;

        const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer comm_file.close();

        var name_buf: [17]u8 = undefined;
        const len = comm_file.read(&name_buf) catch continue;
        if (len == 0) continue;

        // Remove trailing newline
        const name_len = if (len > 0 and name_buf[len - 1] == '\n') len - 1 else len;
        const name = name_buf[0..name_len];

        // Classify thread
        if (std.mem.startsWith(u8, name, "iou-wrk-")) {
            stats.io_uring_workers += 1;
        } else if (std.mem.startsWith(u8, name, "iou-sqp-")) {
            stats.io_uring_sqpoll += 1;
        } else if (std.mem.startsWith(u8, name, "kworker/")) {
            stats.kworkers += 1;
        } else if (std.mem.startsWith(u8, name, "io_wq")) {
            stats.io_uring_workers += 1; // Older naming
        } else {
            stats.userland_threads += 1;
        }
    }

    _ = allocator; // Reserved for future use
    return stats;
}

/// Print detailed kernel thread breakdown
pub fn printKernelThreadReport() void {
    const stats = enumerateKernelThreads(std.heap.page_allocator) catch |err| {
        std.debug.print("[ThreadTrace] Failed to enumerate kernel threads: {}\n", .{err});
        return;
    };

    const io_total = stats.io_uring_workers + stats.io_uring_sqpoll;

    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════════════╗
        \\║                 🔬 KERNEL THREAD BREAKDOWN 🔬                        ║
        \\╠══════════════════════════════════════════════════════════════════════╣
        \\║  Total threads:      {d:<10}                                        
        \\║  ────────────────────────────────────────────────────────────────────
        \\║  Userland threads:   {d:<10} (std.Thread.spawn)                     
        \\║  io_uring workers:   {d:<10} (iou-wrk-*, IORING bounded)            
        \\║  io_uring sqpoll:    {d:<10} (iou-sqp-*, SQPOLL mode)               
        \\║  kworkers:           {d:<10} (kernel work queues)                   
        \\║  Other:              {d:<10}                                        
        \\╠══════════════════════════════════════════════════════════════════════╣
    , .{
        stats.total_threads,
        stats.userland_threads,
        stats.io_uring_workers,
        stats.io_uring_sqpoll,
        stats.kworkers,
        stats.other_kernel,
    });

    // Warning if io_uring is scaling out of control
    if (io_total > 100) {
        std.debug.print(
            \\║  🚨 WARNING: {d} io_uring threads detected!                      
            \\║     This indicates unconstrained IORING worker pool scaling.     
            \\║     FIX: Use IORING_REGISTER_IOWQ_MAX_WORKERS to cap workers.    
            \\╚══════════════════════════════════════════════════════════════════════╝
            \\
        , .{io_total});
    } else {
        std.debug.print(
            \\║  ✅ io_uring thread count looks healthy                          
            \\╚══════════════════════════════════════════════════════════════════════╝
            \\
        , .{});
    }
}

/// Quick check if io_uring workers are exploding (for emergency detection)
pub fn checkIoUringWorkers() u64 {
    var count: u64 = 0;

    var dir = std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        var path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "/proc/self/task/{s}/comm", .{entry.name}) catch continue;

        const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer comm_file.close();

        var name_buf: [17]u8 = undefined;
        const len = comm_file.read(&name_buf) catch continue;
        if (len == 0) continue;

        const name = name_buf[0..@min(len, 8)];
        if (std.mem.startsWith(u8, name, "iou-wrk-") or std.mem.startsWith(u8, name, "io_wq")) {
            count += 1;
        }
    }

    return count;
}

// ============================================================================
// TESTS
// ============================================================================

test "thread tracer basic" {
    const allocator = std.testing.allocator;

    try initGlobal(allocator);
    defer {
        if (global_tracer) |t| {
            t.deinit();
            allocator.destroy(t);
            global_tracer = null;
        }
    }

    const tracer = getGlobal().?;
    tracer.recordSpawn("test.zig", "testFn", 42, 0, .direct_thread);
    tracer.recordSpawn("test.zig", "testFn", 42, 0, .direct_thread);
    tracer.recordSpawn("other.zig", "otherFn", 100, 0, .direct_thread);
    tracer.recordJoin("test.zig", 42, 0);

    try std.testing.expectEqual(@as(u64, 3), tracer.total_spawns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), tracer.total_joins.load(.monotonic));
    try std.testing.expectEqual(@as(i64, 2), tracer.total_active.load(.monotonic));
}

test "proc thread count" {
    const count = readProcThreadCount();
    // Should always have at least 1 thread (main)
    try std.testing.expect(count >= 1);
}
