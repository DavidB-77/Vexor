/// Shred variant constant definitions
pub const ShredVariant = enum(u8) {
    Legacy = 0x00,
    MerkleV2 = 0x10,
    AlpenglowV3 = 0x50, // V3 Shim
    _,
};

/// Stats for Protocol Heatmap
pub const ProtocolStats = struct {
    legacy_count: u64 = 0,
    v2_count: u64 = 0,
    v3_count: u64 = 0,

    pub fn update(self: *ProtocolStats, variant: u8) void {
        if (variant < 0x10) {
            self.legacy_count += 1;
        } else if (variant < 0x50) {
            self.v2_count += 1;
        } else {
            self.v3_count += 1;
        }
    }

    pub fn printHeatmap(self: ProtocolStats) void {
        const total = self.legacy_count + self.v2_count + self.v3_count;
        if (total == 0) return;

        const std = @import("std");
        std.debug.print("\n=== Protocol Heatmap ===\n", .{});
        std.debug.print("Legacy: {d} ({d:.1}%)\n", .{ self.legacy_count, @as(f32, @floatFromInt(self.legacy_count)) / @as(f32, @floatFromInt(total)) * 100.0 });
        std.debug.print("V2    : {d} ({d:.1}%)\n", .{ self.v2_count, @as(f32, @floatFromInt(self.v2_count)) / @as(f32, @floatFromInt(total)) * 100.0 });
        std.debug.print("V3    : {d} ({d:.1}%)\n", .{ self.v3_count, @as(f32, @floatFromInt(self.v3_count)) / @as(f32, @floatFromInt(total)) * 100.0 });
        std.debug.print("========================\n", .{});
    }

    pub fn formatPrometheusMetrics(self: *ProtocolStats, buf: []u8) ![]const u8 {
        const std = @import("std");
        return std.fmt.bufPrint(buf,
            \\# HELP solana_shred_count Total number of shreds received by version
            \\# TYPE solana_shred_count counter
            \\solana_shred_count{{version="legacy"}} {d}
            \\solana_shred_count{{version="merkle_v2"}} {d}
            \\solana_shred_count{{version="alpenglow_v3"}} {d}
        , .{ self.legacy_count, self.v2_count, self.v3_count });
    }
};

/// Data shred content with V3 Shim logic
pub const DataShred = extern struct {
    signature: [64]u8 align(64),
    variant: u8,

    pub fn getPayloadOffset(self: *const DataShred) u16 {
        return switch (self.variant) {
            0x00...0x0F => 0x40, // Legacy
            0x10...0x4F => 0x56, // V2
            else => 0x58, // V3 Alpenglow Shift
        };
    }

    /// Executes the signature check based on the protocol version.
    pub fn verify(self: *const DataShred, leader_pubkey: [32]u8) !bool {
        const std = @import("std");
        const crypto = std.crypto;

        const sig = crypto.sign.Ed25519.Signature.fromBytes(self.signature);
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(leader_pubkey) catch return false;

        const payload = @as([*]const u8, @ptrCast(self));

        return switch (self.variant) {
            // Legacy: Signature covers the entire shred minus the first 64 bytes.
            0x00...0x0F => {
                const msg = payload[64..1228];
                sig.verify(msg, pk) catch return false;
                return true;
            },
            // Merkle V2/V3: Signature covers the Merkle Root, NOT the payload.
            0x10...0x5F => {
                // In Merkle, the signed data is the 20-byte root at offset 0x41.
                // 0x41 is decimal 65. Range [65..85] for 20 bytes.
                const root = payload[65..85];
                sig.verify(root, pk) catch return false;
                return true;
            },
            else => return error.UnsupportedVariant,
        };
    }
};
