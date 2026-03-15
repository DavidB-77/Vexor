//! Merkle Root Live Diagnostics
//!
//! Real-time tracing and statistics for Merkle shred verification.
//! Instruments every step of the verification pipeline and captures
//! full failure context for fast root-cause analysis.
//!
//! Usage:
//!   var diag = MerkleDiagnostics.init();
//!   // In processShred:
//!   if (!diag.traceAndVerify(&shred, &leader_pubkey)) { ... }
//!   // Periodic stats dump:
//!   diag.logStats();

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const bmtree = @import("bmtree.zig");
const shred_mod = @import("shred.zig");

const Shred = shred_mod.Shred;
const ShredVariant = shred_mod.ShredVariant;

/// Maximum number of failure captures to retain
const MAX_FAILURE_CAPTURES = 10;

/// Stats dump interval (every N shreds)
const STATS_DUMP_INTERVAL: u64 = 10_000;

/// Failure reason categories
pub const FailureReason = enum {
    not_merkle, // Legacy shred (skip Merkle path)
    no_leader, // No leader known for slot
    payload_too_short, // Payload shorter than minimum
    proof_size_zero, // Merkle shred but proof_size=0
    proof_bounds_invalid, // Proof region overflows payload
    root_computation_failed, // merkleRoot() returned null
    sig_mismatch, // Ed25519 verify failed against computed root
    legacy_sig_mismatch, // Legacy shred Ed25519 verify failed
};

/// Captured failure context for post-mortem analysis
pub const FailureCapture = struct {
    slot: u64,
    index: u32,
    variant_byte: u8,
    is_data: bool,
    is_merkle: bool,
    proof_size: u8,
    chained: bool,
    resigned: bool,
    payload_len: usize,
    reason: FailureReason,
    /// First 128 bytes of shred payload (hex-encodable)
    header_bytes: [128]u8,
    header_len: usize,
    /// Computed merkle root (if available)
    computed_root: ?[bmtree.MERKLE_NODE_SIZE]u8,
    /// Signature from shred header
    sig_first_8: [8]u8,
    timestamp_ns: i128,
};

/// Thread-safe Merkle verification diagnostics
pub const MerkleDiagnostics = struct {
    // ═══ Counters (atomic) ═══
    total_shreds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merkle_verified: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merkle_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    legacy_verified: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    legacy_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    skipped_no_leader: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // ═══ Failure breakdown (atomic) ═══
    fail_payload_short: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fail_proof_size_zero: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fail_proof_bounds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fail_root_null: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fail_sig_mismatch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fail_legacy_sig: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // ═══ Failure captures ═══
    captures: [MAX_FAILURE_CAPTURES]FailureCapture = undefined,
    capture_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // ═══ Last stats dump ═══
    last_dump_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    /// Main entry point: trace and verify a shred's Merkle signature.
    /// Returns true if shred is valid (or if no leader is known — permissive mode).
    /// Captures full diagnostic context on failure.
    pub fn traceAndVerify(self: *Self, shred: *const Shred, leader_pubkey: *const core.Pubkey) bool {
        const count = self.total_shreds.fetchAdd(1, .monotonic) + 1;

        // Auto-dump stats at interval
        if (count % STATS_DUMP_INTERVAL == 0) {
            self.logStats();
        }

        const v = shred.common.variant;

        // ═══ Legacy path ═══
        if (!v.is_merkle) {
            return self.traceLegacy(shred, leader_pubkey);
        }

        // ═══ Merkle path — trace each step ═══
        return self.traceMerkle(shred, leader_pubkey, v);
    }

    /// Verify a shred when no leader is known (permissive — just count it)
    pub fn traceNoLeader(self: *Self, shred: *const Shred) void {
        _ = shred;
        _ = self.total_shreds.fetchAdd(1, .monotonic);
        _ = self.skipped_no_leader.fetchAdd(1, .monotonic);
    }

    fn traceLegacy(self: *Self, shred: *const Shred, leader_pubkey: *const core.Pubkey) bool {
        if (shred.payload.len <= 64) {
            _ = self.legacy_failed.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .legacy_sig_mismatch, null);
            return false;
        }

        const valid = crypto.verify(&shred.common.signature, leader_pubkey, shred.payload[64..]);
        if (valid) {
            _ = self.legacy_verified.fetchAdd(1, .monotonic);
        } else {
            _ = self.legacy_failed.fetchAdd(1, .monotonic);
            _ = self.fail_legacy_sig.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .legacy_sig_mismatch, null);
            self.logFailure(shred, .legacy_sig_mismatch, null);
        }
        return valid;
    }

    fn traceMerkle(self: *Self, shred: *const Shred, leader_pubkey: *const core.Pubkey, v: ShredVariant) bool {
        const payload = shred.payload;

        // Step 1: Check proof_size
        if (v.proof_size == 0) {
            _ = self.merkle_failed.fetchAdd(1, .monotonic);
            _ = self.fail_proof_size_zero.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .proof_size_zero, null);
            self.logFailure(shred, .proof_size_zero, null);
            return false;
        }

        // Step 2: Compute proof region bounds
        const proof_bytes: usize = @as(usize, v.proof_size) * bmtree.MERKLE_NODE_SIZE;
        const suffix_size: usize = (if (v.chained) @as(usize, 32) else @as(usize, 0)) +
            (if (v.resigned) @as(usize, 64) else @as(usize, 0));

        if (payload.len < suffix_size + proof_bytes) {
            _ = self.merkle_failed.fetchAdd(1, .monotonic);
            _ = self.fail_payload_short.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .payload_too_short, null);
            self.logFailure(shred, .payload_too_short, null);
            return false;
        }

        const proof_end = payload.len - suffix_size;
        const proof_start = proof_end - proof_bytes;
        const header_size: usize = if (v.is_data) shred_mod.SHRED_HEADER_SIZE else 89;

        if (proof_start < header_size) {
            _ = self.merkle_failed.fetchAdd(1, .monotonic);
            _ = self.fail_proof_bounds.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .proof_bounds_invalid, null);
            self.logFailure(shred, .proof_bounds_invalid, null);
            return false;
        }

        // Step 3: Compute leaf hash
        const erasure_shard = payload[64..proof_start];
        const leaf_hash = bmtree.MerkleTree.hashMerkleLeaf(erasure_shard);

        // Step 4: Compute shred index within FEC set
        const fec_set_idx = shred.common.fec_set_index;
        const shred_idx_in_fec: usize = if (shred.common.index >= fec_set_idx)
            @as(usize, shred.common.index - fec_set_idx)
        else
            0;

        // Step 5: Walk proof to reconstruct root
        const proof_nodes = payload[proof_start..proof_end];
        const root = bmtree.MerkleTree.reconstructRoot(leaf_hash, proof_nodes, shred_idx_in_fec);

        // Step 6: Verify Ed25519 signature against computed root
        const valid = crypto.verify(&shred.common.signature, leader_pubkey, &root);
        if (valid) {
            _ = self.merkle_verified.fetchAdd(1, .monotonic);
        } else {
            _ = self.merkle_failed.fetchAdd(1, .monotonic);
            _ = self.fail_sig_mismatch.fetchAdd(1, .monotonic);
            self.captureFailure(shred, .sig_mismatch, root);
            self.logFailure(shred, .sig_mismatch, root);
        }
        return valid;
    }

    /// Capture failure context (first N only)
    fn captureFailure(self: *Self, shred: *const Shred, reason: FailureReason, computed_root: ?[bmtree.MERKLE_NODE_SIZE]u8) void {
        const idx = self.capture_count.fetchAdd(1, .monotonic);
        if (idx >= MAX_FAILURE_CAPTURES) {
            // Already have enough captures, just decrement back
            _ = self.capture_count.fetchSub(1, .monotonic);
            return;
        }

        var capture: FailureCapture = undefined;
        capture.slot = shred.common.slot;
        capture.index = shred.common.index;
        capture.variant_byte = shred.common.variant_byte;
        capture.is_data = shred.common.variant.is_data;
        capture.is_merkle = shred.common.variant.is_merkle;
        capture.proof_size = shred.common.variant.proof_size;
        capture.chained = shred.common.variant.chained;
        capture.resigned = shred.common.variant.resigned;
        capture.payload_len = shred.payload.len;
        capture.reason = reason;
        capture.computed_root = computed_root;
        capture.timestamp_ns = std.time.nanoTimestamp();

        // Copy first 128 bytes of payload
        const copy_len = @min(shred.payload.len, 128);
        @memcpy(capture.header_bytes[0..copy_len], shred.payload[0..copy_len]);
        if (copy_len < 128) @memset(capture.header_bytes[copy_len..], 0);
        capture.header_len = copy_len;

        // Copy first 8 bytes of signature
        @memcpy(&capture.sig_first_8, shred.common.signature.data[0..8]);

        self.captures[idx] = capture;
    }

    /// Log a single failure with context
    fn logFailure(self: *Self, shred: *const Shred, reason: FailureReason, computed_root: ?[bmtree.MERKLE_NODE_SIZE]u8) void {
        _ = self;
        const v = shred.common.variant;

        if (computed_root) |root| {
            std.log.err(
                "[Merkle-Diag] FAIL {s}: slot={d} idx={d} variant=0x{x:0>2} " ++
                    "proof_size={d} chained={} resigned={} payload_len={d} " ++
                    "fec_set={d} root={s}",
                .{
                    @tagName(reason),
                    shred.common.slot,
                    shred.common.index,
                    shred.common.variant_byte,
                    v.proof_size,
                    v.chained,
                    v.resigned,
                    shred.payload.len,
                    shred.common.fec_set_index,
                    std.fmt.fmtSliceHexLower(&root),
                },
            );
        } else {
            std.log.err(
                "[Merkle-Diag] FAIL {s}: slot={d} idx={d} variant=0x{x:0>2} " ++
                    "proof_size={d} chained={} resigned={} payload_len={d} fec_set={d}",
                .{
                    @tagName(reason),
                    shred.common.slot,
                    shred.common.index,
                    shred.common.variant_byte,
                    v.proof_size,
                    v.chained,
                    v.resigned,
                    shred.payload.len,
                    shred.common.fec_set_index,
                },
            );
        }
    }

    /// Log aggregate stats summary
    pub fn logStats(self: *Self) void {
        const total = self.total_shreds.load(.monotonic);
        const m_ok = self.merkle_verified.load(.monotonic);
        const m_fail = self.merkle_failed.load(.monotonic);
        const l_ok = self.legacy_verified.load(.monotonic);
        const l_fail = self.legacy_failed.load(.monotonic);
        const skipped = self.skipped_no_leader.load(.monotonic);

        const merkle_total = m_ok + m_fail;
        const pass_rate: u64 = if (merkle_total > 0) (m_ok * 100) / merkle_total else 0;

        std.log.info(
            \\[Merkle-Diag] ═══ Stats ({d} shreds) ═══
            \\[Merkle-Diag]   Merkle: {d} ok / {d} fail ({d}% pass)
            \\[Merkle-Diag]   Legacy: {d} ok / {d} fail
            \\[Merkle-Diag]   Skipped (no leader): {d}
            \\[Merkle-Diag]   Failures: sig={d} root_null={d} bounds={d} proof0={d} short={d} legacy_sig={d}
            \\[Merkle-Diag]   Captures: {d}/{d}
            \\[Merkle-Diag] ════════════════════════════
        , .{
            total,
            m_ok,
            m_fail,
            pass_rate,
            l_ok,
            l_fail,
            skipped,
            self.fail_sig_mismatch.load(.monotonic),
            self.fail_root_null.load(.monotonic),
            self.fail_proof_bounds.load(.monotonic),
            self.fail_proof_size_zero.load(.monotonic),
            self.fail_payload_short.load(.monotonic),
            self.fail_legacy_sig.load(.monotonic),
            @min(self.capture_count.load(.monotonic), MAX_FAILURE_CAPTURES),
            @as(u32, MAX_FAILURE_CAPTURES),
        });

        self.last_dump_count.store(total, .monotonic);
    }

    /// Dump all captured failures (for manual post-mortem)
    pub fn dumpCaptures(self: *Self) void {
        const count = @min(self.capture_count.load(.monotonic), MAX_FAILURE_CAPTURES);
        if (count == 0) {
            std.log.info("[Merkle-Diag] No failures captured.", .{});
            return;
        }

        std.log.info("[Merkle-Diag] ═══ {d} Captured Failures ═══", .{count});
        for (0..count) |i| {
            const c = self.captures[i];
            std.log.info(
                "[Merkle-Diag] #{d}: slot={d} idx={d} reason={s} variant=0x{x:0>2} " ++
                    "merkle={} proof_size={d} chained={} resigned={} payload_len={d} " ++
                    "sig[0..8]={s}",
                .{
                    i,
                    c.slot,
                    c.index,
                    @tagName(c.reason),
                    c.variant_byte,
                    c.is_merkle,
                    c.proof_size,
                    c.chained,
                    c.resigned,
                    c.payload_len,
                    std.fmt.fmtSliceHexLower(&c.sig_first_8),
                },
            );
            if (c.computed_root) |root| {
                std.log.info("[Merkle-Diag]   computed_root={s}", .{
                    std.fmt.fmtSliceHexLower(&root),
                });
            }
            // Hex-dump first 64 bytes of header
            const dump_len = @min(c.header_len, 64);
            std.log.info("[Merkle-Diag]   header[0..{d}]={s}", .{
                dump_len,
                std.fmt.fmtSliceHexLower(c.header_bytes[0..dump_len]),
            });
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "diagnostics: init and basic stats" {
    var diag = MerkleDiagnostics.init();
    try std.testing.expectEqual(@as(u64, 0), diag.total_shreds.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), diag.merkle_verified.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), diag.merkle_failed.load(.monotonic));

    // Simulate the no-leader path
    var payload: [200]u8 = undefined;
    @memset(&payload, 0);
    payload[64] = 0x80; // Merkle data variant
    const shred = Shred.fromPayload(&payload) catch return;
    diag.traceNoLeader(&shred);
    try std.testing.expectEqual(@as(u64, 1), diag.total_shreds.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), diag.skipped_no_leader.load(.monotonic));
}

test "diagnostics: failure capture limit" {
    var diag = MerkleDiagnostics.init();

    // Try to capture more than MAX_FAILURE_CAPTURES
    var payload: [200]u8 = undefined;
    @memset(&payload, 0);
    payload[64] = 0x80;
    const shred = Shred.fromPayload(&payload) catch return;

    var i: u32 = 0;
    while (i < MAX_FAILURE_CAPTURES + 5) : (i += 1) {
        diag.captureFailure(&shred, .sig_mismatch, null);
    }

    // Should be capped at MAX_FAILURE_CAPTURES
    try std.testing.expect(diag.capture_count.load(.monotonic) <= MAX_FAILURE_CAPTURES);
}

test "diagnostics: stats dump does not crash" {
    var diag = MerkleDiagnostics.init();
    diag.logStats();
    diag.dumpCaptures();
}
