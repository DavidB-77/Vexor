const std = @import("std");
const fec = @import("fec_resolver.zig");
const GaloisField = fec.GaloisField;
const FecSet = fec.FecSet;
const FecResolver = fec.FecResolver;
const parseVariantByte = fec.parseVariantByte;

// ═══════════════════════════════════════════════════════════════════════
// TEST 1: Galois Field identity properties
// ═══════════════════════════════════════════════════════════════════════

test "GF(2^8) mul/div identity" {
    const gf = GaloisField.init();

    // Multiplicative identity: a * 1 = a
    for (1..256) |i| {
        const a: u8 = @intCast(i);
        try std.testing.expectEqual(a, gf.mul(a, 1));
    }

    // Zero property: a * 0 = 0
    for (0..256) |i| {
        const a: u8 = @intCast(i);
        try std.testing.expectEqual(@as(u8, 0), gf.mul(a, 0));
    }

    // Division inverse: (a * b) / b = a
    for (1..256) |i| {
        const a: u8 = @intCast(i);
        for (1..256) |j| {
            const b: u8 = @intCast(j);
            const product = gf.mul(a, b);
            try std.testing.expectEqual(a, gf.div(product, b));
        }
    }
}

test "GF(2^8) inverse: a * inv(a) = 1" {
    const gf = GaloisField.init();

    for (1..256) |i| {
        const a: u8 = @intCast(i);
        const a_inv = gf.inv(a);
        try std.testing.expectEqual(@as(u8, 1), gf.mul(a, a_inv));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 2: parseVariantByte correctness
// ═══════════════════════════════════════════════════════════════════════

test "parseVariantByte - Merkle data variants" {
    // 0x86 = Merkle data, unchained, proof_size=6
    const v1 = parseVariantByte(0x86);
    try std.testing.expect(v1.is_data);
    try std.testing.expect(v1.is_merkle);
    try std.testing.expectEqual(@as(u8, 6), v1.proof_size);

    // 0x93 = Merkle data, chained, proof_size=3
    const v2 = parseVariantByte(0x93);
    try std.testing.expect(v2.is_data);
    try std.testing.expect(v2.is_merkle);
    try std.testing.expectEqual(@as(u8, 3), v2.proof_size);

    // 0xB0 = Merkle data, chained+resigned, proof_size=0
    const v3 = parseVariantByte(0xB0);
    try std.testing.expect(v3.is_data);
    try std.testing.expect(v3.is_merkle);
    try std.testing.expectEqual(@as(u8, 0), v3.proof_size);
}

test "parseVariantByte - Merkle code variants" {
    // 0x4C = Merkle code, unchained, proof_size=12
    const v1 = parseVariantByte(0x4C);
    try std.testing.expect(!v1.is_data);
    try std.testing.expect(v1.is_merkle);
    try std.testing.expectEqual(@as(u8, 12), v1.proof_size);

    // 0x65 = Merkle code, chained, proof_size=5
    const v2 = parseVariantByte(0x65);
    try std.testing.expect(!v2.is_data);
    try std.testing.expect(v2.is_merkle);
    try std.testing.expectEqual(@as(u8, 5), v2.proof_size);

    // 0x70 = Merkle code, chained+resigned, proof_size=0
    const v3 = parseVariantByte(0x70);
    try std.testing.expect(!v3.is_data);
    try std.testing.expect(v3.is_merkle);
    try std.testing.expectEqual(@as(u8, 0), v3.proof_size);
}

test "parseVariantByte - legacy variants" {
    // 0xA5 = Legacy data
    const vd = parseVariantByte(0xA5);
    try std.testing.expect(vd.is_data);
    try std.testing.expect(!vd.is_merkle);

    // 0x5A = Legacy code
    const vc = parseVariantByte(0x5A);
    try std.testing.expect(!vc.is_data);
    try std.testing.expect(!vc.is_merkle);
}

test "parseVariantByte - Alpenglow V3" {
    // 0x58 = V3 Alpenglow
    const v = parseVariantByte(0x58);
    try std.testing.expect(!v.is_data);
    try std.testing.expect(v.is_merkle);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 3: FEC set completion detection
// ═══════════════════════════════════════════════════════════════════════

test "FEC set completes when all data shreds received" {
    const allocator = std.testing.allocator;
    var resolver = FecResolver.init(allocator, 100, 0);
    defer resolver.deinit();

    // Create a minimal 3-data 2-parity FEC set (no recovery needed)
    // First send all 3 data shreds
    var shred_buf: [3][200]u8 = undefined;
    for (0..3) |i| {
        @memset(&shred_buf[i], 0);
        // Set variant to Merkle data (0x86)
        shred_buf[i][64] = 0x86;
        std.mem.writeInt(u64, shred_buf[i][65..73], 100, .little); // slot
        std.mem.writeInt(u32, shred_buf[i][73..77], @as(u32, @intCast(i)), .little); // index
    }

    const r0 = try resolver.addShred(100, 0, 0, true, &shred_buf[0], 0, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.pending, r0);

    const r1 = try resolver.addShred(100, 1, 0, true, &shred_buf[1], 0, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.pending, r1);

    // Now send a parity shred that declares num_data=3, num_parity=2
    var parity_buf: [200]u8 = undefined;
    @memset(&parity_buf, 0);
    parity_buf[64] = 0x46; // Merkle code
    std.mem.writeInt(u64, parity_buf[65..73], 100, .little);

    const rp = try resolver.addShred(100, 3, 0, false, &parity_buf, 0, 3, 2, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.pending, rp);

    // Send the last data shred — should trigger completion
    const r2 = try resolver.addShred(100, 2, 0, true, &shred_buf[2], 0, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.complete, r2);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 4: Version mismatch rejection
// ═══════════════════════════════════════════════════════════════════════

test "version mismatch rejected" {
    const allocator = std.testing.allocator;
    // Resolver expects version 42
    var resolver = FecResolver.init(allocator, 100, 42);
    defer resolver.deinit();

    var buf: [200]u8 = undefined;
    @memset(&buf, 0);
    buf[64] = 0x86; // Merkle data
    std.mem.writeInt(u64, buf[65..73], 1, .little);

    // Send shred with version 99 — should be rejected
    const r = try resolver.addShred(1, 0, 0, true, &buf, 99, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.version_mismatch, r);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 5: Invalid shred size rejection
// ═══════════════════════════════════════════════════════════════════════

test "reject too-small shred" {
    const allocator = std.testing.allocator;
    var resolver = FecResolver.init(allocator, 100, 0);
    defer resolver.deinit();

    var tiny: [50]u8 = undefined;
    @memset(&tiny, 0);
    const r = try resolver.addShred(1, 0, 0, true, &tiny, 0, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.err, r);
}

test "reject too-large shred" {
    const allocator = std.testing.allocator;
    var resolver = FecResolver.init(allocator, 100, 0);
    defer resolver.deinit();

    const huge = try allocator.alloc(u8, 3000);
    defer allocator.free(huge);
    @memset(huge, 0);
    const r = try resolver.addShred(1, 0, 0, true, huge, 0, 0, 0, 0);
    try std.testing.expectEqual(fec.FecResolver.AddResult.err, r);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 6: Eviction when at capacity
// ═══════════════════════════════════════════════════════════════════════

test "eviction when at max_depth" {
    const allocator = std.testing.allocator;
    // max_depth = 2, so 3rd slot should evict the 1st
    var resolver = FecResolver.init(allocator, 2, 0);
    defer resolver.deinit();

    var buf: [200]u8 = undefined;
    @memset(&buf, 0);
    buf[64] = 0x86;

    // Fill slot 1 and 2
    std.mem.writeInt(u64, buf[65..73], 1, .little);
    _ = try resolver.addShred(1, 0, 0, true, &buf, 0, 0, 0, 0);

    std.mem.writeInt(u64, buf[65..73], 2, .little);
    _ = try resolver.addShred(2, 0, 0, true, &buf, 0, 0, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), resolver.active_sets.count());

    // Adding slot 3 should evict one
    std.mem.writeInt(u64, buf[65..73], 3, .little);
    _ = try resolver.addShred(3, 0, 0, true, &buf, 0, 0, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), resolver.active_sets.count());
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 7: FecSet.canRecover logic
// ═══════════════════════════════════════════════════════════════════════

test "FecSet.canRecover requires enough shreds" {
    const allocator = std.testing.allocator;
    var set = FecSet.init(allocator, 1, 0);
    defer set.deinit();

    // No data count yet → can't recover
    try std.testing.expect(!set.canRecover());

    // Set expected counts: 4 data, 2 parity
    var dummy: [200]u8 = undefined;
    @memset(&dummy, 0);
    try set.addParityShred(0, &dummy, 4, 2);
    // Now have 1 parity — need 4 total → can't recover
    try std.testing.expect(!set.canRecover());

    // Add 3 data shreds → still need 4, have 4 total → CAN recover
    try set.addDataShred(0, &dummy);
    try set.addDataShred(1, &dummy);
    try set.addDataShred(2, &dummy);
    try std.testing.expect(set.canRecover());
}
