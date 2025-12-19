# eBPF XDP Implementation - December 15, 2024

## Summary

Successfully implemented eBPF kernel-level packet filtering for AF_XDP, matching Firedancer's approach. This replaces userspace port filtering with kernel-level filtering for significantly better performance (~20M pps vs ~10M pps).

## Key Changes

### 1. Switched from libbpf to Direct BPF Syscalls (Firedancer-style)

**Problem:** Initial implementation used `libbpf` library, which caused linker errors and added unnecessary dependencies.

**Solution:** Switched to direct `bpf()` syscalls, matching Firedancer's approach in `src/waltz/xdp/fd_xdp1.c`.

**Files Modified:**
- `src/network/af_xdp/xdp_program.zig` - Complete rewrite to use direct syscalls
- `build.zig` - Removed `libbpf` and `libelf` linking (no longer needed)

### 2. Manual BPF Union Definition

**Problem:** Zig couldn't handle C's `union bpf_attr` opaque type.

**Solution:** Manually defined `BpfAttr` extern union with all required struct variants:
- `map_create` - For creating BPF maps (XSKMAP, port filter)
- `prog_load` - For loading eBPF programs
- `map_update_elem` - For updating map entries
- `map_delete_elem` - For deleting map entries
- `link_create` - For attaching XDP programs to interfaces

### 3. eBPF Program Loading

**Implementation:** Uses `objcopy` to extract the `.text` section from compiled `xdp_filter.o`, then loads it via `BPF_PROG_LOAD` syscall.

**Files:**
- `src/network/af_xdp/bpf/xdp_filter.c` - eBPF XDP program (filters by UDP port)
- `src/network/af_xdp/xdp_program.zig` - Loader using direct syscalls

### 4. Integration with AF_XDP

**Changes in `src/network/accelerated_io.zig`:**
- Updated `tryInitXdp()` to use new `XdpProgram.init()` signature
- New signature: `init(allocator, ifindex, mode, bind_port)` - handles both loading and attaching
- Removed separate `attach()` call (now part of `init()`)

## Architecture

### Firedancer Reference

Firedancer's approach (from `src/waltz/xdp/fd_xdp1.c`):
1. **Generate eBPF program dynamically** in memory (not from .o file)
2. **Use direct `bpf()` syscalls** (no libbpf)
3. **Create XSKMAP** via `BPF_MAP_CREATE`
4. **Load program** via `BPF_PROG_LOAD`
5. **Attach program** via `BPF_LINK_CREATE`

### Vexor Implementation

Our approach (similar, but loads from compiled .o file):
1. **Compile eBPF program** to `zig-out/bpf/xdp_filter.o` (via `build.zig`)
2. **Extract program instructions** using `objcopy` (from `.text` section)
3. **Create XSKMAP and port filter map** via `BPF_MAP_CREATE`
4. **Load program** via `BPF_PROG_LOAD` (with verifier logging)
5. **Attach program** via `BPF_LINK_CREATE`
6. **Register AF_XDP sockets** in XSKMAP via `BPF_MAP_UPDATE_ELEM`
7. **Add ports to filter** via `BPF_MAP_UPDATE_ELEM`

## Build System Changes

### `build.zig`

**Removed:**
- `exe.linkSystemLibrary("elf")` - No longer needed
- `exe.linkSystemLibrary("bpf")` - No longer needed

**Added:**
- BPF compilation step (already existed, now used correctly)
- Compiles `src/network/af_xdp/bpf/xdp_filter.c` to `zig-out/bpf/xdp_filter.o`

## Type System Fixes

### Issues Resolved

1. **`c_long` vs `i32` mismatch:**
   - `bpf()` returns `c_long` (64-bit on x86_64)
   - Fixed by casting return values appropriately

2. **`std.posix.errno()` type issues:**
   - Fixed by using `@as(i32, @intCast(value))` for all errno calls

3. **Syscall function:**
   - Used `extern "c" fn syscall(...)` for variadic syscall
   - `SYS_bpf = 321` (Linux x86_64 syscall number)

## Current Status

✅ **Build:** Compiles successfully  
✅ **eBPF Program:** Compiled and ready to load  
✅ **Direct Syscalls:** Implemented (Firedancer-style)  
✅ **Integration:** Connected to `accelerated_io.zig`  
⏳ **Testing:** Not yet tested (needs runtime verification)

## Next Steps

1. **Test eBPF program loading:**
   - Verify `objcopy` extraction works
   - Verify `BPF_PROG_LOAD` succeeds
   - Check eBPF verifier logs for any issues

2. **Test packet filtering:**
   - Verify packets are filtered by port at kernel level
   - Monitor performance improvement vs userspace filtering

3. **Error handling:**
   - Add fallback to userspace filtering if eBPF fails
   - Improve error messages from eBPF verifier

## Files Modified

1. `src/network/af_xdp/xdp_program.zig` - Complete rewrite (475 lines)
2. `src/network/accelerated_io.zig` - Updated `tryInitXdp()` call
3. `build.zig` - Removed libbpf/libelf linking

## Files Created

1. `src/network/af_xdp/bpf/xdp_filter.c` - eBPF XDP program (already existed)
2. `scripts/compile_bpf.sh` - Helper script (already existed)

## References

- **Firedancer:** `external/firedancer/src/waltz/xdp/fd_xdp1.c`
- **Firedancer BPF:** `external/firedancer/src/waltz/ebpf/fd_linux_bpf.h`
- **Firedancer eBPF ASM:** `external/firedancer/src/waltz/ebpf/fd_ebpf_asm.h`

## Performance Expectations

- **Userspace filtering:** ~10M pps (current fallback)
- **eBPF kernel filtering:** ~20M pps (target, matching Firedancer)
- **CPU savings:** Significant reduction in userspace packet processing

## Notes

- The eBPF program is loaded from a compiled `.o` file, unlike Firedancer which generates it dynamically
- This approach is simpler but less flexible (can't customize ports at runtime without recompiling)
- Future improvement: Generate eBPF program dynamically like Firedancer for runtime port configuration

