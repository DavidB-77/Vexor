# Vexor Unified Installer Plan

**Created:** December 13, 2024  
**Updated:** December 13, 2024  
**Status:** 🔄 EVOLVING → AUDIT-FIRST APPROACH  
**Priority:** CRITICAL - Core to user experience

---

## 📢 Major Update: Audit-First Approach

The installer is evolving from a simple installation tool to a **comprehensive system auditor and optimizer**.

**See new documents:**
- `AUDIT_FIRST_INSTALLER_DESIGN.md` - Complete audit-first architecture
- `DEBUG_AUTOFIX_SYSTEM.md` - Auto-diagnosis and fix system

### Core Principle
```
AUDIT → RECOMMEND → EXPLAIN → REQUEST PERMISSION → IMPLEMENT → VERIFY
```

**No changes are made without:**
1. Full hardware/software audit
2. Clear explanation of what will change
3. Explicit user permission
4. Automatic rollback capability

---

## 🎉 Basic Implementation Complete!

The basic unified installer has been implemented in `src/tools/installer.zig`.

### Quick Usage
```bash
# Full installation (interactive)
sudo vexor-install install --testnet

# Fix permissions
sudo vexor-install fix-permissions

# Test bootstrap (safe, doesn't stop Agave)
vexor-install test-bootstrap

# Switch to Vexor (stops ANY existing client!)
# Supports: Agave, Firedancer, Jito, Frankendancer
sudo vexor-install switch-to-vexor

# Rollback to previous client
sudo vexor-install switch-to-previous

# Run diagnostics
vexor-install diagnose

# Check status
vexor-install status

# Debug mode - verbose output
sudo vexor-install --debug install --testnet
```

---

## Original Planning Document (Below)

---

## 📋 Problem Statement

We currently have **multiple fragmented approaches** to installing and testing Vexor:

| Component | Location | Issue |
|-----------|----------|-------|
| `vexor-install` | `src/tools/installer.zig` | Interactive installer - incomplete |
| `setup-dual-client.sh` | `scripts/setup-dual-client.sh` | Bash script - duplicates installer logic |
| `client_switcher.zig` | `src/tools/client_switcher.zig` | Separate tool - should be in installer |
| Manual SSH commands | N/A | Debug/test commands scattered, expensive |
| Permission fixes | Ad-hoc | Should be requested upfront |

**Result:** 
- Confusing workflow
- Time-consuming debugging
- Expensive iterations (tokens/API costs)
- Permission issues encountered mid-process
- No single source of truth

---

## ✅ Solution: ONE Unified Installer

### Two Operational Modes

| Mode | Flag | Purpose |
|------|------|---------|
| **DEBUG/TEST** | `vexor-install --debug` | Full diagnostics, verbose logging, test suite, safe rollback |
| **PRODUCTION** | `vexor-install --production` | Optimized, minimal logging, validated config only |

### Built-in Commands (Available in Both Modes)

```bash
vexor-install [MODE] [COMMAND] [OPTIONS]

MODES:
  --debug              Enable full debugging suite
  --production         Clean production install (default)
  --test-only          Run tests without installing

COMMANDS:
  install              Full installation with all steps
  switch-to-vexor      Safe client switch (stops any client, starts Vexor)
  switch-to-previous   Rollback to previous client (stops Vexor)
  diagnose             Run comprehensive health checks
  test-bootstrap       Test snapshot loading without starting network
  test-network         Test gossip/RPC connectivity
  test-extraction      Test snapshot extraction only
  fix-permissions      Fix all permission issues at once
  status               Show current validator state
  backup               Create manual backup of critical files
  restore              Restore from backup

OPTIONS:
  --non-interactive    No prompts (for automation)
  --dry-run            Show what would be done without doing it
  --verbose            Extra verbose output (even in production mode)
  --role <validator|rpc>   Set node role
  --network <testnet|mainnet-beta|devnet|localnet>   Set network
```

---

## 🏗️ Unified Installer Architecture

```
vexor-install
│
├── CORE MODULES (always included):
│   ├── Permission Manager     # Upfront permission requests
│   ├── Directory Manager      # Create all required directories
│   ├── Keypair Validator      # Verify identity/vote keypairs
│   ├── Config Generator       # Create config.toml
│   ├── Systemd Manager        # Create/manage services
│   ├── Backup Manager         # Pre-switch backups
│   ├── Alert System           # Telegram/Discord/Slack notifications
│   └── Client Switcher        # Safe Any-Client ↔ Vexor switching
│
├── DEBUG MODE ADDITIONS:
│   ├── Verbose Logger         # Every step logged in detail
│   ├── Test Runner            # Built-in test commands
│   ├── Snapshot Tester        # Test extraction without full start
│   ├── Network Tester         # Test gossip/RPC without voting
│   ├── Permission Auditor     # Check all permissions
│   ├── Diagnostic Reporter    # Generate full system report
│   └── Step-by-Step Mode      # Pause after each step for review
│
└── PRODUCTION MODE:
    ├── Minimal Logging        # Errors and warnings only
    ├── Optimized Paths        # Skip unnecessary checks
    ├── Auto-Continue          # No pauses unless error
    └── Clean Output           # Summary only
```

---

## 📁 Permission Setup (Requested Upfront)

### Required Permissions

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PERMISSION REQUEST                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Vexor installer needs the following permissions:                    │
│                                                                      │
│  DIRECTORIES (owned by solana user):                                 │
│    [1] /opt/vexor/bin/         - Vexor binaries                     │
│    [2] /mnt/vexor/ledger/      - Ledger storage                     │
│    [3] /mnt/vexor/accounts/    - Accounts database                  │
│    [4] /mnt/vexor/snapshots/   - Snapshot storage                   │
│    [5] /var/log/vexor/         - Log files                          │
│    [6] /var/run/vexor/         - Runtime files (PID, sockets)       │
│    [7] /var/backups/vexor/     - Backup storage                     │
│    [8] /etc/vexor/             - Configuration files                │
│                                                                      │
│  KEYPAIRS (read access only):                                        │
│    [9] Identity keypair        - /home/solana/.secrets/...          │
│   [10] Vote account keypair    - /home/solana/.secrets/...          │
│                                                                      │
│  SYSTEM:                                                             │
│   [11] Systemd service file    - /etc/systemd/system/vexor.service  │
│   [12] Switch scripts          - /usr/local/bin/switch-to-*         │
│   [13] AF_XDP capabilities     - cap_net_raw,cap_net_admin on binary│
│                                                                      │
│  Continue with sudo? [Y/n]                                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Permission Fix Command

For validators that already have partial installations:

```bash
# Fix ALL permissions at once
sudo vexor-install fix-permissions --user solana

# This will:
# 1. Create all directories if missing
# 2. Set ownership to solana:solana
# 3. Set correct modes (rwx for owner)
# 4. Fix snapshot extraction permissions
# 5. Set AF_XDP capabilities
# 6. Verify all paths are accessible
```

---

## 🔧 Debug Mode Features

When running with `--debug`:

### 1. Verbose Logging
```
[DEBUG] [2024-12-13 18:00:00] Step 1/15: Checking permissions...
[DEBUG] [2024-12-13 18:00:00]   /opt/vexor/bin/ - OK (rwx for solana)
[DEBUG] [2024-12-13 18:00:00]   /mnt/vexor/ledger/ - OK (rwx for solana)
[DEBUG] [2024-12-13 18:00:01]   /mnt/vexor/snapshots/ - OK (rwx for solana)
[DEBUG] [2024-12-13 18:00:01] Step 1/15: COMPLETE
```

### 2. Built-in Test Commands
```bash
# Test snapshot extraction without starting validator
vexor-install --debug test-bootstrap

# Test network connectivity without voting
vexor-install --debug test-network

# Generate full diagnostic report
vexor-install --debug diagnose > /tmp/vexor-debug-report.txt
```

### 3. Step-by-Step Mode
```bash
# Pause after each step for manual review
vexor-install --debug install --step-by-step

# Output:
# Step 3/15: Creating systemd service...
# [Press ENTER to continue, 's' to skip, 'q' to quit]
```

### 4. Diagnostic Report
```
═══════════════════════════════════════════════════════════════
                    VEXOR DIAGNOSTIC REPORT
═══════════════════════════════════════════════════════════════

System:
  OS: Ubuntu 22.04 LTS
  Kernel: 5.15.0-89-generic
  CPU: AMD Ryzen 9 7950X3D (32 cores)
  RAM: 128 GB
  
Vexor Status:
  Binary: /opt/vexor/bin/vexor (v0.1.0-alpha)
  Service: inactive (systemd)
  Config: /etc/vexor/config.toml
  
Agave Status:
  Service: active (running for 12h)
  Identity: ABC123...XYZ
  Slot: 374,700,000
  Health: OK
  
Permissions:
  /opt/vexor/bin/vexor          ✅ OK (rwxr-xr-x, root)
  /mnt/vexor/ledger/            ✅ OK (rwxr-xr-x, solana)
  /mnt/vexor/snapshots/         ✅ OK (rwxr-xr-x, solana)
  AF_XDP capabilities           ✅ OK (cap_net_raw+eip)
  
Snapshot:
  Local: /mnt/vexor/snapshots/snapshot-374576751-*.tar.zst
  Size: 4.8 GB
  Extracted: Yes (32 GB, 99,812 files)
  
Network:
  Gossip port 8001: ⚠️  IN USE (Agave)
  RPC port 8899:    ⚠️  IN USE (Agave)
  Vexor RPC 8900:   ✅ AVAILABLE
  
Recommendations:
  1. Stop Agave before starting Vexor to free ports
  2. Or use different ports in Vexor config
  
═══════════════════════════════════════════════════════════════
```

---

## 🔄 Client Switching (Built into Installer)

### Safe Switch Process

```
vexor-install switch-to-vexor
│
├── PRE-SWITCH CHECKS:
│   ├── Verify Vexor binary exists
│   ├── Verify keypairs accessible
│   ├── Verify snapshot available
│   ├── Verify config valid
│   └── Create pre-switch backup
│
├── SWITCH EXECUTION:
│   ├── Stop Agave gracefully (wait for slot boundary)
│   ├── Verify Agave stopped
│   ├── Start Vexor
│   ├── Wait for health check
│   └── Verify Vexor responding
│
├── POST-SWITCH MONITORING:
│   ├── Monitor for 30 seconds
│   ├── Check slot progression
│   ├── Verify gossip connectivity
│   └── Send success alert
│
└── ROLLBACK ON FAILURE:
    ├── Stop Vexor
    ├── Restore Agave from backup
    ├── Start Agave
    ├── Verify Agave healthy
    └── Send failure alert
```

---

## 📦 Files to Consolidate

### Remove/Deprecate:
- `scripts/setup-dual-client.sh` → Absorb into installer
- Separate `client_switcher.zig` binary → Make subcommand

### Update:
- `src/tools/installer.zig` → Main unified installer
- `src/tools/backup_manager.zig` → Keep, use as module
- `src/tools/alert_system.zig` → Keep, use as module

### Add:
- `src/tools/installer/debug_mode.zig` → Debug-specific features
- `src/tools/installer/test_runner.zig` → Built-in tests
- `src/tools/installer/permission_manager.zig` → Upfront permission handling

---

## 🗓️ Implementation Plan

### Phase 1: Immediate (Permission Fixes)
- Provide manual permission fix commands for test validators
- Continue testing with current setup

### Phase 2: Unified Installer (Next)
1. Refactor `installer.zig` with `--debug` and `--production` modes
2. Add `fix-permissions` command
3. Add `test-bootstrap` command
4. Add `switch-to-vexor` / `switch-to-agave` as subcommands
5. Add `diagnose` command with full report
6. Add upfront permission request

### Phase 3: Deprecation
1. Mark `setup-dual-client.sh` as deprecated
2. Update documentation to use unified installer
3. Remove duplicate code

---

## 📝 Notes for Test Validators

### Your Validator (38.92.24.174)

Current issues:
- Snapshot files extracted with no permissions (fixed with chmod)
- Need to fix upfront to avoid repeated issues

One-time fix command (run as root):
```bash
# See PERMISSION_FIX_COMMANDS.md for full script
```

---

## 💰 Cost/Benefit Analysis

### Current Approach (Fragmented)
- ~20 SSH commands per test cycle
- ~10 back-and-forth debug iterations
- High token usage per test

### Unified Installer
- 1-3 commands per test cycle
- Built-in debugging catches errors early
- Lower token usage, faster iteration

**Estimated savings:** 80% reduction in debug iterations

---

## ✅ Acceptance Criteria

The unified installer is complete when:

1. [ ] `vexor-install --debug install` performs full installation with verbose output
2. [ ] `vexor-install --production install` performs clean production install
3. [ ] `vexor-install fix-permissions` fixes all permission issues in one command
4. [ ] `vexor-install test-bootstrap` tests snapshot loading without network
5. [ ] `vexor-install switch-to-vexor` safely switches from any client
6. [ ] `vexor-install switch-to-previous` safely rolls back to previous client
7. [ ] `vexor-install diagnose` generates comprehensive diagnostic report
8. [ ] All permissions requested upfront with user approval
9. [ ] No duplicate code between installer and other scripts

---

## 📚 Related Documents

- `docs/INSTALLATION.md` - User-facing installation guide
- `docs/FIREDANCER_SNAPSHOT_ANALYSIS.md` - Snapshot system analysis
- `docs/PERMISSION_FIX_COMMANDS.md` - Manual permission fix commands
- `docs/AUDIT_FIRST_INSTALLER_DESIGN.md` - **NEW** Comprehensive audit-first architecture
- `docs/DEBUG_AUTOFIX_SYSTEM.md` - **NEW** Auto-diagnosis and fix system


