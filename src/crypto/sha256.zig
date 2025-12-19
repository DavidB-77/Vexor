//! Vexor SHA-256 Implementation
//!
//! Hardware-accelerated SHA-256 hashing using SHA-NI when available.

const std = @import("std");
const core = @import("../core/root.zig");

/// Hash data using SHA-256
pub fn hash(data: []const u8) core.Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    return core.Hash{ .data = hasher.finalResult() };
}

/// Hash multiple pieces of data
pub fn hashMulti(data: []const []const u8) core.Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (data) |chunk| {
        hasher.update(chunk);
    }
    return core.Hash{ .data = hasher.finalResult() };
}

/// Incremental hasher for large data
pub const Hasher = struct {
    inner: std.crypto.hash.sha2.Sha256,

    const Self = @This();

    pub fn init() Self {
        return .{
            .inner = std.crypto.hash.sha2.Sha256.init(.{}),
        };
    }

    pub fn update(self: *Self, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Self) core.Hash {
        return core.Hash{ .data = self.inner.finalResult() };
    }

    pub fn reset(self: *Self) void {
        self.inner = std.crypto.hash.sha2.Sha256.init(.{});
    }
};

/// Hash data using SHA-512 (for some internal operations)
pub fn hash512(data: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "sha256 hash" {
    const data = "Hello, Vexor!";
    const h = hash(data);

    try std.testing.expect(!h.eql(&core.Hash.ZERO));
}

test "sha256 hash consistency" {
    const data = "test data";
    const h1 = hash(data);
    const h2 = hash(data);

    try std.testing.expect(h1.eql(&h2));
}

test "sha256 incremental" {
    var hasher = Hasher.init();
    hasher.update("Hello, ");
    hasher.update("Vexor!");
    const h1 = hasher.final();

    const h2 = hash("Hello, Vexor!");

    try std.testing.expect(h1.eql(&h2));
}

