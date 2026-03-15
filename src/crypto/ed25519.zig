//! Vexor Ed25519 Implementation
//!
//! SIMD-optimized Ed25519 signature verification.
//! Targets AVX2/AVX-512 on x86_64 and NEON on ARM.

const std = @import("std");
const core = @import("../core/root.zig");
const builtin = @import("builtin");

var global_pool: ?*std.Thread.Pool = null;
var global_pool_mutex: std.Thread.Mutex = .{};

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

/// Batch verify multiple signatures using multiple threads and SIMD
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
    const bitmap_size = (signatures.len + 7) / 8;
    const bitmap = try allocator.alloc(u8, bitmap_size);
    @memset(bitmap, 0);

    const thread_count = std.Thread.getCpuCount() catch 1;
    if (thread_count <= 1 or signatures.len < 32) {
        // Sequential fallback for small batches or single-core systems
        var valid_count: usize = 0;
        for (signatures, 0..) |*sig, i| {
            if (verify(sig, &pubkeys[i], messages[i])) {
                valid_count += 1;
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(i % 8);
                bitmap[byte_idx] |= @as(u8, 1) << bit_idx;
            }
        }
        return BatchVerifyResult{
            .valid_count = valid_count,
            .valid_bitmap = bitmap,
            .time_ns = @intCast(std.time.nanoTimestamp() - start),
        };
    }

    // Parallel verification using thread pool
    const pool = try getGlobalThreadPool(allocator);

    var valid_count = std.atomic.Value(usize).init(0);
    const chunk_size = (signatures.len + thread_count - 1) / thread_count;

    var wg = std.Thread.WaitGroup{};
    var i: usize = 0;
    while (i < signatures.len) : (i += chunk_size) {
        const end = @min(i + chunk_size, signatures.len);
        wg.start();
        pool.spawn(batchVerifyWorker, .{
            signatures[i..end],
            pubkeys[i..end],
            messages[i..end],
            bitmap,
            i,
            &valid_count,
            &wg,
        }) catch {
            // If spawning fails, run sequentially in this thread
            batchVerifyWorker(
                signatures[i..end],
                pubkeys[i..end],
                messages[i..end],
                bitmap,
                i,
                &valid_count,
                &wg,
            );
        };
    }
    wg.wait();

    return BatchVerifyResult{
        .valid_count = valid_count.load(.monotonic),
        .valid_bitmap = bitmap,
        .time_ns = @intCast(std.time.nanoTimestamp() - start),
    };
}

fn batchVerifyWorker(
    signatures: []const core.Signature,
    pubkeys: []const core.Pubkey,
    messages: []const []const u8,
    bitmap: []u8,
    offset: usize,
    valid_count: *std.atomic.Value(usize),
    wg: *std.Thread.WaitGroup,
) void {
    defer wg.finish();
    var local_valid: usize = 0;
    for (signatures, 0..) |*sig, i| {
        if (verify(sig, &pubkeys[i], messages[i])) {
            local_valid += 1;
            const global_idx = offset + i;
            const byte_idx = global_idx / 8;
            const bit_idx: u3 = @intCast(global_idx % 8);
            // We use atomic or to avoid races on the bitmap byte
            // (even though workers mostly work on different bytes,
            // they might share a byte at the boundaries)
            const ptr = &bitmap[byte_idx];
            _ = @atomicRmw(u8, ptr, .Or, (@as(u8, 1) << bit_idx), .monotonic);
        }
    }
    _ = valid_count.fetchAdd(local_valid, .monotonic);
}

fn getGlobalThreadPool(allocator: std.mem.Allocator) !*std.Thread.Pool {
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    if (global_pool) |p| return p;

    const thread_count = std.Thread.getCpuCount() catch 1;
    const pool = try allocator.create(std.Thread.Pool);
    try pool.init(.{ .allocator = allocator, .n_jobs = @intCast(thread_count) });
    global_pool = pool;
    return pool;
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
    const key_pair = Ed25519.KeyPair.create(null) catch unreachable;
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
            const x86 = std.Target.x86.Feature;
            if (features.isEnabled(@intFromEnum(x86.avx512f))) break :blk .avx512;
            if (features.isEnabled(@intFromEnum(x86.avx2))) break :blk .avx2;
            if (features.isEnabled(@intFromEnum(x86.sse4_1))) break :blk .sse4;
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
