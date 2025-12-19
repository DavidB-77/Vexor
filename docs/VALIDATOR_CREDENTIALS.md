# Validator Credentials

**⚠️ SENSITIVE INFORMATION - DO NOT COMMIT TO GIT**

## Credentials

- **Username:** `davidb`
- **Password:** `Snapshot26*=`
- **Host:** `v1.qubestake.io` (38.92.24.174)

## Storage

Credentials are stored in:
- `.credentials` file (gitignored)
- Memory (MCP) for automated use

## Usage

### Automated (Scripts)
Scripts automatically load from `.credentials`:
```bash
./scripts/deploy_to_validator.sh
```

### Manual
```bash
# SSH to validator
ssh davidb@v1.qubestake.io

# With password (if sshpass installed)
sshpass -p 'Snapshot26*=' ssh davidb@v1.qubestake.io

# Sudo commands
echo 'Snapshot26*=' | sudo -S <command>
```

## Security Notes

- ✅ Credentials file is gitignored
- ✅ Only used for validator deployment/testing
- ✅ Stored locally only
- ⚠️ Do not share or commit credentials

## Related Files

- `.credentials` - Credentials file (gitignored)
- `scripts/deploy_to_validator.sh` - Uses credentials automatically
- `docs/EBPF_DEPLOYMENT_GUIDE.md` - Deployment instructions

