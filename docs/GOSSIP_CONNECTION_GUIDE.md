# Vexor Gossip Connection Guide

**Last Updated:** December 16, 2024  
**Status:** ✅ WORKING - 982 peers connected

---

## ⚠️ CRITICAL: Required Flags for Peer Connections

### Working Command (Testnet)

```bash
sudo /home/davidb/bin/vexor/vexor run \
  --testnet \
  --no-voting \
  --gossip-port 8101 \
  --rpc-port 8998 \
  --public-ip 38.92.24.174 \
  --identity /home/solana/.secrets/validator-keypair.json
```

### Required Flags Explained

| Flag | Purpose | Why It's Critical |
|------|---------|-------------------|
| `--testnet` | Select testnet cluster | Without this, defaults to mainnet which has different entrypoints |
| `--identity <path>` | Path to validator keypair | **CRITICAL!** Without this, messages aren't signed properly and peers reject them |
| `--public-ip <ip>` | Your validator's public IP | Required for ContactInfo so peers can reach you |
| `--gossip-port <port>` | Gossip UDP port | Use alternate port (8101) when running alongside Agave (8001) |
| `--no-voting` | Disable voting | **REQUIRED** when running alongside Agave to prevent double-voting |

### Keypair Locations (v1.qubestake.io)

```
/home/solana/.secrets/validator-keypair.json      # Identity (staked)
/home/solana/.secrets/vote-account-keypair.json   # Vote account (staked)
```

These are symlinks to:
```
/home/solana/.secrets/testnet/qubetest/validator-keypair.json
/home/solana/.secrets/testnet/qubetest/vote-account-keypair.json
```

---

## Fixes Applied (December 16, 2024)

### 1. Ed25519 Signing Panic ✅

**Problem:** `KeyPair.fromSecretKey()` panics when public key doesn't match derived key.

**Solution:** Use `KeyPair.create(seed)` with 32-byte seed from Solana's 64-byte secret key format.

```zig
// Before (panics):
const sk = Ed25519.SecretKey{ .bytes = secret_key };
const key_pair = Ed25519.KeyPair.fromSecretKey(sk);

// After (works):
const seed: [32]u8 = secret_key[0..32].*;
const key_pair = Ed25519.KeyPair.create(seed);
```

**File:** `src/crypto/ed25519.zig`

### 2. Bloom Filter Format ✅

**Problem:** Firedancer requires `bloom_len > 0` (fd_gossip_msg_parse.c:660).

**Solution:** Create minimal bloom filter with at least 1 u64 element.

```zig
pub fn empty() Bloom {
    return .{
        .keys = &[_]u64{ 0x123456789ABCDEF0, 0xFEDCBA9876543210, 0xDEADBEEFCAFEBABE },
        .bits = &[_]u64{0}, // Single zero element (minimal valid bitvec)
        .num_bits_set = 0,
    };
}
```

**File:** `src/network/bincode.zig`

### 3. Bitvec Serialization ✅

**Problem:** Missing `bits_cnt` field in bitvec serialization.

**Solution:** Write `bits_cnt` (total bits = bits_cap * 64) after bitvec data.

```zig
// Bitvec format:
// [has_bits(1)] + [bits_cap(8)] + [data] + [bits_cnt(8)]
if (self.bits.len > 0) {
    try s.writeU8(1); // has_bits
    try s.writeU64(self.bits.len); // bits_cap
    for (self.bits) |word| try s.writeU64(word);
    try s.writeU64(self.bits.len * 64); // bits_cnt
}
// Then write num_bits_set after bitvec
try s.writeU64(self.num_bits_set);
```

**File:** `src/network/bincode.zig`

### 4. ContactInfo Encoding ✅

**Problem:** Used `writeU8` instead of `compact_u16` for counts in ContactInfo.

**Solution:** Use `compact_u16` format (Firedancer fd_gossip_msg_parse.c:465,499,512,532).

```zig
// Changed from writeU8 to writeCompactU16 for:
// - Address count (line 718)
// - Socket count (line 731)
// - Port offsets (line 740)
// - Extensions count (line 745)
```

**File:** `src/network/bincode.zig`

### 5. Cluster Selection ✅

**Problem:** Default cluster is mainnet, not testnet.

**Solution:** Always specify `--testnet` for testnet.

---

## Protocol Details (Reference)

### PING/PONG Signatures

- **PING:** Sign only the 32-byte token with Ed25519 (raw)
- **PONG:** Use SHA256_ED25519 mode - SHA256("SOLANA_PING_PONG" + token), then Ed25519 sign

### CrdsValue Signatures

- Sign: `[enum_tag(4)] + [serialized_data]`
- Sign type: Raw Ed25519 (FD_KEYGUARD_SIGN_TYPE_ED25519)

### Modern ContactInfo Format (Tag 11)

Required by Firedancer (fd_gossvf_tile.c:786 rejects LegacyContactInfo!)

Format:
1. Pubkey (32 bytes)
2. Wallclock (varint, milliseconds)
3. Instance creation wallclock (u64, microseconds)
4. Shred version (u16)
5. Version (major/minor/patch as varint, commit/feature_set as u32, client as varint)
6. Addresses (compact_u16 count + IPv4 entries)
7. Sockets (compact_u16 count + [tag, addr_index, port_offset as compact_u16])
8. Extensions (compact_u16 count, typically 0)

### Wallclock Freshness

Firedancer rejects messages with wallclock > 15 seconds old. Always update before sending.

---

## Troubleshooting

### peers=0 despite sending pulls

1. **Check `--identity` flag** - Must point to valid keypair
2. **Check `--testnet` flag** - Without it, connects to wrong cluster
3. **Check keypair permissions** - Must be readable by running user
4. **Check firewall** - UDP port must be open

### Not receiving PUSH messages

1. **Check public IP** - Must be reachable from internet
2. **Check ContactInfo format** - Must use modern format (tag 11)
3. **Check wallclock** - Must be fresh (< 15 seconds)

### Signature verification failures

1. **PING** - Sign only token (32 bytes)
2. **PONG** - Sign SHA256("SOLANA_PING_PONG" + token)
3. **CrdsValue** - Sign enum_tag + data (raw Ed25519)

---

## Expected Results

With all fixes applied:
- **Peers:** 980+ connected
- **CRDS Values:** 5,000+ received
- **PUSH Messages:** Continuous stream from network
- **PING/PONG:** Working handshakes

---

## Files Modified

| File | Changes |
|------|---------|
| `src/crypto/ed25519.zig` | Fixed KeyPair.create() usage |
| `src/network/bincode.zig` | Fixed bloom filter, bitvec, compact_u16 |
| `src/network/gossip.zig` | Already had compact_u16 parsing (Dec 15) |

---

## Related Documentation

- `COMPACT_U16_FIX_DEC15.md` - Original compact_u16 parsing fix
- `PEER-CONNECTION-ISSUE-DEC15.md` - Initial peer connection debugging
- `TESTING_PROGRESS_DEC14.md` - Dec 14 testing with 951 peers

