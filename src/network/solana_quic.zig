//! Solana-Compatible QUIC Transport
//! Wire format and protocol compatibility for Solana network.
//!
//! This module bridges our QUIC transport to Solana's actual protocol:
//! - Transaction submission via QUIC streams
//! - Shred propagation via UDP datagrams
//! - Gossip protocol compatibility
//! - RPC over QUIC
//!
//! Solana QUIC Specifics:
//! ┌─────────────────────────────────────────────────────────────────────┐
//! │ SOLANA QUIC PROTOCOL                                                │
//! ├─────────────────────────────────────────────────────────────────────┤
//! │ Transaction Submission (TPU):                                       │
//! │   - QUIC stream per transaction batch                               │
//! │   - Max 128 connections per IP                                      │
//! │   - Max 8 streams per connection                                    │
//! │   - Transaction serialized as bincode                               │
//! │                                                                      │
//! │ Shred Propagation (Turbine):                                        │
//! │   - UDP datagrams (1228 bytes)                                      │
//! │   - Not QUIC (too much overhead for small packets)                  │
//! │                                                                      │
//! │ Gossip Protocol:                                                    │
//! │   - UDP datagrams                                                   │
//! │   - Ping/Pong, Pull, Push, Prune messages                          │
//! └─────────────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const packet = @import("packet.zig");
const quic = @import("quic/root.zig");

/// Solana packet sizes
pub const PACKET_DATA_SIZE: usize = 1232;
pub const SHRED_SIZE: usize = 1228;
pub const MAX_TX_SIZE: usize = 1232;
pub const MTU: usize = 1280;

/// Solana QUIC configuration (matches validator defaults)
pub const SolanaQuicConfig = struct {
    /// Maximum concurrent connections from a single IP
    max_connections_per_ip: u32 = 128,
    /// Maximum streams per connection (for TPU)
    max_streams_per_connection: u32 = 8,
    /// Maximum pending connections
    max_pending_connections: u32 = 1024,
    /// Connection idle timeout (seconds)
    idle_timeout_secs: u32 = 10,
    /// Maximum transaction batch size
    max_tx_batch_size: usize = 128,
    /// Staked connection multiplier (2x for staked validators)
    staked_connection_multiplier: u32 = 2,
};

/// Transaction wire format (Solana bincode serialization)
pub const TransactionWireFormat = struct {
    /// Number of signatures
    signature_count: u8,
    /// Signatures (64 bytes each)
    signatures: []const [64]u8,
    /// Message (compact format)
    message: MessageFormat,

    pub const MessageFormat = struct {
        /// Header
        num_required_signatures: u8,
        num_readonly_signed: u8,
        num_readonly_unsigned: u8,
        /// Account keys (32 bytes each)
        account_keys: []const [32]u8,
        /// Recent blockhash
        recent_blockhash: [32]u8,
        /// Instructions
        instructions: []const InstructionFormat,
    };

    pub const InstructionFormat = struct {
        program_id_index: u8,
        accounts: []const u8,
        data: []const u8,
    };

    /// Serialize to bytes (bincode format)
    pub fn serialize(self: *const TransactionWireFormat, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        // Signature count (compact-u16)
        try writeCompactU16(writer, @intCast(self.signatures.len));

        // Signatures
        for (self.signatures) |sig| {
            try writer.writeAll(&sig);
        }

        // Message header
        try writer.writeByte(self.message.num_required_signatures);
        try writer.writeByte(self.message.num_readonly_signed);
        try writer.writeByte(self.message.num_readonly_unsigned);

        // Account keys
        try writeCompactU16(writer, @intCast(self.message.account_keys.len));
        for (self.message.account_keys) |key| {
            try writer.writeAll(&key);
        }

        // Recent blockhash
        try writer.writeAll(&self.message.recent_blockhash);

        // Instructions
        try writeCompactU16(writer, @intCast(self.message.instructions.len));
        for (self.message.instructions) |ix| {
            try writer.writeByte(ix.program_id_index);
            try writeCompactU16(writer, @intCast(ix.accounts.len));
            try writer.writeAll(ix.accounts);
            try writeCompactU16(writer, @intCast(ix.data.len));
            try writer.writeAll(ix.data);
        }

        return buffer.toOwnedSlice();
    }

    /// Deserialize from bytes
    pub fn deserialize(allocator: Allocator, data: []const u8) !TransactionWireFormat {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Signature count
        const sig_count = try readCompactU16(reader);
        const signatures = try allocator.alloc([64]u8, sig_count);
        for (signatures) |*sig| {
            _ = try reader.readAll(sig);
        }

        // Message header
        const num_required_signatures = try reader.readByte();
        const num_readonly_signed = try reader.readByte();
        const num_readonly_unsigned = try reader.readByte();

        // Account keys
        const key_count = try readCompactU16(reader);
        const account_keys = try allocator.alloc([32]u8, key_count);
        for (account_keys) |*key| {
            _ = try reader.readAll(key);
        }

        // Recent blockhash
        var recent_blockhash: [32]u8 = undefined;
        _ = try reader.readAll(&recent_blockhash);

        // Instructions
        const ix_count = try readCompactU16(reader);
        const instructions = try allocator.alloc(InstructionFormat, ix_count);
        for (instructions) |*ix| {
            ix.program_id_index = try reader.readByte();
            const acc_len = try readCompactU16(reader);
            const accounts = try allocator.alloc(u8, acc_len);
            _ = try reader.readAll(accounts);
            ix.accounts = accounts;
            const data_len = try readCompactU16(reader);
            const ix_data = try allocator.alloc(u8, data_len);
            _ = try reader.readAll(ix_data);
            ix.data = ix_data;
        }

        return .{
            .signature_count = @intCast(sig_count),
            .signatures = signatures,
            .message = .{
                .num_required_signatures = num_required_signatures,
                .num_readonly_signed = num_readonly_signed,
                .num_readonly_unsigned = num_readonly_unsigned,
                .account_keys = account_keys,
                .recent_blockhash = recent_blockhash,
                .instructions = instructions,
            },
        };
    }
};

/// Shred wire format
pub const ShredWireFormat = struct {
    /// Shred header
    pub const Header = extern struct {
        signature: [64]u8,
        variant: u8,
        slot: u64,
        index: u32,
        version: u16,
        fec_set_index: u32,
    };

    /// Shred types
    pub const ShredType = enum(u2) {
        data = 0b10,
        code = 0b01,
    };

    header: Header,
    payload: []const u8,

    pub const MAX_PAYLOAD_SIZE: usize = SHRED_SIZE - @sizeOf(Header);
};

/// Gossip message types (bincode serialized)
pub const GossipMessageType = enum(u32) {
    pull_request = 0,
    pull_response = 1,
    push_message = 2,
    prune_message = 3,
    ping = 4,
    pong = 5,
};

/// Solana QUIC endpoint for TPU
pub const SolanaTpuQuic = struct {
    allocator: Allocator,
    config: SolanaQuicConfig,
    transport: *quic.Transport,
    connections: std.AutoHashMap(u64, ConnectionState),
    stats: Stats,
    running: std.atomic.Value(bool),

    pub const ConnectionState = struct {
        streams_used: u32,
        bytes_sent: u64,
        last_activity: i64,
        is_staked: bool,
    };

    pub const Stats = struct {
        transactions_received: u64 = 0,
        transactions_sent: u64 = 0,
        connections_accepted: u64 = 0,
        connections_rejected: u64 = 0,
        rate_limited: u64 = 0,
    };

    pub fn init(allocator: Allocator, config: SolanaQuicConfig) !*SolanaTpuQuic {
        const self = try allocator.create(SolanaTpuQuic);
        errdefer allocator.destroy(self);

        const transport = try quic.createTransportWithConfig(allocator, .{
            .max_streams = config.max_streams_per_connection,
            .idle_timeout_ms = config.idle_timeout_secs * 1000,
            .enable_datagrams = true,
        });

        self.* = .{
            .allocator = allocator,
            .config = config,
            .transport = transport,
            .connections = std.AutoHashMap(u64, ConnectionState).init(allocator),
            .stats = .{},
            .running = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    pub fn deinit(self: *SolanaTpuQuic) void {
        self.transport.deinit();
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    /// Start listening for TPU QUIC connections
    pub fn listen(self: *SolanaTpuQuic, port: u16) !void {
        try self.transport.listen(port);
        self.running.store(true, .release);
        std.log.info("[TPU-QUIC] Listening on port {d}", .{port});
    }

    /// Send transaction to a TPU endpoint
    pub fn sendTransaction(self: *SolanaTpuQuic, tpu_addr: []const u8, port: u16, tx_data: []const u8) !void {
        if (tx_data.len > MAX_TX_SIZE) return error.TransactionTooLarge;

        const conn = try self.transport.connect(tpu_addr, port);

        // Send on reliable stream (Solana TPU expects stream, not datagram)
        try conn.send(.{
            .data = tx_data,
            .delivery = .reliable,
            .priority = .normal,
        });

        self.stats.transactions_sent += 1;
    }

    /// Send transaction batch
    pub fn sendTransactionBatch(self: *SolanaTpuQuic, tpu_addr: []const u8, port: u16, transactions: []const []const u8) !usize {
        var sent: usize = 0;

        for (transactions) |tx| {
            self.sendTransaction(tpu_addr, port, tx) catch continue;
            sent += 1;
        }

        return sent;
    }

    pub fn getStats(self: *const SolanaTpuQuic) Stats {
        return self.stats;
    }
};

/// Solana network client (high-level API)
pub const SolanaNetworkClient = struct {
    allocator: Allocator,
    tpu_quic: *SolanaTpuQuic,
    identity: core.Pubkey,
    cluster: ClusterType,

    pub const ClusterType = enum {
        mainnet_beta,
        testnet,
        devnet,
        localnet,

        pub fn entrypoints(self: ClusterType) []const Entrypoint {
            return switch (self) {
                .mainnet_beta => &[_]Entrypoint{
                    .{ .host = "entrypoint.mainnet-beta.solana.com", .port = 8001 },
                    .{ .host = "entrypoint2.mainnet-beta.solana.com", .port = 8001 },
                    .{ .host = "entrypoint3.mainnet-beta.solana.com", .port = 8001 },
                },
                .testnet => &[_]Entrypoint{
                    .{ .host = "entrypoint.testnet.solana.com", .port = 8001 },
                },
                .devnet => &[_]Entrypoint{
                    .{ .host = "entrypoint.devnet.solana.com", .port = 8001 },
                },
                .localnet => &[_]Entrypoint{
                    .{ .host = "127.0.0.1", .port = 8001 },
                },
            };
        }
    };

    pub const Entrypoint = struct {
        host: []const u8,
        port: u16,
    };

    pub fn init(allocator: Allocator, identity: core.Pubkey, cluster: ClusterType) !*SolanaNetworkClient {
        const self = try allocator.create(SolanaNetworkClient);
        errdefer allocator.destroy(self);

        const tpu_quic = try SolanaTpuQuic.init(allocator, .{});

        self.* = .{
            .allocator = allocator,
            .tpu_quic = tpu_quic,
            .identity = identity,
            .cluster = cluster,
        };

        return self;
    }

    pub fn deinit(self: *SolanaNetworkClient) void {
        self.tpu_quic.deinit();
        self.allocator.destroy(self);
    }

    /// Send a transaction to the cluster
    pub fn sendTransaction(self: *SolanaNetworkClient, tpu_addr: []const u8, port: u16, tx: []const u8) !void {
        try self.tpu_quic.sendTransaction(tpu_addr, port, tx);
    }

    /// Get cluster entrypoints
    pub fn getEntrypoints(self: *const SolanaNetworkClient) []const Entrypoint {
        return self.cluster.entrypoints();
    }
};

// ============================================================================
// Compact-u16 encoding (Solana's variable-length integer format)
// ============================================================================

fn writeCompactU16(writer: anytype, value: u16) !void {
    if (value < 0x80) {
        try writer.writeByte(@truncate(value));
    } else if (value < 0x4000) {
        try writer.writeByte(@as(u8, @truncate(value & 0x7f)) | 0x80);
        try writer.writeByte(@truncate(value >> 7));
    } else {
        try writer.writeByte(@as(u8, @truncate(value & 0x7f)) | 0x80);
        try writer.writeByte(@as(u8, @truncate((value >> 7) & 0x7f)) | 0x80);
        try writer.writeByte(@truncate(value >> 14));
    }
}

fn readCompactU16(reader: anytype) !u16 {
    var result: u16 = 0;
    var shift: u4 = 0;

    while (shift < 16) {
        const byte = try reader.readByte();
        result |= @as(u16, byte & 0x7f) << shift;

        if (byte & 0x80 == 0) {
            break;
        }
        shift += 7;
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "compact-u16 encoding" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Test small value
    try writeCompactU16(buffer.writer(), 42);
    try std.testing.expectEqual(@as(usize, 1), buffer.items.len);

    var stream = std.io.fixedBufferStream(buffer.items);
    const decoded = try readCompactU16(stream.reader());
    try std.testing.expectEqual(@as(u16, 42), decoded);
}

test "compact-u16 encoding large" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Test larger value
    try writeCompactU16(buffer.writer(), 16384);

    var stream = std.io.fixedBufferStream(buffer.items);
    const decoded = try readCompactU16(stream.reader());
    try std.testing.expectEqual(@as(u16, 16384), decoded);
}

test "SolanaTpuQuic init" {
    const allocator = std.testing.allocator;

    const tpu = try SolanaTpuQuic.init(allocator, .{});
    defer tpu.deinit();

    try std.testing.expect(!tpu.running.load(.acquire));
}

