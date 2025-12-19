# Unified Installer Refactor Plan

**Date:** December 15, 2024  
**Status:** PROPOSAL - Awaiting Approval  
**Goal:** Create ONE unified installer file that does everything efficiently and securely

---

## 📋 Current State Analysis

### What Exists Now:
1. **`src/tools/installer.zig`** (4,583 lines)
   - Unified installer CLI tool
   - Commands: `install`, `audit`, `recommend`, `fix`, `diagnose`, `health`, etc.
   - Has `--debug` flag (no password needed ✅)
   - Has permission request system
   - Has backup/rollback system

2. **`src/tools/installer/`** (separate module)
   - `auto_diagnosis.zig` - Issue detection
   - `auto_fix.zig` - Auto-fix executor
   - `recommendation_engine.zig` - Recommendation generation
   - `issue_database.zig` - Known issues database

3. **`src/optimizer/`** (separate module)
   - `detector.zig` - Hardware detection (CPU, RAM, GPU, Network)
   - `tuner.zig` - System tuning (sysctl, CPU governor, IRQ affinity)
   - `monitor.zig` - Performance monitoring
   - `metrics.zig` - Metrics collection

4. **`src/main.zig`** (current integration)
   - Calls `optimizer.autoOptimize()` at line 199-203
   - Calls `installer` audit system at line 206-373
   - **DUPLICATE**: Both do hardware detection
   - **DUPLICATE**: Both apply optimizations

---

## 🎯 Proposed Solution

### Goal: ONE Unified Installer File

**Single File:** `src/tools/installer.zig` should contain:
- ✅ All audit functionality (network, storage, compute, system)
- ✅ All hardware detection (from optimizer)
- ✅ All system tuning (from optimizer)
- ✅ All recommendation generation
- ✅ All permission requests
- ✅ All auto-fix capabilities
- ✅ Debug flags (no password - accessible to all users)
- ✅ Full audit-first flow: AUDIT → RECOMMEND → EXPLAIN → REQUEST PERMISSION → IMPLEMENT → VERIFY

### Integration with `main.zig`:

**Option A: Simple Function Call (RECOMMENDED)**
```zig
// In main.zig, replace lines 198-374 with:
if (features.auto_optimize) {
    try installer.runAuditAndOptimize(allocator, .{
        .auto_fix_low_risk = true,
        .request_permissions = true,
        .debug = debug_mode,
    });
}
```

**Benefits:**
- ✅ Single entry point
- ✅ No duplication
- ✅ Clean separation of concerns
- ✅ Efficient (one call, one flow)
- ✅ Secure (all logic in installer)

**Option B: Keep Separate (NOT RECOMMENDED)**
- Would require maintaining two separate systems
- More code to maintain
- Risk of divergence

---

## 🔧 Refactoring Steps

### Step 1: Merge Optimizer into Installer
- Move `optimizer/detector.zig` functions into `installer.zig` as internal functions
- Move `optimizer/tuner.zig` functions into `installer.zig` as internal functions
- Remove `optimizer/` module (or keep as thin wrapper that calls installer)

### Step 2: Consolidate Installer Module
- Move `installer/auto_diagnosis.zig` logic into `installer.zig`
- Move `installer/auto_fix.zig` logic into `installer.zig`
- Move `installer/recommendation_engine.zig` logic into `installer.zig`
- Keep `installer/issue_database.zig` as data-only (or inline it)

### Step 3: Create Unified Entry Point
- Add `pub fn runAuditAndOptimize()` function to `installer.zig`
- This function orchestrates the full flow:
  1. Hardware detection (CPU, RAM, GPU, Network)
  2. System audit (AF_XDP, QUIC, storage, permissions)
  3. Issue detection (auto-diagnosis)
  4. Recommendation generation
  5. Permission requests (if interactive)
  6. Auto-fix (low-risk only, with permission)
  7. System tuning (sysctl, CPU governor, etc.)
  8. Verification

### Step 4: Update `main.zig`
- Remove duplicate hardware detection (lines 211-245)
- Remove duplicate optimizer call (lines 199-203)
- Replace with single call to `installer.runAuditAndOptimize()`

### Step 5: Debug Flags
- Keep `--debug` flag (no password needed ✅)
- Add `--debug=network` for network-specific debugging
- Add `--debug=storage` for storage-specific debugging
- Add `--debug=all` for full debugging

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    src/tools/installer.zig                  │
│                  (ONE UNIFIED FILE)                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Hardware Detection (from optimizer)                  │ │
│  │  - detectCpu()                                        │ │
│  │  - detectMemory()                                     │ │
│  │  - detectGpu()                                        │ │
│  │  - detectNetwork()                                    │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  System Audit                                         │ │
│  │  - auditNetwork() (AF_XDP, QUIC, firewall)           │ │
│  │  - auditStorage() (NVMe, RAM disk, mounts)           │ │
│  │  - auditCompute() (CPU features, NUMA, GPU)         │ │
│  │  - auditSystem() (OS, kernel, sysctl, limits)       │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Issue Detection (from installer/auto_diagnosis)      │ │
│  │  - runFullDiagnosis()                                 │ │
│  │  - checkAfXdp()                                       │ │
│  │  - checkMasque()                                      │ │
│  │  - checkStorage()                                     │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Recommendation Engine (from installer/)              │ │
│  │  - generateRecommendations()                          │ │
│  │  - getSummary()                                       │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Permission System                                     │ │
│  │  - requestPermission()                                │ │
│  │  - explainChange()                                    │ │
│  │  - trackApprovals()                                   │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  System Tuning (from optimizer/tuner)                │ │
│  │  - optimizeKernel() (sysctl)                           │ │
│  │  - optimizeCpuGovernor()                              │ │
│  │  - optimizeNetwork() (IRQ affinity)                  │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Auto-Fix (from installer/auto_fix)                   │ │
│  │  - applyFix()                                         │ │
│  │  - verifyFix()                                        │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Public API                                            │ │
│  │  - runAuditAndOptimize()  ← Called from main.zig      │ │
│  │  - main()               ← CLI entry point             │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔒 Security & Efficiency

### Security:
- ✅ Single code path = easier to audit
- ✅ All permission requests in one place
- ✅ All system changes tracked in one place
- ✅ Backup/rollback system centralized

### Efficiency:
- ✅ No duplicate hardware detection
- ✅ No duplicate system tuning
- ✅ Single pass through system
- ✅ Cached results (don't re-detect if already done)

---

## 📝 Implementation Checklist

### Phase 1: Consolidation
- [ ] Move `optimizer/detector.zig` functions into `installer.zig`
- [ ] Move `optimizer/tuner.zig` functions into `installer.zig`
- [ ] Move `installer/auto_diagnosis.zig` logic into `installer.zig`
- [ ] Move `installer/auto_fix.zig` logic into `installer.zig`
- [ ] Move `installer/recommendation_engine.zig` logic into `installer.zig`
- [ ] Inline `installer/issue_database.zig` data

### Phase 2: Unified Entry Point
- [ ] Create `runAuditAndOptimize()` function
- [ ] Implement full audit-first flow
- [ ] Add debug flag support (no password)
- [ ] Add permission request system
- [ ] Add auto-fix integration

### Phase 3: Integration
- [ ] Update `main.zig` to call `installer.runAuditAndOptimize()`
- [ ] Remove duplicate code from `main.zig`
- [ ] Remove `optimizer.autoOptimize()` call
- [ ] Test full flow

### Phase 4: Cleanup
- [ ] Remove `src/tools/installer/` directory (or keep as data-only)
- [ ] Update `src/optimizer/root.zig` to be thin wrapper (or remove)
- [ ] Update all imports
- [ ] Update documentation

---

## ❓ Questions for Approval

1. **Integration Method:** Should `installer.runAuditAndOptimize()` be called from `main.zig`? (Recommended: YES)

2. **Optimizer Module:** Should we remove `src/optimizer/` entirely, or keep it as a thin wrapper that calls installer? (Recommended: Remove entirely)

3. **Installer Module:** Should we remove `src/tools/installer/` directory entirely, or keep it for data-only files? (Recommended: Remove, inline everything)

4. **Debug Flags:** Confirm no password needed - just `--debug`, `--debug=network`, etc.? (Confirmed: YES ✅)

5. **Permission Requests:** Should permission requests be interactive (prompt user) or config-file based? (Recommended: Both - interactive by default, config file for automation)

---

## 🎯 Expected Outcome

After refactoring:
- ✅ ONE unified installer file (`src/tools/installer.zig`)
- ✅ Single entry point from `main.zig`
- ✅ No duplication
- ✅ Full audit-first flow
- ✅ All optimizer functionality integrated
- ✅ Debug flags (no password)
- ✅ Permission requests
- ✅ Auto-fix capabilities
- ✅ Clean, maintainable code

---

## ⚠️ Risks & Mitigation

**Risk:** Large file (installer.zig will be ~6,000+ lines)
**Mitigation:** Use internal functions, clear organization, good comments

**Risk:** Breaking existing functionality
**Mitigation:** Test thoroughly, keep backup of current code

**Risk:** Import conflicts
**Mitigation:** Update all imports, test compilation

---

## ✅ Approval Needed

Please confirm:
1. ✅ Proceed with this refactoring plan?
2. ✅ Remove `optimizer/` module entirely?
3. ✅ Remove `installer/` directory entirely?
4. ✅ Use `installer.runAuditAndOptimize()` from `main.zig`?
5. ✅ Debug flags with no password (accessible to all users)?

Once approved, I will proceed with the refactoring.

