# Firedancer Snapshot System Deep Dive

## Overview

This document analyzes how Firedancer implements snapshot downloading and fast catch-up for validator bootstrapping. Since Firedancer is written in C and Zig can interoperate with C, we can potentially port these mechanisms to Vexor.

## Key Components

Firedancer's snapshot system is modular and consists of several "tiles" (specialized processing units):

### 1. Snapshot Tile Architecture

| Tile | File | Purpose |
|------|------|---------|
| `snapct` | `fd_snapct_tile.c` | **Controller** - orchestrates the entire snapshot flow, selects peers, manages state machine |
| `snapld` | `fd_snapld_tile.c` | **Loader** - reads data from local file or HTTP/HTTPS connection |
| `snapdc` | `fd_snapdc_tile.c` | **Decompressor** - decompresses zstd/bz2 data streams |
| `snapin` | `fd_snapin_tile.c` | **Inserter** - inserts accounts into the database |
| `snapla` | `fd_snapla_tile.c` | **Latency** - measures and reports latency |
| `snapls` | `fd_snapls_tile.c` | **Lister** - lists local snapshots |
| `snapwh` | `fd_snapwh_tile.c` | **Warehouse** - stores snapshot data |
| `snapwr` | `fd_snapwr_tile.c` | **Writer** - writes snapshot data to disk |

### 2. Utility Modules

| Module | Purpose |
|--------|---------|
| `fd_sspeer_selector` | Selects optimal peer based on latency + snapshot freshness |
| `fd_ssping` | ICMP ping tracker for measuring peer latency |
| `fd_sshttp` | HTTP/HTTPS download client |
| `fd_ssarchive` | Parses snapshot archive structure (tar.zst) |
| `fd_ssresolve` | Resolves peer addresses from gossip data |
| `fd_ssmanifest_parser` | Parses snapshot manifest (168KB!) |

## How Firedancer Discovers Snapshot Peers

### Phase 1: Gossip-Based Discovery

1. **Join Gossip Network**: Connect to entrypoints and receive CRDS data
2. **Collect SnapshotHashes**: Validators advertise their snapshot slots in CRDS
3. **Extract ContactInfo**: Get RPC addresses from ContactInfo CRDS entries
4. **Filter Peers**: Only consider peers with RPC port AND recent snapshots

### Phase 2: Peer Selection (`fd_sspeer_selector`)

```c
/* The snapshot peer selector continuously selects the most optimal 
   snapshot peer to download snapshots from. The most optimal peer 
   is defined as the closest peer that serves the most recent snapshot. */

struct fd_ssinfo {
  struct { ulong slot; } full;
  struct { ulong base_slot; ulong slot; } incremental;
};

struct fd_sspeer {
  fd_ip4_port_t addr;   /* address of the peer */
  fd_ssinfo_t   ssinfo; /* resolved snapshot slot info */
  ulong         score;  /* selector score (lower is better) */
};
```

**Selection Algorithm:**
- Score = `(cluster_slot - peer_slot) + latency_factor`
- Lower score = better peer
- Prioritizes freshness + low latency

### Phase 3: HTTP Download (`fd_sshttp`)

Firedancer uses standard HTTP to download snapshots:

```c
// Snapshot URLs (standard Solana format)
if( ctx->load_full ) 
  fd_sshttp_init( ctx->sshttp, addr, hostname, is_https, 
                  "/snapshot.tar.bz2", 17UL, wallclock );
else                 
  fd_sshttp_init( ctx->sshttp, addr, hostname, is_https, 
                  "/incremental-snapshot.tar.bz2", 29UL, wallclock );
```

**Key URLs:**
- Full: `http://<rpc_addr>/snapshot.tar.bz2` or `.tar.zst`
- Incremental: `http://<rpc_addr>/incremental-snapshot.tar.bz2` or `.tar.zst`

### Phase 4: Streaming Decompression

```
snapld (HTTP) → snapdc (zstd decompress) → snapin (DB insert)
```

Data flows through shared memory (dcache) with zero-copy operations.

## Local Snapshot Loading

Before attempting network download, Firedancer checks for local snapshots:

```c
// Look for existing snapshots on disk
fd_ssarchive_latest_pair( tile->snapld.snapshots_path, 1,
                          &full_slot,    &incr_slot,
                           full_path,     incr_path,
                          &full_is_zstd, &incr_is_zstd );
```

## Fast Catch-Up Mode

When no snapshot is available (or to update after loading a snapshot):

1. **Load latest local/downloaded snapshot**
2. **Start shred repair** - Request missing shreds from peers
3. **Replay slots** - Execute transactions to update state
4. **Continue normal operation**

## Key Insights for Vexor

### What We Should Implement

1. **Gossip-Based Peer Discovery**
   - Listen for `SnapshotHashes` CRDS entries in gossip
   - Cross-reference with `ContactInfo` to get RPC addresses
   - Only contact peers that advertise snapshots

2. **Peer Scoring System**
   - Track peer latency via ICMP ping
   - Score by `(freshness * weight) + (latency * weight)`
   - Automatically switch peers if download is too slow

3. **Streaming Download**
   - Use HTTP/1.1 with chunked transfer
   - Stream-decompress zstd on the fly
   - Don't wait for full download before processing

4. **Local Snapshot Priority**
   - Check `/mnt/vexor/snapshots/` first
   - Accept snapshots within N slots of cluster head
   - Fall back to network download only if needed

5. **Fast Catch-Up Fallback**
   - If no snapshot found, start from genesis
   - Use aggressive shred repair to catch up
   - This is slower but always works

### What NOT to Do

- ❌ Query random RPC endpoints hoping they serve snapshots
- ❌ Try to download from validators that don't advertise `rpc` port
- ❌ Wait for full download before starting decompression
- ❌ Fail if snapshot download fails - fall back to shred repair

## Implementation Priority

1. **P0**: Local snapshot loading (already have this)
2. **P1**: Gossip-based peer discovery for snapshots
3. **P2**: HTTP streaming download with zstd decompression
4. **P3**: Peer selection/scoring system
5. **P4**: Fast catch-up via shred repair

## Code References

### Firedancer Files to Study

- `src/discof/restore/fd_snapct_tile.c` - Main controller (65KB)
- `src/discof/restore/utils/fd_sspeer_selector.c` - Peer selection (15KB)
- `src/discof/restore/utils/fd_sshttp.c` - HTTP client (20KB)
- `src/flamenco/gossip/` - Gossip implementation
- `src/flamenco/repair/` - Shred repair protocol

### Solana Gossip CRDS Types

```rust
// From Solana/Agave
enum CrdsData {
    ContactInfo(ContactInfo),
    SnapshotHashes(SnapshotHashes),
    AccountsHashes(AccountsHashes),
    // ... more types
}

struct SnapshotHashes {
    from: Pubkey,
    full: (Slot, Hash),
    incremental: Vec<(Slot, Hash)>,
    wallclock: u64,
}
```

## Conclusion

Firedancer's snapshot system is well-architected with clear separation of concerns. For Vexor, we should:

1. **Short-term**: Use known testnet RPC endpoints that serve snapshots
2. **Medium-term**: Implement proper gossip-based snapshot discovery
3. **Long-term**: Port Firedancer's peer scoring and streaming systems

The key realization is that **most validators don't serve snapshots** - only dedicated RPC nodes with `--full-rpc-api` and `--enable-rpc-transaction-history` do. The gossip network helps us find these nodes.

---

# Next Steps for Vexor Development

## Phase 1: Immediate (Now)

### 1.1 Manual Snapshot Download for Testing
**Status: ✅ COMPLETED**

Since most RPC nodes don't serve snapshots publicly, we manually copied a snapshot from Agave.

**Current Snapshot Setup (Dec 13, 2024):**
```
Location: /mnt/vexor/snapshots/
Snapshot: snapshot-374576751-6Ev8s5Z7esXBZ66paivFgfVFpeHgqu6tHwqVQJZoTVPh.tar.zst
Size:     4.8 GiB
Slot:     374,576,751
Network:  Testnet
```

**How we did it:**
```bash
# Copied from Agave's snapshot directory
sudo cp /mnt/solana/snapshots/remote/snapshot-374576751-*.tar.zst /mnt/vexor/snapshots/
sudo chown solana:solana /mnt/vexor/snapshots/*
```

**For future updates:**
```bash
# Option A: Copy from Agave (if running on same machine)
cp /mnt/solana/snapshots/remote/snapshot-*.tar.zst /mnt/vexor/snapshots/

# Option B: Download from testnet snapshot provider
# (URLs change frequently - check Solana Discord for current providers)
wget -O /mnt/vexor/snapshots/snapshot.tar.zst <PROVIDER_URL>
```

### 1.2 Test Bootstrap with Local Snapshot
```bash
./zig-out/bin/vexor run --bootstrap --testnet \
    --identity ~/validator-keypair.json \
    --snapshots /mnt/vexor/snapshots
```

## Phase 2: Short-Term (1-2 weeks)

### 2.1 Implement Gossip-Based Snapshot Discovery
- Listen for `SnapshotHashes` CRDS entries
- Track which validators have recent snapshots
- Cross-reference with ContactInfo for RPC addresses

### 2.2 Add Peer Scoring
- Track ICMP ping latency to peers
- Score by: `freshness_weight * slot_age + latency_weight * ping_ms`
- Prefer peers with lowest score

### 2.3 Streaming HTTP Download
- Download in chunks (don't buffer entire file)
- Stream to zstd decompressor
- Report progress in real-time

## Phase 3: Medium-Term (1-2 months)

### 3.1 Full Shred Repair Implementation
- Request missing shreds from gossip peers
- Verify shred signatures
- Reconstruct blocks and replay transactions

### 3.2 Incremental Snapshot Support
- Download base snapshot first
- Then download incremental snapshots
- Apply incrementals on top of base

### 3.3 Parallel Download
- Download from multiple peers simultaneously
- Verify checksums match
- Cancel slow/corrupt peers

## Phase 4: Long-Term (3+ months)

### 4.1 Port Firedancer Components
- `fd_sspeer_selector` → Zig peer selector
- `fd_sshttp` → Zig streaming HTTP client
- `fd_ssarchive` → Zig tar parser

### 4.2 Custom Snapshot Format
- Design Vexor-native snapshot format
- Optimize for fast loading
- Support memory-mapped loading

---

# Known Snapshot Providers (as of Dec 2024)

## Testnet
- Solana Foundation validators (may not serve publicly)
- Community providers (check Discord)

## Mainnet
- Triton: `https://snapshots.triton.one`
- Jito: Check their docs
- Various community providers

**Note:** Snapshot provider URLs change frequently. Always verify the latest endpoints in the Solana Discord or documentation.

