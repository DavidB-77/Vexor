# Dry-Run Mode - Testing the Installer Safely

**Date:** December 15, 2024  
**Status:** ✅ IMPLEMENTED

---

## 🎯 Overview

Dry-run mode allows you to test the entire installer without making any changes to your system. It performs all audits, checks, and recommendations, but makes **zero modifications**.

---

## 🚀 Usage

### Basic Dry-Run
```bash
# Test the full installation process
vexor-install --dry-run install

# Test audit only
vexor-install --dry-run audit

# Test fix command
vexor-install --dry-run fix

# Test with debug flags
vexor-install --dry-run --debug=all install
```

---

## ✅ What Dry-Run Does

### Performs ALL Operations:
1. ✅ **Hardware Detection** - Detects CPU, RAM, GPU, network
2. ✅ **System Audit** - Checks network, storage, compute, system
3. ✅ **Issue Detection** - Finds all issues and problems
4. ✅ **Recommendations** - Generates all recommendations
5. ✅ **Key Detection** - Detects existing validator keys
6. ✅ **Client Detection** - Detects any validator client
7. ✅ **Non-Interference Checks** - Checks for existing tuning

### Shows What Would Happen:
- What directories would be created
- What files would be installed
- What systemd services would be created
- What capabilities would be set
- What system tuning would be applied
- What fixes would be applied

### Makes NO Changes:
- ❌ No backups created
- ❌ No directories created
- ❌ No files installed
- ❌ No systemd services created
- ❌ No capabilities set
- ❌ No system tuning applied
- ❌ No fixes applied

---

## 📋 Example Output

```
═══════════════════════════════════════════════════════════════
  VEXOR INSTALLATION - DRY RUN MODE
═══════════════════════════════════════════════════════════════

🧪 DRY-RUN MODE ENABLED

This is a TEST RUN. The installer will:
  ✅ Perform all audits and checks
  ✅ Detect hardware and system state
  ✅ Generate recommendations
  ✅ Show what would be changed
  ❌ Make NO actual changes to your system

Use this to test and debug the installer safely.

📦 [DRY RUN] Would create pre-installation backup
───────────────────────────────────────────────────
  [DRY RUN] Backup would be created at: /var/backups/vexor/backup-<timestamp>
  [DRY RUN] No actual backup will be created

🔍 Running comprehensive system audit and optimization...
  Detecting hardware...
    CPU: AMD Ryzen 9 7950X (16 cores)
    RAM: 128.0 GB
    GPU: NVIDIA RTX 4070 Ti

  Running comprehensive system audit...
  📋 DIAGNOSIS: Found 5 issues (3 fixable, 1 critical)
  💡 RECOMMENDATIONS: 8 available

  🔧 [DRY RUN] Would auto-fix low-risk issues...
    [DRY RUN] Would fix [AFXDP001] AF_XDP capabilities not set
      Command: setcap 'cap_net_raw,cap_net_admin+eip' /opt/vexor/bin/vexor
    [DRY RUN] Would fix [NET001] Network buffers suboptimal
      Command: sysctl -w net.core.rmem_max=134217728
    [DRY RUN] Total fixes that would be applied: 2

  ⚡ [DRY RUN] Would apply system optimizations...
    [DRY RUN] Would optimize kernel parameters
    [DRY RUN] Would set CPU governor to performance
    [DRY RUN] Would optimize network buffer sizes
    [DRY RUN] No actual changes would be made

  [DRY RUN] Would run installation...
    [DRY RUN] Would create directories
    [DRY RUN] Would install binary
    [DRY RUN] Would create config files
    [DRY RUN] Would create systemd service
    [DRY RUN] Would set capabilities
    [DRY RUN] No actual changes would be made

═══════════════════════════════════════════════════════════════
  DRY RUN COMPLETE
═══════════════════════════════════════════════════════════════

✅ All audits completed successfully
❌ NO changes were made to your system

This was a test run. To actually install Vexor, run:
  vexor-install install

(without --dry-run flag)
```

---

## 🎯 Use Cases

1. **Testing the Installer** - Verify all audits work correctly
2. **Debugging Issues** - See what the installer would do without risk
3. **Reviewing Changes** - Preview all changes before applying
4. **Development** - Test installer changes safely
5. **Documentation** - Generate example outputs

---

## 🔧 Implementation Details

### Where Dry-Run is Applied:

1. **Unified Audit Function** (`runAuditAndOptimize`)
   - Skips backup creation
   - Shows what fixes would be applied
   - Shows what tuning would be applied
   - No actual changes

2. **Install Command** (`cmdInstall`)
   - Shows what would be installed
   - Shows what directories would be created
   - Shows what services would be created
   - No actual installation

3. **Fix Command** (`cmdFix`)
   - Shows what fixes would be applied
   - Shows commands that would run
   - No actual fixes

4. **All Installation Functions**
   - `installBinary()` - Shows "[DRY RUN] Would install binary"
   - `createConfigFile()` - Shows "[DRY RUN] Would create config file"
   - `createSystemdService()` - Shows "[DRY RUN] Would create systemd service"
   - `setCapabilities()` - Shows "[DRY RUN] Would set AF_XDP capabilities"

---

## 📊 Summary

**Dry-Run Mode:**
- ✅ Comprehensive - Tests ALL functionality
- ✅ Safe - Makes ZERO changes
- ✅ Informative - Shows exactly what would happen
- ✅ Perfect for testing and debugging

**To Apply Changes:**
Simply run the same command **without** `--dry-run` flag.

---

## 🎉 Conclusion

Dry-run mode is fully implemented and ready for use. It's the perfect way to test the installer safely before making any actual changes to your system!

