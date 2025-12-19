//! Vexor Proof of History (PoH)
//!
//! PoH is Solana's cryptographic clock that proves passage of time.
//! It's a sequential hash chain where each hash proves the previous one existed.
//!
//! tick_hash[n] = SHA256(tick_hash[n-1])
//!
//! This provides:
//! - Verifiable ordering of events
//! - Historical record of time passing
//! - Synchronization point for the network

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");

/// Hashes per tick (determines tick rate)
pub const DEFAULT_HASHES_PER_TICK: u64 = 12500;

/// Target ticks per second
pub const DEFAULT_TICKS_PER_SECOND: u64 = 160;

/// Ticks per slot
pub const DEFAULT_TICKS_PER_SLOT: u64 = 64;

/// PoH configuration
pub const PohConfig = struct {
    /// Hashes per tick
    hashes_per_tick: ?u64 = DEFAULT_HASHES_PER_TICK,

    /// Target tick duration (nanoseconds)
    target_tick_duration_ns: u64 = 1_000_000_000 / DEFAULT_TICKS_PER_SECOND,

    /// Ticks per slot
    ticks_per_slot: u64 = DEFAULT_TICKS_PER_SLOT,
};

/// PoH recorder - generates proof of history
pub const PohRecorder = struct {
    allocator: std.mem.Allocator,

    /// Current hash state
    hash: core.Hash,

    /// Hash count since last tick
    hash_count: u64,

    /// Total hashes since genesis
    total_hash_count: u64,

    /// Current tick height
    tick_height: u64,

    /// Current slot
    slot: core.Slot,

    /// Configuration
    config: PohConfig,

    /// Recorded entries
    entries: std.ArrayList(PohEntry),

    /// Running state
    running: std.atomic.Value(bool),

    /// Last tick timestamp
    last_tick_ns: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, start_hash: core.Hash, config: PohConfig) !*Self {
        const recorder = try allocator.create(Self);
        recorder.* = .{
            .allocator = allocator,
            .hash = start_hash,
            .hash_count = 0,
            .total_hash_count = 0,
            .tick_height = 0,
            .slot = 0,
            .config = config,
            .entries = std.ArrayList(PohEntry).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .last_tick_ns = @intCast(std.time.nanoTimestamp()),
        };
        return recorder;
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        self.allocator.destroy(self);
    }

    /// Start the PoH recorder
    pub fn start(self: *Self, slot: core.Slot) void {
        self.slot = slot;
        self.running.store(true, .seq_cst);
        self.last_tick_ns = @intCast(std.time.nanoTimestamp());
    }

    /// Stop the PoH recorder
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
    }

    /// Perform one hash (call rapidly in a loop)
    pub fn hash_once(self: *Self) void {
        self.hash = crypto.hash(&self.hash);
        self.hash_count += 1;
        self.total_hash_count += 1;
    }

    /// Check if tick threshold reached
    pub fn shouldTick(self: *const Self) bool {
        if (self.config.hashes_per_tick) |hpt| {
            return self.hash_count >= hpt;
        }
        // Time-based tick
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return (now - self.last_tick_ns) >= self.config.target_tick_duration_ns;
    }

    /// Record a tick
    pub fn tick(self: *Self) !PohEntry {
        const entry = PohEntry{
            .entry_type = .tick,
            .num_hashes = self.hash_count,
            .hash = self.hash,
            .mixin = null,
            .tick_height = self.tick_height,
            .slot = self.slot,
        };

        try self.entries.append(entry);

        self.hash_count = 0;
        self.tick_height += 1;
        self.last_tick_ns = @intCast(std.time.nanoTimestamp());

        // Check for slot boundary
        if (self.tick_height % self.config.ticks_per_slot == 0) {
            self.slot += 1;
        }

        return entry;
    }

    /// Record a mixin (transaction hash)
    pub fn record(self: *Self, mixin: core.Hash) !PohEntry {
        // Mix the hash into the chain
        var hasher = crypto.Sha256.init();
        hasher.update(&self.hash);
        hasher.update(&mixin);
        self.hash = hasher.final();

        self.hash_count += 1;
        self.total_hash_count += 1;

        const entry = PohEntry{
            .entry_type = .mixin,
            .num_hashes = 1,
            .hash = self.hash,
            .mixin = mixin,
            .tick_height = self.tick_height,
            .slot = self.slot,
        };

        try self.entries.append(entry);

        return entry;
    }

    /// Get current PoH state
    pub fn getState(self: *const Self) PohState {
        return .{
            .hash = self.hash,
            .hash_count = self.hash_count,
            .total_hash_count = self.total_hash_count,
            .tick_height = self.tick_height,
            .slot = self.slot,
        };
    }

    /// Drain recorded entries
    pub fn drainEntries(self: *Self) []PohEntry {
        const entries = self.entries.toOwnedSlice() catch &[_]PohEntry{};
        self.entries = std.ArrayList(PohEntry).init(self.allocator);
        return entries;
    }

    /// Hash at maximum rate until tick
    pub fn hashUntilTick(self: *Self) !PohEntry {
        while (!self.shouldTick()) {
            self.hash_once();
        }
        return try self.tick();
    }
};

/// PoH entry
pub const PohEntry = struct {
    entry_type: EntryType,
    num_hashes: u64,
    hash: core.Hash,
    mixin: ?core.Hash,
    tick_height: u64,
    slot: core.Slot,

    pub const EntryType = enum {
        tick,
        mixin,
    };
};

/// PoH state snapshot
pub const PohState = struct {
    hash: core.Hash,
    hash_count: u64,
    total_hash_count: u64,
    tick_height: u64,
    slot: core.Slot,
};

/// PoH verifier - verifies proof of history
pub const PohVerifier = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Verify a sequence of PoH entries
    pub fn verify(self: *Self, entries: []const PohEntry, start_hash: core.Hash) bool {
        _ = self;
        var hash = start_hash;

        for (entries) |entry| {
            switch (entry.entry_type) {
                .tick => {
                    // Apply hashes
                    for (0..entry.num_hashes) |_| {
                        hash = crypto.hash(&hash);
                    }
                },
                .mixin => {
                    // Apply mixin
                    if (entry.mixin) |mixin| {
                        var hasher = crypto.Sha256.init();
                        hasher.update(&hash);
                        hasher.update(&mixin);
                        hash = hasher.final();
                    }
                },
            }

            // Check result
            if (!std.mem.eql(u8, &hash, &entry.hash)) {
                return false;
            }
        }

        return true;
    }

    /// Verify PoH in parallel (for long chains)
    pub fn verifyParallel(self: *Self, entries: []const PohEntry, start_hash: core.Hash, num_threads: usize) bool {
        _ = num_threads;
        // TODO: Implement parallel verification
        return self.verify(entries, start_hash);
    }
};

/// PoH timing calculator
pub fn calculateSlotDuration(config: PohConfig) u64 {
    const hashes_per_slot = (config.hashes_per_tick orelse DEFAULT_HASHES_PER_TICK) * config.ticks_per_slot;
    // Rough estimate based on hash rate
    const hash_rate: u64 = 2_000_000_000; // 2 billion hashes/sec (typical)
    return (hashes_per_slot * 1_000_000_000) / hash_rate;
}

/// Calculate slot from bank height
pub fn slotFromTickHeight(tick_height: u64, ticks_per_slot: u64) core.Slot {
    return tick_height / ticks_per_slot;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "poh recorder basic" {
    var recorder = try PohRecorder.init(std.testing.allocator, core.Hash.ZERO, .{});
    defer recorder.deinit();

    // Do some hashing
    for (0..100) |_| {
        recorder.hash_once();
    }

    try std.testing.expectEqual(@as(u64, 100), recorder.hash_count);
}

test "poh tick" {
    var recorder = try PohRecorder.init(std.testing.allocator, core.Hash.ZERO, .{
        .hashes_per_tick = 10,
    });
    defer recorder.deinit();

    // Hash until tick
    for (0..10) |_| {
        recorder.hash_once();
    }

    try std.testing.expect(recorder.shouldTick());

    const entry = try recorder.tick();
    try std.testing.expectEqual(@as(u64, 10), entry.num_hashes);
}

test "poh verify" {
    var recorder = try PohRecorder.init(std.testing.allocator, core.Hash.ZERO, .{
        .hashes_per_tick = 10,
    });
    defer recorder.deinit();

    // Generate some entries
    _ = try recorder.hashUntilTick();
    _ = try recorder.hashUntilTick();

    const entries = recorder.drainEntries();
    defer std.testing.allocator.free(entries);

    // Verify
    var verifier = PohVerifier.init(std.testing.allocator);
    try std.testing.expect(verifier.verify(entries, core.Hash.ZERO));
}

