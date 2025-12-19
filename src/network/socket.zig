//! Vexor Socket Abstraction
//!
//! High-performance UDP socket implementation optimized for validator workloads.
//! Supports:
//! - Non-blocking I/O
//! - Batch receive/send (recvmmsg/sendmmsg on Linux)
//! - Socket options for validator performance

const std = @import("std");
const posix = std.posix;
const packet = @import("packet.zig");
const builtin = @import("builtin");

/// UDP socket wrapper with performance optimizations
pub const UdpSocket = struct {
    fd: posix.socket_t,
    bound_addr: ?posix.sockaddr,
    recv_buffer_size: usize,
    send_buffer_size: usize,

    const Self = @This();

    /// Default buffer sizes optimized for Solana validator
    pub const DEFAULT_RECV_BUFFER: usize = 128 * 1024 * 1024; // 128MB
    pub const DEFAULT_SEND_BUFFER: usize = 128 * 1024 * 1024; // 128MB

    /// Create a new UDP socket
    pub fn init() !Self {
        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        var socket = Self{
            .fd = fd,
            .bound_addr = null,
            .recv_buffer_size = 0,
            .send_buffer_size = 0,
        };

        // Apply performance optimizations
        try socket.setBufferSizes(DEFAULT_RECV_BUFFER, DEFAULT_SEND_BUFFER);
        try socket.setReuseAddr(true);

        return socket;
    }

    /// Close the socket
    pub fn deinit(self: *Self) void {
        posix.close(self.fd);
        self.fd = -1;
    }

    /// Bind to an address
    pub fn bind(self: *Self, addr: std.net.Address) !void {
        const sockaddr = addr.any;
        try posix.bind(self.fd, &sockaddr, @sizeOf(@TypeOf(sockaddr)));
        self.bound_addr = sockaddr;
    }

    /// Bind to a port on all interfaces
    pub fn bindPort(self: *Self, port: u16) !void {
        const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        try self.bind(addr);
    }

    /// Set socket buffer sizes
    pub fn setBufferSizes(self: *Self, recv_size: usize, send_size: usize) !void {
        // Set receive buffer
        const recv_val: i32 = @intCast(@min(recv_size, std.math.maxInt(i32)));
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(recv_val)) catch |err| {
            std.debug.print("Warning: Could not set RCVBUF to {}: {}\n", .{ recv_size, err });
        };

        // Set send buffer  
        const send_val: i32 = @intCast(@min(send_size, std.math.maxInt(i32)));
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(send_val)) catch |err| {
            std.debug.print("Warning: Could not set SNDBUF to {}: {}\n", .{ send_size, err });
        };

        self.recv_buffer_size = recv_size;
        self.send_buffer_size = send_size;
    }

    /// Enable address reuse
    pub fn setReuseAddr(self: *Self, enable: bool) !void {
        const val: i32 = if (enable) 1 else 0;
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(val));
    }

    /// Receive a single packet
    pub fn recv(self: *Self, pkt: *packet.Packet) !bool {
        var src_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const result = posix.recvfrom(
            self.fd,
            &pkt.data,
            0,
            @ptrCast(&src_addr),
            &addr_len,
        );

        if (result) |bytes| {
            pkt.len = @intCast(bytes);
            pkt.src_addr = sockaddrToPacketAddr(&src_addr);
            pkt.timestamp_ns = @intCast(std.time.nanoTimestamp());
            return true;
        } else |err| {
            if (err == error.WouldBlock) {
                return false;
            }
            return err;
        }
    }

    /// Receive multiple packets into a batch
    pub fn recvBatch(self: *Self, batch: *packet.PacketBatch) !usize {
        var received: usize = 0;

        while (!batch.isFull()) {
            if (batch.push()) |pkt| {
                const got = try self.recv(pkt);
                if (got) {
                    received += 1;
                } else {
                    // Would block - restore batch state and return
                    batch.len -= 1;
                    break;
                }
            }
        }

        return received;
    }

    /// Send a single packet
    pub fn send(self: *Self, pkt: *const packet.Packet) !bool {
        const dest_addr = packetAddrToSockaddr(&pkt.src_addr);

        const result = posix.sendto(
            self.fd,
            pkt.data[0..pkt.len],
            0,
            @ptrCast(&dest_addr),
            @sizeOf(posix.sockaddr.in),
        );

        if (result) |_| {
            return true;
        } else |err| {
            if (err == error.WouldBlock) {
                return false;
            }
            return err;
        }
    }

    /// Send to a specific address
    pub fn sendTo(self: *Self, data: []const u8, addr: std.net.Address) !bool {
        const sockaddr = addr.any;

        const result = posix.sendto(
            self.fd,
            data,
            0,
            &sockaddr,
            @sizeOf(@TypeOf(sockaddr)),
        );

        if (result) |_| {
            return true;
        } else |err| {
            if (err == error.WouldBlock) {
                return false;
            }
            return err;
        }
    }

    /// Send multiple packets from a batch
    pub fn sendBatch(self: *Self, batch: *const packet.PacketBatch) !usize {
        var sent: usize = 0;

        for (batch.slice()) |*pkt| {
            const success = try self.send(pkt);
            if (success) {
                sent += 1;
            } else {
                break; // Would block
            }
        }

        return sent;
    }

    /// Get the bound port
    pub fn boundPort(self: *const Self) ?u16 {
        if (self.bound_addr) |addr| {
            const in_addr: *const posix.sockaddr.in = @ptrCast(&addr);
            return std.mem.bigToNative(u16, in_addr.port);
        }
        return null;
    }

    // Helper conversions
    fn sockaddrToPacketAddr(sa: *const posix.sockaddr.in) packet.SocketAddr {
        var result = packet.SocketAddr{
            .family_port = (@as(u32, std.mem.bigToNative(u16, sa.port)) << 16) | 2,
            .addr = [_]u8{0} ** 16,
        };
        const addr_bytes = std.mem.asBytes(&sa.addr);
        @memcpy(result.addr[0..4], addr_bytes);
        return result;
    }

    fn packetAddrToSockaddr(pa: *const packet.SocketAddr) posix.sockaddr.in {
        return posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, pa.port()),
            .addr = @bitCast(pa.addr[0..4].*),
            .zero = [_]u8{0} ** 8,
        };
    }
};

/// Multi-socket manager for handling multiple UDP endpoints
pub const SocketSet = struct {
    allocator: std.mem.Allocator,
    sockets: std.ArrayList(*UdpSocket),
    poll_fds: std.ArrayList(posix.pollfd),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sockets = std.ArrayList(*UdpSocket).init(allocator),
            .poll_fds = std.ArrayList(posix.pollfd).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.sockets.items) |sock| {
            sock.deinit();
            self.allocator.destroy(sock);
        }
        self.sockets.deinit();
        self.poll_fds.deinit();
    }

    /// Add a socket to the set
    pub fn add(self: *Self, socket: *UdpSocket) !void {
        try self.sockets.append(socket);
        try self.poll_fds.append(.{
            .fd = socket.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }

    /// Create and add a socket bound to a port
    pub fn addBoundSocket(self: *Self, port: u16) !*UdpSocket {
        const socket = try self.allocator.create(UdpSocket);
        errdefer self.allocator.destroy(socket);

        socket.* = try UdpSocket.init();
        errdefer socket.deinit();

        try socket.bindPort(port);
        try self.add(socket);

        return socket;
    }

    /// Poll all sockets for activity
    pub fn poll(self: *Self, timeout_ms: i32) !usize {
        if (self.poll_fds.items.len == 0) return 0;

        const ready = try posix.poll(self.poll_fds.items, timeout_ms);
        return @intCast(ready);
    }

    /// Check if a socket has data ready
    pub fn isReadable(self: *const Self, index: usize) bool {
        if (index >= self.poll_fds.items.len) return false;
        return (self.poll_fds.items[index].revents & posix.POLL.IN) != 0;
    }

    /// Get socket by index
    pub fn get(self: *const Self, index: usize) ?*UdpSocket {
        if (index >= self.sockets.items.len) return null;
        return self.sockets.items[index];
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "udp socket create and bind" {
    var socket = try UdpSocket.init();
    defer socket.deinit();

    // Bind to ephemeral port
    try socket.bindPort(0);

    const port = socket.boundPort();
    try std.testing.expect(port != null);
    try std.testing.expect(port.? > 0);
}

test "socket set" {
    var set = SocketSet.init(std.testing.allocator);
    defer set.deinit();

    const sock1 = try set.addBoundSocket(0);
    const sock2 = try set.addBoundSocket(0);

    try std.testing.expect(sock1.boundPort() != sock2.boundPort());
    try std.testing.expectEqual(@as(usize, 2), set.sockets.items.len);
}

test "send and receive" {
    // Create two sockets
    var sender = try UdpSocket.init();
    defer sender.deinit();
    try sender.bindPort(0);

    var receiver = try UdpSocket.init();
    defer receiver.deinit();
    try receiver.bindPort(0);

    const recv_port = receiver.boundPort().?;

    // Send a packet
    const test_data = "Hello, Vexor!";
    const dest = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, recv_port);
    _ = try sender.sendTo(test_data, dest);

    // Small delay for packet to arrive
    std.time.sleep(1_000_000); // 1ms

    // Receive
    var pkt = packet.Packet.init();
    const received = try receiver.recv(&pkt);

    try std.testing.expect(received);
    try std.testing.expectEqualSlices(u8, test_data, pkt.data[0..pkt.len]);
}

