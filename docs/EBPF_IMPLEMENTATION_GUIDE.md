# eBPF XDP Implementation Guide

**Last Updated:** December 18, 2025  
**Status:** ✅ Build Complete, Runtime Tested

---

## Overview

Vexor implements eBPF kernel-level packet filtering for AF_XDP, matching Firedancer's approach. The system uses direct BPF syscalls (no libbpf dependency) and can generate eBPF bytecode at runtime.

---

## Architecture

### Implementation Approach

**Firedancer Reference:**
- Uses direct `bpf()` syscalls (no libbpf)
- Generates eBPF program dynamically in memory
- Creates XSKMAP and attaches program via `BPF_LINK_CREATE`

**Vexor Implementation:**
- Uses direct `bpf()` syscalls (matches Firedancer)
- Can load eBPF program from compiled `.o` file OR generate at runtime
- Same XSKMAP and attachment approach
- Runtime bytecode generation in `src/network/af_xdp/ebpf_gen.zig`

### Key Components

1. **Direct BPF Syscalls**
   - Removed dependency on `libbpf` library
   - Implemented direct `bpf()` syscall wrapper (Firedancer-style)
   - No external library dependencies needed

2. **Manual BPF Union Definition**
   - Defined `BpfAttr` extern union manually
   - Avoids C opaque type issues in Zig
   - Supports all required BPF operations

3. **eBPF Program Loading**
   - Extracts program from compiled `.o` file using `objcopy` (optional)
   - OR generates bytecode at runtime via `ebpf_gen.zig`
   - Loads via `BPF_PROG_LOAD` syscall
   - Includes eBPF verifier logging for debugging

4. **Build System**
   - Removed `libbpf` and `libelf` linking
   - Build compiles successfully
   - BPF program compilation integrated (if using .o file)

5. **Integration**
   - Updated `accelerated_io.zig` to use new API
   - New `XdpProgram.init()` signature handles loading and attaching

---

## Key Files

| File | Purpose |
|------|---------|
| `src/network/af_xdp/xdp_program.zig` | Main eBPF program loading and attachment |
| `src/network/af_xdp/ebpf_gen.zig` | Runtime eBPF bytecode generation |
| `src/network/af_xdp/bpf/xdp_filter.c` | eBPF XDP program (if using compiled .o) |
| `src/network/accelerated_io.zig` | Integration point |
| `build.zig` | Build configuration |

---

## Deployment

### Where to Run Commands

**Local Machine (Development):**
- ✅ Build Vexor binary
- ✅ Compile BPF program (if using .o file, needs clang)
- ✅ Deploy to validator

**Validator (Production):**
- ✅ Set capabilities (`sudo setcap`)
- ✅ Run Vexor
- ✅ Test eBPF functionality

### Quick Deployment

**Option 1: Automated Script**
```bash
# On local machine
cd /home/dbdev/solana-client-research/vexor
./scripts/deploy_to_validator.sh
```

This will:
1. Build locally (with clang if available)
2. Copy binary + BPF program to validator
3. Set capabilities on validator
4. Verify deployment

**Option 2: Manual Steps**

**On Local Machine:**
```bash
# 1. Install clang (if using .o file)
sudo apt-get install clang

# 2. Build with AF_XDP
cd /home/dbdev/solana-client-research/vexor
zig build -Daf_xdp=true

# 3. Verify BPF compiled (if using .o file)
ls -lh zig-out/bpf/xdp_filter.o

# 4. Deploy to validator
scp zig-out/bin/vexor solana@v1.qubestake.io:/home/solana/bin/vexor
scp zig-out/bpf/xdp_filter.o solana@v1.qubestake.io:/home/solana/bin/vexor/bpf/  # if using .o
```

**On Validator:**
```bash
# 1. Set capabilities
sudo setcap cap_net_raw,cap_net_admin+ep /home/solana/bin/vexor

# 2. Verify
getcap /home/solana/bin/vexor

# 3. Test
/home/solana/bin/vexor run --no-voting --gossip-port 8101 --rpc-port 8999 --public-ip 38.92.24.174
```

---

## Expected Output

### Success (eBPF Active):
```
✅ eBPF kernel-level filtering active (~20M pps)
[AF_XDP] Initialized with eBPF kernel-level filtering (~20M pps)
[AF_XDP] Added port 9004 to eBPF filter (kernel-level filtering active)
```

### Fallback (Userspace):
```
Using userspace port filtering (~10M pps)
[AcceleratedIO] Using io_uring backend (~3M pps)
```

---

## Troubleshooting

### "BPF program not compiled"
- Install clang: `sudo apt-get install clang`
- Rebuild: `zig build -Daf_xdp=true`
- **Note:** If using runtime bytecode generation, .o file is not needed

### "Permission denied" (AF_XDP)
- Set capabilities: `sudo setcap cap_net_raw,cap_net_admin+ep /path/to/vexor`
- Verify: `getcap /path/to/vexor`

### "BPF_PROG_LOAD failed"
- Check eBPF verifier log in output
- Verify kernel supports XDP (kernel >= 5.7)
- Check network driver supports XDP

### "XDP Program Attach EBUSY"
- Only one XDP program can be attached per interface
- Second queue fails (known limitation)
- **Workaround:** Use single queue for now

---

## Current Status

### ✅ Completed
- Direct BPF syscall implementation
- Manual BPF union definition
- eBPF program loading (from .o or runtime generation)
- Build system integration
- Runtime bytecode generation (`ebpf_gen.zig`)
- Integration with `accelerated_io.zig`

### ⏳ Pending/Future Improvements
- Full runtime testing on production hardware
- Enhanced error handling and fallback
- Dynamic port configuration without recompiling
- Multi-queue XDP support (currently limited to single queue)

---

## Technical Details

### Runtime Bytecode Generation

Vexor can generate eBPF bytecode at runtime in `src/network/af_xdp/ebpf_gen.zig`:
- Generates XDP filter program dynamically
- Supports port filtering
- No need for compiled .o file
- Matches Firedancer's dynamic generation approach

### BPF Syscall Interface

The implementation uses direct `bpf()` syscalls with manual union definition:
- `BPF_PROG_LOAD` - Load eBPF program
- `BPF_MAP_CREATE` - Create maps (XSKMAP)
- `BPF_MAP_UPDATE_ELEM` - Register sockets
- `BPF_LINK_CREATE` - Attach program to interface

---

## Validator Info

- **Host:** v1.qubestake.io (38.92.24.174)
- **User:** sol
- **Binary Path:** `/home/sol/vexor/bin/vexor-validator`
- **BPF Path:** `/home/sol/vexor/bpf/` (if using .o files)

---

## References

- **Firedancer:** `src/waltz/xdp/fd_xdp*.c` - XDP program implementation
- **Vexor:** `src/network/af_xdp/ebpf_gen.zig` - Runtime bytecode generation
- **Vexor:** `src/network/af_xdp/xdp_program.zig` - Program loading and attachment
- **Fixes:** See `FIXES_COMPLETE_DEC16.md` for eBPF-related fixes

---

*Document created: December 18, 2025*  
*Merged from: EBPF_IMPLEMENTATION_STATUS.md, EBPF_DEPLOYMENT_GUIDE.md*

