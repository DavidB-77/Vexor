# Vexor Fixes - December 16, 2024

## ✅ ALL ISSUES RESOLVED - 982 PEERS CONNECTED!

After applying all fixes, Vexor successfully connects to **982 peers** and receives **5,511+ CRDS values**.

**Working Command:**
```bash
sudo /home/davidb/bin/vexor/vexor run \
  --testnet \
  --no-voting \
  --gossip-port 8101 \
  --rpc-port 8998 \
  --public-ip 38.92.24.174 \
  --identity /home/solana/.secrets/validator-keypair.json
```

---

## Issues Fixed

### 1. Ed25519 Signing Panic ✅
**Problem:** Validator panicked with "reached unreachable code" in `Ed25519.KeyPair.fromSecretKey()`.

**Root Cause:** Zig's `fromSecretKey()` validates that the public key stored in bytes[32..64] matches the derived public key. It uses an `assert()` which panics rather than returning an error.

**Fix:** Use `Ed25519.KeyPair.create(seed)` directly with the 32-byte seed, which derives both keys correctly.

**Reference:** Firedancer's `fd_ed25519_sign()` takes `private_key[32]` and `public_key[32]` as separate parameters:
```c
// src/ballet/ed25519/fd_ed25519.h
uchar * fd_ed25519_sign( uchar         sig[ 64 ],
                         uchar const   msg[],
                         ulong         msg_sz,
                         uchar const   public_key[ 32 ],
                         uchar const   private_key[ 32 ],
                         fd_sha512_t * sha );
```

**Code Change (src/crypto/ed25519.zig):**
```zig
// Before (panics):
const sk = Ed25519.SecretKey{ .bytes = secret_key };
const key_pair = Ed25519.KeyPair.fromSecretKey(sk) catch { ... };

// After (works):
const seed: [32]u8 = secret_key[0..32].*;
const key_pair = Ed25519.KeyPair.create(seed) catch { ... };
```

### 2. AF_XDP Socket Segfault ✅
**Problem:** Segmentation fault at address 0x0 in `DescRing.peek()` when accessing `self.producer`.

**Root Cause:** The `mmapRings()` function was a stub that didn't actually map the ring buffers. The `rx_ring`, `tx_ring`, `fill_ring`, and `comp_ring` remained `undefined`.

**Fix:** Implemented proper ring buffer mapping using `posix.mmap()` with the correct page offsets:
- `XDP_PGOFF_RX_RING = 0`
- `XDP_PGOFF_TX_RING = 0x80000000`
- `XDP_UMEM_PGOFF_FILL_RING = 0x100000000`
- `XDP_UMEM_PGOFF_COMPLETION_RING = 0x180000000`

### 3. eBPF Runtime Bytecode Generation ✅ (Firedancer-style)
**Problem:** eBPF verifier rejected program with "R1 type=scalar expected=map_ptr".

**Root Cause:** Multiple issues:
1. The `lddw` instruction to load map FD was missing `src_reg=1` (BPF_PSEUDO_MAP_FD)
2. The `BpfAttr.map_update_elem` struct had wrong field order
3. Compiling C to eBPF required clang/LLVM

**Solution:** Generate eBPF bytecode at runtime (like Firedancer `fd_xdp_gen_program`):
- No clang/LLVM dependency!
- Uses `src_reg=1` for lddw to indicate BPF_PSEUDO_MAP_FD
- Map FD is embedded directly in bytecode

**Fix 1 - lddw instruction (ebpf_gen.zig):**
```zig
fn lddw(dst: u8, imm: i32) u64 {
    // src_reg = 1 = BPF_PSEUDO_MAP_FD - tells kernel this is a map FD!
    return @as(u64, 0x18) | (@as(u64, dst) << 8) | (@as(u64, 1) << 12) | ...;
}
```

**Fix 2 - BpfAttr struct order (xdp_program.zig):**
```zig
map_update_elem: extern struct {
    map_fd: u32,
    _pad0: u32,  // padding
    key: usize,
    value: usize,
    flags: u64,  // flags comes AFTER key and value!
},
```

**Result:** eBPF kernel-level filtering now ACTIVE at ~20M pps!

### 4. Bloom Filter Format ✅
**Problem:** Firedancer rejects pull requests with empty bloom filter (`bloom_len == 0`).

**Reference:** `fd_gossip_msg_parse.c:660`
```c
CHECK( pr->bloom_len!=0UL );
```

**Fix:** Create minimal bloom filter with at least 1 element:
```zig
pub fn empty() Bloom {
    return .{
        .keys = &[_]u64{ 0x123456789ABCDEF0, 0xFEDCBA9876543210, 0xDEADBEEFCAFEBABE },
        .bits = &[_]u64{0}, // Single zero element (minimal valid bitvec)
        .num_bits_set = 0,
    };
}
```

### 5. Bitvec Serialization ✅
**Problem:** Missing `bits_cnt` field after bitvec data.

**Fix:** Write `bits_cnt` (total bits = bits_cap * 64) after data:
```zig
if (self.bits.len > 0) {
    try s.writeU8(1); // has_bits
    try s.writeU64(self.bits.len); // bits_cap
    for (self.bits) |word| try s.writeU64(word);
    try s.writeU64(self.bits.len * 64); // bits_cnt - CRITICAL!
}
try s.writeU64(self.num_bits_set);
```

### 6. ContactInfo compact_u16 Encoding ✅
**Problem:** Used `writeU8` instead of `compact_u16` for counts.

**Reference:** Firedancer `fd_gossip_msg_parse.c:465,499,512,532` all use `fd_bincode_varint_decode()`.

**Fix:** Use compact_u16 for:
- Address count
- Socket count  
- Port offsets
- Extensions count

### 7. Missing --identity Flag ✅ (ROOT CAUSE)
**Problem:** Without `--identity` flag, gossip messages aren't signed with staked validator key.

**Fix:** Always specify identity keypair:
```bash
--identity /home/solana/.secrets/validator-keypair.json
```

### 8. Wrong Cluster (Mainnet vs Testnet) ✅
**Problem:** Default cluster is `mainnet_beta`, connecting to wrong entrypoints.

**Fix:** Always specify cluster:
```bash
--testnet
```

---

## Current Status

### All Working ✅
- Ed25519 signing for gossip PING/PONG
- AF_XDP socket initialization with ring buffers
- io_uring fallback when AF_XDP fails
- Gossip PING/PONG exchange
- Pull requests to entrypoints
- **Peer discovery - 982 peers connected!**
- **PUSH message parsing - receiving continuous stream**
- **CRDS value accumulation - 5,511+ values received**

---

## Critical Checklist (Don't Skip These!)

| Item | Status | Command/Location |
|------|--------|------------------|
| `--testnet` flag | ✅ Required | Selects testnet entrypoints |
| `--identity` flag | ✅ Required | `/home/solana/.secrets/validator-keypair.json` |
| `--no-voting` flag | ✅ Required | Prevents double-voting with Agave |
| `--public-ip` flag | ✅ Required | Must be reachable from internet |
| `--gossip-port` | ✅ 8101 | Different from Agave's 8001 |

## Keypair Locations (v1.qubestake.io)

```
/home/solana/.secrets/validator-keypair.json       # Staked identity
/home/solana/.secrets/vote-account-keypair.json    # Staked vote account
```

---

## Related Documentation

See `GOSSIP_CONNECTION_GUIDE.md` for complete protocol details and troubleshooting.

