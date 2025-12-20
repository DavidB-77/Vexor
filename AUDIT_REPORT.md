# VEXOR vs Firedancer Comparative Code Audit Report

**Date:** December 2024  
**Auditor:** Claude (Anthropic)  
**Scope:** Network, Consensus, Runtime, and Storage layers
**Status:** UPDATED - Bugs Fixed

---

## ✅ FIXES APPLIED

The following **critical bugs** have been fixed in this session:

### Fix 1: Leader TPU Lookup Now Implemented
**Files:** `src/network/tpu_client.zig`, `src/runtime/root.zig`

The `getLeaderTpu()` function was a TODO stub. Now it:
1. Gets leader pubkey from LeaderScheduleCache
2. Looks up leader's ContactInfo from GossipTable  
3. Returns the leader's TPU address
4. Caches results for future lookups

### Fix 2: TpuClient Connected to LeaderScheduleCache
**File:** `src/runtime/root.zig`

The TPU client now receives a reference to `replay_stage.leader_cache` during initialization.

### Fix 3: VoteSubmitter Uses sendVote() for Redundancy
**File:** `src/runtime/bootstrap.zig`

Changed from `sendTransaction()` to `sendVote()` which sends to multiple consecutive leaders for redundancy.

---

## Executive Summary

This audit compares VEXOR (Zig-based Solana validator) against Firedancer (Jump Crypto's reference C implementation). The analysis reveals **several critical issues** that explain VEXOR's inability to achieve CURRENT voting status on testnet.

### Severity Summary
| Severity | Count | Description |
|----------|-------|-------------|
| 🔴 Critical | 4 | Will prevent validator from working correctly |
| 🟠 High | 6 | Significant functionality gaps |
| 🟡 Medium | 8 | Performance or reliability concerns |
| 🟢 Low | 5 | Code quality / minor improvements |

---

## Critical Issues (Must Fix)

### 🔴 C1: QUIC Implementation is a Placeholder

**Location:** `src/network/quic/transport.zig`

**Finding:** VEXOR's QUIC implementation is NOT RFC 9000/9001 compliant. It's essentially a simplified UDP wrapper with a custom wire format.

**Evidence:**
```zig
fn performHandshake(self: *Connection) !void {
    // QUIC Initial packet with TLS ClientHello
    // For now, simplified handshake
    _ = self;
    // In real implementation: [comments listing what's needed]
}
```

**Firedancer Reference:** `waltz/quic/fd_quic.c` provides full RFC compliance with:
- TLS 1.3 integration via `fd_tls.h`
- 4 encryption levels (Initial, Handshake, 0-RTT, 1-RTT)
- ACK generation with coalescing (`ack_delay`, `ack_threshold`)
- RTT estimation (`fd_rtt_estimate_t`)
- Flow control (tx_max_data, rx_max_data per stream)
- Retry tokens for address validation
- 17+ specific error codes per RFC 9000

**Missing in VEXOR:**
- ❌ No TLS 1.3 handshake
- ❌ No crypto key derivation
- ❌ No packet number spaces
- ❌ No ACK generation
- ❌ No congestion control
- ❌ No retransmission logic
- ❌ No retry tokens

**Impact:** Vote transactions sent via "QUIC" are actually going over raw UDP with no reliability guarantees. This is why votes weren't being recognized on-chain.

**Fix:** Complete rewrite of QUIC layer or use existing Zig QUIC library (e.g., `zig-quic`).

---

### 🔴 C2: TPU Client Uses UDP Only for Vote Submission

**Location:** `src/network/tpu_client.zig`, `src/runtime/bootstrap.zig` (VoteSubmitter)

**Finding:** The TPU client only uses UDP sockets, not QUIC. Vote transactions are sent unreliably.

**Evidence:**
```zig
// tpu_client.zig:159
fn sendUdp(self: *Self, tx_data: []const u8, addr: packet.SocketAddr) !void {
    const sock = self.udp_socket orelse return error.NoSocket;
    _ = std.posix.sendto(sock, tx_data, 0, @ptrCast(&sockaddr.in.sa), ...);
}
```

**Firedancer Reference:** TPU uses QUIC streams for reliable delivery:
- `disco/quic/fd_tpu_tile.c` - proper QUIC stream management
- Transaction batching on streams
- Flow control and backpressure

**Impact:** Votes may be lost in transit, explaining DELINQUENT status even when votes are "submitted."

**Recommended Fix:**
```zig
// Use QUIC streams for votes (pseudo-code)
pub fn sendVoteQuic(self: *Self, vote_tx: []const u8, slot: core.Slot) !void {
    const conn = try self.quic_transport.connect(tpu_addr);
    const stream = try conn.openStream(.critical);
    defer stream.close();
    try stream.write(vote_tx);
    try stream.waitAck(); // Ensure delivery
}
```

---

### 🔴 C3: Blockhash Fetched via HTTP RPC Instead of Local Bank

**Location:** `src/runtime/bootstrap.zig:869-900` (VoteSubmitter.fetchBlockhashFromRpc)

**Finding:** VoteSubmitter fetches recent blockhash from external RPC (api.testnet.solana.com) instead of using the local bank's blockhash.

**Evidence:**
```zig
fn fetchBlockhashFromRpc(self: *Self) !core.Hash {
    var client = http.Client{ .allocator = self.allocator };
    const uri = std.Uri.parse("https://api.testnet.solana.com") catch ...;
    // ... HTTP POST to external server
}
```

**Problems:**
1. **Latency:** ~50-200ms network round-trip per blockhash
2. **Rate Limits:** RPC endpoints may rate-limit
3. **Stale Data:** External RPC may be slots behind
4. **Content-Type Bug:** Missing header caused failures (fixed but symptomatic)

**Firedancer Reference:** Uses local bank state for blockhash:
```c
// Vote transactions use the bank's blockhash directly
fd_hash_t const * recent_blockhash = fd_bank_recent_blockhash( bank );
```

**Recommended Fix:**
```zig
fn getRecentBlockhash(self: *Self) core.Hash {
    // Use local bank's blockhash (always fresh, no network call)
    if (self.replay_stage.root_bank) |bank| {
        return bank.blockhash;
    }
    // Fallback only if bank not ready
    return self.fallbackBlockhash();
}
```

---

### 🔴 C4: Vote Transaction Format May Be Incorrect

**Location:** `src/consensus/vote_tx.zig`, `src/runtime/bootstrap.zig:819`

**Finding:** The TowerSync/CompactUpdateVoteState instruction encoding needs verification against Agave's actual format.

**Evidence from vote_tx.zig:**
```zig
// Instruction discriminator (compact_update_vote_state = 12)
try ix_data.appendSlice(&std.mem.toBytes(@as(u32, 12)));
// Lockout slots
try ix_data.append(@intCast(votes.len)); // compact-u16 for small values
```

**Potential Issues:**
1. `compact-u16` encoding may not match Solana's exact format
2. Missing vote state hash validation
3. Sysvar addresses may be incorrect (hardcoded bytes)
4. Missing proper signature verification structure

**Firedancer Reference:** Uses exact bincode serialization matching Agave:
- `flamenco/runtime/program/fd_vote_program.c`
- Proper compact-u16/u64 encoding
- Correct sysvar account addresses

**Recommended Fix:** 
1. Capture a working vote transaction from Agave
2. Byte-for-byte compare with VEXOR's output
3. Use Solana's transaction decoder to verify format

---

## High Priority Issues (Should Fix)

### 🟠 H1: Gossip Missing Proper CRDS Bloom Filter

**Location:** `src/network/gossip.zig`

**Finding:** Pull requests don't include proper bloom filter for efficient CRDS synchronization.

**Evidence:** `sendPullRequest` doesn't construct bloom filter:
```zig
fn sendPullRequest(self: *Self, target: packet.SocketAddr) !void {
    // Builds pull request WITHOUT bloom filter
    const len = bincode.buildPullRequestWithContactInfo(&pkt.data, ...);
}
```

**Firedancer Reference:** `disco/gossip/fd_gossip.c` uses bloom filters to avoid redundant data transfer.

**Impact:** Excessive bandwidth usage, slower peer discovery.

---

### 🟠 H2: Shred Signature Verification Not Using Batch Ed25519

**Location:** `src/runtime/shred.zig:181-185`

**Finding:** Shred signatures verified individually, not batched.

```zig
pub fn verifySignature(self: *const Shred, leader_pubkey: *const core.Pubkey) bool {
    const signed_data = self.payload[64..];
    return crypto.verify(&self.common.signature, leader_pubkey, signed_data);
}
```

**Firedancer Reference:** Uses batched Ed25519 verification with AVX-512:
- `waltz/ed25519/avx512/fd_ed25519_verify_batch.c`
- ~10x throughput improvement

**Impact:** CPU bottleneck during high shred rates.

---

### 🟠 H3: FEC Resolver Simplified vs Firedancer's Full Implementation

**Location:** `src/runtime/fec_resolver.zig`

**Finding:** VEXOR's FEC resolver exists but is simplified. Missing:
- Proper Reed-Solomon decoding
- Memory pooling for FEC sets
- Parallel decoding

**Firedancer Reference:** `disco/shred/fd_fec_resolver.c` - highly optimized with pre-allocated memory.

---

### 🟠 H4: Repair Protocol Missing AncestorHashes Request Type

**Location:** `src/network/repair.zig`

**Finding:** AncestorHashes repair type defined but not implemented:
```zig
pub const RepairType = enum(u8) {
    AncestorHashes = 3, // Defined but handleRequest doesn't process it
};
```

**Impact:** Cannot verify fork ancestry, potential for following wrong fork.

---

### 🟠 H5: Leader Schedule Fetched from RPC Instead of Computed

**Location:** `src/runtime/bootstrap.zig:228-231`

**Finding:** Leader schedule fetched via HTTP RPC instead of computed from stake distribution.

```zig
replay_stage.leader_cache.fetchFromRpc(rpc_url, snapshot_slot) catch |err| {
    std.log.warn("[Bootstrap] Could not fetch leader schedule: {} ...", .{err});
};
```

**Impact:** Network dependency, potential for stale/incorrect leader schedule.

---

### 🟠 H6: Turbine Tree Calculation Uses Static Fanout

**Location:** `src/network/tvu.zig:691-708`

**Finding:** Turbine retransmit calculation uses fixed fanout of 200 instead of stake-weighted tree.

```zig
pub fn calculateRetransmitPeers(...) !void {
    const fanout: usize = 200; // Should be stake-weighted
    // ...
}
```

**Firedancer Reference:** `disco/shred/fd_shred_dest.c` computes stake-weighted turbine tree.

**Impact:** Suboptimal shred propagation, higher latency.

---

## Medium Priority Issues

### 🟡 M1: No Pre-allocation in Hot Paths

**Finding:** Many hot paths use dynamic allocation (ArrayList, HashMap) instead of pre-allocated buffers.

**Example:** `PacketBatch.init` allocates on every call.

**Recommendation:** Use fixed-size ring buffers or pre-allocated pools like Firedancer.

---

### 🟡 M2: Missing Metrics Infrastructure

**Finding:** VEXOR has basic stats but no comprehensive metrics system.

**Firedancer Reference:** `fd_quic_metrics_t` with 30+ tracked metrics including histograms.

---

### 🟡 M3: AccountsDb Missing Merkle Hash Computation

**Location:** `src/storage/accounts.zig:87-91`

```zig
pub fn computeHash(self: *Self) !core.Hash {
    _ = self;
    // TODO: Merkle tree over sorted accounts
    return core.Hash.ZERO;
}
```

**Impact:** Cannot produce valid snapshots or verify bank hashes.

---

### 🟡 M4: Bank Transaction Processing Incomplete

**Location:** `src/runtime/bank.zig`

**Finding:** Transaction processing is stubbed:
- Missing proper fee calculation
- Missing CPI (Cross-Program Invocation) support
- Missing compute budget enforcement

---

### 🟡 M5: No Connection Pooling/Reuse

**Finding:** Each send creates new UDP connection instead of reusing.

---

### 🟡 M6: Gossip wallclock Updates Not Frequent Enough

**Finding:** Firedancer rejects messages with wallclock >15s old. VEXOR updates before each send, but cache duration may be too long.

---

### 🟡 M7: Missing Snapshot Production Capability

**Finding:** VEXOR can load snapshots but cannot produce them.

---

### 🟡 M8: AF_XDP Socket Setup May Fail Silently

**Location:** `src/network/tvu.zig:229-314`

**Finding:** AF_XDP setup falls back to UDP without clear logging of why.

---

## Low Priority / Code Quality

### 🟢 L1: Inconsistent Error Handling

**Finding:** Mix of `catch {}`, `catch |err|`, and `catch continue` patterns.

**Recommendation:** Standardize error handling strategy.

---

### 🟢 L2: Debug Print Statements in Production Code

**Finding:** Many `std.debug.print` calls that should be `std.log` for proper logging levels.

---

### 🟢 L3: Magic Numbers

**Finding:** Several hardcoded values without named constants:
- Port offsets
- Timeout values
- Buffer sizes

---

### 🟢 L4: Test Coverage Gaps

**Finding:** Many modules have minimal tests. Critical paths like vote submission untested.

---

### 🟢 L5: Documentation Gaps

**Finding:** Some modules well-documented, others lack context for design decisions.

---

## Recommended Fixes - Priority Order

### Immediate (Required for Voting)

1. **Fix Vote Submission Path:**
   - Use local bank blockhash instead of RPC
   - Verify TowerSync transaction format byte-by-byte against Agave
   - Add proper delivery confirmation

2. **Implement Basic QUIC:**
   - At minimum, use proper QUIC library for TPU connections
   - Or: Ensure UDP votes go to multiple leaders for redundancy

3. **Validate Vote Transaction Format:**
   - Capture working vote tx from Agave
   - Compare serialization byte-by-byte
   - Fix any encoding differences

### Short Term (Week 1-2)

4. Add batch Ed25519 verification for shreds
5. Implement proper leader schedule computation
6. Fix gossip bloom filter for pulls
7. Add metrics infrastructure

### Medium Term (Week 2-4)

8. Full QUIC implementation or integration
9. Proper FEC resolver with Reed-Solomon
10. Accounts hash computation
11. Snapshot production

---

## Architecture Comparison

| Component | Firedancer | VEXOR | Gap |
|-----------|------------|-------|-----|
| QUIC | Full RFC 9000/9001 | Placeholder | Critical |
| TPU | QUIC streams | UDP only | Critical |
| TVU | AF_XDP + FEC | AF_XDP + basic FEC | Medium |
| Gossip | Full CRDS | Partial CRDS | Medium |
| Repair | Full protocol | Basic | Medium |
| Tower BFT | Full | Reasonable | Low |
| Fork Choice | Stake-weighted | Stake-weighted | Low |
| Bank | Complete | Partial | High |
| Accounts | Append-only | Basic | High |
| Snapshots | Full | Load only | Medium |

---

## Conclusion

VEXOR has a solid architectural foundation with proper tile/service separation, good use of Zig idioms, and working implementations of several components. However, **critical gaps in the network layer (especially QUIC and vote submission) prevent it from functioning as a voting validator**.

The most impactful fixes are:
1. Proper vote transaction construction and delivery
2. Local blockhash usage
3. Real QUIC implementation

With these fixes, VEXOR should be able to achieve CURRENT status on testnet.

---

*This audit was conducted by analyzing source code only. Runtime testing would provide additional insights.*
