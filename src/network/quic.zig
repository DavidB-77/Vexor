//! Vexor QUIC Transport
//!
//! QUIC/HTTP3 implementation for secure, low-latency communication.
//! Used for TPU (Transaction Processing Unit) connections.
//!
//! Features:
//! - TLS 1.3 encryption
//! - Zero-RTT connection resumption
//! - Multiplexed streams
//! - Flow control
//! - Connection migration
//! - MASQUE proxy support

const std = @import("std");
const packet = @import("packet.zig");
const socket = @import("socket.zig");
const tls13 = @import("tls13.zig");

/// QUIC version constants
pub const QUIC_VERSION_1: u32 = 0x00000001;
pub const QUIC_VERSION_2: u32 = 0x6b3343cf;

/// QUIC frame types
pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // 0x08 - 0x0f
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    connection_close_app = 0x1d,
    handshake_done = 0x1e,
    datagram = 0x30, // RFC 9221
};

/// QUIC packet types
pub const PacketType = enum(u2) {
    initial = 0,
    zero_rtt = 1,
    handshake = 2,
    retry = 3,
};

/// QUIC connection ID (up to 20 bytes)
pub const ConnectionId = struct {
    data: [20]u8,
    len: u8,
    
    pub fn generate() ConnectionId {
        var id = ConnectionId{ .data = undefined, .len = 8 };
        std.crypto.random.bytes(id.data[0..8]);
        return id;
    }
    
    pub fn slice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }
    
    pub fn eql(self: *const ConnectionId, other: *const ConnectionId) bool {
        if (self.len != other.len) return false;
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// QUIC connection state
pub const Connection = struct {
    allocator: std.mem.Allocator,
    
    /// Local connection ID
    local_cid: ConnectionId,
    
    /// Remote connection ID
    remote_cid: ConnectionId,
    
    /// Connection state
    state: State,
    
    /// Peer address
    peer_addr: packet.SocketAddr,
    
    /// Active streams
    streams: std.AutoHashMap(u64, *Stream),
    
    /// Next stream ID (client: odd for bidi, even for uni)
    next_bidi_stream_id: u64,
    next_uni_stream_id: u64,
    
    /// TLS state
    tls: TlsState,
    
    /// Flow control
    max_data_local: u64,
    max_data_remote: u64,
    bytes_sent: u64,
    bytes_received: u64,
    
    /// Packet numbers
    next_pkt_num: u64,
    largest_acked_pkt: u64,
    
    /// RTT estimation
    smoothed_rtt_ns: u64,
    rtt_var_ns: u64,
    min_rtt_ns: u64,
    
    /// Congestion control
    cwnd: u64,
    ssthresh: u64,
    bytes_in_flight: u64,
    
    /// Statistics
    stats: ConnectionStats,

    pub const State = enum {
        initial,
        handshake,
        connected,
        closing,
        draining,
        closed,
    };
    
    pub const ConnectionStats = struct {
        packets_sent: u64 = 0,
        packets_received: u64 = 0,
        packets_lost: u64 = 0,
        bytes_sent: u64 = 0,
        bytes_received: u64 = 0,
        streams_opened: u64 = 0,
        frames_sent: u64 = 0,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, peer_addr: packet.SocketAddr, is_server: bool) !*Self {
        const conn = try allocator.create(Self);
        conn.* = .{
            .allocator = allocator,
            .local_cid = ConnectionId.generate(),
            .remote_cid = ConnectionId{ .data = undefined, .len = 0 },
            .state = .initial,
            .peer_addr = peer_addr,
            .streams = std.AutoHashMap(u64, *Stream).init(allocator),
            .next_bidi_stream_id = if (is_server) 1 else 0, // Server: odd, Client: even
            .next_uni_stream_id = if (is_server) 3 else 2,
            .tls = TlsState.init(allocator),
            .max_data_local = 1024 * 1024, // 1MB initial
            .max_data_remote = 0,
            .bytes_sent = 0,
            .bytes_received = 0,
            .next_pkt_num = 0,
            .largest_acked_pkt = 0,
            .smoothed_rtt_ns = 333 * std.time.ns_per_ms, // 333ms initial
            .rtt_var_ns = 166 * std.time.ns_per_ms,
            .min_rtt_ns = std.math.maxInt(u64),
            .cwnd = 14720, // ~10 packets
            .ssthresh = std.math.maxInt(u64),
            .bytes_in_flight = 0,
            .stats = .{},
        };
        return conn;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.streams.valueIterator();
        while (iter.next()) |stream| {
            stream.*.deinit();
        }
        self.streams.deinit();
        self.allocator.destroy(self);
    }
    
    /// Open a new bidirectional stream
    pub fn openBidiStream(self: *Self) !*Stream {
        const stream_id = self.next_bidi_stream_id;
        self.next_bidi_stream_id += 4; // Increment by 4 for next stream of same type
        
        const stream = try Stream.init(self.allocator, self, stream_id);
        try self.streams.put(stream_id, stream);
        self.stats.streams_opened += 1;
        
        return stream;
    }
    
    /// Open a new unidirectional stream
    pub fn openUniStream(self: *Self) !*Stream {
        const stream_id = self.next_uni_stream_id;
        self.next_uni_stream_id += 4;
        
        const stream = try Stream.init(self.allocator, self, stream_id);
        try self.streams.put(stream_id, stream);
        self.stats.streams_opened += 1;
        
        return stream;
    }
    
    /// Send data on a stream
    pub fn send(self: *Self, stream_id: u64, data: []const u8) !void {
        const stream = self.streams.get(stream_id) orelse return error.StreamNotFound;
        try stream.send(data);
        self.bytes_sent += data.len;
        self.stats.bytes_sent += data.len;
    }
    
    /// Close connection gracefully
    pub fn close(self: *Self, error_code: u64, reason: []const u8) void {
        _ = error_code;
        _ = reason;
        self.state = .closing;
    }
    
    /// Update RTT estimate
    pub fn updateRtt(self: *Self, latest_rtt_ns: u64) void {
        if (self.min_rtt_ns > latest_rtt_ns) {
            self.min_rtt_ns = latest_rtt_ns;
        }
        
        // RFC 9002 RTT calculation
        const rtt_diff = if (self.smoothed_rtt_ns > latest_rtt_ns)
            self.smoothed_rtt_ns - latest_rtt_ns
        else
            latest_rtt_ns - self.smoothed_rtt_ns;
        
        self.rtt_var_ns = (3 * self.rtt_var_ns + rtt_diff) / 4;
        self.smoothed_rtt_ns = (7 * self.smoothed_rtt_ns + latest_rtt_ns) / 8;
    }
    
    /// Check if connection is open
    pub fn isOpen(self: *const Self) bool {
        return self.state == .connected;
    }
};

/// TLS 1.3 state for QUIC with real cryptographic operations
pub const TlsState = struct {
    allocator: std.mem.Allocator,
    handshake_complete: bool,
    early_data_accepted: bool,
    alpn: ?[]const u8,
    
    /// Key schedule for secret derivation
    key_schedule: tls13.KeySchedule,
    
    /// Current encryption level secrets
    initial_secrets: ?tls13.TrafficSecrets,
    handshake_secrets: ?tls13.TrafficSecrets,
    application_secrets: ?tls13.TrafficSecrets,
    
    /// Current cipher suite
    cipher_suite: tls13.CipherSuite,
    
    /// AEAD contexts for encryption/decryption
    client_aead: ?tls13.AeadContext,
    server_aead: ?tls13.AeadContext,
    
    /// Header protection keys
    client_hp: [16]u8,
    server_hp: [16]u8,
    
    /// X25519 key pair for ECDHE
    local_private_key: [32]u8,
    local_public_key: [32]u8,
    remote_public_key: ?[32]u8,
    
    /// Handshake state
    handshake_stage: HandshakeStage,
    
    pub const HandshakeStage = enum {
        initial,
        client_hello_sent,
        server_hello_received,
        encrypted_extensions_received,
        certificate_received,
        certificate_verify_received,
        finished_received,
        finished_sent,
        complete,
    };
    
    pub fn init(allocator: std.mem.Allocator) TlsState {
        // Generate X25519 key pair
        var private_key: [32]u8 = undefined;
        std.crypto.random.bytes(&private_key);
        
        const public_key = std.crypto.dh.X25519.recoverPublicKey(private_key) catch [_]u8{0} ** 32;
        
        return .{
            .allocator = allocator,
            .handshake_complete = false,
            .early_data_accepted = false,
            .alpn = null,
            .key_schedule = tls13.KeySchedule.init(),
            .initial_secrets = null,
            .handshake_secrets = null,
            .application_secrets = null,
            .cipher_suite = .TLS_AES_128_GCM_SHA256,
            .client_aead = null,
            .server_aead = null,
            .client_hp = [_]u8{0} ** 16,
            .server_hp = [_]u8{0} ** 16,
            .local_private_key = private_key,
            .local_public_key = public_key,
            .remote_public_key = null,
            .handshake_stage = .initial,
        };
    }
    
    /// Derive initial secrets from destination connection ID
    pub fn deriveInitialSecrets(self: *TlsState, dcid: []const u8) void {
        self.initial_secrets = tls13.deriveInitialSecrets(dcid);
        
        if (self.initial_secrets) |secrets| {
            self.client_aead = tls13.AeadContext.init(secrets.client, self.cipher_suite);
            self.server_aead = tls13.AeadContext.init(secrets.server, self.cipher_suite);
            self.client_hp = secrets.client.hp;
            self.server_hp = secrets.server.hp;
        }
    }
    
    /// Build ClientHello message
    pub fn buildClientHello(self: *TlsState, quic_params: []const u8) ![]u8 {
        var random: [32]u8 = undefined;
        std.crypto.random.bytes(&random);
        
        const cipher_suites = [_]tls13.CipherSuite{
            .TLS_AES_128_GCM_SHA256,
            .TLS_CHACHA20_POLY1305_SHA256,
        };
        
        const alpn_protos = [_][]const u8{"solana-tpu"};
        
        const client_hello = try tls13.buildClientHello(
            self.allocator,
            random,
            &[_]u8{}, // No session ID for QUIC
            &cipher_suites,
            &self.local_public_key,
            &alpn_protos,
            quic_params,
        );
        
        // Update transcript
        self.key_schedule.updateTranscript(client_hello);
        self.handshake_stage = .client_hello_sent;
        
        return client_hello;
    }
    
    /// Process ServerHello message
    pub fn processServerHello(self: *TlsState, data: []const u8) !void {
        // Update transcript with ServerHello
        self.key_schedule.updateTranscript(data);
        
        const server_hello = try tls13.parseServerHello(data);
        self.cipher_suite = server_hello.cipher_suite;
        
        // Store remote public key
        if (server_hello.key_share.len >= 32) {
            self.remote_public_key = server_hello.key_share[0..32].*;
        }
        
        // Compute shared secret using X25519
        if (self.remote_public_key) |remote_pk| {
            const shared_secret = std.crypto.dh.X25519.scalarmult(
                self.local_private_key,
                remote_pk,
            ) catch return error.KeyExchangeFailed;
            
            // Derive handshake secrets
            self.handshake_secrets = self.key_schedule.deriveHandshakeSecrets(&shared_secret);
            
            if (self.handshake_secrets) |secrets| {
                self.client_aead = tls13.AeadContext.init(secrets.client, self.cipher_suite);
                self.server_aead = tls13.AeadContext.init(secrets.server, self.cipher_suite);
                self.client_hp = secrets.client.hp;
                self.server_hp = secrets.server.hp;
            }
        }
        
        self.handshake_stage = .server_hello_received;
    }
    
    /// Process Finished message and derive application secrets
    pub fn processFinished(self: *TlsState, data: []const u8) !void {
        // Update transcript
        self.key_schedule.updateTranscript(data);
        
        // TODO: Verify Finished message
        
        // Derive application secrets
        self.application_secrets = self.key_schedule.deriveApplicationSecrets();
        
        if (self.application_secrets) |secrets| {
            self.client_aead = tls13.AeadContext.init(secrets.client, self.cipher_suite);
            self.server_aead = tls13.AeadContext.init(secrets.server, self.cipher_suite);
            self.client_hp = secrets.client.hp;
            self.server_hp = secrets.server.hp;
        }
        
        self.handshake_stage = .finished_received;
    }
    
    /// Build Finished message
    pub fn buildFinished(self: *TlsState) ![]u8 {
        // Derive finished key from client handshake secret
        var finished_key: [32]u8 = undefined;
        if (self.handshake_secrets) |secrets| {
            tls13.hkdfExpandLabel(&secrets.client.key, "finished", "", 32, &finished_key);
        } else {
            return error.NoHandshakeSecrets;
        }
        
        const transcript_hash = self.key_schedule.getTranscriptHash();
        const finished_msg = try tls13.buildFinished(self.allocator, finished_key, transcript_hash);
        
        // Update transcript
        self.key_schedule.updateTranscript(finished_msg);
        
        self.handshake_stage = .finished_sent;
        self.handshake_complete = true;
        
        return finished_msg;
    }
    
    /// Encrypt a QUIC packet payload
    pub fn encryptPacket(
        self: *const TlsState,
        is_client: bool,
        packet_number: u64,
        header: []const u8,
        plaintext: []const u8,
        out_ciphertext: []u8,
        out_tag: *[16]u8,
    ) !void {
        const aead = if (is_client) self.client_aead else self.server_aead;
        if (aead) |ctx| {
            ctx.encrypt(packet_number, header, plaintext, out_ciphertext, out_tag);
        } else {
            return error.NoEncryptionKeys;
        }
    }
    
    /// Decrypt a QUIC packet payload
    pub fn decryptPacket(
        self: *const TlsState,
        is_from_client: bool,
        packet_number: u64,
        header: []const u8,
        ciphertext: []const u8,
        tag: [16]u8,
        out_plaintext: []u8,
    ) !void {
        // When receiving from client, use client keys; when receiving from server, use server keys
        const aead = if (is_from_client) self.client_aead else self.server_aead;
        if (aead) |ctx| {
            try ctx.decrypt(packet_number, header, ciphertext, tag, out_plaintext);
        } else {
            return error.NoDecryptionKeys;
        }
    }
    
    /// Apply header protection
    pub fn protectHeader(self: *const TlsState, is_client: bool, header: []u8, pn_offset: usize, pn_length: usize, sample: [16]u8) void {
        const hp_key = if (is_client) self.client_hp else self.server_hp;
        tls13.applyHeaderProtection(hp_key, header, pn_offset, pn_length, sample);
    }
    
    /// Remove header protection
    pub fn unprotectHeader(self: *const TlsState, is_from_client: bool, header: []u8, pn_offset: usize, sample: [16]u8) usize {
        const hp_key = if (is_from_client) self.client_hp else self.server_hp;
        return tls13.removeHeaderProtection(hp_key, header, pn_offset, sample);
    }
};

/// QUIC stream for bidirectional communication
pub const Stream = struct {
    id: u64,
    conn: *Connection,
    state: State,
    recv_buffer: std.ArrayList(u8),
    send_buffer: std.ArrayList(u8),
    recv_offset: u64,
    send_offset: u64,
    max_stream_data_local: u64,
    max_stream_data_remote: u64,
    
    /// Flow control blocked
    blocked: bool,
    
    /// FIN sent/received
    fin_sent: bool,
    fin_received: bool,

    pub const State = enum {
        open,
        half_closed_local,
        half_closed_remote,
        closed,
        reset,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, conn: *Connection, id: u64) !*Self {
        const stream = try allocator.create(Self);
        stream.* = .{
            .id = id,
            .conn = conn,
            .state = .open,
            .recv_buffer = std.ArrayList(u8).init(allocator),
            .send_buffer = std.ArrayList(u8).init(allocator),
            .recv_offset = 0,
            .send_offset = 0,
            .max_stream_data_local = 256 * 1024, // 256KB
            .max_stream_data_remote = 0,
            .blocked = false,
            .fin_sent = false,
            .fin_received = false,
        };
        return stream;
    }

    pub fn deinit(self: *Self) void {
        self.recv_buffer.deinit();
        self.send_buffer.deinit();
        self.conn.allocator.destroy(self);
    }

    pub fn send(self: *Self, data: []const u8) !void {
        if (self.state == .half_closed_local or self.state == .closed) {
            return error.StreamClosed;
        }
        try self.send_buffer.appendSlice(data);
    }
    
    pub fn sendFin(self: *Self) void {
        self.fin_sent = true;
        if (self.state == .open) {
            self.state = .half_closed_local;
        } else if (self.state == .half_closed_remote) {
            self.state = .closed;
        }
    }

    pub fn recv(self: *Self, buf: []u8) !usize {
        const len = @min(buf.len, self.recv_buffer.items.len);
        @memcpy(buf[0..len], self.recv_buffer.items[0..len]);

        // Remove read data from buffer
        const remaining = self.recv_buffer.items.len - len;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining], self.recv_buffer.items[len..]);
        }
        self.recv_buffer.shrinkRetainingCapacity(remaining);
        self.recv_offset += len;

        return len;
    }
    
    pub fn appendRecvData(self: *Self, data: []const u8) !void {
        try self.recv_buffer.appendSlice(data);
    }
    
    pub fn hasPendingData(self: *const Self) bool {
        return self.send_buffer.items.len > 0;
    }
    
    pub fn isReadable(self: *const Self) bool {
        return self.recv_buffer.items.len > 0 or self.fin_received;
    }
    
    pub fn isWritable(self: *const Self) bool {
        return self.state == .open or self.state == .half_closed_remote;
    }
};

/// QUIC endpoint managing multiple connections
pub const Endpoint = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoHashMap(u64, *Connection),
    connections_by_addr: std.AutoHashMap(u64, *Connection), // peer_addr hash -> connection
    bind_addr: packet.SocketAddr,
    is_server: bool,
    sock: ?socket.UdpSocket,
    config: EndpointConfig,
    stats: EndpointStats,

    const Self = @This();
    
    pub const EndpointConfig = struct {
        max_connections: usize = 10000,
        max_streams_per_connection: usize = 100,
        initial_max_data: u64 = 10 * 1024 * 1024, // 10MB
        initial_max_stream_data: u64 = 1024 * 1024, // 1MB
        max_idle_timeout_ms: u64 = 30000, // 30 seconds
        alpn: []const u8 = "solana-tpu",
    };
    
    pub const EndpointStats = struct {
        connections_total: u64 = 0,
        connections_active: u64 = 0,
        packets_sent: u64 = 0,
        packets_received: u64 = 0,
        bytes_sent: u64 = 0,
        bytes_received: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, bind_addr: packet.SocketAddr, is_server: bool, config: EndpointConfig) !*Self {
        const endpoint = try allocator.create(Self);
        endpoint.* = .{
            .allocator = allocator,
            .connections = std.AutoHashMap(u64, *Connection).init(allocator),
            .connections_by_addr = std.AutoHashMap(u64, *Connection).init(allocator),
            .bind_addr = bind_addr,
            .is_server = is_server,
            .sock = null,
            .config = config,
            .stats = .{},
        };
        return endpoint;
    }

    pub fn deinit(self: *Self) void {
        if (self.sock) |*s| {
            s.deinit();
        }
        var iter = self.connections.valueIterator();
        while (iter.next()) |conn| {
            conn.*.deinit();
        }
        self.connections.deinit();
        self.connections_by_addr.deinit();
        self.allocator.destroy(self);
    }
    
    /// Bind the endpoint to its address
    pub fn bind(self: *Self) !void {
        var sock = try socket.UdpSocket.init();
        errdefer sock.deinit();
        try sock.bindPort(self.bind_addr.port());
        self.sock = sock;
    }

    /// Connect to a peer (client mode)
    pub fn connect(self: *Self, peer_addr: packet.SocketAddr) !*Connection {
        if (self.connections.count() >= self.config.max_connections) {
            return error.TooManyConnections;
        }
        
        const conn = try Connection.init(self.allocator, peer_addr, false);
        errdefer conn.deinit();
        
        // Hash the connection ID for lookup
        const cid_hash = hashConnectionId(&conn.local_cid);
        try self.connections.put(cid_hash, conn);
        
        // Also index by peer address
        const addr_hash = hashSocketAddr(&peer_addr);
        try self.connections_by_addr.put(addr_hash, conn);
        
        self.stats.connections_total += 1;
        self.stats.connections_active += 1;
        
        // Send initial packet
        try self.sendInitialPacket(conn);
        
        return conn;
    }
    
    /// Accept a new connection (server mode)
    fn acceptConnection(self: *Self, peer_addr: packet.SocketAddr, remote_cid: ConnectionId) !*Connection {
        if (self.connections.count() >= self.config.max_connections) {
            return error.TooManyConnections;
        }
        
        const conn = try Connection.init(self.allocator, peer_addr, true);
        conn.remote_cid = remote_cid;
        
        const cid_hash = hashConnectionId(&conn.local_cid);
        try self.connections.put(cid_hash, conn);
        
        const addr_hash = hashSocketAddr(&peer_addr);
        try self.connections_by_addr.put(addr_hash, conn);
        
        self.stats.connections_total += 1;
        self.stats.connections_active += 1;
        
        return conn;
    }
    
    /// Send initial QUIC packet with TLS ClientHello
    fn sendInitialPacket(self: *Self, conn: *Connection) !void {
        if (self.sock == null) return error.NotBound;
        
        // Derive initial secrets from destination connection ID
        conn.tls.deriveInitialSecrets(conn.remote_cid.slice());
        
        var pkt = packet.Packet.init();
        
        // Build QUIC Initial packet header
        var header_offset: usize = 0;
        
        // Long header form + Initial packet type + reserved bits + packet number length (2 bytes)
        pkt.data[header_offset] = 0xc3; // Long header, Initial, 4-byte pkt num
        header_offset += 1;
        
        // Version
        std.mem.writeInt(u32, pkt.data[header_offset..][0..4], QUIC_VERSION_1, .big);
        header_offset += 4;
        
        // Destination CID
        pkt.data[header_offset] = conn.remote_cid.len;
        header_offset += 1;
        if (conn.remote_cid.len > 0) {
            @memcpy(pkt.data[header_offset..][0..conn.remote_cid.len], conn.remote_cid.slice());
            header_offset += conn.remote_cid.len;
        }
        
        // Source CID
        pkt.data[header_offset] = conn.local_cid.len;
        header_offset += 1;
        @memcpy(pkt.data[header_offset..][0..conn.local_cid.len], conn.local_cid.slice());
        header_offset += conn.local_cid.len;
        
        // Token length (empty for client initial)
        pkt.data[header_offset] = 0;
        header_offset += 1;
        
        // Build CRYPTO frame with TLS ClientHello
        var plaintext_buf: [1200]u8 = undefined;
        var plaintext_offset: usize = 0;
        
        // CRYPTO frame type
        plaintext_buf[plaintext_offset] = @intFromEnum(FrameType.crypto);
        plaintext_offset += 1;
        
        // CRYPTO frame offset (variable-length integer = 0)
        plaintext_buf[plaintext_offset] = 0;
        plaintext_offset += 1;
        
        // Build QUIC transport parameters
        var transport_params = tls13.TransportParameters{};
        @memcpy(transport_params.original_dcid.?[0..conn.remote_cid.len], conn.remote_cid.slice());
        transport_params.original_dcid_len = conn.remote_cid.len;
        
        const quic_params = try transport_params.encode(self.allocator);
        defer self.allocator.free(quic_params);
        
        // Build ClientHello
        const client_hello = try conn.tls.buildClientHello(quic_params);
        defer self.allocator.free(client_hello);
        
        // CRYPTO frame length (variable-length integer)
        if (client_hello.len < 64) {
            plaintext_buf[plaintext_offset] = @intCast(client_hello.len);
            plaintext_offset += 1;
        } else {
            plaintext_buf[plaintext_offset] = @intCast(0x40 | ((client_hello.len >> 8) & 0x3F));
            plaintext_offset += 1;
            plaintext_buf[plaintext_offset] = @intCast(client_hello.len & 0xFF);
            plaintext_offset += 1;
        }
        
        // ClientHello data
        @memcpy(plaintext_buf[plaintext_offset..][0..client_hello.len], client_hello);
        plaintext_offset += client_hello.len;
        
        // Add PADDING to reach minimum size (1200 bytes for Initial)
        const min_payload = 1200 - header_offset - 20; // Reserve space for length, pkt num, tag
        while (plaintext_offset < min_payload) {
            plaintext_buf[plaintext_offset] = 0; // PADDING frame
            plaintext_offset += 1;
        }
        
        // Calculate payload length (including 4-byte pkt num + ciphertext + 16-byte auth tag)
        const payload_len = 4 + plaintext_offset + 16;
        
        // Write payload length as variable-length integer (2 bytes for values up to 16383)
        pkt.data[header_offset] = @intCast(0x40 | ((payload_len >> 8) & 0x3F));
        header_offset += 1;
        pkt.data[header_offset] = @intCast(payload_len & 0xFF);
        header_offset += 1;
        
        // Record packet number offset for header protection
        const pn_offset = header_offset;
        
        // Packet number (4 bytes)
        std.mem.writeInt(u32, pkt.data[header_offset..][0..4], @intCast(conn.next_pkt_num), .big);
        header_offset += 4;
        
        // Encrypt the payload
        const header = pkt.data[0..header_offset];
        var ciphertext: [1200]u8 = undefined;
        var auth_tag: [16]u8 = undefined;
        
        try conn.tls.encryptPacket(
            true, // is_client
            conn.next_pkt_num,
            header,
            plaintext_buf[0..plaintext_offset],
            ciphertext[0..plaintext_offset],
            &auth_tag,
        );
        
        // Copy ciphertext and tag to packet
        @memcpy(pkt.data[header_offset..][0..plaintext_offset], ciphertext[0..plaintext_offset]);
        header_offset += plaintext_offset;
        @memcpy(pkt.data[header_offset..][0..16], &auth_tag);
        header_offset += 16;
        
        // Apply header protection
        // Sample is taken from 4 bytes after the packet number
        var sample: [16]u8 = undefined;
        @memcpy(&sample, pkt.data[pn_offset + 4 ..][0..16]);
        
        conn.tls.protectHeader(true, pkt.data[0..header_offset], pn_offset, 4, sample);
        
        conn.next_pkt_num += 1;
        
        pkt.len = @intCast(header_offset);
        pkt.src_addr = conn.peer_addr;
        
        _ = try self.sock.?.send(&pkt);
        conn.stats.packets_sent += 1;
        self.stats.packets_sent += 1;
    }

    /// Process incoming packet
    pub fn processPacket(self: *Self, pkt: *const packet.Packet) !void {
        if (pkt.len < 5) return; // Too short
        
        self.stats.packets_received += 1;
        self.stats.bytes_received += pkt.len;
        
        // Parse header
        const first_byte = pkt.data[0];
        const is_long_header = (first_byte & 0x80) != 0;
        
        if (is_long_header) {
            try self.processLongHeaderPacket(pkt);
        } else {
            try self.processShortHeaderPacket(pkt);
        }
    }
    
    fn processLongHeaderPacket(self: *Self, pkt: *const packet.Packet) !void {
        var offset: usize = 1;
        
        // Version
        const version = std.mem.readInt(u32, pkt.data[offset..][0..4], .big);
        offset += 4;
        
        if (version != QUIC_VERSION_1 and version != QUIC_VERSION_2) {
            // Version negotiation needed
            return;
        }
        
        // Destination CID
        const dcid_len = pkt.data[offset];
        offset += 1;
        if (dcid_len > 20 or offset + dcid_len > pkt.len) return;
        var dcid = ConnectionId{ .data = undefined, .len = dcid_len };
        @memcpy(dcid.data[0..dcid_len], pkt.data[offset..][0..dcid_len]);
        offset += dcid_len;
        
        // Source CID
        const scid_len = pkt.data[offset];
        offset += 1;
        if (scid_len > 20 or offset + scid_len > pkt.len) return;
        var scid = ConnectionId{ .data = undefined, .len = scid_len };
        @memcpy(scid.data[0..scid_len], pkt.data[offset..][0..scid_len]);
        offset += scid_len;
        
        // Find or create connection
        const cid_hash = hashConnectionId(&dcid);
        var conn = self.connections.get(cid_hash);
        
        if (conn == null and self.is_server) {
            // New connection (server accepting)
            conn = try self.acceptConnection(pkt.src_addr, scid);
        }
        
        if (conn) |c| {
            c.stats.packets_received += 1;
            // Process frames
            try self.processFrames(c, pkt.data[offset..pkt.len]);
        }
    }
    
    fn processShortHeaderPacket(self: *Self, pkt: *const packet.Packet) !void {
        // Short header: [flags(1) | dcid(variable) | packet_num(1-4) | payload]
        // For short header, we need to know the DCID length from the connection
        
        // Try to find connection by peer address
        const addr_hash = hashSocketAddr(&pkt.src_addr);
        const conn = self.connections_by_addr.get(addr_hash) orelse return;
        
        conn.stats.packets_received += 1;
        
        // Process payload (skip header)
        const header_len = 1 + conn.local_cid.len + 1; // simplified
        if (header_len >= pkt.len) return;
        
        try self.processFrames(conn, pkt.data[header_len..pkt.len]);
    }
    
    fn processFrames(self: *Self, conn: *Connection, payload: []const u8) !void {
        var offset: usize = 0;
        
        while (offset < payload.len) {
            const frame_type = payload[offset];
            offset += 1;
            
            switch (frame_type) {
                @intFromEnum(FrameType.padding) => {
                    // Skip padding
                    continue;
                },
                @intFromEnum(FrameType.ping) => {
                    // Ping - just acknowledge
                    continue;
                },
                @intFromEnum(FrameType.ack), @intFromEnum(FrameType.ack_ecn) => {
                    // Process ACK
                    // Skip for now (simplified)
                    break;
                },
                @intFromEnum(FrameType.crypto) => {
                    // CRYPTO frame (TLS handshake data)
                    if (conn.state == .initial) {
                        conn.state = .handshake;
                    }
                    // Process TLS data (simplified)
                    break;
                },
                @intFromEnum(FrameType.handshake_done) => {
                    conn.state = .connected;
                    conn.tls.handshake_complete = true;
                },
                @intFromEnum(FrameType.stream)...(@intFromEnum(FrameType.stream) + 7) => {
                    // STREAM frame
                    try self.processStreamFrame(conn, frame_type, payload[offset..]);
                    break;
                },
                @intFromEnum(FrameType.connection_close), @intFromEnum(FrameType.connection_close_app) => {
                    conn.state = .draining;
                    break;
                },
                else => {
                    // Unknown frame type
                    break;
                },
            }
        }
    }
    
    fn processStreamFrame(self: *Self, conn: *Connection, frame_type: u8, data: []const u8) !void {
        _ = self;
        if (data.len < 8) return;
        
        // Parse stream frame
        const has_offset = (frame_type & 0x04) != 0;
        const has_length = (frame_type & 0x02) != 0;
        const has_fin = (frame_type & 0x01) != 0;
        _ = has_offset;
        _ = has_length;
        
        var offset: usize = 0;
        
        // Stream ID (variable length integer - simplified to u64)
        const stream_id = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;
        
        // Get or create stream
        var stream = conn.streams.get(stream_id);
        if (stream == null) {
            stream = try Stream.init(conn.allocator, conn, stream_id);
            try conn.streams.put(stream_id, stream.?);
        }
        
        // Append data
        if (offset < data.len) {
            try stream.?.appendRecvData(data[offset..]);
        }
        
        if (has_fin) {
            stream.?.fin_received = true;
            if (stream.?.state == .open) {
                stream.?.state = .half_closed_remote;
            } else if (stream.?.state == .half_closed_local) {
                stream.?.state = .closed;
            }
        }
    }
    
    /// Poll for events
    pub fn poll(self: *Self) !void {
        if (self.sock == null) return;
        
        // Receive packets
        var batch = try packet.PacketBatch.init(self.allocator, 64);
        defer batch.deinit();
        
        _ = self.sock.?.recvBatch(&batch) catch return;
        
        for (batch.slice()) |*pkt| {
            try self.processPacket(pkt);
        }
    }
    
    /// Get connection by ID
    pub fn getConnection(self: *Self, cid: *const ConnectionId) ?*Connection {
        return self.connections.get(hashConnectionId(cid));
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) EndpointStats {
        return self.stats;
    }
};

fn hashConnectionId(cid: *const ConnectionId) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(cid.slice());
    return h.final();
}

fn hashSocketAddr(addr: *const packet.SocketAddr) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(addr));
    return h.final();
}

/// QUIC client for TPU connections
pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    endpoint: *Endpoint,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const client = try allocator.create(Self);
        const bind_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, 0);
        client.* = .{
            .allocator = allocator,
            .endpoint = try Endpoint.init(allocator, bind_addr, false, .{}),
        };
        try client.endpoint.bind();
        return client;
    }
    
    pub fn deinit(self: *Self) void {
        self.endpoint.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn connect(self: *Self, host: []const u8, port: u16) !*Connection {
        // Parse IP
        const ip = std.net.Address.parseIp4(host, port) catch return error.InvalidAddress;
        const addr = packet.SocketAddr.ipv4(
            @as([4]u8, @bitCast(ip.in.sa.addr)),
            port,
        );
        return self.endpoint.connect(addr);
    }
    
    pub fn poll(self: *Self) !void {
        try self.endpoint.poll();
    }
};

/// QUIC server for TPU
pub const QuicServer = struct {
    allocator: std.mem.Allocator,
    endpoint: *Endpoint,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, port: u16, config: Endpoint.EndpointConfig) !*Self {
        const server = try allocator.create(Self);
        const bind_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, port);
        server.* = .{
            .allocator = allocator,
            .endpoint = try Endpoint.init(allocator, bind_addr, true, config),
        };
        try server.endpoint.bind();
        return server;
    }
    
    pub fn deinit(self: *Self) void {
        self.endpoint.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn poll(self: *Self) !void {
        try self.endpoint.poll();
    }
    
    pub fn getStats(self: *const Self) Endpoint.EndpointStats {
        return self.endpoint.getStats();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// LOSS DETECTION AND CONGESTION CONTROL (RFC 9002)
// ═══════════════════════════════════════════════════════════════════════════════

/// Sent packet metadata for loss detection and RTT measurement
/// Optimized: Fixed-size frame storage, no allocations on hot path
pub const SentPacket = struct {
    packet_number: u64,
    time_sent: i64, // nanoseconds since epoch
    ack_eliciting: bool,
    in_flight: bool,
    size: u32, // Changed to u32 (packets are < 64KB)
    encryption_level: EncryptionLevel,
    /// Fixed-size frame storage (avoids ArrayList allocation)
    frames: [MAX_FRAMES_PER_PACKET]FrameType,
    frame_count: u8,

    pub const EncryptionLevel = enum(u8) {
        initial = 0,
        handshake = 1,
        application = 2,
    };
    
    /// Maximum frames we track per packet (typically 1-3)
    pub const MAX_FRAMES_PER_PACKET = 8;
    
    pub fn addFrame(self: *SentPacket, frame: FrameType) void {
        if (self.frame_count < MAX_FRAMES_PER_PACKET) {
            self.frames[self.frame_count] = frame;
            self.frame_count += 1;
        }
    }
    
    pub fn getFrames(self: *const SentPacket) []const FrameType {
        return self.frames[0..self.frame_count];
    }
};

/// Loss detection state per connection
/// Optimized: Fixed-size ring buffer for lost packets, no allocations on hot path
pub const LossDetector = struct {
    allocator: std.mem.Allocator,
    
    /// Sent packets awaiting acknowledgment (keyed by packet number)
    sent_packets: std.AutoHashMap(u64, SentPacket),
    
    /// Largest acknowledged packet number
    largest_acked_packet: ?u64,
    
    /// Time of the most recent ack-eliciting packet sent
    time_of_last_ack_eliciting_packet: i64,
    
    /// Loss detection timer
    loss_time: ?i64,
    
    /// Number of times PTO has been triggered without receiving an ack
    pto_count: u32,
    
    /// RTT measurements
    latest_rtt: u64,
    min_rtt: u64,
    smoothed_rtt: u64,
    rttvar: u64,
    
    /// Fixed-size ring buffer for lost packet numbers (avoids allocation)
    lost_packets_ring: [MAX_LOST_PACKETS]u64,
    lost_count: u32,
    
    /// Cached timestamp to avoid syscalls
    cached_time: i64,
    
    /// Constants (RFC 9002) - using fixed-point arithmetic
    pub const kPacketThreshold: u32 = 3;
    /// Time threshold as fixed-point: 9/8 = 1.125 = 1125/1000
    pub const kTimeThresholdNum: u64 = 9;
    pub const kTimeThresholdDen: u64 = 8;
    pub const kGranularity: u64 = 1_000_000; // 1ms in nanoseconds
    pub const kInitialRtt: u64 = 333_000_000; // 333ms in nanoseconds
    
    /// Maximum lost packets tracked per ACK (ring buffer size)
    pub const MAX_LOST_PACKETS = 256;
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sent_packets = std.AutoHashMap(u64, SentPacket).init(allocator),
            .largest_acked_packet = null,
            .time_of_last_ack_eliciting_packet = 0,
            .loss_time = null,
            .pto_count = 0,
            .latest_rtt = 0,
            .min_rtt = std.math.maxInt(u64),
            .smoothed_rtt = 333_000_000, // Initial 333ms
            .rttvar = 166_000_000, // Initial 166ms
            .lost_packets_ring = undefined,
            .lost_count = 0,
            .cached_time = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // No frame cleanup needed - SentPacket uses fixed array
        self.sent_packets.deinit();
    }
    
    /// Called when a packet is sent
    pub fn onPacketSent(
        self: *Self,
        packet_number: u64,
        ack_eliciting: bool,
        in_flight: bool,
        size: u32,
        encryption_level: SentPacket.EncryptionLevel,
    ) !void {
        const now = std.time.nanoTimestamp();
        self.cached_time = now;
        
        const sent_pkt = SentPacket{
            .packet_number = packet_number,
            .time_sent = now,
            .ack_eliciting = ack_eliciting,
            .in_flight = in_flight,
            .size = size,
            .encryption_level = encryption_level,
            .frames = undefined,
            .frame_count = 0,
        };
        
        try self.sent_packets.put(packet_number, sent_pkt);
        
        if (ack_eliciting) {
            self.time_of_last_ack_eliciting_packet = now;
        }
    }
    
    /// Called when an ACK frame is received
    /// Returns slice of lost packet numbers from internal ring buffer
    pub fn onAckReceived(
        self: *Self,
        largest_acked: u64,
        ack_delay: u64,
        ack_ranges: []const AckRange,
        congestion: *CongestionController,
    ) []const u64 {
        // Reset lost packet count
        self.lost_count = 0;
        
        // Update largest acked
        if (self.largest_acked_packet == null or largest_acked > self.largest_acked_packet.?) {
            self.largest_acked_packet = largest_acked;
        }
        
        // Get current time once (avoid multiple syscalls)
        const now = std.time.nanoTimestamp();
        self.cached_time = now;
        
        // Process newly acknowledged packets
        var newly_acked_bytes: u64 = 0;
        for (ack_ranges) |range| {
            var pn = range.start;
            while (pn <= range.end) : (pn += 1) {
                if (self.sent_packets.fetchRemove(pn)) |kv| {
                    const sent_pkt = kv.value;
                    
                    // Update RTT (only for largest acked to get accurate sample)
                    if (pn == largest_acked) {
                        const rtt_sample = @as(u64, @intCast(now - sent_pkt.time_sent));
                        self.updateRtt(rtt_sample, ack_delay);
                    }
                    
                    if (sent_pkt.in_flight) {
                        newly_acked_bytes += sent_pkt.size;
                    }
                    // No frames.deinit() needed - fixed array
                }
            }
        }
        
        // Update congestion controller
        if (newly_acked_bytes > 0) {
            congestion.onPacketsAcked(newly_acked_bytes);
        }
        
        // Detect lost packets using fixed-point arithmetic (no floats!)
        // loss_delay = max(latest_rtt * 9/8, kGranularity)
        const loss_delay = @max(
            (self.latest_rtt * kTimeThresholdNum) / kTimeThresholdDen,
            kGranularity,
        );
        
        const loss_time = now - @as(i64, @intCast(loss_delay));
        
        var iter = self.sent_packets.iterator();
        while (iter.next()) |entry| {
            const pkt = entry.value_ptr.*;
            
            // Packet is lost if:
            // 1. It's older than the packet threshold
            // 2. It's been outstanding longer than the time threshold
            const packet_threshold_exceeded = self.largest_acked_packet != null and
                pkt.packet_number + kPacketThreshold <= self.largest_acked_packet.?;
            const time_threshold_exceeded = pkt.time_sent <= loss_time;
            
            if (packet_threshold_exceeded or time_threshold_exceeded) {
                if (self.lost_count < MAX_LOST_PACKETS) {
                    self.lost_packets_ring[self.lost_count] = pkt.packet_number;
                    self.lost_count += 1;
                }
            }
        }
        
        // Remove lost packets and update congestion
        for (self.lost_packets_ring[0..self.lost_count]) |pn| {
            if (self.sent_packets.fetchRemove(pn)) |kv| {
                const sent_pkt = kv.value;
                if (sent_pkt.in_flight) {
                    congestion.onPacketLost(sent_pkt.size);
                }
            }
        }
        
        self.pto_count = 0;
        
        return self.lost_packets_ring[0..self.lost_count];
    }
    
    /// Update RTT estimates (RFC 9002 Section 5) - all integer arithmetic
    fn updateRtt(self: *Self, rtt_sample: u64, ack_delay: u64) void {
        self.latest_rtt = rtt_sample;
        
        if (rtt_sample < self.min_rtt) {
            self.min_rtt = rtt_sample;
        }
        
        // Adjust for ack delay
        var adjusted_rtt = rtt_sample;
        if (rtt_sample >= self.min_rtt + ack_delay) {
            adjusted_rtt = rtt_sample - ack_delay;
        }
        
        if (self.smoothed_rtt == kInitialRtt) {
            // First RTT sample
            self.smoothed_rtt = adjusted_rtt;
            self.rttvar = adjusted_rtt >> 1; // Divide by 2
        } else {
            // Subsequent samples (EWMA) - all integer arithmetic
            // rttvar = 3/4 * rttvar + 1/4 * |srtt - rtt|
            // srtt = 7/8 * srtt + 1/8 * rtt
            const rtt_diff = if (self.smoothed_rtt > adjusted_rtt)
                self.smoothed_rtt - adjusted_rtt
            else
                adjusted_rtt - self.smoothed_rtt;
            
            self.rttvar = (3 * self.rttvar + rtt_diff) >> 2; // Divide by 4
            self.smoothed_rtt = (7 * self.smoothed_rtt + adjusted_rtt) >> 3; // Divide by 8
        }
    }
    
    /// Get the Probe Timeout (PTO) - using bit shifts instead of pow
    pub fn getPto(self: *const Self) u64 {
        // PTO = smoothed_rtt + max(4*rttvar, kGranularity)
        var pto = self.smoothed_rtt + @max(self.rttvar << 2, kGranularity);
        // Multiply by 2^pto_count using shift
        pto = pto << @min(self.pto_count, 10); // Cap at 2^10 to prevent overflow
        return pto;
    }
    
    /// Called when PTO timer fires
    pub fn onPtoTimeout(self: *Self) void {
        self.pto_count += 1;
    }
    
    /// Get cached timestamp (use instead of syscall when precision isn't critical)
    pub fn getCachedTime(self: *const Self) i64 {
        return self.cached_time;
    }
};

/// ACK range for loss detection
pub const AckRange = struct {
    start: u64,
    end: u64,
};

/// Congestion controller (NewReno-style, RFC 9002)
/// Optimized: All fixed-point arithmetic, no floating point operations
pub const CongestionController = struct {
    /// Congestion window in bytes
    cwnd: u64,
    
    /// Slow start threshold
    ssthresh: u64,
    
    /// Bytes currently in flight
    bytes_in_flight: u64,
    
    /// Recovery state
    recovery_start_time: ?i64,
    
    /// Congestion event occurred
    congestion_recovery_start_time: ?i64,
    
    /// ECN-CE counter for this path
    ecn_ce_counters: u64,
    
    /// Cached timestamp to avoid syscalls
    cached_time: i64,
    
    /// Constants - all compile-time known, no floats
    pub const kInitialWindow: u64 = 14720; // ~10 packets
    pub const kMinimumWindow: u64 = 2 * 1200; // 2 full-size packets
    pub const kMaxSegmentSize: u64 = 1200; // QUIC max payload
    pub const kPersistentCongestionThreshold: u32 = 3;
    
    const Self = @This();
    
    pub fn init() Self {
        return .{
            .cwnd = kInitialWindow,
            .ssthresh = std.math.maxInt(u64),
            .bytes_in_flight = 0,
            .recovery_start_time = null,
            .congestion_recovery_start_time = null,
            .ecn_ce_counters = 0,
            .cached_time = 0,
        };
    }
    
    /// Check if we can send more data (inline for hot path)
    pub inline fn canSend(self: *const Self, bytes: u64) bool {
        return self.bytes_in_flight + bytes <= self.cwnd;
    }
    
    /// Get available window space
    pub inline fn availableWindow(self: *const Self) u64 {
        return if (self.cwnd > self.bytes_in_flight)
            self.cwnd - self.bytes_in_flight
        else
            0;
    }
    
    /// Called when a packet is sent
    pub inline fn onPacketSent(self: *Self, bytes: u64) void {
        self.bytes_in_flight +|= bytes; // Saturating add
    }
    
    /// Called when packets are acknowledged
    pub fn onPacketsAcked(self: *Self, bytes_acked: u64) void {
        // Saturating subtraction
        self.bytes_in_flight = if (self.bytes_in_flight > bytes_acked)
            self.bytes_in_flight - bytes_acked
        else
            0;
        
        // Don't increase cwnd during recovery
        if (self.congestion_recovery_start_time != null) {
            return;
        }
        
        if (self.cwnd < self.ssthresh) {
            // Slow start: cwnd += bytes_acked (additive increase)
            self.cwnd +|= bytes_acked; // Saturating add
        } else {
            // Congestion avoidance: cwnd += MSS * bytes_acked / cwnd
            // This approximates cwnd += MSS per RTT
            const increment = @max(1, (kMaxSegmentSize * bytes_acked) / self.cwnd);
            self.cwnd +|= increment;
        }
    }
    
    /// Called when a packet is lost
    /// Uses bit shift instead of float multiplication (cwnd * 0.5 = cwnd >> 1)
    pub fn onPacketLost(self: *Self, bytes_lost: u32) void {
        // Saturating subtraction
        self.bytes_in_flight = if (self.bytes_in_flight > bytes_lost)
            self.bytes_in_flight - bytes_lost
        else
            0;
        
        const now = std.time.nanoTimestamp();
        self.cached_time = now;
        
        // Enter recovery if not already in recovery
        if (self.congestion_recovery_start_time == null or
            now > self.congestion_recovery_start_time.?)
        {
            self.congestion_recovery_start_time = now;
            
            // Reduce cwnd by half using bit shift (equivalent to * 0.5)
            // cwnd = max(cwnd >> 1, kMinimumWindow)
            self.cwnd = @max(self.cwnd >> 1, kMinimumWindow);
            self.ssthresh = self.cwnd;
        }
    }
    
    /// Called on ECN-CE (Congestion Experienced)
    /// Uses same fixed-point reduction as packet loss
    pub fn onEcnCe(self: *Self) void {
        self.ecn_ce_counters += 1;
        
        const now = std.time.nanoTimestamp();
        self.cached_time = now;
        
        if (self.congestion_recovery_start_time == null or
            now > self.congestion_recovery_start_time.?)
        {
            self.congestion_recovery_start_time = now;
            // Reduce cwnd by half using bit shift
            self.cwnd = @max(self.cwnd >> 1, kMinimumWindow);
            self.ssthresh = self.cwnd;
        }
    }
    
    /// Reset after persistent congestion
    pub fn onPersistentCongestion(self: *Self) void {
        self.cwnd = kMinimumWindow;
        self.congestion_recovery_start_time = null;
    }
    
    /// Exit recovery mode (called after recovery period ends)
    pub fn exitRecovery(self: *Self) void {
        self.congestion_recovery_start_time = null;
    }
    
    /// Get current statistics
    pub fn getStats(self: *const Self) CongestionStats {
        return .{
            .cwnd = self.cwnd,
            .ssthresh = self.ssthresh,
            .bytes_in_flight = self.bytes_in_flight,
            .in_recovery = self.congestion_recovery_start_time != null,
            .available_window = self.availableWindow(),
        };
    }
    
    pub const CongestionStats = struct {
        cwnd: u64,
        ssthresh: u64,
        bytes_in_flight: u64,
        in_recovery: bool,
        available_window: u64,
    };
};

// ═══════════════════════════════════════════════════════════════════════════════
// 0-RTT EARLY DATA SUPPORT
// ═══════════════════════════════════════════════════════════════════════════════

/// Session ticket for 0-RTT resumption
pub const SessionTicket = struct {
    /// Ticket data (encrypted by server)
    ticket: [256]u8,
    ticket_len: u16,
    
    /// Ticket lifetime in seconds
    lifetime: u32,
    
    /// Ticket age add (for obfuscation)
    age_add: u32,
    
    /// Resumption secret
    resumption_secret: [32]u8,
    
    /// Maximum early data size
    max_early_data_size: u32,
    
    /// Creation time
    created_at: i64,
    
    /// Server name (SNI)
    server_name: [256]u8,
    server_name_len: u8,
    
    /// ALPN protocol
    alpn: [32]u8,
    alpn_len: u8,
    
    pub fn isValid(self: *const SessionTicket) bool {
        const now = std.time.timestamp();
        const age = now - self.created_at;
        return age >= 0 and @as(u64, @intCast(age)) < self.lifetime;
    }
    
    pub fn getObfuscatedAge(self: *const SessionTicket) u32 {
        const now = std.time.timestamp();
        const age_ms: u32 = @intCast(@as(u64, @intCast(now - self.created_at)) * 1000);
        return age_ms +% self.age_add;
    }
};

/// 0-RTT state management
pub const ZeroRttState = struct {
    allocator: std.mem.Allocator,
    
    /// Cached session tickets by server name
    tickets: std.StringHashMap(SessionTicket),
    
    /// Early data buffer (data sent before handshake completes)
    early_data_buffer: std.ArrayList(u8),
    
    /// Whether 0-RTT was accepted
    accepted: bool,
    
    /// Whether we're currently in 0-RTT mode
    in_zero_rtt: bool,
    
    /// Early data secret
    early_secret: ?[32]u8,
    
    /// Early data AEAD context
    early_aead: ?tls13.AeadContext,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tickets = std.StringHashMap(SessionTicket).init(allocator),
            .early_data_buffer = std.ArrayList(u8).init(allocator),
            .accepted = false,
            .in_zero_rtt = false,
            .early_secret = null,
            .early_aead = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.tickets.deinit();
        self.early_data_buffer.deinit();
    }
    
    /// Store a session ticket
    pub fn storeTicket(self: *Self, server_name: []const u8, ticket: SessionTicket) !void {
        try self.tickets.put(server_name, ticket);
    }
    
    /// Get a valid ticket for a server
    pub fn getTicket(self: *Self, server_name: []const u8) ?*SessionTicket {
        if (self.tickets.getPtr(server_name)) |ticket| {
            if (ticket.isValid()) {
                return ticket;
            } else {
                // Remove expired ticket
                _ = self.tickets.remove(server_name);
            }
        }
        return null;
    }
    
    /// Prepare for 0-RTT
    pub fn prepareEarlyData(self: *Self, ticket: *const SessionTicket) !void {
        // Derive early traffic secret from resumption secret
        var early_secret: [32]u8 = undefined;
        tls13.hkdfExpandLabel(&ticket.resumption_secret, "c e traffic", "", 32, &early_secret);
        
        self.early_secret = early_secret;
        
        // Create AEAD context for early data
        const secrets = tls13.Secrets.derive(&early_secret);
        self.early_aead = tls13.AeadContext.init(secrets, .TLS_AES_128_GCM_SHA256);
        
        self.in_zero_rtt = true;
    }
    
    /// Queue early data
    pub fn queueEarlyData(self: *Self, data: []const u8) !void {
        if (!self.in_zero_rtt) return error.NotInZeroRtt;
        try self.early_data_buffer.appendSlice(data);
    }
    
    /// Called when server accepts 0-RTT
    pub fn onAccepted(self: *Self) void {
        self.accepted = true;
        self.in_zero_rtt = false;
    }
    
    /// Called when server rejects 0-RTT
    pub fn onRejected(self: *Self) void {
        self.accepted = false;
        self.in_zero_rtt = false;
        self.early_data_buffer.clearRetainingCapacity();
        self.early_secret = null;
        self.early_aead = null;
    }
    
    /// Get buffered early data for retransmission
    pub fn getBufferedData(self: *const Self) []const u8 {
        return self.early_data_buffer.items;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONNECTION MIGRATION
// ═══════════════════════════════════════════════════════════════════════════════

/// Path state for connection migration
pub const PathState = struct {
    /// Remote address for this path
    peer_addr: packet.SocketAddr,
    
    /// Local address for this path
    local_addr: packet.SocketAddr,
    
    /// Path validation state
    validation_state: ValidationState,
    
    /// Challenge data sent (8 bytes)
    challenge_data: [8]u8,
    
    /// Time challenge was sent
    challenge_sent_time: i64,
    
    /// Number of challenges sent
    challenges_sent: u32,
    
    /// Path MTU
    mtu: u16,
    
    /// ECN capability validated
    ecn_validated: bool,
    
    /// Is this the active path?
    active: bool,
    
    /// Path-specific RTT
    rtt: u64,
    
    /// Path-specific congestion controller
    congestion: CongestionController,
    
    pub const ValidationState = enum {
        unknown,
        validating,
        validated,
        failed,
    };
    
    pub fn init(peer_addr: packet.SocketAddr, local_addr: packet.SocketAddr) PathState {
        return .{
            .peer_addr = peer_addr,
            .local_addr = local_addr,
            .validation_state = .unknown,
            .challenge_data = undefined,
            .challenge_sent_time = 0,
            .challenges_sent = 0,
            .mtu = 1200, // Minimum QUIC MTU
            .ecn_validated = false,
            .active = false,
            .rtt = 333_000_000, // 333ms initial
            .congestion = CongestionController.init(),
        };
    }
    
    /// Start path validation
    pub fn startValidation(self: *PathState) void {
        std.crypto.random.bytes(&self.challenge_data);
        self.validation_state = .validating;
        self.challenge_sent_time = std.time.nanoTimestamp();
        self.challenges_sent += 1;
    }
    
    /// Check if path challenge response is valid
    pub fn validateResponse(self: *PathState, response: [8]u8) bool {
        if (std.mem.eql(u8, &self.challenge_data, &response)) {
            self.validation_state = .validated;
            
            // Update RTT based on challenge/response
            const now = std.time.nanoTimestamp();
            self.rtt = @intCast(now - self.challenge_sent_time);
            
            return true;
        }
        return false;
    }
    
    /// Check if validation timed out
    pub fn isValidationTimedOut(self: *const PathState, timeout_ns: u64) bool {
        if (self.validation_state != .validating) return false;
        
        const now = std.time.nanoTimestamp();
        return @as(u64, @intCast(now - self.challenge_sent_time)) > timeout_ns;
    }
};

/// Connection migration manager
pub const MigrationManager = struct {
    allocator: std.mem.Allocator,
    
    /// All known paths
    paths: std.ArrayList(PathState),
    
    /// Active path index
    active_path_index: usize,
    
    /// Available connection IDs
    available_cids: std.ArrayList(ConnectionId),
    
    /// Retired connection IDs
    retired_cids: std.ArrayList(ConnectionId),
    
    /// Sequence number for next CID
    next_cid_sequence: u64,
    
    /// Whether migration is disabled
    migration_disabled: bool,
    
    /// Maximum paths to probe simultaneously
    max_paths: usize,
    
    /// Path validation timeout (3x PTO)
    validation_timeout_ns: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, initial_path: PathState) !Self {
        var manager = Self{
            .allocator = allocator,
            .paths = std.ArrayList(PathState).init(allocator),
            .active_path_index = 0,
            .available_cids = std.ArrayList(ConnectionId).init(allocator),
            .retired_cids = std.ArrayList(ConnectionId).init(allocator),
            .next_cid_sequence = 0,
            .migration_disabled = false,
            .max_paths = 4,
            .validation_timeout_ns = 3 * 333_000_000, // 3x initial RTT
        };
        
        var path = initial_path;
        path.active = true;
        path.validation_state = .validated; // Initial path is assumed valid
        try manager.paths.append(path);
        
        return manager;
    }
    
    pub fn deinit(self: *Self) void {
        self.paths.deinit();
        self.available_cids.deinit();
        self.retired_cids.deinit();
    }
    
    /// Get the active path
    pub fn getActivePath(self: *Self) *PathState {
        return &self.paths.items[self.active_path_index];
    }
    
    /// Called when a packet is received from a different address
    pub fn onPacketFromNewAddress(self: *Self, peer_addr: packet.SocketAddr, local_addr: packet.SocketAddr) !?*PathState {
        if (self.migration_disabled) return null;
        
        // Check if we already know this path
        for (self.paths.items, 0..) |*path, i| {
            if (std.meta.eql(path.peer_addr, peer_addr)) {
                // Existing path, might be address rebinding
                if (path.validation_state == .validated) {
                    // Switch to this path if it's validated
                    self.paths.items[self.active_path_index].active = false;
                    path.active = true;
                    self.active_path_index = i;
                }
                return path;
            }
        }
        
        // New path - need to validate
        if (self.paths.items.len >= self.max_paths) {
            // Remove oldest non-active path
            for (self.paths.items, 0..) |*path, i| {
                if (!path.active) {
                    _ = self.paths.orderedRemove(i);
                    if (self.active_path_index > i) {
                        self.active_path_index -= 1;
                    }
                    break;
                }
            }
        }
        
        var new_path = PathState.init(peer_addr, local_addr);
        new_path.startValidation();
        try self.paths.append(new_path);
        
        return &self.paths.items[self.paths.items.len - 1];
    }
    
    /// Initiate migration to a new path
    pub fn initiateMigration(self: *Self, new_peer_addr: packet.SocketAddr, local_addr: packet.SocketAddr) !*PathState {
        if (self.migration_disabled) return error.MigrationDisabled;
        
        var new_path = PathState.init(new_peer_addr, local_addr);
        new_path.startValidation();
        try self.paths.append(new_path);
        
        return &self.paths.items[self.paths.items.len - 1];
    }
    
    /// Process PATH_RESPONSE frame
    pub fn onPathResponse(self: *Self, response_data: [8]u8) void {
        for (self.paths.items) |*path| {
            if (path.validation_state == .validating) {
                if (path.validateResponse(response_data)) {
                    // Optionally switch to this path if it's better
                    break;
                }
            }
        }
    }
    
    /// Build PATH_CHALLENGE frame for a path
    pub fn buildPathChallenge(self: *Self, path_index: usize) ?[8]u8 {
        if (path_index >= self.paths.items.len) return null;
        
        var path = &self.paths.items[path_index];
        if (path.validation_state != .validating) {
            path.startValidation();
        }
        
        return path.challenge_data;
    }
    
    /// Add a new connection ID
    pub fn addConnectionId(self: *Self, cid: ConnectionId) !void {
        try self.available_cids.append(cid);
    }
    
    /// Get a fresh connection ID for migration
    pub fn getConnectionIdForMigration(self: *Self) ?ConnectionId {
        if (self.available_cids.items.len > 0) {
            return self.available_cids.pop();
        }
        return null;
    }
    
    /// Retire a connection ID
    pub fn retireConnectionId(self: *Self, cid: ConnectionId) !void {
        try self.retired_cids.append(cid);
    }
    
    /// Check for path validation timeouts
    pub fn checkTimeouts(self: *Self) void {
        for (self.paths.items) |*path| {
            if (path.isValidationTimedOut(self.validation_timeout_ns)) {
                if (path.challenges_sent < 3) {
                    // Retry validation
                    path.startValidation();
                } else {
                    // Give up on this path
                    path.validation_state = .failed;
                }
            }
        }
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) MigrationStats {
        var validated_paths: usize = 0;
        for (self.paths.items) |path| {
            if (path.validation_state == .validated) {
                validated_paths += 1;
            }
        }
        
        return .{
            .total_paths = self.paths.items.len,
            .validated_paths = validated_paths,
            .active_path_index = self.active_path_index,
            .available_cids = self.available_cids.items.len,
        };
    }
    
    pub const MigrationStats = struct {
        total_paths: usize,
        validated_paths: usize,
        active_path_index: usize,
        available_cids: usize,
    };
};

// ═══════════════════════════════════════════════════════════════════════════════
// SERVER-SIDE HANDSHAKE STATE MACHINE
// ═══════════════════════════════════════════════════════════════════════════════

/// Server handshake state machine
pub const ServerHandshake = struct {
    allocator: std.mem.Allocator,
    
    /// Current handshake state
    state: State,
    
    /// TLS state
    tls: *TlsState,
    
    /// Client's initial destination CID (for initial secret derivation)
    original_dcid: ConnectionId,
    
    /// Server's TLS certificate (DER encoded)
    certificate: []const u8,
    
    /// Server's private key (for signing)
    private_key: [32]u8,
    
    /// Received ClientHello data
    client_hello: ?[]u8,
    
    /// Generated ServerHello
    server_hello: ?[]u8,
    
    /// Encrypted Extensions
    encrypted_extensions: ?[]u8,
    
    /// Certificate message
    certificate_msg: ?[]u8,
    
    /// CertificateVerify message
    certificate_verify: ?[]u8,
    
    /// Server Finished
    server_finished: ?[]u8,
    
    /// Client Finished received
    client_finished_received: bool,
    
    /// Early data accepted
    early_data_accepted: bool,
    
    /// ALPN protocol selected
    selected_alpn: ?[]const u8,
    
    /// Transport parameters to send
    transport_params: tls13.TransportParameters,
    
    pub const State = enum {
        awaiting_client_hello,
        processing_client_hello,
        sending_server_hello,
        sending_encrypted_extensions,
        sending_certificate,
        sending_certificate_verify,
        sending_finished,
        awaiting_client_finished,
        complete,
        failed,
    };
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        tls: *TlsState,
        certificate: []const u8,
        private_key: [32]u8,
    ) Self {
        return .{
            .allocator = allocator,
            .state = .awaiting_client_hello,
            .tls = tls,
            .original_dcid = ConnectionId{ .data = undefined, .len = 0 },
            .certificate = certificate,
            .private_key = private_key,
            .client_hello = null,
            .server_hello = null,
            .encrypted_extensions = null,
            .certificate_msg = null,
            .certificate_verify = null,
            .server_finished = null,
            .client_finished_received = false,
            .early_data_accepted = false,
            .selected_alpn = null,
            .transport_params = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.client_hello) |ch| self.allocator.free(ch);
        if (self.server_hello) |sh| self.allocator.free(sh);
        if (self.encrypted_extensions) |ee| self.allocator.free(ee);
        if (self.certificate_msg) |cert| self.allocator.free(cert);
        if (self.certificate_verify) |cv| self.allocator.free(cv);
        if (self.server_finished) |sf| self.allocator.free(sf);
    }
    
    /// Process incoming ClientHello
    pub fn processClientHello(self: *Self, data: []const u8, original_dcid: ConnectionId) !void {
        if (self.state != .awaiting_client_hello) return error.InvalidState;
        
        self.original_dcid = original_dcid;
        
        // Store ClientHello for transcript
        self.client_hello = try self.allocator.dupe(u8, data);
        
        // Update TLS transcript
        self.tls.key_schedule.updateTranscript(data);
        
        // Derive initial secrets from original DCID
        self.tls.deriveInitialSecrets(original_dcid.slice());
        
        self.state = .processing_client_hello;
        
        // Parse ClientHello (simplified - just extract key share)
        // In production, parse all extensions properly
        self.state = .sending_server_hello;
    }
    
    /// Generate ServerHello
    pub fn generateServerHello(self: *Self) ![]u8 {
        if (self.state != .sending_server_hello) return error.InvalidState;
        
        var msg = std.ArrayList(u8).init(self.allocator);
        errdefer msg.deinit();
        
        // Handshake header
        try msg.append(@intFromEnum(tls13.HandshakeType.server_hello));
        try msg.appendNTimes(0, 3); // Length placeholder
        
        // Server version (TLS 1.2 for compatibility)
        try msg.appendSlice(&[_]u8{ 0x03, 0x03 });
        
        // Server random
        var server_random: [32]u8 = undefined;
        std.crypto.random.bytes(&server_random);
        try msg.appendSlice(&server_random);
        
        // Session ID (echo client's)
        try msg.append(0); // Empty session ID for QUIC
        
        // Cipher suite
        try msg.append(0x13);
        try msg.append(0x01); // TLS_AES_128_GCM_SHA256
        
        // Compression method
        try msg.append(0);
        
        // Extensions length placeholder
        const ext_len_pos = msg.items.len;
        try msg.appendNTimes(0, 2);
        
        // Extension: supported_versions (TLS 1.3)
        try msg.appendSlice(&[_]u8{ 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04 });
        
        // Extension: key_share
        try msg.appendSlice(&[_]u8{ 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20 });
        try msg.appendSlice(&self.tls.local_public_key);
        
        // Fill extension length
        const ext_len: u16 = @intCast(msg.items.len - ext_len_pos - 2);
        msg.items[ext_len_pos] = @intCast((ext_len >> 8) & 0xFF);
        msg.items[ext_len_pos + 1] = @intCast(ext_len & 0xFF);
        
        // Fill handshake length
        const body_len: u24 = @intCast(msg.items.len - 4);
        msg.items[1] = @intCast((body_len >> 16) & 0xFF);
        msg.items[2] = @intCast((body_len >> 8) & 0xFF);
        msg.items[3] = @intCast(body_len & 0xFF);
        
        self.server_hello = try msg.toOwnedSlice();
        
        // Update transcript
        self.tls.key_schedule.updateTranscript(self.server_hello.?);
        
        // Compute shared secret and derive handshake keys
        if (self.tls.remote_public_key) |remote_pk| {
            const shared = std.crypto.dh.X25519.scalarmult(
                self.tls.local_private_key,
                remote_pk,
            ) catch return error.KeyExchangeFailed;
            
            self.tls.handshake_secrets = self.tls.key_schedule.deriveHandshakeSecrets(&shared);
        }
        
        self.state = .sending_encrypted_extensions;
        
        return self.server_hello.?;
    }
    
    /// Generate EncryptedExtensions
    pub fn generateEncryptedExtensions(self: *Self) ![]u8 {
        if (self.state != .sending_encrypted_extensions) return error.InvalidState;
        
        var msg = std.ArrayList(u8).init(self.allocator);
        errdefer msg.deinit();
        
        // Handshake type
        try msg.append(@intFromEnum(tls13.HandshakeType.encrypted_extensions));
        try msg.appendNTimes(0, 3); // Length placeholder
        
        // Extensions length placeholder
        const ext_len_pos = msg.items.len;
        try msg.appendNTimes(0, 2);
        
        // ALPN extension
        if (self.selected_alpn) |alpn| {
            try msg.append(0x00);
            try msg.append(0x10); // ALPN extension type
            const alpn_ext_len: u16 = @intCast(3 + alpn.len);
            try msg.append(@intCast((alpn_ext_len >> 8) & 0xFF));
            try msg.append(@intCast(alpn_ext_len & 0xFF));
            try msg.append(@intCast((alpn.len + 1) >> 8));
            try msg.append(@intCast((alpn.len + 1) & 0xFF));
            try msg.append(@intCast(alpn.len));
            try msg.appendSlice(alpn);
        }
        
        // QUIC transport parameters
        const params = try self.transport_params.encode(self.allocator);
        defer self.allocator.free(params);
        
        try msg.append(0x00);
        try msg.append(0x39); // QUIC transport parameters (57)
        try msg.append(@intCast((params.len >> 8) & 0xFF));
        try msg.append(@intCast(params.len & 0xFF));
        try msg.appendSlice(params);
        
        // Early data indication (if accepted)
        if (self.early_data_accepted) {
            try msg.appendSlice(&[_]u8{ 0x00, 0x2a, 0x00, 0x00 }); // early_data extension
        }
        
        // Fill extension length
        const ext_len: u16 = @intCast(msg.items.len - ext_len_pos - 2);
        msg.items[ext_len_pos] = @intCast((ext_len >> 8) & 0xFF);
        msg.items[ext_len_pos + 1] = @intCast(ext_len & 0xFF);
        
        // Fill handshake length
        const body_len: u24 = @intCast(msg.items.len - 4);
        msg.items[1] = @intCast((body_len >> 16) & 0xFF);
        msg.items[2] = @intCast((body_len >> 8) & 0xFF);
        msg.items[3] = @intCast(body_len & 0xFF);
        
        self.encrypted_extensions = try msg.toOwnedSlice();
        self.tls.key_schedule.updateTranscript(self.encrypted_extensions.?);
        
        self.state = .sending_certificate;
        
        return self.encrypted_extensions.?;
    }
    
    /// Generate Certificate message
    pub fn generateCertificate(self: *Self) ![]u8 {
        if (self.state != .sending_certificate) return error.InvalidState;
        
        var msg = std.ArrayList(u8).init(self.allocator);
        errdefer msg.deinit();
        
        // Handshake type
        try msg.append(@intFromEnum(tls13.HandshakeType.certificate));
        try msg.appendNTimes(0, 3); // Length placeholder
        
        // Certificate request context (empty for server)
        try msg.append(0);
        
        // Certificate list length placeholder
        const cert_list_len_pos = msg.items.len;
        try msg.appendNTimes(0, 3);
        
        // Certificate entry
        // Certificate data length
        try msg.append(@intCast((self.certificate.len >> 16) & 0xFF));
        try msg.append(@intCast((self.certificate.len >> 8) & 0xFF));
        try msg.append(@intCast(self.certificate.len & 0xFF));
        
        // Certificate data
        try msg.appendSlice(self.certificate);
        
        // Extensions (empty)
        try msg.append(0);
        try msg.append(0);
        
        // Fill certificate list length
        const cert_list_len: u24 = @intCast(msg.items.len - cert_list_len_pos - 3);
        msg.items[cert_list_len_pos] = @intCast((cert_list_len >> 16) & 0xFF);
        msg.items[cert_list_len_pos + 1] = @intCast((cert_list_len >> 8) & 0xFF);
        msg.items[cert_list_len_pos + 2] = @intCast(cert_list_len & 0xFF);
        
        // Fill handshake length
        const body_len: u24 = @intCast(msg.items.len - 4);
        msg.items[1] = @intCast((body_len >> 16) & 0xFF);
        msg.items[2] = @intCast((body_len >> 8) & 0xFF);
        msg.items[3] = @intCast(body_len & 0xFF);
        
        self.certificate_msg = try msg.toOwnedSlice();
        self.tls.key_schedule.updateTranscript(self.certificate_msg.?);
        
        self.state = .sending_certificate_verify;
        
        return self.certificate_msg.?;
    }
    
    /// Generate CertificateVerify message
    pub fn generateCertificateVerify(self: *Self) ![]u8 {
        if (self.state != .sending_certificate_verify) return error.InvalidState;
        
        var msg = std.ArrayList(u8).init(self.allocator);
        errdefer msg.deinit();
        
        // Handshake type
        try msg.append(@intFromEnum(tls13.HandshakeType.certificate_verify));
        try msg.appendNTimes(0, 3); // Length placeholder
        
        // Signature algorithm (Ed25519 = 0x0807)
        try msg.append(0x08);
        try msg.append(0x07);
        
        // Build content to sign
        // 64 spaces + "TLS 1.3, server CertificateVerify" + 0x00 + transcript_hash
        var sign_content: [130]u8 = undefined;
        @memset(sign_content[0..64], 0x20); // 64 spaces
        const context = "TLS 1.3, server CertificateVerify";
        @memcpy(sign_content[64..][0..context.len], context);
        sign_content[64 + context.len] = 0x00;
        const transcript = self.tls.key_schedule.getTranscriptHash();
        @memcpy(sign_content[65 + context.len ..][0..32], &transcript);
        
        // Sign with Ed25519
        const signature = std.crypto.sign.Ed25519.sign(
            sign_content[0 .. 65 + context.len + 32],
            self.private_key,
            null,
        ) catch return error.SigningFailed;
        
        // Signature length
        try msg.append(0);
        try msg.append(64); // Ed25519 signature is 64 bytes
        
        // Signature
        try msg.appendSlice(&signature.toBytes());
        
        // Fill handshake length
        const body_len: u24 = @intCast(msg.items.len - 4);
        msg.items[1] = @intCast((body_len >> 16) & 0xFF);
        msg.items[2] = @intCast((body_len >> 8) & 0xFF);
        msg.items[3] = @intCast(body_len & 0xFF);
        
        self.certificate_verify = try msg.toOwnedSlice();
        self.tls.key_schedule.updateTranscript(self.certificate_verify.?);
        
        self.state = .sending_finished;
        
        return self.certificate_verify.?;
    }
    
    /// Generate server Finished message
    pub fn generateFinished(self: *Self) ![]u8 {
        if (self.state != .sending_finished) return error.InvalidState;
        
        // Derive server finished key
        var finished_key: [32]u8 = undefined;
        if (self.tls.handshake_secrets) |secrets| {
            tls13.hkdfExpandLabel(&secrets.server.key, "finished", "", 32, &finished_key);
        } else {
            return error.NoHandshakeSecrets;
        }
        
        const transcript = self.tls.key_schedule.getTranscriptHash();
        self.server_finished = try tls13.buildFinished(self.allocator, finished_key, transcript);
        
        self.tls.key_schedule.updateTranscript(self.server_finished.?);
        
        // Derive application secrets
        self.tls.application_secrets = self.tls.key_schedule.deriveApplicationSecrets();
        
        self.state = .awaiting_client_finished;
        
        return self.server_finished.?;
    }
    
    /// Process client Finished message
    pub fn processClientFinished(self: *Self, data: []const u8) !void {
        if (self.state != .awaiting_client_finished) return error.InvalidState;
        
        // Verify client finished
        var finished_key: [32]u8 = undefined;
        if (self.tls.handshake_secrets) |secrets| {
            tls13.hkdfExpandLabel(&secrets.client.key, "finished", "", 32, &finished_key);
        } else {
            return error.NoHandshakeSecrets;
        }
        
        const transcript = self.tls.key_schedule.getTranscriptHash();
        
        if (data.len < 36) return error.InvalidFinished; // 4 byte header + 32 byte verify data
        
        const verify_data = data[4..36].*;
        
        if (!tls13.verifyFinished(finished_key, transcript, verify_data)) {
            self.state = .failed;
            return error.FinishedVerificationFailed;
        }
        
        self.client_finished_received = true;
        self.tls.handshake_complete = true;
        self.state = .complete;
    }
    
    /// Check if handshake is complete
    pub fn isComplete(self: *const Self) bool {
        return self.state == .complete;
    }
    
    /// Get current state
    pub fn getState(self: *const Self) State {
        return self.state;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "connection lifecycle" {
    const addr = packet.SocketAddr.ipv4(.{ 127, 0, 0, 1 }, 8443);
    var conn = try Connection.init(std.testing.allocator, addr);
    defer conn.deinit();

    try std.testing.expectEqual(Connection.State.initial, conn.state);
}

test "endpoint management" {
    const addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, 8443);
    var endpoint = try Endpoint.init(std.testing.allocator, addr, true);
    defer endpoint.deinit();

    const peer = packet.SocketAddr.ipv4(.{ 192, 168, 1, 100 }, 12345);
    const conn = try endpoint.connect(peer);
    _ = conn;

    try std.testing.expectEqual(@as(usize, 1), endpoint.connections.count());
}

