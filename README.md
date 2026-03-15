# Vexor

A high-performance Solana validator client written in Zig, designed for low-latency consensus participation and maximum throughput.

## Architecture

Vexor implements the full Solana validator stack from scratch in Zig, targeting native performance and minimal runtime overhead:

- **Gossip Protocol** — Full CRDS implementation with signed ContactInfo propagation, Ping/Pong protocol, and pull/push message handling. Discovers and maintains connections to 800+ cluster peers.
- **Turbine (TVU)** — Shred ingestion pipeline with kernel-bypass I/O (AF_XDP, io_uring) for sub-microsecond packet processing. Handles 80,000+ shreds/minute at network rate.
- **Shred Assembly** — Buffers incoming data and coding shreds per-slot, detects duplicates, tracks FEC set completions, and signals slot completion via zero-copy handoff to the replay stage.
- **FEC / Erasure Recovery** — Reed-Solomon erasure coding using GF(2^8) arithmetic with SIMD-accelerated Galois field operations for reconstructing missing data shreds from parity shreds.
- **Replay Stage** — Entry parsing, PoH hash verification, transaction execution, accounts delta hashing, and bank freeze pipeline.
- **Tower BFT** — Lockout-based vote tracking with 31-level confirmation stack, optimistic confirmation, and root advancement.
- **AccountsDb** — Append-only account storage with per-bin locking, parallel snapshot loading, and in-memory write cache for pending account mutations.
- **Repair Service** — Requests missing shreds from cluster peers using signed repair requests with proper protocol framing.
- **Leader Schedule** — Epoch-aware leader slot computation from stake-weighted shuffle.

## Building

Requires Zig 0.14.0 or later.

```bash
zig build
```

The validator binary will be at `zig-out/bin/vexor`.

### Build Modes

```bash
zig build                          # Debug (default)
zig build -Doptimize=ReleaseSafe   # Release with safety checks
zig build -Doptimize=ReleaseFast   # Maximum performance
```

## Running

```bash
./zig-out/bin/vexor \
    --identity /path/to/validator-keypair.json \
    --vote-account /path/to/vote-account-keypair.json \
    --entrypoint entrypoint.testnet.solana.com:8001 \
    --cluster testnet
```

See `--help` for the full list of configuration options.

## Project Structure

```
src/
├── main.zig                    # Entry point and CLI argument parsing
├── consensus/
│   ├── tower.zig               # Tower BFT vote tracking and lockout logic
│   ├── vote.zig                # Vote transaction construction and signing
│   ├── vote_tx.zig             # Vote instruction serialization
│   ├── leader_schedule.zig     # Epoch leader slot computation
│   ├── fork_choice.zig         # Fork selection rules
│   └── poh.zig                 # Proof of History verification
├── core/
│   ├── allocator.zig           # Memory allocation strategies
│   ├── base58.zig              # Base58 encoding/decoding
│   └── lock_free.zig           # Lock-free data structures
├── crypto/
│   ├── sigverify.zig           # Ed25519 signature verification thread pool
│   ├── chacha.zig              # ChaCha20 stream cipher
│   └── weighted_shuffle.zig    # Stake-weighted leader shuffle
├── network/
│   ├── gossip.zig              # Gossip protocol + CRDS table
│   ├── tvu.zig                 # Turbine shred receiver
│   ├── accelerated_io.zig      # AF_XDP / io_uring kernel bypass
│   └── af_xdp/                 # AF_XDP socket implementation
├── runtime/
│   ├── bootstrap.zig           # Validator bootstrap and lifecycle
│   ├── replay_stage.zig        # Block replay and bank advancement
│   ├── bank.zig                # Bank state management and hash computation
│   ├── shred.zig               # Shred parsing and Merkle verification
│   ├── fec_resolver.zig        # Reed-Solomon erasure recovery
│   └── transaction.zig         # Transaction processing
├── storage/
│   ├── accounts.zig            # AccountsDb with parallel snapshot loading
│   ├── snapshot.zig            # Snapshot deserialization
│   └── parallel_snapshot.zig   # Multi-threaded snapshot extraction
└── tools/
    └── installer/              # Remote deployment utilities
```

## Development Status

Vexor is under active development, targeting Solana testnet participation. Current capabilities:

- [x] Gossip protocol — cluster discovery and peer management
- [x] Turbine receiver — shred ingestion at network rate
- [x] Shred assembly — slot reconstruction from data shreds
- [x] FEC erasure recovery — Reed-Solomon coding shred reconstruction
- [x] Snapshot loading — parallel deserialization of AccountsDb state
- [x] Replay pipeline — entry parsing, PoH verification, transaction execution
- [x] Tower BFT — vote tracking with lockout and root advancement
- [x] Repair service — missing shred requests
- [ ] Signature verification — Ed25519 Merkle root verification (in progress)
- [ ] Parallel transaction execution
- [ ] Leader block production

## License

MIT
