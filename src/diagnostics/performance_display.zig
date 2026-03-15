//! Real-time Performance Display
//!
//! High-performance metrics tracking inspired by Firedancer's approach.
//! Designed for minimal overhead with atomic operations.
//!
//! Key design principles (from Firedancer):
//! - All metrics are ulong/u64 for atomic access
//! - Cache-line aligned to prevent false sharing
//! - High-frequency metrics batched and drained periodically
//! - TPS calculated from sliding window of completed slots
//!
//! Target benchmarks:
//! - Agave: ~50,000 TPS (theoretical max)
//! - Firedancer: ~1,000,000 TPS (theoretical max)
//! - Vexor goal: Match or exceed Firedancer

const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

/// Cache line size for alignment
pub const CACHE_LINE_SIZE = 128;

/// TPS history window duration in seconds (like Firedancer's 10s)
pub const TPS_WINDOW_SECONDS: u64 = 10;

/// Number of TPS samples to keep (like Firedancer's 150)
pub const TPS_HISTORY_COUNT: usize = 150;

/// Slot-level transaction counts
pub const SlotStats = struct {
    slot: u64,
    completed_time_ns: i128,
    total_txn_cnt: u64,
    vote_txn_cnt: u64,
    nonvote_failed_cnt: u64,
    skipped: bool,
};

/// Core metrics - aligned to cache line to prevent false sharing
pub const CoreMetrics = struct {
    // Transaction metrics
    transactions_received: Atomic(u64) align(CACHE_LINE_SIZE),
    transactions_processed: Atomic(u64),
    transactions_failed: Atomic(u64),
    votes_processed: Atomic(u64),
    
    // Network metrics
    packets_received: Atomic(u64) align(CACHE_LINE_SIZE),
    packets_sent: Atomic(u64),
    bytes_received: Atomic(u64),
    bytes_sent: Atomic(u64),
    
    // Shred metrics
    shreds_received: Atomic(u64) align(CACHE_LINE_SIZE),
    shreds_inserted: Atomic(u64),
    shreds_invalid: Atomic(u64),
    shreds_duplicate: Atomic(u64),
    
    // Gossip metrics
    peers_connected: Atomic(u32) align(CACHE_LINE_SIZE),
    crds_values_received: Atomic(u64),
    pull_requests_sent: Atomic(u64),
    push_messages_sent: Atomic(u64),
    
    // Slot metrics
    current_slot: Atomic(u64) align(CACHE_LINE_SIZE),
    slots_processed: Atomic(u64),
    slots_skipped: Atomic(u64),
    
    // XDP/AF_XDP specific (for benchmarking)
    xdp_rx_packets: Atomic(u64) align(CACHE_LINE_SIZE),
    xdp_tx_packets: Atomic(u64),
    xdp_rx_wakeups: Atomic(u64),
    xdp_tx_wakeups: Atomic(u64),
    xdp_rx_ring_full: Atomic(u64),
    xdp_fill_ring_empty: Atomic(u64),
    
    // Timing metrics (nanoseconds)
    slot_processing_time_ns: Atomic(u64) align(CACHE_LINE_SIZE),
    vote_latency_ns: Atomic(u64),
    
    pub fn init() CoreMetrics {
        return .{
            .transactions_received = Atomic(u64).init(0),
            .transactions_processed = Atomic(u64).init(0),
            .transactions_failed = Atomic(u64).init(0),
            .votes_processed = Atomic(u64).init(0),
            .packets_received = Atomic(u64).init(0),
            .packets_sent = Atomic(u64).init(0),
            .bytes_received = Atomic(u64).init(0),
            .bytes_sent = Atomic(u64).init(0),
            .shreds_received = Atomic(u64).init(0),
            .shreds_inserted = Atomic(u64).init(0),
            .shreds_invalid = Atomic(u64).init(0),
            .shreds_duplicate = Atomic(u64).init(0),
            .peers_connected = Atomic(u32).init(0),
            .crds_values_received = Atomic(u64).init(0),
            .pull_requests_sent = Atomic(u64).init(0),
            .push_messages_sent = Atomic(u64).init(0),
            .current_slot = Atomic(u64).init(0),
            .slots_processed = Atomic(u64).init(0),
            .slots_skipped = Atomic(u64).init(0),
            .xdp_rx_packets = Atomic(u64).init(0),
            .xdp_tx_packets = Atomic(u64).init(0),
            .xdp_rx_wakeups = Atomic(u64).init(0),
            .xdp_tx_wakeups = Atomic(u64).init(0),
            .xdp_rx_ring_full = Atomic(u64).init(0),
            .xdp_fill_ring_empty = Atomic(u64).init(0),
            .slot_processing_time_ns = Atomic(u64).init(0),
            .vote_latency_ns = Atomic(u64).init(0),
        };
    }
    
    // Convenience increment functions for hot paths
    pub fn incTxReceived(self: *CoreMetrics) void {
        _ = self.transactions_received.fetchAdd(1, .monotonic);
    }
    
    pub fn incTxProcessed(self: *CoreMetrics) void {
        _ = self.transactions_processed.fetchAdd(1, .monotonic);
    }
    
    pub fn incPacketsReceived(self: *CoreMetrics, count: u64) void {
        _ = self.packets_received.fetchAdd(count, .monotonic);
    }
    
    pub fn incShredsReceived(self: *CoreMetrics, count: u64) void {
        _ = self.shreds_received.fetchAdd(count, .monotonic);
    }
};

/// TPS history entry
pub const TpsHistoryEntry = struct {
    total_txn: u64,
    vote_txn: u64,
    nonvote_failed: u64,
    timestamp_ns: i128,
};

/// TPS Calculator - Firedancer-style sliding window
pub const TpsCalculator = struct {
    allocator: Allocator,
    
    /// Circular buffer of completed slot stats
    slot_history: []SlotStats,
    slot_history_idx: usize,
    slot_history_count: usize,
    
    /// TPS history samples (like Firedancer's estimated_tps_history)
    tps_history: [TPS_HISTORY_COUNT]TpsHistoryEntry,
    tps_history_idx: usize,
    
    /// Calculated TPS values
    current_tps: f64,
    current_vote_tps: f64,
    current_nonvote_success_tps: f64,
    current_nonvote_failed_tps: f64,
    peak_tps: f64,
    
    /// Packet rates
    current_pps: f64, // Packets per second
    peak_pps: f64,
    
    /// Shred rates
    current_sps: f64, // Shreds per second
    
    /// Last snapshot for delta calculation
    last_snapshot_time_ns: i128,
    last_packets: u64,
    last_shreds: u64,
    
    const SLOT_HISTORY_SIZE = 1024; // Track last 1024 slots
    
    pub fn init(allocator: Allocator) !*TpsCalculator {
        const calc = try allocator.create(TpsCalculator);
        calc.* = TpsCalculator{
            .allocator = allocator,
            .slot_history = try allocator.alloc(SlotStats, SLOT_HISTORY_SIZE),
            .slot_history_idx = 0,
            .slot_history_count = 0,
            .tps_history = undefined,
            .tps_history_idx = 0,
            .current_tps = 0,
            .current_vote_tps = 0,
            .current_nonvote_success_tps = 0,
            .current_nonvote_failed_tps = 0,
            .peak_tps = 0,
            .current_pps = 0,
            .peak_pps = 0,
            .current_sps = 0,
            .last_snapshot_time_ns = std.time.nanoTimestamp(),
            .last_packets = 0,
            .last_shreds = 0,
        };
        @memset(&calc.tps_history, TpsHistoryEntry{
            .total_txn = 0,
            .vote_txn = 0,
            .nonvote_failed = 0,
            .timestamp_ns = 0,
        });
        return calc;
    }
    
    pub fn deinit(self: *TpsCalculator) void {
        self.allocator.free(self.slot_history);
        self.allocator.destroy(self);
    }
    
    /// Record a completed slot (like Firedancer's slot tracking)
    pub fn recordSlotCompleted(self: *TpsCalculator, slot: u64, total_txn: u64, vote_txn: u64, failed_txn: u64, skipped: bool) void {
        const idx = self.slot_history_idx;
        self.slot_history[idx] = SlotStats{
            .slot = slot,
            .completed_time_ns = std.time.nanoTimestamp(),
            .total_txn_cnt = total_txn,
            .vote_txn_cnt = vote_txn,
            .nonvote_failed_cnt = failed_txn,
            .skipped = skipped,
        };
        self.slot_history_idx = (self.slot_history_idx + 1) % SLOT_HISTORY_SIZE;
        if (self.slot_history_count < SLOT_HISTORY_SIZE) {
            self.slot_history_count += 1;
        }
    }
    
    /// Take a TPS snapshot (call every ~400ms like Firedancer)
    pub fn snapshotTps(self: *TpsCalculator) void {
        const now = std.time.nanoTimestamp();
        const window_ns: i128 = TPS_WINDOW_SECONDS * 1_000_000_000;
        
        var total_txn: u64 = 0;
        var vote_txn: u64 = 0;
        var nonvote_failed: u64 = 0;
        
        // Sum transactions from slots within the window
        var i: usize = 0;
        while (i < self.slot_history_count) : (i += 1) {
            const idx = if (self.slot_history_idx >= i + 1)
                self.slot_history_idx - i - 1
            else
                SLOT_HISTORY_SIZE - (i + 1 - self.slot_history_idx);
            
            const slot = &self.slot_history[idx];
            
            // Skip if outside window
            if (slot.completed_time_ns + window_ns < now) break;
            
            // Skip skipped slots
            if (slot.skipped) continue;
            
            total_txn += slot.total_txn_cnt;
            vote_txn += slot.vote_txn_cnt;
            nonvote_failed += slot.nonvote_failed_cnt;
        }
        
        // Store in history
        self.tps_history[self.tps_history_idx] = TpsHistoryEntry{
            .total_txn = total_txn,
            .vote_txn = vote_txn,
            .nonvote_failed = nonvote_failed,
            .timestamp_ns = now,
        };
        self.tps_history_idx = (self.tps_history_idx + 1) % TPS_HISTORY_COUNT;
        
        // Calculate TPS
        const window_seconds: f64 = @floatFromInt(TPS_WINDOW_SECONDS);
        self.current_tps = @as(f64, @floatFromInt(total_txn)) / window_seconds;
        self.current_vote_tps = @as(f64, @floatFromInt(vote_txn)) / window_seconds;
        self.current_nonvote_failed_tps = @as(f64, @floatFromInt(nonvote_failed)) / window_seconds;
        self.current_nonvote_success_tps = self.current_tps - self.current_vote_tps - self.current_nonvote_failed_tps;
        
        if (self.current_tps > self.peak_tps) {
            self.peak_tps = self.current_tps;
        }
    }
    
    /// Update packet/shred rates from core metrics
    pub fn updateRates(self: *TpsCalculator, metrics: *const CoreMetrics) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_snapshot_time_ns;
        
        if (elapsed_ns > 0) {
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            
            const packets = metrics.packets_received.load(.monotonic);
            const shreds = metrics.shreds_received.load(.monotonic);
            
            self.current_pps = @as(f64, @floatFromInt(packets - self.last_packets)) / elapsed_s;
            self.current_sps = @as(f64, @floatFromInt(shreds - self.last_shreds)) / elapsed_s;
            
            if (self.current_pps > self.peak_pps) {
                self.peak_pps = self.current_pps;
            }
            
            self.last_packets = packets;
            self.last_shreds = shreds;
            self.last_snapshot_time_ns = now;
        }
    }
};

/// Get performance rating based on TPS (returns ANSI-colored string)
fn getPerformanceRating(tps: f64) []const u8 {
    if (tps >= 1_000_000) return "\x1b[35m🚀 BLAZING\x1b[0m  ";
    if (tps >= 500_000) return "\x1b[35m⚡ EXCELLENT\x1b[0m";
    if (tps >= 100_000) return "\x1b[32m✅ GREAT\x1b[0m    ";
    if (tps >= 50_000) return "\x1b[32m👍 GOOD\x1b[0m     ";
    if (tps >= 10_000) return "\x1b[33m📈 OK\x1b[0m       ";
    if (tps >= 1_000) return "\x1b[33m⚠️  LOW\x1b[0m      ";
    return "\x1b[36m🔄 STARTING\x1b[0m ";
}

/// Print the full performance dashboard
pub fn printDashboard(calc: *const TpsCalculator, metrics: *const CoreMetrics, uptime_s: f64) void {
    const rating = getPerformanceRating(calc.current_tps);
    
    std.debug.print(
        \\
        \\\x1b[1;36m┌─────────────────────────────────────────────────────────────────────┐\x1b[0m
        \\\x1b[1;36m│\x1b[0m                    \x1b[1;37mVEXOR PERFORMANCE DASHBOARD\x1b[0m                    \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[1;33mTPS (Current):\x1b[0m     {d:>12.0}  \x1b[1;36m│\x1b[0m  Rating: {s}     \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[1;33mTPS (Peak):\x1b[0m        {d:>12.0}  \x1b[1;36m│\x1b[0m  Uptime: {d:>7.1}s          \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[33mVote TPS:\x1b[0m          {d:>12.0}  \x1b[1;36m│\x1b[0m                             \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[33mNon-Vote Success:\x1b[0m  {d:>12.0}  \x1b[1;36m│\x1b[0m                             \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[31mNon-Vote Failed:\x1b[0m   {d:>12.0}  \x1b[1;36m│\x1b[0m                             \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[1;32mPackets/sec:\x1b[0m       {d:>12.0}  \x1b[1;36m│\x1b[0m  \x1b[1;32mShreds/sec:\x1b[0m   {d:>12.0}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  \x1b[32mPeak Pkts/sec:\x1b[0m     {d:>12.0}  \x1b[1;36m│\x1b[0m                             \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
        \\\x1b[1;36m│\x1b[0m  TX Processed:      {d:>12}  \x1b[1;36m│\x1b[0m  TX Failed:   {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  Votes Processed:   {d:>12}  \x1b[1;36m│\x1b[0m  Peers:       {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  Current Slot:      {d:>12}  \x1b[1;36m│\x1b[0m  Slots Done:  {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
        \\\x1b[1;36m│\x1b[0m  Shreds Rcvd:       {d:>12}  \x1b[1;36m│\x1b[0m  Inserted:    {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  CRDS Values:       {d:>12}  \x1b[1;36m│\x1b[0m  Invalid:     {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
        \\\x1b[1;36m│\x1b[0m  XDP RX Pkts:       {d:>12}  \x1b[1;36m│\x1b[0m  XDP TX Pkts: {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  XDP RX Wakeups:    {d:>12}  \x1b[1;36m│\x1b[0m  Ring Full:   {d:>12}  \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m└─────────────────────────────────────────────────────────────────────┘\x1b[0m
        \\
    , .{
        calc.current_tps,
        rating,
        calc.peak_tps,
        uptime_s,
        calc.current_vote_tps,
        calc.current_nonvote_success_tps,
        calc.current_nonvote_failed_tps,
        calc.current_pps,
        calc.current_sps,
        calc.peak_pps,
        metrics.transactions_processed.load(.monotonic),
        metrics.transactions_failed.load(.monotonic),
        metrics.votes_processed.load(.monotonic),
        metrics.peers_connected.load(.monotonic),
        metrics.current_slot.load(.monotonic),
        metrics.slots_processed.load(.monotonic),
        metrics.shreds_received.load(.monotonic),
        metrics.shreds_inserted.load(.monotonic),
        metrics.crds_values_received.load(.monotonic),
        metrics.shreds_invalid.load(.monotonic),
        metrics.xdp_rx_packets.load(.monotonic),
        metrics.xdp_tx_packets.load(.monotonic),
        metrics.xdp_rx_wakeups.load(.monotonic),
        metrics.xdp_rx_ring_full.load(.monotonic),
    });
}

/// Print a compact one-line status (for frequent updates without clearing screen)
pub fn printStatusLine(calc: *const TpsCalculator, metrics: *const CoreMetrics) void {
    std.debug.print(
        "TPS: {d:>8.0} | Peak: {d:>8.0} | Pkts/s: {d:>10.0} | Shreds: {d:>8} | Peers: {d:>4} | Slot: {d}\n",
        .{
            calc.current_tps,
            calc.peak_tps,
            calc.current_pps,
            metrics.shreds_received.load(.monotonic),
            metrics.peers_connected.load(.monotonic),
            metrics.current_slot.load(.monotonic),
        },
    );
}

/// Print comparison with Agave/Firedancer
pub fn printComparison(calc: *const TpsCalculator) void {
    const agave_max: f64 = 50_000;
    const firedancer_max: f64 = 1_000_000;
    
    const vs_agave = (calc.current_tps / agave_max) * 100.0;
    const vs_firedancer = (calc.current_tps / firedancer_max) * 100.0;
    
    // Cap at 100% for display
    const agave_pct = @min(vs_agave, 100.0);
    const fd_pct = @min(vs_firedancer, 100.0);
    
    // Create progress bars
    const agave_bars = @as(usize, @intFromFloat(agave_pct / 5.0)); // 20 chars = 100%
    const fd_bars = @as(usize, @intFromFloat(fd_pct / 5.0));
    
    std.debug.print(
        \\
        \\\x1b[1;36m┌────────────────── COMPARISON ───────────────────┐\x1b[0m
        \\\x1b[1;36m│\x1b[0m  vs Agave (50K TPS):      {d:>6.1}%%               \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  [{s:<20}]                      \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  vs Firedancer (1M TPS):  {d:>6.1}%%               \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m│\x1b[0m  [{s:<20}]                      \x1b[1;36m│\x1b[0m
        \\\x1b[1;36m└─────────────────────────────────────────────────┘\x1b[0m
        \\
    , .{
        vs_agave,
        generateBar(agave_bars),
        vs_firedancer,
        generateBar(fd_bars),
    });
}

fn generateBar(filled: usize) *const [20]u8 {
    const bars = [_][20]u8{
        "                    ".*,
        "█                   ".*,
        "██                  ".*,
        "███                 ".*,
        "████                ".*,
        "█████               ".*,
        "██████              ".*,
        "███████             ".*,
        "████████            ".*,
        "█████████           ".*,
        "██████████          ".*,
        "███████████         ".*,
        "████████████        ".*,
        "█████████████       ".*,
        "██████████████      ".*,
        "███████████████     ".*,
        "████████████████    ".*,
        "█████████████████   ".*,
        "██████████████████  ".*,
        "███████████████████ ".*,
        "████████████████████".*,
    };
    return &bars[@min(filled, 20)];
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "core metrics init and increment" {
    var metrics = CoreMetrics.init();
    
    metrics.incTxReceived();
    metrics.incTxReceived();
    metrics.incPacketsReceived(100);
    
    try std.testing.expectEqual(@as(u64, 2), metrics.transactions_received.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 100), metrics.packets_received.load(.monotonic));
}

test "tps calculator" {
    const allocator = std.testing.allocator;
    
    const calc = try TpsCalculator.init(allocator);
    defer calc.deinit();
    
    // Record some slots
    calc.recordSlotCompleted(1, 1000, 100, 50, false);
    calc.recordSlotCompleted(2, 2000, 200, 100, false);
    
    try std.testing.expectEqual(@as(usize, 2), calc.slot_history_count);
}
