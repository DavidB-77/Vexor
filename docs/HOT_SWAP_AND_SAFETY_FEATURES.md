# Hot-Swap & Safety Features Analysis

**Date:** December 15, 2024  
**Status:** ANALYSIS - What Exists vs What's Needed

---

## ✅ What's ALREADY Implemented

### 1. Client Detection ✅
- **Location:** `src/tools/installer.zig` lines 350-395
- **What it does:**
  - Detects: Agave, Firedancer, Jito, Frankendancer, Unknown
  - Has service names, ledger paths, snapshot paths for each
- **Status:** ✅ WORKING (but limited to 4 clients)

### 2. Backup System ✅
- **Location:** `src/tools/installer.zig` lines 1159-1252
- **What it does:**
  - Creates full system state backup
  - Backs up: sysctl, systemd services, firewall rules, manifest
  - Stores backup ID and path
- **Status:** ✅ WORKING (but not automatic on startup)

### 3. Switch Commands ✅
- **Location:** `src/tools/installer.zig` lines 972-1036
- **What it does:**
  - `switch-to-vexor` - Switches from other client to Vexor
  - `switch-to-agave` - Switches back to previous client
  - Creates backup before switching
- **Status:** ✅ WORKING (but manual, not automatic)

### 4. CPU Pinning Detection ✅
- **Location:** `src/tools/installer.zig` lines 3637-3712
- **What it does:**
  - Detects CPU pinning in existing services
  - Detects IRQ affinity settings
  - Warns if Vexor would interfere
- **Status:** ✅ WORKING (but doesn't auto-rollback)

### 5. System Tuning Detection ✅
- **Location:** `src/tools/installer.zig` lines 2857-2995
- **What it does:**
  - Detects existing sysctl settings
  - Detects huge pages, swappiness, file limits
  - Checks for custom tuning
- **Status:** ✅ WORKING (but doesn't prevent interference)

---

## ❌ What's MISSING (Critical Features)

### 1. Hot-Swap Validator ID & Vote Keys ❌
**Status:** NOT IMPLEMENTED

**What's needed:**
- Command to switch validator identity keypair
- Command to switch vote account keypair
- Ability to do this without stopping validator
- Automatic backup of old keys before swap
- Verification that new keys are valid

**Example usage:**
```bash
vexor-install swap-keys --identity /path/to/new-identity.json --vote-account /path/to/new-vote.json
```

### 2. Automatic State Backup on Vexor Startup ❌
**Status:** PARTIALLY IMPLEMENTED (backup exists, but not automatic)

**What's needed:**
- When Vexor starts, IMMEDIATELY create backup of current state
- Before ANY changes are made
- Store backup ID for later reference
- Make this automatic (not optional)

**Current:** Backup is created during `install` command, but NOT during validator startup

### 3. Comprehensive Validator Client Detection ❌
**Status:** PARTIALLY IMPLEMENTED (only detects 4 clients)

**What's needed:**
- Detect ANY validator client (not just Agave, Firedancer, Jito, Frankendancer)
- Detect custom/unknown validators
- Detect multiple validators running
- Detect validator processes by:
  - Process name patterns
  - Port usage (gossip, RPC, TVU)
  - Service files
  - Binary paths

**Current:** Only detects 4 known clients, doesn't handle unknown/custom clients well

### 4. Automatic Rollback on Interference ❌
**Status:** NOT IMPLEMENTED

**What's needed:**
- If Vexor detects it would interfere with existing tuning:
  - Automatically switch back to previous client
  - Restore previous state
  - Notify user what happened
- If Vexor crashes or fails:
  - Automatically restore previous client
  - Restore previous state
  - Log the issue

**Current:** Has restore command, but requires manual intervention

### 5. Non-Interference Recommendations ❌
**Status:** PARTIALLY IMPLEMENTED (detects, but doesn't prevent)

**What's needed:**
- If CPU pinning detected: Don't modify it, suggest compatible changes
- If custom sysctl detected: Don't override, suggest additions only
- If IRQ affinity set: Don't change it, work with it
- If custom tuning detected: Suggest changes that complement, don't conflict

**Current:** Detects these, but doesn't prevent interference

### 6. Dual System / Hot-Swap Between Clients ❌
**Status:** PARTIALLY IMPLEMENTED (has switch commands, but not automatic)

**What's needed:**
- When Vexor starts: Automatically stop previous client
- When Vexor stops: Automatically start previous client (if configured)
- Systemd service integration for automatic switching
- Health check integration (if Vexor unhealthy, switch back)

**Current:** Has manual switch commands, but not automatic

---

## 🎯 What Needs to Be Added

### Priority 1: Critical Safety Features

1. **Automatic State Backup on Startup**
   - When `main.zig` calls `installer.runAuditAndOptimize()`
   - FIRST thing: Create backup of current state
   - Store backup ID in memory/file for later reference
   - This MUST happen before ANY changes

2. **Comprehensive Client Detection**
   - Detect ANY validator process (not just known ones)
   - Check process names, ports, services
   - Handle unknown/custom validators gracefully

3. **Automatic Rollback on Interference**
   - If interference detected: Auto-rollback
   - If crash detected: Auto-rollback
   - If health check fails: Auto-rollback

### Priority 2: Hot-Swap Features

4. **Hot-Swap Validator Keys**
   - Command to swap identity/vote keys
   - Backup old keys
   - Verify new keys
   - Update configuration

5. **Dual System / Automatic Switching**
   - Systemd integration for auto-switching
   - Health check integration
   - Automatic fallback to previous client

### Priority 3: Non-Interference

6. **Smart Recommendations**
   - Detect existing tuning
   - Suggest compatible changes only
   - Don't override user's custom settings

---

## 📋 Implementation Plan

### Step 1: Add Automatic State Backup to Startup
```zig
// In installer.runAuditAndOptimize()
pub fn runAuditAndOptimize(...) !void {
    // FIRST: Create backup of current state
    const backup_id = try createImmediateBackup(allocator);
    defer allocator.free(backup_id);
    
    // Store backup ID for later reference
    try storeBackupId(backup_id);
    
    // NOW proceed with audit and optimization
    // ...
}
```

### Step 2: Enhance Client Detection
```zig
// Detect ANY validator client
fn detectAnyValidatorClient(allocator: Allocator) !?ValidatorClient {
    // Check processes
    // Check ports
    // Check services
    // Check binaries
    // Return detected client (even if unknown)
}
```

### Step 3: Add Hot-Swap Keys Command
```zig
// New command: swap-keys
fn cmdSwapKeys(self: *Self) !void {
    // Backup current keys
    // Verify new keys
    // Update configuration
    // Restart validator (if needed)
}
```

### Step 4: Add Automatic Rollback
```zig
// Auto-rollback on interference
fn autoRollbackOnInterference(self: *Self, reason: []const u8) !void {
    // Stop Vexor
    // Restore previous client
    // Restore previous state
    // Notify user
}
```

### Step 5: Add Dual System Integration
```zig
// Systemd service integration
fn setupDualSystem(self: *Self) !void {
    // Create systemd service that:
    // - Stops previous client when Vexor starts
    // - Starts previous client when Vexor stops
    // - Handles health checks
}
```

---

## 🔒 Safety Guarantees

After implementation, the system will guarantee:

1. ✅ **State Backup:** Always backed up before ANY changes
2. ✅ **Client Detection:** Detects ANY validator client
3. ✅ **Non-Interference:** Never modifies existing tuning without permission
4. ✅ **Automatic Rollback:** Automatically restores if issues detected
5. ✅ **Hot-Swap Keys:** Can swap keys without stopping validator
6. ✅ **Dual System:** Automatic switching between clients

---

## ❓ Questions

1. **Hot-swap keys:** Should this be done without stopping the validator? (Recommended: YES - but may require validator restart)

2. **Automatic rollback:** Should this be enabled by default, or opt-in? (Recommended: Enabled by default for safety)

3. **Dual system:** Should automatic switching be enabled by default? (Recommended: Opt-in, but easy to enable)

4. **Client detection:** Should we try to detect ALL possible validators, or just common ones? (Recommended: Try to detect all, handle unknown gracefully)

---

## ✅ Next Steps

Once approved, I will:
1. Add automatic state backup to startup
2. Enhance client detection (detect any validator)
3. Add hot-swap keys command
4. Add automatic rollback on interference
5. Add dual system / automatic switching
6. Enhance non-interference recommendations

This will make the installer truly safe and comprehensive.

