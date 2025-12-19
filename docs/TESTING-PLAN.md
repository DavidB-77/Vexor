# Vexor Testing Plan - December 15, 2024

## Current Status
- ✅ Build successful (fixed compilation errors)
- ✅ Binary copied to validator: `/tmp/vexor-new`
- ⚠️ Vexor already running on validator (PID 2968835, started Dec 14)
- ⚠️ Current process using `/tmp/vexor-v10` (old binary)

## Testing Strategy

### Phase 1: Check Current Process
1. Check what the current Vexor process is doing
2. Check logs for any errors or issues
3. Verify slot sync status
4. Check if voting is enabled/disabled

### Phase 2: Test with Voting Enabled
1. Stop current Vexor process (if needed)
2. Replace binary: `/home/solana/bin/vexor/vexor` → `/tmp/vexor-new`
3. Run with voting **ENABLED** (remove `--no-voting` flag):
   ```bash
   sudo -u solana /home/solana/bin/vexor/vexor run \
     --testnet --bootstrap \
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
4. Monitor for:
   - Vote submission attempts
   - Slot processing
   - Any errors or missing components

### Phase 3: Monitor & Debug
1. Watch logs in real-time
2. Check vote transactions on-chain
3. Monitor slot sync
4. Check for any missing implementations

## Key Files to Reference
- **Firedancer repo** (FIRST - C/C++ reference)
- **Zig MCP** (for Zig-specific issues)
- **Solana MCP** (for Solana protocol questions)

## Commands

### Check Current Process
```bash
ssh validator "ps aux | grep vexor | grep -v grep"
ssh validator "tail -100 /mnt/vexor/logs/vexor.log 2>/dev/null || echo 'No log file'"
```

### Replace Binary
```bash
ssh validator "sudo mv /tmp/vexor-new /home/solana/bin/vexor/vexor"
ssh validator "sudo chown solana:solana /home/solana/bin/vexor/vexor"
ssh validator "sudo chmod +x /home/solana/bin/vexor/vexor"
```

### Run Test
```bash
ssh validator "sudo -u solana /home/solana/bin/vexor/vexor run --testnet --bootstrap --identity /home/solana/.secrets/validator-keypair.json --vote-account /home/solana/.secrets/vote-account-keypair.json --ledger /mnt/vexor/ledger --snapshots /mnt/vexor/snapshots --public-ip 38.92.24.174 --rpc-port 8999 --gossip-port 8101 --tvu-port 9004 --verbose 2>&1 | tee /tmp/vexor-test.log"
```

### Monitor
```bash
ssh validator "tail -f /tmp/vexor-test.log"
```

