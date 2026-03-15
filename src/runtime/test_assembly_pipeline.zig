const std = @import("std");
const shred_mod = @import("shred.zig");
const fec_mod = @import("fec_resolver.zig");
const Shred = shred_mod.Shred;
const ShredAssembler = shred_mod.ShredAssembler;

// ═══════════════════════════════════════════════════════════════════════
// HELPERS: Build synthetic shred payloads
// ═══════════════════════════════════════════════════════════════════════

fn buildDataShred(
    slot: u64,
    index: u32,
    version: u16,
    fec_set_index: u32,
    parent_offset: u16,
    is_last: bool,
    entry_data: []const u8,
) []u8 {
    const total_size = 88 + entry_data.len;
    const buf = std.testing.allocator.alloc(u8, total_size) catch unreachable;
    @memset(buf, 0);

    // Variant: Merkle data, unchained, proof_size=6 → 0x86
    buf[64] = 0x86;
    std.mem.writeInt(u64, buf[65..73], slot, .little);
    std.mem.writeInt(u32, buf[73..77], index, .little);
    std.mem.writeInt(u16, buf[77..79], version, .little);
    std.mem.writeInt(u32, buf[79..83], fec_set_index, .little);
    std.mem.writeInt(u16, buf[83..85], parent_offset, .little);
    buf[85] = if (is_last) 0xC0 else 0x00;
    const size_val: u16 = @intCast(total_size);
    std.mem.writeInt(u16, buf[86..88], size_val, .little);
    if (entry_data.len > 0) {
        @memcpy(buf[88..], entry_data);
    }
    return buf;
}

fn freeShredBuf(buf: []u8) void {
    std.testing.allocator.free(buf);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 1: End-to-end — insert shreds, assemble, verify block bytes
// ═══════════════════════════════════════════════════════════════════════

test "end-to-end assembly pipeline - complete slot produces correct block" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Simulate a block with 5 data shreds containing an entry stream
    const entries = [_][]const u8{
        "entry_0_tx_data_aaa",
        "entry_1_tx_data_bbb",
        "entry_2_tx_data_ccc",
        "entry_3_tx_data_ddd",
        "entry_4_tx_data_eee",
    };

    // Build and insert all shreds (last one marked as slot-final)
    var shred_bufs: [5][]u8 = undefined;
    for (0..5) |i| {
        const is_last = (i == 4);
        shred_bufs[i] = buildDataShred(
            200, // slot
            @intCast(i), // index
            100, // version
            0, // fec_set_index
            1, // parent_offset
            is_last,
            entries[i],
        );
    }
    defer for (&shred_bufs) |buf| freeShredBuf(buf);

    for (0..5) |i| {
        const result = try assembler.insert(try Shred.fromPayload(shred_bufs[i]));
        if (i == 4) {
            try std.testing.expectEqual(ShredAssembler.InsertResult.completed_slot, result);
        } else {
            try std.testing.expectEqual(ShredAssembler.InsertResult.inserted, result);
        }
    }

    // Assemble and verify
    const block = try assembler.assembleSlot(200);
    try std.testing.expect(block != null);

    const expected = "entry_0_tx_data_aaa" ++
        "entry_1_tx_data_bbb" ++
        "entry_2_tx_data_ccc" ++
        "entry_3_tx_data_ddd" ++
        "entry_4_tx_data_eee";
    try std.testing.expectEqualSlices(u8, expected, block.?);
    allocator.free(block.?);

    // Verify highest completed slot tracking
    try std.testing.expectEqual(@as(u64, 200), assembler.getHighestCompletedSlot().?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 2: Multiple slots in flight concurrently
// ═══════════════════════════════════════════════════════════════════════

test "multiple concurrent slots" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Interleave shreds from slots 100 and 101
    const s100_0 = buildDataShred(100, 0, 1, 0, 1, false, "A100");
    defer freeShredBuf(s100_0);
    const s101_0 = buildDataShred(101, 0, 1, 0, 1, false, "A101");
    defer freeShredBuf(s101_0);
    const s100_1 = buildDataShred(100, 1, 1, 0, 1, true, "B100");
    defer freeShredBuf(s100_1);
    const s101_1 = buildDataShred(101, 1, 1, 0, 1, true, "B101");
    defer freeShredBuf(s101_1);

    _ = try assembler.insert(try Shred.fromPayload(s100_0));
    _ = try assembler.insert(try Shred.fromPayload(s101_0));
    _ = try assembler.insert(try Shred.fromPayload(s100_1));
    _ = try assembler.insert(try Shred.fromPayload(s101_1));

    const block_100 = try assembler.assembleSlot(100);
    try std.testing.expect(block_100 != null);
    try std.testing.expectEqualSlices(u8, "A100B100", block_100.?);
    allocator.free(block_100.?);

    const block_101 = try assembler.assembleSlot(101);
    try std.testing.expect(block_101 != null);
    try std.testing.expectEqualSlices(u8, "A101B101", block_101.?);
    allocator.free(block_101.?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 3: Assembly with empty data shreds (tick-only)
// ═══════════════════════════════════════════════════════════════════════

test "assembly skips empty data shreds" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Shred 0: has data
    const s0 = buildDataShred(300, 0, 1, 0, 1, false, "real_data");
    defer freeShredBuf(s0);

    // Shred 1: empty (size field = 88, meaning 0 bytes of entry data)
    const s1 = buildDataShred(300, 1, 1, 0, 1, false, "");
    defer freeShredBuf(s1);
    // Force size field to exactly 88 (header only, no data)
    std.mem.writeInt(u16, s1[86..88], 88, .little);

    // Shred 2: has data, last
    const s2 = buildDataShred(300, 2, 1, 0, 1, true, "more_data");
    defer freeShredBuf(s2);

    _ = try assembler.insert(try Shred.fromPayload(s0));
    _ = try assembler.insert(try Shred.fromPayload(s1));
    _ = try assembler.insert(try Shred.fromPayload(s2));

    const block = try assembler.assembleSlot(300);
    try std.testing.expect(block != null);
    // Empty shred should be skipped
    try std.testing.expectEqualSlices(u8, "real_datamore_data", block.?);
    allocator.free(block.?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 4: Slot cleanup after assembly
// ═══════════════════════════════════════════════════════════════════════

test "clearCompletedSlot frees memory" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    const s0 = buildDataShred(400, 0, 1, 0, 1, true, "cleanup_test");
    defer freeShredBuf(s0);
    _ = try assembler.insert(try Shred.fromPayload(s0));

    // Should be assembled before clear
    const block = try assembler.assembleSlot(400);
    try std.testing.expect(block != null);
    allocator.free(block.?);

    // Clear it
    assembler.clearCompletedSlot(400);

    // Should be gone
    const after = try assembler.assembleSlot(400);
    try std.testing.expect(after == null);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 5: Malformed size field does NOT cause out-of-bounds read
// (This exercises the SIGSEGV code path from Issue 5)
// ═══════════════════════════════════════════════════════════════════════

test "malformed size field does not crash assembly" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Build a shred with a size field larger than the actual payload
    const s0 = buildDataShred(500, 0, 1, 0, 1, true, "short");
    defer freeShredBuf(s0);

    // Corrupt the size field: claim 500 bytes but payload is only 93
    std.mem.writeInt(u16, s0[86..88], 500, .little);

    _ = try assembler.insert(try Shred.fromPayload(s0));

    // Assembly should handle this gracefully (not crash)
    // Current behavior: may read past buffer or produce wrong output.
    // After fixing Issue 5, this should produce null or truncated output.
    const block = assembler.assembleSlot(500) catch null;
    // We mainly care that it doesn't crash
    if (block) |b| allocator.free(b);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 6: Parent slot derivation
// ═══════════════════════════════════════════════════════════════════════

test "getParentSlot derives correctly from parent_offset" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Slot=100, parent_offset=3 → parent=97
    const s = buildDataShred(100, 0, 1, 0, 3, true, "x");
    defer freeShredBuf(s);
    _ = try assembler.insert(try Shred.fromPayload(s));

    const parent = assembler.getParentSlot(100);
    try std.testing.expectEqual(@as(u64, 97), parent.?);
}
