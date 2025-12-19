# Vexor Testing Log - December 15, 2024

## Test Session: TPU Integration Fix

### Setup
- **Binary:** `/home/solana/bin/vexor/vexor` (TPU integration fixed)
- **Validator:** 38.92.24.174
- **Mode:** Hot-swap testing with `--no-voting` flag
- **Ports:** gossip 8101, RPC 8999, TVU 9004 (alternate to Agave)
- **Keys:** Using validator's actual keys (safe with --no-voting)

### Test Command
```bash
sudo -u solana /home/solana/bin/vexor/vexor run \
  --testnet --bootstrap --no-voting \
  --identity /home/solana/.secrets/validator-keypair.json \
  --vote-account /home/solana/.secrets/vote-account-keypair.json \
  --ledger /mnt/vexor/ledger \
  --snapshots /mnt/vexor/snapshots \
  --public-ip 38.92.24.174 \
  --rpc-port 8999 \
  --gossip-port 8101 \
  --tvu-port 9004 \
  --verbose
```

### Timeline

**09:28 AM - Startup Successful**
- ✅ **Old process stopped** (PID 2968835 killed)
- ✅ **New process started** (PID 4130654) with TPU-fixed binary
- ✅ **Running as solana user** with `--no-voting` flag
- ✅ **Bootstrap started** - loading snapshot slot 374576751
- ✅ **Gossip active** - sending pulls to entrypoints
- ⏳ **Status:** Waiting for peer connections (peers=0 currently)
- ⏳ **TVU:** No shreds received yet (rcvd=0)

**Old Process Details:**
- PID: 2968835
- Binary: `/tmp/vexor-v10` (old version)
- Ports: gossip 9001, RPC 9899, TVU 9002
- Started: Dec 14
- Status: Still running

**New Process Should Use:**
- Binary: `/home/solana/bin/vexor/vexor` (TPU-fixed)
- Ports: gossip 8101, RPC 8999, TVU 9004
- Flag: `--no-voting` (safe hot-swap testing)

**Monitoring Points:**
1. ✅ Bootstrap complete - slot 374576751
2. ✅ RPC server listening on port 8999
3. ✅ Gossip advertising contact info (IP: 38.92.24.174, ports configured correctly)
4. ⏳ TPU client initialization - **NOTE:** With `--no-voting`, TPU client may not initialize (expected)
5. ⏳ Gossip peer connections (currently peers=0, sending pulls to entrypoints)
6. ⏳ TVU shred reception (currently rcvd=0)
7. ⏳ Slot processing
8. ⏳ Network slot sync

### Expected Behavior (with --no-voting)
- ✅ Bootstrap complete
- ✅ RPC server running
- ✅ Gossip advertising and trying to connect
- ⏳ Gossip should connect to peers (currently trying)
- ⏳ TVU should receive shreds (waiting for network)
- ⏳ Slots should process (once shreds received)
- ❌ TPU client may NOT initialize (expected - only initializes when `enable_voting=true`)
- ❌ Votes should NOT be sent (--no-voting flag)
- ❌ Blocks should NOT be produced

### Issues Found
- ⚠️ **Old Vexor process still running** (PID 2968835, `/tmp/vexor-v10`)
  - Needs to be stopped before new process can fully start
  - Old process using ports: gossip 9001, RPC 9899, TVU 9002
  - New process should use: gossip 8101, RPC 8999, TVU 9004
- ⚠️ **Sudo access needed** to stop old process and start new one properly

### Next Steps
1. Monitor for TPU client initialization
2. Verify gossip connections
3. Verify shred reception
4. Check slot sync status
5. Remove `--no-voting` and test actual vote submission

