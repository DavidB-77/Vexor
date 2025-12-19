# Vexor Implementation Roadmap

**Created:** December 13, 2024  
**Updated:** December 13, 2024  
**Status:** ACTIVE DEVELOPMENT

---

## 🎯 Vision

Build an **ultra-lightweight, high-performance Solana validator client** that:
1. Works for ANY validator, regardless of hardware
2. Audits the system first, then recommends optimizations
3. Never makes changes without permission
4. Auto-diagnoses and fixes issues
5. Achieves maximum performance through kernel bypass (AF_XDP), QUIC/MASQUE, and tiered storage

---

## 📋 Implementation Phases

### Phase 1: Audit-First Installer ⬅️ CURRENT FOCUS
**Goal:** Every installation starts with a comprehensive system audit

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| Network Audit (NIC, driver, XDP) | 🔴 TODO | `src/tools/installer/audit/network_audit.zig` | Must detect XDP support |
| Storage Audit (disk type, ramdisk) | 🔴 TODO | `src/tools/installer/audit/storage_audit.zig` | Detect NVMe vs HDD |
| Compute Audit (CPU, NUMA, GPU) | 🟡 PARTIAL | `src/optimizer/detector.zig` | CPU works, GPU stubbed |
| System Audit (kernel, sysctl, limits) | 🔴 TODO | `src/tools/installer/audit/system_audit.zig` | Check all settings |
| Existing Validator Detection | 🟡 PARTIAL | `src/tools/installer.zig` | Basic, needs expansion |
| **Audit Command** | 🔴 TODO | `src/tools/installer.zig` | Add `audit` subcommand |

### Phase 2: Recommendation Engine
**Goal:** Generate personalized recommendations based on audit

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| AF_XDP Recommendation | 🔴 TODO | `src/tools/installer/recommend/` | If XDP supported → recommend |
| QUIC/MASQUE Recommendation | 🔴 TODO | `src/tools/installer/recommend/` | Check ports, firewall |
| Storage Tier Recommendation | 🔴 TODO | `src/tools/installer/recommend/` | RAM→NVMe→Archive |
| CPU Pinning Recommendation | 🔴 TODO | `src/tools/installer/recommend/` | NUMA-aware |
| System Tuning Recommendation | 🔴 TODO | `src/tools/installer/recommend/` | sysctl, limits |

### Phase 3: Permission & Implementation
**Goal:** Request permission, implement changes safely

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| Permission Request UI | 🔴 TODO | `src/tools/installer/permission/` | Interactive prompts |
| Change Explainer | 🔴 TODO | `src/tools/installer/permission/` | Plain language |
| Backup System | 🟡 PARTIAL | `src/tools/backup_manager.zig` | Works, needs expansion |
| Rollback Manager | 🟡 PARTIAL | `src/tools/client_switcher.zig` | Works, needs expansion |
| Verification System | 🔴 TODO | `src/tools/installer/implement/` | Verify changes worked |

### Phase 4: Debug & Auto-Fix
**Goal:** Diagnose and fix issues automatically

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| Issue Database | 🔴 TODO | `src/tools/installer/debug/issue_database.zig` | Known issues + fixes |
| Auto-Diagnosis | 🔴 TODO | `src/tools/installer/debug/auto_diagnosis.zig` | Detect problems |
| Auto-Fix Engine | 🔴 TODO | `src/tools/installer/debug/auto_fix.zig` | Apply fixes |
| Health Monitor | 🔴 TODO | `src/tools/installer/debug/health_monitor.zig` | Continuous monitoring |
| Debug Logging | 🟡 PARTIAL | `src/tools/installer.zig` | Basic, needs subsystems |

### Phase 5: Core Validator Functions
**Goal:** Actual validator functionality

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| `loadAppendVec` | 🔴 TODO | `src/storage/accounts.zig` | Account loading |
| Gossip Snapshot Discovery | 🔴 TODO | `src/network/gossip/` | CRDS SnapshotHashes |
| Fast Catchup (Shred Repair) | 🔴 TODO | `src/network/tvu/` | Repair after snapshot |
| Vote Submission | 🔴 TODO | `src/consensus/` | Submit votes |
| Block Production | 🔴 TODO | `src/consensus/` | Produce blocks |

### Phase 6: Performance Features
**Goal:** Maximum performance

| Task | Status | File(s) | Notes |
|------|--------|---------|-------|
| AF_XDP Integration | 🟢 BUILT | `src/network/af_xdp/` | Needs installer wiring |
| QUIC Transport | 🟢 BUILT | `src/network/quic/` | Working |
| MASQUE Protocol | 🟢 BUILT | `src/network/masque/` | Needs testing |
| io_uring Backend | 🔴 TODO | `src/network/accelerated_io.zig` | Stubbed |
| RAM Disk Manager | 🟢 BUILT | `src/storage/ramdisk/` | Working |
| GPU Signature Verify | 🔴 TODO | `src/crypto/ed25519.zig` | Stubbed |

---

## 🐛 Known Issues to Fix

### MASQUE/QUIC Integration
**Problem:** Connection issues during testing
**Symptoms:**
- QUIC handshake timing issues
- NAT traversal not working as expected
- Port filtering needed for AF_XDP

**Solution:**
1. Add QUIC port availability check to audit
2. Add firewall rule detection and management
3. Test MASQUE proxy configuration
4. Implement BPF port filtering for AF_XDP

### AF_XDP Compatibility
**Problem:** Not all NICs support XDP
**Solution:**
1. Detect NIC driver in audit phase
2. Check for supported drivers (i40e, mlx5, ixgbe, etc.)
3. Test AF_XDP socket creation
4. Graceful fallback to io_uring → UDP

### Permission Issues
**Problem:** Snapshot extraction, binary capabilities
**Solution:**
1. Request all permissions upfront
2. `fix-permissions` command
3. Verification after each change

---

## 📁 New File Structure (Planned)

```
src/tools/installer/
├── mod.zig                    # Main module
├── audit/
│   ├── mod.zig
│   ├── network_audit.zig      # NIC, XDP, QUIC, firewall
│   ├── storage_audit.zig      # Disk, ramdisk, mounts
│   ├── compute_audit.zig      # CPU, NUMA, GPU
│   ├── system_audit.zig       # OS, kernel, sysctl
│   └── validator_audit.zig    # Existing Agave detection
├── recommend/
│   ├── mod.zig
│   ├── recommendation_engine.zig
│   ├── af_xdp_recommend.zig
│   ├── quic_recommend.zig
│   ├── storage_recommend.zig
│   └── tuning_recommend.zig
├── permission/
│   ├── mod.zig
│   ├── permission_request.zig
│   ├── change_explainer.zig
│   └── approval_tracker.zig
├── implement/
│   ├── mod.zig
│   ├── change_executor.zig
│   ├── backup_creator.zig
│   ├── rollback_manager.zig
│   └── verification.zig
└── debug/
    ├── mod.zig
    ├── issue_database.zig
    ├── auto_diagnosis.zig
    ├── auto_fix.zig
    └── health_monitor.zig
```

---

## ✅ Completion Criteria

### Minimum Viable Product (MVP)
- [ ] `vexor-install audit` detects hardware/software
- [ ] `vexor-install recommend` generates suggestions
- [ ] `vexor-install install --interactive` asks permission for each change
- [ ] `vexor-install health` detects common issues
- [ ] `vexor-install fix` applies fixes with permission
- [ ] All changes create backups and can be rolled back

### Production Ready
- [ ] Works on any Linux validator (Ubuntu, Debian, CentOS)
- [ ] Handles all major NIC vendors (Intel, Mellanox, Broadcom)
- [ ] Detects and handles all common firewall configurations
- [ ] Successfully runs alongside Agave
- [ ] Can switch to Vexor as primary validator
- [ ] Produces blocks and votes correctly

---

## 📊 Progress Tracking

| Phase | Progress | Target |
|-------|----------|--------|
| Phase 1: Audit | 10% | Week 1 |
| Phase 2: Recommend | 0% | Week 2 |
| Phase 3: Permission | 30% | Week 2 |
| Phase 4: Debug | 10% | Week 3 |
| Phase 5: Core | 40% | Week 4-5 |
| Phase 6: Performance | 70% | Week 5-6 |

---

## 📚 Related Documents

- `AUDIT_FIRST_INSTALLER_DESIGN.md` - Detailed audit-first architecture
- `DEBUG_AUTOFIX_SYSTEM.md` - Auto-diagnosis and fix system
- `UNIFIED_INSTALLER_PLAN.md` - Original installer plan
- `PERMISSION_FIX_COMMANDS.md` - Manual permission fixes
- `FIREDANCER_SNAPSHOT_ANALYSIS.md` - Snapshot system reference
- `CHANGELOG.md` - Development history

---

## 🔮 Future Considerations

### Multi-Validator Support
- Support for running multiple Vexor instances
- Load balancing across validators
- Shared snapshot storage

### Cloud Provider Integration
- AWS-specific optimizations (ENA driver, placement groups)
- GCP-specific optimizations
- Azure-specific optimizations

### Observability
- Prometheus metrics export
- Grafana dashboards
- Alert manager integration


