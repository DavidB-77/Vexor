# Vexor CPU Pinning Strategy

**Status:** Implementing  
**Priority:** HIGH (significant performance impact)  
**Created:** December 14, 2024  
**Research Source:** Firedancer docs.firedancer.io

---

## Firedancer's "Tile" Architecture (Reference)

Firedancer achieves 1M+ TPS by using a **tile-based architecture** where each component runs as a dedicated thread pinned to a specific CPU core. This eliminates context switching and cache thrashing.

### Firedancer Tile Types

| Tile | Count | Throughput/Tile | Purpose |
|------|-------|-----------------|---------|
| `net` | 1 | >1M TPS | Packet RX/TX via AF_XDP |
| `quic` | 1 | >1M TPS | QUIC connection management |
| `verify` | 6 | 20-40K TPS | Signature verification |
| `dedup` | 1 | - | Duplicate transaction filtering |
| `resolv` | 1 | - | Address lookup table resolution |
| `pack` | 1 | - | Block packing (CRITICAL - isolated) |
| `bank` | 4 | 20-40K TPS | Transaction execution |
| `poh` | 1 | - | PoH hashing (CRITICAL - isolated) |
| `shred` | 1 | - | Block distribution |
| `store` | 1 | - | Ledger I/O (RocksDB) |
| `sign` | 1 | - | Signing requests |
| `metric` | 1 | - | Metrics collection |

**Total: ~18 tiles = 18 dedicated cores**

### Critical Firedancer Findings

1. **Pack and PoH tiles MUST be isolated** - Even their hyperthread pairs should be disabled
2. **Tiles never sleep** - They spin-wait on queues, so they need 100% of their core
3. **Communication via shared memory** - No syscalls between tiles
4. **Backpressure propagates** - A slow tile can stall the entire pipeline
5. **verify tiles scale linearly** - Add more until no transactions are dropped
6. **bank tiles have diminishing returns** - Lock contention in runtime

### Firedancer Affinity String Format

```toml
[layout]
  affinity = "f1,0-1,2-4/2,f1"  # tile 0 floats, 1->core 0, 2->core 1, etc.
  agave_affinity = "17-31"      # Agave subprocess gets these cores
```

---

## Vexor Tile Mapping

Based on Firedancer's proven approach, here's how Vexor components map:

| Vexor Component | Firedancer Equivalent | Priority | Recommended Cores |
|-----------------|----------------------|----------|-------------------|
| `poh_verifier.zig` | poh | **CRITICAL** | 1 isolated |
| `af_xdp.zig` (RX) | net | HIGH | 1 isolated |
| `af_xdp.zig` (TX) | net | HIGH | 1 isolated |
| `ed25519.zig` | verify | HIGH | 4-6 pooled |
| `quic.zig` | quic | HIGH | 1-2 pooled |
| `gossip.zig` | (agave) | MEDIUM | 1 shared |
| `bank.zig` | bank | HIGH | 4-6 pooled |
| `replay_stage.zig` | pack | HIGH | 1-2 shared |
| `tvu.zig` | shred | MEDIUM | 1-2 shared |
| `ledger.zig` | store | LOW | 1 shared |
| `metrics.zig` | metric | LOW | floating |
| `snapshot.zig` | (load) | LOW | floating |

---

## Hardware Profiles

### Consumer Hardware (Target for Vexor)

**AMD Ryzen 9 7950X3D (16 cores, 32 threads)**
```
Cores 0-7:   CCD0 (with 3D V-Cache - great for PoH!)
Cores 8-15:  CCD1 (standard cache)

Recommended Layout:
- Core 0:  OS Reserved
- Core 1:  PoH (isolated, on 3D V-Cache CCD!)
- Core 2:  AF_XDP RX
- Core 3:  AF_XDP TX
- Cores 4-7:  Signature verification (4 threads)
- Cores 8-11: Bank execution (4 threads)
- Core 12: QUIC
- Core 13: Gossip + TVU
- Core 14: Replay Stage
- Core 15: Background (ledger, metrics, snapshots)
```

**Intel Core i9-14900K (24 cores: 8 P-cores, 16 E-cores)**
```
P-cores 0-7:   Performance cores (high clock, AVX-512)
E-cores 8-23:  Efficiency cores (lower clock)

Recommended Layout:
- P-core 0:  OS Reserved
- P-core 1:  PoH (isolated, P-core for speed!)
- P-core 2:  AF_XDP RX
- P-core 3:  AF_XDP TX
- P-cores 4-7:  Signature verification (4 threads)
- E-cores 8-15: Bank execution (8 threads)
- E-core 16: QUIC
- E-core 17: Gossip
- E-core 18: TVU
- E-core 19: Replay Stage
- E-cores 20-23: Background
```

### Server Hardware (Firedancer Baseline)

**AMD EPYC 7513 (32 cores)**
```
Firedancer Default:
- Cores 1-16:  Firedancer tiles (affinity = "1-16")
- Cores 17-31: Agave subprocess (agave_affinity = "17-31")
```

---

## Implementation for Vexor

### Phase 1: Core Affinity Module

Create `src/core/affinity.zig`:

```zig
const std = @import("std");
const linux = std.os.linux;

pub const TileType = enum {
    poh,           // PoH hashing - CRITICAL isolated
    af_xdp_rx,     // Packet receive
    af_xdp_tx,     // Packet transmit
    verify,        // Signature verification (pooled)
    bank,          // Transaction execution (pooled)
    quic,          // QUIC connections
    gossip,        // Gossip protocol
    tvu,           // Shred handling
    replay,        // Replay stage
    ledger,        // Ledger I/O
    metrics,       // Metrics collection
    background,    // Low priority tasks
};

pub const CoreAffinity = struct {
    total_cores: u32,
    numa_nodes: u32,
    
    // Critical isolated cores
    poh_core: ?u8,
    af_xdp_rx_core: ?u8,
    af_xdp_tx_core: ?u8,
    
    // Pooled cores
    verify_cores: []const u8,
    bank_cores: []const u8,
    
    // Shared cores
    quic_core: ?u8,
    gossip_core: ?u8,
    tvu_core: ?u8,
    replay_core: ?u8,
    ledger_core: ?u8,
    
    // Floating (OS scheduler)
    floating_cores: []const u8,
    
    pub fn detect(allocator: std.mem.Allocator) !CoreAffinity {
        // Read /proc/cpuinfo or /sys/devices/system/cpu/
        const cpu_count = try std.Thread.getCpuCount();
        // ... detect NUMA topology
        // ... auto-assign based on hardware
    }
    
    pub fn pinCurrentThread(core: u8) !void {
        var mask: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
        mask.__bits[core / 64] |= @as(u64, 1) << @intCast(core % 64);
        
        const rc = linux.sched_setaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
        if (rc != 0) return error.AffinityFailed;
    }
    
    pub fn setThreadPriority(priority: i32) !void {
        // SCHED_FIFO for critical tiles
        const param = linux.sched_param{ .sched_priority = priority };
        const rc = linux.sched_setscheduler(0, linux.SCHED_FIFO, &param);
        if (rc != 0) return error.PriorityFailed;
    }
};
```

### Phase 2: Configuration

```toml
# vexor.toml
[cpu]
# Auto-detect optimal pinning (default)
auto = true

# Manual override (advanced users)
# poh_core = 1
# af_xdp_rx_core = 2
# af_xdp_tx_core = 3
# verify_cores = [4, 5, 6, 7]
# bank_cores = [8, 9, 10, 11]

# Disable hyperthreads on critical cores
disable_hyperthreads = true

# Use SCHED_FIFO for critical tiles
realtime_priority = true
```

### Phase 3: Installer Integration

The installer should:
1. **Detect CPU topology** (cores, NUMA nodes, hyperthreads)
2. **Recommend optimal layout** based on hardware
3. **Offer to disable hyperthreads** on critical cores
4. **Configure CPU governor** for performance mode
5. **Set up cgroups** if needed for isolation

---

## Other Performance Optimizations

Beyond CPU pinning, Firedancer uses these techniques:

### 1. Huge Pages (Already Planned)
```bash
# Allocate 1GB huge pages for UMEM
echo 512 > /proc/sys/vm/nr_hugepages
mount -t hugetlbfs none /mnt/.fd/.gigantic -o pagesize=1G
```

### 2. NUMA-Aware Memory
- Allocate memory on same NUMA node as pinned CPU
- Use `mbind()` or `libnuma`

### 3. Disable Turbo Boost Variance
```bash
# Lock CPU frequency to max for consistent latency
echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

---

## C-States (CPU Sleep States) - CRITICAL FOR POH

### What Are C-States?

| State | Name | Wake Latency | Power | Description |
|-------|------|--------------|-------|-------------|
| C0 | Active | 0 | High | CPU executing instructions |
| C1 | Halt | ~1µs | Medium | CPU halted, clocks running |
| C2 | Stop-Clock | ~10µs | Low | Clocks stopped |
| C3 | Sleep | ~100µs | Very Low | L1/L2 cache flushed |
| C6+ | Deep Sleep | ~200µs+ | Minimal | Most state lost |

### Why C-States Break PoH

PoH (Proof of History) must hash continuously at a consistent rate (~400ns per hash).

**Problem:** If the PoH core enters C3+, it takes 100-200µs to wake up.
- PoH expects to complete ~250 hashes in 100µs
- Instead, it does 0 hashes while sleeping
- Result: **Missed slots, dropped leader opportunities**

### How to Fix

**Option 1: Runtime (Temporary)**
```bash
# Disable C-states deeper than C1 on all cores
for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do
    echo 1 | sudo tee $state
done
```

**Option 2: Boot Parameter (Permanent)**
```bash
# Edit /etc/default/grub
GRUB_CMDLINE_LINUX="processor.max_cstate=1 intel_idle.max_cstate=1"

# Then:
sudo update-grub
sudo reboot
```

**Option 3: PoH Core Only (Recommended)**
```bash
# Only disable C-states on core 1 (PoH core)
echo 1 > /sys/devices/system/cpu/cpu1/cpuidle/state2/disable
echo 1 > /sys/devices/system/cpu/cpu1/cpuidle/state3/disable
echo 1 > /sys/devices/system/cpu/cpu1/cpuidle/state4/disable
```

### Tradeoffs

| Approach | Power Cost | Safety | Effectiveness |
|----------|------------|--------|---------------|
| Disable all C-states | High (+50W) | Safe | 100% |
| PoH core only | Low (+5W) | Safe | 95% |
| Kernel params | Medium | Requires reboot | 100% |

---

## IRQ Pinning (Interrupt Affinity) - CRITICAL FOR AF_XDP

### The Problem

When your NIC receives a packet:
1. NIC generates IRQ (interrupt request)
2. Linux kernel wakes a CPU to handle it
3. By default, `irqbalance` spreads IRQs across all cores

If AF_XDP RX thread is on core 2, but IRQ fires on core 7:
- Data lands in core 7's cache
- Core 2 needs it → **cache miss** → 100+ cycle penalty
- At 5M packets/sec, this adds up!

### The Solution

Pin NIC IRQs to the same cores as AF_XDP:

```bash
# 1. Find your NIC's IRQs
cat /proc/interrupts | grep eth0
#   42:    12345    0    0    0   PCI-MSI-edge   eth0-TxRx-0
#   43:    12346    0    0    0   PCI-MSI-edge   eth0-TxRx-1

# 2. Pin IRQ 42 to core 2 (AF_XDP RX)
echo 2 > /proc/irq/42/smp_affinity_list

# 3. Pin IRQ 43 to core 3 (AF_XDP TX)  
echo 3 > /proc/irq/43/smp_affinity_list

# 4. Stop irqbalance from undoing your work
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance
```

### For Multi-Queue NICs

Modern NICs have multiple queues. Set them to match your AF_XDP cores:

```bash
# Check current queues
ethtool -l eth0

# Set to 2 queues (matching 2 AF_XDP cores)
sudo ethtool -L eth0 combined 2

# Set RSS (Receive Side Scaling) to distribute evenly
sudo ethtool -X eth0 equal 2
```

### Vexor Installer Checks

The installer now detects:
- `CPU007`: Deep C-states enabled
- `CPU008`: NIC IRQs spread across cores
- `CPU009`: Kernel not tuned for low-latency
- `CPU010`: Low-latency params already configured

---

## Kernel Parameters for Ultimate Performance

For maximum performance, add these to `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX="isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 processor.max_cstate=1"
```

| Parameter | Effect |
|-----------|--------|
| `isolcpus=1-3` | Exclude cores 1-3 from normal scheduler |
| `nohz_full=1-3` | Disable timer tick on isolated cores |
| `rcu_nocbs=1-3` | Move RCU callbacks off isolated cores |
| `processor.max_cstate=1` | Limit to C1 sleep state |

**After editing:**
```bash
sudo update-grub
sudo reboot
```

⚠️ **WARNING:** These are advanced optimizations. Test on non-production first!

---

### 6. Network Optimizations
- Disable GRO (Generic Receive Offload) for XDP
- Set NIC queues to match net tile count
- Enable BPF JIT

---

## Installer Audit Checklist

The installer should check and offer to fix:

| Check | Issue ID | Auto-Fix |
|-------|----------|----------|
| CPU core count | CPU001 | Info only |
| NUMA topology | CPU002 | Info only |
| Hyperthreading status | CPU003 | `echo 0 > /sys/devices/system/cpu/cpuX/online` |
| CPU governor | CPU004 | `cpupower frequency-set -g performance` |
| Huge pages | MEM001 | `sysctl -w vm.nr_hugepages=512` |
| C-States | CPU005 | kernel param `idle=poll` |
| IRQ balance | NET001 | `systemctl stop irqbalance` |
| SCHED_FIFO capability | CPU006 | `setcap cap_sys_nice+ep` |

---

## Consumer vs Server Trade-offs

### Consumer Hardware Advantages
- ✅ Lower cost
- ✅ AMD 3D V-Cache excellent for PoH
- ✅ High single-core performance
- ❌ Fewer cores (16-24)
- ❌ Less memory bandwidth
- ❌ Single NUMA node

### Server Hardware Advantages
- ✅ More cores (32-128)
- ✅ More memory bandwidth
- ✅ ECC memory
- ✅ Multiple NUMA nodes
- ❌ Higher cost
- ❌ Sometimes lower single-core speed

### Vexor's Goal
Make consumer hardware competitive by:
1. **Smarter pinning** - Fewer cores used more efficiently
2. **Better algorithms** - Zig's comptime optimization
3. **Zero-copy everything** - AF_XDP, io_uring, mmap
4. **No GC pauses** - Unlike Rust/Go validators

---

## References

- Firedancer Configuring: https://docs.firedancer.io/guide/configuring.html
- Firedancer Tuning: https://docs.firedancer.io/guide/tuning.html
- Firedancer default.toml: https://github.com/firedancer-io/firedancer/blob/main/src/app/fdctl/config/default.toml
- Linux sched_setaffinity: https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html

