//! AF_XDP Stub Implementation
//!
//! Fallback when AF_XDP is disabled or unavailable.
//! Uses standard socket API instead.

const std = @import("std");
const packet = @import("packet.zig");

/// Stub XDP socket using regular UDP
pub const XdpSocket = struct {
    allocator: std.mem.Allocator,
    socket_fd: std.posix.socket_t,

    const Self = @This();

    pub const Umem = struct {};
    pub const Ring = struct {};

    pub fn init(allocator: std.mem.Allocator, interface: []const u8, queue_id: u32) !*Self {
        _ = interface;
        _ = queue_id;

        const socket = try allocator.create(Self);
        socket.* = .{
            .allocator = allocator,
            .socket_fd = try std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM,
                0,
            ),
        };
        return socket;
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.socket_fd);
        self.allocator.destroy(self);
    }

    pub fn recv(self: *Self, batch: *packet.PacketBatch) !usize {
        _ = self;
        _ = batch;
        // TODO: Standard recvmsg implementation
        return 0;
    }

    pub fn send(self: *Self, batch: *const packet.PacketBatch) !usize {
        _ = self;
        _ = batch;
        // TODO: Standard sendmsg implementation
        return 0;
    }
};

pub const XdpProgram = struct {
    pub fn load(bpf_path: []const u8) !XdpProgram {
        _ = bpf_path;
        return .{};
    }

    pub fn attach(self: *XdpProgram, ifindex: u32) !void {
        _ = self;
        _ = ifindex;
    }

    pub fn detach(self: *XdpProgram, ifindex: u32) !void {
        _ = self;
        _ = ifindex;
    }
};

pub fn isAvailable() bool {
    return false;
}

test "stub socket" {
    var socket = try XdpSocket.init(std.testing.allocator, "lo", 0);
    defer socket.deinit();
}

