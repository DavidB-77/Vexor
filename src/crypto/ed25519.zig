//! Vexor Ed25519 Implementation
//!
//! SIMD-optimized Ed25519 signature verification.
//! Targets AVX2/AVX-512 on x86_64 and NEON on ARM.

const std = @import("std");
const core = @import("../core/root.zig");
const builtin = @import("builtin");

/// Verify a single Ed25519 signature
pub fn verify(sig: *const core.Signature, pubkey: *const core.Pubkey, message: []const u8) bool {
    // Use Zig's standard library Ed25519 implementation
    // In production, this would use our SIMD-optimized version
    const Ed25519 = std.crypto.sign.Ed25519;

    const signature = Ed25519.Signature.fromBytes(sig.data);
    const public_key = Ed25519.PublicKey.fromBytes(pubkey.data) catch return false;

    signature.verify(message, public_key) catch return false;
    return true;
}

/// Batch verify multiple signatures using SIMD
pub fn batchVerify(
    allocator: std.mem.Allocator,
    signatures: []const core.Signature,
    pubkeys: []const core.Pubkey,
    messages: []const []const u8,
) !BatchVerifyResult {
    if (signatures.len != pubkeys.len or signatures.len != messages.len) {
        return error.LengthMismatch;
    }

    const start = std.time.nanoTimestamp();

    var valid_count: usize = 0;
    const bitmap_size = (signatures.len + 7) / 8;
    const bitmap = try allocator.alloc(u8, bitmap_size);
    // Add errdefer to free bitmap on error after this point
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0);

    // TODO: SIMD batch verification using vector operations
    // For now, verify sequentially
    for (signatures, 0..) |*sig, i| {
        const valid = verify(sig, &pubkeys[i], messages[i]);
        if (valid) {
            valid_count += 1;
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
        }
    }

    const end = std.time.nanoTimestamp();

    return BatchVerifyResult{
        .valid_count = valid_count,
        .valid_bitmap = bitmap,
        .time_ns = @intCast(end - start),
    };
}

pub const BatchVerifyResult = struct {
    valid_count: usize,
    valid_bitmap: []u8,
    time_ns: u64,

    pub fn isValid(self: *const BatchVerifyResult, index: usize) bool {
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        if (byte_idx >= self.valid_bitmap.len) return false;
        return (self.valid_bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }
};

/// Sign a message (for testing/key generation)
/// secret_key is Solana format: [32-byte seed][32-byte public key]
/// Firedancer reference: fd_ed25519_sign takes private_key[32] and public_key[32] separately
/// Solana stores: bytes 0-31 = seed (private), bytes 32-63 = public key
pub fn sign(secret_key: [64]u8, message: []const u8) core.Signature {
    const Ed25519 = std.crypto.sign.Ed25519;
    // Solana format: [32-byte seed][32-byte public key]
    // Zig's Ed25519.SecretKey.bytes is [64]u8, matching Solana's format
    // Firedancer reference: fd_ed25519_sign takes private_key[32] and public_key[32] separately
    // But Zig's API uses the full 64-byte format
    
    // Solana format: [32-byte seed][32-byte public key]
    // Extract the seed (first 32 bytes) and create keypair from it
    // Note: We use KeyPair.create() which derives the public key from the seed
    // This avoids issues with fromSecretKey() which asserts/panics if public key doesn't match
    const seed: [32]u8 = secret_key[0..32].*;
    const key_pair = Ed25519.KeyPair.create(seed) catch {
        return core.Signature{ .data = [_]u8{0} ** 64 };
    };
    
    // Sign the message
    const sig = key_pair.sign(message, null) catch {
        return core.Signature{ .data = [_]u8{0} ** 64 };
    };
    
    // Ed25519 signature is 64 bytes - use .toBytes() method
    return core.Signature{ .data = sig.toBytes() };
}

/// Generate a new keypair
pub fn generateKeypair() struct { public: core.Pubkey, secret: [64]u8 } {
    const Ed25519 = std.crypto.sign.Ed25519;
    const key_pair = Ed25519.KeyPair.create(null);
    return .{
        .public = core.Pubkey{ .data = key_pair.public_key.toBytes() },
        .secret = key_pair.secret_key.toBytes(),
    };
}

/// Check if SIMD acceleration is available
pub fn simdAvailable() SimdCapability {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            const features = builtin.cpu.features;
            if (features.isEnabled(.avx512f)) break :blk .avx512;
            if (features.isEnabled(.avx2)) break :blk .avx2;
            if (features.isEnabled(.sse4_1)) break :blk .sse4;
            break :blk .none;
        },
        .aarch64 => .neon, // NEON is baseline for AArch64
        else => .none,
    };
}

pub const SimdCapability = enum {
    none,
    sse4,
    avx2,
    avx512,
    neon,

    pub fn vectorWidth(self: SimdCapability) usize {
        return switch (self) {
            .none => 1,
            .sse4 => 4,
            .avx2 => 8,
            .avx512 => 16,
            .neon => 4,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "ed25519 sign and verify" {
    const keypair = generateKeypair();
    const message = "Hello, Vexor!";

    const signature = sign(keypair.secret, message);
    const valid = verify(&signature, &keypair.public, message);

    try std.testing.expect(valid);
}

test "ed25519 verify invalid" {
    const keypair = generateKeypair();
    const message = "Hello, Vexor!";
    const wrong_message = "Wrong message";

    const signature = sign(keypair.secret, message);
    const valid = verify(&signature, &keypair.public, wrong_message);

    try std.testing.expect(!valid);
}

test "simd capability" {
    const cap = simdAvailable();
    // Just verify it returns something reasonable
    try std.testing.expect(cap.vectorWidth() >= 1);
}

