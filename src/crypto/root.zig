//! Vexor Cryptography Module
//!
//! High-performance cryptographic operations:
//! - Ed25519 signature verification (SIMD optimized)
//! - SHA-256 hashing
//! - BLS signatures (for Alpenglow)
//! - GPU acceleration (optional, placeholder)
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────┐
//! │                    CRYPTO LAYER                         │
//! ├──────────────┬──────────────┬───────────────────────────┤
//! │   ED25519    │     BLS      │        GPU (opt)          │
//! │   ────────   │    ─────     │        ────────           │
//! │   SIMD      │   Aggregate   │     Batch verify          │
//! │   Batch     │   Threshold   │     CUDA/OpenCL           │
//! └──────────────┴──────────────┴───────────────────────────┘

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const ed25519 = @import("ed25519.zig");
pub const sha256 = @import("sha256.zig");
pub const hash_mod = @import("hash.zig");
pub const sigverify_mod = @import("sigverify.zig");
pub const bls = @import("bls.zig");

// GPU acceleration (optional)
pub const gpu = if (build_options.gpu_enabled)
    @import("gpu.zig")
else
    @import("gpu_stub.zig");

/// Verify an Ed25519 signature
pub fn verify(sig: *const core.Signature, pubkey: *const core.Pubkey, message: []const u8) bool {
    return ed25519.verify(sig, pubkey, message);
}

/// Batch verify multiple Ed25519 signatures
pub fn batchVerify(
    allocator: std.mem.Allocator,
    signatures: []const core.Signature,
    pubkeys: []const core.Pubkey,
    messages: []const []const u8,
) !BatchVerifyResult {
    // Use GPU if available and batch is large enough
    if (build_options.gpu_enabled and signatures.len >= gpu.MIN_BATCH_FOR_GPU) {
        if (try gpu.isAvailable()) {
            return gpu.batchVerify(allocator, signatures, pubkeys, messages);
        }
    }

    // Fall back to SIMD CPU implementation
    return ed25519.batchVerify(allocator, signatures, pubkeys, messages);
}

pub const BatchVerifyResult = struct {
    /// Number of valid signatures
    valid_count: usize,
    /// Bitmap of valid signatures (bit set = valid)
    valid_bitmap: []u8,
    /// Total verification time in nanoseconds
    time_ns: u64,
};

/// Hash data using SHA-256
pub fn hash(data: []const u8) core.Hash {
    return hash_mod.Sha256.hash(data);
}

/// Hash multiple pieces of data
pub fn hashMulti(data: []const []const u8) core.Hash {
    return hash_mod.Sha256.hashMulti(data);
}

// Re-export common types
pub const SigVerifier = sigverify_mod.SigVerifier;
pub const SigVerifyPipeline = sigverify_mod.SigVerifyPipeline;
pub const VerifyBatch = sigverify_mod.VerifyBatch;
pub const Sha256 = hash_mod.Sha256;
pub const Blake3 = hash_mod.Blake3;
pub const MerkleTree = hash_mod.MerkleTree;

test {
    std.testing.refAllDecls(@This());
}

