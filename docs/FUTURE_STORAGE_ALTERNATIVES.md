# Future Storage Engine Alternatives

**Status:** Research / Future Enhancement  
**Priority:** Medium (after core validator is stable)  
**Created:** December 14, 2024

---

## Current State

Vexor currently uses a custom storage layer with:
- **AccountsDb** - In-memory with disk persistence
- **LedgerDb** - Basic key-value storage for blocks/shreds
- **RAM Disk Tiering** - Hot data in tmpfs, cold data on NVMe

RocksDB is the standard in Agave/Solana Labs, but we have an opportunity to improve.

---

## Alternatives to Evaluate

### 1. Speedb ⭐ (Recommended First Choice)

**Website:** https://speedb.io/  
**License:** Apache 2.0 (Open Source)

**Pros:**
- ✅ 100% drop-in replacement for RocksDB
- ✅ Better stability and QoS (less throughput variance)
- ✅ Higher throughput for write-heavy, I/O-bound workloads
- ✅ Reduced Write Amplification Factor (WAF) - critical for validators
- ✅ Minimal integration work

**Cons:**
- ⚠️ Similar average throughput to RocksDB in some benchmarks
- ⚠️ Less battle-tested than RocksDB

**Integration Effort:** LOW (drop-in replacement)

---

### 2. TerarkDB

**Website:** https://github.com/bytedance/terarkdb  
**License:** Apache 2.0 (with proprietary algorithms)

**Pros:**
- ✅ Full binary compatibility with RocksDB
- ✅ Increased storage capacity
- ✅ Improved retrieval speeds
- ✅ Good for ledger and accounts data

**Cons:**
- ⚠️ Proprietary algorithms (ByteDance)
- ⚠️ Less public benchmarks in Solana context
- ⚠️ May have less community support

**Integration Effort:** LOW (drop-in replacement)

---

### 3. SplinterDB

**Website:** https://github.com/vmware/splinterdb  
**License:** Apache 2.0

**Pros:**
- ✅ 6-10x faster insertions than RocksDB
- ✅ Fully utilizes NVMe SSD bandwidth
- ✅ Significantly reduced write amplification
- ✅ Excellent for high-write workloads (perfect for validators)

**Cons:**
- ❌ NOT a drop-in replacement - different architecture
- ❌ "Significant limitations" per authors
- ❌ Not recommended for production yet
- ❌ Sacrifices small range query performance

**Integration Effort:** HIGH (major rewrite needed)

---

### 4. Custom Zig-Native Storage Engine (Long-term)

**Concept:** Build a storage engine specifically optimized for Solana validators

**Pros:**
- ✅ Zero FFI overhead (pure Zig)
- ✅ Tailored for Solana access patterns
- ✅ Integration with AF_XDP / io_uring
- ✅ Perfect alignment with Vexor architecture

**Cons:**
- ❌ Significant development effort
- ❌ Need to solve all the hard problems (compaction, recovery, etc.)

**Could incorporate:**
- LSM-tree with optimized compaction
- Direct io_uring integration
- Memory-mapped B+ trees for hot data
- Append-only journal for crash recovery

**Integration Effort:** VERY HIGH (6+ months of dedicated work)

---

## Solana-Specific Requirements

Any storage engine for Solana validators needs:

1. **High Write Throughput** - Thousands of account updates per second
2. **Low Write Amplification** - NVMe wear is a concern
3. **Fast Point Lookups** - Account reads by pubkey
4. **Range Scans** - For program-owned accounts
5. **Crash Recovery** - Must not lose committed state
6. **Concurrent Access** - Multiple threads reading/writing
7. **Memory Efficiency** - Validators have limited RAM

---

## Recommended Approach

### Phase 1: Speedb Drop-in (Short-term)
- Swap RocksDB for Speedb in Agave fork
- Benchmark on testnet
- If successful, integrate bindings into Vexor

### Phase 2: Evaluate TerarkDB (Medium-term)
- Compare TerarkDB vs Speedb
- Choose winner for production

### Phase 3: Custom Engine R&D (Long-term)
- Start prototyping Zig-native engine
- Target specific Solana access patterns
- Consider hybrid approach (RAM + NVMe tiering)

---

## Related Files

- `src/storage/accounts.zig` - Current accounts storage
- `src/storage/ledger.zig` - Current ledger storage
- `src/storage/tiered_storage.zig` - RAM disk tiering

---

## Notes

- Write Amplification Factor (WAF) in RocksDB is typically 10-30x
- Speedb claims to reduce this significantly
- SplinterDB claims near 1x WAF but not production-ready
- Firedancer uses custom storage, not RocksDB


