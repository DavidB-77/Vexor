# Missing Integrations Found During Testing

**Date:** December 15, 2024  
**Status:** 🔴 **CRITICAL - Blocking Vote Submission**

## Issue #1: TPU Client Not Integrated in ReplayStage

### Problem
The `sendToTpu()` function in `src/runtime/replay_stage.zig` (line 297) only **logs** that it would send a vote transaction, but doesn't actually send it:

```zig
fn sendToTpu(self: *Self, tx_data: []const u8) !void {
    // Get our TPU address from leader schedule for current slot
    const current_slot = self.root_bank.?.slot;
    
    if (self.leader_cache.getSlotLeader(current_slot)) |leader| {
        // Look up leader's TPU address from cluster info
        // For now, we just log that we would send
        std.log.info("[Vote] Would send {d} byte vote tx to leader {}", .{
            tx_data.len,
            std.fmt.fmtSliceHexLower(&leader),
        });
    }
}
```

### Solution
1. Add `tpu_client: ?*network.TpuClient` field to `ReplayStage` struct
2. Add `setTpuClient()` method to inject TPU client
3. Update `sendToTpu()` to actually use the TPU client:
   ```zig
   fn sendToTpu(self: *Self, tx_data: []const u8) !void {
       if (self.tpu_client) |tpu| {
           const current_slot = self.root_bank.?.slot;
           if (self.leader_cache.getSlotLeader(current_slot)) |leader| {
               // Get leader's TPU address from gossip
               const tpu_addr = try self.getLeaderTpuAddress(leader, current_slot);
               try tpu.sendTransaction(tpu_addr, tx_data);
           }
       } else {
           std.log.warn("[Vote] TPU client not available, vote not sent", .{});
       }
   }
   ```

### Reference
- **Firedancer:** `src/disco/quic/fd_quic_tile.c` - TPU tile implementation
- **Vexor:** `src/network/tpu_client.zig` - TPU client exists but not connected

---

## Testing Status

### Current State
- ✅ Build successful
- ✅ Binary copied to validator
- ⚠️ Old Vexor process still running (PID 2968835, `/tmp/vexor-v10`)
- ⚠️ New binary at `/home/solana/bin/vexor/vexor` (Dec 14 build, not latest)

### Next Steps
1. Stop old Vexor process
2. Replace with new binary
3. Run test with voting enabled
4. Monitor for vote submission attempts
5. Fix TPU integration
6. Re-test

