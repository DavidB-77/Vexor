//! Vexor Core Types
//!
//! Fundamental types used throughout the Vexor validator client.
//! These mirror Solana's core types but are optimized for Zig.

const std = @import("std");

/// A 32-byte public key (Ed25519)
pub const Pubkey = extern struct {
    data: [32]u8,

    pub const SIZE = 32;

    pub fn fromBytes(bytes: [32]u8) Pubkey {
        return .{ .data = bytes };
    }

    pub fn fromSlice(slice: []const u8) !Pubkey {
        if (slice.len != 32) return error.InvalidLength;
        var pubkey: Pubkey = undefined;
        @memcpy(&pubkey.data, slice);
        return pubkey;
    }

    pub fn toBase58(self: *const Pubkey, buf: []u8) []const u8 {
        return std.base58.Encoder.encode(buf, &self.data);
    }

    pub fn eql(self: *const Pubkey, other: *const Pubkey) bool {
        return std.mem.eql(u8, &self.data, &other.data);
    }

    pub fn isDefault(self: *const Pubkey) bool {
        return std.mem.allEqual(u8, &self.data, 0);
    }

    pub fn format(
        self: *const Pubkey,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var buf: [44]u8 = undefined;
        const encoded = self.toBase58(&buf);
        try writer.writeAll(encoded);
    }
};

/// A 64-byte Ed25519 signature
pub const Signature = extern struct {
    data: [64]u8,

    pub const SIZE = 64;

    pub fn fromBytes(bytes: [64]u8) Signature {
        return .{ .data = bytes };
    }

    pub fn fromSlice(slice: []const u8) !Signature {
        if (slice.len != 64) return error.InvalidLength;
        var sig: Signature = undefined;
        @memcpy(&sig.data, slice);
        return sig;
    }

    pub fn isDefault(self: *const Signature) bool {
        return std.mem.allEqual(u8, &self.data, 0);
    }

    pub fn verify(self: *const Signature, pubkey: *const Pubkey, message: []const u8) bool {
        _ = self;
        _ = pubkey;
        _ = message;
        // TODO: Implement Ed25519 verification
        return false;
    }
};

/// A 32-byte SHA-256 hash
pub const Hash = extern struct {
    data: [32]u8,

    pub const SIZE = 32;
    pub const ZERO = Hash{ .data = [_]u8{0} ** 32 };

    pub fn fromBytes(bytes: [32]u8) Hash {
        return .{ .data = bytes };
    }

    pub fn fromSlice(slice: []const u8) !Hash {
        if (slice.len != 32) return error.InvalidLength;
        var hash: Hash = undefined;
        @memcpy(&hash.data, slice);
        return hash;
    }

    pub fn eql(self: *const Hash, other: *const Hash) bool {
        return std.mem.eql(u8, &self.data, &other.data);
    }

    pub fn toBase58(self: *const Hash, buf: []u8) []const u8 {
        return std.base58.Encoder.encode(buf, &self.data);
    }

    pub fn format(
        self: *const Hash,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var buf: [44]u8 = undefined;
        const encoded = self.toBase58(&buf);
        try writer.writeAll(encoded);
    }
};

/// Slot number (monotonically increasing)
pub const Slot = u64;

/// Epoch number
pub const Epoch = u64;

/// Lamports (1 SOL = 1_000_000_000 lamports)
pub const Lamports = u64;

/// Unix timestamp in seconds
pub const UnixTimestamp = i64;

/// Transaction index within a slot
pub const TransactionIndex = u64;

/// Shred index within a slot
pub const ShredIndex = u32;

/// Constants for slots/epochs
pub const SLOTS_PER_EPOCH: u64 = 432_000; // ~2 days at 400ms slots
pub const TICKS_PER_SLOT: u64 = 64;
pub const TICKS_PER_SECOND: u64 = 160;
pub const MS_PER_TICK: u64 = 1000 / TICKS_PER_SECOND; // 6.25ms
pub const SLOT_DURATION_MS: u64 = 400;

/// Lamport constants
pub const LAMPORTS_PER_SOL: u64 = 1_000_000_000;

/// Account metadata
pub const AccountMeta = struct {
    pubkey: Pubkey,
    is_signer: bool,
    is_writable: bool,
};

/// A compiled instruction
pub const CompiledInstruction = struct {
    program_id_index: u8,
    accounts: []const u8,
    data: []const u8,
};

/// Transaction message header
pub const MessageHeader = extern struct {
    num_required_signatures: u8,
    num_readonly_signed_accounts: u8,
    num_readonly_unsigned_accounts: u8,
};

/// Vote state for consensus
pub const VoteState = struct {
    node_pubkey: Pubkey,
    authorized_voter: Pubkey,
    authorized_withdrawer: Pubkey,
    commission: u8,
    votes: std.ArrayList(Lockout),
    root_slot: ?Slot,
    epoch_credits: std.ArrayList(EpochCredits),
    last_timestamp: BlockTimestamp,

    pub const Lockout = struct {
        slot: Slot,
        confirmation_count: u32,
    };

    pub const EpochCredits = struct {
        epoch: Epoch,
        credits: u64,
        prev_credits: u64,
    };

    pub const BlockTimestamp = struct {
        slot: Slot,
        timestamp: UnixTimestamp,
    };
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "pubkey operations" {
    const bytes = [_]u8{1} ** 32;
    const pubkey = Pubkey.fromBytes(bytes);
    try std.testing.expect(!pubkey.isDefault());

    const default = Pubkey{ .data = [_]u8{0} ** 32 };
    try std.testing.expect(default.isDefault());
}

test "hash operations" {
    const hash1 = Hash.ZERO;
    const hash2 = Hash.ZERO;
    try std.testing.expect(hash1.eql(&hash2));
}

test "slot constants" {
    try std.testing.expectEqual(@as(u64, 432_000), SLOTS_PER_EPOCH);
    try std.testing.expectEqual(@as(u64, 400), SLOT_DURATION_MS);
}

test "lamport constants" {
    try std.testing.expectEqual(@as(u64, 1_000_000_000), LAMPORTS_PER_SOL);
}

