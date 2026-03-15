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
const quic = @import("quic.zig");
const tpu_client = @import("tpu_client.zig");

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
    /// Allow self-signed certs (local testing only)
    allow_insecure: bool = false,
    /// Local port to bind to (0 = ephemeral)
    bind_port: u16 = 0,
    /// Act as a server (accept incoming connections)
    is_server: bool = true,
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
    client: *quic.QuicClient,
    connections: std.AutoHashMap(u64, *quic.Connection),
    mutex: std.Thread.Mutex,
    stats: Stats,
    running: std.atomic.Value(bool),
    transaction_callback: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    transaction_callback_ctx: ?*anyopaque = null,

    pub const ConnectionState = struct {
        streams_used: u32,
        bytes_sent: u64,
        last_activity: i64,
        is_staked: bool,
    };

    pub const Stats = struct {
        transactions_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        transactions_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        connections_accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        connections_rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        rate_limited: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: Allocator, config: SolanaQuicConfig) !*SolanaTpuQuic {
        const self = try allocator.create(SolanaTpuQuic);
        errdefer allocator.destroy(self);

        const client = try quic.QuicClient.init(allocator, config.bind_port, .{
            .max_connections = config.max_pending_connections,
            .max_streams_per_connection = config.max_streams_per_connection,
            .initial_max_data = 10 * 1024 * 1024,
            .initial_max_stream_data = 1024 * 1024,
            .max_idle_timeout_ms = config.idle_timeout_secs * 1000,
        });

        // If configured as server, ensure the underlying endpoint is in server mode
        client.endpoint.is_server = config.is_server;

        self.* = .{
            .allocator = allocator,
            .config = config,
            .client = client,
            .connections = std.AutoHashMap(u64, *quic.Connection).init(allocator),
            .mutex = .{},
            .stats = .{},
            .running = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    pub fn deinit(self: *SolanaTpuQuic) void {
        self.client.deinit();
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    /// Start listening for TPU QUIC connections
    pub fn listen(self: *SolanaTpuQuic, port: u16) !void {
        _ = port; // Already bound in init via config.bind_port
        self.running.store(true, .release);
        std.log.info("[TPU-QUIC] Listening on port {d}", .{self.config.bind_port});
    }

    /// Set callback for incoming transactions
    pub fn setTransactionCallback(
        self: *SolanaTpuQuic,
        ctx: ?*anyopaque,
        cb: *const fn (ctx: ?*anyopaque, data: []const u8) void,
    ) void {
        self.transaction_callback_ctx = ctx;
        self.transaction_callback = cb;
    }

    /// Poll for events and process incoming transactions
    pub fn poll(self: *SolanaTpuQuic) !void {
        try self.client.poll();

        // Process incoming streams across all connections
        var conn_it = self.client.endpoint.connections.valueIterator();
        while (conn_it.next()) |conn_ptr| {
            const conn = conn_ptr.*;
            var stream_it = conn.streams.iterator();
            while (stream_it.next()) |entry| {
                const stream = entry.value_ptr.*;

                // Solana TPU sends each transaction batch on a separate stream.
                // When we receive FIN, the batch is complete.
                if (stream.fin_received and stream.recv_buffer.items.len > 0) {
                    if (self.transaction_callback) |cb| {
                        cb(self.transaction_callback_ctx, stream.recv_buffer.items);
                    }
                    _ = self.stats.transactions_received.fetchAdd(1, .monotonic);

                    // Clear buffer after processing.
                    // Note: In a production client we'd want to remove the stream from the map
                    // once it's fully processed/closed to avoid memory buildup.
                    stream.recv_buffer.clearAndFree();
                }
            }
        }
    }

    /// Send transaction to a TPU endpoint
    pub fn sendTransaction(self: *SolanaTpuQuic, tpu_addr: []const u8, port: u16, tx_data: []const u8) !void {
        if (tx_data.len > MAX_TX_SIZE) return error.TransactionTooLarge;

        const conn = try self.getOrConnect(tpu_addr, port);
        const stream = try conn.openUniStream();
        try conn.send(stream.id, tx_data);

        try conn.send(stream.id, tx_data);

        _ = self.stats.transactions_sent.fetchAdd(1, .monotonic);
    }

    /// Send transaction via QUIC datagram (experimental H3 datagram capsule)
    pub fn sendTransactionDatagram(
        self: *SolanaTpuQuic,
        tpu_addr: []const u8,
        port: u16,
        tx_data: []const u8,
        use_h3_capsule: bool,
    ) !void {
        if (tx_data.len > MAX_TX_SIZE) return error.TransactionTooLarge;

        const conn = try self.getOrConnect(tpu_addr, port);
        const payload = if (use_h3_capsule)
            try encodeH3DatagramCapsule(self.allocator, tx_data)
        else
            try self.allocator.dupe(u8, tx_data);
        defer self.allocator.free(payload);

        const stream = try conn.openUniStream();
        try conn.send(stream.id, payload);

        try conn.send(stream.id, payload);

        _ = self.stats.transactions_sent.fetchAdd(1, .monotonic);
    }

    fn getOrConnect(self: *SolanaTpuQuic, host: []const u8, port: u16) !*quic.Connection {
        const key = hashTarget(host, port);

        self.mutex.lock();
        if (self.connections.get(key)) |existing| {
            self.mutex.unlock();
            return existing;
        }
        self.mutex.unlock();

        const conn = try self.client.connect(host, port);
        waitForHandshake(self, conn) catch |err| {
            std.debug.print("[QUIC] handshake failed for {s}:{d} stage={s} err={}\n", .{
                host,
                port,
                @tagName(conn.tls.handshake_stage),
                err,
            });
            return err;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.put(key, conn);
        return conn;
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

    /// Send transaction batch on a single stream (coalesced)
    pub fn sendTransactionBatchCoalesced(
        self: *SolanaTpuQuic,
        tpu_addr: []const u8,
        port: u16,
        transactions: []const []const u8,
    ) !usize {
        if (transactions.len == 0) return 0;

        const conn = try self.getOrConnect(tpu_addr, port);
        var sent: usize = 0;
        for (transactions) |tx| {
            if (tx.len > MAX_TX_SIZE) continue;
            const stream = try conn.openUniStream();
            conn.send(stream.id, tx) catch continue;
            sent += 1;
        }

        _ = self.stats.transactions_sent.fetchAdd(sent, .monotonic);
        return sent;
    }

    pub fn getStats(self: *const SolanaTpuQuic) struct {
        transactions_received: u64,
        transactions_sent: u64,
        connections_accepted: u64,
        connections_rejected: u64,
        rate_limited: u64,
    } {
        return .{
            .transactions_received = self.stats.transactions_received.load(.monotonic),
            .transactions_sent = self.stats.transactions_sent.load(.monotonic),
            .connections_accepted = self.stats.connections_accepted.load(.monotonic),
            .connections_rejected = self.stats.connections_rejected.load(.monotonic),
            .rate_limited = self.stats.rate_limited.load(.monotonic),
        };
    }
};

fn waitForHandshake(self: *SolanaTpuQuic, conn: *quic.Connection) !void {
    const start = std.time.milliTimestamp();
    var last_resend = start;
    var resends: u32 = 0;
    while (!conn.tls.handshake_complete) {
        // Use non-blocking poll to keep UI/logs responsive and process other packets
        try self.client.poll();
        const now = std.time.milliTimestamp();

        // Use a more aggressive resend interval (100ms instead of 200ms) for initial packets
        if (now - last_resend >= 100) {
            self.client.resendInitial(conn) catch {};
            last_resend = now;
            resends += 1;
            if (resends % 10 == 0) {
                std.debug.print("[QUIC] handshake progress target={any} stage={s} resends={d}\n", .{
                    conn.peer_addr,
                    @tagName(conn.tls.handshake_stage),
                    resends,
                });
            }
        }
        // Increase timeout to 5 seconds to accommodate slower peers across regions
        if (std.time.milliTimestamp() - start > 5000) {
            std.debug.print("[QUIC] handshake timeout target={any} stage={s} resends={d}\n", .{
                conn.peer_addr,
                @tagName(conn.tls.handshake_stage),
                resends,
            });
            return error.HandshakeTimeout;
        }
        // Reduce sleep time to 1ms for much lower latency polling
        std.time.sleep(1 * std.time.ns_per_ms);
    }
}

fn hashTarget(host: []const u8, port: u16) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(host);
    h.update(std.mem.asBytes(&port));
    return h.final();
}

fn encodeH3DatagramCapsule(allocator: Allocator, payload: []const u8) ![]u8 {
    // HTTP/3 datagram capsule (RFC 9297):
    // capsule-type (varint) = 0x00
    // capsule-length (varint) = payload length
    const header = try encodeQuicVarInt(allocator, 0);
    defer allocator.free(header);
    const len = try encodeQuicVarInt(allocator, payload.len);
    defer allocator.free(len);

    var out = try allocator.alloc(u8, header.len + len.len + payload.len);
    @memcpy(out[0..header.len], header);
    @memcpy(out[header.len .. header.len + len.len], len);
    @memcpy(out[header.len + len.len ..], payload);
    return out;
}

test "quic stub send" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(allocator, "VEXOR_QUIC_STUB") catch return;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;

    var quic_client = try SolanaTpuQuic.init(allocator, .{});
    defer quic_client.deinit();

    try quic_client.sendTransaction("127.0.0.1", 9999, "ping");
}

test "tpu client quic send stub" {
    const allocator = std.testing.allocator;
    const enabled = std.process.getEnvVarOwned(allocator, "VEXOR_QUIC_STUB") catch return;
    defer allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;

    const client = try tpu_client.TpuClient.init(allocator, true, false, true, false, 0, true);
    defer client.deinit();
    client.setQuicTargetOverride(packet.SocketAddr.ipv4(.{ 127, 0, 0, 1 }, 9999));

    try client.sendTransaction("ping", 0);
}

fn encodeQuicVarInt(allocator: Allocator, value: usize) ![]u8 {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    if (value < 64) {
        buf[0] = @as(u8, @intCast(value & 0x3f));
        len = 1;
    } else if (value < 16384) {
        const v: u16 = @intCast(value);
        buf[0] = 0x40 | @as(u8, @intCast((v >> 8) & 0x3f));
        buf[1] = @as(u8, @intCast(v & 0xff));
        len = 2;
    } else if (value < (1 << 30)) {
        const v: u32 = @intCast(value);
        buf[0] = 0x80 | @as(u8, @intCast((v >> 24) & 0x3f));
        buf[1] = @as(u8, @intCast((v >> 16) & 0xff));
        buf[2] = @as(u8, @intCast((v >> 8) & 0xff));
        buf[3] = @as(u8, @intCast(v & 0xff));
        len = 4;
    } else {
        const v: u64 = @intCast(value);
        buf[0] = 0xc0 | @as(u8, @intCast((v >> 56) & 0x3f));
        buf[1] = @as(u8, @intCast((v >> 48) & 0xff));
        buf[2] = @as(u8, @intCast((v >> 40) & 0xff));
        buf[3] = @as(u8, @intCast((v >> 32) & 0xff));
        buf[4] = @as(u8, @intCast((v >> 24) & 0xff));
        buf[5] = @as(u8, @intCast((v >> 16) & 0xff));
        buf[6] = @as(u8, @intCast((v >> 8) & 0xff));
        buf[7] = @as(u8, @intCast(v & 0xff));
        len = 8;
    }

    const out = try allocator.alloc(u8, len);
    @memcpy(out, buf[0..len]);
    return out;
}

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
