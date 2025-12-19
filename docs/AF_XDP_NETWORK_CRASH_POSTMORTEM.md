# AF_XDP Network Crash - Postmortem & Recovery Guide

**Date:** December 18, 2024  
**Severity:** Critical (Complete network outage)  
**Status:** Root cause identified, fixes applied, pending verification  

---

## Executive Summary

Multiple attempts to enable AF_XDP high-performance networking in VEXOR resulted in complete network failures, requiring out-of-band (IPMI) recovery. The root cause was identified in the eBPF XDP program logic: failed `bpf_redirect_map()` calls were causing the kernel to drop ALL packets instead of falling back to the standard network stack.

**Impact:**
- Complete SSH lockout (server unreachable)
- Required IPMI console access for recovery
- Occurred 3 times during testing

**Resolution:**
- Two-part fix implemented:
  1. Initialization order correction (socket registration before XDP attachment)
  2. eBPF fallback logic (XDP_PASS on redirect failure)
- Recovery scripts created for automatic/manual recovery
- AF_XDP currently disabled pending further testing

---

## Technical Root Cause

### The Bug

**Location:** `src/network/af_xdp/ebpf_gen.zig` lines 211-224

**Vulnerable Code:**
```zig
// LBL_REDIRECT: redirect to AF_XDP socket
code_buf[idx] = call_helper(BPF_FUNC_redirect_map);
idx += 1; // call bpf_redirect_map(r1, r2, r3)
code_buf[idx] = exit_insn;  // ❌ BUG: exits even if redirect failed!
idx += 1;
```

**What Happened:**
1. XDP program attached to network interface (enp1s0f0)
2. Incoming packet matches validator port (e.g., 8003)
3. Program calls `bpf_redirect_map(xsks_map_fd, rx_queue_index, 0)`
4. Call fails with `-ENOENT` (socket not in map for that queue)
5. Program exits with r0 = -2 (negative error code)
6. **Kernel interprets any non-XDP_PASS/XDP_TX/XDP_REDIRECT as DROP**
7. ALL packets dropped, including SSH traffic on port 22

**Why It Failed:**
- AF_XDP socket may not have been registered in XSKMAP yet (initialization race)
- Even after registration, `rx_queue_index` from packet may not match registered queue
- No fallback to kernel stack when redirect fails

---

## The Fix (Applied)

### Part 1: Initialization Order

**Files Changed:**
- `src/network/af_xdp/xdp_program.zig`
- `src/network/accelerated_io.zig`

**What Changed:**

Split XDP program initialization into two phases:

```zig
// NEW: Load program WITHOUT attaching to NIC
pub fn initWithoutAttach(allocator: Allocator, ifindex: u32, mode: AttachMode, bind_port: u16) !Self {
    // Create XSKMAP, load eBPF bytecode
    // DON'T attach to NIC yet
    return Self{ .attached = false, ... };
}

// NEW: Attach program AFTER socket is ready
pub fn attach(self: *Self) !void {
    if (self.attached) return error.AlreadyAttached;
    // NOW attach XDP program to NIC
    self.attached = true;
}
```

**Initialization Sequence (Safe Order):**
1. ✅ Create XDP program (maps + eBPF bytecode loaded)
2. ✅ Create AF_XDP socket
3. ✅ Register socket FD in XSKMAP
4. ✅ **THEN** attach XDP program to NIC

This eliminates the race condition where XDP is attached before the socket is ready.

### Part 2: eBPF Fallback Logic

**File Changed:** `src/network/af_xdp/ebpf_gen.zig`

**Fixed Code:**
```zig
// LBL_REDIRECT: redirect to AF_XDP socket with fallback
code_buf[idx] = call_helper(BPF_FUNC_redirect_map);
idx += 1; // call bpf_redirect_map(r1, r2, r3) -> result in r0
// ✅ FIX: Check if redirect failed (r0 < 0) and fallback to kernel
code_buf[idx] = jlt_imm(r0, 0, LBL_PASS);
idx += 1; // if r0 < 0, jump to LBL_PASS (fallback to kernel)
code_buf[idx] = exit_insn;  // Otherwise return r0 (successful XDP_REDIRECT)
idx += 1;
```

**What This Does:**
- ✅ If `bpf_redirect_map()` succeeds (r0 = XDP_REDIRECT = 4) → exit with r0 → packet goes to AF_XDP
- ✅ If `bpf_redirect_map()` fails (r0 < 0, e.g., -ENOENT) → jump to PASS → kernel processes packet
- ✅ Non-validator traffic (doesn't match ports) → always passes to kernel

**This is the standard pattern used in production AF_XDP programs, including Firedancer.**

### Part 3: Shared XDP Program (Multi-Socket Fix)

**File Changed:** New file `src/network/af_xdp/shared_xdp.zig` + modifications to `accelerated_io.zig` and `tvu.zig`

**Root Cause:** TVU creates TWO AF_XDP sockets (shred + repair), each creating its OWN XDP program and attaching to the same NIC. The second attachment **replaces** the first, so only the last port gets filtered.

**The Bug:**
```zig
// OLD CODE in tryStartAcceleratedIO():
// Socket 1: Creates XDP program filtering port 8003, attaches to enp1s0f0
const shred_io = createTvuIOWithQueue(..., 8003, queue:0);

// Socket 2: Creates NEW XDP program filtering port 8004, attaches to enp1s0f0
const repair_io = createTvuIOWithQueue(..., 8004, queue:1);
// ❌ Second attach REPLACES first! Now only port 8004 is filtered
```

**Fixed Architecture:**
```zig
// NEW CODE with SharedXdpManager:
// 1. Create ONE XDP program filtering ALL ports
const xdp_mgr = SharedXdpManager.init(..., &[8003, 8004, 8005]);

// 2. Create socket 1, register in shared XSKMAP
const shred_io = AcceleratedIO.init(..., .shared_xdp = xdp_mgr);

// 3. Create socket 2, register in SAME shared XSKMAP
const repair_io = AcceleratedIO.init(..., .shared_xdp = xdp_mgr);

// 4. Attach XDP program ONCE (after all sockets ready)
xdp_mgr.attach();
// ✅ ONE XDP program, filters ALL ports, routes to correct sockets via queue_id
```

**Benefits:**
- ✅ ONE XDP program attached to NIC (no conflicts)
- ✅ ALL validator ports filtered in eBPF (8003, 8004, 8005)
- ✅ ONE shared XSKMAP with all sockets registered
- ✅ Packets routed to correct socket based on `rx_queue_index`
- ✅ Clean lifecycle: create sockets → register in map → attach program

---

## Incident Timeline

### Incident #1 - December 18, 21:02 UTC
**What:** First AF_XDP enable attempt  
**Trigger:** Set capabilities, started VEXOR  
**Symptoms:** Immediate SSH lockout  
**Recovery:** IPMI console → `ip link set enp1s0f0 xdp off`  
**Diagnosis:** XDP program attached before socket registered (initialization order bug)

### Incident #2 - December 18, 21:15 UTC
**What:** Second attempt after initialization fix  
**Trigger:** Deployed fixed binary with `initWithoutAttach()`, started VEXOR  
**Symptoms:** Network came up briefly, then SSH hung after ~30 seconds  
**Recovery:** IPMI console → detach XDP, switch to Agave  
**Diagnosis:** Initialization order fixed, but redirect failures still dropping packets

### Incident #3 - December 18, 21:26 UTC
**What:** Third attempt with eBPF fallback fix  
**Trigger:** Deployed binary with `jlt_imm(r0, 0, LBL_PASS)` fallback  
**Symptoms:** Network initially responsive ("Network alive!"), then SSH commands hung  
**Recovery:** IPMI console required again  
**Diagnosis:** Fix applied but not fully verified; possible additional issue

---

## Recovery Procedures

### Immediate Recovery (IPMI Console)

When server is unreachable via SSH:

1. **Access IPMI console** (out-of-band management)
2. **Login as root**
3. **Run these commands:**
   ```bash
   # Stop validator (releases XDP)
   systemctl stop solana-validator
   
   # Detach XDP program from NIC
   ip link set enp1s0f0 xdp off
   
   # Verify XDP removed
   ip link show enp1s0f0 | grep xdp  # Should show nothing
   
   # Test connectivity
   ping -c 3 8.8.8.8
   
   # Switch to Agave (safe)
   /home/sol/scripts/switch-client.sh agave
   
   # Remove AF_XDP capabilities (prevent re-triggering)
   setcap -r /home/sol/vexor/bin/vexor-validator
   ```

4. **Verify SSH works:** Try connecting from another terminal

### Automated Recovery (xdp-watchdog.sh)

**Location:** `/home/sol/scripts/xdp-watchdog.sh`

**Usage:**
```bash
# Start watchdog BEFORE testing AF_XDP
/home/sol/scripts/xdp-watchdog.sh &
```

**What It Does:**
- Pings 8.8.8.8 every 5 seconds
- After 3 consecutive failures (~15 seconds), triggers recovery:
  - Stops solana-validator
  - Removes XDP from enp1s0f0
  - Restarts NetworkManager
  - Switches to Agave
  - Logs to `/var/log/xdp-watchdog.log`

**Script:**
```bash
#!/bin/bash
# xdp-watchdog.sh - Auto-recover from AF_XDP network failures

LOG="/var/log/xdp-watchdog.log"
FAILURES=0
MAX_FAILURES=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

log "XDP watchdog started (PID: $$)"

while true; do
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        FAILURES=$((FAILURES + 1))
        log "Ping failed (attempt $FAILURES/$MAX_FAILURES)"
        
        if [ $FAILURES -ge $MAX_FAILURES ]; then
            log "ALERT: Network failure detected! Recovering..."
            
            systemctl stop solana-validator
            ip link set enp1s0f0 xdp off
            systemctl restart NetworkManager
            sleep 3
            
            if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
                log "Network restored! Switching to Agave..."
                /home/sol/scripts/switch-client.sh agave
                log "Recovery complete. Watchdog exiting."
                exit 0
            else
                log "ERROR: Recovery failed! Manual intervention required."
                exit 1
            fi
        fi
    else
        FAILURES=0
    fi
    
    sleep 5
done
```

### Manual Recovery Script (xdp-recover.sh)

**Location:** `/home/sol/scripts/xdp-recover.sh`

**Usage:** Run from IPMI console when SSH is down
```bash
/home/sol/scripts/xdp-recover.sh
```

**Script:**
```bash
#!/bin/bash
# xdp-recover.sh - Manual XDP recovery script

echo "[XDP Recovery] Stopping validator..."
systemctl stop solana-validator

echo "[XDP Recovery] Removing XDP from enp1s0f0..."
ip link set enp1s0f0 xdp off

echo "[XDP Recovery] Restarting NetworkManager..."
systemctl restart NetworkManager
sleep 3

echo "[XDP Recovery] Testing connectivity..."
if ping -c 3 8.8.8.8; then
    echo "[XDP Recovery] ✅ Network restored!"
    echo ""
    echo "Next steps:"
    echo "1. Switch to Agave: /home/sol/scripts/switch-client.sh agave"
    echo "2. Remove capabilities: setcap -r /home/sol/vexor/bin/vexor-validator"
    echo "3. Verify SSH from remote: ssh root@38.92.24.174"
else
    echo "[XDP Recovery] ❌ Network still down! Check NIC status:"
    ip link show enp1s0f0
fi
```

---

## Testing Procedure for AF_XDP

**Before enabling AF_XDP, follow these steps:**

### Prerequisites
1. ✅ Have IPMI console access ready
2. ✅ Backup server access available
3. ✅ Current validator is stable (Agave running)
4. ✅ No active catchup or critical operations

### Safe Testing Steps

1. **Deploy Recovery Scripts** (if not already present):
   ```bash
   ssh root@38.92.24.174
   cat > /home/sol/scripts/xdp-watchdog.sh << 'EOF'
   [paste watchdog script here]
   EOF
   chmod +x /home/sol/scripts/xdp-watchdog.sh
   
   cat > /home/sol/scripts/xdp-recover.sh << 'EOF'
   [paste recovery script here]
   EOF
   chmod +x /home/sol/scripts/xdp-recover.sh
   ```

2. **Start Watchdog** (in separate SSH session):
   ```bash
   /home/sol/scripts/xdp-watchdog.sh &
   tail -f /var/log/xdp-watchdog.log
   ```

3. **Enable AF_XDP Capabilities**:
   ```bash
   setcap cap_net_raw,cap_bpf,cap_net_admin=ep /home/sol/vexor/bin/vexor-validator
   getcap /home/sol/vexor/bin/vexor-validator  # Verify
   ```

4. **Switch to VEXOR**:
   ```bash
   /home/sol/scripts/switch-client.sh vexor
   ```

5. **Monitor Logs** (in another SSH session):
   ```bash
   journalctl -u solana-validator -f | grep -E 'XDP|AF_XDP|accelerated|Program attached'
   ```

6. **Verify AF_XDP Active**:
   ```bash
   # Check XDP attachment
   ip link show enp1s0f0 | grep xdp
   
   # Should show: xdp/id:XXX
   ```

7. **Test Network Stability**:
   ```bash
   # From remote machine, continuously ping
   ping -i 1 38.92.24.174
   
   # SSH multiple times
   for i in {1..10}; do ssh root@38.92.24.174 "echo test $i"; done
   ```

8. **Check Validator Performance**:
   ```bash
   # Slot advancement
   curl -s http://localhost:8899 -X POST -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}'
   
   # AF_XDP stats (if available)
   journalctl -u solana-validator | grep -i "pps\|packets"
   ```

### Success Criteria
- ✅ SSH remains stable for 5+ minutes
- ✅ Validator slots advancing
- ✅ XDP program attached (`ip link show` shows xdp/id)
- ✅ Logs show "AF_XDP initialized" or similar
- ✅ No packet drops in kernel stats

### Failure Indicators
- ❌ SSH hangs or times out
- ❌ Watchdog triggers recovery
- ❌ Validator stops advancing slots
- ❌ Kernel logs show XDP drops

### Rollback Procedure
If AF_XDP causes issues:

```bash
# Option 1: Let watchdog auto-recover (wait ~15 seconds)

# Option 2: Manual rollback (if SSH still works)
systemctl stop solana-validator
ip link set enp1s0f0 xdp off
setcap -r /home/sol/vexor/bin/vexor-validator
/home/sol/scripts/switch-client.sh agave

# Option 3: IPMI recovery (if network is down)
# Use /home/sol/scripts/xdp-recover.sh from IPMI console
```

---

## Current Status

**As of December 18, 2024 - 22:00 UTC:**

| Component | Status | Notes |
|-----------|--------|-------|
| **Initialization Order Fix** | ✅ Applied | `initWithoutAttach()` + `attach()` pattern |
| **eBPF Fallback Fix** | ✅ Applied | `jlt_imm(r0, 0, LBL_PASS)` added |
| **Shared XDP Fix** | ✅ Applied | ONE XDP program for all sockets |
| **Binary Built** | ✅ Yes | Build successful with shared XDP |
| **AF_XDP Capabilities** | ❌ Removed | `setcap -r` to disable (currently) |
| **Recovery Scripts** | ⏸️ Need Deploy | Scripts ready, not yet on server |
| **Testing** | ⏸️ Pending | Ready for deployment with watchdog |
| **Validator** | ✅ Running | Agave (stable) |

**Why AF_XDP Is Currently Disabled:**

Despite both fixes being applied, the third test still resulted in network instability. This suggests there may be an additional issue we haven't identified yet. Until we can safely test with the watchdog script running, AF_XDP remains disabled.

**Performance Impact (AF_XDP Disabled):**
- Current: Standard UDP socket (~1-2M pps)
- Potential with AF_XDP: ~20M pps (10-20x improvement)
- Validator is functional but not at peak performance

---

## Lessons Learned

1. **Always Test with Watchdog First**
   - Don't test AF_XDP without automated recovery
   - IPMI access is critical for kernel-level issues
   - Network bugs can't be recovered via SSH

2. **eBPF Programs Need Exhaustive Fallback Logic**
   - Any unexpected return value = packet drop
   - `bpf_redirect_map()` can fail for many reasons
   - Always fallback to XDP_PASS, never drop

3. **Initialization Order Matters**
   - Socket MUST be registered before XDP attachment
   - Race conditions in kernel bypass are fatal
   - Split init into multiple phases for safety

4. **Testing in Production Is Dangerous**
   - This took down a live validator 3 times
   - Should have tested on local VM first
   - Consider staged rollout: dev → staging → prod

5. **Recovery Scripts Are Essential**
   - Create recovery scripts BEFORE testing risky features
   - Automate recovery (watchdog) when possible
   - Document manual recovery for when automation fails

---

## Next Steps

### Before Re-enabling AF_XDP:

1. **Deploy Recovery Scripts**
   ```bash
   scp xdp-watchdog.sh root@38.92.24.174:/home/sol/scripts/
   scp xdp-recover.sh root@38.92.24.174:/home/sol/scripts/
   ssh root@38.92.24.174 "chmod +x /home/sol/scripts/xdp-*.sh"
   ```

2. **Test on Dev/Staging First**
   - Replicate server environment in VM
   - Test AF_XDP with network capture (tcpdump)
   - Verify XDP_PASS fallback works as expected

3. **Add Debug Logging to eBPF**
   - Use `bpf_trace_printk()` to debug redirect failures
   - Log: queue index, XSKMAP lookups, redirect results
   - Review with `cat /sys/kernel/debug/tracing/trace_pipe`

4. **Verify XSKMAP Registration**
   - Ensure socket is registered for correct queue ID
   - Check `bpftool map dump` to see XSKMAP contents
   - Validate queue ID matches `rx_queue_index` in packets

5. **Consider Alternative Approaches**
   - Use XDP_SKB mode (slower but safer) for testing
   - Start with single port (8003) instead of all validator ports
   - Implement gradual rollout with feature flag

### Production Readiness Checklist:

- [ ] Recovery scripts deployed and tested
- [ ] Watchdog tested and verified to work
- [ ] eBPF program tested in VM environment
- [ ] Debug logging added for troubleshooting
- [ ] XSKMAP registration verified correct
- [ ] Safe rollback procedure documented
- [ ] IPMI access confirmed available
- [ ] Backup validator ready to takeover if needed
- [ ] Network monitoring in place (ping tests, packet counters)
- [ ] Off-hours maintenance window scheduled

**Do not enable AF_XDP in production until all items are checked.**

---

## References

### Code Files Modified
- `src/network/af_xdp/xdp_program.zig` - XDP program management, init order fix
- `src/network/af_xdp/ebpf_gen.zig` - eBPF bytecode generation, fallback fix
- `src/network/accelerated_io.zig` - I/O backend initialization, safe ordering

### Related Documentation
- `docs/AFXDP_PERFORMANCE_GUIDE.md` - AF_XDP architecture and performance
- `docs/EBPF_IMPLEMENTATION_GUIDE.md` - eBPF programming patterns
- `docs/RUNNING_VALIDATOR_WITHOUT_CRASHES.md` - General safety guidelines

### External Resources
- Linux XDP Documentation: https://www.kernel.org/doc/html/latest/networking/af_xdp.html
- Firedancer XDP Implementation: (reference implementation)
- BPF Helper Functions: https://man7.org/linux/man-pages/man7/bpf-helpers.7.html

---

## Contact

For questions or issues with AF_XDP:
- Check IPMI console access first
- Review `/var/log/xdp-watchdog.log` for automated recovery events
- Use `journalctl -u solana-validator | grep -i xdp` for validator logs
- Consult this document for recovery procedures

**Remember: Safety first. AF_XDP gives 10-20x performance, but only when it works correctly. A stable validator at 1M pps is better than a crashed validator at 0 pps.**
