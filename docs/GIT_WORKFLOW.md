# Vexor Git Workflow

## Repository

**GitHub:** https://github.com/DavidB-77/Vexor

## Current Status: NOT READY FOR PUSH

⚠️ **Do NOT push to GitHub until the following milestones are achieved:**

### Minimum Requirements Before First Push

- [ ] Snapshot loading fully working (including `loadAppendVec`)
- [ ] Account loading from snapshot complete
- [ ] Basic block production working
- [ ] Vote transactions submitting
- [ ] Can maintain consensus with testnet

### Nice to Have Before Push

- [ ] Snapshot discovery via gossip (CRDS SnapshotHashes)
- [ ] Fast catchup with shred repair
- [ ] Stable running for 24+ hours on testnet

## Why Wait?

1. **Quality** - First impression matters for open source
2. **Security** - No accidental credential commits
3. **Completeness** - README should reflect working software
4. **Documentation** - Should have basic usage docs

## When Ready

1. Review all files for secrets/credentials
2. Update README with accurate status
3. Create proper .gitignore
4. Initialize repo locally:
   ```bash
   cd /home/dbdev/solana-client-research/vexor
   git init
   git remote add origin git@github.com:DavidB-77/Vexor.git
   ```
5. Make initial commit
6. Push to GitHub

## Files to NEVER Commit

- `*.json` keypair files
- SSH keys
- API tokens
- `.env` files with secrets
- Validator identity/vote keys

## Local Development

Until ready for GitHub, all version tracking is done via:
- `CHANGELOG.md` - Manual version history
- `.cursorrules` - AI assistant context
- `docs/` - Project documentation

---

*Last updated: 2024-12-13*

