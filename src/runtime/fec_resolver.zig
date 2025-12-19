//! Vexor FEC Resolver
//!
//! Reed-Solomon Forward Error Correction for shred recovery.
//! Based on Firedancer: src/disco/shred/fd_fec_resolver.c
//!
//! FEC sets allow recovery of missing shreds using coding (parity) shreds.
//! Solana uses Reed-Solomon erasure coding in GF(2^8).

const std = @import("std");
const core = @import("../core/root.zig");

/// Maximum data shreds per FEC set (from Firedancer FD_REEDSOL_DATA_SHREDS_MAX)
pub const MAX_DATA_SHREDS: usize = 67;

/// Maximum parity/coding shreds per FEC set (from Firedancer FD_REEDSOL_PARITY_SHREDS_MAX)
pub const MAX_PARITY_SHREDS: usize = 67;

/// Total maximum shreds in an FEC set
pub const MAX_SHREDS_PER_FEC_SET: usize = MAX_DATA_SHREDS + MAX_PARITY_SHREDS;

/// Standard shred size
pub const SHRED_SIZE: usize = 1228;

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
        const diff = (@as(i16, log_a) - @as(i16, log_b) + 255) % 255;
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
        if (self.data_shred_cnt == 0) {
            self.data_shred_cnt = num_data;
            self.parity_shred_cnt = num_parity;
        }

        // Copy the shred data
        const copy = try self.allocator.alloc(u8, data.len);
        @memcpy(copy, data);

        self.parity_shreds[pos] = copy;
        self.parity_received.set(pos);
        self.parity_received_cnt += 1;
        self.shred_sz = data.len;
    }

    /// Check if we can recover missing data shreds
    pub fn canRecover(self: *const Self) bool {
        if (self.data_shred_cnt == 0) return false; // Don't know expected counts yet

        // Need at least data_shred_cnt total shreds to recover
        const total_received = self.data_received_cnt + self.parity_received_cnt;
        return total_received >= self.data_shred_cnt;
    }

    /// Check if already complete (have all data shreds)
    pub fn isComplete(self: *const Self) bool {
        if (self.data_shred_cnt == 0) return false;
        return self.data_received_cnt >= self.data_shred_cnt;
    }

    /// Get missing data shred indices
    pub fn getMissingDataIndices(self: *const Self, out: []u16) usize {
        var count: usize = 0;
        for (0..self.data_shred_cnt) |i| {
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

    /// Active FEC sets by (slot, fec_set_idx) key
    active_sets: std.AutoHashMap(FecSetKey, *FecSet),

    /// Maximum concurrent FEC sets to track
    max_depth: usize,

    /// Shred version filter
    expected_shred_version: u16,

    /// Statistics
    stats: Stats,

    const Self = @This();

    pub const FecSetKey = struct {
        slot: core.Slot,
        fec_set_idx: u32,
    };

    pub const Stats = struct {
        sets_started: u64 = 0,
        sets_completed: u64 = 0,
        shreds_received: u64 = 0,
        shreds_recovered: u64 = 0,
        recovery_failures: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, max_depth: usize, shred_version: u16) Self {
        return Self{
            .allocator = allocator,
            .gf = GaloisField.init(),
            .active_sets = std.AutoHashMap(FecSetKey, *FecSet).init(allocator),
            .max_depth = max_depth,
            .expected_shred_version = shred_version,
            .stats = Stats{},
        };
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
        const key = FecSetKey{ .slot = slot, .fec_set_idx = fec_set_idx };

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
        // Check shred version
        if (shred_version != self.expected_shred_version and self.expected_shred_version != 0) {
            return .version_mismatch;
        }

        self.stats.shreds_received += 1;

        const set = try self.getOrCreateSet(slot, fec_set_idx);

        if (is_data) {
            // Data shred: position is (shred_index - first_shred_index_of_fec_set)
            // For simplicity, use shred_index mod max_data_shreds
            const pos: u16 = @intCast(shred_index % MAX_DATA_SHREDS);
            set.addDataShred(pos, shred_data) catch return .duplicate;
        } else {
            set.addParityShred(parity_position, shred_data, num_data, num_parity) catch return .duplicate;
        }

        // Check if already complete
        if (set.isComplete()) {
            set.is_complete = true;
            self.stats.sets_completed += 1;
            return .complete;
        }

        // Try recovery if we have enough shreds
        if (set.canRecover()) {
            const recovered = self.tryRecover(set);
            if (recovered) {
                set.is_complete = true;
                self.stats.sets_completed += 1;
                return .complete;
            }
        }

        return .pending;
    }

    /// Attempt Reed-Solomon recovery on an FEC set
    /// Reference: Firedancer fd_reedsol_recover_fini
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

        // Perform Reed-Solomon recovery
        // This is a simplified version - full implementation would use
        // matrix inversion in GF(2^8)
        const recovered = self.reedSolomonRecover(set, missing[0..missing_cnt]) catch {
            self.stats.recovery_failures += 1;
            return false;
        };

        if (recovered) {
            self.stats.shreds_recovered += @intCast(missing_cnt);
        }

        return recovered;
    }

    /// Reed-Solomon recovery using Galois Field arithmetic
    /// Reference: Firedancer src/ballet/reedsol/fd_reedsol_recover.c
    fn reedSolomonRecover(self: *Self, set: *FecSet, missing_indices: []const u16) !bool {
        const n = set.data_shred_cnt;
        const k = missing_indices.len;

        if (k == 0) return true;
        if (k > set.parity_received_cnt) return false;

        // For each missing data shred, we need to solve the Reed-Solomon equation
        // This is done by building and inverting a matrix

        // Simplified single-erasure recovery (most common case)
        if (k == 1) {
            return try self.recoverSingleErasure(set, missing_indices[0]);
        }

        // Multi-erasure recovery requires full matrix inversion
        // For now, return false - full implementation would use Gaussian elimination
        _ = n;
        return false;
    }

    /// Optimized single-erasure recovery
    /// When only one data shred is missing, XOR all received data and parity
    fn recoverSingleErasure(self: *Self, set: *FecSet, missing_idx: u16) !bool {
        const shred_sz = set.shred_sz;
        if (shred_sz == 0) return false;

        // Allocate buffer for recovered shred
        var recovered = try self.allocator.alloc(u8, shred_sz);
        @memset(recovered, 0);

        // XOR all received data shreds
        for (0..set.data_shred_cnt) |i| {
            if (i == missing_idx) continue;
            if (set.data_shreds[i]) |shred| {
                for (0..@min(shred.len, recovered.len)) |j| {
                    recovered[j] ^= shred[j];
                }
            } else {
                // Missing another data shred - can't use single erasure
                self.allocator.free(recovered);
                return false;
            }
        }

        // XOR with first available parity shred
        var found_parity = false;
        for (0..set.parity_shred_cnt) |i| {
            if (set.parity_shreds[i]) |parity| {
                for (0..@min(parity.len, recovered.len)) |j| {
                    recovered[j] ^= parity[j];
                }
                found_parity = true;
                break;
            }
        }

        if (!found_parity) {
            self.allocator.free(recovered);
            return false;
        }

        // Store recovered shred
        set.data_shreds[missing_idx] = recovered;
        set.data_received.set(missing_idx);
        set.data_received_cnt += 1;

        return true;
    }

    /// Get completed FEC set data shreds
    pub fn getCompletedSetData(self: *Self, slot: core.Slot, fec_set_idx: u32) ?[]*const []u8 {
        const key = FecSetKey{ .slot = slot, .fec_set_idx = fec_set_idx };
        const set = self.active_sets.get(key) orelse return null;

        if (!set.is_complete) return null;

        // Return slice of data shreds
        var result: [MAX_DATA_SHREDS]*const []u8 = undefined;
        for (0..set.data_shred_cnt) |i| {
            if (set.data_shreds[i]) |shred| {
                result[i] = shred;
            } else {
                return null;
            }
        }

        return result[0..set.data_shred_cnt];
    }

    /// Remove a completed FEC set to free memory
    pub fn removeSet(self: *Self, slot: core.Slot, fec_set_idx: u32) void {
        const key = FecSetKey{ .slot = slot, .fec_set_idx = fec_set_idx };
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
            if (entry.key_ptr.slot == slot) {
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

