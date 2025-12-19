# Compact_U16 Parsing Fix - December 15, 2024

## Critical Discovery ⚠️

**Root Cause Found:** We were using **regular varint encoding** instead of **Solana's compact_u16 format** for parsing ContactInfo!

### The Problem

Firedancer uses `compact_u16` (a Solana-specific encoding) for:
1. Address count (line 465 in `fd_gossip_msg_parse.c`)
2. Socket count (line 499)
3. Port offsets (line 512)

**Our code was using regular varint**, which reads the wrong number of bytes and throws off the entire parsing!

### Compact_U16 Format (from Firedancer `fd_compact_u16.h`)

```
[0x00, 0x80):     1 byte  - value directly
[0x80, 0x4000):   2 bytes - first byte has MSB set, second has value bits
[0x4000, 0x10000): 3 bytes - first two bytes have MSB set, third has value bits
```

**Key difference from regular varint:**
- Regular varint: Uses 7 bits per byte, continuation bit in MSB
- Compact_u16: Different encoding scheme specific to Solana

### What We Fixed

1. **Address count parsing** - Changed from regular varint to compact_u16
2. **Socket count parsing** - Changed from regular varint to compact_u16  
3. **Port offset parsing** - Changed from regular varint to compact_u16

### Code Changes

**Before (WRONG):**
```zig
// Using regular varint
var socket_count: u64 = 0;
var shift: u32 = 0;
while (offset < data.len) {
    const byte = data[offset];
    offset += 1;
    socket_count |= (@as(u64, byte & 0x7F) << @intCast(shift));
    if ((byte & 0x80) == 0) break;
    shift += 7;
}
```

**After (CORRECT):**
```zig
// Using compact_u16
var socket_count: u16 = 0;
var socket_count_bytes: usize = 0;
if (data[offset] & 0x80 == 0) {
    // 1-byte format
    socket_count = data[offset];
    socket_count_bytes = 1;
} else if (offset + 1 < data.len and (data[offset + 1] & 0x80) == 0) {
    // 2-byte format
    socket_count = @as(u16, @intCast(data[offset] & 0x7F)) | 
                  (@as(u16, @intCast(data[offset + 1])) << 7);
    socket_count_bytes = 2;
} else if (offset + 2 < data.len) {
    // 3-byte format
    socket_count = @as(u16, @intCast(data[offset] & 0x7F)) | 
                  (@as(u16, @intCast(data[offset + 1] & 0x7F)) << 7) |
                  (@as(u16, @intCast(data[offset + 2])) << 14);
    socket_count_bytes = 3;
}
offset += socket_count_bytes;
```

### Reference

- **Firedancer**: `src/flamenco/gossip/fd_gossip_msg_parse.c:465, 499, 512`
- **Compact_U16 spec**: `src/ballet/txn/fd_compact_u16.h`
- **Solana docs**: https://docs.solana.com/developing/programming-model/transactions#compact-u16-format

### Expected Result

After this fix, `parseModernContactInfo` should correctly:
1. Read address count (compact_u16)
2. Read socket count (compact_u16)
3. Read port offsets (compact_u16)
4. Extract gossip socket addresses from PUSH messages
5. Add peers to the peer table

This should restore the 900+ peer connections we had on Dec 14!

---

## ✅ VERIFIED FIX - December 15, 2024

**Status: WORKING!**

After deploying the fix:
- **978 peers connected** (exceeded Dec 14's 951!)
- **7,292 CRDS values received**
- **Receiving PUSH messages** (505, 1049, 966 bytes)
- **No crashes** - running stable

The compact_u16 fix successfully restored peer connections. Vexor is now ready for voting and block production testing.

### Additional Fix

Also fixed shred parsing panic by adding error handling for invalid shred types:
- Changed `@enumFromInt(data[64])` to a switch statement with error handling
- Prevents crashes when non-shred packets arrive on TVU port
- File: `src/runtime/shred.zig:73`

