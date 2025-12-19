# Missing Installer/Audit System Integration - December 15, 2024

## Problem

The **Audit-First Installer** system exists but is **NOT being called** during validator startup. This means:

1. ❌ System audit is not running
2. ❌ Issues are not being detected automatically
3. ❌ Recommendations are not being generated
4. ❌ Auto-fixes are not being applied (even with permission)
5. ❌ Only basic auto-optimizer runs (sysctl, CPU governor)

## What Should Be Running

### Current State (What's Actually Running)
- ✅ **Auto-Optimizer** (`optimizer.autoOptimize()`) - Called in `main.zig:187-191`
  - Detects hardware (CPU, RAM)
  - Applies basic sysctl tuning
  - Sets CPU governor
  - Optimizes network settings

### Missing Components (What Should Be Running)
- ❌ **System Audit** (`installer.auto_diagnosis.AutoDiagnosis.runFullDiagnosis()`)
  - Checks AF_XDP capabilities
  - Checks MASQUE/QUIC ports
  - Checks storage (ramdisk, NVMe)
  - Checks system tuning (sysctl, limits)
  
- ❌ **Recommendation Engine** (`installer.recommendation_engine.RecommendationEngine.generateRecommendations()`)
  - Generates personalized recommendations
  - Prioritizes fixes by impact
  - Explains benefits and risks

- ❌ **Auto-Fix System** (`installer.auto_fix.FixSession`)
  - Applies fixes with user permission
  - Creates backups
  - Verifies fixes
  - Supports rollback

## Code Location

### Installer System (Exists but Not Called)
- `src/tools/installer/mod.zig` - Main installer module
- `src/tools/installer/auto_diagnosis.zig` - System audit
- `src/tools/installer/recommendation_engine.zig` - Recommendations
- `src/tools/installer/auto_fix.zig` - Fix executor
- `src/tools/installer/issue_database.zig` - Known issues database

### Current Integration Point
- `src/main.zig:187-191` - Only calls `optimizer.autoOptimize()`
- Should also call installer system

## What Needs to Be Fixed

### 1. Integrate Installer into Startup

Add to `src/main.zig` after auto-optimizer:

```zig
// Run installer audit system if enabled
if (features.auto_optimize) {
    std.debug.print("🔍 Running system audit...\n", .{});
    
    // Initialize installer components
    var diagnosis = installer.auto_diagnosis.AutoDiagnosis.init(allocator);
    defer diagnosis.deinit();
    
    // Run full diagnosis
    try diagnosis.runFullDiagnosis();
    
    // Generate recommendations
    var engine = installer.recommendation_engine.RecommendationEngine.init(allocator);
    defer engine.deinit();
    
    // Convert diagnosis to audit results
    const audit_results = try convertDiagnosisToAudit(allocator, &diagnosis);
    try engine.generateRecommendations(audit_results);
    
    // Show recommendations
    if (engine.recommendations.items.len > 0) {
        std.debug.print("⚠️  Found {d} optimization opportunities:\n", .{engine.recommendations.items.len});
        for (engine.recommendations.items, 1..) |rec, i| {
            std.debug.print("  [{d}] {s} - {s}\n", .{i, rec.title, rec.benefit});
        }
        
        // Apply auto-fixes (if configured to auto-approve)
        if (config.auto_apply_fixes) {
            var fix_session = installer.auto_fix.FixSession.init(allocator, "/var/backups/vexor", false);
            defer fix_session.deinit();
            
            for (engine.recommendations.items) |rec| {
                if (rec.command) |cmd| {
                    // Apply fix with permission
                    const result = try fix_session.applyFixForRecommendation(rec);
                    if (result.success) {
                        std.debug.print("  ✅ Applied: {s}\n", .{rec.title});
                    }
                }
            }
        }
    }
}
```

### 2. Add Config Options

Add to `src/core/config.zig`:

```zig
// Installer/audit options
auto_apply_fixes: bool = false,  // Auto-apply fixes without prompting
audit_on_startup: bool = true,   // Run audit on every startup
show_recommendations: bool = true, // Show recommendations even if not applying
```

### 3. What the Installer Should Check

Based on `auto_diagnosis.zig`, it should detect:

1. **AF_XDP Issues**:
   - Missing capabilities (`AFXDP001`)
   - Driver not XDP-capable (`AFXDP002`)
   - Missing libbpf (`AFXDP003`)

2. **MASQUE/QUIC Issues**:
   - Ports in use (`MASQUE001`)
   - Firewall blocking (`MASQUE002`)
   - Old OpenSSL (`MASQUE003`)

3. **Storage Issues**:
   - Ramdisk not mounted (`STOR001`)
   - HDD detected (`STOR002`)

4. **System Tuning Issues**:
   - Network buffers too small (`TUNE001`)
   - Huge pages not enabled (`TUNE002`)
   - File limits too low (`TUNE003`)

## Expected Behavior After Fix

When Vexor starts, it should:

1. ✅ Run system audit
2. ✅ Detect issues (e.g., "AF_XDP capabilities missing")
3. ✅ Generate recommendations ("Enable AF_XDP for 10x performance")
4. ✅ Show recommendations to user
5. ✅ Apply fixes (if auto-approve enabled or user approves)
6. ✅ Verify fixes were applied
7. ✅ Continue with normal startup

## Current Workaround

The AF_XDP capabilities were manually set, but the installer should have:
1. Detected this issue automatically
2. Recommended the fix
3. Applied it with permission

## Next Steps

1. **Integrate installer into `main.zig`** - Call audit system during startup
2. **Add config flags** - Control auto-apply behavior
3. **Test on validator** - Verify installer detects and fixes issues
4. **Document** - Update installation docs to reflect audit-first approach

## References

- Installer Design: `docs/AUDIT_FIRST_INSTALLER_DESIGN.md`
- Installer Code: `src/tools/installer/`
- Auto-Optimizer: `src/optimizer/root.zig`
- Main Entry: `src/main.zig:187-191`

