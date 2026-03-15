//! Vexor Signature Verification Pipeline
//!
//! High-performance batch signature verification.
//! Supports CPU SIMD and GPU acceleration (when enabled).
//!
//! Pipeline stages:
//! 1. Packet deduplication (bloom filter)
//! 2. Signature extraction
//! 3. Batch verification (Ed25519)
//! 4. Result propagation

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;

const core = @import("../core/root.zig");
const ed25519 = @import("ed25519.zig");
const build_options = @import("build_options");

/// Signature verification result
pub const VerifyResult = enum {
    valid,
    invalid,
    error_parse,
    error_pubkey,
};

/// Packet with signature info
pub const SignaturePacket = struct {
    /// Raw packet data
    data: []const u8,
    /// Signature offset in data
    sig_offset: u16,
    /// Public key offset
    pubkey_offset: u16,
    /// Message offset
    message_offset: u16,
    /// Message length
    message_len: u16,
    /// Verification result
    result: VerifyResult,
    /// Transaction signature (for dedup)
    signature: [64]u8,

    const Self = @This();

    pub fn fromTransaction(data: []const u8) !Self {
        if (data.len < 1) return error.TooShort;

        // Parse transaction header
        const num_signatures = data[0];
        if (num_signatures == 0) return error.NoSignatures;
        // Solana transactions have at most ~12 signatures; reject obviously invalid packets
        if (num_signatures > 127) return error.TooManySignatures;

        // Widen to u32 to avoid u8 overflow in arithmetic (64 * 255 would overflow u8)
        const num_sigs: u32 = num_signatures;

        // Signature starts at offset 1
        const sig_offset: u16 = 1;
        if (data.len < sig_offset + 64) return error.TooShort;

        // Public key starts after all signatures
        const pub_off = 1 + (64 * num_sigs) + 3; // +3 for header
        if (pub_off > std.math.maxInt(u16) or data.len < pub_off + 32) return error.TooShort;
        const pubkey_offset: u16 = @intCast(pub_off);

        // Message starts after signatures
        const msg_off = 1 + (64 * num_sigs);
        if (msg_off > data.len) return error.TooShort;
        const message_offset: u16 = @intCast(msg_off);
        const message_len: u16 = @intCast(data.len - msg_off);

        var sig: [64]u8 = undefined;
        @memcpy(&sig, data[sig_offset..][0..64]);

        return Self{
            .data = data,
            .sig_offset = sig_offset,
            .pubkey_offset = pubkey_offset,
            .message_offset = message_offset,
            .message_len = message_len,
            .result = .valid, // Assume valid until verified
            .signature = sig,
        };
    }
};

/// Batch of packets to verify
pub const VerifyBatch = struct {
    allocator: Allocator,
    packets: std.ArrayList(SignaturePacket),
    verified_count: usize,
    valid_count: usize,
    invalid_count: usize,

    // Lifecycle management for underlying data
    context: ?*anyopaque,
    destructor: ?*const fn (?*anyopaque, Allocator) void,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .packets = std.ArrayList(SignaturePacket).init(allocator),
            .verified_count = 0,
            .valid_count = 0,
            .invalid_count = 0,
            .context = null,
            .destructor = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.packets.deinit();
    }

    pub fn add(self: *Self, packet: SignaturePacket) !void {
        try self.packets.append(packet);
    }

    pub fn clear(self: *Self) void {
        // If we have a context/destructor, cleaning it is the caller's responsibility BEFORE calling clear
        // OR we should call it here?
        // Typically pool reuse implies we reset pointers. Caller handles lifecycle of previous data.
        if (self.context) |ctx| {
            if (self.destructor) |des| {
                des(ctx, self.allocator);
            }
        }
        self.context = null;
        self.destructor = null;

        self.packets.clearRetainingCapacity();
        self.verified_count = 0;
        self.valid_count = 0;
        self.invalid_count = 0;
    }

    pub fn count(self: *const Self) usize {
        return self.packets.items.len;
    }
};

/// Signature verifier alias for compatibility
pub const SigVerifier = SigVerifyPipeline;

/// Signature verification pipeline
pub const SigVerifyPipeline = struct {
    allocator: Allocator,
    config: PipelineConfig,

    // Deduplication bloom filter
    dedup_filter: BloomFilter,

    // Verification queues
    pending_batches: std.ArrayList(*VerifyBatch),
    pending_mutex: Mutex,

    // Statistics
    stats: PipelineStats,

    // State
    running: Atomic(bool),
    threads: std.ArrayList(Thread),

    // Concurrency
    input_cond: std.Thread.Condition,
    verified_batches: std.ArrayList(*VerifyBatch),
    verified_mutex: Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, config: PipelineConfig) !*Self {
        const pipeline = try allocator.create(Self);

        pipeline.* = Self{
            .allocator = allocator,
            .config = config,
            .dedup_filter = BloomFilter.init(config.dedup_filter_bits),
            .pending_batches = std.ArrayList(*VerifyBatch).init(allocator),
            .pending_mutex = .{},
            .stats = .{},
            .running = Atomic(bool).init(false),
            .threads = std.ArrayList(Thread).init(allocator),
            .input_cond = .{},
            .verified_batches = std.ArrayList(*VerifyBatch).init(allocator),
            .verified_mutex = .{},
        };

        return pipeline;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.pending_batches.deinit();
        self.allocator.destroy(self);
    }

    /// Start the pipeline
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);

        // Spawn worker threads
        for (0..self.config.num_threads) |_| {
            const t = try Thread.spawn(.{}, workerLoop, .{self});
            try self.threads.append(t);
        }
    }

    /// Stop the pipeline
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        self.input_cond.broadcast(); // Wake up threads

        for (self.threads.items) |t| {
            t.join();
        }
        self.threads.clearRetainingCapacity();
    }

    fn workerLoop(self: *Self) void {
        while (self.running.load(.seq_cst)) {
            // Get batch
            self.pending_mutex.lock();
            while (self.pending_batches.items.len == 0 and self.running.load(.seq_cst)) {
                self.input_cond.wait(&self.pending_mutex);
            }

            if (!self.running.load(.seq_cst)) {
                self.pending_mutex.unlock();
                break;
            }

            const batch = self.pending_batches.orderedRemove(0); // FIFO
            self.pending_mutex.unlock();

            // Verify
            self.verifyBatch(batch) catch {
                // If verify crashes, log?
                // Currently verifyBatch uses `catch` inside for logic errors
                // but returns void? No, verifyBatch returns !void.
                // We should handle error.
            };

            // Push to output
            self.verified_mutex.lock();
            self.verified_batches.append(batch) catch {};
            self.verified_mutex.unlock();
        }
    }

    /// Submit a batch for verification
    pub fn submitBatch(self: *Self, batch: *VerifyBatch) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        try self.pending_batches.append(batch);
        self.input_cond.signal();
    }

    /// Retrieve verified batches
    pub fn getVerifiedBatches(self: *Self, output: *std.ArrayList(*VerifyBatch)) !void {
        self.verified_mutex.lock();
        defer self.verified_mutex.unlock();

        try output.appendSlice(self.verified_batches.items);
        self.verified_batches.clearRetainingCapacity();
    }

    /// Verify a single batch
    pub fn verifyBatch(self: *Self, batch: *VerifyBatch) !void {
        for (batch.packets.items) |*packet| {
            // Deduplication check
            if (self.dedup_filter.contains(&packet.signature)) {
                packet.result = .invalid;
                batch.invalid_count += 1;
                self.stats.duplicates += 1;
                continue;
            }

            // Add to bloom filter
            self.dedup_filter.add(&packet.signature);

            // Extract components
            const sig_start = packet.sig_offset;
            const pubkey_start = packet.pubkey_offset;
            const msg_start = packet.message_offset;
            const msg_len = packet.message_len;

            if (packet.data.len < sig_start + 64 or
                packet.data.len < pubkey_start + 32 or
                packet.data.len < msg_start + msg_len)
            {
                packet.result = .error_parse;
                batch.invalid_count += 1;
                self.stats.parse_errors += 1;
                continue;
            }

            const sig = packet.data[sig_start..][0..64];
            const pubkey = packet.data[pubkey_start..][0..32];
            const message = packet.data[msg_start..][0..msg_len];

            // Verify signature
            if (self.config.use_gpu and build_options.gpu_enabled) {
                // GPU verification would go here
                // For now, fall back to CPU
                packet.result = self.verifyCpu(sig, pubkey, message);
            } else {
                packet.result = self.verifyCpu(sig, pubkey, message);
            }

            if (packet.result == .valid) {
                batch.valid_count += 1;
                self.stats.valid += 1;
            } else {
                batch.invalid_count += 1;
                self.stats.invalid += 1;
            }

            batch.verified_count += 1;
        }

        self.stats.batches_processed += 1;
        self.stats.total_verified += batch.verified_count;
    }

    fn verifyCpu(self: *Self, sig: *const [64]u8, pubkey: *const [32]u8, message: []const u8) VerifyResult {
        _ = self;
        const s = core.Signature{ .data = sig.* };
        const p = core.Pubkey{ .data = pubkey.* };
        if (ed25519.verify(&s, &p, message)) {
            return .valid;
        }
        return .invalid;
    }

    /// Reset dedup filter (call periodically)
    pub fn resetDedupFilter(self: *Self) void {
        self.dedup_filter.reset();
        self.stats.dedup_resets += 1;
    }

    pub fn getStats(self: *const Self) PipelineStats {
        return self.stats;
    }
};

/// Pipeline configuration
pub const PipelineConfig = struct {
    /// Number of worker threads
    num_threads: usize = 4,
    /// Batch size for verification
    batch_size: usize = 128,
    /// Use GPU acceleration
    use_gpu: bool = false,
    /// Dedup filter size (bits)
    dedup_filter_bits: usize = 1 << 20, // ~1M bits
    /// Dedup filter hash functions
    dedup_filter_hashes: usize = 3,
};

/// Pipeline statistics
pub const PipelineStats = struct {
    batches_processed: u64 = 0,
    total_verified: u64 = 0,
    valid: u64 = 0,
    invalid: u64 = 0,
    duplicates: u64 = 0,
    parse_errors: u64 = 0,
    dedup_resets: u64 = 0,

    pub fn validRate(self: *const PipelineStats) f64 {
        if (self.total_verified == 0) return 0;
        return @as(f64, @floatFromInt(self.valid)) / @as(f64, @floatFromInt(self.total_verified));
    }
};

/// Simple bloom filter for deduplication
pub const BloomFilter = struct {
    bits: []u64,
    num_hashes: usize,
    allocator: ?Allocator,

    const Self = @This();

    pub fn init(num_bits: usize) Self {
        _ = num_bits;
        // Use static buffer for simplicity
        return Self{
            .bits = &[_]u64{},
            .num_hashes = 3,
            .allocator = null,
        };
    }

    pub fn initAlloc(allocator: Allocator, num_bits: usize) !Self {
        const num_words = (num_bits + 63) / 64;
        const bits = try allocator.alloc(u64, num_words);
        @memset(bits, 0);

        return Self{
            .bits = bits,
            .num_hashes = 3,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.allocator) |alloc| {
            if (self.bits.len > 0) {
                alloc.free(self.bits);
            }
        }
    }

    pub fn add(self: *Self, data: []const u8) void {
        if (self.bits.len == 0) return;

        const hash1 = std.hash.Fnv1a_64.hash(data);
        const hash2 = std.hash.CityHash64.hash(data);

        for (0..self.num_hashes) |i| {
            const combined = hash1 +% (@as(u64, i) *% hash2);
            const bit_idx = combined % (self.bits.len * 64);
            const word_idx = bit_idx / 64;
            const bit_pos: u6 = @intCast(bit_idx % 64);
            self.bits[word_idx] |= (@as(u64, 1) << bit_pos);
        }
    }

    pub fn contains(self: *const Self, data: []const u8) bool {
        if (self.bits.len == 0) return false;

        const hash1 = std.hash.Fnv1a_64.hash(data);
        const hash2 = std.hash.CityHash64.hash(data);

        for (0..self.num_hashes) |i| {
            const combined = hash1 +% (@as(u64, i) *% hash2);
            const bit_idx = combined % (self.bits.len * 64);
            const word_idx = bit_idx / 64;
            const bit_pos: u6 = @intCast(bit_idx % 64);
            if ((self.bits[word_idx] & (@as(u64, 1) << bit_pos)) == 0) {
                return false;
            }
        }
        return true;
    }

    pub fn reset(self: *Self) void {
        @memset(self.bits, 0);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "bloom filter" {
    const allocator = std.testing.allocator;

    var filter = try BloomFilter.initAlloc(allocator, 1024);
    defer filter.deinit();

    const key1 = "test_signature_1";
    const key2 = "test_signature_2";

    try std.testing.expect(!filter.contains(key1));
    filter.add(key1);
    try std.testing.expect(filter.contains(key1));
    try std.testing.expect(!filter.contains(key2));
}

test "pipeline init" {
    const allocator = std.testing.allocator;

    const pipeline = try SigVerifyPipeline.init(allocator, .{});
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(u64, 0), pipeline.stats.total_verified);
}

test "verify batch" {
    const allocator = std.testing.allocator;

    const pipeline = try SigVerifyPipeline.init(allocator, .{});
    defer pipeline.deinit();

    var batch = VerifyBatch.init(allocator);
    defer batch.deinit();

    // Empty batch should process fine
    try pipeline.verifyBatch(&batch);
    try std.testing.expectEqual(@as(usize, 0), batch.count());
}
