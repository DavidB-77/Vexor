//! Weighted Shuffle for Turbine Tree
//!
//! Implements stake-weighted shuffling where higher-weighted indices
//! appear earlier proportionally to their weight.
//!
//! Reference: Sig's rand/weighted_shuffle.zig

const std = @import("std");
const chacha = @import("chacha.zig");

/// Weighted shuffle iterator
/// Indices are returned in order proportional to their weights.
pub fn WeightedShuffle(comptime Int: type) type {
    return struct {
        allocator: std.mem.Allocator,
        /// Tree structure for efficient weighted sampling
        /// tree[i] contains partial sums for the subtree rooted at i
        tree: std.ArrayList([FANOUT - 1]Int),
        /// Current sum of all weights
        weight: Int,
        /// Indices with zero weight (shuffled at the end)
        zeros: std.ArrayList(usize),

        const BIT_SHIFT: usize = 4;
        const FANOUT: usize = 1 << BIT_SHIFT;
        const BIT_MASK: usize = FANOUT - 1;

        const Self = @This();

        /// Initialize with weights array
        pub fn init(allocator: std.mem.Allocator, weights: []const Int) !Self {
            const tree_size = getTreeSize(weights.len);
            var tree = try std.ArrayList([FANOUT - 1]Int).initCapacity(allocator, tree_size);
            for (0..tree_size) |_| {
                tree.appendAssumeCapacity([_]Int{0} ** (FANOUT - 1));
            }

            var sum: Int = 0;
            var zeros = std.ArrayList(usize).init(allocator);

            for (weights, 0..) |weight, k| {
                if (weight <= 0) {
                    try zeros.append(k);
                    continue;
                }
                // Check for overflow
                if (std.math.maxInt(Int) - sum < weight) {
                    try zeros.append(k);
                    continue;
                }
                sum += weight;
                var index = tree.items.len + k;
                while (index != 0) {
                    const offset = index & BIT_MASK;
                    index = (index - 1) >> BIT_SHIFT;
                    if (offset > 0) {
                        tree.items[index][offset - 1] += weight;
                    }
                }
            }

            return .{
                .allocator = allocator,
                .tree = tree,
                .weight = sum,
                .zeros = zeros,
            };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
            self.zeros.deinit();
        }

        pub fn clone(self: *const Self) !Self {
            return .{
                .allocator = self.allocator,
                .tree = try self.tree.clone(),
                .weight = self.weight,
                .zeros = try self.zeros.clone(),
            };
        }

        /// Remove weight at specified index
        pub fn remove(self: *Self, index: usize, weight: Int) void {
            if (self.weight < weight) return;
            self.weight -= weight;
            var curr_index = self.tree.items.len + index;
            while (curr_index != 0) {
                const offset = curr_index & BIT_MASK;
                curr_index = (curr_index - 1) >> BIT_SHIFT;
                if (offset > 0) {
                    if (self.tree.items[curr_index][offset - 1] >= weight) {
                        self.tree.items[curr_index][offset - 1] -= weight;
                    }
                }
            }
        }

        /// Remove index from the tree
        pub fn removeIndex(self: *Self, index: usize) void {
            var curr_index = self.tree.items.len + index;
            var weight: Int = 0;
            while (curr_index != 0) {
                const offset = curr_index & BIT_MASK;
                curr_index = (curr_index - 1) >> BIT_SHIFT;
                if (offset > 0) {
                    if (self.tree.items[curr_index][offset - 1] != weight) {
                        self.remove(index, self.tree.items[curr_index][offset - 1] - weight);
                    } else {
                        self.removeZero(index);
                    }
                    return;
                }
                for (self.tree.items[curr_index]) |node| {
                    weight += node;
                }
            }
            if (self.weight != weight) {
                self.remove(index, self.weight - weight);
            } else {
                self.removeZero(index);
            }
        }

        fn removeZero(self: *Self, k: usize) void {
            var found_idx: ?usize = null;
            for (self.zeros.items, 0..) |i, j| {
                if (i == k) {
                    found_idx = j;
                    break;
                }
            }
            if (found_idx) |idx| {
                _ = self.zeros.orderedRemove(idx);
            }
        }

        /// Search for smallest index where sum of weights[..=k] > val
        pub fn search(self: *const Self, value: Int) struct { usize, Int } {
            var val = value;
            var index: usize = 0;
            var weight = self.weight;

            while (index < self.tree.items.len) {
                var continue_to_next_iter = false;
                for (self.tree.items[index], 0..) |node, j| {
                    if (val < node) {
                        weight = node;
                        index = (index << BIT_SHIFT) + j + 1;
                        continue_to_next_iter = true;
                        break;
                    }
                    if (weight >= node) weight -= node;
                    if (val >= node) val -= node;
                }
                if (continue_to_next_iter) continue;
                index = (index << BIT_SHIFT) + FANOUT;
            }
            return .{ index - self.tree.items.len, weight };
        }

        /// Get a shuffle iterator
        pub fn shuffle(self: *Self, random: std.Random) Iterator {
            return .{
                .weighted_shuffle = self,
                .rng = random,
            };
        }

        fn getTreeSize(count: usize) usize {
            if (count <= 1) return 1;
            var size: usize = 0;
            var nodes: usize = 1;
            while (nodes < count) {
                size += nodes;
                nodes *= FANOUT;
            }
            return size;
        }

        pub const Iterator = struct {
            weighted_shuffle: *Self,
            rng: std.Random,

            pub fn next(self: *Iterator) ?usize {
                if (self.weighted_shuffle.weight > 0) {
                    const sample = uintLessThanRust(Int, self.rng, self.weighted_shuffle.weight);
                    const index, const weight = self.weighted_shuffle.search(sample);
                    self.weighted_shuffle.remove(index, weight);
                    return index;
                }
                if (self.weighted_shuffle.zeros.items.len == 0) return null;
                const idx = uintLessThanRust(usize, self.rng, self.weighted_shuffle.zeros.items.len);
                return self.weighted_shuffle.zeros.swapRemove(idx);
            }
        };
    };
}

/// Custom RNG downsampling to match Rust's rand behavior
pub fn uintLessThanRust(comptime T: type, random: std.Random, less_than: T) T {
    return intRangeLessThanRust(T, random, 0, less_than);
}

pub fn intRangeLessThanRust(comptime T: type, random: std.Random, at_least: T, less_than: T) T {
    const Unsigned = switch (T) {
        i8, u8 => u8,
        i16, u16 => u16,
        i32, u32 => u32,
        i64, u64 => u64,
        i128, u128 => u128,
        isize, usize => usize,
        else => @compileError("Unsupported integer type"),
    };
    const UnsignedLarge = switch (T) {
        i8, u8 => u32,
        i16, u16 => u32,
        i32, u32 => u32,
        i64, u64 => u64,
        i128, u128 => u128,
        isize, usize => usize,
        else => @compileError("Unsupported integer type"),
    };

    const range_t = less_than -% at_least;
    const range_u: Unsigned = @intCast(range_t);
    const range_ul: UnsignedLarge = @intCast(range_u);

    if (range_ul == 0) return random.int(T);

    const zone_ul: UnsignedLarge = if (std.math.maxInt(Unsigned) <= std.math.maxInt(u16)) blk: {
        const unsigned_max = std.math.maxInt(UnsignedLarge);
        const ints_to_reject = (unsigned_max - range_ul + 1) % range_ul;
        break :blk unsigned_max - ints_to_reject;
    } else blk: {
        break :blk (range_ul << @as(u6, @truncate(@clz(range_ul)))) -% 1;
    };

    while (true) {
        const v_ul = random.int(UnsignedLarge);
        const tmp = std.math.mulWide(UnsignedLarge, v_ul, range_ul);
        const lo: UnsignedLarge = @truncate(tmp);
        const hi: Unsigned = @truncate(tmp >> @typeInfo(UnsignedLarge).Int.bits);
        if (lo <= zone_ul) return at_least + @as(T, @intCast(hi));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "weighted shuffle basic" {
    const allocator = std.testing.allocator;
    const weights = [_]u64{ 100, 200, 300, 400 };

    var ws = try WeightedShuffle(u64).init(allocator, &weights);
    defer ws.deinit();

    // Should have total weight of 1000
    try std.testing.expectEqual(@as(u64, 1000), ws.weight);
}

test "weighted shuffle deterministic" {
    const allocator = std.testing.allocator;
    const weights = [_]u64{ 100, 200, 300, 400, 500 };

    var ws1 = try WeightedShuffle(u64).init(allocator, &weights);
    defer ws1.deinit();
    var ws2 = try WeightedShuffle(u64).init(allocator, &weights);
    defer ws2.deinit();

    const seed = [_]u8{0x42} ** 32;
    var rng1 = chacha.ChaChaRng.fromSeed(seed);
    var rng2 = chacha.ChaChaRng.fromSeed(seed);

    var iter1 = ws1.shuffle(rng1.random());
    var iter2 = ws2.shuffle(rng2.random());

    // Same seed should produce same shuffle order
    while (iter1.next()) |idx1| {
        const idx2 = iter2.next() orelse break;
        try std.testing.expectEqual(idx1, idx2);
    }
}

test "weighted shuffle higher weights first" {
    const allocator = std.testing.allocator;
    // Very skewed weights - 1000 should almost always come first
    const weights = [_]u64{ 1, 1, 1, 1000 };

    var first_counts = [_]usize{0} ** 4;

    for (0..100) |i| {
        var ws = try WeightedShuffle(u64).init(allocator, &weights);
        defer ws.deinit();

        var seed: [32]u8 = undefined;
        @memcpy(seed[0..8], std.mem.asBytes(&i));
        @memset(seed[8..], 0);
        var rng = chacha.ChaChaRng.fromSeed(seed);

        var iter = ws.shuffle(rng.random());
        if (iter.next()) |first| {
            first_counts[first] += 1;
        }
    }

    // Index 3 (weight 1000) should appear first most often
    try std.testing.expect(first_counts[3] > 80);
}
