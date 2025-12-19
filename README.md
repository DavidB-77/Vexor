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
```

## ⚙️ Feature Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-Dgpu=true` | false | Enable GPU acceleration |
| `-Daf_xdp=true` | false | Enable AF_XDP kernel bypass |
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
├── dashboard/             # Next.js monitoring dashboard
├── docs/                  # Documentation
├── scripts/               # Utility scripts
└── build.zig              # Build configuration
```

## 🔄 CLI Compatibility

Vexor uses **the same CLI flags as Agave (solana-validator)** to enable seamless switching between clients.

```bash
# Your existing Agave startup script:
solana-validator \
    --identity ~/validator-keypair.json \
    --vote-account ~/vote-account-keypair.json \
    --ledger /mnt/ledger

# Just change the binary name:
vexor validator --bootstrap \
    --testnet \
    --identity ~/validator-keypair.json \
    --vote-account ~/vote-account-keypair.json \
    --ledger /mnt/ledger
```

## 📊 Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| TPS | 1,000,000+ | Transaction throughput |
| Sig Verify | 500,000/sec | Per CPU core with SIMD |
| Packet Processing | 1M+ pps | With AF_XDP |
| Memory | < 128 GB | Full mainnet state |

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

## 📜 License

MIT License

## 🙏 Acknowledgments

- Solana Labs for the protocol specification
- Jump Crypto for Firedancer inspiration
- The Zig community for an excellent language
