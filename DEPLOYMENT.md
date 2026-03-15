# Vexor Deployment Notes

## Server Access

- **IP:** YOUR_VALIDATOR_IP
- **SSH Port:** 2222 (NOT default 22)
- **SSH Config Alias:** `vexor-validator`
- **User:** sol
- **SSH Command:** `ssh vexor-validator`

## Key Paths on Server

| Path | Description |
|------|-------------|
| `/home/sol/vexor/bin/vexor-validator` | Vexor binary |
| `/home/sol/agave/bin/agave-validator` | Agave binary |
| `/home/sol/bin/switch-client.sh` | Switch between Agave/Vexor |
| `/home/sol/bin/vexor-testnet-restart` | Vexor startup script |
| `/home/sol/bin/agave-testnet-restart` | Agave startup script |
| `/home/sol/.secrets/qubetest/` | Keypairs |
| `/home/sol/ledger/` | Ledger data |
| `/home/sol/logs/` | Log files |

## Systemd Services

- `solana-validator.service` - Agave validator
- `vexor-validator.service` - Vexor validator

## Switch Client Commands

Passwordless sudo is configured for the `sol` user for validator commands:

```bash
# Switch to Vexor
ssh vexor-validator "sudo /home/sol/bin/switch-client.sh vexor"

# Switch to Agave  
ssh vexor-validator "sudo /home/sol/bin/switch-client.sh agave"

# Restart Vexor (after deploying new binary)
ssh vexor-validator "sudo systemctl restart vexor-validator"

# Check status
ssh vexor-validator "sudo systemctl status vexor-validator"
```

## Deploy New Binary

```bash
# Build locally
cd /home/dbdev/solana-client-research/vexor
zig build -Doptimize=ReleaseFast

# Upload via SSH config alias (binary is named 'vexor', deploy as 'vexor-validator')
scp zig-out/bin/vexor vexor-validator:/home/sol/vexor/bin/vexor-validator

# Restart to use new binary
ssh vexor-validator "sudo systemctl restart vexor-validator"
```

## SSH Keys Reference

SSH config is at `~/.ssh/config`. Key aliases:

| Alias | Host | Port | User | Key |
|-------|------|------|------|-----|
| `vexor-validator` | YOUR_VALIDATOR_IP | 2222 | sol | `~/.ssh/vexor_validator` |

Other keys in `~/.ssh/`:
- `id_vexor`, `id_vexor_deploy` - Vexor-related keys
- `id_davidb_validator` - davidb user access
- `snapstream_wsl`, `snapstream_ed25519` - Snapstream keys
- `id_solsnap_vps` - Solsnap VPS access

## View Logs

**Log File Locations:**
| Client | Log File | journald Unit |
|--------|----------|---------------|
| Agave | `/home/sol/solana-validator.log` | `solana-validator` |
| Vexor | `/home/sol/vexor-validator.log` | `vexor-validator` |

```bash
# === VEXOR LOGS ===
# Live tail (file)
ssh vexor-validator "tail -f /home/sol/vexor-validator.log"

# Live tail (journald - includes startup messages)
ssh vexor-validator "journalctl -u vexor-validator -f"

# Filter out gossip noise
ssh vexor-validator "tail -100 /home/sol/vexor-validator.log | grep -v 'PULL_RESPONSE\|Gossip'"

# === AGAVE LOGS ===
# Live tail
ssh vexor-validator "tail -f /home/sol/solana-validator.log"

# journald
ssh vexor-validator "journalctl -u solana-validator -f"
```

**Note:** Vexor startup/debug messages go to journald. Once running, application logs go to the log file.

---

# Server Configuration Reference

## Switch Client Script (`/home/sol/scripts/switch-client.sh`)

```bash
#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: switch-client.sh <agave|vexor>"
  exit 1
fi

TARGET="$1"

case "$TARGET" in
  agave)
    sudo systemctl stop vexor-validator || true
    sudo systemctl start solana-validator
    ;;
  vexor)
    sudo systemctl stop solana-validator || true
    sudo systemctl start vexor-validator
    ;;
  *)
    echo "Unknown target: $TARGET"
    exit 1
    ;;
esac

sudo systemctl status "${TARGET}-validator" --no-pager || true
```

## Agave Startup Script (`/home/sol/bin/agave-testnet-restart`)

```bash
#!/bin/bash
exec /home/sol/agave/bin/agave-validator \
  --no-port-check \
  --identity /home/sol/.secrets/qubetest/validator-keypair.json \
  --vote-account /home/sol/.secrets/qubetest/vote-account-keypair.json \
  --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on \
  --known-validator 7XSY3MrYnK8vq693Rju17bbPkCN3Z7KvvfvJx4kdrsSY \
  --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN \
  --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv \
  --known-validator 6gPFU17pZ7rSHCs7Uqr2WC5LqZDEVQd9mDXVkHezcVkn \
  --known-validator J5e4xh1V7zGZnHq9rYfsowFJghoc9SEZWFfiCdbc8FF1 \
  --known-validator FT9QgTVo375TgDAQusTgpsfXqTosCJLfrBpoVdcbnhtS \
  --only-known-rpc \
  --log /home/sol/solana-validator.log \
  --ledger /home/sol/ledger \
  --accounts /home/sol/accounts-ramdisk \
  --accounts-hash-cache-path /home/sol/restart_snapshots/accounts_hash_cache \
  --snapshots /home/sol/restart_snapshots \
  --rpc-port 8899 \
  --dynamic-port-range 8800-9000 \
  --entrypoint entrypoint.testnet.solana.com:8001 \
  --entrypoint entrypoint2.testnet.solana.com:8001 \
  --entrypoint entrypoint3.testnet.solana.com:8001 \
  --expected-genesis-hash 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY \
  --wal-recovery-mode skip_any_corrupted_record \
  --limit-ledger-size 50000000 \
  --full-snapshot-interval-slots 100000 \
  --incremental-snapshot-interval-slots 1000 \
  --experimental-poh-pinned-cpu-core 2 \
  --expected-shred-version 27350
```

## Vexor Startup Script (`/home/sol/bin/vexor-testnet-restart`)

```bash
#!/bin/bash
set -euo pipefail

exec /home/sol/vexor/bin/vexor-validator run \
  --bootstrap \
  --testnet \
  --identity /home/sol/.secrets/qubetest/validator-keypair.json \
  --vote-account /home/sol/.secrets/qubetest/vote-account-keypair.json \
  --ledger /home/sol/ledger \
  --accounts /mnt/ramdisk/accounts \
  --snapshots /home/sol/restart_snapshots \
  --log /home/sol/vexor-validator.log \
  --public-ip YOUR_VALIDATOR_IP \
  --gossip-port 8001 \
  --tpu-port 8003 \
  --tvu-port 8004 \
  --rpc-port 8899 \
  --dynamic-port-range 8000-8010 \
  --expected-shred-version 27350 \
  --disable-io-uring \
  --enable-parallel-snapshot \
  --parallel-snapshot-threads 8 \
  --limit-ledger-size 50000000
```

## Systemd Service Files

Both services are nearly identical, differing only in binary path:

**`/etc/systemd/system/solana-validator.service`** and **`/etc/systemd/system/vexor-validator.service`**:

```ini
[Unit]
Description=<agave|vexor>
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
LimitNOFILE=1000000
LogRateLimitIntervalSec=0
Environment="PATH=/bin:/usr/bin:/usr/local/bin:/home/sol/<agave|vexor>/bin"
Environment="SOLANA_METRICS_CONFIG=host=https://metrics.solana.com:8086,db=tds,u=testnet_write,p=..."
ExecStart=/home/sol/bin/<agave|vexor>-testnet-restart
TimeoutSec=infinity
User=sol
Group=sol
WorkingDirectory=/home/sol

[Install]
WantedBy=multi-user.target
```

## Key Differences: Agave vs Vexor Startup

| Feature | Agave | Vexor |
|---------|-------|-------|
| Binary | `agave-validator` | `vexor-validator run` |
| Accounts Path | `/home/sol/accounts-ramdisk` | `/mnt/ramdisk/accounts` |
| Port Check | `--no-port-check` | Not needed |
| Bootstrap | Downloads snapshot automatically | `--bootstrap` flag |
| Parallel Snapshot | Not supported | `--enable-parallel-snapshot` |
| Known Validators | 7 specified | Uses testnet defaults |
| Entrypoints | 3 explicit | Uses `--testnet` |

---

# Change Log

## 2026-01-29: Slot Completion Fix

**Problem:** Vexor was receiving shreds but never detecting slot completion. Slots weren't being marked complete because the `last_in_slot` flag detection was broken.

**Root Cause:** `SlotShreds` struct was using `highest_data_index` (highest shred index seen) instead of properly tracking `last_shred_index` (the shred with `last_in_slot` flag). This meant `hasAllDataShreds()` never returned true.

**Files Changed:** `src/runtime/shred.zig`

**Changes Made:**
1. Modified `SlotShreds` struct to add:
   - `max_seen_index: u32` - highest shred index seen
   - `last_shred_index: ?u32` - index of shred with `last_in_slot` flag
   - `unique_count: u32` - count of unique shreds received

2. Updated `hasAllDataShreds()` to use Sig's logic:
   ```zig
   // Slot complete when: unique_count == last_shred_index + 1
   const last_idx = self.last_shred_index orelse return false;
   return self.unique_count == last_idx + 1;
   ```

3. Updated `insert()` to properly track `last_shred_index` when `isLastInSlot()` is true

4. Updated `handleFecComplete()` for FEC-recovered shreds

5. Updated `assembleSlot()` to iterate to `last_shred_index` instead of `highest_data_index`

6. Updated `getHighestCompletedSlot()` to use `hasAllDataShreds()` instead of removed `is_complete` field

7. Updated `getMissingIndices()` to use `last_shred_index` or `max_seen_index`

**Reference:** Sig's `shred_tracker.zig` - `MonitoredSlot.record()` function

**Status:** Deployed and tested. SIGBUS crash occurred during snapshot loading - needs investigation.

---

---

## 2026-01-31: QUIC Stability & Thread Safety

**Focus:** Resolving `HandshakeTimeout` errors and ensuring thread safety in networking components.

**Changes Made:**
1. **Thread Safety:**
   - Added `std.Thread.Mutex` to `SolanaTpuQuic` to protect connection map and client access.
   - Added `NoLock` variants of cache access methods in `TpuClient` to prevent deadlocks.
   - Verified thread-safe access patterns for `getLeaderTpuQuic`.

2. **QUIC Handshake Optimization:**
   - Reduced handshake sleep interval from default to 10ms for faster retries.
   - increased `HandshakeTimeout` to 5 seconds.
   - Added non-blocking polling during handshake to prevent thread starvation.

3. **Transaction Submission Logic:**
   - Implemented `error.VoteQueued` handling in `VoteSubmitter` to distinguish between network failures and missing leader info (common during catchup).
   - Enhanced `TpuClient` logging (Info level) to pinpoint exactly why leader lookups fail (missing schedule vs missing gossip contact).

**Status:**
- QUIC client initializing correctly on port 8008.
- Votes correctly queueing when leader info is unavailable (catchup mode).
- **Next Step:** Verify successful QUIC vote delivery once validator catches up to a slot with known leader info.

---

## 2026-01-29: Parallel Snapshot Loading (Experimental)

**Feature:** Added `--enable-parallel-snapshot` flag to use multiple threads for AppendVec parsing during snapshot load.

**Files Changed:** 
- `src/core/config.zig` - Added config flags
- `src/storage/parallel_snapshot.zig` - New parallel loader module
- `src/storage/root.zig` - Module export

**New CLI Flags:**
- `--enable-parallel-snapshot` - Enable parallel loading
- `--disable-parallel-snapshot` - Disable (default)
- `--parallel-snapshot-threads N` - Set thread count (0 = auto)

**Status:** Implemented but not yet wired into bootstrap. Local benchmarks showed slowdown due to:
- WSL2 overhead on dev machine
- Allocator contention between threads
- Small test files (real AppendVecs are larger)

**Next Steps:** 
1. Wire into `bootstrap.zig` behind the flag
2. Test on actual validator hardware
3. Consider zero-copy approach (keep files mmapped)

---

## Known Issues

### SIGBUS During Snapshot Loading (FIXED)
- **Root Cause**: SIGBUS occurred in `AppendVec.append()` when writing to mmap'd regions
- The crash happened at ~350K accounts stored, ~7000 files processed
- Each AppendVec created a 64MB mmap, and with thousands of files, kernel limits were exceeded
- **Solution Applied** (2026-01-29):
  - Replaced mmap-based AppendVec with heap-allocated storage (following Sig's design)
  - Changed `AppendVec.data` from `[]align(std.mem.page_size) u8` (mmap) to `[]u8` (heap)
  - Added `flushToDisk()` method for periodic persistence
  - Removed `MmapAllocator` dependency from AppendVec
  - Added `dirty` flag to track when flush is needed
- **Result**: Successfully loading 80,000+ files and 3.5M+ accounts without SIGBUS

### Parallel Snapshot Loading (IMPLEMENTED)
- **Feature**: Multi-threaded snapshot loading for faster catchup
- **Enable with CLI flags**: `--enable-parallel-snapshot --parallel-snapshot-threads 8`
- **Implementation** (2026-01-29):
  - Added `ParallelSnapshotLoader` in `parallel_snapshot.zig`
  - Parse phase: 8 threads parse AppendVec files in parallel
  - Store phase: Optimized bulk store (pre-serialize outside lock)
  - Wired into both download and local disk load paths in `bootstrap.zig`
  - Added `storeAccountBulk()` - skips cache/shadow, pre-serializes outside lock
  - Added `enableBulkLoading()`/`disableBulkLoading()` - pre-sizes index
  - Added `serializeAccountToBytes()`/`writeAccountBytes()` - minimizes lock time
- **Performance** (93,514 files, 610,869 accounts):
  - Parse phase: ~6-7 seconds (8 threads)
  - Store phase: ~18-20 seconds (optimized bulk store)
  - **Total: ~27 seconds** (vs ~4 minutes single-threaded, ~9x faster)
- **io_uring investigation** (2026-01-29):
  - Added `BatchFileReader` to `io_uring.zig` with `prep_read`, `prep_statx` ops
  - Tested but **disabled** - io_uring slower (32s) vs threaded (26s)
  - Root cause: io_uring requires file sizes upfront (stat per file)
  - Threaded approach parallelizes stat+read together, which is faster
  - Code preserved for future use cases (e.g., network I/O)
- **VexStore bulk loading** (2026-01-29):
  - Build with: `zig build -Doptimize=ReleaseFast -Dvexstore_shadow=true`
  - Modified `parallel_snapshot.zig` to use `storeAccountBulkVexStore()` when available
  - Initial results: Store phase 13.5s (was 20.9s)
- **MemTable implementation** (2026-01-29):
  - Added sorted MemTable with binary search for normal put/get operations
  - Added `putBulk()` method that bypasses MemTable for O(1) hash inserts during bulk loading
  - MemTable is used for runtime operations (sorted order for SSTable flush)
  - `putBulk` used for snapshot loading (direct hash index, no WAL)
- **VexStore LSM Tree Components** (2026-01-29):
  - **Phase 2B-2**: Multi-level SSTable structure (L0-L6 levels, SSTableMeta tracking)
  - **Phase 2B-3**: L0 compaction (L0->L1 merge when L0 has 4+ files)
  - **Phase 2B-4**: Bloom filters (probabilistic set membership, ~1% FPR)
  - **Phase 2B-5**: Background compaction threads (non-blocking GC)
  - **Phase 2B-6**: Value log GC with stats (`getGCStats()`)
  - **Phase 2B-7**: Snapshot API (`createSnapshotIterator()` for deterministic iteration)
- **Additional Optimizations** (2026-01-29):
  - **Opt 1**: Bloom filters integrated into read path with stats
  - **Opt 2**: Manifest persistence (SSTable metadata survives restarts)
  - **Opt 3**: Hot Cache (128MB LRU cache for frequently accessed accounts)
  - **Opt 4**: Segmented value log infrastructure (256MB segments)
- **Current best performance** (93,514 files, 610,869 accounts):
  - Parse: ~5.2s (8 threads)
  - Store: ~8.7s (VexStore putBulk)
  - **Total: ~14.0s** (~17x faster than original ~4 minutes)
- **VexStore Features Complete**:
  - WiscKey architecture (keys in LSM tree, values in append-only log)
  - MemTable with sorted buffer for writes
  - Multi-level SSTable structure with compaction
  - Bloom filters for fast negative lookups (integrated in reads)
  - Background compaction thread
  - Incremental value log garbage collection
  - Deterministic snapshot iterator
  - WAL for crash recovery
  - Manifest persistence for restart recovery
  - LRU hot cache (128MB)
  - Segmented value log tracking
- **Future optimizations**:
  - Parallel store phase (thread-safe VexStore)
  - Per-SSTable lookup (reduce memory for index)
  - Active segment rolling (auto-create new segments at 256MB)

---

## Storage Architecture Notes

### Vexor Storage Systems
| System | Purpose | Technology |
|--------|---------|------------|
| **VexStore** | Account storage | Custom Zig WiscKey LSM tree (keys in LSM, values in append-only log) |
| **SpeedDB** | Optional backend | RocksDB-compatible via speedb.zig bindings |
| **Blockstore** | Shred/slot storage | Custom Zig in-memory hash maps |

### Validator Ledger (Agave RocksDB)
- The 418GB `/home/sol/ledger/rocksdb` is from **Agave**, not Vexor
- Agave uses RocksDB for ledger storage with `--limit-ledger-size` flag
- RocksDB compaction must run to reclaim disk space after slot deletion
- **Maintenance command**: `agave-ledger-tool blockstore purge -l /home/sol/ledger --enable-compaction <start_slot> <end_slot>`

### Ledger Maintenance (2026-01-30)
- Ran purge: slots 0 to 383,838,987 with compaction enabled
- Expected to reduce RocksDB from ~418GB to <100GB
- Added cleanup.sh cron job (runs at 4am/6pm) for ongoing maintenance

---

## Current Implementation Status (Verified 2026-01-29)

### Working Components
| Component | Status | Notes |
|-----------|--------|-------|
| VexStore | ✅ Complete | Full LSM tree, 14s snapshot loading |
| TVU | ✅ Working | UDP on port 8004 |
| TPU | ✅ Working | QUIC + UDP fallback |
| Gossip | ✅ Working | No bloom filter but functional |
| Tower BFT | ✅ Working | Vote generation, lockouts |
| Fork Choice | ✅ Working | Stake-weighted selection |
| Bank | ✅ Working | Transaction processing |
| Shred/FEC | ✅ Working | Assembly with FEC recovery |
| Vote Submission | ✅ Working | Sends to multiple leaders |
| AccountsDB Merkle | ✅ Working | computeHash() implemented |
| Auto-Optimizer | ⚠️ Partial | CPU/Memory/Kernel tuning work |

### Known Issues (Current)
| Issue | Severity | Details |
|-------|----------|---------|
| ShredAssembler Threading | 🔴 High | Hash map concurrent access crash in `shred.zig:539`. Panic: "reached unreachable code" in lock assertion. Needs mutex/atomic protection. |
| ShredAssembler Threading | 🔴 High | Hash map concurrent access crash in `shred.zig:539`. Panic: "reached unreachable code" in lock assertion. Needs mutex/atomic protection. |
| QUIC Handshake | 🟡 Medium | Thread-safety fixes applied. Handshake loop optimized. Monitoring for timeouts during catchup. |
| Blockhash Source | 🟠 Medium | Still using RPC in "bootstrap mode" |
| Blockhash Source | 🟠 Medium | Still using RPC in "bootstrap mode" |
| SIMD Ed25519 | 🟠 Medium | Sequential verification, no AVX batch |
| Snapshot Save | 🟡 Low | Hash computation disabled (crash bug) |
| AF_XDP | 🟡 Low | Falls back to UDP (BPF loading incomplete) |
| BLS Crypto | 🟡 Low | Structure only, operations are stubs |
| LLM Diagnostics | 🟡 Low | All providers return "not implemented" |

### Observed in Live Logs
```
[QUIC] handshake timeout stage=client_hello_sent resends=14
[QUIC] handshake failed err=error.HandshakeTimeout
[TpuClient] QUIC send failed: error.HandshakeTimeout
[TpuClient] Vote sent to 4 leader(s) for slot XXXXXX  (UDP fallback works)
[QUIC] handshake timeout stage=client_hello_sent resends=14
[QUIC] handshake failed err=error.HandshakeTimeout
[TpuClient] QUIC send failed: error.HandshakeTimeout
[TpuClient] Vote sent to 4 leader(s) for slot XXXXXX  (UDP fallback works)
[VoteSubmitter] Bootstrap mode - fetching blockhash from RPC
[VoteSubmitter] ⚠ Vote queued for slot XXXXXX (leader not found)
```

---

## VEXOR Feature Roadmap (Prioritized)

This roadmap tracks all features, fixes, and unique innovations. Items are prioritized by their impact on validator functionality and competitive differentiation.

### Priority Legend
- 🔴 **P0 - Critical**: Blocking reliable validator operation
- 🟠 **P1 - High**: Significant performance or functionality gap
- 🟡 **P2 - Medium**: Important but not blocking
- 🟢 **P3 - Low**: Nice to have, future enhancement
- ✅ **Complete**: Implemented and verified

---

### P0 - CRITICAL (Blocking Validator Operation)

| # | Feature | Type | Status | Notes |
|---|---------|------|--------|-------|
| 1 | Fix QUIC Handshake | Parity | ⚠️ VERIFY | Thread-safety fixes + loop optimization applied. Monitoring reliability. |
| 2 | Blockhash from Local Bank | Parity | ⚠️ PARTIAL | Shred reception at 92-97% after Turbine fix. FEC recovery disabled (was producing garbage). Awaiting slot completions. |
| 3 | Vote Transaction Format | Parity | ⬜ VERIFY | May be incorrect per audit. Needs verification against Agave/Firedancer. |
| 4 | Turbine Shred Reception | Parity | ✅ IMPROVED | Implemented TurbineTree with weighted shuffle (2026-01-30). Shred reception improved from 10% to 92-97%. |
| 5 | CPU Usage Optimization | **UNIQUE** | ⬜ TODO | Vexor runs at ~100% CPU. Need to profile and optimize. Goal: lighter than Firedancer/Agave. |

#### Blockhash Investigation Notes (2026-01-29)
- **Fixed**: Shred assembler was rejecting all shreds due to `highest_slot + 1000` check when `highest_slot=0`
- **Fixed**: FEC resolver data shred position calculation 
- **FEC Working**: Parity shreds received (32 data + 32 parity per FEC set), but not enough total shreds for recovery
- **Current Bottleneck**: Only receiving ~47 shreds when 448 needed per slot
- **Root Cause**: Turbine retransmit tree issue - validator not receiving full shred fan-out

#### Turbine Tree Implementation (2026-01-30)
- **Created**: `src/network/turbine_tree.zig` - proper stake-weighted Turbine tree
- **Reference**: Sig `turbine_tree.zig` and Firedancer `fd_shred_dest.c`
- **Key Features**:
  - Nodes sorted by (stake, pubkey) descending
  - Deterministic seed: SHA256(slot || shred_type || index || leader_pubkey)
  - Position-based child calculation matching Solana spec
  - Fanout of 200 (DATA_PLANE_FANOUT)
- **Updated**: `src/network/tvu.zig` Turbine struct to use TurbineTree
- **Deployed**: 2026-01-30 - binary hash `3fd22e5de6c0abdb0e49baf5198ae500`

#### Turbine + FEC Fixes (2026-01-30)
- **RESULT**: Shred reception increased from ~47 to 295-320 shreds per slot (92-97% complete)
- **Files Changed**:
  - `src/network/turbine_tree.zig` - Fixed `peer.id` → `peer.pubkey` 
  - `src/crypto/chacha.zig` - NEW: ChaChaRng matching Rust's `rand_chacha`
  - `src/crypto/weighted_shuffle.zig` - NEW: Stake-weighted shuffle algorithm
  - `src/network/tvu.zig` - Added shred_version filtering for peers
  - `src/runtime/root.zig` - Pass expected_shred_version to TVU
  - `src/runtime/shred.zig` - Added missing merkle code shred types (0x40-0x5F)
  - `src/runtime/fec_resolver.zig` - Disabled incorrect XOR-based recovery
- **FEC Recovery Issue Found**: Previous XOR-based single-erasure recovery was incorrect 
  for Reed-Solomon codes (which use Galois Field math, not XOR). This produced garbage 
  shreds with invalid type bytes (0xC0, 0xF0). Recovery disabled until proper RS 
  implementation is added.
- **Gossip Peers**: 5 peers available for repair (filtered by shred_version)

#### Reed-Solomon FEC Recovery Implementation (2026-01-30)
- **RESULT**: FEC recovery now working! Slots completing via RS recovery!
- **Key Reference**: Official Solana spec: https://github.com/solana-foundation/specs/blob/main/p2p/shred.md
- **Algorithm**:
  1. Reed-Solomon in GF(2^8) using polynomial `x^8 + x^4 + x^3 + x^2 + 1` (0x11D)
  2. Data shred i evaluated at point i, Code shred j evaluated at point N+j
  3. Recovery uses Vandermonde matrix inversion via Gaussian elimination
  4. Polynomial interpolation with Horner's method for evaluation
- **Critical Discovery**: Erasure shard offsets differ by shred type:
  - **Merkle data shreds**: bytes [64..end] (skip 64-byte signature)
  - **Code shreds**: bytes [89..end] (skip all headers)
  - **Legacy data shreds**: bytes [0..end] (full shred)
- **Files Changed**:
  - `src/runtime/fec_resolver.zig`:
    - Added `SIGNATURE_SIZE`, `DATA_HEADER_SIZE`, `CODE_HEADER_SIZE` constants
    - Rewrote `recoverWithMatrix()` to properly handle erasure shard offsets
    - Detects Merkle vs Legacy shreds via variant byte (0x80-0xBF = Merkle data)
    - Builds Vandermonde matrix from available shred evaluation points
    - Inverts matrix using GF(2^8) Gaussian elimination
    - Recovers missing data using polynomial interpolation
    - Copies header from template shred, recovers erasure portion
  - `src/network/tvu.zig`:
    - Increased repair peer buffer from 5 to 32 (`MAX_REPAIR_PEERS`)
    - Implemented random sampling from up to 512 gossip peers
    - Increased `REPAIR_FANOUT` from 3 to 6
- **Logs Showing Success**:
  ```
  [FEC] Successfully recovered 17 data shreds
  [FEC] Slot 385115674 FEC set 288 RECOVERED!
  [TVU] *** SLOT 385115674 COMPLETED! (total: 1) ***
  ```
- **Remaining Issue**: Some recovered shreds show `Unknown type byte: 0x00` - 
  likely header reconstruction issue, but slots are completing successfully.
- **Deployed**: 2026-01-30 - binary hash `b1934b451d04411254da5f489951a19d`

#### FEC Recovery Merkle Proof Fix (2026-01-30 - CRITICAL FIX)
- **ROOT CAUSE FOUND**: The erasure shard calculation was INCLUDING the merkle proof bytes
  at the end of the shred, but per the Solana spec, the merkle proof is NOT part of RS encoding!
- **Key Insight from Solana Spec**:
  > "When using Merkle authentication, the interpretation of 'data shred' used for erasure 
  > coding begins immediately after the signature field and ends immediately BEFORE the 
  > Merkle proof section."
- **The Bug**:
  - Previous: `erasure_sz = shred.len - 64` = 1203 - 64 = 1139 bytes (WRONG)
  - Fixed: `erasure_sz = shred.len - 64 - (proof_size * 20)` = 1203 - 64 - 120 = **1019 bytes** (CORRECT)
  - The 120-byte merkle proof (6 entries * 20 bytes each) was being included in RS math
- **How to calculate merkle proof size**:
  - Variant byte (shred[64]) low 4 bits = `proof_size` (merkle tree height)
  - Merkle proof bytes = `proof_size * 20` (each entry is 20 bytes, truncated SHA256)
  - For typical FEC sets (32+32=64 total), height = ceil(log2(64)) = 6, proof = 120 bytes
- **Files Changed**:
  - `src/runtime/fec_resolver.zig`:
    - Added `MERKLE_PROOF_ENTRY_SIZE = 20`
    - Added `parseVariantByte()` to extract proof_size from variant byte
    - Added `calculateErasureShardSize()` to compute correct bounds
    - Fixed `recoverWithSigMethod()` to exclude merkle proof bytes from all shard extractions
- **Verification**:
  ```
  [FEC] Erasure params: is_merkle=true, proof_size=6, merkle_proof_bytes=120, erasure_sz=1019, data_start=64
  [FEC] Recovered 17/17 data shreds (merkle=true, erasure_sz=1019, n=32, m=32)
  [FEC] Slot 385135520 FEC set 384 RECOVERED!
  ```
- **NEW ISSUE FOUND**: After fixing FEC, a threading bug appeared in `shred.zig:539`
  (hash map concurrent access assertion failure). This is a separate issue from FEC.
- **Deployed**: 2026-01-30

---

### P1 - HIGH (Performance/Functionality Gaps)

| # | Feature | Type | Status | Notes |
|---|---------|------|--------|-------|
| 4 | SIMD Ed25519 Batch Verification | Parity | ⬜ TODO | Sequential verification is a bottleneck. AVX2/AVX-512 detection exists but unused. |
| 5 | AncestorHashes Repair | Parity | ⬜ TODO | Defined in enum but no implementation. Needed for fork recovery. |
| 6 | Gossip CRDS Bloom Filter | Parity | ⬜ TODO | Using HashMap instead of bloom filter. Higher bandwidth usage. |
| 7 | Leader Schedule Computation | Parity | ⬜ VERIFY | May be fetched from RPC instead of computed locally. |
| 8 | Turbine Tree Calculation | Parity | ⬜ TODO | Uses static fanout instead of dynamic calculation. |

---

### P2 - MEDIUM (Important Enhancements)

| # | Feature | Type | Status | Notes |
|---|---------|------|--------|-------|
| 9 | Snapshot Save (Hash Fix) | Parity | ⬜ TODO | Hash computation disabled due to crash. Prevents snapshot production. |
| 10 | AF_XDP BPF Loading | Parity | ⬜ TODO | BPF loading incomplete, falls back to UDP. |
| 11 | Block Production | Parity | ⬜ STUB | Replay works but `createShreds()` and `broadcastShreds()` are stubs. |
| 12 | FEC Resolver Enhancement | Parity | ✅ DONE | Proper RS recovery implemented (2026-01-30). Uses Vandermonde matrix + GF(2^8) + Gaussian elimination. Slots completing via FEC recovery! |
| 13 | Auto-Optimizer (Complete) | **UNIQUE** | ⚠️ PARTIAL | CPU/Memory works. Need GPU detection, Network detection, IRQ affinity. |
| 14 | SnapStream Integration | **UNIQUE** | ⬜ TODO | CDN-based parallel snapshot download. Plan exists, not implemented. |

---

### P3 - LOW (Future Enhancements / Unique Features)

| # | Feature | Type | Status | Notes |
|---|---------|------|--------|-------|
| 15 | BLS Cryptography (Alpenglow) | Parity | ⬜ STUB | Structure exists, crypto operations are placeholders. |
| 16 | LLM Diagnostics | **UNIQUE** | ⬜ STUB | AI-assisted troubleshooting. All providers return "not implemented". |
| 17 | RISC-V Hybrid JIT VM | **UNIQUE** | ⬜ TODO | sBPF → RISC-V → native code. Major performance opportunity. |
| 18 | GPU Signature Verification | **UNIQUE** | ⬜ STUB | CUDA-accelerated Ed25519. `gpu_stub.zig` exists. |
| 19 | Ramdisk Tiering | **UNIQUE** | ⬜ TODO | Automatic memory tiering beyond LRU cache. |
| 20 | Thread-Safe VexStore | Enhancement | ⬜ TODO | Enable parallel store phase for faster snapshot loading. |
| 21 | Per-SSTable Lookup | Enhancement | ⬜ TODO | Reduce memory footprint by not loading all keys into RAM. |

---

### ✅ COMPLETED FEATURES

| # | Feature | Type | Completed | Notes |
|---|---------|------|-----------|-------|
| ✅ | VexStore LSM Tree | **UNIQUE** | 2026-01-29 | Full WiscKey implementation, 17x faster snapshots |
| ✅ | MemTable + putBulk | **UNIQUE** | 2026-01-29 | O(1) bulk loading bypasses sorted insert |
| ✅ | SSTable Structure | **UNIQUE** | 2026-01-29 | L0-L6 levels with metadata tracking |
| ✅ | Bloom Filters | **UNIQUE** | 2026-01-29 | Per-SSTable bloom filters, ~1% FPR |
| ✅ | Background Compaction | **UNIQUE** | 2026-01-29 | Non-blocking L0→L1 merge |
| ✅ | Value Log GC | **UNIQUE** | 2026-01-29 | Incremental garbage collection |
| ✅ | Snapshot Iterator | **UNIQUE** | 2026-01-29 | Deterministic key iteration |
| ✅ | Manifest Persistence | **UNIQUE** | 2026-01-29 | SSTable metadata survives restarts |
| ✅ | LRU Hot Cache | **UNIQUE** | 2026-01-29 | 128MB cache for frequent accounts |
| ✅ | Segmented Value Log | **UNIQUE** | 2026-01-29 | 256MB segment infrastructure |
| ✅ | Parallel Snapshot Parse | Enhancement | 2026-01-29 | 8-thread parallel AppendVec parsing |
| ✅ | SIGBUS Fix | Bug Fix | 2026-01-29 | Heap allocation instead of mmap |
| ✅ | Slot Completion Detection | Bug Fix | 2026-01-29 | Proper last_shred_index tracking |
| ✅ | TVU/TPU/Gossip | Parity | 2026-01-29 | Core networking functional |
| ✅ | Tower BFT | Parity | 2026-01-29 | Vote generation with lockouts |
| ✅ | Fork Choice | Parity | 2026-01-29 | Stake-weighted selection |
| ✅ | AccountsDB Merkle | Parity | 2026-01-29 | computeHash() implemented |

---

### Recommended Work Order

**Phase 1: Reliable Voting (P0)**
1. Fix QUIC Handshake → reliable vote delivery
2. Blockhash from Local Bank → correct vote transactions
3. Verify Vote Transaction Format

**Phase 2: Performance Parity (P1)**
4. SIMD Ed25519 → faster signature verification
5. Gossip Bloom Filter → lower bandwidth
6. AncestorHashes Repair → better fork recovery

**Phase 3: Full Validator (P2)**
7. Snapshot Save → can serve snapshots
8. Block Production → can be leader
9. Complete Auto-Optimizer

**Phase 4: Differentiation (P3)**
10. SnapStream Integration → fast cross-client catchup
11. RISC-V JIT → performance leadership
12. GPU Verification → unique capability

---

## Client Switching Scripts

### switch-client.sh

Location: `/home/sol/bin/switch-client.sh`

**Updated version (2026-01-30)** - Uses service file renaming to prevent both validators from running:

- Renames inactive service to `.disabled` so systemd cannot find/restart it
- Uses `systemctl daemon-reload` after renaming to update systemd
- Includes process verification and force-kill as backup

```bash
#!/bin/bash
set -euo pipefail

# Switch between Agave and Vexor validator clients
# Usage: switch-client.sh <agave|vexor|status>

SERVICE_DIR="/etc/systemd/system"

case "$1" in
  agave)
    echo "=== Switching to Agave ==="
    # Stop and disable Vexor
    sudo systemctl stop vexor-validator 2>/dev/null || true
    sudo mv "$SERVICE_DIR/vexor-validator.service" "$SERVICE_DIR/vexor-validator.service.disabled" 2>/dev/null || true
    # Enable and start Agave
    sudo mv "$SERVICE_DIR/solana-validator.service.disabled" "$SERVICE_DIR/solana-validator.service" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl enable solana-validator
    sudo systemctl start solana-validator
    ;;
  vexor)
    echo "=== Switching to Vexor ==="
    # Stop and disable Agave
    sudo systemctl stop solana-validator 2>/dev/null || true
    sudo mv "$SERVICE_DIR/solana-validator.service" "$SERVICE_DIR/solana-validator.service.disabled" 2>/dev/null || true
    # Enable and start Vexor
    sudo mv "$SERVICE_DIR/vexor-validator.service.disabled" "$SERVICE_DIR/vexor-validator.service" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl enable vexor-validator
    sudo systemctl start vexor-validator
    ;;
  status)
    echo "=== Service Files ==="
    ls -la "$SERVICE_DIR" | grep -E "solana|vexor" || echo "No validator services found"
    echo ""
    echo "=== Active Services ==="
    systemctl is-active solana-validator 2>/dev/null && echo "Agave: ACTIVE" || echo "Agave: inactive/disabled"
    systemctl is-active vexor-validator 2>/dev/null && echo "Vexor: ACTIVE" || echo "Vexor: inactive/disabled"
    echo ""
    echo "=== Running Processes ==="
    ps aux | grep -E "agave-validator|vexor-validator" | grep -v grep | awk '{print $11, "CPU:", $3"%", "MEM:", $4"%"}' || echo "None"
    ;;
esac
```

**Current State (2026-01-30):**
- Agave service file: `/etc/systemd/system/solana-validator.service.disabled` (DISABLED)
- Vexor service file: `/etc/systemd/system/vexor-validator.service` (ACTIVE)
- Only Vexor can run; Agave is completely disabled

### Systemd Service Files

**Agave** (`/etc/systemd/system/solana-validator.service`):
```ini
[Unit]
Description=Solana Validator
After=network.target

[Service]
Type=simple
User=sol
ExecStart=/home/sol/bin/agave-testnet-restart
Restart=on-failure
RestartSec=10
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
```

**Vexor** (`/etc/systemd/system/vexor-validator.service`):
```ini
[Unit]
Description=Vexor Validator
After=network.target

[Service]
Type=simple
User=sol
ExecStart=/home/sol/bin/vexor-testnet-restart
Restart=on-failure
RestartSec=10
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
```

### Startup Scripts

**Agave** (`/home/sol/bin/agave-testnet-restart`):
- Uses `--limit-ledger-size 50000000`
- Uses `--no-port-check` to skip UDP port verification
- Loads identity from `/home/sol/.secrets/qubetest/`

**Vexor** (`/home/sol/bin/vexor-testnet-restart`):
- Uses `--enable-parallel-snapshot --parallel-snapshot-threads 8`
- Uses `--snapshots /home/sol/restart_snapshots` (symlinked to `/mnt/vexor/snapshots`)
- Uses `--accounts /mnt/ramdisk/accounts`

---

## Testnet Info (as of 2026-01-30)

- **Current Slot:** ~384,905,000
- **Epoch:** 890
- **Shred Version:** 27350
- **Genesis Hash:** 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY

---

## Alpenglow Preparation (Future-Proofing Vexor)

Alpenglow is Solana's upcoming consensus overhaul (expected Q1 2026), providing 100x faster 
finality (12.8s → 150ms). Key components to implement in Vexor:

### Priority Components for Vexor

| # | Component | Description | Priority | Notes |
|---|-----------|-------------|----------|-------|
| 1 | **BLS Signatures** | Aggregate vote signatures | 🔴 P0 | Required for Votor. Vexor has stub in `bls_stub.zig`. |
| 2 | **Rotor Protocol** | Single-hop shred dissemination | 🔴 P0 | Replaces Turbine tree with flat relay model. |
| 3 | **Votor Voting** | Off-chain voting with certificates | 🔴 P0 | Dual-path: ≥80% fast, ≥60%+≥60% slow finality. |
| 4 | **Remove PoH** | Replace with 400ms fixed block time | 🟠 P1 | Local timeout timers instead of hash chain. |
| 5 | **Skip Certificates** | Formal slot skip mechanism | 🟠 P1 | ≥60% SkipVote produces Skip Certificate. |

### Alpenglow Key Technical Details

**Rotor (Block Propagation):**
- Single-hop relay model (replaces Turbine's 200-fanout tree)
- Each shred sent to relay → relay broadcasts to ALL nodes
- 18ms block propagation for 1500 shreds at 1Gb/s
- Natively compatible with multicast (DoubleZero)
- Shreds are single erasure-coded packets (no separate data/parity)

**Votor (Voting):**
- Off-chain votes via UDP, BLS-aggregated certificates on-chain
- Fast-Finalization: ≥80% stake in round 1 → immediate finality (~100ms)
- Slow-Finalization: ≥60% round 1 + ≥60% round 2 → finality (~150ms)
- Eliminates vote transactions (saves ~$60K/year per validator)
- "20+20" resilience: safe with 20% adversarial + 20% offline

**No More Tower BFT:**
- No exponential lockouts
- No vote transactions
- No gossip-based vote propagation
- Simplified commitment levels (confirmed = finalized)

### Reference Implementation

- **Alpenglow Reference**: https://github.com/qkniep/alpenglow (Rust)
- **Agave + Alpenglow Prototype**: https://github.com/anza-xyz/alpenglow
- **Whitepaper**: https://drive.google.com/file/d/1y_7ddr8oNOknTQYHzXeeMD2ProQ0WjMs/view

### Vexor Alpenglow Implementation Plan

**Phase 1: BLS Foundation**
- Implement BLS12-381 signatures (can use blst library bindings or pure Zig)
- Add BLS key generation and aggregation
- Reference: `deanmlittle/solana-alt-bn128-bls`

**Phase 2: Rotor Protocol**
- Modify Turbine to single-hop relay model
- Remove multi-layer tree structure
- Implement stake-weighted relay selection
- Keep Reed-Solomon erasure coding

**Phase 3: Votor Voting**
- Replace Tower BFT with Votor
- Implement Pool data structure for vote memoization
- Add certificate generation (NotarCert, FastFinalCert, FinalCert, SkipCert)
- Remove vote transactions from TPU

**Phase 4: Remove PoH**
- Replace hash-chain timing with 400ms fixed block time
- Implement local timeout timers (Δtimeout + slotIndex * Δblock)
- Remove continuous hash grinding

### Current Vexor BLS Status

File: `src/crypto/bls_stub.zig` - Contains placeholder structures:
- `BlsPublicKey`, `BlsSecretKey`, `BlsSignature` structs exist
- Operations are stubs returning errors
- Ready for real implementation

### Agave 3.0 Improvements (Available Now)

These can be implemented immediately without waiting for Alpenglow:
- **30-40% faster transaction processing** via optimized runtime
- **Program cache architecture** improvements  
- **Validator startup time halved** (200 seconds)
- **SIMD-0306**: Compute unit increases (12M → 40M per block)
- **25% larger block capacity**
