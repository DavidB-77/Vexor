# Vexor

**Ve**lox (swift) + Ful**gor** (brilliance) = **Vexor**

A high-performance, lightweight Solana validator client built in Zig.

## 🎯 Goals

- **Performance**: Target 1M+ TPS, matching Firedancer
- **Lightweight**: Run on consumer-grade hardware
- **Efficient**: Minimal resource footprint
- **Automatic**: Built-in system optimization

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         VEXOR RUNTIME                           │
├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
│  NETWORK    │  CONSENSUS  │   STORAGE   │   CRYPTO    │ OPTIM.  │
│  ─────────  │  ─────────  │   ───────   │   ──────    │ ─────── │
│  AF_XDP     │  Tower BFT  │  RAM Disk   │  Ed25519    │ HW Det. │
│  QUIC       │  Alpenglow  │  NVMe SSD   │  BLS        │ Tuning  │
│  TPU/TVU    │  Votor      │  AccountsDB │  GPU(opt)   │ LLM(?)  │
└─────────────┴─────────────┴─────────────┴─────────────┴─────────┘
```

## 🛠️ Building

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run validator
zig build run -- validator --identity ~/keypair.json

# Run benchmarks
zig build bench

# Run tests
zig build test

# Run system optimizer
zig build optimize
```

## ⚙️ Feature Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-Dgpu=true` | false | Enable GPU acceleration |
| `-Daf_xdp=true` | true | Enable AF_XDP kernel bypass |
| `-Dramdisk=true` | true | Enable RAM disk tier-0 storage |
| `-Dalpenglow=true` | false | Enable Alpenglow consensus |
| `-Dauto_optimize=true` | true | Enable auto-optimizer |

## 📁 Project Structure

```
vexor/
├── src/
│   ├── main.zig           # Entry point
│   ├── bench.zig          # Benchmarks
│   ├── core/              # Core types, config, allocators
│   ├── network/           # AF_XDP, QUIC, gossip, TPU, TVU
│   ├── consensus/         # Tower BFT, Alpenglow, fork choice
│   ├── storage/           # AccountsDB, blockstore, snapshots
│   ├── crypto/            # Ed25519, SHA-256, BLS, GPU accel
│   ├── optimizer/         # Hardware detection, system tuning
│   └── runtime/           # Main validator runtime
├── tests/                 # Integration tests
├── config/                # Configuration files
├── scripts/               # Utility scripts
└── build.zig              # Build configuration
```

## 🔄 CLI Compatibility

Vexor uses **the same CLI flags as Agave (solana-validator)** to enable seamless switching between clients. Your existing validator scripts will work with minimal or no changes.

### Agave-Compatible Flags
```bash
# These flags work exactly like solana-validator:
--identity <KEYPAIR>          # Validator identity
--vote-account <KEYPAIR>      # Vote account  
--ledger <DIR>                # Ledger directory
--accounts <DIR>              # Accounts directory
--entrypoint <HOST:PORT>      # Cluster entrypoint
--rpc-port <PORT>             # RPC port
--dynamic-port-range <RANGE>  # Port range
--limit-ledger-size           # Limit ledger size
--cuda                        # Enable GPU (alias: --enable-gpu)
--known-validator <PUBKEY>    # Known validators
--log <PATH>                  # Log file
```

### Vexor-Specific Flags
```bash
# Additional Vexor optimizations:
--enable-af-xdp               # Kernel bypass networking
--enable-ramdisk              # RAM disk for hot storage
--ramdisk-size <GB>           # RAM disk size
--disable-auto-optimize       # Skip auto system tuning
```

## 🚀 Quick Start (Unified Installer)

The recommended way to install Vexor is using the **unified installer**:

```bash
# 1. Build the installer
zig build -Doptimize=ReleaseFast

# 2. Test the installer first (dry-run, no changes)
./zig-out/bin/vexor-install --dry-run install --testnet

# 3. Run full installation (interactive)
sudo ./zig-out/bin/vexor-install install --testnet

# 4. Check status
vexor-install status

# 5. Test bootstrap (safe, doesn't stop Agave)
vexor-install test-bootstrap

# 6. Switch to Vexor (stops Agave!)
sudo vexor-install switch-to-vexor

# 7. If issues, rollback to Agave
sudo vexor-install switch-to-agave
```

### Installer Commands

| Command | Description |
|---------|-------------|
| `install` | Full installation with all steps |
| `audit` | System audit only (no changes) |
| `fix` | Interactive fix for all issues |
| `fix-permissions` | Fix all permission issues at once |
| `test-bootstrap` | Test snapshot loading (safe) |
| `test-network` | Test networking (stops Agave!) |
| `switch-to-vexor` | Switch from Agave to Vexor |
| `switch-to-agave` | Rollback from Vexor to Agave |
| `swap-keys` | Hot-swap validator identity/vote keys |
| `diagnose` | Run comprehensive health checks |
| `status` | Show current validator state |
| `health` | Health check with auto-fix |
| `backup` | Create full system state backup |
| `restore` | Restore from backup |

### Installer Modes

```bash
# Dry-run mode - test without making changes (RECOMMENDED FIRST!)
vexor-install --dry-run install --testnet

# Debug mode - verbose output, full diagnostics
sudo vexor-install --debug install --testnet

# Debug specific subsystem
sudo vexor-install --debug=network install
sudo vexor-install --debug=storage install
sudo vexor-install --debug=compute install
sudo vexor-install --debug=system install
sudo vexor-install --debug=all install

# Production mode - clean install (default)
sudo vexor-install --production install --mainnet-beta
```

### Key Features

- ✅ **Unified Installer** - Single entry point for all operations
- ✅ **Dry-Run Mode** - Test safely without making changes
- ✅ **Automatic Backup** - Creates backup before any changes
- ✅ **Key Management** - Hot-swap keys, detect existing keys
- ✅ **Client Detection** - Detects ANY validator client
- ✅ **Automatic Rollback** - On failure or interference
- ✅ **Dual System** - Automatic switching between clients
- ✅ **Non-Interference** - Doesn't modify existing tuning
- ✅ **Comprehensive Audit** - Checks everything (network, storage, compute, system)

## 🔧 Manual Setup

If you prefer manual setup:

```bash
# 1. Build the validator
zig build -Doptimize=ReleaseFast -Daf_xdp=true

# 2. Run system optimizer (requires root)
sudo ./zig-out/bin/vexor-optimize optimize

# 3. Start validator with bootstrap
./zig-out/bin/vexor run --bootstrap \
    --testnet \
    --identity ~/validator-keypair.json \
    --vote-account ~/vote-account-keypair.json \
    --ledger /mnt/ledger \
    --accounts /mnt/accounts \
    --snapshots /mnt/snapshots
```

### Switching from Agave
```bash
# Your existing Agave startup script:
solana-validator \
    --identity ~/validator-keypair.json \
    --vote-account ~/vote-account-keypair.json \
    --ledger /mnt/ledger \
    --accounts /mnt/accounts \
    --entrypoint entrypoint.mainnet-beta.solana.com:8001 \
    --limit-ledger-size

# Just change the binary name:
vexor run --bootstrap \
    --mainnet-beta \
    --identity ~/validator-keypair.json \
    --vote-account ~/vote-account-keypair.json \
    --ledger /mnt/ledger \
    --accounts /mnt/accounts \
    --limit-ledger-size
```

## 📊 Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| TPS | 1,000,000+ | Transaction throughput |
| Sig Verify | 500,000/sec | Per CPU core with SIMD |
| Packet Processing | 1M+ pps | With AF_XDP |
| Memory | < 128 GB | Full mainnet state |
| CPU | Consumer Ryzen | 7950X or similar |

## 🔧 System Requirements

### Minimum (Testnet)
- CPU: 8 cores / 16 threads
- RAM: 64 GB
- Storage: 500 GB NVMe SSD
- Network: 1 Gbps

### Recommended (Mainnet)
- CPU: AMD Ryzen 9 7950X (16 cores / 32 threads)
- RAM: 128 GB DDR5
- Storage: 2 TB NVMe SSD + 32 GB RAM disk
- Network: 10 Gbps
- GPU: NVIDIA RTX 4060 (optional)

## 📜 License

MIT License - see LICENSE file

## 🙏 Acknowledgments

- Solana Labs for the protocol specification
- Jump Crypto for Firedancer inspiration
- The Zig community for an excellent language

