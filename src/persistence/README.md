# VEXOR Tiered Persistence System

## Overview

A battle-tested persistence architecture combining 40+ years of database engineering 
best practices with Solana-specific optimizations. Designed to be:

1. **Proven** - Uses WAL, append-only storage, and tiered caching (all industry standard)
2. **Future-proof** - Clean abstraction layers allow upgrading any component
3. **Snapstream-ready** - Cold tier is the integration point for Snapstream CDN
4. **Cross-client** - Standardized formats allow Agave/Firedancer/Sig to use Snapstream

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           VEXOR VALIDATOR                                   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  HOT TIER (RAM) - ~5-10 GB                                          │   │
│  │  • Active accounts from last 32 slots (2 epochs worth of voting)    │   │
│  │  • Write buffer for uncommitted slot changes                        │   │
│  │  • Account index (SwissMap - O(1) lookup)                           │   │
│  │  Eviction: LRU to Warm Tier when slot commits                       │   │
│  └───────────────────────────────┬─────────────────────────────────────┘   │
│                                  │ commit                                   │
│  ┌───────────────────────────────▼─────────────────────────────────────┐   │
│  │  WARM TIER (NVMe SSD) - ~50-100 GB                                  │   │
│  │  • WAL (Write-Ahead Log) - every account delta, append-only         │   │
│  │  • Account files (append vectors, mmap'd)                           │   │
│  │  • Index checkpoint (periodic, for fast restart)                    │   │
│  │  Compaction: Background thread merges WAL into account files        │   │
│  └───────────────────────────────┬─────────────────────────────────────┘   │
│                                  │ snapshot                                 │
│  ┌───────────────────────────────▼─────────────────────────────────────┐   │
│  │  COLD TIER (Disk / Network) - Unbounded                             │   │
│  │  • Full snapshots (every ~25000 slots)                              │   │
│  │  • Incremental snapshots (every ~500 slots)                         │   │
│  │  ══════════════════════════════════════════════════════             │   │
│  │  ║  SNAPSTREAM INTEGRATION POINT                      ║             │   │
│  │  ║  • Upload: Push snapshots to Snapstream CDN        ║             │   │
│  │  ║  • Download: Pull snapshots from Snapstream CDN    ║             │   │
│  │  ║  • Stream: Real-time account delta streaming       ║             │   │
│  │  ══════════════════════════════════════════════════════             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Why This Architecture?

### 1. Write-Ahead Log (WAL)
- **Proven by**: PostgreSQL (since 1996), MySQL InnoDB, SQLite, RocksDB
- **How it works**: 
  1. Before modifying any account, write the change to WAL
  2. WAL is append-only (sequential writes = fast)
  3. On crash: replay WAL from last checkpoint
- **Benefit**: Never lose more than a few seconds of data

### 2. Append-Only Account Files
- **Proven by**: Solana's existing AccountsDB, Git, Kafka
- **How it works**:
  1. Never modify account data in place
  2. Append new version to end of file
  3. Update index to point to new location
  4. Background compaction removes old versions
- **Benefit**: No corruption from partial writes, easy to snapshot

### 3. Tiered Storage
- **Proven by**: CPU caches, RocksDB, Cassandra, S3 Glacier
- **How it works**:
  1. Hot data in RAM (fastest, smallest)
  2. Warm data on NVMe (fast, medium)
  3. Cold data on disk/network (slow, largest)
- **Benefit**: Optimal cost/performance, handles any dataset size

### 4. Checkpoint + Replay
- **Proven by**: Every database ever, all Solana validators
- **How it works**:
  1. Periodically save full state (checkpoint)
  2. On restart: load checkpoint + replay changes since
- **Benefit**: Fast recovery, bounded WAL size

## Restart Scenarios

| Scenario | Recovery Time | Data Loss |
|----------|---------------|-----------|
| Clean shutdown | ~5 seconds | None |
| Process crash | ~30 seconds | Last 1-2 slots |
| Power loss | ~1-2 minutes | Last 1-2 slots |
| Disk failure | ~15 minutes (full snapshot) | None (with Snapstream) |

## Snapstream Integration

The Cold Tier is specifically designed as the Snapstream integration point:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   VEXOR      │     │  SNAPSTREAM  │     │   AGAVE      │
│   Cold Tier  │◄───►│     CDN      │◄───►│   Validator  │
└──────────────┘     └──────────────┘     └──────────────┘
                            ▲
                            │
                     ┌──────┴──────┐
                     │  FIREDANCER │
                     │   Validator │
                     └─────────────┘
```

### Snapstream Protocol (Future)
1. **Upload**: Validators push snapshots/deltas to Snapstream
2. **Download**: Validators pull snapshots from nearest edge
3. **Stream**: Real-time account change subscription
4. **Verify**: Merkle proofs for trustless verification

## File Formats

All formats are designed for cross-client compatibility:

### WAL Entry Format
```
┌────────────┬────────────┬────────────┬────────────┬────────────┐
│ Magic (4B) │ Slot (8B)  │ Pubkey(32B)│ Length(4B) │ Data (var) │
├────────────┼────────────┼────────────┼────────────┼────────────┤
│ 0x56455831 │ LE u64     │ [u8; 32]   │ LE u32     │ Account    │
└────────────┴────────────┴────────────┴────────────┴────────────┘
│                                                                │
└──────────────── CRC32 checksum at end ─────────────────────────┘
```

### Checkpoint Format
```
Header:
  - Magic: "VXCP" (4 bytes)
  - Version: u32
  - Slot: u64
  - Account count: u64
  - Accounts hash: [32]u8
  - Index offset: u64

Body:
  - Accounts (append vectors, same as Solana format)
  
Footer:
  - Index (pubkey -> file offset mapping)
  - Checksum
```

## Implementation Status

- [ ] WAL writer/reader
- [ ] Hot tier (RAM cache with LRU)
- [ ] Warm tier (mmap'd account files)
- [ ] Checkpoint writer
- [ ] Checkpoint loader
- [ ] Background compaction
- [ ] Snapstream upload stub
- [ ] Snapstream download stub
- [ ] Cross-client format tests
