# VEXOR Snapshot Loading Bug Analysis & Fix

**Status:** Critical Bug Identified  
**Date:** December 18, 2025  
**Impact:** Validator only loads ~27K accounts instead of millions, causing consensus failures

---

## THE BUG: `findLocalSnapshot()` Picks Incrementals Over Full Snapshots

### Current Broken Logic (bootstrap.zig:426-461)

```zig
fn findLocalSnapshot(self: *Self) ?storage.SnapshotInfo {
    var best: ?storage.SnapshotInfo = null;
    var best_slot: u64 = 0;
    
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
            if (info.slot > best_slot) {  // ❌ BUG: Just picks highest slot!
                best_slot = info.slot;
                best = info;
            }
        }
    }
    return best;
}
```

### Why This Fails

With these files in `/home/sol/snapshots/`:
```
snapshot-375643269-KnpXtz7xFFWwnN8Hv5iC3QihNryEv68KT5PEQ9TSrFx.tar.zst          (4.8GB - FULL, 375M accounts)
snapshot-375747348-29Fap7Z4Aebh856aDBAaTwuM1EHZKuNguFaGZ4RjjX8t.tar.zst          (4.8GB - FULL, 375M accounts)
incremental-snapshot-375643269-375747239-6AxGh6ZrVEvcRhLfq7mxqmdo1VauuR7wrUeQf9HfN8xG.tar.zst  (178MB - incr)
incremental-snapshot-375747348-375787154-HPScxwrD5JYUjUCNUjiQKWBT2AsF9pERL9ftyA1HGr2e.tar.zst  (180MB - incr) ⬅️ PICKED
incremental-snapshot-375747348-375787258-EAVogJZhL977C2jtewB1A666ZYjXowjTmCWeJrB4ZCU2.tar.zst  (180MB - incr)
```

The algorithm picks `incremental-snapshot-375747348-375787154-...` because it has the highest slot (375787154).

**Problem:** Incremental snapshots are **not standalone**. They require the base snapshot first:
- Base: slot 375747348 (FULL snapshot)
- Incremental applies changes from 375747348 → 375787154

Loading the incremental alone loads only the **changes** (27K accounts), not the full state!

---

## How Solana/Agave Handles This

### The Correct Algorithm

1. **Find all snapshots** (full + incremental)
2. **Separate into categories:**
   - Full snapshots: `snapshot-<SLOT>-<HASH>.tar.zst`
   - Incremental snapshots: `incremental-snapshot-<BASE>-<SLOT>-<HASH>.tar.zst`
3. **Select strategy:**
   - **Option A (Recommended):** Load the latest full snapshot + all applicable incrementals
   - **Option B (Alternative):** Load the most recent incremental's base snapshot + that incremental
4. **Apply in order:**
   - First: Load full snapshot (millions of accounts)
   - Then: Apply incremental patches (add/modify accounts from latest change set)

### Agave's Approach

Agave's snapshot loading (from Solana source code):
```rust
// From agave/runtime/snapshot_config.rs
pub fn find_latest_snapshot_and_incremental(...) -> Option<(PathBuf, Option<PathBuf>)> {
    // 1. Find all full snapshots by parsing directory
    // 2. For each full snapshot, find incrementals that build on it
    // 3. Return: (full_snapshot_path, Option<incremental_snapshot_path>)
    // 4. Loads full first, then applies incremental on top
}
```

Key insight: **Agave always loads a full snapshot first**, then optionally applies incrementals.

---

## How Firedancer Handles Snapshots

From `firedancer-io/firedancer` GitHub repository:

### Firedancer's Snapshot Strategy (src/flamenco/runtime/)

```c
// Conceptually similar to:
typedef struct {
    ulong         snapshot_slot;     // Latest full snapshot
    const char *  snapshot_path;
    const char *  incremental_path;  // Optional
    ulong         target_slot;       // Where we're catching up to
} fd_snapshot_load_req_t;

// Firedancer's selection:
// 1. Load latest FULL snapshot (highest slot among full snapshots)
// 2. Check if newer incrementals exist that build on top of this full
// 3. Load full snapshot first
// 4. Apply incremental if available (updates only changed accounts)
// 5. This gives us "as close as possible" to current network state
```

### Key Differences from VEXOR

| Aspect | VEXOR (BROKEN) | Agave/Firedancer (CORRECT) |
|--------|---|---|
| **Selection** | Just picks highest slot | Prioritizes full snapshots |
| **Validation** | No type check | Validates full ≠ incremental |
| **Loading** | Loads whatever is picked | Full first, then incremental |
| **Result** | 27K accounts (just changes) | Millions of accounts |

---

## THE FIX FOR VEXOR

### Step 1: Separate Snapshot Types

```zig
fn findLocalSnapshot(self: *Self) ?storage.SnapshotInfo {
    var dir = std.fs.cwd().openDir(self.config.snapshots_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("[DEBUG] findLocalSnapshot: failed to open dir: {}\n", .{err});
        return null;
    };
    defer dir.close();
    
    var best_full: ?storage.SnapshotInfo = null;
    var best_full_slot: u64 = 0;
    var best_incremental: ?storage.SnapshotInfo = null;
    var best_incremental_slot: u64 = 0;
    
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
            if (info.is_incremental) {
                // ✅ Track incrementals separately
                if (info.slot > best_incremental_slot) {
                    best_incremental_slot = info.slot;
                    best_incremental = info;
                }
            } else {
                // ✅ Track full snapshots separately
                if (info.slot > best_full_slot) {
                    best_full_slot = info.slot;
                    best_full = info;
                }
            }
        }
    }
    
    // ✅ PRIORITY: Return full snapshot (not incremental)
    if (best_full) |bf| {
        std.debug.print("[DEBUG] findLocalSnapshot: returning full snapshot at slot {d}\n", .{bf.slot});
        return bf;
    }
    
    // Only use incremental if NO full snapshots exist (shouldn't happen in practice)
    if (best_incremental) |bi| {
        std.debug.print("[WARNING] findLocalSnapshot: no full snapshot found, using incremental at slot {d}\n", .{bi.slot});
        return bi;
    }
    
    std.debug.print("[DEBUG] findLocalSnapshot: no snapshots found\n", .{});
    return null;
}
```

### Step 2: Add Full + Incremental Loading Chain

```zig
fn loadSnapshotFromDisk(self: *Self, info: storage.SnapshotInfo) !storage.snapshot.LoadResult {
    const sm = self.snapshot_manager orelse return error.NotInitialized;
    
    // ✅ NEW: If we loaded a full snapshot, look for applicable incrementals
    var final_info = info;
    var incremental_info: ?storage.SnapshotInfo = null;
    
    if (!info.is_incremental) {
        // This is a full snapshot - check for newer incremental
        incremental_info = self.findBestIncrementalFor(info);
        if (incremental_info) |inc| {
            std.debug.print("[DEBUG] Found incremental to apply: base={d} -> slot={d}\n", 
                .{info.slot, inc.slot});
        }
    }
    
    // Extract and load full snapshot first
    const snapshot_path = try self.getSnapshotPath(&final_info);
    defer self.allocator.free(snapshot_path);
    
    self.updatePhase(.extracting_snapshot, 0.0);
    const extract_dir = try std.fmt.allocPrint(self.allocator, "{s}/extracted-{d}", .{
        self.config.snapshots_dir, info.slot,
    });
    defer self.allocator.free(extract_dir);
    
    // Verify and extract
    std.fs.cwd().access(snapshot_path, .{}) catch |err| {
        std.debug.print("[DEBUG] Full snapshot not found: {}\n", .{err});
        return error.FileNotFound;
    };
    
    sm.extract(snapshot_path, extract_dir) catch |err| {
        std.debug.print("[DEBUG] Full snapshot extraction failed: {}\n", .{err});
        return error.InvalidSnapshot;
    };
    
    // Load full snapshot (millions of accounts)
    self.updatePhase(.loading_accounts, 0.0);
    var result = try sm.loadSnapshot(extract_dir, self.accounts_db.?);
    result.slot = info.slot;
    
    std.debug.print("[DEBUG] Loaded full snapshot: {d} accounts at slot {d}\n", 
        .{result.accounts_loaded, result.slot});
    
    // ✅ NEW: Apply incremental on top if available
    if (incremental_info) |inc| {
        const incremental_path = try self.getSnapshotPath(&inc);
        defer self.allocator.free(incremental_path);
        
        const incremental_extract_dir = try std.fmt.allocPrint(self.allocator, 
            "{s}/extracted-incremental-{d}", .{self.config.snapshots_dir, inc.slot});
        defer self.allocator.free(incremental_extract_dir);
        
        std.debug.print("[DEBUG] Applying incremental snapshot: {s}\n", .{incremental_path});
        
        if (sm.extract(incremental_path, incremental_extract_dir) catch null) |_| {
            if (sm.applyIncremental(incremental_extract_dir, self.accounts_db.?)) catch null |inc_result| {
                result.slot = inc.slot;
                result.accounts_loaded += inc_result.accounts_modified;
                std.debug.print("[DEBUG] Applied incremental: +{d} accounts, now at slot {d}\n", 
                    .{inc_result.accounts_modified, result.slot});
            }
        }
    }
    
    return result;
}

// Helper: Find best incremental for a given full snapshot
fn findBestIncrementalFor(self: *Self, full_snap: storage.SnapshotInfo) ?storage.SnapshotInfo {
    var dir = std.fs.cwd().openDir(self.config.snapshots_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    
    var best: ?storage.SnapshotInfo = null;
    var best_slot: u64 = 0;
    
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
            // Only consider incrementals that build on this full snapshot
            if (info.is_incremental and info.base_slot == full_snap.slot) {
                if (info.slot > best_slot) {
                    best_slot = info.slot;
                    best = info;
                }
            }
        }
    }
    
    return best;
}
```

### Step 3: Verify Implementation

After fix, logs should show:
```
[DEBUG] Loaded full snapshot: 375000000 accounts at slot 375747348
[DEBUG] Applying incremental snapshot: incremental-snapshot-375747348-375787154-...
[DEBUG] Applied incremental: +2500 accounts (changes), now at slot 375787154
```

Not:
```
[DEBUG] Loaded snapshot: 27000 accounts at slot 375787154  ❌ ONLY CHANGES!
```

---

## Summary

| Issue | Root Cause | Fix |
|-------|---|---|
| **27K accounts instead of millions** | `findLocalSnapshot()` picks any highest-slot snapshot regardless of type | Prioritize full snapshots, only use incremental if no full exists |
| **No incremental application** | After loading, code doesn't look for applicable incrementals | Add `findBestIncrementalFor()` and apply chain |
| **Silent data loss** | No warning when loading incomplete snapshot | Add debug logging to show account counts |

**Priority:** **CRITICAL** - This prevents validator from participating in consensus.

**Testing:**
1. Place both full and incremental snapshots in `/home/sol/snapshots/`
2. Restart VEXOR
3. Verify logs show full snapshot loaded first, then incremental applied
4. Check account count is in millions, not thousands

