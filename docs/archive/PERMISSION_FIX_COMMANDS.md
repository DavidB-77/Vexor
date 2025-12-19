# Vexor Permission Fix Commands

> **Note**: The unified installer now includes a built-in permission fix command:
> ```bash
> sudo vexor-install fix-permissions
> ```
> The commands below are for manual/emergency fixes.

**For:** Test Validator (38.92.24.174)  
**User:** davidb / solana  
**Created:** December 13, 2024

---

## 🚀 Quick Fix (Run This First)

SSH to your validator and run this single script as root:

```bash
# SSH to validator
ssh davidb@38.92.24.174

# Run the comprehensive permission fix
sudo bash << 'PERMISSION_FIX'
#!/bin/bash
set -e

echo "═══════════════════════════════════════════════════════════════"
echo "            VEXOR PERMISSION FIX SCRIPT"
echo "═══════════════════════════════════════════════════════════════"
echo ""

VEXOR_USER="solana"
VEXOR_GROUP="solana"

# ═══════════════════════════════════════════════════════════════════
# 1. CREATE DIRECTORIES
# ═══════════════════════════════════════════════════════════════════
echo "[1/7] Creating directories..."

mkdir -p /opt/vexor/bin
mkdir -p /mnt/vexor/ledger
mkdir -p /mnt/vexor/accounts
mkdir -p /mnt/vexor/snapshots
mkdir -p /var/log/vexor
mkdir -p /var/run/vexor
mkdir -p /var/backups/vexor
mkdir -p /etc/vexor

echo "  ✅ Directories created"

# ═══════════════════════════════════════════════════════════════════
# 2. SET OWNERSHIP
# ═══════════════════════════════════════════════════════════════════
echo "[2/7] Setting ownership..."

chown -R ${VEXOR_USER}:${VEXOR_GROUP} /mnt/vexor
chown -R ${VEXOR_USER}:${VEXOR_GROUP} /var/log/vexor
chown -R ${VEXOR_USER}:${VEXOR_GROUP} /var/run/vexor
chown -R ${VEXOR_USER}:${VEXOR_GROUP} /var/backups/vexor
chown root:root /opt/vexor/bin
chown root:root /etc/vexor

echo "  ✅ Ownership set"

# ═══════════════════════════════════════════════════════════════════
# 3. SET PERMISSIONS
# ═══════════════════════════════════════════════════════════════════
echo "[3/7] Setting permissions..."

chmod 755 /opt/vexor/bin
chmod 755 /mnt/vexor
chmod 755 /mnt/vexor/ledger
chmod 755 /mnt/vexor/accounts
chmod 755 /mnt/vexor/snapshots
chmod 755 /var/log/vexor
chmod 755 /var/run/vexor
chmod 755 /var/backups/vexor
chmod 755 /etc/vexor

echo "  ✅ Permissions set"

# ═══════════════════════════════════════════════════════════════════
# 4. FIX SNAPSHOT EXTRACTION PERMISSIONS
# ═══════════════════════════════════════════════════════════════════
echo "[4/7] Fixing snapshot extraction permissions..."

if [ -d "/mnt/vexor/snapshots/extracted-374576751" ]; then
    chmod -R u+r /mnt/vexor/snapshots/extracted-374576751
    chown -R ${VEXOR_USER}:${VEXOR_GROUP} /mnt/vexor/snapshots/extracted-374576751
    echo "  ✅ Snapshot extraction permissions fixed"
else
    echo "  ⚠️  No extracted snapshot found (will be fixed during extraction)"
fi

# ═══════════════════════════════════════════════════════════════════
# 5. SET AF_XDP CAPABILITIES
# ═══════════════════════════════════════════════════════════════════
echo "[5/7] Setting AF_XDP capabilities..."

if [ -f "/opt/vexor/bin/vexor" ]; then
    setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
    echo "  ✅ AF_XDP capabilities set"
    getcap /opt/vexor/bin/vexor
else
    echo "  ⚠️  Vexor binary not found, skipping capabilities"
fi

# ═══════════════════════════════════════════════════════════════════
# 6. FIX SYSTEMD SERVICE
# ═══════════════════════════════════════════════════════════════════
echo "[6/7] Configuring systemd service..."

if [ ! -f "/etc/systemd/system/vexor.service" ]; then
    cat > /etc/systemd/system/vexor.service << 'EOF'
[Unit]
Description=Vexor Solana Validator
After=network.target
Wants=network-online.target
Conflicts=solana-validator.service

[Service]
Type=simple
User=solana
Group=solana
WorkingDirectory=/home/solana
ExecStart=/opt/vexor/bin/vexor run --bootstrap --testnet --identity /home/solana/.secrets/validator-keypair.json --vote-account /home/solana/.secrets/vote-account-keypair.json --ledger /mnt/vexor/ledger --accounts /mnt/vexor/accounts --snapshots /mnt/vexor/snapshots --entrypoint entrypoint.testnet.solana.com:8001 --rpc-port 8900 --gossip-port 8801
ExecStop=/bin/kill -SIGTERM $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=1000000
LimitNPROC=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo "  ✅ Systemd service created"
else
    echo "  ✅ Systemd service already exists"
fi

# ═══════════════════════════════════════════════════════════════════
# 7. FIX SWITCH SCRIPTS
# ═══════════════════════════════════════════════════════════════════
echo "[7/7] Updating switch scripts..."

cat > /usr/local/bin/switch-to-vexor << 'SCRIPT'
#!/bin/bash
set -e
echo "═══════════════════════════════════════════════════════════════"
echo "           SWITCHING TO VEXOR VALIDATOR"
echo "═══════════════════════════════════════════════════════════════"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo switch-to-vexor"
    exit 1
fi

# Pre-switch backup
echo "Creating pre-switch backup..."
BACKUP_DIR="/var/backups/vexor/switchover-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -p /home/solana/.secrets/validator-keypair.json "$BACKUP_DIR/" 2>/dev/null || true
echo "  Backup: $BACKUP_DIR"

# Stop Agave
echo "Stopping Agave (solana-validator)..."
systemctl stop solana-validator || true
sleep 5

# Start Vexor
echo "Starting Vexor..."
systemctl start vexor

sleep 3
if systemctl is-active --quiet vexor; then
    echo "✅ Vexor is running"
    journalctl -u vexor --no-pager -n 10
else
    echo "❌ Vexor failed to start - rolling back..."
    systemctl start solana-validator
    exit 1
fi
SCRIPT
chmod +x /usr/local/bin/switch-to-vexor

cat > /usr/local/bin/switch-to-agave << 'SCRIPT'
#!/bin/bash
set -e
echo "═══════════════════════════════════════════════════════════════"
echo "           SWITCHING BACK TO AGAVE"
echo "═══════════════════════════════════════════════════════════════"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo switch-to-agave"
    exit 1
fi

# Stop Vexor
echo "Stopping Vexor..."
systemctl stop vexor || true
sleep 5

# Start Agave
echo "Starting Agave..."
systemctl start solana-validator

sleep 3
if systemctl is-active --quiet solana-validator; then
    echo "✅ Agave is running"
else
    echo "❌ Agave failed to start!"
    exit 1
fi
SCRIPT
chmod +x /usr/local/bin/switch-to-agave

cat > /usr/local/bin/validator-status << 'SCRIPT'
#!/bin/bash
echo "═══════════════════════════════════════════════════════════════"
echo "             VALIDATOR STATUS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if systemctl is-active --quiet vexor 2>/dev/null; then
    echo "🟢 VEXOR:  RUNNING"
    echo "   Port 8900: $(curl -s http://localhost:8900 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null | grep -q ok && echo '✅ Healthy' || echo '⏳ Starting...')"
else
    echo "⚪ VEXOR:  stopped"
fi

if systemctl is-active --quiet solana-validator 2>/dev/null; then
    echo "🟢 AGAVE:  RUNNING"
    SLOT=$(curl -s http://localhost:8899 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' 2>/dev/null | grep -oP '"result":\K[0-9]+' || echo 'N/A')
    echo "   Slot: $SLOT"
    echo "   Port 8899: $(curl -s http://localhost:8899 -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null | grep -q ok && echo '✅ Healthy' || echo '⏳ Starting...')"
else
    echo "⚪ AGAVE:  stopped"
fi

echo ""
echo "Commands:"
echo "  sudo switch-to-vexor  - Switch to Vexor"
echo "  sudo switch-to-agave  - Switch to Agave"
SCRIPT
chmod +x /usr/local/bin/validator-status

echo "  ✅ Switch scripts updated"

# ═══════════════════════════════════════════════════════════════════
# VERIFICATION
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "            VERIFICATION"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Directories:"
for dir in /opt/vexor/bin /mnt/vexor/ledger /mnt/vexor/accounts /mnt/vexor/snapshots /var/log/vexor /var/backups/vexor; do
    if [ -d "$dir" ]; then
        PERMS=$(stat -c '%a' "$dir")
        OWNER=$(stat -c '%U:%G' "$dir")
        echo "  ✅ $dir ($PERMS, $OWNER)"
    else
        echo "  ❌ $dir (missing)"
    fi
done

echo ""
echo "Files:"
if [ -f "/opt/vexor/bin/vexor" ]; then
    CAPS=$(getcap /opt/vexor/bin/vexor 2>/dev/null || echo "none")
    echo "  ✅ /opt/vexor/bin/vexor (caps: $CAPS)"
else
    echo "  ⚠️  /opt/vexor/bin/vexor (not installed yet)"
fi

if [ -f "/etc/systemd/system/vexor.service" ]; then
    echo "  ✅ /etc/systemd/system/vexor.service"
else
    echo "  ❌ /etc/systemd/system/vexor.service"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "            PERMISSION FIX COMPLETE! ✅"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Check status:           validator-status"
echo "  2. Test Vexor bootstrap:   sudo -u solana /opt/vexor/bin/vexor run --bootstrap --testnet --identity /home/solana/.secrets/validator-keypair.json --snapshots /mnt/vexor/snapshots"
echo "  3. Switch to Vexor:        sudo switch-to-vexor"
echo "  4. Switch to Agave:        sudo switch-to-agave"
echo ""
PERMISSION_FIX
```

---

## 📋 Individual Commands (If Needed Separately)

### Fix Directory Ownership
```bash
sudo chown -R solana:solana /mnt/vexor
sudo chown -R solana:solana /var/log/vexor
sudo chown -R solana:solana /var/backups/vexor
```

### Fix Snapshot Extraction Permissions
```bash
sudo chmod -R u+r /mnt/vexor/snapshots/extracted-*
```

### Set AF_XDP Capabilities
```bash
sudo setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
```

### Verify Capabilities
```bash
getcap /opt/vexor/bin/vexor
# Expected: /opt/vexor/bin/vexor cap_net_admin,cap_net_raw,cap_sys_admin=eip
```

---

## 🧪 Test Commands After Permission Fix

### 1. Check Status
```bash
validator-status
```

### 2. Test Bootstrap (Without Network)
```bash
# This tests snapshot loading without starting the full validator
sudo -u solana timeout 60 /opt/vexor/bin/vexor run --bootstrap --testnet \
  --identity /home/solana/.secrets/validator-keypair.json \
  --snapshots /mnt/vexor/snapshots 2>&1 | tail -30
```

### 3. Safe Switch to Vexor
```bash
# This will stop Agave and start Vexor
sudo switch-to-vexor
```

### 4. Check Vexor Health
```bash
# Wait 30 seconds then check
sleep 30 && validator-status
```

### 5. Rollback to Agave (If Issues)
```bash
sudo switch-to-agave
```

---

## 🔒 Security Notes

1. **Keypairs remain protected** - We only request READ access, never modify them
2. **AF_XDP capabilities** - Required for kernel bypass networking, runs as solana user
3. **Systemd conflicts** - `vexor.service` conflicts with `solana-validator.service` to prevent both running

---

## ⚠️ Troubleshooting

### "Permission denied" on snapshot files
```bash
sudo chmod -R u+r /mnt/vexor/snapshots/
```

### "Address in use" error
```bash
# Check what's using the port
sudo ss -tlnp | grep 8001
# Stop Agave first
sudo systemctl stop solana-validator
```

### "AF_XDP not available"
```bash
# Verify capabilities are set
getcap /opt/vexor/bin/vexor
# If not set, run:
sudo setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
```

### Vexor won't start
```bash
# Check logs
sudo journalctl -u vexor -n 50 --no-pager
# Or run manually to see output
sudo -u solana /opt/vexor/bin/vexor run --bootstrap --testnet ...
```


