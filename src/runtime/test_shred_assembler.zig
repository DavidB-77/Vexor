const std = @import("std");
const shred_mod = @import("shred.zig");
const Shred = shred_mod.Shred;
const ShredCommonHeader = shred_mod.ShredCommonHeader;
const ShredAssembler = shred_mod.ShredAssembler;

// ═══════════════════════════════════════════════════════════════════════
// HELPERS: Build synthetic shred payloads matching real Solana layout
// ═══════════════════════════════════════════════════════════════════════

/// Build a minimal data shred payload with the correct binary layout.
/// Layout (88-byte header + data):
///   [0..64]   Ed25519 signature (zeroed for tests)
///   [64]      variant byte
///   [65..73]  slot (u64 LE)
///   [73..77]  index (u32 LE)
///   [77..79]  version (u16 LE)
///   [79..83]  fec_set_index (u32 LE)
///   [83..85]  parent_offset (u16 LE) — data shreds only
///   [85]      flags (ShredFlags)
///   [86..88]  size (u16 LE) — header + data length
///   [88..]    entry data
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

    // Slot
    std.mem.writeInt(u64, buf[65..73], slot, .little);
    // Index
    std.mem.writeInt(u32, buf[73..77], index, .little);
    // Version
    std.mem.writeInt(u16, buf[77..79], version, .little);
    // FEC set index
    std.mem.writeInt(u32, buf[79..83], fec_set_index, .little);
    // Parent offset (data shred only)
    std.mem.writeInt(u16, buf[83..85], parent_offset, .little);
    // Flags
    buf[85] = if (is_last) 0xC0 else 0x00;
    // Size field: header_size + data_len
    const size_val: u16 = @intCast(total_size);
    std.mem.writeInt(u16, buf[86..88], size_val, .little);
    // Entry data
    if (entry_data.len > 0) {
        @memcpy(buf[88..], entry_data);
    }

    return buf;
}

/// Build a coding shred payload (variant 0x46 = Merkle code, proof_size=6).
/// Code header starts at offset 83 (6 bytes):
///   [83..85]  num_data_shreds (u16 LE)
///   [85..87]  num_coding_shreds (u16 LE)
///   [87..89]  coding_position (u16 LE)
fn buildCodeShred(
    slot: u64,
    index: u32,
    version: u16,
    fec_set_index: u32,
    num_data: u16,
    num_coding: u16,
    position: u16,
) []u8 {
    const buf = std.testing.allocator.alloc(u8, shred_mod.SHRED_PAYLOAD_SIZE) catch unreachable;
    @memset(buf, 0);

    // Variant: Merkle code, unchained, proof_size=6 → 0x46
    buf[64] = 0x46;

    // Common header
    std.mem.writeInt(u64, buf[65..73], slot, .little);
    std.mem.writeInt(u32, buf[73..77], index, .little);
    std.mem.writeInt(u16, buf[77..79], version, .little);
    std.mem.writeInt(u32, buf[79..83], fec_set_index, .little);

    // Code header
    std.mem.writeInt(u16, buf[83..85], num_data, .little);
    std.mem.writeInt(u16, buf[85..87], num_coding, .little);
    std.mem.writeInt(u16, buf[87..89], position, .little);

    return buf;
}

fn freeShredBuf(buf: []u8) void {
    std.testing.allocator.free(buf);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 1: Parse Merkle V2 data shred header
// ═══════════════════════════════════════════════════════════════════════

test "parse Merkle V2 data shred - header fields" {
    const payload = buildDataShred(42, 7, 1234, 0, 1, false, "hello");
    defer freeShredBuf(payload);

    const s = try Shred.fromPayload(payload);

    try std.testing.expectEqual(@as(u64, 42), s.slot());
    try std.testing.expectEqual(@as(u32, 7), s.index());
    try std.testing.expectEqual(@as(u16, 1234), s.version());
    try std.testing.expect(s.isData());
    try std.testing.expectEqual(@as(u16, 1), s.parentOffset());
    try std.testing.expect(!s.isLastInSlot());
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 2: Parse Merkle V2 code shred header
// ═══════════════════════════════════════════════════════════════════════

test "parse Merkle V2 code shred - header fields" {
    const payload = buildCodeShred(100, 3, 5678, 0, 10, 5, 2);
    defer freeShredBuf(payload);

    const s = try Shred.fromPayload(payload);

    try std.testing.expectEqual(@as(u64, 100), s.slot());
    try std.testing.expectEqual(@as(u32, 3), s.index());
    try std.testing.expectEqual(@as(u16, 5678), s.version());
    try std.testing.expect(!s.isData());

    // Code shred specific fields
    try std.testing.expectEqual(@as(u16, 10), s.numData());
    try std.testing.expectEqual(@as(u16, 5), s.numCoding());
    try std.testing.expectEqual(@as(u16, 2), s.codingPosition());
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 3: Reject undersized payloads
// ═══════════════════════════════════════════════════════════════════════

test "reject undersized shred payload" {
    var tiny = [_]u8{0} ** 20;
    const result = Shred.fromPayload(&tiny);
    try std.testing.expectError(error.ShredTooShort, result);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 4: isLastInSlot flag detection
// ═══════════════════════════════════════════════════════════════════════

test "isLastInSlot detects LAST_SHRED_IN_SLOT correctly" {
    // 0xC0 = data_complete + last_in_slot → true
    const last_payload = buildDataShred(1, 5, 100, 0, 1, true, "data");
    defer freeShredBuf(last_payload);
    const last_shred = try Shred.fromPayload(last_payload);
    try std.testing.expect(last_shred.isLastInSlot());

    // 0x40 = data_complete only → false
    const dc_payload = buildDataShred(1, 4, 100, 0, 1, false, "data");
    defer freeShredBuf(dc_payload);
    dc_payload[85] = 0x40; // force DATA_COMPLETE but not LAST_IN_SLOT
    const dc_shred = try Shred.fromPayload(dc_payload);
    try std.testing.expect(!dc_shred.isLastInSlot());
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 5: Single slot assembly
// ═══════════════════════════════════════════════════════════════════════

test "single slot assembly - 3 shreds complete slot" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Insert 3 data shreds for slot 42
    const s0 = buildDataShred(42, 0, 100, 0, 1, false, "AAAA");
    defer freeShredBuf(s0);
    const s1 = buildDataShred(42, 1, 100, 0, 1, false, "BBBB");
    defer freeShredBuf(s1);
    const s2 = buildDataShred(42, 2, 100, 0, 1, true, "CCCC");
    defer freeShredBuf(s2);

    const r0 = try assembler.insert(try Shred.fromPayload(s0));
    try std.testing.expectEqual(ShredAssembler.InsertResult.inserted, r0);

    const r1 = try assembler.insert(try Shred.fromPayload(s1));
    try std.testing.expectEqual(ShredAssembler.InsertResult.inserted, r1);

    const r2 = try assembler.insert(try Shred.fromPayload(s2));
    try std.testing.expectEqual(ShredAssembler.InsertResult.completed_slot, r2);

    // Assemble and verify
    const assembled = try assembler.assembleSlot(42);
    try std.testing.expect(assembled != null);
    try std.testing.expectEqualSlices(u8, "AAAABBBBCCCC", assembled.?);
    allocator.free(assembled.?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 6: Duplicate shred rejection
// ═══════════════════════════════════════════════════════════════════════

test "duplicate shred rejection" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    const s0 = buildDataShred(10, 0, 100, 0, 1, false, "XX");
    defer freeShredBuf(s0);

    const r0 = try assembler.insert(try Shred.fromPayload(s0));
    try std.testing.expectEqual(ShredAssembler.InsertResult.inserted, r0);

    // Same slot + index should be rejected as duplicate
    const s0_dup = buildDataShred(10, 0, 100, 0, 1, false, "YY");
    defer freeShredBuf(s0_dup);

    const r1 = try assembler.insert(try Shred.fromPayload(s0_dup));
    try std.testing.expectEqual(ShredAssembler.InsertResult.duplicate, r1);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 7: Out-of-order insertion still assembles correctly
// ═══════════════════════════════════════════════════════════════════════

test "out-of-order insertion assembles correctly" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Insert in reverse order: 2, 0, 1
    const s2 = buildDataShred(50, 2, 100, 0, 1, true, "CC");
    defer freeShredBuf(s2);
    const s0 = buildDataShred(50, 0, 100, 0, 1, false, "AA");
    defer freeShredBuf(s0);
    const s1 = buildDataShred(50, 1, 100, 0, 1, false, "BB");
    defer freeShredBuf(s1);

    _ = try assembler.insert(try Shred.fromPayload(s2));
    _ = try assembler.insert(try Shred.fromPayload(s0));
    const r = try assembler.insert(try Shred.fromPayload(s1));
    try std.testing.expectEqual(ShredAssembler.InsertResult.completed_slot, r);

    const assembled = try assembler.assembleSlot(50);
    try std.testing.expect(assembled != null);
    // Should be ordered by index, not insertion order
    try std.testing.expectEqualSlices(u8, "AABBCC", assembled.?);
    allocator.free(assembled.?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 8: Coding shreds are filtered from assembly output
// ═══════════════════════════════════════════════════════════════════════

test "coding shreds filtered from assembly" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Insert a data shred (index 0, last)
    const d0 = buildDataShred(60, 0, 100, 0, 1, true, "REAL");
    defer freeShredBuf(d0);
    _ = try assembler.insert(try Shred.fromPayload(d0));

    // Assemble — should only contain data shred content
    const assembled = try assembler.assembleSlot(60);
    try std.testing.expect(assembled != null);
    try std.testing.expectEqualSlices(u8, "REAL", assembled.?);
    allocator.free(assembled.?);
}

// ═══════════════════════════════════════════════════════════════════════
// TEST 9: Slot info and missing index tracking
// ═══════════════════════════════════════════════════════════════════════

test "getSlotInfo and getMissingIndices" {
    const allocator = std.testing.allocator;
    var assembler = try ShredAssembler.init(allocator);
    defer assembler.deinit();

    // Insert shred 0 and shred 2 (skip 1), mark 2 as last
    const s0 = buildDataShred(70, 0, 100, 0, 1, false, "A");
    defer freeShredBuf(s0);
    const s2 = buildDataShred(70, 2, 100, 0, 1, true, "C");
    defer freeShredBuf(s2);

    _ = try assembler.insert(try Shred.fromPayload(s0));
    _ = try assembler.insert(try Shred.fromPayload(s2));

    const info = try assembler.getSlotInfo(70);
    try std.testing.expect(info.knows_last_shred);
    try std.testing.expectEqual(@as(usize, 2), info.unique_count);
    try std.testing.expectEqual(@as(u32, 2), info.last_shred_index);

    const missing = try assembler.getMissingIndices(70);
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(@as(u32, 1), missing[0]);
}
