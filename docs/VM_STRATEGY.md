# Vexor VM Execution Strategy

## Overview

Vexor requires a virtual machine to execute Solana programs (smart contracts). All Solana programs compile to sBPF (Solana Berkeley Packet Filter), a modified eBPF instruction set. Any Solana validator client must execute this bytecode identically to maintain consensus.

This document outlines our approach to VM implementation, balancing immediate functionality with long-term performance goals.

## Current State

Vexor has a functional sBPF interpreter (`src/runtime/bpf/interpreter.zig`) that implements the core instruction set: ALU operations, memory access, jumps, and function calls. The syscall framework exists but is not yet connected to the Bank for actual transaction execution.

The validator is currently running on testnet, successfully receiving shreds and processing gossip, but replay does not yet execute BPF programs - native program stubs return hardcoded values.

## Immediate Focus: Functional Replay

Our first priority is getting the existing interpreter connected to the Bank so that transaction replay actually executes programs and modifies account state. This means:

- Wiring the BPF VM into `bank.executeBpfProgram()`
- Implementing account state modifications in `LoadedAccounts.commit()`
- Building out critical syscalls: `sol_log`, `sol_memcpy`, `sol_sha256`, `sol_invoke_signed` (CPI)
- Implementing real logic for native programs (System, Vote, Stake)

This follows the same path Sig took - they achieved a "faster sBPF interpreter" through clean architectural separation, not JIT compilation. Getting functional correctness first allows us to validate against Firedancer's conformance test suite before optimizing.

## Interpreter Optimization

Once replay is functional, we'll optimize the interpreter using Zig's strengths:

- Comptime dispatch tables for opcode handling
- Cache-friendly memory layouts
- SIMD where applicable (batch verification)
- Profile-guided optimization of hot paths

Sig demonstrated that a well-designed interpreter can achieve competitive performance. Our target is to match or exceed their interpreted execution speed.

## Future: JIT Compilation

The interpreter will eventually hit performance limits for compute-heavy programs. When profiling indicates VM execution is a bottleneck, we have two compelling paths:

### Option A: x86_64 JIT (rbpf-style)

Agave's rbpf library includes a proven x86_64 JIT compiler. This could be ported to Zig, giving us:
- 10-50x speedup over interpretation
- Battle-tested on mainnet
- Known compatibility characteristics

### Option B: RISC-V with Hybrid JIT

This is the more ambitious path, and frankly, the more interesting one.

RISC-V is gaining momentum in high-performance blockchain VMs. The DTVM project demonstrated 2x speedup over evmone for smart contracts, with sub-millisecond invocation times using hybrid lazy-JIT compilation. Key advantages:

- Register-based ISA aligns well with sBPF's register model
- Mature compiler toolchains (LLVM, GCC, Rust, Zig)
- 30-70% smaller compiled code than alternatives
- Native Zig support for RISC-V targets
- Future-proof: RISC-V is becoming the standard for secure execution environments

A RISC-V approach would involve compiling sBPF to RISC-V IR, then using LLVM or a custom backend for native code generation. This adds complexity but positions Vexor for long-term performance leadership.

The bpftime project showed that LLVM-based JIT for eBPF achieves 13-16x speedup on uprobe operations. Combining this with RISC-V's efficiency could yield a VM that outperforms both Firedancer and Agave.

## Why Not Build Something Entirely New

Protocol compatibility is non-negotiable. Every Solana validator must execute the same sBPF instructions with identical results. The ISA is defined, the syscall interfaces are defined, and conformance tests exist. Innovation happens in how we execute that spec, not in changing it.

We also benefit from Alpenglow on the horizon. When Solana transitions to Alpenglow consensus (expected early 2026), the execution layer remains sBPF-based. Our VM investment carries forward.

## Decision Framework

We'll make the JIT decision based on profiling data once replay is functional:

- If VM execution is <10% of slot processing time → interpreter is sufficient
- If VM execution is 10-30% → x86_64 JIT provides good ROI
- If VM execution is >30% or we want performance leadership → RISC-V hybrid JIT

## Conformance

Regardless of execution strategy, we must pass Firedancer's solana-conformance test suite:

| Test Suite | Coverage |
|------------|----------|
| elf_loader | 198 cases |
| vm_interp | 108,811 cases |
| vm_syscalls | 4,563 cases |
| instr_execute | 21,619 cases |
| txn_execute | 5,624 cases |

These tests ensure behavioral equivalence with Agave and Firedancer.

## Summary

**Now:** Connect interpreter to Bank, implement syscalls, achieve functional replay.

**Next:** Optimize interpreter using Zig's strengths, run conformance tests.

**Later:** Add JIT compilation when profiling justifies it - with RISC-V hybrid JIT as the ambitious target for performance leadership.

The path is clear: correctness first, then speed. But we're keeping the RISC-V door wide open.
