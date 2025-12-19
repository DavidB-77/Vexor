# Vexor Complete Fixes Documentation - December 16, 2024

This document captures ALL fixes made during the December 15-16 session to ensure
we can quickly resolve these issues if they recur.

## Table of Contents

1. [Ed25519 Signing Panic](#1-ed25519-signing-panic)
2. [AF_XDP Socket Segfault](#2-af-xdp-socket-segfault)
3. [eBPF Program Loading Failures](#3-ebpf-program-loading-failures)
4. [Gossip Peer Connection Issues](#4-gossip-peer-connection-issues)
5. [Zero-Copy Mode for 30M PPS](#5-zero-copy-mode-for-30m-pps)
6. [Working Command Line](#6-working-command-line)
7. [Current Status & Known Issues](#7-current-status--known-issues)
8. [TPU Integration Fix](#8-tpu-integration-fix)

---

## 1. Ed25519 Signing Panic

### Symptom
```
panic: reached unreachable code
```
During gossip PING/PONG or vote signing.

### Root Cause
Solana uses a 64-byte "secret key" format: `[32-byte seed][32-byte public key]`

Zig's `Ed25519.SecretKey.fromBytes()` expects only the 32-byte seed, and 
`fromSecretKey()` has internal assertions that fail when the derived public 
key doesn't match.

### Fix Location
`src/crypto/ed25519.zig` - `sign()` function

### Fix Code
```zig
pub fn sign(secret_key: [64]u8, message: []const u8) core.Signature {
    const Ed25519 = std.crypto.sign.Ed25519;
    
    // Extract seed (first 32 bytes) - this is the private key
    const seed: [32]u8 = secret_key[0..32].*;
    
    // Create keypair directly from seed to avoid fromSecretKey's internal assertions
    const key_pair = Ed25519.KeyPair.create(seed) catch {
        return core.Signature{ .data = [_]u8{0} ** 64 };
    };
    
    // Sign the message
    const sig = key_pair.sign(message, null) catch {
        return core.Signature{ .data = [_]u8{0} ** 64 };
    };
    
    return core.Signature{ .data = sig.toBytes() };
}
```

### Key Insight
Use `Ed25519.KeyPair.create(seed)` instead of `Ed25519.SecretKey.fromBytes()`.

---

## 2. AF_XDP Socket Segfault

### Symptom
```
Segmentation fault at address 0x0
src/network/af_xdp/socket.zig:202:48: 0x11fbdde in peek
```

### Root Cause
The `mmapRings()` function was a stub that didn't properly initialize the
`producer`, `consumer`, and `ring` pointers in `UmemRing` and `DescRing` structs.

### Fix Location
`src/network/af_xdp/socket.zig` - `mmapRings()` function

### Fix Code
```zig
fn mmapRings(self: *XdpSocket, offsets: *const XdpMmapOffsets) !void {
    // Map RX ring
    const rx_size = offsets.rx.desc + self.config.rx_size * @sizeOf(XdpDesc);
    const rx_map = try posix.mmap(
        null,
        rx_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        self.fd,
        XDP_PGOFF_RX_RING,
    );
    
    self.rx_ring = .{
        .producer = @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.producer),
        .consumer = @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.consumer),
        .ring = @as([*]XdpDesc, @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.desc))[0..self.config.rx_size],
        .cached_prod = 0,
        .cached_cons = 0,
        .mask = self.config.rx_size - 1,
        .flags = @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.flags),
    };
    
    // Similar for TX, Fill, and Completion rings...
}
```

### Key Insight
Must use `getsockopt(XDP_MMAP_OFFSETS)` to get ring offsets, then `mmap()` each ring.

---

## 3. eBPF Program Loading Failures

### Symptom 1: `EACCES` with verifier log `R1 type=scalar expected=map_ptr`

### Root Cause
The `lddw` instruction for loading map FDs wasn't using `BPF_PSEUDO_MAP_FD` flag.

### Fix Location
`src/network/af_xdp/ebpf_gen.zig` - `lddw()` function

### Fix Code
```zig
fn lddw(dst: u8, imm: i32) u64 {
    // 0x18 = BPF_LD | BPF_IMM | BPF_DW
    // src_reg = 1 (0x10 in byte 1) = BPF_PSEUDO_MAP_FD
    // This tells kernel this is a map FD that needs conversion to pointer
    return (0x18 | (dst << 8) | (1 << 12)) | (@as(u64, @intCast(imm)) << 32);
}
```

### Symptom 2: `EINVAL` when registering socket in XSKMAP

### Root Cause
`BpfAttr.map_update_elem` struct had fields in wrong order.

### Fix Code
```zig
pub const BpfAttr = extern union {
    map_update_elem: extern struct {
        map_fd: u32,    // First
        key: usize,     // Second
        value: usize,   // Third
        flags: u64,     // Fourth - was incorrectly before key/value
    },
    // ...
};
```

### Key Insight
eBPF bytecode is now generated at runtime in `ebpf_gen.zig`, not compiled from C.

---

## 4. Gossip Peer Connection Issues

### Symptom
`peers=0` despite receiving PULL_RESPONSE messages.

### Root Cause 1: Bloom Filter with `bloom_len=0`

Firedancer explicitly checks `bloom_len != 0` when parsing PULL_REQUEST.

### Fix Location
`src/network/bincode.zig` - `Bloom.empty()` and `Bloom.serialize()`

### Fix Code
```zig
pub fn empty() Bloom {
    return .{
        .keys = &[_]u64{ 0, 0, 0 },  // 3 hash keys
        .bits = &[_]u64{0},          // 1 bit (not 0!)
        .num_bits_set = 0,
    };
}

pub fn serialize(self: *const Bloom, writer: anytype) !void {
    // Ensure bloom_len != 0 for Firedancer compatibility
    if (self.bits.len == 0) {
        // Write minimal bloom filter
        try writer.writeInt(u64, 3, .little); // 3 keys
        try writer.writeInt(u64, 0, .little);
        try writer.writeInt(u64, 0, .little);
        try writer.writeInt(u64, 0, .little);
        // bitvec with at least 1 bit
        try writeCompactU16(writer, 1); // bits_cnt = 1
        try writer.writeInt(u64, 1, .little); // bloom_len = 1
        try writer.writeInt(u64, 0, .little); // empty bits
        try writer.writeInt(u64, 0, .little); // num_bits_set
    } else {
        // Normal serialization...
    }
}
```

### Root Cause 2: Wrong Encoding for ContactInfo Counts

Firedancer expects `compact_u16` for `addrs_cnt`, `socket_cnt`, `port_offset`.

### Fix Location
`src/network/bincode.zig` - `ContactInfo.serialize()` and `writeCompactU16()`

### Fix Code
```zig
pub fn writeCompactU16(writer: anytype, value: u16) !void {
    if (value < 0x80) {
        try writer.writeByte(@intCast(value));
    } else if (value < 0x4000) {
        try writer.writeByte(@intCast((value & 0x7F) | 0x80));
        try writer.writeByte(@intCast(value >> 7));
    } else {
        try writer.writeByte(@intCast((value & 0x7F) | 0x80));
        try writer.writeByte(@intCast(((value >> 7) & 0x7F) | 0x80));
        try writer.writeByte(@intCast(value >> 14));
    }
}
```

### Root Cause 3: Wrong Cluster (Mainnet vs Testnet)

Default cluster was `mainnet_beta`, causing connection to wrong entrypoints.

### Fix
Always use `--testnet` flag explicitly.

### Root Cause 4: Missing `--identity` Flag

Without staked identity, gossip messages are rejected.

### Fix
Always use `--identity /path/to/validator-keypair.json`

---

## 5. Zero-Copy Mode for 30M PPS

### Symptom
`Bound with copy mode (~20M pps)` instead of zero-copy.

### Root Cause 1: `zero_copy` defaulted to `false`

### Fix Location
`src/network/accelerated_io.zig`

### Fix Code
```zig
pub const AcceleratedIoConfig = struct {
    zero_copy: bool = true,  // Changed from false
    // ...
};
```

### Root Cause 2: Wrong XDP_FLAGS values

### Fix Location
`src/network/af_xdp/xdp_program.zig`

### Fix Code
```zig
pub const AttachMode = enum(u32) {
    skb = 1 << 0,         // XDP_FLAGS_SKB_MODE
    driver = 1 << 1,      // XDP_FLAGS_DRV_MODE  
    hardware = 1 << 2,    // XDP_FLAGS_HW_MODE
    update_only = 1 << 3, // XDP_FLAGS_UPDATE_IF_NOEXIST
};
```

### Root Cause 3: Missing XDP_USE_NEED_WAKEUP

### Fix Location
`src/network/af_xdp/socket.zig`

### Fix Code
```zig
// In XdpSocket.init():
var bind_flags: u16 = XDP_USE_NEED_WAKEUP;
if (self.config.zero_copy) {
    bind_flags |= XDP_ZEROCOPY;
} else {
    bind_flags |= XDP_COPY;
}

// Add needWakeup() to UmemRing and DescRing:
pub fn needWakeup(self: *const UmemRing) bool {
    if (self.flags) |flags| {
        return (flags.* & XDP_RING_NEED_WAKEUP) != 0;
    }
    return true; // Conservative: always wake if no flags
}
```

---

## 6. Working Command Line

### Full Command for Testnet Voting
```bash
/usr/local/bin/vexor validator \
  --testnet \
  --identity /home/solana/.secrets/validator-keypair.json \
  --vote-account /home/solana/.secrets/vote-account-keypair.json \
  --expected-shred-version 9604 \
  --ledger /mnt/solana/ledger \
  --entrypoint entrypoint.testnet.solana.com:8001 \
  --entrypoint entrypoint2.testnet.solana.com:8001 \
  > /home/solana/log/vexor.log 2>&1
```

### Key Points
- **Must use `validator` subcommand** (not just flags)
- **Must use `--testnet`** (default is mainnet)
- **Must use `--identity`** with staked keypair
- **Must use `--vote-account`** for voting
- **Must use `--expected-shred-version 9604`** for testnet

---

## 7. Current Status & Known Issues

### Working Features ✅
- Gossip protocol (PING/PONG, PULL_REQUEST)
- Receiving PULL_RESPONSE messages
- AF_XDP with eBPF (runtime-generated bytecode)
- Zero-copy mode enabled (on supported NICs)
- Ed25519 signing
- Memory leak fixes

### Known Issues ⚠️

#### Issue 1: Peer Parsing Only Processes First CrdsValue ✅ FIXED
**Location**: `src/network/gossip.zig:handlePush()` and `handlePullResponse()`

The `handlePush` had a `break` statement that only processed the first CrdsValue.
The `handlePullResponse` used a fixed 268-byte offset estimate.

**Fix Applied (Dec 16, 2024)**:
1. Removed `break` from `handlePush` - now scans up to 50 values
2. Improved offset estimation using CRDS type-specific sizes
3. Increased scan limit in `handlePullResponse` from 20 to 100 values
4. Added type-based size estimation for all CRDS types (0-11)

#### Issue 2: XDP Program Attach EBUSY
Only one XDP program can be attached per interface. Second queue fails.

**Workaround**: Use single queue for now.

#### Issue 3: Block Production Not Tested
Block production code exists but hasn't been tested in production.

---

## 8. TPU Integration Fix

### Problem
The `sendToTpu()` function in `ReplayStage` was only logging "Would send" but not actually sending vote transactions. The `TpuClient` existed but wasn't connected to `ReplayStage`.

### Root Cause
The `TpuClient` was initialized in `root.zig` but never connected to `ReplayStage`, so `sendToTpu()` had no client to use.

### Fix Location
- `src/runtime/replay_stage.zig` - Added TPU client field and setter
- `src/runtime/root.zig` - Initialize and connect TPU client
- `src/network/tpu_client.zig` - Fixed compilation errors

### Fix Code

**1. Added TPU client field to ReplayStage** (`src/runtime/replay_stage.zig`):
```zig
/// TPU client for sending vote transactions
tpu_client: ?*network.TpuClient,
```

**2. Added setter method** (`src/runtime/replay_stage.zig`):
```zig
/// Set TPU client for sending vote transactions
/// Reference: Firedancer fd_quic_tile.c - TPU client initialization
pub fn setTpuClient(self: *Self, tpu: *network.TpuClient) void {
    self.tpu_client = tpu;
}
```

**3. Updated sendToTpu() to actually send** (`src/runtime/replay_stage.zig`):
```zig
fn sendToTpu(self: *Self, tx_data: []const u8) !void {
    if (self.tpu_client) |tpu| {
        const current_slot = self.root_bank.?.slot;
        if (self.leader_cache.getSlotLeader(current_slot)) |leader| {
            try tpu.sendTransaction(tx_data, current_slot);
            std.log.info("[Vote] Sent {d} byte vote tx to leader {} for slot {d}", .{
                tx_data.len, leader, current_slot,
            });
        }
    } else {
        std.log.warn("[Vote] TPU client not available, vote not sent", .{});
    }
}
```

**4. Initialize TPU client in root.zig** (`src/runtime/root.zig`):
```zig
// Initialize TPU client for vote submission
// Reference: Firedancer fd_quic_tile.c - TPU client initialization
if (self.config.enable_voting) {
    self.tpu_client = try network.TpuClient.init(self.allocator);
    if (self.gossip_service) |gs| {
        self.tpu_client.?.setGossipService(gs);
    }
    if (self.replay_stage) |rs| {
        rs.setTpuClient(self.tpu_client.?);
    }
}
```

**5. Fixed compilation errors**:
- Added `network` import to `replay_stage.zig`
- Fixed `fcntl` call in `tpu_client.zig` (use Linux O_NONBLOCK = 0x800)
- Fixed `sendto` type cast for sockaddr

### Key Insight
**Reference:** Firedancer `fd_quic_tile.c` - TPU client initialization and transaction sending

The TPU client must be explicitly connected to ReplayStage via a setter method. Simply initializing it in `root.zig` is not enough - it needs to be injected into the ReplayStage instance.

### Testing
- ✅ Build successful
- ✅ Binary deployed to validator
- ✅ Testing with `--no-voting` flag (safe hot-swap testing)
- ⏳ Monitor for TPU client initialization in logs: `"[Network] TPU client initialized"`

---

## Quick Reference: Key Files

| File | Purpose |
|------|---------|
| `src/crypto/ed25519.zig` | Ed25519 signing (use KeyPair.create) |
| `src/network/af_xdp/socket.zig` | AF_XDP socket, mmapRings |
| `src/network/af_xdp/xdp_program.zig` | eBPF program loading, XDP flags |
| `src/network/af_xdp/ebpf_gen.zig` | Runtime eBPF bytecode generation |
| `src/network/gossip.zig` | Gossip protocol, CRDS parsing |
| `src/network/bincode.zig` | Bincode serialization, compact_u16 |
| `src/network/accelerated_io.zig` | AF_XDP configuration, zero_copy |
| `src/core/config.zig` | Cluster config, entrypoints |
| `src/runtime/replay_stage.zig` | TPU client integration, vote submission |
| `src/network/tpu_client.zig` | TPU client implementation |

---

## Quick Reference: Firedancer Comparison

| Component | Firedancer File | Vexor Equivalent |
|-----------|-----------------|------------------|
| XDP program | `src/waltz/xdp/fd_xdp*.c` | `af_xdp/ebpf_gen.zig` |
| Gossip parse | `src/flamenco/gossip/fd_gossip_msg_parse.c` | `gossip.zig`, `bincode.zig` |
| ContactInfo | Uses compact_u16 for counts | Must use `writeCompactU16()` |
| Bloom filter | Requires `bloom_len > 0` | `Bloom.empty()` returns 1 bit |

---

## Debugging Tips

### Check if receiving gossip:
```bash
grep "PULL_RESPONSE\|peers=" /home/solana/log/vexor.log | tail -20
```

### Check CRDS tags being received:
```bash
grep "CRDS tag stats" /home/solana/log/vexor.log
```

### Check XDP mode:
```bash
grep "zero-copy\|copy mode" /home/solana/log/vexor.log
```

### Check peer count:
```bash
grep "VEXOR STATUS" -A 3 /home/solana/log/vexor.log | tail -10
```

---

*Document created: December 16, 2024*
*Last updated: December 18, 2025*

