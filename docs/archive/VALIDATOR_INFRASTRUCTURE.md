# Vexor Validator Infrastructure

**Last Updated:** December 14, 2024

---

## ⚠️ CRITICAL NOTICE

**Both validators have REAL SOL staked. These are PRODUCTION SYSTEMS.**

- Never overwrite or delete keypairs
- Always use safe switchover commands
- Test thoroughly in local/read-only mode first

---

## ⚠️ VPS/Hosting Provider Notes

**WARNING: High CPU Usage Can Trigger Security Alerts**

Solana validators run at very high CPU utilization (often 90-100%) during:
- Snapshot loading (can take 1+ hours at 99% CPU)
- Catch-up/replay
- Normal operation (50-80% is typical)

**This can trigger hosting provider security systems** that mistake sustained high CPU for:
- Cryptocurrency mining malware
- DDoS attack participation
- Compromised server

**Recommendations:**
1. **Notify your hosting provider** before running a validator
2. **Use dedicated/bare-metal hosting** when possible (not shared VPS)
3. **Monitor for provider alerts** during first startup
4. **Document your use case** with the provider in advance

**Known providers that support validators:**
- Latitude.sh (recommended, validator-friendly)
- Equinix Metal
- AWS dedicated instances
- OVH dedicated
- Hetzner (check TOS for crypto)

---

## 🖥️ Infrastructure Overview

| System | IP Address | Role | Status |
|--------|------------|------|--------|
| **Validator 1** | 38.92.24.174 | Primary testnet validator + SnapStream | ✅ Running |
| **Validator 2** | 38.58.183.154:36963 | Secondary testnet validator | ✅ Running |
| **VPS** | 148.230.81.56 | Dashboard (qstesting.com) | ✅ Running |

---

## 🔑 SSH Access

### Validator 1 (Primary)
```bash
# Via SSH config alias (recommended)
ssh validator

# Or explicit
ssh davidb@38.92.24.174 -i ~/.ssh/snapstream_wsl -J qstesting

# As solana user
ssh validator-solana
```
- **Users:** `davidb`, `solana`
- **Sudo Password:** `<REMOVED>`
- **SSH Key:** `~/.ssh/snapstream_wsl` or `~/.ssh/id_davidb_validator`

### Validator 2 (Secondary)
```bash
ssh -p 36963 davidb@38.58.183.154
```
- **User:** `davidb`
- **Sudo Password:** `Carreton26*=`

### VPS (Dashboard)
```bash
ssh -i ~/.ssh/id_solsnap_vps solsnap@qstesting.com
```
- **User:** `solsnap`
- **Sudo Password:** `Carreton77++`

---

## 📁 Validator Paths

| Component | Validator 1 | Validator 2 |
|-----------|-------------|-------------|
| Solana Install | `/home/solana/` | `/home/solana/` |
| Validator Service | `solana-validator.service` | `solana-validator.service` |
| Vexor Binary | `/home/solana/bin/vexor/vexor` | `/home/solana/bin/vexor/vexor` |
| Ledger | `/mnt/solana/ledger/` | `/mnt/solana/ledger/` |
| Snapshots | `/mnt/solana/snapshots/` | `/mnt/solana/snapshots/` |
| Accounts (Agave) | `/mnt/solana/ramdisk/accounts` | `/mnt/solana/ramdisk/accounts` |

### 🔑 Keypair Locations (CRITICAL)

**All keypairs are in `/home/solana/.secrets/`** (symlinks to actual files):

```
/home/solana/.secrets/
├── validator-keypair.json          -> testnet/qubetest/validator-keypair.json
├── vote-account-keypair.json       -> testnet/qubetest/vote-account-keypair.json
├── authorized-withdrawer-keypair.json -> testnet/qubetest/authorized-withdrawer-keypair.json
└── testnet/
    └── qubetest/
        ├── validator-keypair.json    (actual file)
        ├── vote-account-keypair.json (actual file)
        └── authorized-withdrawer-keypair.json (actual file)
```

**Use these paths for Vexor:**
```bash
--identity /home/solana/.secrets/validator-keypair.json
--vote-account /home/solana/.secrets/vote-account-keypair.json
```

⚠️ **The `/home/solana/.config/solana/` directory does NOT contain keypairs!**

---

## 🧪 Vexor Testing Strategy

### Phase 1: Local WSL2 Testing (SAFE - No Risk)
```bash
cd /home/dbdev/solana-client-research/vexor

# Build and run basic tests
zig build
zig build test

# Test installer audit (read-only)
./zig-out/bin/vexor-install audit

# Test fix in dry-run mode
./zig-out/bin/vexor-install fix --dry-run
```

### Phase 2: Read-Only Testnet Connection
```bash
# Test Vexor against testnet RPC (no voting, no block production)
./zig-out/bin/vexor --rpc-url https://api.testnet.solana.com --read-only
```

### Phase 3: Validator Switchover (ON VALIDATOR - Requires SSH)
```bash
# SSH to validator first
ssh validator

# Copy Vexor binary to validator
scp ./zig-out/bin/vexor validator:/tmp/
scp ./zig-out/bin/vexor-install validator:/tmp/
ssh validator "sudo mv /tmp/vexor /tmp/vexor-install /home/solana/bin/vexor/"

# Set AF_XDP capabilities (REQUIRED for high-performance networking)
ssh validator "sudo setcap cap_net_raw,cap_net_admin,cap_sys_admin+eip /home/solana/bin/vexor/vexor"

# On validator: Run audit
/home/solana/bin/vexor/vexor-install audit

# On validator: Test Vexor with debug mode (doesn't affect Agave)
/home/solana/bin/vexor/vexor run --debug --bootstrap \
  --cluster testnet \
  --identity /home/solana/.secrets/validator-keypair.json \
  --vote-account /home/solana/.secrets/vote-account-keypair.json \
  --snapshot-path /mnt/vexor/snapshots \
  --ledger /mnt/vexor/ledger \
  --accounts /mnt/vexor/accounts \
  --entrypoint entrypoint.testnet.solana.com:8001

# On validator: Safe switchover (stops ANY existing client, starts Vexor)
# Works with: Agave, Firedancer, Jito, Frankendancer
/home/solana/bin/vexor/vexor-install switch-to-vexor \
  --identity /home/solana/.secrets/validator-keypair.json \
  --vote-account /home/solana/.secrets/vote-account-keypair.json
```

### Phase 4: Rollback (if needed)
```bash
# On validator: Switch back to previous client (whatever was running before)
/home/solana/bin/vexor-install switch-to-previous

# Or use the legacy command (alias)
/home/solana/bin/vexor-install switch-to-agave
```

---

## ⚠️ CRITICAL: Same Keypair Warning

**Both Vexor and Agave use the same identity/vote keypairs!**

### When It's SAFE (Current Testing):
- ✅ Vexor running with `--no-voting` flag (no voting, no block production)
- ✅ Using different ports and directories (`/mnt/vexor/` vs `/mnt/solana/`)
- ✅ Alternate ports: gossip 8101, RPC 8999, TVU 9004 (Agave uses 8001, 8899, 8004)
- ✅ **Hot-swap testing**: Both use same identity/vote keys, but Vexor doesn't vote
- ✅ Agave is the only one voting and producing blocks
- ✅ Safe because `--no-voting` prevents vote submission even if code tries

### When It's DANGEROUS:
- ❌ **NEVER** run both with voting enabled simultaneously
- ❌ This would cause **double voting** → potential slashing
- ❌ Both producing blocks → fork the network

### Safe Switchover Procedure:
1. Verify Vexor snapshot loading complete
2. **STOP Agave first**: `systemctl stop solana-validator`
3. Wait for Agave to fully stop
4. Start Vexor with voting: `vexor-install switch-to-vexor`
5. Monitor for issues
6. If problems → `vexor-install switch-to-previous`

---

## 🔒 Security Reminders

1. **Never commit this file to public repos** - contains sensitive credentials
2. **Keypairs are backed up** - but still treat them as irreplaceable
3. **Test in dry-run first** - `vexor-install fix --dry-run`
4. **Monitor after switchover** - `vexor-install status` or `journalctl -u vexor -f`

---

## 📊 Current Testnet Status

- **Shred Version:** 9604
- **Recent Slot:** 374,301,609
- **Gossip Stake:** ~73% (needs 80% for consensus)
- **Live Monitor:** https://qstesting.com/status

---

## 📝 Related Documents

- `/home/dbdev/snapstream/QUICK-STATE.md` - Full SnapStream status
- `/home/dbdev/snapstream/docs/runbooks/validator-provision.md` - Provisioning guide
- `./docs/IMPLEMENTATION_STATUS.md` - Vexor implementation status

