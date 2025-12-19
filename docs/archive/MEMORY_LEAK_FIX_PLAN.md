# Memory Leak Fix Plan

## Current Status
- ✅ Validator runs (using `page_allocator`)
- ⚠️ Memory leaks present but hidden
- ⚠️ Can't use `GeneralPurposeAllocator` leak detection

## Leak Locations (from error logs)

### 1. `src/diagnostics/metrics.zig`
**Lines:** 77, 156, 268, 281, 282
**Issue:** Allocated objects not freed
- `HistogramBucket` arrays
- `MetricsRegistry` instances
- `Metric` and `Histogram` objects

**Fix:** Add proper `deinit()` calls and ensure cleanup

### 2. `src/tools/installer/recommendation_engine.zig`
**Lines:** 259, 295
**Issue:** `allocPrint` strings not freed
- Recommendation descriptions
- Command strings

**Fix:** Use arena allocator or ensure `defer allocator.free()`

### 3. `src/tools/installer.zig`
**Lines:** 5571 (createImmediateBackup)
**Issue:** Backup path strings not freed
- `allocPrint` for backup paths

**Fix:** Add `defer allocator.free()` for all `allocPrint` results

### 4. `src/storage/root.zig`
**Line:** 116
**Issue:** Storage allocations not freed

**Fix:** Ensure proper cleanup in `deinit()`

## Fix Strategy

1. **Use Arena Allocator for temporary strings**
   - Installer recommendations (short-lived)
   - Diagnostic messages (short-lived)

2. **Add proper deinit() methods**
   - Metrics registry cleanup
   - Storage cleanup

3. **Track allocations with defer**
   - All `allocPrint` calls
   - All `alloc`/`create` calls

4. **Test with GeneralPurposeAllocator**
   - Re-enable after fixes
   - Verify no leaks detected

## Priority Order

1. **High Priority:** Installer strings (called during startup)
2. **Medium Priority:** Metrics (called frequently)
3. **Low Priority:** Storage (long-lived, less critical)

## Testing

After fixes:
1. Change back to `GeneralPurposeAllocator` in `main.zig`
2. Run validator
3. Check for leak errors
4. Fix any remaining leaks
5. Verify validator runs cleanly

