# Vexor Debug & Auto-Fix System

**Created:** December 13, 2024  
**Status:** PLANNING → IMPLEMENTATION  
**Priority:** HIGH - Essential for self-service troubleshooting

---

## 🎯 Vision

Validators should be able to diagnose and fix most issues **without contacting support**. The system must:

1. **Detect** problems automatically
2. **Diagnose** the root cause
3. **Explain** what's wrong in plain language
4. **Offer** a fix (with permission)
5. **Execute** the fix safely
6. **Verify** the fix worked
7. **Log** everything for auditing

---

## 🔍 Debug Modes

### Verbosity Levels

```bash
# Normal output (errors only)
vexor-install install

# Verbose (info + warnings)
vexor-install -v install

# Debug (detailed logging)
vexor-install --debug install

# Trace (everything, including syscalls)
vexor-install --trace install
```

### Subsystem-Specific Debug

```bash
# Debug only network
vexor-install --debug=network install

# Debug only storage
vexor-install --debug=storage install

# Debug multiple subsystems
vexor-install --debug=network,storage install

# Debug all
vexor-install --debug=all install
```

### Log Output Options

```bash
# Log to file
vexor-install --log-file=/var/log/vexor-install.log install

# Log to stderr (default)
vexor-install --debug install

# Log to both
vexor-install --debug --log-file=/var/log/vexor.log install

# JSON format (for parsing)
vexor-install --debug --log-format=json install
```

---

## 🔧 Auto-Diagnosis System

### Issue Database

A comprehensive database of known issues and their solutions:

```zig
// src/tools/installer/debug/issue_database.zig

pub const KnownIssue = struct {
    id: []const u8,
    name: []const u8,
    category: Category,
    severity: Severity,
    symptoms: []const []const u8,
    causes: []const []const u8,
    diagnosis_commands: []const []const u8,
    auto_fix: ?AutoFix,
    manual_fix_instructions: []const u8,
    references: []const []const u8,
};

pub const AutoFix = struct {
    command: []const u8,
    risk_level: RiskLevel,
    requires_sudo: bool,
    reversible: bool,
    rollback_command: ?[]const u8,
    verification_command: []const u8,
};

pub const known_issues = [_]KnownIssue{
    // AF_XDP Issues
    .{
        .id = "AFXDP001",
        .name = "AF_XDP Socket Creation Failed (EPERM)",
        .category = .network,
        .severity = .high,
        .symptoms = &[_][]const u8{
            "AF_XDP socket creation returns EPERM",
            "Falling back to standard UDP",
            "Network throughput severely limited",
        },
        .causes = &[_][]const u8{
            "Binary missing CAP_NET_RAW capability",
            "CAP_NET_ADMIN not set",
            "Kernel lockdown enabled",
        },
        .diagnosis_commands = &[_][]const u8{
            "getcap /opt/vexor/bin/vexor",
            "cat /sys/kernel/security/lockdown",
        },
        .auto_fix = .{
            .command = "setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor",
            .risk_level = .low,
            .requires_sudo = true,
            .reversible = true,
            .rollback_command = "setcap -r /opt/vexor/bin/vexor",
            .verification_command = "getcap /opt/vexor/bin/vexor | grep -q cap_net_raw",
        },
        .manual_fix_instructions = 
            \\Run the following command as root:
            \\  sudo setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
            \\
            \\Then verify with:
            \\  getcap /opt/vexor/bin/vexor
        ,
        .references = &[_][]const u8{
            "https://docs.kernel.org/networking/af_xdp.html",
        },
    },
    
    .{
        .id = "AFXDP002",
        .name = "AF_XDP Driver Not Supported",
        .category = .network,
        .severity = .high,
        .symptoms = &[_][]const u8{
            "AF_XDP socket bind fails",
            "No XDP support detected",
        },
        .causes = &[_][]const u8{
            "NIC driver doesn't support XDP",
            "Old kernel version",
        },
        .diagnosis_commands = &[_][]const u8{
            "ethtool -i eth0 | grep driver",
            "uname -r",
        },
        .auto_fix = null, // No auto-fix, hardware limitation
        .manual_fix_instructions = 
            \\Your network driver doesn't support AF_XDP.
            \\
            \\Supported drivers: i40e, mlx5, ixgbe, ice, igc, veth
            \\
            \\Options:
            \\1. Use a supported NIC
            \\2. Continue with standard UDP (slower but functional)
            \\3. Use io_uring for improved performance (kernel 5.1+)
        ,
        .references = &[_][]const u8{
            "https://github.com/xdp-project/xdp-tutorial",
        },
    },

    // QUIC/MASQUE Issues
    .{
        .id = "QUIC001",
        .name = "QUIC Ports Blocked",
        .category = .network,
        .severity = .high,
        .symptoms = &[_][]const u8{
            "QUIC connection timeout",
            "UDP packets to port 8801 dropped",
            "MASQUE proxy unreachable",
        },
        .causes = &[_][]const u8{
            "Firewall blocking UDP traffic",
            "Cloud provider UDP restrictions",
            "ISP blocking QUIC",
        },
        .diagnosis_commands = &[_][]const u8{
            "nft list ruleset | grep -E 'udp|8801'",
            "ss -ulpn | grep 8801",
            "nc -u -v localhost 8801",
        },
        .auto_fix = .{
            .command = "nft add rule inet filter input udp dport 8801-8810 accept",
            .risk_level = .low,
            .requires_sudo = true,
            .reversible = true,
            .rollback_command = "nft delete rule inet filter input udp dport 8801-8810 accept",
            .verification_command = "nft list ruleset | grep -q 8801",
        },
        .manual_fix_instructions = 
            \\Add firewall rules to allow QUIC traffic:
            \\
            \\For nftables:
            \\  sudo nft add rule inet filter input udp dport 8801-8810 accept
            \\
            \\For iptables:
            \\  sudo iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT
            \\
            \\For cloud providers:
            \\  - AWS: Add UDP 8801-8810 to security group
            \\  - GCP: Add firewall rule for UDP 8801-8810
            \\  - Azure: Add NSG rule for UDP 8801-8810
        ,
        .references = &[_][]const u8{
            "https://www.rfc-editor.org/rfc/rfc9000",
        },
    },

    // Storage Issues
    .{
        .id = "STOR001",
        .name = "RAM Disk Mount Failed",
        .category = .storage,
        .severity = .medium,
        .symptoms = &[_][]const u8{
            "tmpfs mount failed",
            "RAM disk not available",
            "Using slow disk fallback",
        },
        .causes = &[_][]const u8{
            "Insufficient RAM",
            "Mount point doesn't exist",
            "Insufficient permissions",
        },
        .diagnosis_commands = &[_][]const u8{
            "free -h",
            "ls -la /mnt/vexor/",
            "mount | grep tmpfs",
        },
        .auto_fix = .{
            .command = "mkdir -p /mnt/vexor/ramdisk && mount -t tmpfs -o size=16G tmpfs /mnt/vexor/ramdisk",
            .risk_level = .medium,
            .requires_sudo = true,
            .reversible = true,
            .rollback_command = "umount /mnt/vexor/ramdisk",
            .verification_command = "df -h /mnt/vexor/ramdisk | grep -q tmpfs",
        },
        .manual_fix_instructions = 
            \\Create and mount RAM disk:
            \\
            \\1. Check available RAM:
            \\   free -h
            \\
            \\2. Create mount point:
            \\   sudo mkdir -p /mnt/vexor/ramdisk
            \\
            \\3. Mount tmpfs (adjust size based on available RAM):
            \\   sudo mount -t tmpfs -o size=16G tmpfs /mnt/vexor/ramdisk
            \\
            \\4. Add to /etc/fstab for persistence:
            \\   tmpfs /mnt/vexor/ramdisk tmpfs size=16G 0 0
        ,
        .references = &[_][]const u8{},
    },

    // System Tuning Issues
    .{
        .id = "TUNE001",
        .name = "Network Buffers Too Small",
        .category = .system,
        .severity = .medium,
        .symptoms = &[_][]const u8{
            "UDP packet loss under load",
            "Receive buffer overflows",
            "Inconsistent network performance",
        },
        .causes = &[_][]const u8{
            "Default kernel buffer sizes",
            "System not tuned for high-throughput",
        },
        .diagnosis_commands = &[_][]const u8{
            "sysctl net.core.rmem_max",
            "sysctl net.core.wmem_max",
            "cat /proc/net/udp | head -5",
        },
        .auto_fix = .{
            .command = "sysctl -w net.core.rmem_max=134217728 && sysctl -w net.core.wmem_max=134217728",
            .risk_level = .low,
            .requires_sudo = true,
            .reversible = true,
            .rollback_command = "sysctl -w net.core.rmem_max=212992 && sysctl -w net.core.wmem_max=212992",
            .verification_command = "sysctl net.core.rmem_max | grep -q 134217728",
        },
        .manual_fix_instructions = 
            \\Increase network buffer sizes:
            \\
            \\Temporary (until reboot):
            \\  sudo sysctl -w net.core.rmem_max=134217728
            \\  sudo sysctl -w net.core.wmem_max=134217728
            \\
            \\Permanent:
            \\  echo "net.core.rmem_max=134217728" | sudo tee -a /etc/sysctl.d/99-vexor.conf
            \\  echo "net.core.wmem_max=134217728" | sudo tee -a /etc/sysctl.d/99-vexor.conf
            \\  sudo sysctl --system
        ,
        .references = &[_][]const u8{
            "https://docs.solanalabs.com/operations/requirements",
        },
    },

    .{
        .id = "TUNE002",
        .name = "Huge Pages Not Enabled",
        .category = .system,
        .severity = .low,
        .symptoms = &[_][]const u8{
            "High memory allocation latency",
            "TLB misses",
            "Suboptimal memory performance",
        },
        .causes = &[_][]const u8{
            "Huge pages not configured",
            "Insufficient contiguous memory",
        },
        .diagnosis_commands = &[_][]const u8{
            "cat /proc/meminfo | grep HugePages",
            "sysctl vm.nr_hugepages",
        },
        .auto_fix = .{
            .command = "sysctl -w vm.nr_hugepages=16384",
            .risk_level = .medium,
            .requires_sudo = true,
            .reversible = true,
            .rollback_command = "sysctl -w vm.nr_hugepages=0",
            .verification_command = "cat /proc/meminfo | grep -q 'HugePages_Total:.*16384'",
        },
        .manual_fix_instructions = 
            \\Enable huge pages:
            \\
            \\1. Check available memory:
            \\   free -h
            \\
            \\2. Enable huge pages (2MB each, 16384 = 32GB):
            \\   sudo sysctl -w vm.nr_hugepages=16384
            \\
            \\3. Make permanent:
            \\   echo "vm.nr_hugepages=16384" | sudo tee -a /etc/sysctl.d/99-vexor.conf
            \\
            \\Note: Huge pages reserve contiguous memory and may fail if RAM is fragmented.
        ,
        .references = &[_][]const u8{
            "https://www.kernel.org/doc/Documentation/vm/hugetlbpage.txt",
        },
    },
};
```

---

## 🔄 Auto-Fix Flow

### Permission-Based Auto-Fix

```
┌─────────────────────────────────────────────────────────────────────┐
│ AUTO-FIX WORKFLOW                                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 1: DETECT ISSUE                                            │ │
│ │                                                                  │ │
│ │ Health check runs every 60 seconds (or on-demand):              │ │
│ │   • Test AF_XDP socket creation                                 │ │
│ │   • Test QUIC connectivity                                      │ │
│ │   • Check memory usage                                          │ │
│ │   • Verify disk I/O                                             │ │
│ │   • Monitor network latency                                     │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              ↓                                       │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 2: DIAGNOSE                                                │ │
│ │                                                                  │ │
│ │ Match symptoms against known issues database:                   │ │
│ │   • Check all diagnosis commands                                │ │
│ │   • Score symptom matches                                       │ │
│ │   • Identify root cause                                         │ │
│ │   • Determine if auto-fix available                             │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              ↓                                       │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 3: EXPLAIN TO USER                                         │ │
│ │                                                                  │ │
│ │ [ISSUE DETECTED: AFXDP001]                                      │ │
│ │                                                                  │ │
│ │ Problem: AF_XDP Socket Creation Failed                          │ │
│ │ Cause:   Binary missing CAP_NET_RAW capability                  │ │
│ │ Impact:  Network throughput limited to ~1M pps (vs 10M pps)     │ │
│ │                                                                  │ │
│ │ We can fix this automatically.                                  │ │
│ │                                                                  │ │
│ │ Command that will be run:                                       │ │
│ │   setcap 'cap_net_raw,cap_net_admin+eip' /opt/vexor/bin/vexor   │ │
│ │                                                                  │ │
│ │ Risk Level: LOW                                                 │ │
│ │ Reversible: YES                                                 │ │
│ │                                                                  │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              ↓                                       │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 4: REQUEST PERMISSION                                      │ │
│ │                                                                  │ │
│ │ Do you want to apply this fix?                                  │ │
│ │                                                                  │ │
│ │ [YES - Apply Fix]  [NO - Skip]  [SHOW MANUAL STEPS]             │ │
│ │                                                                  │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              ↓                                       │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 5: EXECUTE FIX (if approved)                               │ │
│ │                                                                  │ │
│ │ Creating backup...                                              │ │
│ │ Running: setcap 'cap_net_raw,cap_net_admin+eip' /opt/vexor/...  │ │
│ │ Verifying: getcap /opt/vexor/bin/vexor | grep cap_net_raw       │ │
│ │                                                                  │ │
│ │ ✅ Fix applied successfully                                      │ │
│ │                                                                  │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                              ↓                                       │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │ Step 6: VERIFY FIX                                              │ │
│ │                                                                  │ │
│ │ Re-running health check...                                      │ │
│ │ Testing AF_XDP socket creation... ✅ SUCCESS                    │ │
│ │                                                                  │ │
│ │ Issue AFXDP001 is now RESOLVED.                                 │ │
│ │                                                                  │ │
│ └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📊 Health Monitoring Dashboard

### Status Display

```
┌─────────────────────────────────────────────────────────────────────┐
│ VEXOR HEALTH STATUS                                    2024-12-13   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ ⚡ NETWORK                                                           │
│   AF_XDP:        ✅ Active (i40e, zero-copy)                        │
│   QUIC:          ✅ Connected (8 streams)                           │
│   Gossip:        ✅ 1,247 peers                                     │
│   Packet Rate:   8.3M pps RX, 2.1M pps TX                           │
│   Latency:       0.8μs avg (P99: 2.1μs)                             │
│                                                                      │
│ 💾 STORAGE                                                           │
│   RAM Disk:      ✅ 18.2/32 GB used                                 │
│   Hot Accounts:  1,847,293 cached                                   │
│   NVMe:          ✅ 847 GB free                                     │
│   Disk I/O:      Read: 3.2 GB/s, Write: 1.8 GB/s                    │
│                                                                      │
│ 🖥️  COMPUTE                                                          │
│   CPU Usage:     67% (cores 0-3: 95%, 4-7: 72%, 8-15: 45%)          │
│   Memory:        89.2/128 GB                                        │
│   Huge Pages:    ✅ 16384 allocated                                 │
│                                                                      │
│ 🔗 VALIDATOR                                                         │
│   Status:        ✅ RUNNING                                         │
│   Current Slot:  374,892,147                                        │
│   Behind:        2 slots                                            │
│   Vote Success:  99.7%                                              │
│   Skip Rate:     0.3%                                               │
│                                                                      │
│ ⚠️  ISSUES (1)                                                       │
│   [TUNE003] Swap usage high (2.1GB) - recommendation available      │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│ [R] Refresh   [D] Diagnose   [F] Fix Issues   [Q] Quit              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 🛡️ Safety Features

### Risk Level Classification

| Level | Description | User Action Required |
|-------|-------------|---------------------|
| **NONE** | Read-only operations | No |
| **LOW** | Reversible, isolated changes | Yes (can auto-approve) |
| **MEDIUM** | System-wide changes, reversible | Yes (explicit approval) |
| **HIGH** | Potentially service-affecting | Yes (with warning) |
| **CRITICAL** | May cause data loss if wrong | Yes (with confirmation) |

### Auto-Approve Settings

```bash
# In config file: /etc/vexor/auto-fix.conf

[auto_fix]
# Enable auto-fix without prompting
enabled = true

# Risk levels to auto-approve
auto_approve_risk_levels = ["none", "low"]

# Always prompt for these
always_prompt_risk_levels = ["medium", "high", "critical"]

# Specific issues to always auto-fix
always_fix = ["TUNE001", "TUNE002"]

# Specific issues to never auto-fix
never_fix = ["AFXDP002"]  # Hardware limitation, can't fix

# Notification settings
notify_on_fix = true
notify_method = "telegram"  # telegram, slack, email, webhook
```

---

## 📝 Logging System

### Log Format

```
[2024-12-13T18:30:45.123Z] [INFO] [AUDIT/NETWORK] Starting network audit
[2024-12-13T18:30:45.124Z] [DEBUG] [AUDIT/NETWORK] Detecting network interfaces...
[2024-12-13T18:30:45.156Z] [DEBUG] [AUDIT/NETWORK] Found interface: eth0 (i40e)
[2024-12-13T18:30:45.189Z] [DEBUG] [AUDIT/NETWORK] XDP capability check: SUPPORTED
[2024-12-13T18:30:45.201Z] [INFO] [AUDIT/NETWORK] Network audit complete: 2 interfaces, XDP supported
[2024-12-13T18:30:45.202Z] [WARN] [AUDIT/NETWORK] Firewall may block QUIC (ports 8801-8810)
```

### Debug Output Example

```
[DEBUG] === AF_XDP Socket Creation Test ===
[DEBUG] Interface: eth0
[DEBUG] Queue ID: 0
[DEBUG] Creating UMEM (2MB, 4096 frames)...
[DEBUG]   mmap() succeeded at 0x7f1234567890
[DEBUG]   UMEM registration: OK
[DEBUG] Creating XDP socket...
[DEBUG]   socket(AF_XDP, SOCK_RAW, 0) = 4
[DEBUG]   setsockopt(XDP_UMEM_REG) = OK
[DEBUG]   setsockopt(XDP_UMEM_FILL_RING) = OK
[DEBUG]   setsockopt(XDP_UMEM_COMPLETION_RING) = OK
[DEBUG]   setsockopt(XDP_RX_RING) = OK
[DEBUG]   setsockopt(XDP_TX_RING) = OK
[DEBUG] Binding to interface...
[DEBUG]   bind(eth0, queue=0) = OK
[DEBUG] Loading BPF program...
[DEBUG]   bpf(BPF_PROG_LOAD) = 5
[DEBUG]   bpf(BPF_LINK_CREATE) = OK
[DEBUG] === AF_XDP Socket Creation: SUCCESS ===
```

---

## 🔧 CLI Commands

```bash
# Run health check
vexor-install health

# Run health check and show all issues
vexor-install health --verbose

# Run health check and auto-fix approved issues
vexor-install health --auto-fix

# Diagnose specific issue
vexor-install diagnose AFXDP001

# Show all known issues
vexor-install issues --list

# Show issues affecting this system
vexor-install issues --detected

# Show fix for specific issue
vexor-install fix AFXDP001 --dry-run
vexor-install fix AFXDP001 --apply

# Fix all detected issues (with prompts)
vexor-install fix --all

# Fix all detected issues (auto-approve low risk)
vexor-install fix --all --auto-approve=low

# Generate diagnostic report
vexor-install diagnose --report > /tmp/vexor-diagnostic.txt

# Watch mode (continuous monitoring)
vexor-install health --watch --interval=60
```

---

## ✅ Implementation Checklist

### Core Debug System
- [ ] Verbosity levels (normal, verbose, debug, trace)
- [ ] Subsystem-specific debug flags
- [ ] Log file output
- [ ] JSON log format option

### Issue Database
- [ ] Define issue structure
- [ ] Populate known issues (AF_XDP, QUIC, storage, tuning)
- [ ] Auto-fix command definitions
- [ ] Risk level classification

### Auto-Diagnosis
- [ ] Health check runner
- [ ] Symptom matcher
- [ ] Root cause analyzer
- [ ] Issue reporter

### Auto-Fix System
- [ ] Permission request UI
- [ ] Backup before fix
- [ ] Command executor
- [ ] Verification after fix
- [ ] Rollback on failure

### Health Monitoring
- [ ] Status dashboard
- [ ] Continuous monitoring mode
- [ ] Alert notifications
- [ ] Metrics collection

---

## 📚 Related Documents

- `AUDIT_FIRST_INSTALLER_DESIGN.md` - Overall installer architecture
- `UNIFIED_INSTALLER_PLAN.md` - Original installer plan
- `PERMISSION_FIX_COMMANDS.md` - Manual fix commands reference


