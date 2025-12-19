# Running Validator Without Crashes

## Problem

The validator was crashing due to memory leak detection in `GeneralPurposeAllocator`. The leak detection was aborting the process before TVU could initialize, preventing us from seeing eBPF status.

## Solution

**Changed allocator from `GeneralPurposeAllocator` to `page_allocator`** in `src/main.zig`:

```zig
// Before (crashed on leaks):
var gpa = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// After (no leak detection):
const allocator = std.heap.page_allocator;
```

## Why This Works

1. **`page_allocator`** doesn't track allocations, so it won't abort on leaks
2. **Allows testing** without fixing all memory leaks first
3. **Validator runs** long enough to initialize TVU and show eBPF status

## Trade-offs

**Pros:**
- ✅ Validator runs without crashing
- ✅ Can test eBPF initialization
- ✅ Can verify TVU starts correctly
- ✅ Faster development iteration

**Cons:**
- ⚠️ Memory leaks won't be detected
- ⚠️ Not suitable for long-running production
- ⚠️ May use more memory over time

## Next Steps

1. **For Testing:** Use `page_allocator` (current)
2. **For Production:** Fix memory leaks and re-enable `GeneralPurposeAllocator`

## Running the Validator

```bash
# On validator:
/home/davidb/bin/vexor/vexor run \
  --no-voting \
  --gossip-port 8101 \
  --rpc-port 8999 \
  --public-ip 38.92.24.174
```

## Expected Output

You should now see:
- ✅ Validator initialization complete
- ✅ RPC server listening
- ✅ Gossip service started
- ✅ **TVU STARTED WITH AF_XDP ACCELERATION ⚡** (if eBPF works)
- ✅ eBPF status messages

## Memory Leak Fixes (Future)

The following modules have known leaks (from error logs):
- `src/diagnostics/metrics.zig` - Histogram registration
- `src/tools/installer/recommendation_engine.zig` - String allocations
- `src/tools/installer.zig` - Backup path allocations
- `src/storage/root.zig` - Storage allocations

These should be fixed before production deployment.

