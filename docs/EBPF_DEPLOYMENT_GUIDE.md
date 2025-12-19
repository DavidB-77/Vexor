# eBPF Deployment Guide

## Where to Run Commands

### Local Machine (Development)
- ✅ Build Vexor binary
- ✅ Compile BPF program (needs clang)
- ✅ Deploy to validator

### Validator (Production)
- ✅ Set capabilities (`sudo setcap`)
- ✅ Run Vexor
- ✅ Test eBPF functionality

## Quick Deployment

### Option 1: Automated Script

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

### Option 2: Manual Steps

#### On Local Machine:

```bash
# 1. Install clang (if needed)
sudo apt-get install clang

# 2. Build with AF_XDP
cd /home/dbdev/solana-client-research/vexor
zig build -Daf_xdp=true

# 3. Verify BPF compiled
ls -lh zig-out/bpf/xdp_filter.o

# 4. Deploy to validator
scp zig-out/bin/vexor solana@v1.qubestake.io:/home/solana/bin/vexor
scp zig-out/bpf/xdp_filter.o solana@v1.qubestake.io:/home/solana/bin/vexor/bpf/
```

#### On Validator:

```bash
# 1. Set capabilities
sudo setcap cap_net_raw,cap_net_admin+ep /home/solana/bin/vexor

# 2. Verify
getcap /home/solana/bin/vexor

# 3. Test
/home/solana/bin/vexor run --no-voting --gossip-port 8101 --rpc-port 8999 --public-ip 38.92.24.174
```

## What to Look For

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

## Troubleshooting

### "BPF program not compiled"
- Install clang: `sudo apt-get install clang`
- Rebuild: `zig build -Daf_xdp=true`

### "Permission denied" (AF_XDP)
- Set capabilities: `sudo setcap cap_net_raw,cap_net_admin+ep /path/to/vexor`
- Verify: `getcap /path/to/vexor`

### "BPF_PROG_LOAD failed"
- Check eBPF verifier log in output
- Verify kernel supports XDP (kernel >= 5.7)
- Check network driver supports XDP

## Validator Info

- **Host:** v1.qubestake.io (38.92.24.174)
- **User:** solana
- **Binary Path:** /home/solana/bin/vexor
- **BPF Path:** /home/solana/bin/vexor/bpf/

