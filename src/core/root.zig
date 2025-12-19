//! Vexor Core Module
//! 
//! Core types, configuration, and memory management for the Vexor validator.

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const Allocator = @import("allocator.zig");
pub const types = @import("types.zig");
pub const keypair = @import("keypair.zig");
pub const affinity = @import("affinity.zig");

// Re-export common types
pub const Pubkey = types.Pubkey;
pub const Signature = types.Signature;
pub const Hash = types.Hash;
pub const Slot = types.Slot;
pub const Epoch = types.Epoch;
pub const Lamports = types.Lamports;
pub const Keypair = keypair.Keypair;
pub const loadKeypairFromFile = keypair.loadKeypairFromFile;

test {
    std.testing.refAllDecls(@This());
}

