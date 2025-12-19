# VEXOR Deployment & Testing Guide
## For Cursor IDE - Safe Client Swapping Setup

---

# REBUILD CONTEXT (December 2025)

## What Happened

The original server SSD failed after **2.74 PB written** (117% of rated lifespan). A complete rebuild was performed:

- **Old OS:** Ubuntu (version unknown)
- **New OS:** Fedora 43 Server (Kernel 6.17.11)
- **Reason for Fedora:** Better AMD 7950X3D support, latest XDP/eBPF for VEXOR development

## What Was Preserved (from VPS backup at 148.230.81.56)

- ✅ Validator keypairs (`validator-keypair.json`, `vote-account-keypair.json`)
- ✅ Monitoring scripts and configuration
- ✅ Telegraf configuration

## What Was Rebuilt from Scratch

- ❌ Operating system (fresh Fedora 43 install)
- ❌ All kernel/sysctl optimizations (50+ parameters)
- ❌ Agave validator (built from source v3.1.4)
- ❌ Ledger data (re-synced from testnet)

## Build Note: RocksDB + GCC 15

Fedora 43 uses GCC 15, which broke the bundled RocksDB build. Solution was to use system `rocksdb-devel` package instead. If rebuilding Agave, you may need:

```bash
dnf install rocksdb-devel
export ROCKSDB_LIB_DIR=/usr/lib64
export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH
```

---

# SERVER ACCESS

## SSH Connection

```bash
# Connect as root (for system operations)
ssh root@38.92.24.174

# Connect as sol (for validator operations)
ssh sol@38.92.24.174
```

## Server Details

```yaml
IP Address: 38.92.24.174
SSH Port: 22
Hostname: qubestake
OS: Fedora 43 Server
Kernel: 6.17.11-300.fc43.x86_64
```

## Users

| User | Password | Purpose |
|------|----------|---------|
| root | (key-based or known) | System administration |
| sol | (key-based or known) | Validator operations |

---

# RECOMMENDED DIRECTORY STRUCTURE

```
/home/sol/
├── agave/                      # Current Agave client (KEEP)
│   └── bin/
│       └── agave-validator
├── vexor/                      # NEW: VEXOR client
│   ├── bin/
│   │   └── vexor-validator     # VEXOR binary
│   ├── src/                    # Source code (optional)
│   ├── build.zig
│   └── config/
│       └── vexor.toml          # VEXOR-specific config
├── keypairs/                   # Shared keypairs (BOTH clients use)
│   ├── validator-keypair.json
│   ├── vote-account-keypair.json
│   └── authorized-withdrawer-keypair.json
├── ledger/                     # Shared ledger (BOTH clients use)
├── accounts-ramdisk/           # Symlink to /mnt/ramdisk
├── logs/
│   ├── validator.log           # Active client log
│   ├── agave.log              # Agave-specific logs
│   └── vexor.log              # VEXOR-specific logs
├── scripts/                    # NEW: Management scripts
│   ├── start-agave.sh
│   ├── start-vexor.sh
│   ├── switch-client.sh
│   └── status.sh
├── validator.sh                # Active startup script (symlink)
├── validator-agave.sh          # Agave startup script
└── validator-vexor.sh          # VEXOR startup script
```

---

# INITIAL SETUP COMMANDS

## 1. Create Directory Structure

```bash
# SSH to server
ssh root@38.92.24.174

# Create VEXOR directories
mkdir -p /home/sol/vexor/{bin,src,config}
mkdir -p /home/sol/scripts
mkdir -p /home/sol/logs

# Set ownership
chown -R sol:sol /home/sol/vexor
chown -R sol:sol /home/sol/scripts
```

## 2. Install Zig (if not already installed)

```bash
# Download Zig 0.13.0
cd /opt
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar -xf zig-linux-x86_64-0.13.0.tar.xz
ln -sf /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig

# Verify
zig version
# Should output: 0.13.0
```

## 3. Install Build Dependencies

```bash
# For AF_XDP, io_uring, eBPF support
dnf install -y \
    libbpf-devel \
    libxdp-devel \
    liburing-devel \
    clang \
    llvm \
    make \
    git
```

---

# STARTUP SCRIPTS

## Agave Startup Script

File: `/home/sol/validator-agave.sh`

```bash
#!/bin/bash
# Agave Validator Startup Script
# Client: Agave 3.1.4

LOG_FILE="/home/sol/logs/agave.log"

exec /home/sol/agave/bin/agave-validator \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --authorized-voter /home/sol/keypairs/validator-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log "$LOG_FILE" \
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
    --limit-ledger-size 50000000
```

## VEXOR Startup Script (Template)

File: `/home/sol/validator-vexor.sh`

```bash
#!/bin/bash
# VEXOR Validator Startup Script
# Client: VEXOR (Zig-based)

LOG_FILE="/home/sol/logs/vexor.log"

# VEXOR-specific environment variables
export VEXOR_LOG_LEVEL=info
export VEXOR_TILE_THREADS=30

exec /home/sol/vexor/bin/vexor-validator \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log "$LOG_FILE" \
    --entrypoint entrypoint.testnet.solana.com:8001 \
    --entrypoint entrypoint2.testnet.solana.com:8001 \
    --entrypoint entrypoint3.testnet.solana.com:8001 \
    --rpc-port 8899 \
    --dynamic-port-range 8000-8050
```

## Client Switching Script

File: `/home/sol/scripts/switch-client.sh`

```bash
#!/bin/bash
# Safe Client Switching Script
# Usage: ./switch-client.sh [agave|vexor]

set -e

CLIENT=$1
CURRENT_LINK=$(readlink /home/sol/validator.sh 2>/dev/null || echo "none")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [agave|vexor]"
    echo ""
    echo "Commands:"
    echo "  agave  - Switch to Agave validator client"
    echo "  vexor  - Switch to VEXOR validator client"
    echo "  status - Show current client"
    exit 1
}

show_status() {
    echo -e "${YELLOW}Current Configuration:${NC}"
    echo "  Active script: $CURRENT_LINK"
    
    if systemctl is-active --quiet solana-validator; then
        echo -e "  Service status: ${GREEN}RUNNING${NC}"
        PID=$(pgrep -f "validator" | head -1)
        if [ -n "$PID" ]; then
            BINARY=$(readlink -f /proc/$PID/exe 2>/dev/null || echo "unknown")
            echo "  Running binary: $BINARY"
        fi
    else
        echo -e "  Service status: ${RED}STOPPED${NC}"
    fi
}

switch_to_agave() {
    echo -e "${YELLOW}Switching to Agave...${NC}"
    
    # Check if Agave binary exists
    if [ ! -f /home/sol/agave/bin/agave-validator ]; then
        echo -e "${RED}ERROR: Agave binary not found at /home/sol/agave/bin/agave-validator${NC}"
        exit 1
    fi
    
    # Stop current validator
    echo "Stopping current validator..."
    systemctl stop solana-validator || true
    sleep 5
    
    # Update symlink
    ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh
    
    # Start Agave
    echo "Starting Agave validator..."
    systemctl start solana-validator
    
    echo -e "${GREEN}Switched to Agave successfully!${NC}"
}

switch_to_vexor() {
    echo -e "${YELLOW}Switching to VEXOR...${NC}"
    
    # Check if VEXOR binary exists
    if [ ! -f /home/sol/vexor/bin/vexor-validator ]; then
        echo -e "${RED}ERROR: VEXOR binary not found at /home/sol/vexor/bin/vexor-validator${NC}"
        echo "Please build VEXOR first."
        exit 1
    fi
    
    # Stop current validator
    echo "Stopping current validator..."
    systemctl stop solana-validator || true
    sleep 5
    
    # Update symlink
    ln -sf /home/sol/validator-vexor.sh /home/sol/validator.sh
    
    # Start VEXOR
    echo "Starting VEXOR validator..."
    systemctl start solana-validator
    
    echo -e "${GREEN}Switched to VEXOR successfully!${NC}"
}

# Main logic
case "$CLIENT" in
    agave)
        switch_to_agave
        ;;
    vexor)
        switch_to_vexor
        ;;
    status)
        show_status
        ;;
    *)
        show_status
        echo ""
        usage
        ;;
esac
```

## Status Check Script

File: `/home/sol/scripts/status.sh`

```bash
#!/bin/bash
# Validator Status Script

echo "=== QubeStake Validator Status ==="
echo ""

# Current client
CURRENT=$(readlink /home/sol/validator.sh 2>/dev/null | xargs basename | sed 's/validator-//' | sed 's/.sh//')
echo "Active Client: ${CURRENT:-unknown}"

# Service status
echo ""
echo "=== Service Status ==="
systemctl status solana-validator --no-pager | head -10

# Catchup status
echo ""
echo "=== Catchup Status ==="
/home/sol/.local/share/solana/install/active_release/bin/solana catchup --our-localhost 2>&1 | head -3

# Resource usage
echo ""
echo "=== Resource Usage ==="
echo "CPU: $(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage "%"}')"
echo "RAM: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo "Ramdisk: $(df -h /mnt/ramdisk | awk 'NR==2 {print $3 "/" $2}')"

# Thread count
if pgrep -f "validator" > /dev/null; then
    THREADS=$(ps -T -p $(pgrep -f "validator" | head -1) | wc -l)
    echo "Validator Threads: $THREADS"
fi
```

---

# SYSTEMD SERVICE UPDATE

The systemd service should call the symlinked script:

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

---

# DEPLOYMENT WORKFLOW

## Step 1: Initial Setup (Run Once)

```bash
# SSH to server as root
ssh root@38.92.24.174

# Create directories
mkdir -p /home/sol/vexor/{bin,src,config}
mkdir -p /home/sol/scripts

# Create startup scripts
cat > /home/sol/validator-agave.sh << 'AGAVE_EOF'
#!/bin/bash
exec /home/sol/agave/bin/agave-validator \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --authorized-voter /home/sol/keypairs/validator-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log /home/sol/logs/agave.log \
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
    --limit-ledger-size 50000000
AGAVE_EOF

chmod +x /home/sol/validator-agave.sh

# Set up symlink to current (Agave)
ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh

# Set ownership
chown -R sol:sol /home/sol/vexor /home/sol/scripts /home/sol/validator-*.sh
```

## Step 2: Transfer VEXOR from Local Machine

From your local development machine (where Cursor is):

```bash
# Build VEXOR (in Cursor terminal)
cd /path/to/vexor
zig build -Doptimize=ReleaseFast

# Transfer binary to server
scp zig-out/bin/vexor-validator root@38.92.24.174:/home/sol/vexor/bin/

# Transfer source (optional, for debugging)
rsync -avz --exclude 'zig-cache' --exclude 'zig-out' \
    /path/to/vexor/ root@38.92.24.174:/home/sol/vexor/src/
```

## Step 3: Create VEXOR Startup Script

```bash
# SSH to server
ssh root@38.92.24.174

# Create VEXOR startup script (adjust flags as needed for VEXOR)
cat > /home/sol/validator-vexor.sh << 'VEXOR_EOF'
#!/bin/bash
export VEXOR_LOG_LEVEL=info

exec /home/sol/vexor/bin/vexor-validator \
    --identity /home/sol/keypairs/validator-keypair.json \
    --vote-account /home/sol/keypairs/vote-account-keypair.json \
    --ledger /home/sol/ledger \
    --accounts /home/sol/accounts-ramdisk \
    --log /home/sol/logs/vexor.log \
    --entrypoint entrypoint.testnet.solana.com:8001 \
    --entrypoint entrypoint2.testnet.solana.com:8001 \
    --entrypoint entrypoint3.testnet.solana.com:8001 \
    --rpc-port 8899 \
    --dynamic-port-range 8000-8050
VEXOR_EOF

chmod +x /home/sol/validator-vexor.sh
chown sol:sol /home/sol/validator-vexor.sh
```

## Step 4: Test VEXOR

```bash
# Switch to VEXOR
/home/sol/scripts/switch-client.sh vexor

# Monitor logs
tail -f /home/sol/logs/vexor.log

# Check status
/home/sol/scripts/status.sh

# If issues, switch back to Agave
/home/sol/scripts/switch-client.sh agave
```

---

# SAFE TESTING WORKFLOW

## Quick Swap Commands

```bash
# Check current status
/home/sol/scripts/switch-client.sh status

# Switch to Agave (stable)
/home/sol/scripts/switch-client.sh agave

# Switch to VEXOR (testing)
/home/sol/scripts/switch-client.sh vexor

# Emergency: Force stop and start Agave
systemctl stop solana-validator
ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh
systemctl start solana-validator
```

## Testing Checklist

Before switching to VEXOR:

- [ ] VEXOR binary exists: `ls -la /home/sol/vexor/bin/vexor-validator`
- [ ] VEXOR script executable: `ls -la /home/sol/validator-vexor.sh`
- [ ] Keypairs accessible: `ls -la /home/sol/keypairs/`
- [ ] Ledger healthy: `du -sh /home/sol/ledger`
- [ ] Ramdisk mounted: `df -h /mnt/ramdisk`
- [ ] Timeshift backup created: `timeshift --create --comments "Pre-VEXOR-Test"`

After switching to VEXOR:

- [ ] Service running: `systemctl status solana-validator`
- [ ] Logs clean: `tail -50 /home/sol/logs/vexor.log`
- [ ] RPC responding: `curl localhost:8899 -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}'`
- [ ] Gossip connected: Check log for peer connections
- [ ] Catching up: `solana catchup --our-localhost`

---

# CURSOR IDE QUICK REFERENCE

## SSH Extension Setup

1. Install "Remote - SSH" extension in VS Code/Cursor
2. Add SSH config (`~/.ssh/config`):

```
Host qubestake
    HostName 38.92.24.174
    User root
    IdentityFile ~/.ssh/id_rsa
```

3. Connect: `Ctrl+Shift+P` → "Remote-SSH: Connect to Host" → `qubestake`

## Direct Terminal Commands

From Cursor terminal:

```bash
# Quick deploy new VEXOR build
zig build -Doptimize=ReleaseFast && \
scp zig-out/bin/vexor-validator root@38.92.24.174:/home/sol/vexor/bin/ && \
ssh root@38.92.24.174 "/home/sol/scripts/switch-client.sh vexor"

# Quick check status
ssh root@38.92.24.174 "/home/sol/scripts/status.sh"

# Quick switch back to Agave
ssh root@38.92.24.174 "/home/sol/scripts/switch-client.sh agave"
```

---

# TROUBLESHOOTING

## VEXOR Won't Start

```bash
# Check binary permissions
ls -la /home/sol/vexor/bin/vexor-validator
# Should be: -rwxr-xr-x

# Check for missing libraries
ldd /home/sol/vexor/bin/vexor-validator

# Run manually to see errors
/home/sol/vexor/bin/vexor-validator --help

# Check logs
tail -100 /home/sol/logs/vexor.log
```

## Emergency Recovery

```bash
# Force switch to Agave
systemctl stop solana-validator
pkill -9 -f validator
ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh
systemctl start solana-validator

# Verify
systemctl status solana-validator
```

---

# SUMMARY

| Item | Path |
|------|------|
| Server IP | 38.92.24.174 |
| SSH User | root or sol |
| Agave Binary | /home/sol/agave/bin/agave-validator |
| VEXOR Binary | /home/sol/vexor/bin/vexor-validator |
| Active Script | /home/sol/validator.sh (symlink) |
| Switch Command | /home/sol/scripts/switch-client.sh [agave\|vexor] |
| Keypairs | /home/sol/keypairs/ |
| Ledger | /home/sol/ledger/ |
| Logs | /home/sol/logs/ |

**Safe Testing Flow:**
1. Build VEXOR locally
2. `scp` binary to server
3. `switch-client.sh vexor`
4. Monitor logs
5. If issues: `switch-client.sh agave`

---

*Document Version: 1.0*
*Created: December 17, 2025*

