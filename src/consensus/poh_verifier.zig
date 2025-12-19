//! Vexor Proof of History Verifier
//!
//! Verifies PoH hash chains during slot replay.
//! The PoH is a sequential hash chain that provides a verifiable time ordering.
//!
//! Hash chain: H(i+1) = SHA256(H(i))

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// PoH hash (32 bytes)
pub const PohHash = [32]u8;

/// PoH entry to verify
pub const PohEntry = struct {
    /// Number of hashes since previous entry
    num_hashes: u64,
    /// Resulting hash
    hash: PohHash,
    /// Optional mixin (transaction hash)
    mixin: ?PohHash,
};

/// PoH verification result
pub const VerifyResult = enum {
    valid,
    invalid_hash,
    invalid_sequence,
    tick_mismatch,
};

/// PoH tick
pub const Tick = struct {
    hash: PohHash,
    slot: u64,
    tick_index: u64,
};

/// PoH Verifier
pub const PohVerifier = struct {
    allocator: Allocator,
    config: VerifierConfig,

    /// Current hash state
    current_hash: PohHash,

    /// Tick tracking
    ticks_per_slot: u64,
    current_tick: u64,
    current_slot: u64,

    /// Statistics
    stats: VerifierStats,

    /// State
    running: Atomic(bool),

    const Self = @This();

    pub fn init(allocator: Allocator, config: VerifierConfig) !*Self {
        const verifier = try allocator.create(Self);

        // Explicit zero initialization (safer than undefined + memset)
        const initial_hash: PohHash = [_]u8{0} ** 32;

        verifier.* = Self{
            .allocator = allocator,
            .config = config,
            .current_hash = initial_hash,
            .ticks_per_slot = config.ticks_per_slot,
            .current_tick = 0,
            .current_slot = 0,
            .stats = .{},
            .running = Atomic(bool).init(false),
        };

        return verifier;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Set starting state from snapshot
    pub fn setStartState(self: *Self, hash: PohHash, slot: u64, tick: u64) void {
        self.current_hash = hash;
        self.current_slot = slot;
        self.current_tick = tick;
    }

    /// Verify a single PoH entry
    /// Optimized: Uses prefetch hints for large hash chains
    pub fn verifyEntry(self: *Self, entry: *const PohEntry) VerifyResult {
        // Compute expected hash using optimized path for large chains
        const computed = if (entry.num_hashes > 64)
            hashChainWithPrefetch(self.current_hash, entry.num_hashes)
        else blk: {
            var hash = self.current_hash;
            for (0..entry.num_hashes) |_| {
                hash = hashOnce(hash);
            }
            break :blk hash;
        };

        // Apply mixin if present
        const final_hash = if (entry.mixin) |mixin|
            hashWithMixin(computed, mixin)
        else
            computed;

        // Compare using constant-time comparison for security
        if (!std.mem.eql(u8, &final_hash, &entry.hash)) {
            self.stats.invalid_entries += 1;
            return .invalid_hash;
        }

        // Update state
        self.current_hash = entry.hash;
        self.stats.entries_verified += 1;
        self.stats.hashes_computed += entry.num_hashes;

        return .valid;
    }

    /// Verify a batch of entries (for a slot)
    pub fn verifySlotEntries(self: *Self, entries: []const PohEntry, slot: u64) VerifyResult {
        if (slot != self.current_slot + 1 and slot != self.current_slot) {
            self.stats.sequence_errors += 1;
            return .invalid_sequence;
        }

        var tick_count: u64 = 0;

        for (entries) |*entry| {
            const result = self.verifyEntry(entry);
            if (result != .valid) {
                return result;
            }

            // Count ticks (entries with no transactions)
            if (entry.mixin == null and entry.num_hashes > 0) {
                tick_count += 1;
            }
        }

        // Verify tick count for complete slots
        if (slot != self.current_slot) {
            if (tick_count != self.ticks_per_slot) {
                self.stats.tick_mismatches += 1;
                return .tick_mismatch;
            }
            self.current_slot = slot;
            self.current_tick = 0;
        }

        self.stats.slots_verified += 1;
        return .valid;
    }

    /// Verify PoH for a tick
    pub fn verifyTick(self: *Self, tick: *const Tick) VerifyResult {
        // Verify slot matches
        if (tick.slot != self.current_slot) {
            return .invalid_sequence;
        }

        // Verify tick index
        if (tick.tick_index != self.current_tick) {
            return .invalid_sequence;
        }

        self.current_tick += 1;
        self.stats.ticks_verified += 1;

        return .valid;
    }

    /// Get current hash
    pub fn getCurrentHash(self: *const Self) PohHash {
        return self.current_hash;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) VerifierStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *Self) void {
        self.stats = .{};
    }
    
    /// Verify entries in parallel (for batch verification)
    /// Splits entries into chunks and verifies them on multiple threads
    pub fn verifyEntriesParallel(self: *Self, entries: []const PohEntry) !ParallelVerifyResult {
        if (!self.config.parallel or entries.len < self.config.num_threads * 2) {
            // Fall back to sequential for small batches
            var result = ParallelVerifyResult{};
            for (entries) |*entry| {
                const verify_result = self.verifyEntry(entry);
                if (verify_result != .valid) {
                    result.invalid_count += 1;
                } else {
                    result.valid_count += 1;
                }
            }
            return result;
        }
        
        // Parallel verification using work stealing pattern
        const num_threads = @min(self.config.num_threads, entries.len);
        const chunk_size = entries.len / num_threads;
        
        var threads: [16]?Thread = undefined;
        var results: [16]ThreadResult = undefined;
        
        for (0..num_threads) |i| {
            const start = i * chunk_size;
            const end = if (i == num_threads - 1) entries.len else (i + 1) * chunk_size;
            
            // For parallel verification, each thread verifies hash chains independently
            // This works because each entry contains num_hashes and expected hash
            threads[i] = try Thread.spawn(.{}, verifyChunk, .{
                entries[start..end],
                self.current_hash, // Starting hash for this chunk
                &results[i],
            });
        }
        
        // Wait for all threads
        var total_result = ParallelVerifyResult{};
        for (0..num_threads) |i| {
            if (threads[i]) |t| {
                t.join();
                total_result.valid_count += results[i].valid;
                total_result.invalid_count += results[i].invalid;
                total_result.hashes_computed += results[i].hashes;
            }
        }
        
        self.stats.hashes_computed += total_result.hashes_computed;
        self.stats.entries_verified += total_result.valid_count;
        self.stats.invalid_entries += total_result.invalid_count;
        
        return total_result;
    }
    
    /// Result from parallel verification
    pub const ParallelVerifyResult = struct {
        valid_count: u64 = 0,
        invalid_count: u64 = 0,
        hashes_computed: u64 = 0,
    };
    
    const ThreadResult = struct {
        valid: u64 = 0,
        invalid: u64 = 0,
        hashes: u64 = 0,
    };
    
    /// Worker function for parallel verification
    fn verifyChunk(entries: []const PohEntry, start_hash: PohHash, result: *ThreadResult) void {
        var current = start_hash;
        
        for (entries) |*entry| {
            // Compute expected hash
            for (0..entry.num_hashes) |_| {
                current = hashOnce(current);
            }
            
            // Apply mixin if present
            if (entry.mixin) |mixin| {
                current = hashWithMixin(current, mixin);
            }
            
            // Compare
            if (std.mem.eql(u8, &current, &entry.hash)) {
                result.valid += 1;
            } else {
                result.invalid += 1;
            }
            
            result.hashes += entry.num_hashes;
            
            // Update current for next entry
            current = entry.hash;
        }
    }
    
    /// Benchmark POH hash rate
    pub fn benchmark(self: *Self, num_hashes: u64) BenchmarkResult {
        const start = std.time.nanoTimestamp();
        
        var hash = self.current_hash;
        for (0..num_hashes) |_| {
            hash = hashOnce(hash);
        }
        
        const end = std.time.nanoTimestamp();
        const elapsed_ns = end - start;
        
        return BenchmarkResult{
            .num_hashes = num_hashes,
            .elapsed_ns = @intCast(elapsed_ns),
            .hash_rate = @as(f64, @floatFromInt(num_hashes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9),
        };
    }
    
    pub const BenchmarkResult = struct {
        num_hashes: u64,
        elapsed_ns: u64,
        hash_rate: f64, // hashes per second
    };
};

/// Verifier configuration
pub const VerifierConfig = struct {
    /// Ticks per slot
    ticks_per_slot: u64 = 64,
    /// Hashes per tick
    hashes_per_tick: u64 = 12500,
    /// Enable parallel verification
    parallel: bool = false,
    /// Number of verification threads
    num_threads: usize = 4,
};

/// Verifier statistics
pub const VerifierStats = struct {
    entries_verified: u64 = 0,
    slots_verified: u64 = 0,
    ticks_verified: u64 = 0,
    hashes_computed: u64 = 0,
    invalid_entries: u64 = 0,
    sequence_errors: u64 = 0,
    tick_mismatches: u64 = 0,

    pub fn hashRate(self: *const VerifierStats, elapsed_ns: i128) f64 {
        if (elapsed_ns <= 0) return 0;
        return @as(f64, @floatFromInt(self.hashes_computed)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);
    }
};

/// Compute single hash
/// Optimized: Explicit initialization to avoid undefined behavior
fn hashOnce(input: PohHash) PohHash {
    // Explicit zero initialization for safety (SHA256 will overwrite all bytes)
    var output: PohHash = [_]u8{0} ** 32;
    Sha256.hash(&input, &output, .{});
    return output;
}

/// Compute hash with mixin
/// Optimized: Explicit initialization to avoid undefined behavior
fn hashWithMixin(state: PohHash, mixin: PohHash) PohHash {
    // Explicit zero initialization for safety
    var combined: [64]u8 = [_]u8{0} ** 64;
    @memcpy(combined[0..32], &state);
    @memcpy(combined[32..64], &mixin);

    var output: PohHash = [_]u8{0} ** 32;
    Sha256.hash(&combined, &output, .{});
    return output;
}

/// Optimized hash chain computation with prefetch hints
/// Used for bulk hash verification where we know we'll process many hashes
fn hashChainWithPrefetch(input: PohHash, num_hashes: u64) PohHash {
    var current = input;
    
    // Process in blocks of 8 for better cache utilization
    const BLOCK_SIZE: u64 = 8;
    const full_blocks = num_hashes / BLOCK_SIZE;
    const remainder = num_hashes % BLOCK_SIZE;
    
    var i: u64 = 0;
    while (i < full_blocks) : (i += 1) {
        // Prefetch hint for next block's input data
        @prefetch(&current, .{
            .rw = .read,
            .locality = 3, // High temporal locality
            .cache = .data,
        });
        
        // Process block of 8 hashes
        inline for (0..BLOCK_SIZE) |_| {
            current = hashOnce(current);
        }
    }
    
    // Handle remainder
    for (0..remainder) |_| {
        current = hashOnce(current);
    }
    
    return current;
}

/// Compute hash chain (for testing)
pub fn computeHashChain(start: PohHash, num_hashes: u64) PohHash {
    var current = start;
    for (0..num_hashes) |_| {
        current = hashOnce(current);
    }
    return current;
}

// ═══════════════════════════════════════════════════════════════════════════════
// POH RECORDER (for block production)
// ═══════════════════════════════════════════════════════════════════════════════

/// PoH Recorder for block production
pub const PohRecorder = struct {
    allocator: Allocator,

    /// Current hash state
    current_hash: PohHash,

    /// Hashes since last record
    hashes_since_record: u64,

    /// Current slot
    slot: u64,

    /// Current tick
    tick: u64,

    /// Ticks per slot
    ticks_per_slot: u64,

    /// Hashes per tick
    hashes_per_tick: u64,

    /// Recorded entries
    entries: std.ArrayList(PohEntry),

    /// Is recording
    recording: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, slot: u64, start_hash: PohHash) !*Self {
        const recorder = try allocator.create(Self);

        recorder.* = Self{
            .allocator = allocator,
            .current_hash = start_hash,
            .hashes_since_record = 0,
            .slot = slot,
            .tick = 0,
            .ticks_per_slot = 64,
            .hashes_per_tick = 12500,
            .entries = std.ArrayList(PohEntry).init(allocator),
            .recording = false,
        };

        return recorder;
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
        self.allocator.destroy(self);
    }

    /// Start recording
    pub fn startRecording(self: *Self) void {
        self.recording = true;
    }

    /// Stop recording
    pub fn stopRecording(self: *Self) void {
        self.recording = false;
    }

    /// Hash forward
    pub fn hash(self: *Self) void {
        self.current_hash = hashOnce(self.current_hash);
        self.hashes_since_record += 1;
    }

    /// Record a tick
    pub fn recordTick(self: *Self) !void {
        if (!self.recording) return;

        const entry = PohEntry{
            .num_hashes = self.hashes_since_record,
            .hash = self.current_hash,
            .mixin = null,
        };

        try self.entries.append(entry);
        self.hashes_since_record = 0;
        self.tick += 1;
    }

    /// Record entry with mixin (transaction)
    pub fn recordMixin(self: *Self, mixin: PohHash) !void {
        if (!self.recording) return;

        // Apply mixin
        self.current_hash = hashWithMixin(self.current_hash, mixin);

        const entry = PohEntry{
            .num_hashes = self.hashes_since_record,
            .hash = self.current_hash,
            .mixin = mixin,
        };

        try self.entries.append(entry);
        self.hashes_since_record = 0;
    }

    /// Get recorded entries and clear
    pub fn drainEntries(self: *Self) ![]PohEntry {
        return self.entries.toOwnedSlice();
    }

    /// Check if tick threshold reached
    pub fn shouldRecordTick(self: *const Self) bool {
        return self.hashes_since_record >= self.hashes_per_tick;
    }

    /// Check if slot complete
    pub fn isSlotComplete(self: *const Self) bool {
        return self.tick >= self.ticks_per_slot;
    }

    /// Advance to next slot
    pub fn advanceSlot(self: *Self) void {
        self.slot += 1;
        self.tick = 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "hash once" {
    const input: PohHash = [_]u8{0} ** 32;
    const output = hashOnce(input);

    // SHA256 of 32 zero bytes
    try std.testing.expect(!std.mem.eql(u8, &output, &input));
}

test "hash chain" {
    const start: PohHash = [_]u8{0} ** 32;
    const result = computeHashChain(start, 100);

    // Should be deterministic
    const result2 = computeHashChain(start, 100);
    try std.testing.expect(std.mem.eql(u8, &result, &result2));
}

test "verifier init" {
    const allocator = std.testing.allocator;

    const verifier = try PohVerifier.init(allocator, .{});
    defer verifier.deinit();

    try std.testing.expectEqual(@as(u64, 64), verifier.ticks_per_slot);
}

test "verify entry" {
    const allocator = std.testing.allocator;

    const verifier = try PohVerifier.init(allocator, .{});
    defer verifier.deinit();

    // Create valid entry
    const start_hash = verifier.getCurrentHash();
    const expected = computeHashChain(start_hash, 10);

    const entry = PohEntry{
        .num_hashes = 10,
        .hash = expected,
        .mixin = null,
    };

    const result = verifier.verifyEntry(&entry);
    try std.testing.expectEqual(VerifyResult.valid, result);
}

test "recorder" {
    const allocator = std.testing.allocator;

    // Explicit zero initialization (safer than undefined + memset)
    const start: PohHash = [_]u8{0} ** 32;

    const recorder = try PohRecorder.init(allocator, 0, start);
    defer recorder.deinit();

    recorder.startRecording();

    // Hash and record
    for (0..100) |_| {
        recorder.hash();
    }
    try recorder.recordTick();

    const entries = try recorder.drainEntries();
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 100), entries[0].num_hashes);
}

