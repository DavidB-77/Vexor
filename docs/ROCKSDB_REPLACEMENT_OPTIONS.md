# RocksDB Replacement Options (VEXOR)

## Purpose
Consolidate research on replacing RocksDB in the VEXOR storage stack with a
better-performing option suitable for prosumer hardware (5–10GbE, 64–128GB RAM).
This document is separate from the roadmap/testing docs and focused on storage.

## Related Design Spec
- VexStore detailed design: `VEXSTORE_DESIGN_SPEC.md`

## Current Storage Context
Existing research already outlines a custom LSM and tiered storage strategy.
See: `/home/dbdev/solana-client-research/architecture/03-STORAGE-DEEP-DIVE.md`.

## Requirements
- Zig-native or Zig-friendly integration (FFI acceptable short-term).
- Better write amplification and compaction behavior than RocksDB.
- Predictable tail latency for validator workloads.
- Compatible with NVMe-first, RAM-tiered architecture.
- GPU acceleration is a later phase (not required now).

## Short-Term Drop-In Options (Zig-Compatible)

### 1) Speedb (RocksDB fork)
Pros:
- Drop-in replacement with improvements for write-heavy workloads.
- Better QoS under some IO patterns.
Cons:
- Still C++ and FFI overhead.
- Performance gains depend on workload.
Sources:
- https://docs.speedb.io/readme/releases
- https://smalldatum.blogspot.com/2024/12/speedb-vs-rocksdb-on-large-server.html

### 2) RocksDB via Zig bindings
Pros:
- Immediate integration via Zig bindings.
- Stable, battle-tested.
Cons:
- Still RocksDB performance and compaction limitations.
Sources:
- https://github.com/Syndica/rocksdb-zig

Recommendation:
- If we need a fast stopgap, Speedb via rocksdb-zig is lowest risk.

## Mid-Term Custom Build (Recommended)

### VexStore (WiscKey-Style)
Key idea: separate keys (LSM) from values (append-only log).
Benefits:
- Lower write amplification than classic LSM.
- Compaction only touches keys, not large values.
- Better SSD usage, less GC pressure.
Sources:
- https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf
- https://dl.acm.org/doi/10.1145/3033273

Proposed VexStore features:
- Key LSM + value log (WiscKey-inspired).
- Parallel compaction.
- io_uring backend for async reads/writes.
- Optional future GPU indexing (later phase).

## Long-Term / Emerging Candidates (Research-Only)

### 1) TidesDB (LSM alternative)
Reports higher write throughput and lower amplification vs RocksDB.
Source:
- https://tidesdb.com/articles/benchmark-analysis-tidesdb6-rocksdb1075/

### 2) Learned/Hybrid Index Stores
Academic designs like learned indexes show improvements but lack production maturity.
Source:
- https://arxiv.org/abs/2406.18099

### 3) Pebble (Design Reference)
Pure Go implementation of RocksDB concepts (useful as a blueprint).
Source:
- https://github.com/petermattis/pebble

## Zig Integration Considerations
- Short-term: FFI to Speedb/RocksDB is feasible.
- Mid-term: Zig-native VexStore provides full control and optimal performance.
- Long-term: consider selective borrow of concepts from Pebble and research systems.

## Suggested Evaluation Plan

### Phase A: Benchmark Drop-In
- Speedb via rocksdb-zig vs current RocksDB.
- Metrics: write amplification, compaction time, p99 latency, CPU per op.

### Phase B: Prototype VexStore Core
- Implement key LSM + value log.
- Bench against Speedb on validator-like workloads.

### Phase C: Integrate with AccountsDB/Blockstore
- Replace storage layer under `src/storage/`.
- Validate snapshot creation and hash correctness.

## Decision Matrix (Summary)

| Option | Short-Term Risk | Long-Term Potential | Zig Fit |
| ------ | --------------- | ------------------ | ------- |
| Speedb | Low | Medium | Medium (FFI) |
| RocksDB + tuning | Low | Low | Medium (FFI) |
| VexStore (WiscKey) | Medium | High | High (native) |
| TidesDB | Medium | Unknown | Low |

## Recommendation
1) Use Speedb as a temporary drop-in if immediate gains are needed.
2) Build VexStore (WiscKey-style) as the long-term, Zig-native solution.
3) Keep TidesDB and learned-index systems as research references only.

