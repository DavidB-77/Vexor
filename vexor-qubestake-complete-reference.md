# VEXOR QubeStake Validator - Complete Technical Reference
## Master Documentation for Claude Opus 4.5 in Cursor IDE

**Version:** 1.0  
**Last Updated:** December 17, 2025  
**Author:** QubeShare Team  
**Status:** Phase 2 Complete - Validator Operational

---

# TABLE OF CONTENTS

1. [Project Overview](#1-project-overview)
2. [Current System Status](#2-current-system-status)
3. [Server Access & Credentials](#3-server-access--credentials)
4. [File System Layout](#4-file-system-layout)
5. [Hardware Specifications](#5-hardware-specifications)
6. [Operating System Configuration](#6-operating-system-configuration)
7. [All Applied Optimizations](#7-all-applied-optimizations)
8. [Validator Configuration](#8-validator-configuration)
9. [Monitoring Setup](#9-monitoring-setup)
10. [Backup Infrastructure](#10-backup-infrastructure)
11. [Phase 3: VEXOR Build Plan](#11-phase-3-vexor-build-plan)
12. [Phase 4: VexStore Custom Storage](#12-phase-4-vexstore-custom-storage)
13. [Phase 5: GPU Acceleration](#13-phase-5-gpu-acceleration)
14. [Cursor IDE Optimization](#14-cursor-ide-optimization)
15. [Troubleshooting & Recovery](#15-troubleshooting--recovery)
16. [Quick Reference Commands](#16-quick-reference-commands)

---

# 1. PROJECT OVERVIEW

## What is VEXOR?

VEXOR is a custom Solana validator client being developed by QubeShare to match or exceed Firedancer's performance. The project has multiple phases:

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | System Tuning & Optimization | ✅ Complete |
| Phase 2 | Agave Validator Deployment | ✅ Complete |
| Phase 3 | VEXOR Initial Build (Zig) | ⏳ Planned |
| Phase 4 | VexStore Custom Storage | ⏳ Planned |
| Phase 5 | GPU Acceleration | ⏳ Planned |

## Project Goals

1. **Match Firedancer Performance** - Target 1M+ TPS capability
2. **Reduce Hardware Costs** - Through software optimization (30-40% savings potential)
3. **Custom Storage Engine** - Replace RocksDB with GPU-accelerated VexStore
4. **Zig-Native Implementation** - Zero-overhead, direct hardware control

## Key Technologies

- **Language:** Zig (for VEXOR), Rust (current Agave)
- **Networking:** QUIC, MASQUE, eBPF/AF_XDP
- **I/O:** io_uring for async operations
- **Crypto:** AVX-512 SIMD, GPU batch verification
- **Storage:** Custom LSM-tree (VexStore)

---

# 2. CURRENT SYSTEM STATUS

## Validator Identity

```yaml
Network: Testnet
Identity Pubkey: 3J2jADiEoKMaooCQbkyr9aLnjAb5ApDWfVvKgzyK2fbP
Vote Account: BfXryoEG8XEsdi4YBpSA7iWgs2BZfVxBM6xXCnreDC8n
Validator Name: v1.qubestake.io
Commission: 100%
```

## Current Software Versions

```yaml
Operating System: Fedora 43 Server
Kernel: 6.17.11-300.fc43.x86_64
Validator Client: Agave 3.1.4
Solana CLI: 3.1.4
Rust: Latest stable
Telegraf: Latest
```

## Service Status

| Service | Status | Command |
|---------|--------|---------|
| solana-validator | ✅ Running | `systemctl status solana-validator` |
| telegraf | ✅ Running | `systemctl status telegraf` |
| nic-tuning | ✅ Running | `systemctl status nic-tuning` |

---

# 3. SERVER ACCESS & CREDENTIALS

## Primary Validator Server

```yaml
Hostname: qubestake
IP Address: 38.92.24.174
SSH Port: 22
Location: Datacenter (co-located)
```

## SSH Access

```bash
# Connect as root
ssh root@38.92.24.174

# Connect as sol user
ssh sol@38.92.24.174
```

## Users

| User | Purpose | Home Directory |
|------|---------|----------------|
| root | System administration | /root |
| sol | Validator operations | /home/sol |

## Backup VPS

```yaml
IP Address: 148.230.81.56
Provider: Hostinger
User: solsnap
Purpose: Emergency backups, snapshot storage
```

```bash
# Connect to backup VPS
ssh solsnap@148.230.81.56
```

---

# 4. FILE SYSTEM LAYOUT

## Critical Directories

```
/home/sol/
├── agave/
│   └── bin/
│       └── agave-validator      # Validator binary
├── keypairs/
│   ├── validator-keypair.json   # Identity key (CRITICAL)
│   ├── vote-account-keypair.json # Vote account key (CRITICAL)
│   └── authorized-withdrawer-keypair.json
├── ledger/                      # Blockchain data (~100GB+)
├── accounts-ramdisk -> /mnt/ramdisk  # Symlink to ramdisk
├── logs/
│   └── validator.log            # Main validator log
├── monitoring/                  # thevalidators.io scripts
│   ├── output_starter.sh
│   ├── monitoring_config.py
│   ├── output_validator_measurements.py
│   └── bin/                     # Python venv
└── validator.sh                 # Startup script

/mnt/ramdisk/                    # 64GB tmpfs for accounts
/etc/telegraf/telegraf.conf      # Telegraf configuration
/etc/sysctl.d/99-solana-validator.conf  # Kernel tuning
/etc/security/limits.d/99-solana.conf   # User limits
/usr/local/bin/tune-nic.sh       # NIC tuning script
/usr/local/bin/pin-irqs.sh       # IRQ pinning script
```

## Solana CLI Location

```bash
# For sol user
/home/sol/.local/share/solana/install/active_release/bin/solana

# Add to PATH (in ~/.bashrc)
export PATH="/home/sol/.local/share/solana/install/active_release/bin:$PATH"
```

---

# 5. HARDWARE SPECIFICATIONS

## CPU

```yaml
Model: AMD Ryzen 9 7950X3D
Cores: 16 physical / 32 threads
Architecture: Zen 4 with 3D V-Cache
Base Clock: 4.2 GHz
Boost Clock: 5.7 GHz
L3 Cache: 128MB (96MB 3D V-Cache + 32MB standard)
Features: AVX-512, AMD-V, SMT
```

## Memory

```yaml
Total RAM: 128GB DDR5
Type: ECC (recommended for validators)
Speed: 4800+ MT/s
Ramdisk Allocation: 64GB for accounts
```

## Storage

```yaml
Primary Drive: 2TB NVMe SSD
Mount Point: / (root filesystem)
Ledger Location: /home/sol/ledger
Scheduler: none (optimal for NVMe)
Read-ahead: 2048KB
```

## Network

```yaml
NIC Model: Intel 82599ES 10GbE (likely)
Interface: enp1s0f0
Speed: 10 Gbps
Queues: 32 TX/RX queues
```

---

# 6. OPERATING SYSTEM CONFIGURATION

## Rebuild History (December 17, 2025)

### What Happened

The original NVMe SSD failed after **2.74 PB written** (117% of rated lifespan). The server became unreachable - both the main IP (38.92.24.174) and IPMI were down, indicating a critical hardware failure.

### Emergency Recovery

1. **IPMI Access** - Connected via datacenter VPN to access IPMI console
2. **Backup to VPS** - Critical files saved to 148.230.81.56 (solsnap user):
   - `/home/sol/keypairs/` - Validator identity keys (CRITICAL)
   - `/etc/telegraf/telegraf.conf` - Monitoring configuration
   - Monitoring scripts from `/home/solana/monitoring/`
3. **Drive Replacement** - New 2TB NVMe installed
4. **Fresh OS Install** - Fedora 43 Server chosen for rebuild

### What Was Preserved

| Item | Status | Location |
|------|--------|----------|
| validator-keypair.json | ✅ Saved | VPS backup → restored |
| vote-account-keypair.json | ✅ Saved | VPS backup → restored |
| Monitoring scripts | ✅ Saved | VPS backup → restored |
| Telegraf config | ✅ Saved | VPS backup → restored |

### What Was Lost (Rebuilt)

| Item | Status | Resolution |
|------|--------|------------|
| Ledger data | ❌ Lost | Re-synced from testnet |
| Previous OS (Ubuntu?) | ❌ Lost | Replaced with Fedora 43 |
| Agave binary | ❌ Lost | Rebuilt from source |
| All optimizations | ❌ Lost | Reapplied (documented below) |

## Why Fedora 43?

The OS choice was deliberate for VEXOR development, not just validator operation:

| Factor | Fedora 43 | Ubuntu 24.04 | Why It Matters |
|--------|-----------|--------------|----------------|
| Kernel | 6.17 | 6.8 | Latest AMD 7950X3D optimizations |
| AMD P-State | Full HFI support | Basic | Better power/performance scaling |
| XDP/AF_XDP | Native, latest | Manual setup | Critical for VEXOR networking |
| eBPF/libbpf | Latest | Older | Required for packet processing |
| GCC | 15 | 14 | Better Zig interop, newer C++ |
| io_uring | Latest features | Older | Async I/O for VexStore |

### Build Challenges Encountered

During the Agave 3.1.4 build, several issues were resolved:

1. **Missing Dependencies** - Iteratively installed:
   - `systemd-devel`, `libudev-devel`
   - `perl-FindBin`, `perl-IPC-Cmd`
   - `openssl-devel`, `clang`, `llvm-devel`

2. **RocksDB + GCC 15 Incompatibility** - The bundled RocksDB failed to compile:
   ```
   error: 'uint64_t' was not declared in this scope
   ```
   **Solution:** Install system `rocksdb-devel` package instead of building from source.

3. **Dynamic Linking** - Required `LD_LIBRARY_PATH` for RocksDB:
   ```bash
   export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH
   ```

## Kernel Boot Parameters

Current `/proc/cmdline`:
```
hugepagesz=1G hugepages=32 default_hugepagesz=1G transparent_hugepage=never
mitigations=off processor.max_cstate=1 idle=poll amd_pstate=active
nosoftlockup tsc=reliable clocksource=tsc nmi_watchdog=0 audit=0
selinux=0 nowatchdog
```

### Parameter Explanations

| Parameter | Purpose |
|-----------|---------|
| `hugepagesz=1G hugepages=32` | 32GB of 1GB huge pages for validator |
| `transparent_hugepage=never` | Disable THP (causes latency spikes) |
| `mitigations=off` | Disable CPU security mitigations (~5-15% performance) |
| `processor.max_cstate=1` | Keep CPU in highest performance state |
| `idle=poll` | Don't sleep on idle (latency sensitive) |
| `amd_pstate=active` | AMD P-state driver for Ryzen |
| `nosoftlockup` | Disable soft lockup detection |
| `tsc=reliable clocksource=tsc` | Use TSC for timing (most accurate) |
| `nmi_watchdog=0 nowatchdog` | Disable watchdogs (reduce interrupts) |
| `audit=0 selinux=0` | Disable audit and SELinux overhead |

## To Modify Boot Parameters

```bash
# Edit GRUB config
vi /etc/default/grub

# Regenerate GRUB (Fedora)
grub2-mkconfig -o /boot/grub2/grub.cfg

# Reboot to apply
reboot
```

---

# 7. ALL APPLIED OPTIMIZATIONS

## 7.1 Sysctl Parameters (50+ settings)

File: `/etc/sysctl.d/99-solana-validator.conf`

```ini
# VIRTUAL MEMORY
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 100
vm.dirty_writeback_centisecs = 100
vm.vfs_cache_pressure = 50
vm.max_map_count = 2000000
vm.min_free_kbytes = 524288
vm.nr_hugepages = 32
vm.hugetlb_shm_group = 1000

# NETWORK - CORE
net.core.rmem_max = 134217728
net.core.rmem_default = 134217728
net.core.wmem_max = 134217728
net.core.wmem_default = 134217728
net.core.optmem_max = 134217728
net.core.netdev_max_backlog = 300000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 65535

# NETWORK - TCP
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 87380 134217728
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 786432 1048576 26777216
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535

# FILE SYSTEM
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# KERNEL SCHEDULER
kernel.pid_max = 4194304
kernel.threads-max = 4194304
kernel.sched_rt_runtime_us = -1
kernel.numa_balancing = 0
kernel.perf_event_paranoid = -1
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
```

### Apply Changes

```bash
sysctl --system
```

## 7.2 User Limits

File: `/etc/security/limits.d/99-solana.conf`

```ini
sol soft nofile 2097152
sol hard nofile 2097152
sol soft nproc 2097152
sol hard nproc 2097152
sol soft memlock unlimited
sol hard memlock unlimited
sol soft stack unlimited
sol hard stack unlimited
sol soft core unlimited
sol hard core unlimited
root soft nofile 2097152
root hard nofile 2097152
root soft memlock unlimited
root hard memlock unlimited
* soft nofile 1048576
* hard nofile 1048576
```

## 7.3 Ramdisk Configuration

File: `/etc/fstab` entry:

```
tmpfs /mnt/ramdisk tmpfs rw,noexec,nodev,nosuid,noatime,size=64G,uid=1000,gid=1000,mode=0700 0 0
```

### Verify Ramdisk

```bash
df -h /mnt/ramdisk
# Should show: 64G total, ~30-40G used for accounts
```

## 7.4 NIC Tuning

File: `/usr/local/bin/tune-nic.sh`

```bash
#!/bin/bash
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$IFACE" ] && exit 1
ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null || true
ethtool -C $IFACE rx-usecs 0 rx-frames 0 tx-usecs 0 tx-frames 0 2>/dev/null || true
ethtool -K $IFACE gro on gso on tso on lro off 2>/dev/null || true
echo "NIC $IFACE tuned"
```

## 7.5 IRQ Pinning

File: `/usr/local/bin/pin-irqs.sh`

```bash
#!/bin/bash
# Pin network IRQs to CPUs 0-1 (non-validator cores)
# CPU mask 0x3 = binary 11 = CPUs 0 and 1

IFACE="enp1s0f0"

for irq in $(grep $IFACE /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
    echo 3 > /proc/irq/$irq/smp_affinity 2>/dev/null && echo "Pinned IRQ $irq to CPUs 0-1"
done

echo "Network IRQ pinning complete"

# Enable XPS for TX queues
for i in /sys/class/net/enp1s0f0/queues/tx-*/xps_cpus; do
    echo 3 > $i 2>/dev/null
done
echo "XPS configured"
```

### IRQ Pinning Strategy

- **CPUs 0-1:** Handle network interrupts and OS tasks
- **CPUs 2-31:** Available for validator threads
- **Result:** No interrupt contention on validator threads

## 7.6 NVMe Optimization

```bash
# Read-ahead set to 2048KB
echo 2048 > /sys/block/nvme0n1/queue/read_ahead_kb

# Scheduler set to none (best for NVMe)
cat /sys/block/nvme0n1/queue/scheduler
# Output: [none] mq-deadline kyber bfq
```

Persistent via udev rule `/etc/udev/rules.d/60-nvme-readahead.rules`:
```
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/read_ahead_kb}="2048"
```

## 7.7 CPU Governor

```bash
# Set to performance mode
tuned-adm profile latency-performance

# Verify
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# Output: performance
```

## 7.8 Systemd Services for Tuning

File: `/etc/systemd/system/nic-tuning.service`

```ini
[Unit]
Description=NIC Tuning for Solana Validator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/tune-nic.sh
ExecStartPost=/usr/local/bin/pin-irqs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

---

# 8. VALIDATOR CONFIGURATION

## Startup Script

File: `/home/sol/validator.sh`

```bash
#!/bin/bash
exec /home/sol/agave/bin/agave-validator \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --authorized-voter /home/sol/keypairs/validator-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log /home/sol/logs/validator.log \
    --entrypoint entrypoint.testnet.solana.com:8001 \
    --entrypoint entrypoint2.testnet.solana.com:8001 \
    --entrypoint entrypoint3.testnet.solana.com:8001 \
    --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on \
    --known-validator dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs \
    --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN \
    --known-validator eoKpUABi59aT4rR9HGS3LcMecfut9x7zJyodWWP43YQ \
    --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv \
    --expected-shred-version 9604 \
    --expected-genesis-hash 4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY \
    --full-rpc-api \
    --rpc-port 8899 \
    --dynamic-port-range 8000-8050 \
    --wal-recovery-mode skip_any_corrupted_record \
    --limit-ledger-size 50000000 \
    --no-snapshot-fetch
```

### Key Flags Explained

| Flag | Purpose |
|------|---------|
| `--identity` | Validator identity keypair |
| `--vote-account` | Vote account for consensus |
| `--accounts /mnt/ramdisk` | Use ramdisk for account data |
| `--full-rpc-api` | Enable all RPC methods |
| `--limit-ledger-size 50000000` | Keep ledger under ~100GB |
| `--no-snapshot-fetch` | Don't download snapshots (already synced) |

## Systemd Service

File: `/etc/systemd/system/solana-validator.service`

```ini
[Unit]
Description=Solana Validator
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=10
User=root
LimitNOFILE=2097152
LimitNPROC=2097152
LimitMEMLOCK=infinity
LimitSTACK=infinity
WorkingDirectory=/home/sol
ExecStart=/home/sol/validator.sh

[Install]
WantedBy=multi-user.target
```

### Service Commands

```bash
# Start validator
systemctl start solana-validator

# Stop validator (may take 30-60s)
systemctl stop solana-validator

# Restart validator
systemctl restart solana-validator

# Check status
systemctl status solana-validator

# View logs
journalctl -u solana-validator -f
```

---

# 9. MONITORING SETUP

## Dashboard

- **URL:** https://solana.thevalidators.io/d/e-8yEOXMwerfwe/solana-monitoring
- **Parameters:** `?var-server=v1.qubestake.io&var-cluster=testnet`

## InfluxDB Configuration

```yaml
Database: v_metrics
URL: http://influx.thevalidators.io:8086
Username: v_user
Password: thepassword
```

## Telegraf Configuration

File: `/etc/telegraf/telegraf.conf`

```ini
[agent]
  hostname = "v1.qubestake.io"
  flush_interval = "30s"
  interval = "30s"

[global_tags]
  cluster = "testnet"

[[inputs.cpu]]
  percpu = false
  totalcpu = true
  collect_cpu_time = false
  report_active = false

[[inputs.disk]]
  mount_points = ["/", "/home/sol/ledger", "/home/sol/accounts-ramdisk"]
  ignore_fs = ["devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

[[inputs.diskio]]
[[inputs.net]]
[[inputs.mem]]
[[inputs.swap]]
[[inputs.system]]
[[inputs.netstat]]
[[inputs.processes]]
[[inputs.kernel]]

[[inputs.exec]]
  commands = ["sudo -u sol /home/sol/monitoring/output_starter.sh output_validator_measurements"]
  interval = "30s"
  timeout = "30s"
  data_format = "json"
  json_name_key = "measurement"
  json_time_key = "time"
  tag_keys = ["validator_name", "validator_identity_pubkey", "validator_vote_pubkey", "cluster_environment"]
  json_string_fields = ["monitoring_version", "solana_version", "validator_identity_pubkey", "validator_vote_pubkey", "cluster_environment", "cpu_model"]
  json_time_format = "unix_ms"

[[inputs.systemd_units]]
  pattern = "solana-validator.service"

[[outputs.influxdb]]
  database = "v_metrics"
  urls = [ "http://influx.thevalidators.io:8086" ]
  username = "v_user"
  password = "thepassword"
```

## Monitoring Scripts

Location: `/home/sol/monitoring/`

### output_starter.sh

```bash
#!/bin/bash
export PATH="/home/sol/.local/share/solana/install/active_release/bin:$PATH"
source "/home/sol/monitoring/bin/activate"
result=$(timeout -k 50 45 python3 "/home/sol/monitoring/$1.py")
if [ -z "${result}" ]
then
        echo "{}"
else
        echo "$result"
fi
```

### monitoring_config.py

```python
from common import ValidatorConfig
config = ValidatorConfig(
    validator_name="v1.qubestake.io",
    secrets_path="/home/sol/keypairs",
    local_rpc_address="http://localhost:8899",
    remote_rpc_address="https://api.testnet.solana.com",
    cluster_environment="testnet",
    debug_mode=False
)
```

---

# 10. BACKUP INFRASTRUCTURE

## Timeshift Snapshots

```bash
# List snapshots
timeshift --list

# Create snapshot
timeshift --create --comments "Description" --tags D

# Restore snapshot
timeshift --restore --snapshot '2025-12-17_16-17-56'
```

### Current Snapshots

1. `Phase0-Keypairs-Restored` - Initial OS setup
2. `Phase2-Complete-Monitoring-Working` - Monitoring configured
3. `Phase2-AllOptimizations-Complete` - All tuning applied

## VPS Backup Location

```
Server: 148.230.81.56 (solsnap user)
Path: ~/backup-qubestake-dec16/

Contents:
├── etc-backup/
│   └── telegraf/telegraf.conf
├── home-solana/
│   └── monitoring/           # Original monitoring scripts
└── keypairs/                 # Backup keypairs
```

### Restore from VPS

```bash
# Connect to VPS
ssh solsnap@148.230.81.56

# Copy specific file
scp solsnap@148.230.81.56:~/backup-qubestake-dec16/path/to/file /local/path/

# Bulk copy directory
ssh solsnap@148.230.81.56 "cd ~/backup-qubestake-dec16 && tar czf - directory" | tar xzf - -C /local/destination/
```

---

# 11. PHASE 3: VEXOR BUILD PLAN

## Overview

VEXOR is a Zig-based Solana validator client designed to match or exceed Firedancer's performance through:

1. **Zero-overhead language** (Zig vs Rust)
2. **Tile-based architecture** (like Firedancer)
3. **Direct hardware access** (io_uring, eBPF, AF_XDP)
4. **Custom crypto** (AVX-512 optimized)

## Architecture: Tile-Based Design

```
┌─────────────────────────────────────────────────────────────┐
│                      VEXOR VALIDATOR                         │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │  NET    │  │  SIG    │  │  BANK   │  │  STORE  │        │
│  │  TILE   │  │  TILE   │  │  TILE   │  │  TILE   │        │
│  │ (QUIC)  │  │(VERIFY) │  │ (EXEC)  │  │(LEDGER) │        │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘        │
│       │            │            │            │              │
│       └────────────┴────────────┴────────────┘              │
│                     SHARED MEMORY                           │
└─────────────────────────────────────────────────────────────┘
```

### Tile Responsibilities

| Tile | Function | CPU Pinning |
|------|----------|-------------|
| NET | QUIC/Turbine networking | CPUs 0-1 |
| SIG | Ed25519 signature verification | CPUs 2-7 |
| BANK | Transaction execution | CPUs 8-23 |
| STORE | Ledger/accounts persistence | CPUs 24-31 |

## Technology Stack

### Networking Layer

```zig
// AF_XDP for kernel bypass networking
const xdp = @import("xdp");

pub fn receivePackets(socket: *xdp.Socket) ![]Packet {
    // Zero-copy packet receive via AF_XDP
    const rx_batch = try socket.recv(BATCH_SIZE);
    return rx_batch.packets;
}
```

### io_uring for Async I/O

```zig
// io_uring for async file operations
const io = @import("io_uring");

pub fn asyncWrite(ring: *io.Ring, fd: i32, data: []const u8) !void {
    const sqe = try ring.get_sqe();
    io.prep_write(sqe, fd, data, 0);
    _ = try ring.submit();
}
```

### SIMD Crypto (AVX-512)

```zig
// AVX-512 batch signature verification
const Vector = @Vector(8, u64);

pub fn batchVerifyEd25519(sigs: []Signature, msgs: [][]const u8, pubs: []PublicKey) bool {
    // Process 8 signatures in parallel using AVX-512
    var valid = Vector{1, 1, 1, 1, 1, 1, 1, 1};
    // ... SIMD verification logic
    return @reduce(.And, valid) == 1;
}
```

## Build Requirements

```bash
# Install Zig
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar -xf zig-linux-x86_64-0.13.0.tar.xz
export PATH=$PATH:$PWD/zig-linux-x86_64-0.13.0

# Dependencies
dnf install -y libbpf-devel libxdp-devel liburing-devel
```

## Development Workflow

1. **Set up Zig project structure**
2. **Implement core types** (Transaction, Block, Account)
3. **Build networking tile** (AF_XDP + QUIC)
4. **Build signature tile** (AVX-512 Ed25519)
5. **Build bank tile** (execution engine)
6. **Build store tile** (ledger persistence)
7. **Integration testing** against testnet

---

# 12. PHASE 4: VEXSTORE CUSTOM STORAGE

## Why Replace RocksDB?

| Issue | RocksDB | VexStore Goal |
|-------|---------|---------------|
| Write Amplification | ~30x | ~5x |
| Memory Usage | High | 50% reduction |
| GPU Support | None | Native |
| Zig Integration | FFI overhead | Native |

## VexStore Architecture

Based on **WiscKey** design (separate keys from values):

```
┌────────────────────────────────────────┐
│              VexStore                   │
├────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐   │
│  │   Key LSM    │  │  Value Log   │   │
│  │   (small)    │  │   (append)   │   │
│  └──────────────┘  └──────────────┘   │
│         │                  │          │
│         ▼                  ▼          │
│  ┌──────────────┐  ┌──────────────┐   │
│  │   MemTable   │  │   Circular   │   │
│  │   (sorted)   │  │   Buffer     │   │
│  └──────────────┘  └──────────────┘   │
└────────────────────────────────────────┘
```

## Key Features

1. **Key-Value Separation** - Small keys in LSM, large values in log
2. **Parallel Compaction** - Multi-threaded background compaction
3. **GPU Index** - GPU-accelerated B-tree index lookups
4. **io_uring Backend** - Async I/O for all operations

## Alternative Options Researched

| Database | Pros | Cons |
|----------|------|------|
| Speedb | Drop-in RocksDB replacement, 10x faster | Still C++, limited Zig integration |
| TitanDB | Key-value separation | Blob GC complexity |
| LMDB | Simple, ACID | Single writer limitation |
| redb | Pure Rust, simple | Not battle-tested |
| Custom | Full control, GPU support | Development time |

**Recommendation:** Build custom VexStore for maximum performance and GPU integration.

---

# 13. PHASE 5: GPU ACCELERATION

## Target Hardware

```yaml
GPU: NVIDIA RTX 4090
VRAM: 24GB GDDR6X
CUDA Cores: 16384
Tensor Cores: 512
Memory Bandwidth: 1 TB/s
```

Alternative: Dual RTX 3090 (48GB combined VRAM)

## GPU Acceleration Targets

### 1. Ed25519 Batch Signature Verification

```
CPU (AVX-512): ~100K verifications/sec
GPU (CUDA):    ~2M verifications/sec (20x speedup)
```

Requirements:
- Batch size > 10,000 for efficiency
- Pinned memory for zero-copy transfer
- Async verification pipeline

### 2. Account Index Lookups (VexStore)

```
CPU B-tree lookup: O(log n) with cache misses
GPU parallel lookup: O(1) with hash tables
```

### 3. Future: CuSVM (GPU-Native sBPF Execution)

Execute Solana programs directly on GPU:
- Parallel account processing
- Block-STM style concurrency
- 10-100x transaction throughput

## Zig-CUDA Integration

```zig
// cuda.zig - Zig bindings for CUDA
const cuda = @cImport({
    @cInclude("cuda_runtime.h");
});

pub fn gpuBatchVerify(sigs: []Signature, device_ptr: *anyopaque) !void {
    // Launch CUDA kernel for batch verification
    cuda.cudaMemcpyAsync(device_ptr, sigs.ptr, sigs.len * @sizeOf(Signature), 
                         cuda.cudaMemcpyHostToDevice, stream);
    // ... kernel launch
}
```

## Implementation Roadmap

1. **Phase 5.1:** CUDA toolchain setup
2. **Phase 5.2:** Ed25519 GPU kernel
3. **Phase 5.3:** Async verification pipeline
4. **Phase 5.4:** VexStore GPU index
5. **Phase 5.5:** CuSVM prototype

---

# 14. CURSOR IDE OPTIMIZATION

## Project Structure for Claude

```
vexor/
├── _prompts/                    # AI assistant context
│   ├── vexor-quick-ref.md      # Quick reference (paste into chat)
│   ├── vexor-dev-prompt.md     # Task modules
│   └── notes/                   # Saved Claude responses
├── src/
│   ├── net/                     # Networking tile
│   ├── sig/                     # Signature verification
│   ├── bank/                    # Transaction execution
│   └── store/                   # Storage engine
├── build.zig
└── README.md
```

## Quick Reference File

Create `_prompts/vexor-quick-ref.md`:

```markdown
# VEXOR Quick Reference

## Project
- Name: VEXOR
- Type: Solana validator client
- Language: Zig
- Goal: Match/exceed Firedancer performance

## Current Status
- Phase: 3 (Initial VEXOR build)
- Validator: Running on testnet (Agave 3.1.4)
- Server: 38.92.24.174

## Key Files
- /home/sol/validator.sh - Startup script
- /home/sol/keypairs/ - Validator keys
- /etc/telegraf/telegraf.conf - Monitoring

## Tasks
- T1: Network tile (AF_XDP + QUIC)
- T2: Signature tile (AVX-512)
- T3: Bank tile (execution)
- T4: Store tile (VexStore)
```

## Session Workflow

### Starting a Session

1. Open Cursor IDE
2. Press `Ctrl+L` to open chat
3. Paste the quick reference file
4. State your current task

Example:
```
I'm working on VEXOR today. [paste quick-ref]

Today I'm focusing on the networking tile (T1).
I need to implement AF_XDP packet receive.

Let's start.
```

### Task Modules

Copy relevant module from `vexor-dev-prompt.md`:

```yaml
### MODULE: Network Tile Implementation

task: implement_net_tile
priority: high
files: src/net/

requirements:
  - AF_XDP socket setup
  - QUIC packet parsing
  - Zero-copy receive path
  - Integration with sig tile

output:
  - Working packet receive loop
  - Performance benchmark results
```

### Code Generation (Composer)

Press `Ctrl+I` to open Composer:

```
Context: VEXOR project (Zig Solana validator)

Create a new file: src/net/xdp.zig

Implement:
- AF_XDP socket initialization
- Packet receive function with zero-copy
- Error handling for socket operations

Use Zig best practices.
```

### @ Mentions

Reference files directly:

```
Look at @src/net/xdp.zig and explain what changes 
are needed for batch packet processing.
```

## Tips for Better Results

1. **Keep chats focused** - One task per chat
2. **Save good responses** - Store in `_prompts/notes/`
3. **Use @ mentions** - Reference files directly
4. **Reset if confused** - Paste quick-ref again
5. **Be specific** - Clear requirements get better code

---

# 15. TROUBLESHOOTING & RECOVERY

## Common Issues

### Validator Won't Start

```bash
# Check logs
journalctl -u solana-validator -n 100

# Check permissions
ls -la /home/sol/keypairs/
# Should be: -rw------- sol sol

# Check ramdisk
df -h /mnt/ramdisk
mount | grep ramdisk
```

### High Skip Rate

```bash
# Check if catching up
solana catchup --our-localhost

# Check network connectivity
solana gossip | wc -l
# Should be > 500 peers

# Check CPU usage
htop
# Validator threads should be distributed across CPUs
```

### Monitoring Not Working

```bash
# Test monitoring script
sudo -u sol bash -c 'source /home/sol/monitoring/bin/activate && python3 /home/sol/monitoring/output_validator_measurements.py'

# Check telegraf
systemctl status telegraf
journalctl -u telegraf -n 50

# Test InfluxDB connectivity
curl -s -o /dev/null -w "%{http_code}" "http://influx.thevalidators.io:8086/ping"
# Should return: 204
```

### Emergency Recovery

```bash
# Restore from Timeshift
timeshift --list
timeshift --restore --snapshot '2025-12-17_16-17-56'

# Restore from VPS backup
ssh solsnap@148.230.81.56
scp solsnap@148.230.81.56:~/backup-qubestake-dec16/keypairs/* /home/sol/keypairs/
```

---

# 16. QUICK REFERENCE COMMANDS

## Validator Management

```bash
# Start/Stop/Restart
systemctl start solana-validator
systemctl stop solana-validator
systemctl restart solana-validator

# Status
systemctl status solana-validator

# Logs
tail -f /home/sol/logs/validator.log
journalctl -u solana-validator -f
```

## Solana CLI (as sol user)

```bash
# Set alias (add to ~/.bashrc)
alias solana='/home/sol/.local/share/solana/install/active_release/bin/solana'

# Check slot
solana slot --url localhost

# Check catchup
solana catchup --our-localhost

# Check vote account
solana vote-account /home/sol/keypairs/vote-account-keypair.json

# Check balance
solana balance

# Check validators
solana validators | grep 3J2jADiEoKMaooCQbkyr9aLnjAb5ApDWfVvKgzyK2fbP
```

## System Monitoring

```bash
# CPU/Memory
htop

# Disk usage
df -h

# Network connections
ss -tuln | grep -E "8899|8001|8000"

# Check IRQ affinity
cat /proc/irq/83/smp_affinity

# Check CPU frequencies
cat /proc/cpuinfo | grep MHz | head -4
```

## Backup Commands

```bash
# Create Timeshift snapshot
timeshift --create --comments "Description" --tags D

# List snapshots
timeshift --list

# Connect to backup VPS
ssh solsnap@148.230.81.56
```

---

# APPENDIX A: OPTIMIZATION SUMMARY TABLE

| Category | Parameter | Value | Purpose |
|----------|-----------|-------|---------|
| VM | vm.swappiness | 1 | Minimize swap usage |
| VM | vm.max_map_count | 2000000 | Support large mmap |
| VM | vm.nr_hugepages | 32 | 32GB huge pages |
| Network | net.core.rmem_max | 128MB | Large receive buffers |
| Network | tcp_congestion_control | bbr | Modern congestion control |
| Network | tcp_fastopen | 3 | Enable TFO |
| Kernel | pid_max | 4194304 | Support many threads |
| Kernel | numa_balancing | 0 | Disable (single NUMA) |
| NIC | Ring buffers | 4096 | Maximum queue depth |
| NIC | GRO/GSO/TSO | on | Hardware offloads |
| IRQ | Affinity | CPUs 0-1 | Isolate from validator |
| NVMe | Read-ahead | 2048KB | Better sequential reads |
| NVMe | Scheduler | none | Optimal for NVMe |
| CPU | Governor | performance | Maximum frequency |
| Boot | mitigations | off | Disable CPU mitigations |
| Boot | idle | poll | No idle sleep |

---

# APPENDIX B: NETWORK PORTS

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH |
| 8899 | TCP | RPC |
| 8900 | TCP | RPC WebSocket |
| 8001 | UDP | Gossip |
| 8000-8050 | UDP/TCP | TPU/Turbine |

---

# APPENDIX C: KEY FILE CHECKSUMS

```bash
# Generate checksums of critical files
sha256sum /home/sol/keypairs/validator-keypair.json
sha256sum /home/sol/keypairs/vote-account-keypair.json
sha256sum /home/sol/validator.sh
sha256sum /etc/telegraf/telegraf.conf
```

Store these securely for integrity verification.

---

**END OF DOCUMENT**

*Version 1.0 - December 17, 2025*
*QubeShare VEXOR Project*

