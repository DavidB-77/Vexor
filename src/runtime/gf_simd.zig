//! SIMD-accelerated GF(2^8) multiply-accumulate for Reed-Solomon FEC.
//!
//! Three tiers of hardware acceleration for the RS recovery hot loop:
//!   Tier 1: GFNI + AVX-512F — 64 bytes/instruction (AMD Zen 4, Intel Icelake+)
//!   Tier 2: AVX2 vpshufb    — 32 bytes/instruction (Intel Haswell+, AMD Zen+)
//!   Tier 3: Scalar log/exp  —  1 byte/instruction  (Universal fallback)
//!
//! Usage:
//!   const simd = GfSimd.init();
//!   // dst[i] ^= gfMul(coeff, src[i])  for all i
//!   simd.mulAccum(dst, src, coeff);
//!
//! Build with `-Dcpu=znver4` (or `-Dcpu=native` on Zen 4) to activate GFNI.
//! Build with `-Dcpu=x86_64_v3` for AVX2. Generic builds use scalar fallback.

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════
// Compile-Time Feature Detection
// ═══════════════════════════════════════════════════════════════════════════

const is_x86_64 = builtin.cpu.arch == .x86_64;

pub const has_gfni_avx512: bool = is_x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .gfni) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);

pub const has_avx2: bool = is_x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// Active tier (resolved at comptime — dead code is eliminated)
pub const active_tier: GfTier = if (has_gfni_avx512)
    .gfni_avx512
else if (has_avx2)
    .avx2
else
    .scalar;

pub const GfTier = enum {
    gfni_avx512, // 64 bytes/cycle
    avx2, // 32 bytes/cycle
    scalar, // 1 byte/cycle

    pub fn name(self: GfTier) []const u8 {
        return switch (self) {
            .gfni_avx512 => "GFNI+AVX-512 (64B/cycle)",
            .avx2 => "AVX2 vpshufb (32B/cycle)",
            .scalar => "Scalar log/exp (1B/cycle)",
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// GF(2^8) Primitives (used for table construction — NOT in hot path)
// ═══════════════════════════════════════════════════════════════════════════

/// GF(2^8) with irreducible polynomial x^8 + x^4 + x^3 + x^2 + 1
const POLY: u16 = 0x11D;

/// Scalar GF(2^8) multiply using peasant multiplication.
/// Only used during table/matrix construction at init time.
pub fn gfMulScalar(a: u8, b: u8) u8 {
    var r: u8 = 0;
    var aa: u16 = a;
    var bb: u8 = b;
    inline for (0..8) |_| {
        if (bb & 1 != 0) r ^= @truncate(aa);
        bb >>= 1;
        aa <<= 1;
        if (aa & 0x100 != 0) aa ^= POLY;
    }
    return r;
}

// ═══════════════════════════════════════════════════════════════════════════
// The GfSimd Engine
// ═══════════════════════════════════════════════════════════════════════════

pub const GfSimd = struct {
    /// Log/exp tables for scalar fallback path
    log_table: [256]u8,
    exp_table: [512]u8,

    /// Pre-computed GFNI matrices: gfni_matrices[c] = 8x8 bit matrix for mul-by-c
    /// Only populated when tier == .gfni_avx512
    gfni_matrices: [256]u64,

    /// Pre-computed split-tables for AVX2: lo_tables[c] and hi_tables[c]
    /// Only populated when tier == .avx2
    lo_tables: [256][16]u8,
    hi_tables: [256][16]u8,

    tier: GfTier,

    pub fn init() GfSimd {
        var self: GfSimd = undefined;
        self.tier = active_tier;

        // Always build log/exp tables (needed for scalar path and table construction)
        var x: u16 = 1;
        for (0..255) |i| {
            self.exp_table[i] = @truncate(x);
            self.exp_table[i + 255] = @truncate(x);
            x <<= 1;
            if (x & 0x100 != 0) x ^= POLY;
        }
        self.exp_table[510] = self.exp_table[0];
        self.exp_table[511] = self.exp_table[1];
        self.log_table[0] = 0;
        for (0..255) |i| {
            self.log_table[self.exp_table[i]] = @truncate(i);
        }

        // Build tier-specific lookup structures
        if (comptime has_gfni_avx512) {
            for (0..256) |c| {
                self.gfni_matrices[c] = buildGfniMatrix(@truncate(c));
            }
        }

        if (comptime has_avx2 or has_gfni_avx512) {
            // AVX2 tables are also useful as a secondary path
            for (0..256) |c| {
                const coeff: u8 = @truncate(c);
                for (0..16) |i| {
                    self.lo_tables[c][i] = gfMulScalar(coeff, @truncate(i));
                    self.hi_tables[c][i] = gfMulScalar(coeff, @truncate(i << 4));
                }
            }
        }

        std.log.info("[FEC-SIMD] GF(2^8) engine initialized: {s}", .{self.tier.name()});
        return self;
    }

    /// Scalar GF multiply using log/exp tables
    pub inline fn mul(self: *const GfSimd, a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return self.exp_table[@as(u16, self.log_table[a]) + @as(u16, self.log_table[b])];
    }

    // ═══════════════════════════════════════════════════════════════════
    // The Core Operation: Multiply-Accumulate
    //   dst[i] ^= gfMul(coeff, src[i])   for all i in 0..len
    //
    // This is the innermost loop of RS recovery. Each recovered byte is
    // the XOR-sum of (decode_matrix_coeff * available_shard_byte) across
    // all n available shards. Vectorizing this loop gives us 32-64x speedup.
    // ═══════════════════════════════════════════════════════════════════

    pub fn mulAccum(self: *const GfSimd, dst: []u8, src: []const u8, coeff: u8) void {
        std.debug.assert(dst.len == src.len);
        if (coeff == 0) return;
        if (coeff == 1) {
            // Multiply by 1 = identity → just XOR
            for (dst, src) |*d, s| d.* ^= s;
            return;
        }

        if (comptime has_gfni_avx512) {
            self.mulAccumGfni(dst, src, coeff);
        } else if (comptime has_avx2) {
            self.mulAccumAvx2(dst, src, coeff);
        } else {
            self.mulAccumScalar(dst, src, coeff);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tier 3: Scalar Fallback (1 byte/cycle)
    // ═══════════════════════════════════════════════════════════════════

    fn mulAccumScalar(self: *const GfSimd, dst: []u8, src: []const u8, coeff: u8) void {
        const log_c = self.log_table[coeff];
        for (dst, src) |*d, s| {
            if (s != 0) {
                d.* ^= self.exp_table[@as(u16, self.log_table[s]) + @as(u16, log_c)];
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tier 2: AVX2 vpshufb Split-Table (32 bytes/cycle)
    //
    // Technique: Split each input byte into two 4-bit nibbles.
    // Use vpshufb as a 16-entry lookup table for each nibble half.
    //   product = lo_table[byte & 0x0F] ^ hi_table[byte >> 4]
    //
    // vpshufb processes 32 bytes in parallel (YMM register).
    // ═══════════════════════════════════════════════════════════════════

    fn mulAccumAvx2(self: *const GfSimd, dst: []u8, src: []const u8, coeff: u8) void {
        const lo_tbl = &self.lo_tables[coeff];
        const hi_tbl = &self.hi_tables[coeff];
        // 0x0F mask for nibble extraction (stack-allocated, loaded once)
        const nibble_mask = [_]u8{0x0F} ** 32;

        var i: usize = 0;

        // Main SIMD loop: 32 bytes per iteration
        while (i + 32 <= src.len) : (i += 32) {
            const src_ptr = src.ptr + i;
            const dst_ptr = dst.ptr + i;

            // AVX2 vpshufb split-table multiply + XOR accumulate
            //
            // Algorithm for each byte b:
            //   lo_nibble = b & 0x0F
            //   hi_nibble = b >> 4
            //   product   = lo_table[lo_nibble] ^ hi_table[hi_nibble]
            //   dst      ^= product
            //
            // vpshufb performs 16-entry table lookup using the low 4 bits
            // of each index byte (high bit zeros the output — masked by vpand).
            asm volatile (
            // Load lookup tables — broadcast 16B across both 128-bit lanes
                \\vbroadcasti128 (%[lo]), %%ymm0
                \\vbroadcasti128 (%[hi]), %%ymm1
                // Load 32 bytes of source data
                \\vmovdqu (%[src]), %%ymm2
                // Load nibble mask (0x0F in every byte)
                \\vmovdqu (%[mask]), %%ymm6
                // Extract low nibbles: ymm3 = src & 0x0F
                \\vpand %%ymm6, %%ymm2, %%ymm3
                // Extract high nibbles: ymm4 = (src >> 4) & 0x0F
                \\vpsrlw $4, %%ymm2, %%ymm4
                \\vpand %%ymm6, %%ymm4, %%ymm4
                // Table lookup via vpshufb (AT&T: indices, table, dst)
                \\vpshufb %%ymm3, %%ymm0, %%ymm3
                \\vpshufb %%ymm4, %%ymm1, %%ymm4
                // Combine halves: product = lo_result ^ hi_result
                \\vpxor %%ymm3, %%ymm4, %%ymm5
                // XOR-accumulate with destination
                \\vpxor (%[dst]), %%ymm5, %%ymm5
                \\vmovdqu %%ymm5, (%[dst])
                :
                : [lo] "r" (lo_tbl),
                  [hi] "r" (hi_tbl),
                  [src] "r" (src_ptr),
                  [dst] "r" (dst_ptr),
                  [mask] "r" (&nibble_mask),
                : "ymm0", "ymm1", "ymm2", "ymm3", "ymm4", "ymm5", "ymm6", "memory",
            );
        }

        // Scalar tail for remaining bytes
        const log_c = self.log_table[coeff];
        while (i < src.len) : (i += 1) {
            const s = src[i];
            if (s != 0) {
                dst[i] ^= self.exp_table[@as(u16, self.log_table[s]) + @as(u16, log_c)];
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tier 1: GFNI + AVX-512F (64 bytes/cycle)
    //
    // The GF2P8AFFINEQB instruction performs:
    //   for each byte b in src: output = M × b  (in GF(2))
    // where M is an 8×8 bit matrix packed in a u64 qword.
    //
    // To multiply by constant c in GF(2^8):
    //   Column j of M = bit representation of gfMul(c, 2^j)
    //   This works because multiplication is GF(2)-linear.
    //
    // One instruction processes 64 bytes (ZMM register) — 64x scalar speed.
    // ═══════════════════════════════════════════════════════════════════

    fn mulAccumGfni(self: *const GfSimd, dst: []u8, src: []const u8, coeff: u8) void {
        _ = self;
        const matrix = buildGfniMatrix(coeff);

        var i: usize = 0;

        // Main SIMD loop: 64 bytes per iteration
        while (i + 64 <= src.len) : (i += 64) {
            const src_ptr = src.ptr + i;
            const dst_ptr = dst.ptr + i;

            // GFNI+AVX-512: multiply 64 bytes by coeff, XOR into dst
            asm volatile (
            // Broadcast the 8x8 matrix to all 8 qwords of ZMM
                \\vpbroadcastq %[matrix_ptr], %%zmm15
                // Load 64 bytes of source data
                \\vmovdqu64 (%[src]), %%zmm0
                // GF(2^8) affine transform: zmm1 = matrix × zmm0
                \\vgf2p8affineqb $0, %%zmm15, %%zmm0, %%zmm1
                // XOR-accumulate with destination
                \\vmovdqu64 (%[dst]), %%zmm2
                \\vpxord %%zmm1, %%zmm2, %%zmm2
                \\vmovdqu64 %%zmm2, (%[dst])
                :
                : [src] "r" (src_ptr),
                  [dst] "r" (dst_ptr),
                  [matrix_ptr] "m" (matrix),
                : "zmm0", "zmm1", "zmm2", "zmm15", "memory",
            );
        }

        // AVX2 middle (32-byte chunks) if available
        while (i + 32 <= src.len) : (i += 32) {
            const src_ptr = src.ptr + i;
            const dst_ptr = dst.ptr + i;

            asm volatile (
                \\vpbroadcastq %[matrix_ptr], %%ymm15
                \\vmovdqu (%[src]), %%ymm0
                \\vgf2p8affineqb $0, %%ymm15, %%ymm0, %%ymm1
                \\vpxor (%[dst]), %%ymm1, %%ymm1
                \\vmovdqu %%ymm1, (%[dst])
                :
                : [src] "r" (src_ptr),
                  [dst] "r" (dst_ptr),
                  [matrix_ptr] "m" (matrix),
                : "ymm0", "ymm1", "ymm15", "memory",
            );
        }

        // Scalar tail (< 32 bytes remaining)
        while (i < src.len) : (i += 1) {
            dst[i] ^= gfMulScalar(coeff, src[i]);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// GFNI Matrix Construction
// ═══════════════════════════════════════════════════════════════════════════

/// Build the 8×8 GF(2) matrix for multiplication by constant `c`.
///
/// The GF2P8AFFINEQB instruction computes, for each input byte x:
///   output_bit[i] = XOR over j of ( M_byte[7-j].bit[i]  AND  x.bit[j] )
///
/// For GF(2^8) multiplication by c, column j represents gfMul(c, 2^j).
/// The matrix qword stores row 0 in the MSB (byte 7) per Intel convention.
///
/// See: Intel® 64 ISA Extensions Reference, GFNI chapter.
pub fn buildGfniMatrix(c: u8) u64 {
    var matrix: u64 = 0;
    // Byte k of the qword (k=0 is LSB) = gfMul(c, 2^(7-k))
    // This matches Intel's "byte 7-j" convention
    inline for (0..8) |k| {
        const power: u8 = @as(u8, 1) << @intCast(7 - k);
        const col_val = gfMulScalar(c, power);
        matrix |= @as(u64, col_val) << @intCast(k * 8);
    }
    return matrix;
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime CPU Feature Detection (for generic builds)
// ═══════════════════════════════════════════════════════════════════════════

/// Detect the best GF tier at runtime using CPUID.
/// Use this when the binary is built with generic x86_64 features
/// and you want to enable SIMD on capable hardware.
pub fn detectTierRuntime() GfTier {
    if (!is_x86_64) return .scalar;

    // CPUID leaf 7, subleaf 0
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
        : [eax] "{eax}" (@as(u32, 7)),
          [in_ecx] "{ecx}" (@as(u32, 0)),
        : "edx",
    );

    const cpu_avx2 = (ebx & (1 << 5)) != 0;
    const cpu_avx512f = (ebx & (1 << 16)) != 0;
    const cpu_gfni = (ecx & (1 << 8)) != 0;

    // Also verify OS has enabled AVX state saving via XGETBV (XCR0)
    var xcr0_lo: u32 = undefined;
    asm volatile ("xgetbv"
        : [eax] "={eax}" (xcr0_lo),
        : [in_ecx] "{ecx}" (@as(u32, 0)),
        : "edx",
    );
    const os_avx = (xcr0_lo & 0x06) == 0x06; // SSE + AVX state
    const os_avx512 = os_avx and (xcr0_lo & 0xE0) == 0xE0; // opmask + ZMM state

    if (cpu_gfni and cpu_avx512f and os_avx512) return .gfni_avx512;
    if (cpu_avx2 and os_avx) return .avx2;
    return .scalar;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "gfMulScalar: identity and zero" {
    // a * 1 = a
    for (1..256) |i| {
        const a: u8 = @intCast(i);
        try std.testing.expectEqual(a, gfMulScalar(a, 1));
    }
    // a * 0 = 0
    for (0..256) |i| {
        try std.testing.expectEqual(@as(u8, 0), gfMulScalar(@intCast(i), 0));
    }
}

test "gfMulScalar: commutativity" {
    for (1..50) |i| {
        for (1..50) |j| {
            const a: u8 = @intCast(i);
            const b: u8 = @intCast(j);
            try std.testing.expectEqual(gfMulScalar(a, b), gfMulScalar(b, a));
        }
    }
}

test "gfMulScalar: inverse via division" {
    // (a * b) should be derivable: test a few known products
    // 2 * 2 in GF(2^8) with poly 0x11D
    try std.testing.expectEqual(@as(u8, 4), gfMulScalar(2, 2)); // x * x = x^2
    try std.testing.expectEqual(@as(u8, 0x1D), gfMulScalar(0x80, 2)); // x^7 * x = x^8 = x^4+x^3+x^2+1
}

test "buildGfniMatrix: mul-by-1 is identity" {
    const matrix = buildGfniMatrix(1);
    // Multiplying by 1 should produce the identity matrix.
    // In GFNI convention, byte k = gfMul(1, 2^(7-k)) = 2^(7-k).
    // byte 0 (LSB) = 2^7 = 0x80, byte 7 (MSB) = 2^0 = 0x01
    const expected: u64 = 0x0102040810204080;
    try std.testing.expectEqual(expected, matrix);
}

test "buildGfniMatrix: mul-by-2 is shift" {
    const matrix = buildGfniMatrix(2);
    // byte 7 (MSB) = gfMul(2, 1) = 2
    // byte 0 (LSB) = gfMul(2, 128) = 2*128 = 256 -> reduce by 0x11D -> 0x1D
    const byte7 = @as(u8, @truncate(matrix >> 56));
    try std.testing.expectEqual(@as(u8, 2), byte7);
    const byte0 = @as(u8, @truncate(matrix));
    try std.testing.expectEqual(@as(u8, 0x1D), byte0);
}

test "GfSimd scalar mulAccum correctness" {
    const simd = GfSimd.init();

    // Test: dst ^= coeff * src
    var dst = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const coeff: u8 = 37;

    simd.mulAccum(&dst, &src, coeff);

    // Verify against reference scalar multiply
    for (0..8) |i| {
        try std.testing.expectEqual(gfMulScalar(coeff, src[i]), dst[i]);
    }
}

test "GfSimd mulAccum: XOR accumulation" {
    const simd = GfSimd.init();

    // Two rounds of mulAccum should XOR-accumulate
    var dst = [_]u8{0} ** 16;
    const src1 = [_]u8{0x42} ** 16;
    const src2 = [_]u8{0x7F} ** 16;

    simd.mulAccum(&dst, &src1, 5);
    simd.mulAccum(&dst, &src2, 11);

    // Verify: dst[i] = gfMul(5, 0x42) ^ gfMul(11, 0x7F)
    const expected = gfMulScalar(5, 0x42) ^ gfMulScalar(11, 0x7F);
    try std.testing.expectEqual(expected, dst[0]);
}

test "GfSimd mulAccum: coeff=0 is noop" {
    const simd = GfSimd.init();
    var dst = [_]u8{0xAA} ** 8;
    const src = [_]u8{0x55} ** 8;
    simd.mulAccum(&dst, &src, 0);
    // dst should be unchanged
    try std.testing.expectEqual(@as(u8, 0xAA), dst[0]);
}

test "GfSimd mulAccum: coeff=1 is XOR" {
    const simd = GfSimd.init();
    var dst = [_]u8{0xF0} ** 4;
    const src = [_]u8{0x0F} ** 4;
    simd.mulAccum(&dst, &src, 1);
    try std.testing.expectEqual(@as(u8, 0xFF), dst[0]);
}


test "detectTierRuntime: does not crash" {
    if (!is_x86_64) return;
    const tier = detectTierRuntime();
    // Just verify it returns a valid tier without crashing
    _ = tier.name();
}

test "mulAccum: 1084-byte shred (realistic tail handling)" {
    // Typical Turbine erasure portion: 1084 bytes
    // GFNI: 16 × 64 = 1024, then 32-byte YMM chunk, then 28-byte scalar tail
    const simd = GfSimd.init();
    const coeff: u8 = 0xAB;

    var src: [1084]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i ^ 0x37);

    // SIMD path
    var dst_simd = [_]u8{0} ** 1084;
    simd.mulAccum(&dst_simd, &src, coeff);

    // Reference: scalar one-at-a-time
    var dst_ref = [_]u8{0} ** 1084;
    for (&dst_ref, &src) |*d, s| d.* ^= gfMulScalar(coeff, s);

    // Every byte must match
    try std.testing.expectEqualSlices(u8, &dst_ref, &dst_simd);
}

test "mulAccum: 1-byte edge case (pure scalar tail)" {
    const simd = GfSimd.init();
    var dst = [_]u8{0};
    const src = [_]u8{0xFF};
    simd.mulAccum(&dst, &src, 42);
    try std.testing.expectEqual(gfMulScalar(42, 0xFF), dst[0]);
}

test "mulAccum: 63-byte edge case (no full SIMD chunk)" {
    const simd = GfSimd.init();
    const coeff: u8 = 200;
    var src: [63]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i + 1);

    var dst_simd = [_]u8{0} ** 63;
    simd.mulAccum(&dst_simd, &src, coeff);

    var dst_ref = [_]u8{0} ** 63;
    for (&dst_ref, &src) |*d, s| d.* ^= gfMulScalar(coeff, s);

    try std.testing.expectEqualSlices(u8, &dst_ref, &dst_simd);
}
