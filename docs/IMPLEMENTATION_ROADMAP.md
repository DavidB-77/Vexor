# VEXOR Implementation Roadmap (Single Source of Truth)

## Purpose
This roadmap sequences new features and integrations for VEXOR so we can validate
one change at a time and avoid multi-variable regressions. It aligns with the
goal: a Zig validator client that is faster or equal to the best clients, while
remaining viable on prosumer hardware (5–10GbE minimum).

## Constraints and Targets
- Hardware: prosumer-grade (5–10GbE NICs, not 25GbE-only).
- Performance: competitive with Agave/Firedancer on practical hardware.
- Reliability: each change must be individually verifiable and reversible.

## Working assumptions
- We optimize for highest performance without degrading network stability on devnet/testnet/mainnet.
- When details are ambiguous, we choose the safest high-performance default and document it.
- Snapshot metadata is flushed automatically after snapshot load; snapshot save will also flush once implemented.

## Current Baseline (Local Status)
- Core validator pipeline exists (gossip, TVU, replay, vote submission).
- Known gaps historically: QUIC compliance, vote landing, leader schedule parsing.
- AF_XDP and io_uring scaffolding present; QUIC transport is placeholder.

## Research-Driven Priorities
### Alpenglow (Consensus Rewrite)
- Votor: fast/slow vote paths, off-chain vote certificate aggregation (BLS).
- Rotor: single-hop relay propagation replacing Turbine tree.
Sources: [Helius Alpenglow overview](https://helius.dev/blog/alpenglow),
[Blockworks SIMD-0326 vote](https://blockworks.co/news/solana-validators-commence-vote-alpenglow)

### Firedancer
- fd_quic is high-performance and essentially complete.
Source: [Firedancer QUIC announcement](https://solanafloor.com/news/firedancer-unveils-fd_quic-a-high-performance-implementation-of-quic-and-solana-transaction-ingest-network-protocols)

### Sig (Zig validator reference)
- Mature runtime/VM/precompiles with Firedancer/Agave cross-validation.
Sources: [Sig repo](https://github.com/Syndica/sig),
[Sig runtime update](https://blog.syndica.io/sig-engineering-part-8-sigs-svm-and-runtime/)

### Emerging Networking/IO (Not widely adopted by validators)
- io_uring zero-copy RX (ZC RX) for receive path.
  Source: [io_uring ZC RX docs](https://www.kernel.org/doc/html/next/networking/iou-zcrx.html)
- SO_PREFER_BUSY_POLL for low-latency UDP/QUIC paths.
  Source: [LWN busy poll](https://lwn.net/Articles/837010/)
- Threaded NAPI busy poll for stable low-latency tails.
  Source: [LWN threaded NAPI busy poll](https://lwn.net/Articles/1035645/)
- AF_XDP busy-polling and need_wakeup tuning.
  Source: [DPDK AF_XDP guide](https://doc.dpdk.org/guides-24.11/nics/af_xdp.html)

### Additional Research Updates
- Firedancer QUIC tile / network architecture reference (connection management, AF_XDP integration).
  Source: [Firedancer Net Tile](https://docs.firedancer.io/guide/internals/net_tile.html)
- Sig AccountsDB buffer pool and gossip memory optimizations (storage + networking efficiency).
  Sources: [Sig AccountsDB & Gossip optimizations](https://blog.syndica.io/sig-engineering-part-7-accountsdb-gossip-memory-optimizations/),
  [Sig runtime update](https://blog.syndica.io/sig-engineering-part-8-sigs-svm-and-runtime/)

### Emerging Tech Candidates (Ranked for 5–10GbE)
1. io_uring ZC RX (if NIC supports header/data split and flow steering).
2. SO_PREFER_BUSY_POLL (low-latency UDP/QUIC path).
3. Threaded NAPI busy poll (P99 latency stability).
4. AF_XDP need_wakeup/busy_budget tuning (CPU efficiency).
5. XDP-accelerated QUIC patterns (e.g., s2n-quic-xdp design patterns).
   Source: [s2n-quic-xdp](https://docs.rs/s2n-quic-xdp/latest/s2n_quic_xdp/)

## Roadmap Phases (One-at-a-time changes)

## Status Legend
- ⏳ Planned
- 🟡 In progress
- ✅ Done
- ❌ Blocked

## Progress Log
Add entries as we complete work. Keep each entry short.

| Date | Phase | Status | Summary | Notes |
| --- | --- | --- | --- | --- |
| YYYY-MM-DD | Phase N | ⏳/🟡/✅/❌ | Short summary | Links/logs |

### Phase 0 — Baseline Freeze
Goal: Lock the last known good baseline so we can compare.
- Tag the baseline commit and build artifacts.
- Verify we can start/stop cleanly and that logs are stable.
Acceptance:
- No regressions in startup and gossip connectivity.
- Build is repeatable.

Checklist:
- [ ] Baseline commit tagged
- [ ] Build artifacts captured
- [ ] 30+ minute stable run verified
- [ ] Logs reviewed and archived

### Phase 1 — Vote Landing Reliability
Goal: Ensure votes land on-chain with correct TPU routing.
Scope:
- TPU_VOTE port parsing and routing.
- Leader lookup validation/logging.
Acceptance:
- Votes are sent to TPU_VOTE port (not TPU).
- Vote account root and lastVote advance steadily.
Rollback:
- Revert to baseline if votes stop landing.

Checklist:
- [ ] TPU_VOTE port confirmed in logs
- [ ] Vote account root advances
- [ ] lastVote increases steadily
- [ ] No vote queue growth

### Phase 2 — QUIC Transport (Primary TPU Path)
Goal: Replace UDP-only ingest with QUIC (Solana default).
Scope:
- Implement QUIC session establishment and stream send for TPU.
- Add minimal QoS/flow control compatibility.
Acceptance:
- Transactions/votes send via QUIC with no protocol errors.
- No regression in UDP fallback.

Checklist:
- [ ] QUIC handshake succeeds
- [ ] QUIC send path active
- [ ] UDP fallback verified
- [ ] No QUIC protocol errors

### Phase 3 — IO/Kernel Optimizations (Prosumer)
Goal: Lower CPU cost and latency on 5–10GbE.
Scope:
- Evaluate AF_XDP vs io_uring ZC RX on target NICs.
- Enable SO_PREFER_BUSY_POLL / threaded NAPI where supported.
Acceptance:
- Packet processing latency improves without instability.
- CPU utilization per packet decreases.

Checklist:
- [ ] AF_XDP baseline collected
- [ ] io_uring ZC RX benchmarked (if supported)
- [ ] NIC capability check for ZC RX (header/data split, flow steering, RSS)
- [ ] Busy poll settings validated
- [ ] p99 latency improvement measured

### Phase 4 — Alpenglow Readiness
Goal: Prepare VEXOR to migrate early.
Scope:
- BLS aggregation pipeline for Votor.
- Rotor-style relay propagation design (single-hop).
Acceptance:
- Prototype path for off-chain vote certificates.
- Rotor relay PoC in controlled test.

Checklist:
- [ ] BLS aggregation PoC complete
- [ ] Votor vote flow modeled
- [ ] Rotor relay prototype tested
- [ ] BLS certificate format documented
- [ ] Feature-flagged for safety

### Phase 5 — Sig/Firedancer Integration Candidates
Goal: Adopt proven components without redesigning VEXOR.
Scope:
- Sig precompiles, syscalls, crypto routines.
- Firedancer-compatible QUIC patterns.
Acceptance:
- Conformance tests pass where applicable.

Checklist:
- [ ] Precompile parity validated
- [ ] Syscall behavior parity validated
- [ ] QUIC behavior aligned with reference

## Integration Shortlist (High Value, Low Risk)
1. Sig precompiles (ed25519/secp256k1/secp256r1).
2. Sig syscall semantics for CPI/memory/ECC.
3. Firedancer-inspired QUIC behavior and flow control.

## Notes on Prosumer Hardware
We will favor approaches that:
- Scale on 5–10GbE NICs.
- Avoid high-cost NIC offloads.
- Use CPU pinning and IRQ affinity as needed.

## Change Management
Every phase must include:
- A dedicated test plan entry.
- Clear success criteria.
- Clear rollback steps.

