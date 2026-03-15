//! Alpenglow Stub
//!
//! Placeholder when Alpenglow is disabled.

const std = @import("std");
const core = @import("../core/root.zig");

pub const Alpenglow = struct {
    pub fn init(allocator: std.mem.Allocator) !*Alpenglow {
        _ = allocator;
        return error.AlpenglowDisabled;
    }

    pub fn deinit(self: *Alpenglow) void {
        _ = self;
    }
};

pub const Votor = struct {};
pub const Rotor = struct {};
pub const BlsPublicKey = extern struct { data: [48]u8 };
pub const BlsSignature = extern struct { data: [96]u8 };
pub const BlsVote = struct {
    slot: core.Slot,
    hash: core.Hash,
    voter: core.Pubkey,
    signature: BlsSignature,
};
pub const BlsCertificate = struct {
    slot: core.Slot,
    aggregate_signature: BlsSignature,
    signers_bitfield: [128]u8,
    signer_count: u32,
};

