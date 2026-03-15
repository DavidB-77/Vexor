//! Vexor FEC Resolver
//!
//! Reed-Solomon Forward Error Correction for shred recovery.
//! Based on Firedancer: src/disco/shred/fd_fec_resolver.c
//!
//! FEC sets allow recovery of missing shreds using coding (parity) shreds.
//! Solana uses Reed-Solomon erasure coding in GF(2^8).

const std = @import("std");
const core = @import("../core/root.zig");
const gf_simd = @import("gf_simd.zig");

/// Maximum data shreds per FEC set (from Firedancer FD_REEDSOL_DATA_SHREDS_MAX)
pub const MAX_DATA_SHREDS: usize = 67;

/// Maximum parity/coding shreds per FEC set (from Firedancer FD_REEDSOL_PARITY_SHREDS_MAX)
pub const MAX_PARITY_SHREDS: usize = 67;

/// Total maximum shreds in an FEC set
pub const MAX_SHREDS_PER_FEC_SET: usize = MAX_DATA_SHREDS + MAX_PARITY_SHREDS;

/// Standard shred size
pub const SHRED_SIZE: usize = 1228;

/// Signature size in bytes (Ed25519)
pub const SIGNATURE_SIZE: usize = 64;

/// Data shred header size (common header 83 + data header 5)
pub const DATA_HEADER_SIZE: usize = 88;

/// Code shred header size (common header 83 + code header 6)
pub const CODE_HEADER_SIZE: usize = 89;

/// Merkle proof entry size (truncated hash)
pub const MERKLE_PROOF_ENTRY_SIZE: usize = 20;

/// Parse variant byte to extract shred type and proof_size
/// Per Solana spec:
/// - Legacy code: 0x5A (high=0x5, low=0xA)
/// - Legacy data: 0xA5 (high=0xA, low=0x5)
/// - Merkle code: high nibble 0x4, 0x6, or 0x7; low nibble = proof_size
/// - Merkle data: high nibble 0x8, 0x9, 0xA (if not 0xA5), 0xB; low nibble = proof_size
pub fn parseVariantByte(variant: u8) struct { is_data: bool, is_merkle: bool, proof_size: u8 } {
    const high_nibble = variant & 0xF0;
    const low_nibble = variant & 0x0F;

    // Check for Alpenglow V3: Variant 0x58 - special case
    // Proof size is 0, is_chained = true (based on 0x50 prefix)
    if (variant == 0x58) {
        return .{ .is_data = false, .is_merkle = true, .proof_size = 0 };
    }

    // Check for legacy variants first (exact match)
    if (variant == 0x5A) {
        return .{ .is_data = false, .is_merkle = false, .proof_size = 0 }; // Legacy code
    }
    if (variant == 0xA5) {
        return .{ .is_data = true, .is_merkle = false, .proof_size = 0 }; // Legacy data
    }

    // Merkle variants: high nibble determines type
    return switch (high_nibble) {
        // Merkle code variants: 0x4X, 0x6X, 0x7X
        0x40 => .{ .is_data = false, .is_merkle = true, .proof_size = low_nibble },
        0x60 => .{ .is_data = false, .is_merkle = true, .proof_size = low_nibble }, // chained
        0x70 => .{ .is_data = false, .is_merkle = true, .proof_size = low_nibble }, // chained+resigned
        // Merkle data variants: 0x8X, 0x9X, 0xAX, 0xBX
        0x80 => .{ .is_data = true, .is_merkle = true, .proof_size = low_nibble },
        0x90 => .{ .is_data = true, .is_merkle = true, .proof_size = low_nibble }, // chained
        0xA0 => .{ .is_data = true, .is_merkle = true, .proof_size = low_nibble }, // (but 0xA5 already handled)
        0xB0 => .{ .is_data = true, .is_merkle = true, .proof_size = low_nibble }, // chained+resigned
        else => .{ .is_data = false, .is_merkle = false, .proof_size = 0 },
    };
}

/// Calculate the erasure shard size for a shred
/// For Merkle shreds, this EXCLUDES the merkle proof at the end
fn calculateErasureShardSize(shred: []const u8, is_data: bool) usize {
    if (shred.len <= 64) return 0;

    const variant = shred[64];
    const parsed = parseVariantByte(variant);

    // Calculate merkle proof size (only for Merkle shreds)
    const merkle_proof_size: usize = if (parsed.is_merkle)
        @as(usize, parsed.proof_size) * MERKLE_PROOF_ENTRY_SIZE
    else
        0;

    // Erasure shard starts at different offsets for data vs code
    const start_offset: usize = if (is_data) SIGNATURE_SIZE else CODE_HEADER_SIZE;

    // Erasure shard ends before the merkle proof
    if (shred.len <= start_offset + merkle_proof_size) return 0;

    return shred.len - start_offset - merkle_proof_size;
}

/// GF(2^8) Galois Field operations for Reed-Solomon
/// Reference: Firedancer src/ballet/reedsol/fd_reedsol_gf.h
pub const GaloisField = struct {
    /// GF(2^8) multiplication using log/exp tables
    /// The field uses polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D)
    const PRIMITIVE_POLY: u16 = 0x11D;

    /// Logarithm table (256 entries)
    log_table: [256]u8,

    /// Exponent/antilog table (512 entries for wraparound)
    exp_table: [512]u8,

    pub fn init() GaloisField {
        var gf = GaloisField{
            .log_table = undefined,
            .exp_table = undefined,
        };

        // Build exp table: exp[i] = alpha^i where alpha is primitive element (2)
        var x: u16 = 1;
        for (0..255) |i| {
            gf.exp_table[i] = @truncate(x);
            gf.exp_table[i + 255] = @truncate(x); // Duplicate for easy wraparound

            // Multiply by alpha (2) in GF(2^8)
            x <<= 1;
            if (x & 0x100 != 0) {
                x ^= PRIMITIVE_POLY;
            }
        }
        gf.exp_table[510] = gf.exp_table[0];
        gf.exp_table[511] = gf.exp_table[1];

        // Build log table: log[exp[i]] = i
        gf.log_table[0] = 0; // log(0) is undefined, use 0
        for (0..255) |i| {
            gf.log_table[gf.exp_table[i]] = @truncate(i);
        }

        return gf;
    }

    /// Multiply two elements in GF(2^8)
    pub fn mul(self: *const GaloisField, a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        const log_a = self.log_table[a];
        const log_b = self.log_table[b];
        return self.exp_table[@as(u16, log_a) + @as(u16, log_b)];
    }

    /// Divide in GF(2^8): a / b
    pub fn div(self: *const GaloisField, a: u8, b: u8) u8 {
        if (a == 0) return 0;
        if (b == 0) return 0; // Division by zero
        const log_a = self.log_table[a];
        const log_b = self.log_table[b];
        // Handle wraparound: (log_a - log_b) mod 255
        const diff = @mod(@as(i16, log_a) - @as(i16, log_b) + 255, @as(i16, 255));
        return self.exp_table[@intCast(diff)];
    }

    /// Add in GF(2^8) - just XOR
    pub fn add(_: *const GaloisField, a: u8, b: u8) u8 {
        return a ^ b;
    }

    /// Inverse in GF(2^8)
    pub fn inv(self: *const GaloisField, a: u8) u8 {
        if (a == 0) return 0;
        return self.exp_table[255 - @as(u16, self.log_table[a])];
    }
};

/// FEC Set - tracks shreds for one FEC set
/// Reference: Firedancer src/ballet/shred/fd_fec_set.h
pub const FecSet = struct {
    allocator: std.mem.Allocator,

    /// Slot this FEC set belongs to
    slot: core.Slot,

    /// FEC set index within the slot
    fec_set_idx: u32,

    /// Expected number of data shreds (from first parity shred header)
    data_shred_cnt: u16,

    /// Expected number of parity shreds
    parity_shred_cnt: u16,

    /// Received data shreds (indexed by position in FEC set, not global index)
    data_shreds: [MAX_DATA_SHREDS]?[]u8,

    /// Received parity shreds
    parity_shreds: [MAX_PARITY_SHREDS]?[]u8,

    /// Which data shreds we have
    data_received: std.StaticBitSet(MAX_DATA_SHREDS),

    /// Which parity shreds we have
    parity_received: std.StaticBitSet(MAX_PARITY_SHREDS),

    /// Count of received data shreds
    data_received_cnt: u16,

    /// Count of received parity shreds
    parity_received_cnt: u16,

    /// Whether this FEC set is complete (all data recovered)
    is_complete: bool,

    /// Shred size (all shreds in set must be same size)
    shred_sz: usize,

    /// Last time recovery was attempted and failed (for backoff)
    last_failed_recovery_time: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot: core.Slot, fec_set_idx: u32) Self {
        return Self{
            .allocator = allocator,
            .slot = slot,
            .fec_set_idx = fec_set_idx,
            .data_shred_cnt = 0,
            .parity_shred_cnt = 0,
            .data_shreds = [_]?[]u8{null} ** MAX_DATA_SHREDS,
            .parity_shreds = [_]?[]u8{null} ** MAX_PARITY_SHREDS,
            .data_received = std.StaticBitSet(MAX_DATA_SHREDS).initEmpty(),
            .parity_received = std.StaticBitSet(MAX_PARITY_SHREDS).initEmpty(),
            .data_received_cnt = 0,
            .parity_received_cnt = 0,
            .is_complete = false,
            .shred_sz = SHRED_SIZE,
            .last_failed_recovery_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.data_shreds) |*shred| {
            if (shred.*) |s| {
                self.allocator.free(s);
                shred.* = null;
            }
        }
        for (&self.parity_shreds) |*shred| {
            if (shred.*) |s| {
                self.allocator.free(s);
                shred.* = null;
            }
        }
    }

    /// Add a data shred to this FEC set
    /// pos is the position within the FEC set (0-based)
    pub fn addDataShred(self: *Self, pos: u16, data: []const u8) !void {
        if (pos >= MAX_DATA_SHREDS) return error.InvalidPosition;
        if (self.data_received.isSet(pos)) return; // Already have it

        // Copy the shred data
        const copy = try self.allocator.alloc(u8, data.len);
        @memcpy(copy, data);

        self.data_shreds[pos] = copy;
        self.data_received.set(pos);
        self.data_received_cnt += 1;
        self.shred_sz = data.len;
    }

    /// Add a parity/coding shred to this FEC set
    pub fn addParityShred(self: *Self, pos: u16, data: []const u8, num_data: u16, num_parity: u16) !void {
        if (pos >= MAX_PARITY_SHREDS) return error.InvalidPosition;
        if (self.parity_received.isSet(pos)) return; // Already have it

        // Update expected counts from the parity shred header
        // FIX: Validate counts to prevent out-of-bounds access later
        if (self.data_shred_cnt == 0) {
            self.data_shred_cnt = @min(num_data, MAX_DATA_SHREDS);
            self.parity_shred_cnt = @min(num_parity, MAX_PARITY_SHREDS);
        }

        // Copy the shred data
        const copy = try self.allocator.alloc(u8, data.len);
        @memcpy(copy, data);

        self.parity_shreds[pos] = copy;
        self.parity_received.set(pos);
        self.parity_received_cnt += 1;
        self.shred_sz = data.len;
    }

    /// Check if we have enough shreds to attempt recovery
    pub fn canRecover(self: *const FecSet) bool {
        if (self.is_complete) return false;
        if (self.data_shred_cnt == 0) return false;

        // Backoff check: Don't retry immediately if we just failed
        // This prevents CPU spinning on unrecoverable sets (e.g., mismatching shred data)
        const now = std.time.milliTimestamp();
        if (now < self.last_failed_recovery_time + 1000) {
            return false;
        }

        const total_needed = self.data_shred_cnt;
        const total_have = self.data_received_cnt + self.parity_received_cnt;

        return total_have >= total_needed;
    }

    /// Check if already complete (have all data shreds)
    pub fn isComplete(self: *const Self) bool {
        if (self.data_shred_cnt == 0) return false;
        return self.data_received_cnt >= self.data_shred_cnt;
    }

    /// Get missing data shred indices
    pub fn getMissingDataIndices(self: *const Self, out: []u16) usize {
        var count: usize = 0;
        // FIX: Clamp data_shred_cnt to prevent out-of-bounds access
        const max_idx = @min(self.data_shred_cnt, MAX_DATA_SHREDS);
        for (0..max_idx) |i| {
            if (!self.data_received.isSet(i)) {
                if (count < out.len) {
                    out[count] = @intCast(i);
                    count += 1;
                }
            }
        }
        return count;
    }
};

/// FEC Resolver - manages multiple FEC sets and performs recovery
/// Reference: Firedancer src/disco/shred/fd_fec_resolver.c
pub const FecResolver = struct {
    allocator: std.mem.Allocator,

    /// Galois field for Reed-Solomon operations
    gf: GaloisField,

    /// SIMD-accelerated GF(2^8) engine (GFNI/AVX2/scalar)
    simd: gf_simd.GfSimd,

    /// Enable SIMD acceleration for FEC (gated by --enable-simd-fec)
    enable_simd_fec: bool,

    /// Active FEC sets by (slot, fec_set_idx) key
    active_sets: std.AutoHashMap(FecSetKey, *FecSet),

    /// Maximum concurrent FEC sets to track
    max_depth: usize,

    /// Shred version filter
    expected_shred_version: u16,

    /// Statistics
    stats: Stats,

    /// Disable RS recovery (Data-Only mode)
    /// When true, FEC sets are tracked but recovery is never attempted.
    /// This avoids the SIGSEGV crash from the RS implementation while
    /// still allowing complete slots (where all data shreds arrive naturally).
    disable_recovery: bool,

    const Self = @This();

    pub const FecSetKey = u128;
    pub inline fn makeKey(slot: core.Slot, fec_set_idx: u32) FecSetKey {
        return (@as(u128, slot) << 64) | @as(u128, fec_set_idx);
    }

    pub const Stats = struct {
        sets_started: u64 = 0,
        sets_completed: u64 = 0,
        shreds_received: u64 = 0,
        shreds_recovered: u64 = 0,
        recovery_failures: u64 = 0,
        recovery_skipped: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, max_depth: usize, shred_version: u16) Self {
        return initWithConfig(allocator, max_depth, shred_version, false);
    }

    /// Create with SIMD FEC enabled
    pub fn initWithSimd(allocator: std.mem.Allocator, max_depth: usize, shred_version: u16) Self {
        return initWithConfig(allocator, max_depth, shred_version, true);
    }

    fn initWithConfig(allocator: std.mem.Allocator, max_depth: usize, shred_version: u16, simd_enabled: bool) Self {
        const simd_engine = gf_simd.GfSimd.init();
        const runtime_tier = gf_simd.detectTierRuntime();
        if (simd_enabled) {
            std.log.info("[FEC] SIMD engine: comptime={s}, runtime={s}", .{
                gf_simd.active_tier.name(), runtime_tier.name(),
            });
        }
        return Self{
            .allocator = allocator,
            .gf = GaloisField.init(),
            .simd = simd_engine,
            .enable_simd_fec = simd_enabled,
            .active_sets = std.AutoHashMap(FecSetKey, *FecSet).init(allocator),
            .max_depth = max_depth,
            .expected_shred_version = shred_version,
            .stats = Stats{},
            .disable_recovery = false,
        };
    }

    /// Create with recovery disabled (Data-Only mode for stability)
    pub fn initDataOnly(allocator: std.mem.Allocator, max_depth: usize, shred_version: u16) Self {
        var resolver = init(allocator, max_depth, shred_version);
        resolver.disable_recovery = true;
        return resolver;
    }

    pub fn deinit(self: *Self) void {
        var it = self.active_sets.valueIterator();
        while (it.next()) |set| {
            set.*.deinit();
            self.allocator.destroy(set.*);
        }
        self.active_sets.deinit();
    }

    /// Get or create FEC set for a shred
    fn getOrCreateSet(self: *Self, slot: core.Slot, fec_set_idx: u32) !*FecSet {
        const key = makeKey(slot, fec_set_idx);

        if (self.active_sets.get(key)) |existing| {
            return existing;
        }

        // Evict oldest if at capacity
        if (self.active_sets.count() >= self.max_depth) {
            // Simple eviction: remove first entry
            var iter = self.active_sets.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                _ = self.active_sets.remove(entry.key_ptr.*);
            }
        }

        // Create new set
        const new_set = try self.allocator.create(FecSet);
        new_set.* = FecSet.init(self.allocator, slot, fec_set_idx);
        try self.active_sets.put(key, new_set);
        self.stats.sets_started += 1;

        return new_set;
    }

    /// Result of adding a shred
    pub const AddResult = enum {
        /// Shred added, waiting for more
        pending,
        /// FEC set complete, all data shreds available
        complete,
        /// Shred was duplicate
        duplicate,
        /// Shred version mismatch
        version_mismatch,
        /// Error during processing
        err,
    };

    /// Add a shred and attempt recovery if possible
    /// Returns complete if the FEC set now has all data shreds
    /// Reference: Firedancer fd_fec_resolver_add_shred
    /// Reference: Sig shred_verifier.verifyShred for validation patterns
    pub fn addShred(
        self: *Self,
        slot: core.Slot,
        shred_index: u32,
        fec_set_idx: u32,
        is_data: bool,
        shred_data: []const u8,
        shred_version: u16,
        // For parity shreds only:
        num_data: u16,
        num_parity: u16,
        parity_position: u16,
    ) !AddResult {
        // DEFENSIVE: Validate shred_data length (prevents buffer overruns)
        // Firedancer uses SHRED_SIZE=1228, we allow some flexibility
        if (shred_data.len < 88 or shred_data.len > 2048) {
            std.log.warn("[FEC] Rejecting shred with invalid size {d}", .{shred_data.len});
            return .err;
        }

        // DEFENSIVE: Validate FEC set parameters (Firedancer MAX = 67)
        if (num_data > MAX_DATA_SHREDS or num_parity > MAX_PARITY_SHREDS) {
            std.log.warn("[FEC] Rejecting shred with invalid FEC params: data={d}, parity={d}", .{ num_data, num_parity });
            return .err;
        }

        // DEFENSIVE: Validate parity position
        if (!is_data and parity_position >= MAX_PARITY_SHREDS) {
            std.log.warn("[FEC] Rejecting parity shred with invalid position {d}", .{parity_position});
            return .err;
        }

        // Check shred version
        if (shred_version != self.expected_shred_version and self.expected_shred_version != 0) {
            return .version_mismatch;
        }

        self.stats.shreds_received += 1;

        const set = self.getOrCreateSet(slot, fec_set_idx) catch |err| {
            std.log.err("[FEC] Failed to getOrCreateSet for slot {d} fec {d}: {}", .{ slot, fec_set_idx, err });
            return .err;
        };

        if (is_data) {
            // Data shred index MUST be >= fec_set_idx for Merkle V2
            if (shred_index < fec_set_idx) return .err;
            const diff = shred_index - fec_set_idx;
            if (diff >= MAX_DATA_SHREDS) return .err;
            const pos: u16 = @intCast(diff);
            set.addDataShred(pos, shred_data) catch return .duplicate;
        } else {
            set.addParityShred(parity_position, shred_data, num_data, num_parity) catch return .duplicate;

            // Log parity shred receipt (helpful for debugging)
            if (set.parity_received_cnt == 1) {
                // std.debug.print("[FEC] Slot {d} FEC set {d}: first parity, expect {d} data + {d} parity\n", .{
                //    slot, fec_set_idx, num_data, num_parity,
                // });
            }
        }

        // Check if already complete
        if (set.isComplete()) {
            set.is_complete = true;
            self.stats.sets_completed += 1;
            // std.debug.print("[FEC] Slot {d} FEC set {d} COMPLETE (all data received)\n", .{ slot, fec_set_idx });
            return .complete;
        }

        // Try recovery if we have enough shreds
        if (set.canRecover()) {
            if (self.disable_recovery) {
                // Data-Only mode: skip RS recovery to avoid SIGSEGV
                self.stats.recovery_skipped += 1;
                return .pending;
            }
            // std.debug.print("[FEC] Slot {d} FEC set {d}: attempting recovery (have {d} data + {d} parity, need {d})\n", .{
            //     slot, fec_set_idx, set.data_received_cnt, set.parity_received_cnt, set.data_shred_cnt,
            // });
            const recovered = self.tryRecover(set);
            if (recovered) {
                set.is_complete = true;
                self.stats.sets_completed += 1;
                // std.debug.print("[FEC] Slot {d} FEC set {d} RECOVERED!\n", .{ slot, fec_set_idx });
                return .complete;
            } else {
                // std.debug.print("[FEC] Slot {d} FEC set {d}: recovery FAILED\n", .{ slot, fec_set_idx });
            }
        }

        return .pending;
    }

    /// Attempt Reed-Solomon recovery on an FEC set
    /// Reference: Sig's reed_solomon.zig reconstruct() function
    ///
    /// Algorithm (following Sig's approach):
    /// 1. Build Vandermonde matrix V where V[i,j] = i^j for all shards
    /// 2. Pick rows corresponding to available shards to form submatrix
    /// 3. Invert the submatrix using Gaussian elimination
    /// 4. Multiply inverted matrix by available shard data to get missing data
    fn tryRecover(self: *Self, set: *FecSet) bool {
        if (set.data_shred_cnt == 0) return false;

        // Count missing data shreds
        var missing: [MAX_DATA_SHREDS]u16 = undefined;
        const missing_cnt = set.getMissingDataIndices(&missing);

        if (missing_cnt == 0) {
            // Already complete!
            return true;
        }

        // Need at least missing_cnt parity shreds to recover
        if (set.parity_received_cnt < missing_cnt) {
            return false;
        }

        // Perform Reed-Solomon recovery using Sig's matrix approach
        const recovered = self.recoverWithSigMethod(set, missing[0..missing_cnt]) catch {
            self.stats.recovery_failures += 1;
            set.last_failed_recovery_time = std.time.milliTimestamp();
            return false;
        };

        if (recovered) {
            self.stats.shreds_recovered += @intCast(missing_cnt);
        } else {
            set.last_failed_recovery_time = std.time.milliTimestamp();
        }

        return recovered;
    }

    /// Reed-Solomon recovery using Sig's encoding matrix approach
    ///
    /// Key insight from Sig: The encoding matrix M = V * inv(top(V)) has the property that
    /// the top n rows are identity (data shards unchanged) and bottom m rows compute parity.
    /// For decoding, we pick rows from M, not raw Vandermonde.
    ///
    /// SAFETY: Uses ArenaAllocator for all temporary matrices (~50KB total)
    /// to avoid blowing the thread stack during repair bursts.
    fn recoverWithSigMethod(self: *Self, set: *FecSet, missing_indices: []const u16) !bool {
        const n: usize = set.data_shred_cnt;
        const m: usize = set.parity_shred_cnt;
        const k = missing_indices.len;
        const shred_sz = set.shred_sz;

        if (k == 0) return true;
        if (shred_sz == 0) return false;
        if (n == 0 or n > MAX_DATA_SHREDS) return false;
        if (m == 0 or m > MAX_PARITY_SHREDS) return false;
        if (n + m > MAX_SHREDS_PER_FEC_SET) return false;

        const total = n + m;
        const total_available = set.data_received_cnt + set.parity_received_cnt;
        if (total_available < n) return false;

        // ── Arena allocator for all temporary matrices ──────────────────
        // Freed in bulk when this function returns — no leak risk.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const tmp = arena.allocator();

        // Determine erasure shard boundaries using proper Merkle-aware calculation
        var erasure_sz: usize = 0;
        var data_start: usize = SIGNATURE_SIZE;
        var proof_size: u8 = 0;
        var is_merkle = true;

        // Get erasure size from first available data shred
        for (0..n) |i| {
            if (set.data_shreds[i]) |shred| {
                erasure_sz = calculateErasureShardSize(shred, true);
                if (shred.len > 64) {
                    const variant = shred[64];
                    const parsed = parseVariantByte(variant);
                    is_merkle = parsed.is_merkle;
                    proof_size = parsed.proof_size;
                    data_start = if (is_merkle) SIGNATURE_SIZE else 0;
                }
                break;
            }
        }

        // If no data shred available, get from parity shred
        if (erasure_sz == 0) {
            for (0..m) |i| {
                if (set.parity_shreds[i]) |shred| {
                    erasure_sz = calculateErasureShardSize(shred, false);
                    if (shred.len > 64) {
                        const variant = shred[64];
                        const parsed = parseVariantByte(variant);
                        is_merkle = parsed.is_merkle;
                        proof_size = parsed.proof_size;
                    }
                    break;
                }
            }
        }

        // ── STRICT BOUNDS VALIDATION ────────────────────────────────────
        if (erasure_sz == 0) {
            std.log.err("[FEC] Could not determine erasure shard size", .{});
            return false;
        }
        const max_erasure_sz = if (shred_sz > SIGNATURE_SIZE) shred_sz - SIGNATURE_SIZE else 0;
        if (erasure_sz > max_erasure_sz) {
            std.log.err("[FEC] erasure_sz {d} exceeds max {d} (shred_sz={d}), likely corrupted variant", .{
                erasure_sz, max_erasure_sz, shred_sz,
            });
            return false;
        }
        if (data_start + erasure_sz > shred_sz) {
            std.log.err("[FEC] data_start({d}) + erasure_sz({d}) > shred_sz({d}), aborting recovery", .{
                data_start, erasure_sz, shred_sz,
            });
            return false;
        }

        const merkle_proof_sz: usize = if (is_merkle) @as(usize, proof_size) * MERKLE_PROOF_ENTRY_SIZE else 0;

        std.log.debug("[FEC] Erasure params: is_merkle={any}, proof_size={d}, merkle_proof_bytes={d}, erasure_sz={d}, data_start={d}", .{ is_merkle, proof_size, merkle_proof_sz, erasure_sz, data_start });

        // ── HEAP-ALLOCATED MATRICES (via arena) ─────────────────────────
        // Total: ~4 matrices of n×n + 2 matrices of total×n ≈ 4×67² + 2×134×67 ≈ ~36KB
        // All freed by arena.deinit() on return.
        const vandermonde = try tmp.alloc(u8, total * n);
        const top_inv = try tmp.alloc(u8, n * n);
        const augmented = try tmp.alloc(u8, n * 2 * n);
        const enc_matrix = try tmp.alloc(u8, total * n);
        const sub_matrix = try tmp.alloc(u8, n * n);
        const sub_aug = try tmp.alloc(u8, n * 2 * n);
        const decode_matrix = try tmp.alloc(u8, n * n);
        const available_rows = try tmp.alloc(usize, n);
        const available_shards = try tmp.alloc([]const u8, n);

        // Step 1: Build full Vandermonde matrix V (total x n)
        for (0..total) |row| {
            const x: u8 = @intCast(row);
            var x_pow: u8 = 1;
            for (0..n) |col| {
                vandermonde[row * n + col] = x_pow;
                if (x == 0) {
                    x_pow = 0;
                } else {
                    x_pow = self.gf.mul(x_pow, x);
                }
            }
        }

        // Step 2: Extract and invert top n x n submatrix
        for (0..n) |row| {
            for (0..n) |col| {
                augmented[row * (2 * n) + col] = vandermonde[row * n + col];
            }
            for (0..n) |col| {
                augmented[row * (2 * n) + n + col] = if (row == col) 1 else 0;
            }
        }

        // Gaussian elimination (top submatrix)
        for (0..n) |col| {
            var pivot_row = col;
            while (pivot_row < n and augmented[pivot_row * (2 * n) + col] == 0) pivot_row += 1;
            if (pivot_row >= n) return false;

            if (pivot_row != col) {
                for (0..(2 * n)) |c| {
                    const tmp_val = augmented[col * (2 * n) + c];
                    augmented[col * (2 * n) + c] = augmented[pivot_row * (2 * n) + c];
                    augmented[pivot_row * (2 * n) + c] = tmp_val;
                }
            }

            const pivot_val = augmented[col * (2 * n) + col];
            if (pivot_val != 1) {
                const inv_pivot = self.gf.inv(pivot_val);
                for (0..(2 * n)) |c| {
                    augmented[col * (2 * n) + c] = self.gf.mul(augmented[col * (2 * n) + c], inv_pivot);
                }
            }

            for (0..n) |row| {
                if (row != col) {
                    const factor = augmented[row * (2 * n) + col];
                    if (factor != 0) {
                        for (0..(2 * n)) |c| {
                            augmented[row * (2 * n) + c] = self.gf.add(augmented[row * (2 * n) + c], self.gf.mul(factor, augmented[col * (2 * n) + c]));
                        }
                    }
                }
            }
        }

        for (0..n) |row| {
            for (0..n) |col| {
                top_inv[row * n + col] = augmented[row * (2 * n) + n + col];
            }
        }

        // Step 3: Compute encoding matrix M = V * top_inv
        for (0..total) |row| {
            for (0..n) |col| {
                var sum: u8 = 0;
                for (0..n) |kk| {
                    sum = self.gf.add(sum, self.gf.mul(vandermonde[row * n + kk], top_inv[kk * n + col]));
                }
                enc_matrix[row * n + col] = sum;
            }
        }

        // Step 4: Collect available shards and their row indices
        var available_count: usize = 0;

        for (0..n) |i| {
            if (available_count >= n) break;
            if (set.data_shreds[i]) |shred| {
                const end_offset = if (shred.len > merkle_proof_sz) shred.len - merkle_proof_sz else shred.len;
                if (end_offset > data_start) {
                    available_rows[available_count] = i;
                    available_shards[available_count] = shred[data_start..end_offset];
                    available_count += 1;
                }
            }
        }

        // Parity shard collection with size alignment (arena-allocated padding)
        const code_start: usize = CODE_HEADER_SIZE;
        var target_erasure_sz: usize = 0;
        if (available_count > 0) {
            target_erasure_sz = available_shards[0].len;
        }

        for (0..m) |i| {
            if (available_count >= n) break;
            if (set.parity_shreds[i]) |shred| {
                const end_offset = if (shred.len > merkle_proof_sz) shred.len - merkle_proof_sz else shred.len;
                if (end_offset > code_start) {
                    const parity_erasure = shred[code_start..end_offset];
                    const padded_sz = if (target_erasure_sz > 0) target_erasure_sz else parity_erasure.len;

                    // Arena-allocated padding — freed with all other temporaries
                    const padded = try tmp.alloc(u8, padded_sz);
                    @memset(padded, 0);
                    const copy_len = @min(parity_erasure.len, padded_sz);
                    if (copy_len > 0) {
                        @memcpy(padded[0..copy_len], parity_erasure[0..copy_len]);
                    }

                    available_rows[available_count] = n + i;
                    available_shards[available_count] = padded;
                    available_count += 1;
                }
            }
        }

        if (available_count < n) {
            std.log.debug("[FEC] Not enough available shards: have {d}, need {d}", .{ available_count, n });
            return false;
        }

        // Step 5: Build submatrix from enc_matrix rows and invert
        for (0..n) |row| {
            const enc_row = available_rows[row];
            for (0..n) |col| {
                sub_matrix[row * n + col] = enc_matrix[enc_row * n + col];
            }
        }

        // Invert sub_matrix (Gaussian elimination)
        for (0..n) |row| {
            for (0..n) |col| {
                sub_aug[row * (2 * n) + col] = sub_matrix[row * n + col];
            }
            for (0..n) |col| {
                sub_aug[row * (2 * n) + n + col] = if (row == col) 1 else 0;
            }
        }

        for (0..n) |col| {
            var pivot_row = col;
            while (pivot_row < n and sub_aug[pivot_row * (2 * n) + col] == 0) pivot_row += 1;
            if (pivot_row >= n) return false;

            if (pivot_row != col) {
                for (0..(2 * n)) |c| {
                    const tmp_val = sub_aug[col * (2 * n) + c];
                    sub_aug[col * (2 * n) + c] = sub_aug[pivot_row * (2 * n) + c];
                    sub_aug[pivot_row * (2 * n) + c] = tmp_val;
                }
            }

            const pivot_val = sub_aug[col * (2 * n) + col];
            if (pivot_val != 1) {
                const inv_pivot = self.gf.inv(pivot_val);
                for (0..(2 * n)) |c| {
                    sub_aug[col * (2 * n) + c] = self.gf.mul(sub_aug[col * (2 * n) + c], inv_pivot);
                }
            }

            for (0..n) |row| {
                if (row != col) {
                    const factor = sub_aug[row * (2 * n) + col];
                    if (factor != 0) {
                        for (0..(2 * n)) |c| {
                            sub_aug[row * (2 * n) + c] = self.gf.add(sub_aug[row * (2 * n) + c], self.gf.mul(factor, sub_aug[col * (2 * n) + c]));
                        }
                    }
                }
            }
        }

        for (0..n) |row| {
            for (0..n) |col| {
                decode_matrix[row * n + col] = sub_aug[row * (2 * n) + n + col];
            }
        }

        // Step 6: Recover missing shreds
        //
        // LOOP INVERSION: Instead of iterating byte-by-byte (vertical) and computing
        // the dot product across shards at each position, we iterate shard-by-shard
        // (horizontal) and use mulAccum() to process the entire erasure portion in
        // one vectorized pass. This enables GFNI (64B/op) and AVX2 (32B/op) SIMD.
        //
        // Old: for each byte → for each shard → multiply-accumulate (scalar)
        // New: for each shard → mulAccum(dest_slice, src_shard_slice, coeff)  (SIMD)
        //
        // Tail handling: mulAccum() processes 64-byte chunks (GFNI) or 32-byte chunks
        // (AVX2), then falls back to scalar for the remaining bytes. For a typical
        // 1084-byte erasure portion: 16×64 = 1024 GFNI + 1×32 AVX2 + 28 scalar.
        var recovered_count: usize = 0;
        for (missing_indices) |missing_idx| {
            if (missing_idx >= n) continue;

            const decode_row_idx = missing_idx;

            // Allocate recovery buffer from MAIN allocator (outlives the arena)
            var recovered = self.allocator.alloc(u8, shred_sz) catch return false;
            @memset(recovered, 0);

            // Copy signature from a template data shred
            for (0..n) |i| {
                if (set.data_shreds[i]) |template| {
                    if (template.len >= SIGNATURE_SIZE) {
                        @memcpy(recovered[0..SIGNATURE_SIZE], template[0..SIGNATURE_SIZE]);
                    }
                    break;
                }
            }

            // BOUNDS CHECK: verify the write region fits
            if (data_start + erasure_sz > recovered.len) {
                std.log.err("[FEC] Recovery OOB: data_start({d}) + erasure_sz({d}) > recovered.len({d}), aborting", .{
                    data_start, erasure_sz, recovered.len,
                });
                self.allocator.free(recovered);
                return false;
            }

            // The destination slice for the erasure portion
            const dest = recovered[data_start..][0..erasure_sz];

            if (self.enable_simd_fec) {
                // ═══════════ SIMD PATH (inverted loop) ═══════════════════
                // Iterate shard-by-shard, applying coeff × shard horizontally.
                // mulAccum handles 64B GFNI → 32B AVX2 → scalar tail internally.
                for (0..n) |j| {
                    const coeff = decode_matrix[decode_row_idx * n + j];
                    const shard_len = available_shards[j].len;
                    const common_len = @min(erasure_sz, shard_len);
                    if (common_len > 0) {
                        self.simd.mulAccum(
                            dest[0..common_len],
                            available_shards[j][0..common_len],
                            coeff,
                        );
                    }
                }
            } else {
                // ═══════════ SCALAR PATH (original byte-by-byte) ════════
                for (0..erasure_sz) |byte_idx| {
                    var val: u8 = 0;
                    for (0..n) |j| {
                        if (byte_idx < available_shards[j].len) {
                            const coeff = decode_matrix[decode_row_idx * n + j];
                            const shard_byte = available_shards[j][byte_idx];
                            val = self.gf.add(val, self.gf.mul(coeff, shard_byte));
                        }
                    }
                    dest[byte_idx] = val;
                }
            }

            // Validate the variant byte
            const variant_byte = if (recovered.len > 64) recovered[64] else 0;
            const is_valid_data = (variant_byte >= 0x80 and variant_byte <= 0xBF) or variant_byte == 0xA5;

            if (!is_valid_data) {
                std.log.warn("[FEC] Recovered shred idx={d} variant=0x{x:0>2} invalid, discarding", .{ missing_idx, variant_byte });
                self.allocator.free(recovered);
                continue;
            }

            set.data_shreds[missing_idx] = recovered;
            set.data_received.set(missing_idx);
            set.data_received_cnt += 1;
            recovered_count += 1;
        }

        if (recovered_count > 0) {
            std.log.info("[FEC] Recovered {d}/{d} shreds (simd={any}, erasure_sz={d}, n={d}, m={d})", .{
                recovered_count, k, self.enable_simd_fec, erasure_sz, n, m,
            });
        }
        return recovered_count > 0;
    }

    /// Remove a completed FEC set to free memory
    pub fn removeSet(self: *Self, slot: core.Slot, fec_set_idx: u32) void {
        const key = makeKey(slot, fec_set_idx);
        if (self.active_sets.fetchRemove(key)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Remove all FEC sets for a slot
    pub fn removeSlot(self: *Self, slot: core.Slot) void {
        var to_remove = std.ArrayList(FecSetKey).init(self.allocator);
        defer to_remove.deinit();

        var it = self.active_sets.iterator();
        while (it.next()) |entry| {
            if (@as(u64, @intCast(entry.key_ptr.* >> 64)) == slot) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.active_sets.fetchRemove(key)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "galois field basic operations" {
    const gf = GaloisField.init();

    // Test identity
    try std.testing.expectEqual(@as(u8, 1), gf.mul(1, 1));

    // Test commutativity
    try std.testing.expectEqual(gf.mul(5, 7), gf.mul(7, 5));

    // Test inverse
    for (1..256) |i| {
        const x: u8 = @intCast(i);
        const inv_x = gf.inv(x);
        try std.testing.expectEqual(@as(u8, 1), gf.mul(x, inv_x));
    }
}

test "fec set basic operations" {
    const allocator = std.testing.allocator;

    var set = FecSet.init(allocator, 12345, 0);
    defer set.deinit();

    // Add some data shreds
    var data1: [100]u8 = undefined;
    @memset(&data1, 0xAA);
    try set.addDataShred(0, &data1);

    try std.testing.expectEqual(@as(u16, 1), set.data_received_cnt);
    try std.testing.expect(set.data_received.isSet(0));
}
