//! MASQUE Protocol Implementation
//! Multiplexed Application Substrate over QUIC Encryption (RFC 9298, RFC 9484)
//!
//! MASQUE enables:
//! - CONNECT-UDP: Proxy UDP datagrams over QUIC
//! - CONNECT-IP: Proxy IP packets over QUIC
//! - HTTP/3 Datagrams for low-latency transfer
//!
//! Transport Modes:
//! ┌─────────────────────────────────────────────────────────────────────┐
//! │  QUIC DATAGRAMS (RFC 9221)          CAPSULES OVER STREAMS          │
//! │  ─────────────────────────          ─────────────────────          │
//! │  • Unreliable delivery              • Reliable delivery             │
//! │  • ~1200-1350 byte limit            • Unlimited size                │
//! │  • Lowest latency (~1ms)            • Slightly higher latency       │
//! │  • Best for: shreds, gossip         • Best for: snapshots, large TX │
//! │                                                                      │
//! │  Auto-selection based on payload size:                              │
//! │  ┌──────────────┐                                                   │
//! │  │ payload_size │──▶ < MAX_DATAGRAM_SIZE ──▶ Use QUIC Datagram     │
//! │  └──────────────┘──▶ >= MAX_DATAGRAM_SIZE ─▶ Use Capsule/Stream    │
//! └─────────────────────────────────────────────────────────────────────┘
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────────────┐
//! │                        MASQUE Proxy                                  │
//! ├─────────────────────────────────────────────────────────────────────┤
//! │  Client                    Proxy                    Target           │
//! │  ──────                    ─────                    ──────           │
//! │  ┌──────┐    QUIC        ┌──────┐      UDP       ┌──────────┐       │
//! │  │Vexor │◄──────────────▶│MASQUE│◄──────────────▶│ Validator│       │
//! │  │Dash  │  CONNECT-UDP   │Server│   Forwarded    │ Cluster  │       │
//! │  └──────┘                └──────┘                └──────────┘       │
//! │                                                                      │
//! │  Benefits:                                                           │
//! │  - Traverse NAT/firewalls                                           │
//! │  - Encrypt all traffic                                              │
//! │  - Multiplex connections                                            │
//! │  - ~1-2ms overhead                                                  │
//! └─────────────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// DATAGRAM SIZE LIMITS
// ============================================================================

/// Maximum QUIC datagram payload size (conservative estimate)
/// Based on: 1500 (MTU) - 40 (IPv6) - 8 (UDP) - 20-50 (QUIC headers) ≈ 1200
pub const MAX_DATAGRAM_PAYLOAD: usize = 1200;

/// Recommended safe datagram size for most networks
pub const SAFE_DATAGRAM_SIZE: usize = 1200;

/// Solana-specific sizes for reference
pub const SOLANA_SHRED_SIZE: usize = 1228;
pub const SOLANA_PACKET_DATA_SIZE: usize = 1232;
pub const SOLANA_MTU: usize = 1280; // IPv6 minimum MTU

/// Transport mode selection
pub const TransportMode = enum {
    /// Use QUIC datagrams (unreliable, low latency, size-limited)
    datagram,
    /// Use capsules over QUIC stream (reliable, higher latency, unlimited size)
    stream,
    /// Auto-select based on payload size
    auto,
};

/// Determine the appropriate transport mode for a payload
pub fn selectTransportMode(payload_size: usize, max_datagram_size: usize) TransportMode {
    if (payload_size <= max_datagram_size) {
        return .datagram;
    }
    return .stream;
}

/// Check if a payload fits in a single datagram
pub fn fitsInDatagram(payload_size: usize) bool {
    return payload_size <= MAX_DATAGRAM_PAYLOAD;
}

/// MASQUE capsule types (RFC 9297)
pub const CapsuleType = enum(u62) {
    // Core capsule types
    datagram = 0x00,
    close_webtransport_session = 0x2843,

    // CONNECT-UDP specific (RFC 9298)
    register_datagram_context = 0x00,
    close_datagram_context = 0x01,

    // CONNECT-IP specific (RFC 9484)
    address_assign = 0x01,
    address_request = 0x02,
    route_advertisement = 0x03,
};

/// HTTP/3 DATAGRAM frame format (RFC 9297)
/// ┌────────────────────────────────────────┐
/// │ Quarter Stream ID (i)                  │
/// ├────────────────────────────────────────┤
/// │ HTTP Datagram Payload (..)             │
/// └────────────────────────────────────────┘
pub const Http3Datagram = struct {
    quarter_stream_id: u64,
    payload: []const u8,

    pub fn encode(self: *const Http3Datagram, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        // Encode variable-length integer for quarter stream ID
        try encodeVarint(writer, self.quarter_stream_id);
        try writer.writeAll(self.payload);

        return buffer.toOwnedSlice();
    }

    pub fn decode(allocator: Allocator, data: []const u8) !Http3Datagram {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const qsid = try decodeVarint(reader);
        const remaining = data[stream.pos..];

        const payload = try allocator.dupe(u8, remaining);

        return .{
            .quarter_stream_id = qsid,
            .payload = payload,
        };
    }
};

/// CONNECT-UDP request target
/// Format: /.well-known/masque/udp/{target_host}/{target_port}/
pub const ConnectUdpTarget = struct {
    host: []const u8,
    port: u16,

    pub fn toPath(self: *const ConnectUdpTarget, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "/.well-known/masque/udp/{s}/{d}/", .{
            self.host,
            self.port,
        });
    }

    pub fn fromPath(path: []const u8) ?ConnectUdpTarget {
        const prefix = "/.well-known/masque/udp/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;

        const remainder = path[prefix.len..];
        var iter = std.mem.splitScalar(u8, remainder, '/');

        const host = iter.next() orelse return null;
        const port_str = iter.next() orelse return null;

        const port = std.fmt.parseInt(u16, port_str, 10) catch return null;

        return .{
            .host = host,
            .port = port,
        };
    }
};

/// CONNECT-IP request target
/// Format: /.well-known/masque/ip/{target_host}/
pub const ConnectIpTarget = struct {
    host: ?[]const u8, // null for wildcard

    pub fn toPath(self: *const ConnectIpTarget, allocator: Allocator) ![]u8 {
        if (self.host) |h| {
            return std.fmt.allocPrint(allocator, "/.well-known/masque/ip/{s}/", .{h});
        }
        return std.fmt.allocPrint(allocator, "/.well-known/masque/ip/*/", .{});
    }
};

/// Datagram context for multiplexing
pub const DatagramContext = struct {
    context_id: u64,
    target: ConnectUdpTarget,
    created_at: i64,
    bytes_sent: u64,
    bytes_received: u64,
    datagrams_sent: u64,
    datagrams_received: u64,
    /// Negotiated max datagram size for this context
    max_datagram_size: usize = MAX_DATAGRAM_PAYLOAD,
    /// Transport mode preference
    transport_mode: TransportMode = .auto,
};

/// Chunked payload for large data that exceeds datagram limits
/// Used when sending data > MAX_DATAGRAM_PAYLOAD over streams
pub const ChunkedPayload = struct {
    /// Unique ID for reassembly
    payload_id: u64,
    /// Total number of chunks
    total_chunks: u32,
    /// Current chunk index (0-based)
    chunk_index: u32,
    /// Total payload size
    total_size: u64,
    /// Chunk data
    data: []const u8,

    pub const CHUNK_HEADER_SIZE: usize = 8 + 4 + 4 + 8; // payload_id + total + index + size

    pub fn encode(self: *const ChunkedPayload, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.writeInt(u64, self.payload_id, .big);
        try writer.writeInt(u32, self.total_chunks, .big);
        try writer.writeInt(u32, self.chunk_index, .big);
        try writer.writeInt(u64, self.total_size, .big);
        try writer.writeAll(self.data);

        return buffer.toOwnedSlice();
    }

    pub fn decode(allocator: Allocator, data: []const u8) !ChunkedPayload {
        if (data.len < CHUNK_HEADER_SIZE) return error.InsufficientData;

        return .{
            .payload_id = std.mem.readInt(u64, data[0..8], .big),
            .total_chunks = std.mem.readInt(u32, data[8..12], .big),
            .chunk_index = std.mem.readInt(u32, data[12..16], .big),
            .total_size = std.mem.readInt(u64, data[16..24], .big),
            .data = try allocator.dupe(u8, data[24..]),
        };
    }

    /// Calculate chunk size for a given payload
    pub fn calculateChunkCount(payload_size: usize, max_chunk_size: usize) u32 {
        const effective_chunk_size = max_chunk_size - CHUNK_HEADER_SIZE;
        return @intCast((payload_size + effective_chunk_size - 1) / effective_chunk_size);
    }
};

/// Reassembly buffer for chunked payloads
pub const ChunkReassembler = struct {
    allocator: Allocator,
    /// Pending reassemblies by payload_id
    pending: std.AutoHashMap(u64, PendingPayload),
    /// Timeout for incomplete reassemblies (nanoseconds)
    timeout_ns: u64 = 30 * std.time.ns_per_s,

    pub const PendingPayload = struct {
        chunks: std.ArrayList(?[]u8),
        received_count: u32,
        total_chunks: u32,
        total_size: u64,
        started_at: i64,
    };

    pub fn init(allocator: Allocator) ChunkReassembler {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(u64, PendingPayload).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkReassembler) void {
        var iter = self.pending.valueIterator();
        while (iter.next()) |pending| {
            for (pending.chunks.items) |chunk_opt| {
                if (chunk_opt) |chunk| {
                    self.allocator.free(chunk);
                }
            }
            pending.chunks.deinit();
        }
        self.pending.deinit();
    }

    /// Add a chunk and return the complete payload if reassembly is done
    pub fn addChunk(self: *ChunkReassembler, chunk: ChunkedPayload) !?[]u8 {
        const result = try self.pending.getOrPut(chunk.payload_id);

        if (!result.found_existing) {
            // New payload
            var chunks = std.ArrayList(?[]u8).init(self.allocator);
            try chunks.resize(chunk.total_chunks);
            for (chunks.items) |*item| {
                item.* = null;
            }

            result.value_ptr.* = .{
                .chunks = chunks,
                .received_count = 0,
                .total_chunks = chunk.total_chunks,
                .total_size = chunk.total_size,
                .started_at = std.time.timestamp(),
            };
        }

        var pending = result.value_ptr;

        // Store chunk (if not already received)
        if (pending.chunks.items[chunk.chunk_index] == null) {
            pending.chunks.items[chunk.chunk_index] = try self.allocator.dupe(u8, chunk.data);
            pending.received_count += 1;
        }

        // Check if complete
        if (pending.received_count == pending.total_chunks) {
            // Reassemble
            var complete = std.ArrayList(u8).init(self.allocator);
            for (pending.chunks.items) |chunk_opt| {
                if (chunk_opt) |data| {
                    try complete.appendSlice(data);
                    self.allocator.free(data);
                }
            }
            pending.chunks.deinit();
            _ = self.pending.remove(chunk.payload_id);

            return try complete.toOwnedSlice();
        }

        return null;
    }

    /// Remove stale incomplete payloads
    pub fn pruneStale(self: *ChunkReassembler) void {
        const now = std.time.timestamp();
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            const age_ns: u64 = @intCast((now - entry.value_ptr.started_at) * std.time.ns_per_s);
            if (age_ns > self.timeout_ns) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |id| {
            if (self.pending.fetchRemove(id)) |removed| {
                for (removed.value.chunks.items) |chunk_opt| {
                    if (chunk_opt) |chunk| {
                        self.allocator.free(chunk);
                    }
                }
                var pending_chunks = removed.value.chunks;
                pending_chunks.deinit();
            }
        }
    }
};

/// Capsule format (RFC 9297)
/// ┌────────────────────────────────────────┐
/// │ Capsule Type (i)                       │
/// ├────────────────────────────────────────┤
/// │ Capsule Length (i)                     │
/// ├────────────────────────────────────────┤
/// │ Capsule Value (..)                     │
/// └────────────────────────────────────────┘
pub const Capsule = struct {
    capsule_type: u64,
    value: []const u8,

    pub fn encode(self: *const Capsule, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try encodeVarint(writer, self.capsule_type);
        try encodeVarint(writer, self.value.len);
        try writer.writeAll(self.value);

        return buffer.toOwnedSlice();
    }

    pub fn decode(allocator: Allocator, data: []const u8) !struct { capsule: Capsule, consumed: usize } {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const capsule_type = try decodeVarint(reader);
        const length = try decodeVarint(reader);

        const value_start = stream.pos;
        if (value_start + length > data.len) return error.InsufficientData;

        const value = try allocator.dupe(u8, data[value_start..][0..length]);

        return .{
            .capsule = .{
                .capsule_type = capsule_type,
                .value = value,
            },
            .consumed = value_start + length,
        };
    }
};

/// CONNECT-UDP context registration capsule
pub const ContextRegistration = struct {
    context_id: u64,
    target_host: []const u8,
    target_port: u16,

    pub fn encode(self: *const ContextRegistration, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try encodeVarint(writer, self.context_id);
        try encodeVarint(writer, self.target_host.len);
        try writer.writeAll(self.target_host);
        try writer.writeInt(u16, self.target_port, .big);

        return buffer.toOwnedSlice();
    }
};

/// IP Address Assignment capsule (CONNECT-IP)
pub const AddressAssign = struct {
    request_id: u64,
    assigned_address: IpAddress,
    prefix_length: u8,

    pub const IpAddress = union(enum) {
        ipv4: [4]u8,
        ipv6: [16]u8,
    };
};

/// Route Advertisement capsule (CONNECT-IP)
pub const RouteAdvertisement = struct {
    routes: []const Route,

    pub const Route = struct {
        ip_address: AddressAssign.IpAddress,
        prefix_length: u8,
        protocol: u8, // 0 = any, 6 = TCP, 17 = UDP
    };
};

// ============================================================================
// Variable-length integer encoding (QUIC format)
// ============================================================================

fn encodeVarint(writer: anytype, value: u64) !void {
    if (value < 64) {
        try writer.writeByte(@truncate(value));
    } else if (value < 16384) {
        try writer.writeByte(@as(u8, 0x40) | @as(u8, @truncate(value >> 8)));
        try writer.writeByte(@truncate(value));
    } else if (value < 1073741824) {
        try writer.writeByte(@as(u8, 0x80) | @as(u8, @truncate(value >> 24)));
        try writer.writeByte(@truncate(value >> 16));
        try writer.writeByte(@truncate(value >> 8));
        try writer.writeByte(@truncate(value));
    } else {
        try writer.writeByte(@as(u8, 0xc0) | @as(u8, @truncate(value >> 56)));
        try writer.writeByte(@truncate(value >> 48));
        try writer.writeByte(@truncate(value >> 40));
        try writer.writeByte(@truncate(value >> 32));
        try writer.writeByte(@truncate(value >> 24));
        try writer.writeByte(@truncate(value >> 16));
        try writer.writeByte(@truncate(value >> 8));
        try writer.writeByte(@truncate(value));
    }
}

fn decodeVarint(reader: anytype) !u64 {
    const first = try reader.readByte();
    const prefix = first >> 6;

    return switch (prefix) {
        0 => first,
        1 => (@as(u64, first & 0x3f) << 8) | try reader.readByte(),
        2 => blk: {
            var buf: [3]u8 = undefined;
            _ = try reader.readAll(&buf);
            break :blk (@as(u64, first & 0x3f) << 24) |
                (@as(u64, buf[0]) << 16) |
                (@as(u64, buf[1]) << 8) |
                buf[2];
        },
        3 => blk: {
            var buf: [7]u8 = undefined;
            _ = try reader.readAll(&buf);
            break :blk (@as(u64, first & 0x3f) << 56) |
                (@as(u64, buf[0]) << 48) |
                (@as(u64, buf[1]) << 40) |
                (@as(u64, buf[2]) << 32) |
                (@as(u64, buf[3]) << 24) |
                (@as(u64, buf[4]) << 16) |
                (@as(u64, buf[5]) << 8) |
                buf[6];
        },
        else => unreachable,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "varint encoding: small values" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encodeVarint(buffer.writer(), 37);
    try std.testing.expectEqual(@as(usize, 1), buffer.items.len);
    try std.testing.expectEqual(@as(u8, 37), buffer.items[0]);
}

test "varint encoding: two-byte values" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encodeVarint(buffer.writer(), 15293);
    try std.testing.expectEqual(@as(usize, 2), buffer.items.len);
}

test "varint roundtrip" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const test_values = [_]u64{ 0, 1, 63, 64, 16383, 16384, 1073741823, 1073741824 };

    for (test_values) |val| {
        buffer.clearRetainingCapacity();
        try encodeVarint(buffer.writer(), val);

        var stream = std.io.fixedBufferStream(buffer.items);
        const decoded = try decodeVarint(stream.reader());
        try std.testing.expectEqual(val, decoded);
    }
}

test "ConnectUdpTarget: parse path" {
    const target = ConnectUdpTarget.fromPath("/.well-known/masque/udp/example.com/8001/");
    try std.testing.expect(target != null);
    try std.testing.expectEqualStrings("example.com", target.?.host);
    try std.testing.expectEqual(@as(u16, 8001), target.?.port);
}

test "Http3Datagram: encode/decode" {
    const allocator = std.testing.allocator;

    const original = Http3Datagram{
        .quarter_stream_id = 42,
        .payload = "test payload",
    };

    const encoded = try original.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try Http3Datagram.decode(allocator, encoded);
    defer allocator.free(decoded.payload);

    try std.testing.expectEqual(original.quarter_stream_id, decoded.quarter_stream_id);
    try std.testing.expectEqualSlices(u8, original.payload, decoded.payload);
}

