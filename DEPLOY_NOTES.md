# Vexor Deployment Notes

## Build & Deploy Workflow

### Source Code (Single Source of Truth)
- **Local path**: `/home/dbdev/solana-client-research/vexor/`
- There is NO source code on the validator — only compiled binaries.
- All builds happen locally, then the binary is `scp`'d to the validator.

### Build Output
- **Local binary**: `/home/dbdev/solana-client-research/vexor/zig-out/bin/vexor`
- Build command: `zig build` (from the project root)

### Validator Server
- **Server**: `YOUR_VALIDATOR_IP` (port 2222, user `sol`)
- **SSH key**: `~/.ssh/vexor_validator`
- **Active binary**: `/home/sol/vexor/bin/vexor-validator`
- **Backup binaries**: `/home/sol/vexor/bin/vexor-*.backup*` (multiple dated backups)
- **Debug binaries**: `/home/sol/vexor/bin/vexor-{deltahash,entry-fix,entry-limit,graceful-replay,hexdump-diag,lockfix,nuclear-fix,nuclear-fix-v2,replay-enabled,trace,trace2,writecache}` — named snapshots from debugging sessions
- **Old/original binary**: `/home/sol/vexor/vexor-validator` (Feb 7, 2026 — NOT the active one)
- **Support files**: `/home/sol/vexor/` — tower-state.bin, vexor.log, slot_*_fail.bin, scripts/, metrics/

### Deploy Command
```bash
scp scp -P 2222 \
  /home/dbdev/solana-client-research/vexor/zig-out/bin/vexor \
  root@YOUR_VALIDATOR_IP:/home/sol/vexor/bin/vexor-validator
```

### Other Vexor-Related Locations on the Server
- `/opt/vexor/config/` — validator keypair files (validator-private.key, validator-public.key)
- `/opt/vexor-dashboard/` — Dashboard UI (dist/, server-prod.mjs, vexor-metrics-exporter.py)
- `/opt/vexor-monitoring/` — monitoring-scripts, vexor_metrics.sh
- `/home/sol/vexor-monitoring/` — vexor_metrics.sh (symlink or copy)

### GitHub Repo
- **Repo**: `https://github.com/DavidB-77/Vexor`
- **Status**: 3 months behind local (last pushed Dec 23, 2025)
- **Needs**: Full push of all uncommitted changes (78 files, +19K lines)

## Verified Binary Match (March 14, 2026)
```
LOCAL:     md5=1254c7a5c07322d052018684ecd50096  size=17274296  date=2026-03-13 22:46 CST
VALIDATOR: md5=1254c7a5c07322d052018684ecd50096  size=17274296  date=2026-03-14 03:46 UTC
MATCH: ✅ IDENTICAL
```
