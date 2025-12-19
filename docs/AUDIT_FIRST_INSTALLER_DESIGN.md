# Vexor Audit-First Installer Design

**Created:** December 13, 2024  
**Status:** PLANNING → IMPLEMENTATION  
**Priority:** CRITICAL - Core to user experience

---

## 🎯 Vision

Every Vexor installation must follow the **Audit-First** principle:

```
AUDIT → RECOMMEND → EXPLAIN → REQUEST PERMISSION → IMPLEMENT → VERIFY
```

No changes are made to a validator's system without:
1. Full hardware/software audit
2. Clear explanation of what will change
3. Explicit user permission
4. Automatic rollback capability

---

## 📋 Installation Phases

### Phase 1: SYSTEM AUDIT

Automatically detect and report on:

#### 1.1 Network Audit
```
┌─────────────────────────────────────────────────────────────────────┐
│ NETWORK AUDIT                                                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ [NIC DETECTION]                                                      │
│   Interface:    eth0 (primary), eth1 (secondary)                    │
│   Driver:       i40e (Intel X710) - XDP SUPPORTED ✅                │
│   Speed:        10 Gbps                                              │
│   Queues:       RX: 8, TX: 8                                        │
│   MAC:          00:1a:2b:3c:4d:5e                                   │
│                                                                      │
│ [AF_XDP CAPABILITY]                                                  │
│   Kernel:       5.15.0 (≥4.18 required) ✅                          │
│   libbpf:       Installed (v1.3.0) ✅                               │
│   Socket Test:  AF_XDP socket creation SUCCESS ✅                   │
│   Zero-Copy:    Supported by driver ✅                              │
│   Capability:   CAP_NET_RAW needed ⚠️                               │
│                                                                      │
│ [QUIC/MASQUE]                                                        │
│   UDP Ports:    8801-8810 AVAILABLE ✅                              │
│   Firewall:     nftables (rules may need update) ⚠️                 │
│   NAT Type:     Symmetric (MASQUE recommended)                      │
│   QUIC Offload: Not supported by NIC                                │
│                                                                      │
│ [PORTS IN USE]                                                       │
│   8899 (RPC):   Agave using                                         │
│   8001 (Gossip): Agave using                                        │
│   8900-8910:    AVAILABLE for Vexor ✅                              │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

#### 1.2 Storage Audit
```
┌─────────────────────────────────────────────────────────────────────┐
│ STORAGE AUDIT                                                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ [DISK DETECTION]                                                     │
│   /dev/nvme0n1:  Samsung 990 Pro 2TB (NVMe) ✅                      │
│                  Read: 7,450 MB/s, Write: 6,900 MB/s                │
│                  IOPS: 1,400K read, 1,550K write                    │
│   /dev/sda:      WD Red 8TB (HDD) - ARCHIVE ONLY ⚠️                 │
│                                                                      │
│ [MOUNT POINTS]                                                       │
│   /mnt/solana:        NVMe, ext4, 1.8TB free                        │
│   /mnt/solana/ledger: 500GB used                                    │
│   /var:               NVMe, ext4, 50GB free                         │
│                                                                      │
│ [RAMDISK CAPABILITY]                                                 │
│   Total RAM:    128 GB                                               │
│   Available:    96 GB                                                │
│   Recommended:  32 GB ramdisk (25% of total)                        │
│   Huge Pages:   Not enabled ⚠️ (recommended for performance)        │
│   tmpfs:        Can mount at /mnt/vexor/ramdisk                     │
│                                                                      │
│ [TIERED STORAGE RECOMMENDATION]                                      │
│   Tier 0 (RAM):   /mnt/vexor/ramdisk - Hot accounts, pending TX     │
│   Tier 1 (NVMe):  /mnt/vexor/accounts - Warm accounts               │
│   Tier 2 (NVMe):  /mnt/vexor/ledger - Ledger, snapshots             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

#### 1.3 Compute Audit
```
┌─────────────────────────────────────────────────────────────────────┐
│ COMPUTE AUDIT                                                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ [CPU DETECTION]                                                      │
│   Model:        AMD Ryzen 9 7950X                                   │
│   Cores:        16 physical, 32 threads                             │
│   Base Clock:   4.5 GHz, Boost: 5.7 GHz                             │
│   Cache:        L1: 1MB, L2: 16MB, L3: 64MB                         │
│                                                                      │
│ [CPU FEATURES]                                                       │
│   AVX2:         ✅ Supported (SIMD acceleration)                    │
│   AVX-512:      ✅ Supported (advanced SIMD)                        │
│   SHA-NI:       ✅ Supported (hardware SHA acceleration)            │
│   AES-NI:       ✅ Supported (hardware encryption)                  │
│                                                                      │
│ [NUMA TOPOLOGY]                                                      │
│   Nodes:        1 (single socket)                                   │
│   Memory:       All local (no remote access penalty)                │
│                                                                      │
│ [CPU PINNING RECOMMENDATION]                                         │
│   Cores 0-3:    Network I/O (AF_XDP, gossip, QUIC)                  │
│   Cores 4-7:    Consensus (Tower BFT, voting, PoH)                  │
│   Cores 8-11:   Transaction Processing                              │
│   Cores 12-15:  Storage I/O (accounts, ledger, snapshots)           │
│                                                                      │
│ [GPU DETECTION]                                                      │
│   GPU 0:        NVIDIA RTX 4070 Ti                                  │
│                 VRAM: 12GB, CUDA: 12.0                              │
│                 Signature verify: ~500K/sec possible                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

#### 1.4 System Audit
```
┌─────────────────────────────────────────────────────────────────────┐
│ SYSTEM AUDIT                                                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ [OS DETECTION]                                                       │
│   Distribution: Ubuntu 22.04 LTS                                    │
│   Kernel:       5.15.0-89-generic                                   │
│   Arch:         x86_64                                               │
│                                                                      │
│ [CURRENT SYSCTL SETTINGS]                                            │
│   net.core.rmem_max:        212992 ⚠️ (recommend: 134217728)        │
│   net.core.wmem_max:        212992 ⚠️ (recommend: 134217728)        │
│   vm.swappiness:            60 ⚠️ (recommend: 10)                   │
│   vm.dirty_ratio:           20 ⚠️ (recommend: 40)                   │
│   fs.file-max:              9223372036854775807 ✅                  │
│                                                                      │
│ [LIMITS]                                                             │
│   NOFILE (solana user):     1000000 ✅                              │
│   NPROC (solana user):      1000000 ✅                              │
│                                                                      │
│ [SERVICES]                                                           │
│   solana-validator:         RUNNING (Agave)                         │
│   vexor:                    NOT INSTALLED                           │
│                                                                      │
│ [EXISTING VALIDATOR]                                                 │
│   Client:       Agave v2.0.1                                        │
│   Identity:     ABC123...XYZ                                        │
│   Vote Account: DEF456...UVW                                        │
│   Current Slot: 374,700,000                                         │
│   Health:       OK                                                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Phase 2: RECOMMENDATION GENERATION

Based on audit, generate specific recommendations:

```
┌─────────────────────────────────────────────────────────────────────┐
│ VEXOR RECOMMENDATIONS FOR YOUR SYSTEM                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ ⚡ PERFORMANCE OPTIMIZATIONS AVAILABLE:                              │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ [1] AF_XDP KERNEL BYPASS                           RECOMMENDED  │ │
│ │ ─────────────────────────────────────────────────────────────── │ │
│ │ Your Intel X710 NIC supports AF_XDP kernel bypass.              │ │
│ │                                                                  │ │
│ │ BENEFIT: 10x packet throughput (~10M pps vs ~1M pps)            │ │
│ │ LATENCY: <1μs vs 5-20μs                                         │ │
│ │                                                                  │ │
│ │ REQUIRES:                                                        │ │
│ │   • CAP_NET_RAW, CAP_NET_ADMIN capabilities on binary           │ │
│ │   • BPF program loaded for XDP                                  │ │
│ │                                                                  │ │
│ │ SECURITY NOTE: Elevated network privileges required             │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ [2] QUIC/MASQUE TRANSPORT                          RECOMMENDED  │ │
│ │ ─────────────────────────────────────────────────────────────── │ │
│ │ Modern encrypted transport with NAT traversal.                  │ │
│ │                                                                  │ │
│ │ BENEFIT: Works through firewalls, multiplexed connections       │ │
│ │ LATENCY: ~1-2ms overhead for encryption                         │ │
│ │                                                                  │ │
│ │ REQUIRES:                                                        │ │
│ │   • UDP ports 8801-8810 open                                    │ │
│ │   • Firewall rules for QUIC traffic                             │ │
│ │                                                                  │ │
│ │ FIREWALL RULES TO ADD:                                          │ │
│ │   nft add rule inet filter input udp dport 8801-8810 accept     │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ [3] RAM DISK STORAGE                               RECOMMENDED  │ │
│ │ ─────────────────────────────────────────────────────────────── │ │
│ │ You have 96GB available RAM. We recommend 32GB ramdisk.         │ │
│ │                                                                  │ │
│ │ BENEFIT: <1μs latency for hot accounts                          │ │
│ │ vs 50-100μs for NVMe                                            │ │
│ │                                                                  │ │
│ │ COMMAND:                                                         │ │
│ │   mount -t tmpfs -o size=32G tmpfs /mnt/vexor/ramdisk           │ │
│ │                                                                  │ │
│ │ WILL USE: 32GB of your 128GB RAM                                │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ [4] SYSTEM TUNING                                  RECOMMENDED  │ │
│ │ ─────────────────────────────────────────────────────────────── │ │
│ │ Your sysctl settings can be optimized.                          │ │
│ │                                                                  │ │
│ │ CHANGES:                                                         │ │
│ │   net.core.rmem_max:    212992 → 134217728                      │ │
│ │   net.core.wmem_max:    212992 → 134217728                      │ │
│ │   vm.swappiness:        60 → 10                                 │ │
│ │   vm.dirty_ratio:       20 → 40                                 │ │
│ │   vm.nr_hugepages:      0 → 16384 (32GB huge pages)             │ │
│ │                                                                  │ │
│ │ BACKUP: Original settings saved to /var/backups/vexor/          │ │
│ │ ROLLBACK: vexor-install rollback sysctl                         │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Phase 3: PERMISSION REQUEST

Each change requires explicit approval:

```
┌─────────────────────────────────────────────────────────────────────┐
│ ⚠️  PERMISSION REQUEST                                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ Vexor needs your permission to make the following changes:          │
│                                                                      │
│ [1] AF_XDP Kernel Bypass                                            │
│     COMMAND: setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' \ │
│              /opt/vexor/bin/vexor                                   │
│     RISK: LOW - Standard capability for network tools               │
│     REVERSIBLE: Yes                                                 │
│                                                                      │
│     ┌──────────┐ ┌──────────┐ ┌──────────────────┐                  │
│     │ APPROVE  │ │   SKIP   │ │ EXPLAIN MORE...  │                  │
│     └──────────┘ └──────────┘ └──────────────────┘                  │
│                                                                      │
│ [2] Firewall Rules for QUIC                                         │
│     COMMAND: nft add rule inet filter input udp dport 8801-8810 ... │
│     RISK: LOW - Opens specific UDP ports only                       │
│     REVERSIBLE: Yes                                                 │
│                                                                      │
│     ┌──────────┐ ┌──────────┐ ┌──────────────────┐                  │
│     │ APPROVE  │ │   SKIP   │ │ EXPLAIN MORE...  │                  │
│     └──────────┘ └──────────┘ └──────────────────┘                  │
│                                                                      │
│ [3] RAM Disk Mount                                                  │
│     COMMAND: mount -t tmpfs -o size=32G tmpfs /mnt/vexor/ramdisk    │
│     RISK: MEDIUM - Uses 32GB of system RAM                          │
│     REVERSIBLE: Yes (umount)                                        │
│                                                                      │
│     ┌──────────┐ ┌──────────┐ ┌──────────────────┐                  │
│     │ APPROVE  │ │   SKIP   │ │ EXPLAIN MORE...  │                  │
│     └──────────┘ └──────────┘ └──────────────────┘                  │
│                                                                      │
│ [4] System Tuning (14 sysctl changes)                               │
│     COMMAND: sysctl -w <settings> && persist to /etc/sysctl.d/      │
│     RISK: LOW - Standard Solana validator tuning                    │
│     REVERSIBLE: Yes (backup created)                                │
│                                                                      │
│     ┌──────────┐ ┌──────────┐ ┌──────────────────┐                  │
│     │ APPROVE  │ │   SKIP   │ │ EXPLAIN MORE...  │                  │
│     └──────────┘ └──────────┘ └──────────────────┘                  │
│                                                                      │
│ ═══════════════════════════════════════════════════════════════════ │
│                                                                      │
│ ┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐   │
│ │   APPROVE ALL     │ │   REVIEW EACH     │ │      CANCEL       │   │
│ └───────────────────┘ └───────────────────┘ └───────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Phase 4: IMPLEMENTATION

Only approved items are implemented, with full logging:

```
┌─────────────────────────────────────────────────────────────────────┐
│ 🔧 IMPLEMENTING APPROVED CHANGES                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ Creating backup: /var/backups/vexor/pre-install-20241213-183045     │
│   → Backing up /etc/sysctl.d/... ✅                                 │
│   → Backing up firewall rules... ✅                                 │
│   → Recording system state... ✅                                    │
│                                                                      │
│ [1/4] Setting AF_XDP capabilities...                                │
│   → Running: setcap 'cap_net_raw,cap_net_admin...'                  │
│   → Verifying: getcap /opt/vexor/bin/vexor                          │
│   → Result: ✅ SUCCESS                                               │
│                                                                      │
│ [2/4] Configuring firewall for QUIC...                              │
│   → Adding: nft add rule inet filter input udp dport 8801-8810...   │
│   → Verifying: nft list ruleset | grep 8801                         │
│   → Result: ✅ SUCCESS                                               │
│                                                                      │
│ [3/4] Setting up RAM disk...                                        │
│   → Creating: mkdir -p /mnt/vexor/ramdisk                           │
│   → Mounting: mount -t tmpfs -o size=32G tmpfs /mnt/vexor/ramdisk   │
│   → Verifying: df -h /mnt/vexor/ramdisk                             │
│   → Adding to /etc/fstab for persistence...                         │
│   → Result: ✅ SUCCESS                                               │
│                                                                      │
│ [4/4] Applying system tuning...                                     │
│   → Writing: /etc/sysctl.d/99-vexor.conf                            │
│   → Applying: sysctl --system                                       │
│   → Verifying: sysctl net.core.rmem_max                             │
│   → Result: ✅ SUCCESS                                               │
│                                                                      │
│ ═══════════════════════════════════════════════════════════════════ │
│                                                                      │
│ ✅ INSTALLATION COMPLETE                                             │
│                                                                      │
│ Summary:                                                             │
│   • 4/4 changes applied successfully                                │
│   • 0 errors, 0 warnings                                            │
│   • Backup ID: pre-install-20241213-183045                          │
│                                                                      │
│ Rollback command (if needed):                                       │
│   vexor-install rollback pre-install-20241213-183045                │
│                                                                      │
│ Next steps:                                                          │
│   vexor-install status              # Check current state           │
│   vexor-install test-bootstrap      # Test snapshot loading         │
│   vexor-install switch-to-vexor     # Switch from any client to Vexor │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 🔧 DEBUGGING & AUTO-FIX SYSTEM

### Debug Mode

Every component has comprehensive debugging:

```bash
# Full debug mode - logs everything
vexor-install --debug <command>

# Debug specific subsystem
vexor-install --debug=network audit
vexor-install --debug=storage audit
vexor-install --debug=all audit

# Debug output to file
vexor-install --debug --log-file=/tmp/vexor-debug.log audit
```

### Auto-Diagnosis

Built-in problem detection:

```
┌─────────────────────────────────────────────────────────────────────┐
│ 🔍 AUTO-DIAGNOSIS RESULTS                                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ [ISSUE #1] AF_XDP Socket Creation Failed                            │
│ ────────────────────────────────────────────────────────────────── │
│ SYMPTOM:   AF_XDP socket creation returns EPERM                     │
│ CAUSE:     Binary missing CAP_NET_RAW capability                    │
│ SEVERITY:  HIGH - Falling back to slow UDP path                     │
│                                                                      │
│ DIAGNOSIS:                                                          │
│   $ getcap /opt/vexor/bin/vexor                                     │
│   (empty - no capabilities set)                                     │
│                                                                      │
│ AUTO-FIX AVAILABLE:                                                 │
│   Command: setcap 'cap_net_raw,cap_net_admin+eip' /opt/vexor/...    │
│   Risk: LOW                                                         │
│                                                                      │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐   │
│   │ AUTO-FIX NOW   │  │ SHOW COMMAND   │  │ SKIP (use fallback)│   │
│   └────────────────┘  └────────────────┘  └────────────────────┘   │
│                                                                      │
│ ───────────────────────────────────────────────────────────────────│
│                                                                      │
│ [ISSUE #2] QUIC Ports Blocked by Firewall                           │
│ ────────────────────────────────────────────────────────────────── │
│ SYMPTOM:   UDP packets to port 8801 dropped                         │
│ CAUSE:     nftables rule blocking UDP traffic                       │
│ SEVERITY:  HIGH - QUIC transport not working                        │
│                                                                      │
│ DIAGNOSIS:                                                          │
│   $ nft list ruleset | grep -E "udp.*drop"                          │
│   udp dport != {22, 80, 443} drop                                   │
│                                                                      │
│ AUTO-FIX AVAILABLE:                                                 │
│   Command: nft add rule inet filter input udp dport 8801-8810 accept│
│   Risk: LOW - Opens specific ports only                             │
│                                                                      │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐   │
│   │ AUTO-FIX NOW   │  │ SHOW COMMAND   │  │ MANUAL FIX LATER   │   │
│   └────────────────┘  └────────────────┘  └────────────────────┘   │
│                                                                      │
│ ───────────────────────────────────────────────────────────────────│
│                                                                      │
│ [ISSUE #3] Insufficient Huge Pages                                  │
│ ────────────────────────────────────────────────────────────────── │
│ SYMPTOM:   High memory allocation latency                           │
│ CAUSE:     Huge pages not enabled (vm.nr_hugepages = 0)             │
│ SEVERITY:  MEDIUM - Performance degraded but functional             │
│                                                                      │
│ AUTO-FIX AVAILABLE:                                                 │
│   Command: sysctl -w vm.nr_hugepages=16384                          │
│   Risk: LOW - Standard optimization                                 │
│                                                                      │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐   │
│   │ AUTO-FIX NOW   │  │ SHOW COMMAND   │  │ SKIP (not critical)│   │
│   └────────────────┘  └────────────────┘  └────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Continuous Health Monitoring

```bash
# Run health check anytime
vexor-install health

# Auto-fix mode (with permission)
vexor-install health --auto-fix

# Silent monitoring (for cron/systemd)
vexor-install health --quiet --auto-fix --notify=telegram
```

---

## 📁 File Structure for Implementation

```
src/tools/installer/
├── audit/
│   ├── network_audit.zig      # NIC, XDP, QUIC, firewall
│   ├── storage_audit.zig      # Disk, ramdisk, mounts
│   ├── compute_audit.zig      # CPU, NUMA, GPU
│   ├── system_audit.zig       # OS, kernel, sysctl
│   └── existing_validator.zig # Detect Agave, config
├── recommend/
│   ├── recommendation_engine.zig
│   ├── af_xdp_recommend.zig
│   ├── quic_recommend.zig
│   ├── storage_recommend.zig
│   └── tuning_recommend.zig
├── permission/
│   ├── permission_request.zig
│   ├── change_explainer.zig
│   └── approval_tracker.zig
├── implement/
│   ├── change_executor.zig
│   ├── backup_creator.zig
│   ├── rollback_manager.zig
│   └── verification.zig
├── debug/
│   ├── auto_diagnosis.zig
│   ├── auto_fix.zig
│   ├── health_monitor.zig
│   └── issue_database.zig     # Known issues + fixes
└── installer.zig              # Main entry point
```

---

## 🔄 Rollback System

Every change is reversible:

```bash
# List all backups
vexor-install rollback --list

# Rollback specific backup
vexor-install rollback pre-install-20241213-183045

# Rollback specific component
vexor-install rollback --component=sysctl
vexor-install rollback --component=firewall
vexor-install rollback --component=ramdisk

# Full rollback (restore everything)
vexor-install rollback --full
```

---

## ✅ Implementation Checklist

### Phase 1: Audit System
- [ ] Network audit (NIC, XDP, QUIC, firewall)
- [ ] Storage audit (disk type, ramdisk, mounts)
- [ ] Compute audit (CPU, NUMA, GPU)
- [ ] System audit (OS, kernel, sysctl)
- [ ] Existing validator detection

### Phase 2: Recommendation Engine
- [ ] AF_XDP recommendation logic
- [ ] QUIC/MASQUE recommendation logic
- [ ] Storage tier recommendation
- [ ] System tuning recommendation

### Phase 3: Permission System
- [ ] Permission request UI
- [ ] Change explainer
- [ ] Approval tracker
- [ ] Non-interactive mode (config file)

### Phase 4: Implementation
- [ ] Change executor with verification
- [ ] Backup system (pre-change snapshots)
- [ ] Rollback manager
- [ ] Success/failure reporting

### Phase 5: Debugging & Auto-Fix
- [ ] Auto-diagnosis engine
- [ ] Issue database (known problems + solutions)
- [ ] Auto-fix executor (with permission)
- [ ] Health monitoring (continuous)

---

## 📚 Related Documents

- `UNIFIED_INSTALLER_PLAN.md` - Original installer design
- `PERMISSION_FIX_COMMANDS.md` - Manual fix commands
- `FIREDANCER_SNAPSHOT_ANALYSIS.md` - Snapshot system reference
- `CHANGELOG.md` - Development history


