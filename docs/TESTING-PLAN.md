# VEXOR Testing Plan (Single Source of Truth)

## Purpose
Validate one change at a time. Each phase is isolated with explicit success
criteria and rollback steps to avoid multi-variable failures.

## Global Principles
- Single change per test cycle.
- Validate both functional correctness and performance impact.
- Keep production validator stable; test on a single validator first.

## Test Environments
1. **Local dev**: unit/integration tests, log validation.
2. **Single validator**: canary test with controlled flags.
3. **Main validator**: only after success on canary.

## Status Legend
- ⏳ Planned
- 🟡 In progress
- ✅ Done
- ❌ Failed

## Test Log
Record each test run and outcome.

| Date | Phase | Status | Environment | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-01-23 | Phase 0 | ✅ | Local | Pass | Mock test mode 30s run, no crashes (log: /tmp/vexor-mock.log) |
| 2026-01-23 | Phase 3 | ❌ | Local | Fail | SO_PREFER_BUSY_POLL denied (PermissionDenied); requires elevated privileges |
| 2026-01-23 | Phase 3 | ❌ | Local | Fail | SharedXDP pinned map missing; needs `setup-xdp.sh` (AF_XDP fallback to UDP) |
| 2026-01-23 | Phase 3 | ❌ | Local | Fail | Accelerated I/O fallback hit port-in-use (io_uring bind 8001/8005); AF_XDP unavailable |
| 2026-01-23 | Phase 3 | 🟡 | Local | Pass | io_uring backend active for TVU; busy-poll still PermissionDenied |
| 2026-01-23 | Phase 0 | ❌ | Local | Fail | solana-test-validator panicked (AddrInUse) even with custom ports |
| 2026-01-23 | Phase 0 | ❌ | Local | Fail | solana-test-validator AddrInUse persists on multiple high port ranges |
| 2026-01-23 | Phase 1 | 🟡 | Local | Pass | VEXOR connected to Windows localnet RPC; gossip entrypoint ping sent |
| 2026-01-23 | Phase 1 | ✅ | Local | Pass | Localnet transfer succeeded; recipient balance = 1 SOL |
| 2026-01-23 | Phase 1 | ✅ | Local | Pass | Vote tx simulated ok and finalized; vote account shows new vote entry |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | QUIC TPU send path enabled; QUIC sends observed with UDP fallback |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | Debug localnet run w/ QUIC+H3 datagram and stream reuse; gossip ping OK; no QUIC sends observed yet |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | Force-QUIC localnet run (UDP disabled); gossip ping OK; no QUIC sends observed yet |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | QUIC-only stream mode: QUIC connect + send observed; stream reuse log hit; QUIC send error (ECONNREFUSED) + simulate AccountNotFound |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | QUIC-only retest: no crash on ECONNREFUSED; QUIC send ok; stream reuse log hit; simulate still AccountNotFound |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | AccountNotFound guard active: votes skipped with warning (vote=true id=false) instead of simulate error |
| 2026-01-23 | Phase 2 | 🟡 | Local | Pass | Identity funded: votes sent; simulate now InvalidArgument (no AccountNotFound); QUIC send ok |
| 2026-01-23 | Phase 2 | ✅ | Local | Pass | QUIC-only rerun: simulateTransaction success; vote instruction account order fixed; vote submitted via QUIC |
| 2026-01-23 | Phase 2 | ✅ | Local | Pass | Vote landed: vote account shows slot 100448 with confirmation count 1 |
| YYYY-MM-DD | Phase N | ⏳/🟡/✅/❌ | Local/Canary/Main | Pass/Fail | Links/logs |

## Phase 0 — Baseline Freeze
Tests:
- Build succeeds.
- Validator starts and maintains stable gossip connections.
- Logs show no crash loops or repeated errors.
Acceptance:
- Stable running state for 30+ minutes.

Checklist:
- [ ] Build succeeds
- [ ] Stable gossip for 30+ minutes
- [ ] No crash loops in logs

## Phase 1 — Vote Landing Reliability
Tests:
- Verify TPU_VOTE port usage in logs.
- Confirm vote account `lastVote` increases.
- Check root advancement.
Commands:
- `solana vote-account <vote_pubkey> --url http://localhost:8899`
Acceptance:
- Sustained vote landing for 30+ minutes.
Rollback:
- Revert to baseline build if votes stop landing.

Checklist:
- [ ] TPU_VOTE port appears in logs
- [ ] lastVote increases
- [ ] rootSlot advances
- [ ] No vote send errors

## Phase 2 — QUIC Transport
Tests:
- QUIC session establishment to TPU leaders.
- Send votes/txs via QUIC and confirm no protocol errors.
- UDP fallback remains functional.
Acceptance:
- QUIC path stable; UDP fallback works.
Rollback:
- Disable QUIC transport and revert to UDP.

Checklist:
- [ ] QUIC handshake success
- [ ] QUIC send success
- [ ] UDP fallback verified
- [ ] Error rates acceptable
- [ ] Connection management stable under load (no reconnect storms)

## Phase 3 — IO/Kernel Optimizations
Tests:
- AF_XDP path vs io_uring ZC RX path benchmark.
- Busy poll settings validation (no packet loss, no stalls).
Metrics:
- p99 latency, CPU utilization, packet drops.
Acceptance:
- Reduced latency and CPU without instability.
Rollback:
- Disable busy poll or ZC RX.

Checklist:
- [ ] AF_XDP baseline benchmarked
- [ ] ZC RX benchmarked (if supported)
- [ ] ZC RX prerequisites verified (NIC header/data split, flow steering, RSS)
- [ ] Busy poll validated
- [ ] p99 latency improved
- [ ] No increase in packet drops

## Phase 4 — Alpenglow Readiness
Tests:
- BLS aggregation PoC correctness.
- Rotor relay prototype in a test cluster.
Acceptance:
- Functional PoC with clean fallback.
Rollback:
- Keep features behind flags until mainnet-ready.

Checklist:
- [ ] BLS aggregation PoC passes
- [ ] Rotor relay prototype passes
- [ ] Feature flags verified
- [ ] BLS certificate format validated against spec references

## Phase 5 — Sig/Firedancer Integration
Tests:
- Precompile conformance tests (Sig).
- Syscall equivalence checks.
Acceptance:
- Conformance results match reference expectations.
Rollback:
- Feature-flag integration until stable.

Checklist:
- [ ] Precompile tests pass
- [ ] Syscall equivalence confirmed
- [ ] AccountsDB/gossip memory usage regression check (if adopted)

## Release Checklist (Each Phase)
1. Build validated.
2. Canary validator testing complete.
3. Main validator testing complete.
4. Rollback plan verified.

