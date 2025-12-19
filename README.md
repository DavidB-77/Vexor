# VEXOR

High-performance Solana validator client written in Zig.

## Features

- Tower BFT consensus with proper vote signing
- Vote transaction submission to TPU
- AF_XDP network acceleration (optional)
- Compatible with Solana testnet

## Build

```bash
zig build -Doptimize=ReleaseFast
```

## Deploy

```bash
scp zig-out/bin/vexor root@YOUR_SERVER:/home/sol/vexor/bin/vexor-validator
```
