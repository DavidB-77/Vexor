# Vexor Gossip Protocol Status

## Current State: ✅ WORKING (Dec 15, 2024)

### Status Update

**FIXED:** Peer connection issue resolved! Vexor is now successfully connecting to gossip peers.

**Current Status:**
```
║  Gossip: peers=978  values_rcvd=7292     pulls=198    ║
```

**What Was Fixed:**
- **Compact_U16 Encoding**: Changed from regular varint to Solana's compact_u16 format for ContactInfo parsing
- **Address/Socket/Port Parsing**: Fixed parsing of address count, socket count, and port offsets in modern ContactInfo
- **Shred Parsing**: Added error handling to prevent crashes on invalid shred types

**Files Modified:**
- `src/network/gossip.zig` - Fixed `parseModernContactInfo()` 
- `src/runtime/shred.zig` - Added error handling

**Reference:** See `docs/COMPACT_U16_FIX_DEC15.md` for full details.

---

## Previous State (Before Fix): Not Solana-Compatible ⚠️

### Problem (RESOLVED)

Our gossip implementation was using regular varint encoding instead of Solana's compact_u16 format for ContactInfo parsing. This caused:

1. **Parsing Mismatch**: Incorrect byte reading for address count, socket count, and port offsets
2. **ContactInfo Extraction Failure**: Could not extract gossip socket addresses from PUSH messages
3. **Peer Table Empty**: No peers added despite receiving PUSH messages

### Evidence (Before Fix)

```
║  Gossip: peers=0    values_rcvd=0        pulls=0      ║
```

Despite sending pull requests to entrypoints and receiving PUSH messages, peers were not being added because ContactInfo parsing was failing.

---

## What Solana Gossip Actually Does

### Message Types (from Solana source)
```rust
pub enum Protocol {
    PullRequest(CrdsFilter, CrdsValue),  // Request new values
    PullResponse(Pubkey, Vec<CrdsValue>), // Response with values
    PushMessage(Pubkey, Vec<CrdsValue>),  // Push new values
    PruneMessage(Pubkey, PruneData),      // Prune stale values
    PingMessage(Ping),                     // Health check
    PongMessage(Pong),                     // Health response
}
```

### CRDS Value Format
```rust
pub struct CrdsValue {
    pub signature: Signature,
    pub data: CrdsData,
}

pub enum CrdsData {
    LegacyContactInfo(LegacyContactInfo),
    Vote(VoteIndex, Vote),
    LowestSlot(/*...*/),
    SnapshotHashes(/*...*/),
    AccountsHashes(/*...*/),
    EpochSlots(/*...*/),
    LegacyVersion(/*...*/),
    Version(/*...*/),
    NodeInstance(/*...*/),
    DuplicateShred(/*...*/),
    IncrementalSnapshotHashes(/*...*/),
    ContactInfo(ContactInfo), // New format
    RestartLastVotedForkSlots(/*...*/),
    RestartHeaviestFork(/*...*/),
}
```

---

## Solutions

### Option 1: Implement Full Solana Gossip (Recommended for Production)

**Effort**: 2-3 weeks  
**Pros**: Full compatibility, voting, block production  
**Cons**: Significant work

Required:
1. Implement bincode serialization in Zig
2. Implement CRDS data structures
3. Implement bloom filters for pull requests
4. Implement proper signature generation/verification
5. Match message ID hashing (SHA-256)

### Option 2: RPC-Based Cluster Discovery (Quick Workaround)

**Effort**: 2-3 days  
**Pros**: Can receive shreds without gossip  
**Cons**: Cannot vote, cannot be discovered by others

Steps:
1. Call `getClusterNodes` RPC to get peer TVU addresses
2. Request shreds directly via Turbine protocol
3. Update peer list periodically via RPC

### Option 3: Integrate Agave Gossip (IPC Bridge)

**Effort**: 1-2 weeks  
**Pros**: Reuses working gossip implementation  
**Cons**: Requires running Agave, complexity

Steps:
1. Run minimal Agave gossip node
2. Create IPC bridge to receive ContactInfo
3. Use Agave's peer list for TVU connections

---

## Recommended Path Forward

### Phase 1: Quick Catch-Up (RPC Workaround)
Get Vexor receiving shreds and syncing slots via RPC-based peer discovery.

### Phase 2: Full Gossip Implementation
Implement proper bincode serialization and CRDS format for production use.

### Phase 3: Voting & Block Production
Enable voting after gossip is working and node is caught up.

---

## Testnet Cluster Info (via RPC)

Example nodes from `getClusterNodes`:
- TVU: 192.155.103.41:8002 (shred version 9604)
- TVU: 104.250.133.50:8000 (shred version 9604)
- Shred Version: 9604 (testnet)

These could be used for direct shred subscription without gossip.

---

## Files to Modify for Full Gossip

| File | Changes Needed |
|------|----------------|
| `src/network/gossip.zig` | Complete rewrite of message format |
| `src/core/bincode.zig` | NEW: Bincode serialization |
| `src/network/crds.zig` | NEW: CRDS data structures |
| `src/network/bloom.zig` | NEW: Bloom filter implementation |
| `src/crypto/signature.zig` | Signature over CRDS values |

---

## Current Test Status

- ✅ Public IP advertising configured
- ✅ AF_XDP acceleration enabled  
- ✅ Bootstrap and snapshot loading working
- ✅ Main loop running stably
- ✅ Repair requests being sent (every 5 seconds)
- ❌ Gossip peer discovery (protocol mismatch - needs bincode)
- ❌ Repair responses received (protocol mismatch - needs bincode)
- ❌ TVU shred reception (no peers responding)
- ❌ Slot sync to network
- ❌ Voting

## The Bincode Problem

Both gossip and repair protocols require **bincode serialization** to communicate with
Solana nodes. Our current implementations use simplified custom formats that the network
doesn't recognize.

### What Bincode Is
Bincode is a compact binary serialization format used by Rust's serde ecosystem.
Solana uses it for all inter-node communication:
- Gossip messages (CRDS values, pull/push)
- Repair requests/responses
- Transaction forwarding

### Bincode Features Needed
1. **Variable-length integers** (VarInt encoding)
2. **Enum tags** (u32 for variant index)
3. **Sequence encoding** (length-prefixed arrays)
4. **Struct field ordering** (by declaration order)
5. **Signature encoding** (64 bytes)

### Implementation Estimate
- **Bincode codec in Zig**: 3-5 days
- **CRDS data structures**: 3-5 days
- **Gossip message types**: 2-3 days
- **Repair message types**: 2-3 days
- **Testing and debugging**: 3-5 days
- **Total**: ~2-3 weeks for full protocol compatibility

## Workaround: Use Agave as Gossip Proxy

A faster path to get Vexor syncing:
1. Run Agave in minimal mode (gossip only)
2. Create IPC bridge to get peer info from Agave
3. Use Agave's gossip for peer discovery
4. Eventually replace with native Zig gossip

This allows Vexor to:
- Receive shreds via the established peer network
- Catch up with the network
- Focus bincode implementation as a parallel effort


