# Vexor Debugging Rules & Reference Guide

## CRITICAL DEBUGGING APPROACH

When debugging or implementing Solana protocol features, ALWAYS:

### 1. Reference Firedancer (Primary C Reference)
- **Location**: `/home/dbdev/external/firedancer/`
- **Key directories**:
  - `src/flamenco/gossip/` - Gossip protocol implementation
  - `src/flamenco/repair/` - Repair protocol
  - `src/flamenco/runtime/` - Runtime/replay
  - `src/flamenco/shred/` - Shred processing
- **Why**: Firedancer is in C, which is nearly identical to Zig semantically. Their implementations are battle-tested and correct.

### 2. Use MCPs for Research
- **Solana MCP**: `mcp_vexor-core_solana__*` - For protocol questions, documentation search
- **Zig MCP**: `mcp_vexor-core_zig__*` or `mcp_research_context7__*` - For Zig patterns
- **Firecrawl MCP**: `mcp_research_firecrawl__*` - For deep web research on protocols
- **Memory MCP**: Store key findings for later reference

### 3. Verify Against Spec
- Solana gossip spec: https://github.com/eigerco/solana-spec
- Always check bincode serialization format matches exactly

### 4. Check Firedancer for:
- Exact message formats (struct layouts)
- Signature computation (what data gets signed)
- Validation logic (what causes messages to be rejected)
- Timing requirements (ping/pong intervals, timeouts)

---

## CURRENT ISSUES LOG

### ✅ FIXED: Peer Connection Issue (Dec 15, 2024)
**Status**: RESOLVED
**Symptom**: Vexor not connecting to gossip peers (0 peers) despite receiving PUSH messages
**Root Cause**: Using regular varint instead of Solana's compact_u16 for ContactInfo parsing
**Fix**: Changed address count, socket count, and port offset parsing to use compact_u16
**Result**: 978 peers connected, 7,292 CRDS values received
**Files**: `src/network/gossip.zig` (parseModernContactInfo), `src/runtime/shred.zig` (error handling)
**Reference**: Firedancer `fd_gossip_msg_parse.c:465, 499, 512` and `fd_compact_u16.h`

### Issue: Ping/Pong Signature Mismatch (Dec 14, 2024)
**Status**: INVESTIGATING
**Symptom**: We receive PONGs from entrypoints responding to our PONGs, but they don't respond to our PINGs
**Discovery**: 
- Firedancer signs ONLY the 32-byte `ping_token` for PING messages
- Our code signs `from + token` (64 bytes)
- This is likely why entrypoints ignore our PINGs

**Firedancer Reference**:
```c
// fd_gossip.c line 779
gossip->sign_fn( gossip->sign_ctx, out_ping->ping_token, 32UL, FD_KEYGUARD_SIGN_TYPE_ED25519, out_ping->signature );
```

---

## KNOWN CORRECT VALUES

### Testnet
- Shred Version: 9604
- Entrypoints: 
  - entrypoint.testnet.solana.com:8001 (35.203.170.30:8001)
  - entrypoint2.testnet.solana.com:8001 (109.94.99.177:8001)

### Default Ports (Agave/Firedancer)
- Gossip: 8001
- TPU: 8000
- TVU: 8003
- Repair: 8006
- Serve Repair: 8007
- RPC: 8899
- *Note*: Custom ports (like our 9001) are allowed

---

## USEFUL GREP PATTERNS FOR FIREDANCER

```bash
# Find ping/pong handling
grep -r "ping\|pong" /home/dbdev/external/firedancer/src/flamenco/gossip/

# Find signing logic
grep -r "sign_fn\|sign_ctx" /home/dbdev/external/firedancer/src/flamenco/gossip/

# Find message serialization
grep -r "serialize\|encode" /home/dbdev/external/firedancer/src/flamenco/gossip/

# Find pull request handling
grep -r "pull_request\|PULL" /home/dbdev/external/firedancer/src/flamenco/gossip/
```

