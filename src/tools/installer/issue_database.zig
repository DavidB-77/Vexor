//! Vexor Issue Database
//! Known issues, their symptoms, causes, and fixes for MASQUE, QUIC, AF_XDP, and all performance features.
//!
//! This database enables auto-diagnosis and guided fixes for validators.

const std = @import("std");

/// Risk level for a fix
pub const RiskLevel = enum {
    none,      // Read-only, no changes
    low,       // Easily reversible, isolated
    medium,    // System-wide but reversible
    high,      // May affect other services
    critical,  // Potential data loss if wrong

    pub fn description(self: RiskLevel) []const u8 {
        return switch (self) {
            .none => "None - Read only",
            .low => "Low - Easily reversible",
            .medium => "Medium - System-wide, reversible",
            .high => "High - May affect other services",
            .critical => "Critical - Potential data impact",
        };
    }

    pub fn emoji(self: RiskLevel) []const u8 {
        return switch (self) {
            .none => "⚪",
            .low => "🟢",
            .medium => "🟡",
            .high => "🟠",
            .critical => "🔴",
        };
    }
};

/// Category of issue
pub const Category = enum {
    network,    // AF_XDP, QUIC, MASQUE, ports
    storage,    // Ramdisk, NVMe, I/O
    compute,    // CPU pinning, NUMA
    system,     // Sysctl, limits, kernel
    permission, // Capabilities, ownership

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .network => "Network",
            .storage => "Storage",
            .compute => "Compute",
            .system => "System",
            .permission => "Permission",
        };
    }
};

/// Severity of issue
pub const Severity = enum {
    info,       // FYI, not a problem
    low,        // Minor performance impact
    medium,     // Moderate performance impact
    high,       // Significant performance impact
    critical,   // Feature completely broken

    pub fn emoji(self: Severity) []const u8 {
        return switch (self) {
            .info => "ℹ️",
            .low => "⚠️",
            .medium => "⚠️",
            .high => "❌",
            .critical => "🚨",
        };
    }
};

/// Auto-fix definition
pub const AutoFix = struct {
    command: []const u8,
    risk_level: RiskLevel,
    requires_sudo: bool,
    reversible: bool,
    rollback_command: ?[]const u8,
    verification_command: []const u8,
    explanation: []const u8,
};

/// Known issue definition
pub const KnownIssue = struct {
    id: []const u8,
    name: []const u8,
    category: Category,
    severity: Severity,
    description: []const u8,
    symptoms: []const []const u8,
    causes: []const []const u8,
    diagnosis_commands: []const []const u8,
    auto_fix: ?AutoFix,
    manual_instructions: []const u8,
    performance_impact: []const u8,
    references: []const []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════════
// MASQUE/QUIC ISSUES
// ═══════════════════════════════════════════════════════════════════════════════

pub const MASQUE001 = KnownIssue{
    .id = "MASQUE001",
    .name = "QUIC Ports Blocked by Firewall",
    .category = .network,
    .severity = .high,
    .description = "QUIC/MASQUE requires UDP ports 8801-8810 to be open. Firewall is blocking these ports.",
    .symptoms = &.{
        "QUIC connection timeout",
        "MASQUE proxy unreachable",
        "Falling back to TCP transport",
        "High latency on transaction submission",
    },
    .causes = &.{
        "Firewall blocking UDP traffic",
        "Cloud provider security group rules",
        "ISP blocking QUIC protocol",
        "Default deny policy for UDP",
    },
    .diagnosis_commands = &.{
        "nft list ruleset 2>/dev/null | grep -E 'udp|8801' || iptables -L -n | grep -E 'udp|8801'",
        "ss -ulnp | grep -E '880[1-9]|8810'",
        "curl -s --connect-timeout 5 https://check-host.net/check-udp?host=YOUR_IP:8801",
    },
    .auto_fix = .{
        .command = "nft add rule inet filter input udp dport 8801-8810 accept 2>/dev/null || iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "nft delete rule inet filter input udp dport 8801-8810 accept 2>/dev/null || iptables -D INPUT -p udp --dport 8801:8810 -j ACCEPT",
        .verification_command = "nft list ruleset 2>/dev/null | grep 8801 || iptables -L -n | grep 8801",
        .explanation = "Opens UDP ports 8801-8810 for QUIC/MASQUE traffic. These ports are used for high-performance transaction submission and gossip.",
    },
    .manual_instructions = 
    \\MANUAL FIX FOR QUIC PORTS:
    \\
    \\For nftables (modern):
    \\  sudo nft add rule inet filter input udp dport 8801-8810 accept
    \\
    \\For iptables (legacy):
    \\  sudo iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT
    \\  sudo iptables-save > /etc/iptables/rules.v4
    \\
    \\For cloud providers:
    \\  AWS:   Add inbound UDP 8801-8810 to security group
    \\  GCP:   Add firewall rule: gcloud compute firewall-rules create allow-quic --allow udp:8801-8810
    \\  Azure: Add NSG rule for UDP 8801-8810
    \\
    \\For UFW:
    \\  sudo ufw allow 8801:8810/udp
    ,
    .performance_impact = "Without QUIC: ~50-100ms latency increase on transaction submission. MASQUE proxy will not work.",
    .references = &.{
        "https://www.rfc-editor.org/rfc/rfc9000 (QUIC)",
        "https://www.rfc-editor.org/rfc/rfc9298 (MASQUE)",
    },
};

pub const MASQUE002 = KnownIssue{
    .id = "MASQUE002",
    .name = "MASQUE Proxy Connection Failed",
    .category = .network,
    .severity = .high,
    .description = "Cannot establish MASQUE proxy connection for NAT traversal.",
    .symptoms = &.{
        "MASQUE CONNECT-UDP failed",
        "Proxy handshake timeout",
        "HTTP/3 connection refused",
        "Falling back to direct connection",
    },
    .causes = &.{
        "Symmetric NAT blocking UDP hole punching",
        "MASQUE proxy server unreachable",
        "HTTP/3 not supported by network",
        "TLS certificate validation failure",
    },
    .diagnosis_commands = &.{
        "curl -v --http3 https://cloudflare-quic.com 2>&1 | head -20",
        "stun stun.l.google.com:19302 2>&1 | grep -i nat",
        "timeout 5 nc -u -v proxy.vexor.io 443",
    },
    .auto_fix = null, // Requires network changes or different proxy
    .manual_instructions = 
    \\MANUAL FIX FOR MASQUE PROXY:
    \\
    \\1. Check your NAT type:
    \\   stun stun.l.google.com:19302
    \\   
    \\   If "Symmetric NAT" - you need a MASQUE proxy or direct public IP
    \\
    \\2. Test HTTP/3 support:
    \\   curl --http3 https://cloudflare-quic.com
    \\
    \\3. If behind corporate firewall:
    \\   - Request UDP 443 outbound access
    \\   - Or use a VPN with UDP support
    \\
    \\4. Configure alternative proxy in /etc/vexor/config.toml:
    \\   [masque]
    \\   proxy_url = "https://your-proxy.example.com:443"
    \\   fallback_direct = true
    ,
    .performance_impact = "Without MASQUE: Validators behind NAT may have reduced peer connectivity and slower block propagation.",
    .references = &.{
        "https://www.rfc-editor.org/rfc/rfc9484 (CONNECT-UDP)",
    },
};

pub const MASQUE003 = KnownIssue{
    .id = "MASQUE003",
    .name = "QUIC Handshake Failure",
    .category = .network,
    .severity = .high,
    .description = "QUIC TLS 1.3 handshake fails, preventing secure connection establishment.",
    .symptoms = &.{
        "QUIC handshake timeout",
        "TLS alert: handshake_failure",
        "Connection reset during handshake",
        "Falling back to TCP",
    },
    .causes = &.{
        "TLS 1.3 blocked by firewall/proxy",
        "Deep packet inspection interfering",
        "Clock skew causing certificate validation failure",
        "Missing root certificates",
    },
    .diagnosis_commands = &.{
        "openssl s_client -connect entrypoint.testnet.solana.com:8801 -tls1_3 2>&1 | head -20",
        "date && curl -s http://worldtimeapi.org/api/ip | grep -o '\"datetime\":\"[^\"]*\"'",
        "ls -la /etc/ssl/certs/ | head -5",
    },
    .auto_fix = .{
        .command = "apt-get update && apt-get install -y ca-certificates && update-ca-certificates",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = false,
        .rollback_command = null,
        .verification_command = "openssl s_client -connect google.com:443 -tls1_3 2>&1 | grep -i 'verify return'",
        .explanation = "Updates CA certificates which may be required for TLS 1.3 validation.",
    },
    .manual_instructions = 
    \\MANUAL FIX FOR QUIC HANDSHAKE:
    \\
    \\1. Sync system clock:
    \\   sudo timedatectl set-ntp true
    \\   sudo systemctl restart systemd-timesyncd
    \\
    \\2. Update CA certificates:
    \\   sudo apt-get update && sudo apt-get install -y ca-certificates
    \\   sudo update-ca-certificates
    \\
    \\3. If behind corporate proxy with DPI:
    \\   - Request exemption for validator IPs
    \\   - Or disable DPI for UDP traffic
    \\
    \\4. Test TLS 1.3:
    \\   openssl s_client -connect google.com:443 -tls1_3
    ,
    .performance_impact = "Without QUIC: All network traffic falls back to TCP with ~2-5x higher latency.",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// AF_XDP ISSUES  
// ═══════════════════════════════════════════════════════════════════════════════

pub const AFXDP001 = KnownIssue{
    .id = "AFXDP001",
    .name = "AF_XDP Socket Creation Failed (EPERM)",
    .category = .permission,
    .severity = .high,
    .description = "Cannot create AF_XDP socket due to missing capabilities. This is the #1 cause of AF_XDP failure.",
    .symptoms = &.{
        "AF_XDP socket creation returns EPERM",
        "Falling back to standard UDP",
        "Network throughput severely limited",
        "'Operation not permitted' in logs",
    },
    .causes = &.{
        "Binary missing CAP_NET_RAW capability",
        "CAP_NET_ADMIN not set",
        "Kernel lockdown enabled (Secure Boot)",
        "Running as non-root without capabilities",
    },
    .diagnosis_commands = &.{
        "getcap /opt/vexor/bin/vexor",
        "cat /sys/kernel/security/lockdown",
        "id",
    },
    .auto_fix = .{
        .command = "setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "setcap -r /opt/vexor/bin/vexor",
        .verification_command = "getcap /opt/vexor/bin/vexor | grep -q cap_net_raw && echo 'OK' || echo 'FAILED'",
        .explanation = "Grants the Vexor binary network capabilities required for kernel bypass (AF_XDP). This is the standard way to enable AF_XDP without running as root.",
    },
    .manual_instructions = 
    \\MANUAL FIX FOR AF_XDP CAPABILITIES:
    \\
    \\Run as root:
    \\  sudo setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
    \\
    \\Verify:
    \\  getcap /opt/vexor/bin/vexor
    \\  # Should show: /opt/vexor/bin/vexor cap_net_admin,cap_net_raw,cap_sys_admin=eip
    \\
    \\If kernel lockdown is enabled:
    \\  cat /sys/kernel/security/lockdown
    \\  # If "integrity" or "confidentiality", AF_XDP may not work
    \\  # Consider disabling Secure Boot or using io_uring fallback
    ,
    .performance_impact = "Without AF_XDP: ~10x reduction in packet throughput (1M pps vs 10M pps). Critical for high-stake validators.",
    .references = &.{
        "https://docs.kernel.org/networking/af_xdp.html",
    },
};

pub const AFXDP002 = KnownIssue{
    .id = "AFXDP002",
    .name = "AF_XDP Driver Not Supported",
    .category = .network,
    .severity = .medium,
    .description = "Network interface driver doesn't support XDP. Must use fallback.",
    .symptoms = &.{
        "AF_XDP socket bind fails with EOPNOTSUPP",
        "XDP program load fails",
        "No zero-copy mode available",
    },
    .causes = &.{
        "NIC driver doesn't support XDP",
        "Virtual NIC (some cloud providers)",
        "Old driver version",
        "Kernel too old for driver's XDP support",
    },
    .diagnosis_commands = &.{
        "ethtool -i eth0 | grep driver",
        "uname -r",
        "ls /sys/class/net/*/device/driver",
    },
    .auto_fix = null, // Hardware limitation
    .manual_instructions = 
    \\CHECKING XDP DRIVER SUPPORT:
    \\
    \\Supported drivers (full XDP):
    \\  - i40e (Intel X710, XL710)
    \\  - ice (Intel E810)
    \\  - mlx5_core (Mellanox ConnectX-5/6)
    \\  - ixgbe (Intel 82599, X520, X540)
    \\
    \\Limited XDP support:
    \\  - virtio_net (VirtIO - SKB mode only)
    \\  - e1000e (Intel Pro/1000)
    \\  - ena (AWS ENA - SKB mode)
    \\
    \\No XDP support:
    \\  - hv_netvsc (Hyper-V/Azure)
    \\  - Most Wi-Fi drivers
    \\
    \\OPTIONS:
    \\1. Use a supported NIC (recommended: Intel X710 or Mellanox ConnectX-5)
    \\2. Use io_uring backend (good fallback, ~50% of AF_XDP performance)
    \\3. Use standard UDP (functional but slower)
    \\
    \\To force io_uring fallback, set in /etc/vexor/config.toml:
    \\  [network]
    \\  prefer_io_uring = true
    \\  af_xdp_enabled = false
    ,
    .performance_impact = "With io_uring: ~50% of AF_XDP performance. With standard UDP: ~10% of AF_XDP performance.",
    .references = &.{
        "https://github.com/xdp-project/xdp-tutorial",
    },
};

pub const AFXDP003 = KnownIssue{
    .id = "AFXDP003",
    .name = "libbpf Not Installed",
    .category = .system,
    .severity = .high,
    .description = "libbpf library required for AF_XDP is not installed.",
    .symptoms = &.{
        "BPF program load fails",
        "AF_XDP initialization error",
        "Library not found errors",
    },
    .causes = &.{
        "libbpf package not installed",
        "Wrong version of libbpf",
        "Library path not configured",
    },
    .diagnosis_commands = &.{
        "ldconfig -p | grep -i bpf",
        "apt list --installed 2>/dev/null | grep -i bpf || rpm -qa | grep -i bpf",
        "pkg-config --modversion libbpf 2>/dev/null || echo 'not found'",
    },
    .auto_fix = .{
        .command = "apt-get update && apt-get install -y libbpf-dev || yum install -y libbpf-devel",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "apt-get remove -y libbpf-dev || yum remove -y libbpf-devel",
        .verification_command = "ldconfig -p | grep -q libbpf && echo 'OK' || echo 'FAILED'",
        .explanation = "Installs the libbpf development library required for AF_XDP BPF program loading.",
    },
    .manual_instructions = 
    \\INSTALL libbpf:
    \\
    \\Ubuntu/Debian:
    \\  sudo apt-get update
    \\  sudo apt-get install -y libbpf-dev linux-tools-common
    \\
    \\CentOS/RHEL:
    \\  sudo yum install -y libbpf-devel bpftool
    \\
    \\Verify:
    \\  ldconfig -p | grep libbpf
    \\  # Should show: libbpf.so.0 or libbpf.so.1
    ,
    .performance_impact = "Without libbpf: AF_XDP cannot load BPF programs, completely disabling kernel bypass.",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// STORAGE/IO ISSUES
// ═══════════════════════════════════════════════════════════════════════════════

pub const STOR001 = KnownIssue{
    .id = "STOR001",
    .name = "RAM Disk Not Mounted",
    .category = .storage,
    .severity = .medium,
    .description = "RAM disk (tmpfs) for tier-0 hot storage is not mounted.",
    .symptoms = &.{
        "Account access latency >10μs",
        "No /mnt/vexor/ramdisk mount",
        "Hot accounts stored on disk",
    },
    .causes = &.{
        "tmpfs not mounted",
        "Insufficient RAM",
        "Mount point doesn't exist",
        "Not added to fstab",
    },
    .diagnosis_commands = &.{
        "mount | grep tmpfs | grep vexor",
        "free -h",
        "ls -la /mnt/vexor/ramdisk 2>/dev/null || echo 'not found'",
    },
    .auto_fix = .{
        .command = "mkdir -p /mnt/vexor/ramdisk && mount -t tmpfs -o size=32G,mode=1777 tmpfs /mnt/vexor/ramdisk",
        .risk_level = .medium,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "umount /mnt/vexor/ramdisk",
        .verification_command = "mount | grep -q '/mnt/vexor/ramdisk.*tmpfs' && echo 'OK' || echo 'FAILED'",
        .explanation = "Creates a 32GB RAM disk for hot account data. This significantly reduces account access latency from ~100μs (NVMe) to <1μs (RAM).",
    },
    .manual_instructions = 
    \\SETUP RAM DISK:
    \\
    \\1. Check available RAM (need at least 64GB for 32GB ramdisk):
    \\   free -h
    \\
    \\2. Create mount point:
    \\   sudo mkdir -p /mnt/vexor/ramdisk
    \\
    \\3. Mount tmpfs (adjust size based on available RAM):
    \\   sudo mount -t tmpfs -o size=32G,mode=1777 tmpfs /mnt/vexor/ramdisk
    \\
    \\4. Make permanent (add to /etc/fstab):
    \\   echo 'tmpfs /mnt/vexor/ramdisk tmpfs size=32G,mode=1777 0 0' | sudo tee -a /etc/fstab
    \\
    \\5. Verify:
    \\   df -h /mnt/vexor/ramdisk
    \\
    \\RECOMMENDED SIZES:
    \\  64GB RAM:  16GB ramdisk
    \\  128GB RAM: 32GB ramdisk
    \\  256GB RAM: 64GB ramdisk
    \\  512GB RAM: 128GB ramdisk
    ,
    .performance_impact = "Without ramdisk: Account access latency increases ~100x. Critical for high-frequency voting.",
    .references = &.{},
};

pub const STOR002 = KnownIssue{
    .id = "STOR002",
    .name = "Slow Disk Detected",
    .category = .storage,
    .severity = .medium,
    .description = "Primary storage device is not NVMe or has poor performance.",
    .symptoms = &.{
        "High I/O wait in top",
        "Ledger sync falling behind",
        "Snapshot extraction very slow",
        "HDD detected for validator storage",
    },
    .causes = &.{
        "Using HDD instead of NVMe",
        "SATA SSD instead of NVMe",
        "NVMe thermal throttling",
        "I/O scheduler not optimized",
    },
    .diagnosis_commands = &.{
        "lsblk -d -o NAME,ROTA,MODEL,SIZE",
        "cat /sys/block/*/queue/scheduler",
        "iostat -x 1 3 2>/dev/null | tail -20 || echo 'iostat not available'",
    },
    .auto_fix = .{
        .command = "echo 'none' | tee /sys/block/nvme*/queue/scheduler 2>/dev/null; echo 'mq-deadline' | tee /sys/block/sd*/queue/scheduler 2>/dev/null",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "echo 'mq-deadline' | tee /sys/block/*/queue/scheduler 2>/dev/null",
        .verification_command = "cat /sys/block/*/queue/scheduler | grep -E '\\[none\\]|\\[mq-deadline\\]'",
        .explanation = "Sets optimal I/O scheduler for NVMe (none) and SATA (mq-deadline). This reduces latency and improves throughput.",
    },
    .manual_instructions = 
    \\STORAGE OPTIMIZATION:
    \\
    \\1. Check if using NVMe:
    \\   lsblk -d -o NAME,ROTA,MODEL,SIZE
    \\   # ROTA=0 means SSD/NVMe, ROTA=1 means HDD
    \\
    \\2. If using HDD - STRONGLY RECOMMEND upgrading to NVMe
    \\   Minimum: Samsung 970 EVO Plus or Intel Optane
    \\   Recommended: Samsung 990 Pro or Intel P5800X
    \\
    \\3. Optimize I/O scheduler:
    \\   # For NVMe (scheduler should be 'none'):
    \\   echo 'none' | sudo tee /sys/block/nvme0n1/queue/scheduler
    \\   
    \\   # For SATA SSD:
    \\   echo 'mq-deadline' | sudo tee /sys/block/sda/queue/scheduler
    \\
    \\4. Enable write caching (if UPS available):
    \\   hdparm -W1 /dev/nvme0n1
    \\
    \\PERFORMANCE REFERENCE:
    \\  HDD:      ~150 MB/s, 5-10ms latency
    \\  SATA SSD: ~550 MB/s, 0.1-0.5ms latency
    \\  NVMe:     ~3500 MB/s, 0.02-0.1ms latency
    \\  Optane:   ~2500 MB/s, 0.01ms latency
    ,
    .performance_impact = "HDD vs NVMe: 10-50x performance difference. Can cause vote/block production delays.",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// SYSTEM TUNING ISSUES
// ═══════════════════════════════════════════════════════════════════════════════

pub const TUNE001 = KnownIssue{
    .id = "TUNE001",
    .name = "Network Buffers Too Small",
    .category = .system,
    .severity = .medium,
    .description = "Kernel network buffer sizes are too small for high-throughput validator traffic.",
    .symptoms = &.{
        "UDP packet loss under load",
        "Receive buffer overflows in netstat",
        "Inconsistent network performance",
        "'No buffer space available' errors",
    },
    .causes = &.{
        "Default kernel buffer sizes",
        "System not tuned for high-throughput networking",
    },
    .diagnosis_commands = &.{
        "sysctl net.core.rmem_max net.core.wmem_max",
        "netstat -su 2>/dev/null | grep -i 'receive buffer error' || ss -su | head",
    },
    .auto_fix = .{
        .command = "sysctl -w net.core.rmem_max=134217728 net.core.wmem_max=134217728 net.core.rmem_default=134217728 net.core.wmem_default=134217728",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "sysctl -w net.core.rmem_max=212992 net.core.wmem_max=212992",
        .verification_command = "sysctl net.core.rmem_max | grep -q 134217728 && echo 'OK' || echo 'FAILED'",
        .explanation = "Increases network buffer sizes to 128MB. This prevents packet loss during traffic bursts.",
    },
    .manual_instructions = 
    \\NETWORK BUFFER TUNING:
    \\
    \\1. Set immediately:
    \\   sudo sysctl -w net.core.rmem_max=134217728
    \\   sudo sysctl -w net.core.wmem_max=134217728
    \\   sudo sysctl -w net.core.rmem_default=134217728
    \\   sudo sysctl -w net.core.wmem_default=134217728
    \\   sudo sysctl -w net.ipv4.udp_rmem_min=8192
    \\   sudo sysctl -w net.ipv4.udp_wmem_min=8192
    \\
    \\2. Make permanent:
    \\   cat << 'EOF' | sudo tee /etc/sysctl.d/99-vexor-network.conf
    \\   net.core.rmem_max=134217728
    \\   net.core.wmem_max=134217728
    \\   net.core.rmem_default=134217728
    \\   net.core.wmem_default=134217728
    \\   net.ipv4.udp_rmem_min=8192
    \\   net.ipv4.udp_wmem_min=8192
    \\   EOF
    \\   sudo sysctl --system
    ,
    .performance_impact = "Without tuning: Up to 30% packet loss under heavy load, causing vote/block delays.",
    .references = &.{},
};

pub const TUNE002 = KnownIssue{
    .id = "TUNE002",
    .name = "Huge Pages Not Enabled",
    .category = .system,
    .severity = .low,
    .description = "Huge pages (2MB pages) not enabled, causing TLB misses.",
    .symptoms = &.{
        "High memory allocation latency",
        "Frequent TLB misses in perf",
        "Memory-intensive operations slower than expected",
    },
    .causes = &.{
        "Huge pages not configured",
        "Insufficient contiguous memory",
        "Memory fragmentation",
    },
    .diagnosis_commands = &.{
        "cat /proc/meminfo | grep -i huge",
        "sysctl vm.nr_hugepages",
    },
    .auto_fix = .{
        .command = "sysctl -w vm.nr_hugepages=16384",
        .risk_level = .medium,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "sysctl -w vm.nr_hugepages=0",
        .verification_command = "cat /proc/meminfo | grep HugePages_Total | grep -v '^HugePages_Total:.*0$' && echo 'OK' || echo 'FAILED'",
        .explanation = "Allocates 32GB of huge pages (16384 x 2MB). Reduces TLB misses and improves memory performance.",
    },
    .manual_instructions = 
    \\HUGE PAGES SETUP:
    \\
    \\1. Check current state:
    \\   cat /proc/meminfo | grep -i huge
    \\
    \\2. Calculate pages needed (2MB each):
    \\   32GB = 16384 pages
    \\   64GB = 32768 pages
    \\
    \\3. Enable huge pages:
    \\   sudo sysctl -w vm.nr_hugepages=16384
    \\
    \\4. Make permanent:
    \\   echo 'vm.nr_hugepages=16384' | sudo tee -a /etc/sysctl.d/99-vexor-hugepages.conf
    \\
    \\NOTE: Huge pages reserve contiguous memory. If allocation fails:
    \\  - Reboot and set early in boot
    \\  - Add to GRUB: hugepages=16384
    ,
    .performance_impact = "Without huge pages: ~5-10% performance reduction in memory-intensive operations.",
    .references = &.{},
};

pub const TUNE003 = KnownIssue{
    .id = "TUNE003",
    .name = "File Descriptor Limit Too Low",
    .category = .system,
    .severity = .high,
    .description = "System file descriptor limit is too low for validator operation.",
    .symptoms = &.{
        "'Too many open files' errors",
        "Connection failures",
        "Unable to open snapshot files",
    },
    .causes = &.{
        "Default ulimit too low",
        "System-wide limit not increased",
        "PAM limits not configured",
    },
    .diagnosis_commands = &.{
        "ulimit -n",
        "cat /proc/sys/fs/file-max",
        "grep -r 'nofile' /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null",
    },
    .auto_fix = .{
        .command = "echo '* soft nofile 1000000' >> /etc/security/limits.conf && echo '* hard nofile 1000000' >> /etc/security/limits.conf && sysctl -w fs.file-max=2097152",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = null,
        .verification_command = "grep nofile /etc/security/limits.conf | tail -1",
        .explanation = "Sets file descriptor limit to 1,000,000 for all users. Required for validators handling many concurrent connections.",
    },
    .manual_instructions = 
    \\FILE DESCRIPTOR LIMITS:
    \\
    \\1. Set system-wide limit:
    \\   sudo sysctl -w fs.file-max=2097152
    \\   echo 'fs.file-max=2097152' | sudo tee -a /etc/sysctl.d/99-vexor-limits.conf
    \\
    \\2. Set per-user limits (/etc/security/limits.conf):
    \\   solana soft nofile 1000000
    \\   solana hard nofile 1000000
    \\
    \\3. Set systemd service limit (if using systemd):
    \\   # In /etc/systemd/system/vexor.service
    \\   [Service]
    \\   LimitNOFILE=1000000
    \\
    \\4. Verify (need re-login):
    \\   ulimit -n
    ,
    .performance_impact = "Without increase: Validator will crash when opening many peer connections or snapshot files.",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// ALL ISSUES ARRAY
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// IO_URING ISSUES
// ═══════════════════════════════════════════════════════════════════════════════

pub const IOURING001 = KnownIssue{
    .id = "IOURING001",
    .name = "Kernel Too Old for io_uring",
    .category = .system,
    .severity = .medium,
    .description = "Kernel version doesn't support io_uring, limiting fallback options.",
    .symptoms = &.{
        "io_uring initialization fails",
        "No async I/O fallback available",
    },
    .causes = &.{
        "Kernel older than 5.1",
    },
    .diagnosis_commands = &.{
        "uname -r",
    },
    .auto_fix = null,
    .manual_instructions = 
    \\io_uring requires kernel 5.1+. Consider upgrading:
    \\  Ubuntu: sudo apt-get install linux-image-generic-hwe-22.04
    ,
    .performance_impact = "Without io_uring: Must use standard UDP (~5x slower than io_uring)",
    .references = &.{},
};

pub const IOURING002 = KnownIssue{
    .id = "IOURING002",
    .name = "liburing Not Installed",
    .category = .system,
    .severity = .low,
    .description = "liburing library required for io_uring is not installed.",
    .symptoms = &.{
        "io_uring fallback unavailable",
    },
    .causes = &.{
        "liburing package not installed",
    },
    .diagnosis_commands = &.{
        "ldconfig -p | grep liburing",
    },
    .auto_fix = .{
        .command = "apt-get update && apt-get install -y liburing-dev",
        .risk_level = .low,
        .requires_sudo = true,
        .reversible = true,
        .rollback_command = "apt-get remove -y liburing-dev",
        .verification_command = "ldconfig -p | grep liburing",
        .explanation = "Installs liburing for io_uring support.",
    },
    .manual_instructions = 
    \\Ubuntu/Debian: sudo apt-get install -y liburing-dev
    \\CentOS/RHEL: sudo yum install -y liburing-devel
    ,
    .performance_impact = "Without liburing: io_uring fallback unavailable",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// GPU ISSUES
// ═══════════════════════════════════════════════════════════════════════════════

pub const GPU001 = KnownIssue{
    .id = "GPU001",
    .name = "NVIDIA GPU Detected but CUDA Not Installed",
    .category = .compute,
    .severity = .low,
    .description = "System has an NVIDIA GPU but CUDA toolkit is not installed.",
    .symptoms = &.{
        "GPU signature verification unavailable",
    },
    .causes = &.{
        "CUDA toolkit not installed",
    },
    .diagnosis_commands = &.{
        "nvidia-smi",
        "nvcc --version",
    },
    .auto_fix = null,
    .manual_instructions = 
    \\To enable GPU signature verification:
    \\1. Install CUDA Toolkit from: https://developer.nvidia.com/cuda-downloads
    \\2. Rebuild Vexor with -Dgpu=true
    ,
    .performance_impact = "GPU can verify ~500K signatures/sec (10x faster than CPU)",
    .references = &.{},
};

// ═══════════════════════════════════════════════════════════════════════════════
// ALL ISSUES ARRAY
// ═══════════════════════════════════════════════════════════════════════════════

pub const all_issues = [_]KnownIssue{
    // MASQUE/QUIC
    MASQUE001,
    MASQUE002,
    MASQUE003,
    // AF_XDP
    AFXDP001,
    AFXDP002,
    AFXDP003,
    // Storage
    STOR001,
    STOR002,
    // System Tuning
    TUNE001,
    TUNE002,
    TUNE003,
    // io_uring
    IOURING001,
    IOURING002,
    // GPU
    GPU001,
};

/// Get all issues in a category
pub fn getIssuesByCategory(category: Category) []const KnownIssue {
    var count: usize = 0;
    for (all_issues) |issue| {
        if (issue.category == category) count += 1;
    }
    
    // Note: In real use, this would need proper allocation
    // For now, caller should iterate all_issues and filter
    return &.{};
}

/// Find issue by ID
pub fn findIssueById(id: []const u8) ?KnownIssue {
    for (all_issues) |issue| {
        if (std.mem.eql(u8, issue.id, id)) {
            return issue;
        }
    }
    return null;
}

