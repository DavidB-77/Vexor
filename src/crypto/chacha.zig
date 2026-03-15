//! ChaCha20 Random Number Generator
//!
//! Port of ChaCha from Rust's `rand_chacha` crate to match Sig/Agave behavior.
//! This is needed for deterministic Turbine tree shuffling.
//!
//! Reference: Sig's rand/chacha.zig

const std = @import("std");
const builtin = @import("builtin");

const endian = builtin.cpu.arch.endian();

/// ChaCha20 Random Number Generator
/// Generates the same stream as ChaChaRng in Rust's `rand_chacha`.
pub const ChaChaRng = struct {
    core: ChaCha20,
    /// Buffer of generated random bytes
    buffer: [256]u8,
    /// Index into buffer
    index: usize,

    const Self = @This();

    /// Create a new ChaChaRng from a 32-byte seed
    pub fn fromSeed(seed: [32]u8) Self {
        return Self{
            .core = ChaCha20.init(seed, .{0} ** 12),
            .buffer = undefined,
            .index = 256, // Start exhausted to force generation
        };
    }

    /// Get a std.Random interface
    pub fn random(self: *Self) std.Random {
        return .{
            .ptr = self,
            .fillFn = fill,
        };
    }

    fn fill(ptr: *anyopaque, buf: []u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        while (i < buf.len) {
            if (self.index >= 256) {
                self.generate();
            }
            const remaining = @min(256 - self.index, buf.len - i);
            @memcpy(buf[i..][0..remaining], self.buffer[self.index..][0..remaining]);
            self.index += remaining;
            i += remaining;
        }
    }

    fn generate(self: *Self) void {
        var out: [64]u32 = undefined;
        self.core.generate(&out);
        self.buffer = @bitCast(out);
        self.index = 0;
    }
};

/// ChaCha20 stream cipher core
const ChaCha20 = struct {
    b: [4]u32,
    c: [4]u32,
    d: [4]u32,

    const Self = @This();
    const ROUNDS = 20;

    pub fn init(key: [32]u8, nonce: [12]u8) Self {
        const ctr_nonce = .{0} ++ leIntBitCast([3]u32, nonce);
        return .{
            .b = leIntBitCast([4]u32, key[0..16].*),
            .c = leIntBitCast([4]u32, key[16..].*),
            .d = ctr_nonce,
        };
    }

    /// Generate next block of 64 u32s
    pub fn generate(self: *Self, out: *[64]u32) void {
        const k = comptime leIntBitCast([4]u32, @as([16]u8, "expand 32-byte k".*));
        const b = self.b;
        const c = self.c;
        var x = State{
            .a = .{ k, k, k, k },
            .b = .{ b, b, b, b },
            .c = .{ c, c, c, c },
            .d = repeat4timesAndAdd0123(self.d),
        };
        for (0..ROUNDS / 2) |_| {
            x = diagonalize(round(diagonalize(round(x), 1)), @as(i32, -1));
        }
        const sb = self.b;
        const sc = self.c;
        const sd = repeat4timesAndAdd0123(self.d);
        const results: [64]u32 = @bitCast(transpose4(.{
            wrappingAddEachInt(x.a, .{ k, k, k, k }),
            wrappingAddEachInt(x.b, .{ sb, sb, sb, sb }),
            wrappingAddEachInt(x.c, .{ sc, sc, sc, sc }),
            wrappingAddEachInt(x.d, sd),
        }));
        @memcpy(out[0..64], &results);
        self.d = wrappingAddToFirstHalf(sd[0], 4);
    }
};

const State = struct {
    a: [4][4]u32,
    b: [4][4]u32,
    c: [4][4]u32,
    d: [4][4]u32,
};

fn transpose4(a: [4][4][4]u32) [4][4][4]u32 {
    return .{
        .{ a[0][0], a[1][0], a[2][0], a[3][0] },
        .{ a[0][1], a[1][1], a[2][1], a[3][1] },
        .{ a[0][2], a[1][2], a[2][2], a[3][2] },
        .{ a[0][3], a[1][3], a[2][3], a[3][3] },
    };
}

fn wrappingAddToFirstHalf(d: [4]u32, i: u64) [4]u32 {
    var u64s = leIntBitCast([2]u64, d);
    u64s[0] +%= i;
    return leIntBitCast([4]u32, u64s);
}

fn repeat4timesAndAdd0123(d: [4]u32) [4][4]u32 {
    return .{
        wrappingAddToFirstHalf(d, 0),
        wrappingAddToFirstHalf(d, 1),
        wrappingAddToFirstHalf(d, 2),
        wrappingAddToFirstHalf(d, 3),
    };
}

fn round(state: State) State {
    var x = state;
    x.a = wrappingAddEachInt(x.a, x.b);
    x.d = xorThenRotateRight(x.d, x.a, 16);
    x.c = wrappingAddEachInt(x.c, x.d);
    x.b = xorThenRotateRight(x.b, x.c, 20);
    x.a = wrappingAddEachInt(x.a, x.b);
    x.d = xorThenRotateRight(x.d, x.a, 24);
    x.c = wrappingAddEachInt(x.c, x.d);
    x.b = xorThenRotateRight(x.b, x.c, 25);
    return x;
}

fn diagonalize(state: State, comptime dir: i32) State {
    var x = state;
    // Rotate rows for diagonal access
    if (dir == 1) {
        x.b = rotateRows(x.b, 1);
        x.c = rotateRows(x.c, 2);
        x.d = rotateRows(x.d, 3);
    } else {
        x.b = rotateRows(x.b, 3);
        x.c = rotateRows(x.c, 2);
        x.d = rotateRows(x.d, 1);
    }
    return x;
}

fn rotateRows(m: [4][4]u32, amount: usize) [4][4]u32 {
    var result: [4][4]u32 = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            result[i][j] = m[i][(j + amount) % 4];
        }
    }
    return result;
}

fn wrappingAddEachInt(a: [4][4]u32, b: [4][4]u32) [4][4]u32 {
    var sum: [4][4]u32 = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            sum[i][j] = a[i][j] +% b[i][j];
        }
    }
    return sum;
}

fn xorThenRotateRight(const_lhs: [4][4]u32, rhs: [4][4]u32, comptime rotate: u5) [4][4]u32 {
    var lhs = const_lhs;
    for (0..4) |i| {
        for (0..4) |j| {
            const xor_val = lhs[i][j] ^ rhs[i][j];
            lhs[i][j] = std.math.rotr(u32, xor_val, rotate);
        }
    }
    return lhs;
}

fn leIntBitCast(comptime Output: type, input: anytype) Output {
    switch (endian) {
        .little => return @bitCast(input),
        .big => {
            if (numItems(Output) > numItems(@TypeOf(input))) {
                var in = input;
                for (&in) |*n| n.* = @byteSwap(n.*);
                return @bitCast(in);
            } else {
                var out: Output = @bitCast(input);
                for (&out) |*n| n.* = @byteSwap(n.*);
                return out;
            }
        },
    }
}

fn numItems(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .array => |a| a.len,
        else => 1,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "chacha20 basic" {
    var rng = ChaChaRng.fromSeed([_]u8{0} ** 32);
    const random = rng.random();
    
    // Just verify it produces some output
    const val1 = random.int(u64);
    const val2 = random.int(u64);
    try std.testing.expect(val1 != val2);
}

test "chacha20 deterministic" {
    const seed = [_]u8{0x42} ** 32;
    var rng1 = ChaChaRng.fromSeed(seed);
    var rng2 = ChaChaRng.fromSeed(seed);
    
    const random1 = rng1.random();
    const random2 = rng2.random();
    
    // Same seed should produce same sequence
    for (0..100) |_| {
        try std.testing.expectEqual(random1.int(u64), random2.int(u64));
    }
}
