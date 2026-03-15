//! Vexor Alpenglow Consensus (Experimental)
//!
//! Implementation of Solana's next-generation consensus protocol.
//! Features:
//! - Votor: Efficient voting and finalization
//! - Rotor: Optimized data dissemination
//! - BLS signatures: Aggregatable signatures for lightweight certificates
//! - Target: 100-150ms finality
//!
//! NOTE: This is experimental and will be enabled when Alpenglow goes live.

const std = @import("std");
const core = @import("../core/root.zig");

/// Alpenglow consensus engine
pub const Alpenglow = struct {
    allocator: std.mem.Allocator,
    votor: Votor,
    rotor: Rotor,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const engine = try allocator.create(Self);
        engine.* = .{
            .allocator = allocator,
            .votor = try Votor.init(allocator),
            .rotor = try Rotor.init(allocator),
        };
        return engine;
    }

    pub fn deinit(self: *Self) void {
        self.votor.deinit();
        self.rotor.deinit();
        self.allocator.destroy(self);
    }
};

/// Votor: Voting and finalization engine
pub const Votor = struct {
    allocator: std.mem.Allocator,
    /// Current epoch's BLS public key aggregate
    aggregate_pubkey: ?BlsPublicKey,
    /// Votes collected for current slot
    pending_votes: std.ArrayList(BlsVote),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .aggregate_pubkey = null,
            .pending_votes = std.ArrayList(BlsVote).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_votes.deinit();
    }

    /// Add a vote
    pub fn addVote(self: *Self, vote: BlsVote) !void {
        try self.pending_votes.append(vote);
    }

    /// Aggregate votes into a certificate
    pub fn aggregateVotes(self: *Self) !?BlsCertificate {
        if (self.pending_votes.items.len == 0) return null;

        // TODO: BLS signature aggregation
        var cert = BlsCertificate{
            .slot = self.pending_votes.items[0].slot,
            .aggregate_signature = BlsSignature{ .data = [_]u8{0} ** 96 },
            .signers_bitfield = [_]u8{0} ** 128,
            .signer_count = @intCast(self.pending_votes.items.len),
        };

        // Set bits for signers
        for (self.pending_votes.items, 0..) |_, i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            if (byte_idx < cert.signers_bitfield.len) {
                cert.signers_bitfield[byte_idx] |= @as(u8, 1) << bit_idx;
            }
        }

        self.pending_votes.clearRetainingCapacity();
        return cert;
    }
};

/// Rotor: Data dissemination layer
pub const Rotor = struct {
    allocator: std.mem.Allocator,
    /// Current turbine tree
    turbine_tree: ?TurbineTree,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .turbine_tree = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.turbine_tree) |*tree| {
            tree.deinit();
        }
    }
};

/// BLS public key (48 bytes compressed)
pub const BlsPublicKey = extern struct {
    data: [48]u8,

    pub fn isDefault(self: *const BlsPublicKey) bool {
        return std.mem.allEqual(u8, &self.data, 0);
    }
};

/// BLS signature (96 bytes)
pub const BlsSignature = extern struct {
    data: [96]u8,

    pub fn isDefault(self: *const BlsSignature) bool {
        return std.mem.allEqual(u8, &self.data, 0);
    }
};

/// Vote with BLS signature
pub const BlsVote = struct {
    slot: core.Slot,
    hash: core.Hash,
    voter: core.Pubkey,
    signature: BlsSignature,
};

/// Aggregated BLS certificate
pub const BlsCertificate = struct {
    slot: core.Slot,
    aggregate_signature: BlsSignature,
    /// Bitfield indicating which validators signed
    signers_bitfield: [128]u8, // Up to 1024 validators
    signer_count: u32,
};

/// Turbine tree for efficient data propagation
pub const TurbineTree = struct {
    allocator: std.mem.Allocator,
    leader: core.Pubkey,
    layers: std.ArrayList([]core.Pubkey),
    fanout: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, leader: core.Pubkey, fanout: u32) !Self {
        return .{
            .allocator = allocator,
            .leader = leader,
            .layers = std.ArrayList([]core.Pubkey).init(allocator),
            .fanout = fanout,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.layers.items) |layer| {
            self.allocator.free(layer);
        }
        self.layers.deinit();
    }

    /// Build tree from validator set
    pub fn build(self: *Self, validators: []const core.Pubkey) !void {
        _ = self;
        _ = validators;
        // TODO: Construct turbine tree based on stake
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "votor init" {
    var votor = try Votor.init(std.testing.allocator);
    defer votor.deinit();

    try std.testing.expect(votor.aggregate_pubkey == null);
}

test "bls vote aggregation" {
    var votor = try Votor.init(std.testing.allocator);
    defer votor.deinit();

    // Add some votes
    try votor.addVote(.{
        .slot = 100,
        .hash = core.Hash.ZERO,
        .voter = core.Pubkey{ .data = [_]u8{1} ** 32 },
        .signature = BlsSignature{ .data = [_]u8{0} ** 96 },
    });

    const cert = try votor.aggregateVotes();
    try std.testing.expect(cert != null);
    try std.testing.expectEqual(@as(u32, 1), cert.?.signer_count);
}

