//! AF_XDP Packet Processor
//! High-performance packet processing pipeline for Solana network traffic.
//!
//! Processing pipeline:
//! ┌─────────────────────────────────────────────────────────────┐
//! │  NIC → XDP Socket → Parser → Router → Handler → Response   │
//! └─────────────────────────────────────────────────────────────┘
//!
//! Packet types handled:
//! - UDP/QUIC: Transaction submission, gossip, turbine
//! - TCP: RPC (fallback)

const std = @import("std");
const Allocator = std.mem.Allocator;
const socket = @import("socket.zig");
const XdpSocket = socket.XdpSocket;
const XdpConfig = socket.XdpConfig;
const Packet = socket.Packet;

/// Ethernet header
pub const EthHeader = extern struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,
};

/// IPv4 header
pub const Ipv4Header = extern struct {
    version_ihl: u8,
    dscp_ecn: u8,
    total_length: u16,
    identification: u16,
    flags_frag_offset: u16,
    ttl: u8,
    protocol: u8,
    header_checksum: u16,
    src_addr: u32,
    dst_addr: u32,

    pub fn headerLength(self: *const Ipv4Header) usize {
        return @as(usize, self.version_ihl & 0x0f) * 4;
    }
};

/// UDP header
pub const UdpHeader = extern struct {
    src_port: u16,
    dst_port: u16,
    length: u16,
    checksum: u16,
};

/// Protocol numbers
pub const IPPROTO_UDP: u8 = 17;
pub const IPPROTO_TCP: u8 = 6;

/// Ethernet types
pub const ETH_P_IP: u16 = 0x0800;
pub const ETH_P_IPV6: u16 = 0x86DD;

/// Solana port ranges
pub const SOLANA_TPU_PORT: u16 = 8000;
pub const SOLANA_TPU_QUIC_PORT: u16 = 8001;
pub const SOLANA_GOSSIP_PORT: u16 = 8001;
pub const SOLANA_TURBINE_PORT: u16 = 8002;
pub const SOLANA_RPC_PORT: u16 = 8899;

/// Parsed packet
pub const ParsedPacket = struct {
    /// Source IP
    src_ip: u32,
    /// Destination IP
    dst_ip: u32,
    /// Source port
    src_port: u16,
    /// Destination port
    dst_port: u16,
    /// Protocol (UDP/TCP)
    protocol: u8,
    /// Payload data
    payload: []const u8,
    /// Packet type classification
    packet_type: PacketType,
};

/// Packet type classification
pub const PacketType = enum {
    gossip,
    turbine_shred,
    tpu_transaction,
    tpu_quic,
    rpc,
    repair,
    vote,
    unknown,
};

/// Packet handler callback
pub const PacketHandler = *const fn (*ParsedPacket) void;

/// Processor configuration
pub const ProcessorConfig = struct {
    /// XDP socket configuration
    xdp_config: XdpConfig = .{},
    /// Batch size for packet processing
    batch_size: usize = 64,
    /// Number of worker threads
    worker_threads: usize = 4,
    /// Enable packet statistics
    enable_stats: bool = true,
};

/// Packet statistics
pub const PacketStats = struct {
    packets_received: u64 = 0,
    packets_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    parse_errors: u64 = 0,
    dropped_packets: u64 = 0,
    gossip_packets: u64 = 0,
    turbine_packets: u64 = 0,
    tpu_packets: u64 = 0,
    vote_packets: u64 = 0,
};

/// Packet processor
pub const PacketProcessor = struct {
    /// XDP socket
    xdp_socket: ?XdpSocket,
    /// Configuration
    config: ProcessorConfig,
    /// Statistics
    stats: PacketStats,
    /// Packet handlers by type
    handlers: std.EnumArray(PacketType, ?PacketHandler),
    /// Worker threads
    workers: std.ArrayList(std.Thread),
    /// Shutdown flag
    shutdown: std.atomic.Value(bool),
    /// Allocator
    allocator: Allocator,
    /// Is using AF_XDP (vs fallback)
    using_xdp: bool,
    /// Fallback UDP socket
    fallback_socket: ?std.posix.socket_t,

    pub fn init(allocator: Allocator, config: ProcessorConfig) !PacketProcessor {
        var processor = PacketProcessor{
            .xdp_socket = null,
            .config = config,
            .stats = .{},
            .handlers = std.EnumArray(PacketType, ?PacketHandler).initFill(null),
            .workers = std.ArrayList(std.Thread).init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .using_xdp = false,
            .fallback_socket = null,
        };

        // Try to initialize AF_XDP
        processor.xdp_socket = XdpSocket.init(allocator, config.xdp_config) catch |err| blk: {
            std.log.warn("AF_XDP unavailable ({s}), using standard UDP socket", .{@errorName(err)});
            break :blk null;
        };

        processor.using_xdp = processor.xdp_socket != null;

        // If no XDP, set up fallback
        if (!processor.using_xdp) {
            processor.fallback_socket = try setupFallbackSocket(config.xdp_config.interface);
        }

        return processor;
    }

    pub fn deinit(self: *PacketProcessor) void {
        self.stop();

        if (self.xdp_socket) |*sock| {
            sock.deinit();
        }

        if (self.fallback_socket) |sock| {
            std.posix.close(sock);
        }

        self.workers.deinit();
    }

    /// Register a handler for a packet type
    pub fn registerHandler(self: *PacketProcessor, packet_type: PacketType, handler: PacketHandler) void {
        self.handlers.set(packet_type, handler);
    }

    /// Start processing
    pub fn start(self: *PacketProcessor) !void {
        // Start worker threads
        for (0..self.config.worker_threads) |_| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{self});
            try self.workers.append(thread);
        }

        std.log.info("Packet processor started with {d} workers (XDP: {s})", .{
            self.config.worker_threads,
            if (self.using_xdp) "enabled" else "disabled",
        });
    }

    /// Stop processing
    pub fn stop(self: *PacketProcessor) void {
        self.shutdown.store(true, .release);

        for (self.workers.items) |thread| {
            thread.join();
        }
        self.workers.clearRetainingCapacity();
    }

    fn workerLoop(self: *PacketProcessor) void {
        var packets: [64]Packet = undefined;

        while (!self.shutdown.load(.acquire)) {
            const count = self.receivePackets(&packets) catch |err| {
                std.log.warn("Receive error: {s}", .{@errorName(err)});
                continue;
            };

            for (packets[0..count]) |*pkt| {
                self.processPacket(pkt);
            }
        }
    }

    fn receivePackets(self: *PacketProcessor, packets: []Packet) !usize {
        if (self.xdp_socket) |*xdp| {
            // Poll first
            if (try xdp.poll(100)) {
                return try xdp.recv(packets);
            }
            return 0;
        }

        if (self.fallback_socket) |sock| {
            // Standard recv
            return receiveFallback(sock, packets);
        }

        return 0;
    }

    fn processPacket(self: *PacketProcessor, pkt: *Packet) void {
        // Update stats
        self.stats.packets_received += 1;
        self.stats.bytes_received += pkt.len;

        // Parse packet
        var parsed = self.parsePacket(pkt) orelse {
            self.stats.parse_errors += 1;
            return;
        };

        // Update type-specific stats
        switch (parsed.packet_type) {
            .gossip => self.stats.gossip_packets += 1,
            .turbine_shred => self.stats.turbine_packets += 1,
            .tpu_transaction, .tpu_quic => self.stats.tpu_packets += 1,
            .vote => self.stats.vote_packets += 1,
            else => {},
        }

        // Call handler
        if (self.handlers.get(parsed.packet_type)) |handler| {
            handler(&parsed);
        }
    }

    fn parsePacket(self: *PacketProcessor, pkt: *Packet) ?ParsedPacket {
        _ = self;

        if (pkt.len < @sizeOf(EthHeader)) return null;

        const eth: *const EthHeader = @ptrCast(@alignCast(pkt.data.ptr));

        // Check for IPv4
        if (std.mem.bigToNative(u16, eth.ethertype) != ETH_P_IP) {
            return null;
        }

        var offset: usize = @sizeOf(EthHeader);
        if (pkt.len < offset + @sizeOf(Ipv4Header)) return null;

        const ip: *const Ipv4Header = @ptrCast(@alignCast(pkt.data.ptr + offset));
        offset += ip.headerLength();

        var parsed = ParsedPacket{
            .src_ip = ip.src_addr,
            .dst_ip = ip.dst_addr,
            .src_port = 0,
            .dst_port = 0,
            .protocol = ip.protocol,
            .payload = &[_]u8{},
            .packet_type = .unknown,
        };

        // Parse transport layer
        if (ip.protocol == IPPROTO_UDP) {
            if (pkt.len < offset + @sizeOf(UdpHeader)) return null;

            const udp: *const UdpHeader = @ptrCast(@alignCast(pkt.data.ptr + offset));
            offset += @sizeOf(UdpHeader);

            parsed.src_port = std.mem.bigToNative(u16, udp.src_port);
            parsed.dst_port = std.mem.bigToNative(u16, udp.dst_port);
            parsed.payload = pkt.data[offset..];

            // Classify by port
            parsed.packet_type = classifyByPort(parsed.dst_port);
        }

        return parsed;
    }

    /// Send packets
    pub fn sendPackets(self: *PacketProcessor, packets: []const Packet) !usize {
        var sent: usize = 0;

        if (self.xdp_socket) |*xdp| {
            sent = try xdp.send(packets);
        } else if (self.fallback_socket) |sock| {
            sent = try sendFallback(sock, packets);
        }

        self.stats.packets_sent += sent;
        for (packets[0..sent]) |pkt| {
            self.stats.bytes_sent += pkt.len;
        }

        return sent;
    }

    /// Get statistics
    pub fn getStats(self: *PacketProcessor) PacketStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *PacketProcessor) void {
        self.stats = .{};
    }
};

/// Classify packet by destination port
fn classifyByPort(port: u16) PacketType {
    return switch (port) {
        SOLANA_TPU_PORT => .tpu_transaction,
        SOLANA_TPU_QUIC_PORT => .tpu_quic,
        SOLANA_GOSSIP_PORT => .gossip,
        SOLANA_TURBINE_PORT => .turbine_shred,
        SOLANA_RPC_PORT => .rpc,
        8003...8010 => .repair, // Typical repair port range
        else => .unknown,
    };
}

fn setupFallbackSocket(interface: []const u8) !std.posix.socket_t {
    _ = interface;
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);

    // Set socket options for high performance
    const one: u32 = 1;
    _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one));

    return sock;
}

fn receiveFallback(sock: std.posix.socket_t, packets: []Packet) !usize {
    _ = sock;
    _ = packets;
    // Simplified - would use recvmmsg in production
    return 0;
}

fn sendFallback(sock: std.posix.socket_t, packets: []const Packet) !usize {
    _ = sock;
    _ = packets;
    // Simplified - would use sendmmsg in production
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "PacketProcessor: init without XDP" {
    const allocator = std.testing.allocator;

    // This will fall back to standard sockets since we don't have XDP in test
    var processor = try PacketProcessor.init(allocator, .{
        .worker_threads = 0, // Don't start workers in test
    });
    defer processor.deinit();

    try std.testing.expect(!processor.using_xdp);
}

test "classifyByPort: TPU" {
    const pkt_type = classifyByPort(SOLANA_TPU_PORT);
    try std.testing.expectEqual(PacketType.tpu_transaction, pkt_type);
}

test "classifyByPort: gossip" {
    const pkt_type = classifyByPort(SOLANA_GOSSIP_PORT);
    try std.testing.expectEqual(PacketType.gossip, pkt_type);
}

test "EthHeader: size" {
    try std.testing.expectEqual(@as(usize, 14), @sizeOf(EthHeader));
}

test "Ipv4Header: size" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(Ipv4Header));
}

test "UdpHeader: size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(UdpHeader));
}

