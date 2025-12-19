# Vexor Installation Guide

**High-performance Solana validator client written in Zig with AF_XDP kernel bypass networking.**

---

## 🚀 Quick Install

```bash
# 1. Test the installer first (dry-run, no changes) - RECOMMENDED!
./vexor-install --dry-run install --testnet

# 2. Run the interactive installer
sudo ./vexor-install install --testnet

# 3. After installation, set up AF_XDP (for 10x packet performance)
sudo /opt/vexor/bin/setup-afxdp.sh
```

**💡 Tip:** Always run with `--dry-run` first to see what changes will be made!

---

## 📋 Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 8 cores | 16+ cores (AMD Ryzen 9 / Intel Xeon) |
| RAM | 32 GB | 128+ GB |
| Storage | 500 GB NVMe | 2+ TB NVMe |
| Network | 1 Gbps | 10 Gbps |

### Software Requirements

| Package | Purpose |
|---------|---------|
| Linux Kernel 5.x+ | AF_XDP support |
| `libbpf-dev` | eBPF/XDP library |
| `libcap2-bin` | Capability management (setcap) |

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y libbpf-dev libcap2-bin
```

---

## 🔧 Installation Steps

### Step 1: Test the Installer (Dry-Run) - RECOMMENDED!

```bash
# Test without making changes
./vexor-install --dry-run install --testnet

# This will show you:
# - What hardware will be detected
# - What issues will be found
# - What fixes will be applied
# - What changes will be made
# - NO actual changes will be made
```

### Step 2: Run the Interactive Installer

```bash
# For testnet
sudo ./vexor-install install --testnet

# For mainnet (when ready)
sudo ./vexor-install install --mainnet-beta

# For devnet
sudo ./vexor-install install --devnet
```

The unified installer will:
1. **Create automatic backup** (before any changes)
2. **Detect hardware** (CPU, RAM, GPU, network)
3. **Run comprehensive audit** (network, storage, compute, system)
4. **Detect existing validator** (Agave, Firedancer, Jito, etc.)
5. **Detect existing keys** (identity and vote account)
6. **Key selection prompt** (use existing or create new)
7. **Generate recommendations** (based on your hardware)
8. **Request permissions** (for each change)
9. **Apply fixes** (low-risk auto-fixes)
10. **Install binary** (with AF_XDP capabilities)
11. **Create directories** (ledger, accounts, snapshots)
12. **Create config files** (TOML configuration)
13. **Setup systemd service** (for auto-start)
14. **Setup dual system** (automatic client switching)
15. **Apply system tuning** (if approved)

### Step 2: Set Up AF_XDP (Critical for Performance)

```bash
sudo /opt/vexor/bin/setup-afxdp.sh
```

This script will:
- Install `libbpf-dev` and `libcap2-bin` if missing
- Set capabilities on the vexor binary:
  - `CAP_NET_RAW` - Raw socket access
  - `CAP_NET_ADMIN` - Network administration
  - `CAP_SYS_ADMIN` - System administration (for XDP)
- Verify the setup

**Why AF_XDP?**
- Standard UDP: ~1M packets/second
- AF_XDP: ~10M packets/second ⚡

### Step 3: Verify Installation

```bash
# Check capabilities
getcap /opt/vexor/bin/vexor
# Expected: /opt/vexor/bin/vexor cap_net_admin,cap_net_raw,cap_sys_admin=eip

# Check validator status
validator-status

# Test RPC (without starting full validator)
curl -s http://localhost:8900 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}'
```

---

## 🔄 Dual-Client Setup (Running Alongside Agave)

Vexor is designed to run safely alongside your existing Agave validator:

| Component | Agave | Vexor |
|-----------|-------|-------|
| Identity | Shared | Shared |
| Vote Account | Shared | Shared |
| Ledger | `/mnt/solana/ledger` | `/mnt/vexor/ledger` |
| Accounts | `/mnt/solana/accounts` | `/mnt/vexor/accounts` |
| Snapshots | `/mnt/solana/snapshots` | `/mnt/vexor/snapshots` |
| RPC Port | 8899 | 8900 |
| Gossip Port | 8001 | 8002 |

### Switching Between Clients

```bash
# Check current status
validator-status

# Switch to Vexor (stops ANY existing client, starts Vexor)
# Works with: Agave, Firedancer, Jito, Frankendancer
switch-to-vexor

# Switch back to previous client (stops Vexor, starts whatever was running)
switch-to-previous

# Legacy alias (still works)
switch-to-agave
```

**Safety Features:**
- Automatic backup before switching
- Pre-switch validation
- Alert notifications (if configured)

---

## ⚡ AF_XDP Technical Details

### What is AF_XDP?

AF_XDP (Address Family XDP) is a Linux kernel feature that allows user-space applications to receive and transmit network packets with minimal kernel overhead.

### How Vexor Uses AF_XDP

```
Traditional Path:
  NIC → Kernel → Socket → User Space
  Latency: ~10-50µs per packet

AF_XDP Path:
  NIC → UMEM (shared memory) → User Space
  Latency: ~1-5µs per packet
```

### Multi-Queue Support

Vexor uses separate queues for different traffic types:
- **Queue 0**: Shred reception (TVU)
- **Queue 1**: Repair requests

This prevents queue contention and maximizes throughput.

### Interface Auto-Detection

Vexor automatically detects your default network interface from the routing table:

```bash
# Manual check
ip route | grep default
# default via 10.0.0.1 dev enp1s0f0 ...
#                          ^^^^^^^^^ This interface is used
```

### Troubleshooting AF_XDP

| Issue | Solution |
|-------|----------|
| "AF_XDP not available" | Run `sudo /opt/vexor/bin/setup-afxdp.sh` |
| "Bind failed: queue already in use" | Another process is using that queue |
| "Permission denied" | Capabilities not set correctly |
| "Interface not found" | Check interface name in config |

---

## 📁 Directory Structure

```
/opt/vexor/
├── bin/
│   ├── vexor              # Main validator binary
│   ├── vexor-install      # Interactive installer
│   ├── vexor-optimize     # System optimizer
│   ├── vexor-switch       # Client switcher
│   └── setup-afxdp.sh     # AF_XDP setup script
├── etc/
│   └── vexor/
│       ├── config.toml    # Main configuration
│       └── alerts.toml    # Alert configuration

/mnt/vexor/
├── ledger/                # Blockchain data
├── accounts/              # Account state
└── snapshots/             # Snapshot storage

/var/backups/vexor/        # Automatic backups
/var/log/vexor/            # Log files
```

---

## 🛡️ Security Considerations

### Why Capabilities Instead of Root?

Running as root is dangerous. Instead, Vexor uses Linux capabilities:

```bash
# Only these capabilities are needed:
cap_net_raw      # Raw socket access for AF_XDP
cap_net_admin    # Network interface configuration
cap_sys_admin    # XDP program loading
```

### File Permissions

```bash
# Vexor binary (owned by root, executable by solana user)
-rwxr-xr-x root root /opt/vexor/bin/vexor

# Keypairs (owned by solana, readable only by solana)
-r-------- solana solana /home/solana/.secrets/validator-keypair.json
```

---

## 📊 Performance Comparison

| Metric | Agave | Vexor |
|--------|-------|-------|
| Language | Rust | Zig |
| Packet Rate | ~1M pps (UDP) | ~10M pps (AF_XDP) |
| Memory Usage | Higher | Lower (no GC) |
| Startup Time | ~30s | ~5s |
| Binary Size | ~150 MB | ~4 MB |

---

## 🔗 Related Documentation

- [Vexor Architecture](./ARCHITECTURE.md)
- [CLI Reference](./CLI.md)
- [Troubleshooting](./TROUBLESHOOTING.md)
- [Contributing](./CONTRIBUTING.md)

---

## 📞 Support

- **GitHub Issues**: [github.com/your-org/vexor/issues](https://github.com/your-org/vexor/issues)
- **Discord**: Join our validator community
- **Email**: support@example.com

---

*Vexor - High-performance Solana validation for everyone.*

