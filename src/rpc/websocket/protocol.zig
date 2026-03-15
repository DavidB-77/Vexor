//! WebSocket Protocol Implementation
//! RFC 6455 compliant WebSocket protocol for Solana RPC subscriptions.
//!
//! Frame format:
//! ┌────────────────────────────────────────────────────────────┐
//! │  0               1               2               3         │
//! │  0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 ... │
//! │ +-+-+-+-+-------+-+-------------+-------------------------------+
//! │ |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
//! │ |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
//! │ |N|V|V|V|       |S|             |   (if payload len==126/127)   |
//! │ | |1|2|3|       |K|             |                               |
//! │ +-+-+-+-+-------+-+-------------+-------------------------------+
//! │ |     Extended payload length continued, if payload len == 127  |
//! │ +-------------------------------+-------------------------------+
//! │ |                   Masking-key, if MASK set to 1               |
//! │ +-------------------------------+-------------------------------+
//! │ |                         Payload Data                          |
//! │ +---------------------------------------------------------------+
//! └────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const base64 = std.base64;

/// WebSocket opcodes
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
};

/// WebSocket close codes
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    bad_gateway = 1014,
    tls_handshake = 1015,
};

/// WebSocket frame
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    mask: bool,
    masking_key: ?[4]u8,
    payload: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Frame) void {
        if (self.payload.len > 0) {
            self.allocator.free(self.payload);
        }
    }

    /// Create a text frame
    pub fn text(allocator: Allocator, data: []const u8) !Frame {
        const payload = try allocator.dupe(u8, data);
        return .{
            .fin = true,
            .opcode = .text,
            .mask = false,
            .masking_key = null,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// Create a binary frame
    pub fn binary(allocator: Allocator, data: []const u8) !Frame {
        const payload = try allocator.dupe(u8, data);
        return .{
            .fin = true,
            .opcode = .binary,
            .mask = false,
            .masking_key = null,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// Create a close frame
    pub fn close(allocator: Allocator, code: CloseCode, reason: []const u8) !Frame {
        var payload = try allocator.alloc(u8, 2 + reason.len);
        std.mem.writeInt(u16, payload[0..2], @intFromEnum(code), .big);
        @memcpy(payload[2..], reason);
        return .{
            .fin = true,
            .opcode = .close,
            .mask = false,
            .masking_key = null,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// Create a ping frame
    pub fn ping(allocator: Allocator, data: []const u8) !Frame {
        const payload = try allocator.dupe(u8, data);
        return .{
            .fin = true,
            .opcode = .ping,
            .mask = false,
            .masking_key = null,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// Create a pong frame
    pub fn pong(allocator: Allocator, data: []const u8) !Frame {
        const payload = try allocator.dupe(u8, data);
        return .{
            .fin = true,
            .opcode = .pong,
            .mask = false,
            .masking_key = null,
            .payload = payload,
            .allocator = allocator,
        };
    }

    /// Encode frame to bytes
    pub fn encode(self: *const Frame, allocator: Allocator) ![]u8 {
        const payload_len = self.payload.len;
        var header_len: usize = 2;

        // Extended payload length
        if (payload_len > 125 and payload_len < 65536) {
            header_len += 2;
        } else if (payload_len >= 65536) {
            header_len += 8;
        }

        // Masking key
        if (self.mask) {
            header_len += 4;
        }

        var buf = try allocator.alloc(u8, header_len + payload_len);
        errdefer allocator.free(buf);

        // First byte: FIN + opcode
        buf[0] = (@as(u8, if (self.fin) 0x80 else 0)) | @intFromEnum(self.opcode);

        // Second byte: MASK + payload length
        var offset: usize = 2;
        if (payload_len < 126) {
            buf[1] = (@as(u8, if (self.mask) 0x80 else 0)) | @as(u8, @truncate(payload_len));
        } else if (payload_len < 65536) {
            buf[1] = (@as(u8, if (self.mask) 0x80 else 0)) | 126;
            std.mem.writeInt(u16, buf[2..4], @as(u16, @truncate(payload_len)), .big);
            offset = 4;
        } else {
            buf[1] = (@as(u8, if (self.mask) 0x80 else 0)) | 127;
            std.mem.writeInt(u64, buf[2..10], payload_len, .big);
            offset = 10;
        }

        // Masking key
        if (self.mask) {
            if (self.masking_key) |key| {
                @memcpy(buf[offset..][0..4], &key);
            }
            offset += 4;
        }

        // Payload
        @memcpy(buf[offset..], self.payload);

        // Apply mask if needed
        if (self.mask) {
            if (self.masking_key) |key| {
                for (buf[offset..], 0..) |*byte, i| {
                    byte.* ^= key[i % 4];
                }
            }
        }

        return buf;
    }

    /// Decode frame from bytes
    pub fn decode(allocator: Allocator, data: []const u8) !struct { frame: Frame, consumed: usize } {
        if (data.len < 2) return error.InsufficientData;

        const fin = (data[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(data[0] & 0x0f);
        const mask = (data[1] & 0x80) != 0;
        var payload_len: u64 = data[1] & 0x7f;
        var offset: usize = 2;

        // Extended payload length
        if (payload_len == 126) {
            if (data.len < 4) return error.InsufficientData;
            payload_len = std.mem.readInt(u16, data[2..4], .big);
            offset = 4;
        } else if (payload_len == 127) {
            if (data.len < 10) return error.InsufficientData;
            payload_len = std.mem.readInt(u64, data[2..10], .big);
            offset = 10;
        }

        // Masking key
        var masking_key: ?[4]u8 = null;
        if (mask) {
            if (data.len < offset + 4) return error.InsufficientData;
            masking_key = data[offset..][0..4].*;
            offset += 4;
        }

        // Check we have full payload
        if (data.len < offset + payload_len) return error.InsufficientData;

        // Copy payload
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        @memcpy(payload, data[offset..][0..payload_len]);

        // Unmask if needed
        if (masking_key) |key| {
            for (payload, 0..) |*byte, i| {
                byte.* ^= key[i % 4];
            }
        }

        return .{
            .frame = .{
                .fin = fin,
                .opcode = opcode,
                .mask = mask,
                .masking_key = masking_key,
                .payload = payload,
                .allocator = allocator,
            },
            .consumed = offset + payload_len,
        };
    }
};

/// WebSocket handshake
pub const Handshake = struct {
    /// Generate WebSocket accept key from client key
    pub fn generateAcceptKey(client_key: []const u8) ![28]u8 {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        var combined: [60 + magic.len]u8 = undefined;
        const key_len = @min(client_key.len, 60);
        @memcpy(combined[0..key_len], client_key[0..key_len]);
        @memcpy(combined[key_len..][0..magic.len], magic);

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(combined[0 .. key_len + magic.len], &hash, .{});

        var accept_key: [28]u8 = undefined;
        _ = base64.standard.Encoder.encode(&accept_key, &hash);

        return accept_key;
    }

    /// Build handshake response
    pub fn buildResponse(allocator: Allocator, client_key: []const u8) ![]u8 {
        const accept_key = try generateAcceptKey(client_key);

        return std.fmt.allocPrint(allocator,
            \\HTTP/1.1 101 Switching Protocols\r
            \\Upgrade: websocket\r
            \\Connection: Upgrade\r
            \\Sec-WebSocket-Accept: {s}\r
            \\\r
            \\
        , .{accept_key});
    }
};

/// WebSocket connection state
pub const ConnectionState = enum {
    connecting,
    open,
    closing,
    closed,
};

// ============================================================================
// Tests
// ============================================================================

test "Frame: encode text frame" {
    const allocator = std.testing.allocator;

    var frame = try Frame.text(allocator, "Hello");
    defer frame.deinit();

    const encoded = try frame.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(u8, 0x81), encoded[0]); // FIN + TEXT
    try std.testing.expectEqual(@as(u8, 5), encoded[1]); // Length
    try std.testing.expectEqualSlices(u8, "Hello", encoded[2..7]);
}

test "Frame: decode text frame" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    const result = try Frame.decode(allocator, &data);
    var frame = result.frame;
    defer frame.deinit();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(Opcode.text, frame.opcode);
    try std.testing.expectEqualSlices(u8, "Hello", frame.payload);
    try std.testing.expectEqual(@as(usize, 7), result.consumed);
}

test "Frame: encode/decode roundtrip" {
    const allocator = std.testing.allocator;

    var original = try Frame.text(allocator, "Test message");
    defer original.deinit();

    const encoded = try original.encode(allocator);
    defer allocator.free(encoded);

    const result = try Frame.decode(allocator, encoded);
    var decoded = result.frame;
    defer decoded.deinit();

    try std.testing.expectEqualSlices(u8, original.payload, decoded.payload);
}

test "Handshake: generate accept key" {
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try Handshake.generateAcceptKey(client_key);
    try std.testing.expectEqualSlices(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

