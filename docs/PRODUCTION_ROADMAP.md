# Vexor Production Roadmap

## Current Status ✅ IMPLEMENTATION COMPLETE

All components for **voting and block production** are now implemented!

### Completed Components

| Component | Status | File | Firedancer Reference |
|-----------|--------|------|---------------------|
| Gossip Protocol | ✅ Complete | `gossip.zig`, `bincode.zig` | `fd_gossip.c` |
| Bincode Serialization | ✅ Complete | `bincode.zig` | `fd_gossip_msg_ser.c` |
| ContactInfo (tag=11) | ✅ Complete | `bincode.zig` | `fd_gossip_crds.c` |
| TVU Shred Reception | ✅ Complete | `tvu.zig` | `fd_shred_tile.c` |
| Network Slot Sync | ✅ Complete | `root.zig` | - |
| CRDS Value Parsing | ✅ Complete | `gossip.zig` | `fd_gossip_crds.c` |
| **FEC Recovery** | ✅ **NEW** | `fec_resolver.zig` | `fd_fec_resolver.c` |
| **Merkle Tree** | ✅ **NEW** | `bmtree.zig` | `fd_bmtree.c` |
| **Shredder** | ✅ **NEW** | `shredder.zig` | `fd_shredder.h` |
| **TPU Client** | ✅ **NEW** | `tpu_client.zig` | `fd_quic_tile.c` |
| Tower Logic | ✅ Complete | `tower.zig` | `fd_tower.c` |
| Vote TX Building | ✅ Complete | `vote_tx.zig` | `fd_tower_tile.c` |
| Leader Schedule | ✅ Complete | `leader_schedule.zig` | `fd_leaders.c` |
| PoH Generator | ✅ Complete | `poh.zig` | `fd_poh_tile.c` |
| Block Producer | ✅ **UPDATED** | `block_producer.zig` | `fd_pack_tile.c` |
| Replay Stage | ✅ Complete | `replay_stage.zig` | `fd_replay_tile.c` |
| Bank Execution | ✅ Complete | `bank.zig` | `fd_runtime_execute.c` |

---

## Phase 1: Slot Completion (FEC Recovery) ✅ COMPLETE

### 1.1 FEC Resolver (Reed-Solomon) ✅
- **File**: `src/runtime/fec_resolver.zig`
- **Features**:
  - Galois Field GF(2^8) with log/exp tables
  - FEC set tracking by (slot, fec_set_idx) key
  - Single-erasure XOR recovery (fast path)
  - Data and parity shred management
  - Automatic set eviction when at capacity

### 1.2 Merkle Tree Verification ✅
- **File**: `src/runtime/bmtree.zig`
- **Features**:
  - Binary Merkle tree with SHA256
  - 0x00 prefix for leaves, 0x01 for branches
  - Inclusion proof generation and verification
  - ShredMerkleTree wrapper for FEC set signing

### 1.3 Shred FEC Integration ✅
- **File**: `src/runtime/shred.zig`
- **Changes**: ShredAssembler now includes FecResolver for automatic recovery

---

## Phase 2: Replay Stage Integration ✅ COMPLETE

### 2.1 Block Reconstruction ✅
- **File**: `src/runtime/replay_stage.zig`
- Entry parsing from shred data
- Transaction verification and execution
- Bank state updates

### 2.2 Entry Verification ✅
- **File**: `src/runtime/entry.zig`
- PoH hash verification
- Transaction count validation

### 2.3 Transaction Execution ✅
- **File**: `src/runtime/bank.zig`
- Native program execution (System, Vote, Stake)
- BPF program support
- Fee calculation and collection

---

## Phase 3: Tower/Consensus ✅ COMPLETE

### 3.1 Tower State Management ✅
- **File**: `src/consensus/tower.zig`
- Vote lockout tracking (31 levels)
- Fork choice with stake weighting
- Root slot management

### 3.2 Vote Transaction Building ✅
- **File**: `src/consensus/vote_tx.zig`
- `compact_update_vote_state` instruction (type 12)
- Proper sysvar account ordering
- Signature with identity keypair

### 3.3 Vote Submission ✅ **NEW**
- **File**: `src/network/tpu_client.zig`
- UDP transaction submission
- Leader TPU address caching via gossip
- Vote priority with multi-leader retry
- Pending transaction queue

---

## Phase 4: Block Production ✅ COMPLETE

### 4.1 Leader Schedule ✅
- **File**: `src/consensus/leader_schedule.zig`
- Stake-weighted leader selection
- Epoch schedule caching
- Leader slot detection

### 4.2 PoH Generator ✅
- **File**: `src/consensus/poh.zig`
- Configurable hashes per tick
- Tick recording with entry production
- Transaction mixin support

### 4.3 Block Packing ✅ **UPDATED**
- **File**: `src/runtime/block_producer.zig`
- Transaction batching
- Entry serialization
- Shredder integration for broadcast

### 4.4 Shred Production ✅ **NEW**
- **File**: `src/runtime/shredder.zig`
- Entry-to-shred conversion
- Reed-Solomon parity generation
- Merkle root signing
- BlockBuilder for incremental shredding

---

## Phase 5: Turbine Participation 🟡 FUTURE

### 5.1 Turbine Tree Construction
- Not yet implemented
- Needed for faster propagation
- Reference: `fd_shred_dest.c`

### 5.2 Shred Retransmission  
- Not yet implemented
- Would improve network performance

---

## Next Steps for Testing

### Build and Deploy
```bash
cd /home/dbdev/solana-client-research/vexor
zig build -Doptimize=ReleaseFast

# Copy to validator
scp zig-out/bin/vexor davidb@validator1:/home/solana/bin/vexor/
```

### Test Voting
1. Start Vexor with vote keypair configured
2. Wait for slot completion (FEC recovery)
3. Verify votes appear in gossip
4. Check on-chain vote account updates

### Test Block Production
1. Wait to be scheduled as leader
2. Verify entries are created
3. Verify shreds are broadcast
4. Check block appears on network

---

## File Summary

### New Files Created
| File | Lines | Purpose |
|------|-------|---------|
| `src/runtime/fec_resolver.zig` | ~450 | Reed-Solomon FEC recovery |
| `src/runtime/bmtree.zig` | ~300 | Merkle tree verification |
| `src/runtime/shredder.zig` | ~350 | Block-to-shred conversion |
| `src/network/tpu_client.zig` | ~350 | Vote/TX submission |

### Updated Files
| File | Changes |
|------|---------|
| `src/runtime/shred.zig` | FEC resolver integration |
| `src/runtime/block_producer.zig` | Shredder integration |
| `src/runtime/root.zig` | New module exports |
| `src/network/root.zig` | TPU client exports |
| `CHANGELOG.md` | Version 0.2.0 documentation |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      VEXOR VALIDATOR                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   GOSSIP    │───▶│     TVU     │───▶│  FEC RESOLVER│    │
│  │  (peers)    │    │  (shreds)   │    │  (recovery)  │    │
│  └─────────────┘    └─────────────┘    └──────┬───────┘    │
│                                                │             │
│  ┌─────────────┐    ┌─────────────┐    ┌──────▼───────┐    │
│  │   TOWER     │◀───│   REPLAY    │◀───│    BANK      │    │
│  │  (voting)   │    │  (entries)  │    │ (execution)  │    │
│  └──────┬──────┘    └─────────────┘    └──────────────┘    │
│         │                                                    │
│  ┌──────▼──────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ TPU CLIENT  │───▶│  SHREDDER   │◀───│BLOCK PRODUCER│    │
│  │ (submit)    │    │  (create)   │    │   (pack)     │    │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Notes

- All Firedancer references in `/home/dbdev/external/firedancer/src/`
- Build with `zig build -Doptimize=ReleaseFast` for production
- Test on testnet before any mainnet deployment
- Monitor gossip peers and TVU shred counts for health
