# VexStore Design Specification (Zig-Native Storage Engine)

## Purpose
Design a Zig-native storage engine to replace RocksDB for VEXOR’s AccountsDB
and related validator storage needs, optimized for prosumer hardware
(5–10GbE, 64–128GB RAM, NVMe-first).

This spec focuses on:
- Maximum TPS on prosumer hardware
- Predictable tail latency
- Low write amplification
- Efficient snapshot/hash generation
- Zig-native implementation (no C++/FFI for core path)

## Non-Goals (Initial Phase)
- GPU acceleration (future phase)
- Cross-language portability
- Multi-datacenter replication

## High-Level Architecture
VexStore is a **WiscKey-style** KV store:
- Keys in an LSM tree
- Values in an append-only value log

This reduces write amplification by keeping large values out of LSM compaction.

References:
- WiscKey paper (FAST'16): https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf
- WiscKey ACM: https://dl.acm.org/doi/10.1145/3033273

## Data Model
### Keys
- Account pubkey (32 bytes)
- Composite keys for versioning: `pubkey || slot` (optional MVCC)

### Values
- Fixed-size Account metadata (128 bytes aligned)
- Variable-size account data stored in Value Log

## Storage Components

### 1) MemTable (Write Buffer)
- In-memory sorted structure (skiplist or B-tree)
- Stores key -> value_log_ptr + metadata
- Flushes to SSTables when size threshold reached

### 2) LSM Tree (Keys Only)
- SSTables store key -> value_log_ptr
- Bloom filters per SSTable
- Leveled compaction (L0 -> L1 -> L2)
- Compaction touches only keys, not values

### 3) Value Log (Append-Only)
- Writes raw account data to log
- Log-structured, sequential writes
- Value pointers stored in LSM
- Garbage collection compacts log

### 4) Manifest / WAL
- Manifest tracks SSTables and levels
- WAL provides crash recovery for MemTable
- WAL can be simplified with append-only log

## Write Path
1. Write record to WAL
2. Append value to Value Log
3. Insert key -> value_ptr in MemTable
4. Flush MemTable to SSTable when full
5. Background compaction merges SSTables

## Read Path
1. Check Hot Cache (RAM)
2. Search MemTable
3. Search SSTables (newest to oldest) with bloom filter
4. Read value from Value Log via pointer

## Compaction Strategy
- Leveled compaction on key tables only
- No value rewrite during compaction
- Value log GC handles stale values

## Value Log GC
- Scan value log segments
- For each record, check if key still maps to this value_ptr
- If stale, drop
- If live, rewrite to new segment

## Tiered Storage Integration
VexStore integrates with the existing tiered design:
- Hot: RAM cache for frequently accessed accounts
- Warm: memory-mapped value log on NVMe
- Cold: compressed archive (future)

Reference:
- `/home/dbdev/solana-client-research/architecture/03-STORAGE-DEEP-DIVE.md`

## Snapshots and Hashing
- Maintain deterministic iteration order of keys
- Generate Merkle hash over sorted keys
- Snapshot captures LSM state + value log offsets
- Incremental snapshots from value log segments

## Concurrency Model
- Single-writer (for determinism) with multiple readers
- Background threads for compaction and GC
- Separate IO threads for value log

## IO Backend
Initial: standard pread/pwrite with async thread pool  
Future: io_uring backend with fixed buffers

Reference:
- io_uring ZC RX (future potential): https://www.kernel.org/doc/html/next/networking/iou-zcrx.html

## On-Disk Layout (Proposed)
```
vexstore/
  manifest
  wal/
    wal-0001.log
  sst/
    L0-0001.sst
    L1-0002.sst
  vlog/
    segment-0001.vlog
    segment-0002.vlog
```

## Interfaces (Zig)
```zig
pub const VexStore = struct {
    pub fn init(alloc: Allocator, path: []const u8) !*VexStore;
    pub fn get(self: *VexStore, key: []const u8) ?[]const u8;
    pub fn put(self: *VexStore, key: []const u8, value: []const u8) !void;
    pub fn delete(self: *VexStore, key: []const u8) !void;
    pub fn flush(self: *VexStore) !void;
    pub fn snapshot(self: *VexStore) !Snapshot;
    pub fn deinit(self: *VexStore) void;
};
```

## Benchmarks and Metrics
Measure:
- Write amplification (target < 5x)
- p99 read/write latency
- Compaction time
- GC overhead
- CPU per op

## Migration Path
1. Prototype VexStore with unit tests
2. Benchmark vs RocksDB/Speedb
3. Integrate into AccountsDB
4. Validate snapshot hash correctness

## Alternative Options (Reference Only)
See `ROCKSDB_REPLACEMENT_OPTIONS.md` for:
- Speedb
- TidesDB
- Pebble

## References
- WiscKey (FAST'16): https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf
- WiscKey ACM: https://dl.acm.org/doi/10.1145/3033273
- Pebble (design reference): https://github.com/petermattis/pebble
- Speedb releases: https://docs.speedb.io/readme/releases
- RocksDB Zig bindings: https://github.com/Syndica/rocksdb-zig

