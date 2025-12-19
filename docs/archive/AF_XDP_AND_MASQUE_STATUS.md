# AF_XDP and MASQUE/QUIC Status - December 15, 2024

## Current Status

### AF_XDP (Kernel Bypass Networking) ✅ CAPABILITIES SET - NEEDS RESTART

**Issue**: AF_XDP socket creation is failing, causing fallback to io_uring (~3M pps instead of ~10M pps).

**Root Cause**: Binary lacks required Linux capabilities (`cap_net_raw` and `cap_net_admin`).

**Evidence from Logs**:
```
debug: [AF_XDP] Socket creation test failed - not available
info: [AcceleratedIO] Using io_uring backend (~3M pps)
[TVU] AF_XDP not available, falling back to standard UDP
```

**System Status**:
- ✅ Kernel: 6.1.0-40-amd64 (supports AF_XDP - requires 4.18+)
- ✅ BPF JIT: Enabled (1)
- ✅ Binary capabilities: **NOW SET** (`cap_net_admin,cap_net_raw=ep`)

**Fix Required**:
```bash
sudo setcap cap_net_raw,cap_net_admin+ep /home/solana/bin/vexor/vexor
```

**Expected After Fix**:
```
╔══════════════════════════════════════════════════════════╗
║  TVU STARTED WITH AF_XDP ACCELERATION ⚡                  ║
║  Port: 9004                                               ║
║  Expected: ~10M packets/sec                              ║
╚══════════════════════════════════════════════════════════╝
```

---

### MASQUE/QUIC/HTTP3 ⚠️ NOT INITIALIZED

**Status**: MASQUE and QUIC components are implemented but not initialized in the runtime.

**Current State**:
- ✅ **Code exists**: `src/network/masque/`, `src/network/quic/`
- ✅ **Build option**: `-Dmasque=true` (disabled by default)
- ❌ **Runtime initialization**: Not called in `src/runtime/root.zig`
- ❌ **Configuration**: No CLI flags or config options for MASQUE

**What's Implemented**:
1. **MASQUE Protocol** (`src/network/masque/`):
   - Client (`MasqueClient`) - Connect through MASQUE proxies
   - Server (`MasqueServer`) - Run MASQUE proxy
   - Protocol handlers (CONNECT-UDP, CONNECT-IP)
   - UDP/IP tunneling

2. **QUIC Transport** (`src/network/quic/`):
   - Full QUIC implementation with automatic transport selection
   - MASQUE bridge for tunneling QUIC through proxies
   - Stream/datagram handling
   - TLS 1.3 encryption

3. **Integration Points**:
   - `src/network/root.zig` exports MASQUE/QUIC types
   - `src/network/quic/masque_bridge.zig` provides transparent proxying

**Why Not Initialized**:
- MASQUE is an **optional feature** for specific use cases:
  - Dashboard streaming through firewalls
  - NAT traversal for gossip
  - Secure metrics collection
  - RPC access through corporate networks
- Not required for basic validator operation
- Should be initialized only when explicitly enabled

**When to Enable**:
- Running validator behind NAT/firewall
- Need to tunnel gossip/RPC through corporate proxy
- Dashboard streaming to external aggregator
- Multi-validator metrics collection

**How to Enable** (when needed):
1. Build with MASQUE: `zig build -Dmasque=true`
2. Add MASQUE initialization in `src/runtime/root.zig`:
   ```zig
   // In initializeNetworking()
   if (self.config.enable_masque) {
       self.masque_client = try network.MasqueClient.init(self.allocator, .{
           .proxy_host = self.config.masque_proxy_host,
           .proxy_port = self.config.masque_proxy_port,
       });
   }
   ```
3. Add config options:
   - `--masque-proxy-host`
   - `--masque-proxy-port`
   - `--enable-masque`

---

## Summary

| Component | Status | Performance Impact | Action Required |
|-----------|--------|-------------------|-----------------|
| **AF_XDP** | ✅ Capabilities Set | Needs restart to activate | Restart Vexor to verify |
| **io_uring** | ✅ Working | 3M pps (fallback) | None |
| **MASQUE** | ⚠️ Not Initialized | N/A (optional) | Initialize if needed |
| **QUIC** | ⚠️ Not Initialized | N/A (optional) | Initialize if needed |
| **Gossip** | ✅ Working | 978 peers connected | None |
| **TPU Client** | ✅ Working | Vote submission ready | None |
| **TVU** | ✅ Working | Receiving shreds | None |

---

## Immediate Action Items

### Priority 1: Fix AF_XDP ✅ COMPLETE
```bash
# ✅ DONE: Capabilities are now set
sudo getcap /home/solana/bin/vexor/vexor
# Shows: /home/solana/bin/vexor/vexor = cap_net_admin,cap_net_raw=ep
```

**Next Step**: Restart Vexor to activate AF_XDP. The current running process was started before capabilities were set, so it's still using io_uring fallback.

### Priority 2: Verify Build Configuration
Check if binary was built with AF_XDP enabled:
```bash
# On dev machine
cd /home/dbdev/solana-client-research/vexor
zig build -Doptimize=ReleaseFast -Daf_xdp=true
```

### Priority 3: MASQUE/QUIC (Optional)
Only needed if:
- Validator is behind NAT/firewall
- Need to tunnel traffic through proxy
- Dashboard streaming required

---

## References

- **AF_XDP**: `src/network/af_xdp/root.zig`
- **MASQUE**: `src/network/masque/root.zig`
- **QUIC**: `src/network/quic/root.zig`
- **AcceleratedIO**: `src/network/accelerated_io.zig`
- **TVU**: `src/network/tvu.zig` (line 172-187)

---

## Testing After Fix

1. **AF_XDP Verification**:
   ```bash
   # Check logs for:
   ╔══════════════════════════════════════════════════════════╗
   ║  TVU STARTED WITH AF_XDP ACCELERATION ⚡                  ║
   ```

2. **Performance Check**:
   - Monitor packet reception rate
   - Should see ~10M pps capability (vs 3M with io_uring)

3. **MASQUE/QUIC** (if enabled):
   - Check for MASQUE client/server initialization logs
   - Verify QUIC transport creation
   - Test tunnel connectivity

