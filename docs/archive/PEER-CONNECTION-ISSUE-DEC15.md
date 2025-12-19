# Peer Connection Issue - December 15, 2024

## Problem
Vexor is not connecting to any gossip peers (peers=0) despite:
- ✅ IP correctly advertised: `38.92.24.174`
- ✅ Keypair set and messages being signed
- ✅ Entrypoints resolving correctly
- ✅ Pull requests being sent to entrypoints

## Previous Fix (December 14, 2024)

### What Was Fixed
On Dec 14, Vexor successfully connected to **913 peers** after fixing:

1. **IP Advertisement Issue** ✅ (Already fixed in current run)
   - Was advertising `0.0.0.0` instead of public IP
   - Fixed by adding `--public-ip` flag and `setSelfInfo()` call
   - Current status: ✅ IP correctly advertised

2. **Gossip Protocol Fixes** (from CHANGELOG.md):
   - **PING Signature**: Sign only 32-byte token, not `from+token` (fd_gossip.c:779)
   - **PONG Signature**: Use SHA256_ED25519 mode - SHA256 the pre_image first, then Ed25519 sign (fd_keyguard.h:55)
   - **BitVec Serialization**: When empty, write only `has_bits=0` (1 byte), NO length field
   - **Modern ContactInfo**: Use tag=11 format (fd_gossvf_tile.c:786 rejects LegacyContactInfo!)
   - **Version Encoding**: major/minor/patch as varints, commit+feature_set as u32, client as varint
   - **Socket Encoding**: Sort by port, use relative port offsets
   - **Wallclock Freshness**: Update before each send - Firedancer rejects >15s old

### Dec 14 Working Command
```bash
sudo -u solana /home/solana/bin/vexor/vexor run \
  --debug --bootstrap --testnet \
  --identity /home/solana/.secrets/validator-keypair.json \
  --vote-account /home/solana/.secrets/vote-account-keypair.json \
  --ledger /mnt/vexor/ledger \
  --accounts /mnt/vexor/accounts \
  --snapshots /mnt/vexor/snapshots \
  --entrypoint entrypoint.testnet.solana.com:8001 \
  --no-voting \
  --rpc-port 8999 \
  --gossip-port 8101
```

**Note:** Dec 14 command used `--entrypoint entrypoint.testnet.solana.com:8001` explicitly, but current command relies on default entrypoints.

### Dec 14 Results
- **Gossip peers:** 913 nodes
- **TVU shreds received:** 35,800+ (and counting)
- **CRDS values received:** 9,102+
- **Network slot sync:** Only 20 slots behind live network!

## Current Status (Dec 15)

### What's Working
- ✅ IP correctly advertised: `38.92.24.174`
- ✅ Keypair set: "Keypair set - messages will now be signed"
- ✅ Entrypoints resolving:
  - `entrypoint.testnet.solana.com` → `35.203.170.30:8001`
  - `entrypoint2.testnet.solana.com` → `109.94.99.177:8001`
- ✅ Pull requests being sent to entrypoints

### What's Not Working
- ❌ No peers connecting (peers=0)
- ❌ No CRDS values received (values_rcvd=0)
- ❌ No TVU shreds received (rcvd=0)

## Possible Causes

1. **Gossip Protocol Mismatch**
   - Current code may have regressed on one of the Dec 14 fixes
   - Need to verify PING/PONG signatures match Firedancer
   - Need to verify ContactInfo format (tag=11) is correct
   - Need to verify wallclock freshness

2. **Message Rejection**
   - Entrypoints may be rejecting our pull requests
   - Could be signature verification failure
   - Could be ContactInfo format issue
   - Could be wallclock too old

3. **Network/Firewall**
   - UDP packets may be blocked
   - Port 8101 may not be accessible from outside
   - Entrypoints may not be able to reach us

4. **Missing Entrypoint Flag**
   - Dec 14 used explicit `--entrypoint` flag
   - Current run uses default entrypoints
   - May need to explicitly specify

## Root Cause Found! ⚠️

**The binary on the validator is OLD!**
- Binary timestamp: Dec 14 10:16 (before the fix)
- Gossip.zig fix timestamp: Dec 14 13:02 (1:02pm Central - when fix was made)
- **We were running an old binary that doesn't have the Dec 14 fixes!**

**Solution:** Build fresh debug binary and deploy it.

## Evidence from Dec 14 Logs ✅

Found `/tmp/vexor-v9.log` from Dec 14 12:00 showing **successful peer connections**:
- **951 peers connected** (matches user's "900+ peers" memory)
- **11,144 CRDS values received** (ContactInfo successfully parsed from PUSH messages)
- Progression: `peers=910` → `peers=951` → stabilized
- **Receiving PUSH messages** (1049, 505, 220 bytes) - these contain ContactInfo

**Key Insight:** The Dec 14 working version was successfully parsing ContactInfo from PUSH messages, which allowed peers to be added to the peer table. 

## Critical Fix: Compact_U16 Encoding ⚠️

**Root Cause:** We were using **regular varint encoding** instead of **Solana's compact_u16 format** for parsing ContactInfo!

Firedancer uses `compact_u16` (Solana-specific) for:
- Address count (fd_gossip_msg_parse.c:465)
- Socket count (fd_gossip_msg_parse.c:499)  
- Port offsets (fd_gossip_msg_parse.c:512)

**Our code was using regular varint**, which reads the wrong number of bytes and throws off the entire parsing!

**Fix Applied:** Changed all three locations to use proper `compact_u16` decoding (see `COMPACT_U16_FIX_DEC15.md`).

## ✅ FIXED! December 15, 2024

**Status: WORKING!**

After applying the `compact_u16` fix:
- **978 peers connected** (exceeded Dec 14's 951!)
- **7,292 CRDS values received**
- **Receiving PUSH messages** successfully
- **No crashes** - running stable

### Fixes Applied

1. ✅ **Compact_U16 encoding** - Fixed address count, socket count, and port offset parsing
2. ✅ **Shred parsing panic** - Added error handling for invalid shred types
3. ✅ **Fresh binary deployed** - All fixes included

### Current Status

```
║  Gossip: peers=978  values_rcvd=7292     pulls=198    ║
```

**Ready for voting and block production testing!**

### Known Issues (Non-blocking)

- TVU shreds showing as invalid (separate issue, doesn't block gossip)
- Network slot sync still pending (but gossip is working)
   - Check if any of the Dec 14 fixes were reverted
   - Verify PING/PONG signature implementation
   - Verify ContactInfo serialization (tag=11)

2. **Add debug logging**
   - Log when pull requests are sent
   - Log when responses are received (or not received)
   - Log signature verification results
   - Log ContactInfo serialization

3. **Test with explicit entrypoint flag**
   - Try adding `--entrypoint entrypoint.testnet.solana.com:8001` explicitly

4. **Check network connectivity**
   - Verify UDP port 8101 is accessible
   - Test if entrypoints can reach us
   - Check firewall rules

5. **Reference Firedancer source**
   - Check `fd_gossip.c` for PING/PONG signature requirements
   - Check `fd_gossvf_tile.c` for ContactInfo rejection reasons
   - Verify our implementation matches exactly

## Files to Check

- `src/network/gossip.zig` - Gossip protocol implementation
- `src/network/bincode.zig` - ContactInfo serialization
- `src/crypto/ed25519.zig` - Signature implementation
- Firedancer references:
  - `fd_gossip.c` - PING/PONG signatures
  - `fd_gossvf_tile.c` - ContactInfo validation
  - `fd_gossip_msg_ser.c` - Message serialization

