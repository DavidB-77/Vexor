# VEXOR Deployment Guide

## Server Access

**Validator IP:** `38.92.24.174`  
**Root Password:** `Carreton77++`

### SSH/SCP Commands (use password auth)

Local SSH keys have passphrases - use password authentication:

```bash
# SSH to server
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@38.92.24.174

# SCP files to server
scp -o PreferredAuthentications=password -o PubkeyAuthentication=no <file> root@38.92.24.174:<dest>
```

---

## Deployment Steps

### 1. Build Release Binary
```bash
cd /home/dbdev/solana-client-research/vexor
zig build -Doptimize=ReleaseFast
```

### 2. Deploy to Server
```bash
scp -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    zig-out/bin/vexor root@38.92.24.174:/home/sol/vexor/bin/vexor-validator
```

### 3. Switch to VEXOR
```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@38.92.24.174
# Then on server:
/home/sol/scripts/switch-client.sh vexor
```

### 4. Switch Back to Agave
```bash
/home/sol/scripts/switch-client.sh agave
```

---

## Server Directory Structure

```
/home/sol/
├── agave/bin/agave-validator    # Agave binary
├── vexor/bin/vexor-validator    # VEXOR binary
├── keypairs/                    # Validator keypairs
├── ledger/                      # Ledger data
├── accounts/                    # Account data
├── snapshots/                   # Snapshots
├── logs/                        # Log files
├── scripts/switch-client.sh     # Client switch script
├── validator.sh                 # Active startup script (symlink)
├── validator-agave.sh           # Agave startup config
└── validator-vexor.sh           # VEXOR startup config
```

---

## Verification Commands

```bash
# Check current status
/home/sol/scripts/switch-client.sh status

# Check running process
ps aux | grep -E "(agave|vexor)" | grep -v grep

# Check service status
systemctl status solana-validator

# View logs
tail -f /home/sol/logs/agave.log   # or vexor.log
journalctl -u solana-validator -f
```

---

## Validator Identity

- **Identity:** `3J2jADiEoKMaooCQbkyr9aLnjAb5ApDWfVvKgzyK2fbP`
- **Vote Account:** `BfXryoEG8XEsdi4YBpSA7iWgs2BZfVxBM6xXCnreDC8n`
- **Network:** Testnet
