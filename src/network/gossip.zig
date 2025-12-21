//! Vexor Gossip Protocol
//!
//! Implementation of Solana's CRDS (Cluster Replicated Data Store) gossip protocol.
//! Handles:
//! - Validator discovery and cluster membership
//! - Node health/contact info propagation
//! - Vote and epoch stake distribution
//!
//! Reference: Solana Gossip Protocol (based on Firedancer's fd_gossip)
//! Wire format: https://github.com/eigerco/solana-spec/blob/main/gossip-protocol-spec.md

const std = @import("std");
const socket = @import("socket.zig");
const packet = @import("packet.zig");
const core = @import("../core/root.zig");
const bincode = @import("bincode.zig");

/// Gossip protocol message types (matches Solana bincode format)
/// See bincode.zig for full protocol implementation
pub const MessageType = enum(u32) {
    pull_request = 0,
    pull_response = 1,
    push_message = 2,
    prune_message = 3,
    ping = 4,
    pong = 5,
    _,
};

/// Testnet shred version
pub const TESTNET_SHRED_VERSION: u16 = 9604;

/// Contact info for a cluster node
pub const ContactInfo = struct {
    /// Node's identity pubkey
    pubkey: core.Pubkey,

    /// Gossip address
    gossip_addr: packet.SocketAddr,

    /// TPU address (for transactions)
    tpu_addr: packet.SocketAddr,

    /// TPU forward address
    tpu_fwd_addr: packet.SocketAddr,

    /// TVU address (for shreds)
    tvu_addr: packet.SocketAddr,

    /// TVU forward address  
    tvu_fwd_addr: packet.SocketAddr,

    /// Repair address
    repair_addr: packet.SocketAddr,

    /// RPC address
    rpc_addr: packet.SocketAddr,

    /// Serve repair address
    serve_repair_addr: packet.SocketAddr,

    /// Wallclock timestamp
    wallclock: u64,

    /// Shred version (for compatibility check)
    shred_version: u16,

    /// Software version
    version: Version,

    pub const Version = struct {
        major: u16,
        minor: u16,
        patch: u16,
        commit: ?u32,

        pub fn format(self: Version, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}.{}.{}", .{ self.major, self.minor, self.patch });
        }
    };

    /// Create contact info for our node
    /// IMPORTANT: `ip` MUST be the validator's public IP for the network to send shreds!
    pub fn initSelf(
        identity: core.Pubkey,
        ip: [4]u8,
        gossip_port: u16,
        tpu_port: u16,
        tvu_port: u16,
        repair_port: u16,
        rpc_port: u16,
    ) ContactInfo {
        return .{
            .pubkey = identity,
            .gossip_addr = packet.SocketAddr.ipv4(ip, gossip_port),
            .tpu_addr = packet.SocketAddr.ipv4(ip, tpu_port),
            .tpu_fwd_addr = packet.SocketAddr.ipv4(ip, tpu_port + 1),
            .tvu_addr = packet.SocketAddr.ipv4(ip, tvu_port),
            .tvu_fwd_addr = packet.SocketAddr.ipv4(ip, tvu_port + 1),
            .repair_addr = packet.SocketAddr.ipv4(ip, repair_port),
            .rpc_addr = packet.SocketAddr.ipv4(ip, rpc_port),
            .serve_repair_addr = packet.SocketAddr.ipv4(ip, repair_port + 1),
            .wallclock = @intCast(std.time.milliTimestamp()),
            .shred_version = 0,
            .version = .{ .major = 0, .minor = 1, .patch = 0, .commit = null },
        };
    }

    /// Check if contact info is stale
    pub fn isStale(self: *const ContactInfo, now_ms: u64, timeout_ms: u64) bool {
        return (now_ms - self.wallclock) > timeout_ms;
    }
};

/// CRDS data types that can be gossiped
pub const CrdsValueKind = enum(u32) {
    contact_info = 0,
    vote = 1,
    lowest_slot = 2,
    snapshot_hashes = 3,
    accounts_hashes = 4,
    epoch_slots = 5,
    legacy_version = 6,
    version = 7,
    node_instance = 8,
    duplicate_shred = 9,
    incremental_snapshot_hashes = 10,
    _,
};

/// CRDS Value - a piece of gossip data
pub const CrdsValue = struct {
    /// The pubkey that created this value
    pubkey: core.Pubkey,

    /// Signature over the data
    signature: core.Signature,

    /// Wallclock when created  
    wallclock: u64,

    /// Type of value
    kind: CrdsValueKind,

    /// Serialized value data
    data: []const u8,

    /// Hash of the value (for deduplication)
    pub fn hash(self: *const CrdsValue) core.Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.kind));
        hasher.update(&self.pubkey);
        hasher.update(self.data);
        return hasher.finalResult();
    }
};

/// Gossip table - stores received gossip data
pub const GossipTable = struct {
    allocator: std.mem.Allocator,

    /// Contact info for all known nodes
    contacts: std.AutoHashMap(core.Pubkey, ContactInfo),

    /// All received CRDS values by hash
    values: std.AutoHashMap(core.Hash, CrdsValue),

    /// Our own contact info
    self_info: ?ContactInfo,

    /// Statistics
    stats: Stats,

    const Self = @This();

    pub const Stats = struct {
        values_received: u64 = 0,
        values_inserted: u64 = 0,
        values_expired: u64 = 0,
        pull_requests_sent: u64 = 0,
        pull_responses_received: u64 = 0,
        push_messages_received: u64 = 0,
        pings_sent: u64 = 0,
        pongs_received: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .contacts = std.AutoHashMap(core.Pubkey, ContactInfo).init(allocator),
            .values = std.AutoHashMap(core.Hash, CrdsValue).init(allocator),
            .self_info = null,
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.contacts.deinit();
        self.values.deinit();
    }

    /// Insert or update contact info
    pub fn upsertContact(self: *Self, info: ContactInfo) !void {
        const existing = self.contacts.get(info.pubkey);
        if (existing) |ex| {
            // Only update if newer
            if (info.wallclock > ex.wallclock) {
                try self.contacts.put(info.pubkey, info);
            }
        } else {
            try self.contacts.put(info.pubkey, info);
        }
    }

    /// Get contact info for a pubkey
    pub fn getContact(self: *const Self, pubkey: core.Pubkey) ?ContactInfo {
        return self.contacts.get(pubkey);
    }

    /// Get all known node pubkeys
    pub fn knownNodes(self: *const Self) []const core.Pubkey {
        return self.contacts.keys();
    }

    /// Get count of known contacts
    pub fn contactCount(self: *const Self) usize {
        return self.contacts.count();
    }

    /// Prune stale contacts
    /// SAFETY: Collects keys to remove first to avoid modifying HashMap during iteration
    pub fn pruneStale(self: *Self, timeout_ms: u64) usize {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        var pruned: usize = 0;

        // Collect keys to remove (avoid modifying during iteration)
        var keys_to_remove: [256]core.Pubkey = undefined;
        var remove_count: usize = 0;

        var it = self.contacts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isStale(now, timeout_ms) and remove_count < 256) {
                keys_to_remove[remove_count] = entry.key_ptr.*;
                remove_count += 1;
            }
        }

        // Now remove the collected keys
        for (keys_to_remove[0..remove_count]) |key| {
            _ = self.contacts.remove(key);
            pruned += 1;
            self.stats.values_expired += 1;
        }

        return pruned;
    }
};

/// Gossip service - manages gossip protocol communication
pub const GossipService = struct {
    allocator: std.mem.Allocator,

    /// Our identity
    identity: core.Pubkey,
    
    /// Our keypair for signing (optional - needed for full gossip)
    keypair: ?*const core.Keypair = null,

    /// Gossip UDP socket
    sock: ?socket.UdpSocket,

    /// Gossip data table
    table: GossipTable,

    /// Entrypoint addresses to connect to
    entrypoints: std.ArrayList(packet.SocketAddr),

    /// Random number generator
    rng: std.Random.DefaultPrng,

    /// Configuration
    config: Config,
    
    /// Running state
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    
    /// Last action timestamps
    last_pull_time: i64 = 0,
    last_push_time: i64 = 0,
    last_ping_time: i64 = 0,
    
    /// Our public IP address
    public_ip: [4]u8 = .{ 0, 0, 0, 0 },
    
    /// Shred version (for cluster compatibility)
    shred_version: u16 = TESTNET_SHRED_VERSION,
    
    /// Our LegacyContactInfo in bincode format (deprecated, but kept for Agave compat)
    legacy_contact_info: ?bincode.LegacyContactInfo = null,
    
    /// Our modern ContactInfo (required by Firedancer)
    modern_contact_info: ?bincode.ContactInfo = null,

    const Self = @This();

    pub const Config = struct {
        /// Gossip port to bind
        gossip_port: u16 = 8000,

        /// How often to pull from peers (ms)
        pull_interval_ms: u64 = 15_000,

        /// How often to push to peers (ms)  
        push_interval_ms: u64 = 500,

        /// How often to ping peers (ms)
        ping_interval_ms: u64 = 2_000,

        /// Timeout for stale contacts (ms)
        contact_timeout_ms: u64 = 120_000,

        /// Max peers to push to
        max_push_fanout: usize = 6,
        
        /// TPU port
        tpu_port: u16 = 8004,
        
        /// TVU port
        tvu_port: u16 = 8001,
        
        /// Repair port
        repair_port: u16 = 8003,
        
        /// RPC port
        rpc_port: u16 = 8899,
    };

    pub fn init(allocator: std.mem.Allocator, identity: core.Pubkey, config: Config) Self {
        return .{
            .allocator = allocator,
            .identity = identity,
            .sock = null,
            .table = GossipTable.init(allocator),
            .entrypoints = std.ArrayList(packet.SocketAddr).init(allocator),
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.sock) |*s| {
            s.deinit();
        }
        self.table.deinit();
        self.entrypoints.deinit();
    }

    /// Start the gossip service
    pub fn start(self: *Self) !void {
        // Create and bind gossip socket
        var sock = try socket.UdpSocket.init();
        errdefer sock.deinit();

        try sock.bindPort(self.config.gossip_port);
        self.sock = sock;

        std.debug.print("Gossip service started on port {}\n", .{self.config.gossip_port});
    }

    /// Add an entrypoint address (supports hostnames and IPs)
    pub fn addEntrypoint(self: *Self, host: []const u8, port: u16) !void {
        // Try parsing as IP first
        if (std.net.Address.parseIp4(host, port)) |ip| {
            const addr = packet.SocketAddr.ipv4(
                @as([4]u8, @bitCast(ip.in.sa.addr)),
                port,
            );
            try self.entrypoints.append(addr);
            std.log.info("[Gossip] Added entrypoint (IP): {s}:{d}", .{ host, port });
            return;
        } else |_| {}
        
        // If not an IP, try DNS resolution using getAddressList
        std.log.info("[Gossip] Resolving hostname: {s}:{d}", .{ host, port });
        
        // Use getAddressList for proper DNS resolution
        const list = std.net.getAddressList(self.allocator, host, port) catch |err| {
            std.log.warn("[Gossip] DNS resolution failed for {s}: {}", .{ host, err });
            return err;
        };
        defer list.deinit();
        
        // Use the first resolved address
        if (list.addrs.len > 0) {
            const resolved = list.addrs[0];
            if (resolved.any.family == std.posix.AF.INET) {
                const ipv4 = @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(&resolved.any)));
                const ip_bytes: [4]u8 = @bitCast(ipv4.addr);
                const addr = packet.SocketAddr.ipv4(ip_bytes, port);
                try self.entrypoints.append(addr);
                std.log.info("[Gossip] Resolved {s} -> {d}.{d}.{d}.{d}:{d}", .{
                    host, ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], port,
                });
            } else {
                std.log.warn("[Gossip] Resolved address is not IPv4 for {s}", .{host});
            }
        } else {
            std.log.warn("[Gossip] No addresses resolved for {s}", .{host});
        }
    }

    /// Send a ping to a node (bincode format with proper signature)
    pub fn sendPing(self: *Self, target: packet.SocketAddr) !void {
        if (self.sock == null) return error.NotStarted;

        // Build ping message in proper bincode format
        var pkt = packet.Packet.init();

        // Generate random token
        var token: [32]u8 = undefined;
        const random = self.rng.random();
        random.bytes(&token);

        // Sign the ping message
        var signature: ?core.Signature = null;
        if (self.keypair) |kp| {
            const signable = bincode.getPingSignableData(self.identity, token);
            signature = kp.sign(&signable);
        }

        // Build bincode-formatted ping message
        const len = bincode.buildPingMessage(
            &pkt.data,
            self.identity,
            token,
            signature,
        ) catch {
            std.debug.print("[Gossip] Failed to build ping message\n", .{});
            return;
        };

        pkt.len = @intCast(len);
        pkt.src_addr = target;

        _ = try self.sock.?.send(&pkt);
        self.table.stats.pings_sent += 1;
    }

    /// Process received gossip packets
    pub fn processPackets(self: *Self, batch: *packet.PacketBatch) !void {
        for (batch.slice()) |*pkt| {
            try self.processPacket(pkt);
        }
    }

    fn processPacket(self: *Self, pkt: *const packet.Packet) !void {
        if (pkt.len < 4) return; // Too short

        const msg_type_raw = std.mem.readInt(u32, pkt.data[0..4], .little);
        const msg_type: MessageType = @enumFromInt(msg_type_raw);

        switch (msg_type) {
            .ping => {
                try self.handlePing(pkt);
            },
            .pong => {
                std.debug.print("[Gossip] Received PONG from {}.{}.{}.{}:{}\n", .{
                    pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
                    pkt.src_addr.port(),
                });
                self.handlePong(pkt);
            },
            .push_message => {
                std.debug.print("[Gossip] Received PUSH ({} bytes) from {}.{}.{}.{}:{}\n", .{
                    pkt.len,
                    pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
                    pkt.src_addr.port(),
                });
                try self.handlePush(pkt);
            },
            .pull_request => {
                try self.handlePullRequest(pkt);
            },
            .pull_response => {
                std.debug.print("[Gossip] Received PULL_RESPONSE ({} bytes) from {}.{}.{}.{}:{}\n", .{
                    pkt.len,
                    pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
                    pkt.src_addr.port(),
                });
                try self.handlePullResponse(pkt);
            },
            .prune_message => {
                std.debug.print("[Gossip] Received PRUNE from {}.{}.{}.{}:{}\n", .{
                    pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
                    pkt.src_addr.port(),
                });
            },
            _ => {
                // Debug: Show first 16 bytes to diagnose the wire format issue
                std.debug.print("[Gossip] Unknown type {} ({} bytes) from {}.{}.{}.{}:{}\n", .{
                    msg_type_raw, pkt.len,
                    pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
                    pkt.src_addr.port(),
                });
                std.debug.print("[Gossip] First 16 bytes: ", .{});
                const debug_len = @min(16, pkt.len);
                for (pkt.data[0..debug_len]) |b| {
                    std.debug.print("{x:0>2} ", .{b});
                }
                std.debug.print("\n", .{});
            },
        }
    }

    fn handlePing(self: *Self, pkt: *const packet.Packet) !void {
        // Bincode format: [enum_tag(4)] + [from(32)] + [token(32)] + [signature(64)] = 132 bytes
        if (pkt.len < 132) {
            std.debug.print("[Gossip] Ping too short: {} bytes (need 132)\n", .{pkt.len});
            return;
        }

        // Extract ping token (at offset 36, after enum_tag + from pubkey)
        const ping_token = pkt.data[36..68];

        // Sign the pong response
        var signature: ?core.Signature = null;
        if (self.keypair) |kp| {
            const signable = bincode.getPongSignableData(self.identity, ping_token[0..32]);
            signature = kp.sign(&signable);
        }

        // Build pong response in proper bincode format
        var response = packet.Packet.init();
        const len = bincode.buildPongMessage(
            &response.data,
            self.identity,
            ping_token[0..32],
            signature,
        ) catch {
            std.debug.print("[Gossip] Failed to build pong message\n", .{});
            return;
        };

        response.len = @intCast(len);
        response.src_addr = pkt.src_addr;

        _ = try self.sock.?.send(&response);
        
        // Log successful ping/pong for debugging
        std.debug.print("[Gossip] Received PING, sent signed PONG to {}.{}.{}.{}:{}\n", .{
            pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
            pkt.src_addr.port(),
        });
    }

    fn handlePong(self: *Self, pkt: *const packet.Packet) void {
        self.table.stats.pongs_received += 1;
        std.debug.print("[Gossip] Received PONG ({} bytes) from {}.{}.{}.{}:{}\n", .{
            pkt.len,
            pkt.src_addr.addr[0], pkt.src_addr.addr[1], pkt.src_addr.addr[2], pkt.src_addr.addr[3],
            pkt.src_addr.port(),
        });
    }

    fn handlePush(self: *Self, pkt: *const packet.Packet) !void {
        self.table.stats.push_messages_received += 1;
        
        // Parse PUSH message: [enum_tag(4)] + [sender_pubkey(32)] + [vec_len(8)] + [crds_values...]
        if (pkt.len < 44) return; // Minimum: 4 + 32 + 8
        
        const data = pkt.data[0..pkt.len];
        var offset: usize = 4; // Skip enum tag
        
        // Skip sender pubkey
        offset += 32;
        
        // Read number of CrdsValues
        if (offset + 8 > data.len) return;
        const num_values = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        
        // Parse each CrdsValue - properly parse to get exact size (like Firedancer)
        // Reference: fd_gossip_msg_crds_vals_parse in fd_gossip_msg_parse.c
        var values_parsed: u64 = 0;
        var contact_infos_found: u64 = 0;
        var i: u64 = 0;
        
        while (i < num_values and offset + 68 < data.len) : (i += 1) {
            // Each CrdsValue: [signature(64)] + [enum_tag(4)] + [data...]
            const crds_tag = std.mem.readInt(u32, data[offset + 64 ..][0..4], .little);
            
            // Try to parse ContactInfo
            if (crds_tag == 0 or crds_tag == 11) {
                if (try self.parseCrdsValue(data[offset..])) |peer_info| {
                    self.table.upsertContact(peer_info) catch {};
                    contact_infos_found += 1;
                }
            }
            values_parsed += 1;
            
            // Get exact size of this CrdsValue by parsing it
            // This is the key fix - Firedancer parses each value to get exact size
            const value_size = getCrdsValueSize(data[offset..], crds_tag) orelse break;
            offset += value_size;
        }
        
        if (contact_infos_found > 0) {
            self.table.stats.values_received += contact_infos_found;
        }
    }
    
    /// Calculate the exact size of a CrdsValue by parsing its structure
    /// Based on Firedancer fd_gossip_msg_crds_data_parse
    fn getCrdsValueSize(data: []const u8, crds_tag: u32) ?usize {
        // CrdsValue = signature(64) + tag(4) + data
        const header_size: usize = 64 + 4;
        if (data.len < header_size) return null;
        
        var offset: usize = header_size;
        
        switch (crds_tag) {
            0 => { // LegacyContactInfo: pubkey(32) + 10x sockets + wallclock(8) + shred_version(2)
                // Each socket: family(4) + ip4(4)+port(2) or ip6(16)+port(2)+flowinfo(4)+scope(4)
                offset += 32; // pubkey
                var socket_idx: usize = 0;
                while (socket_idx < 10) : (socket_idx += 1) {
                    if (offset + 4 > data.len) return null;
                    const is_ip6 = std.mem.readInt(u32, data[offset..][0..4], .little);
                    offset += 4;
                    if (is_ip6 == 0) {
                        offset += 4 + 2; // ip4 + port
                    } else {
                        offset += 16 + 2 + 4 + 4; // ip6 + port + flowinfo + scope
                    }
                }
                offset += 8 + 2; // wallclock + shred_version
            },
            11 => { // ContactInfo (modern) - variable size with compact_u16
                offset += 32; // pubkey
                // Skip varint wallclock
                while (offset < data.len) {
                    const byte = data[offset];
                    offset += 1;
                    if ((byte & 0x80) == 0) break;
                }
                offset += 8 + 2; // instance_creation + shred_version
                // Skip version (3 varints + 2 u32s + 1 varint)
                var vi: usize = 0;
                while (vi < 4) : (vi += 1) { // major, minor, patch, client
                    while (offset < data.len) {
                        const byte = data[offset];
                        offset += 1;
                        if ((byte & 0x80) == 0) break;
                    }
                    if (vi == 2) offset += 8; // commit + feature_set after patch
                }
                // Skip addresses (compact_u16 len + entries)
                if (offset >= data.len) return null;
                const addr_count = readCompactU16(data[offset..]) orelse return null;
                offset += compactU16Size(addr_count);
                var ai: u16 = 0;
                while (ai < addr_count) : (ai += 1) {
                    if (offset + 4 > data.len) return null;
                    const is_ip6 = std.mem.readInt(u32, data[offset..][0..4], .little);
                    offset += 4;
                    offset += if (is_ip6 == 0) 4 else 16;
                }
                // Skip sockets (compact_u16 len + entries)
                if (offset >= data.len) return null;
                const socket_count = readCompactU16(data[offset..]) orelse return null;
                offset += compactU16Size(socket_count);
                var si: u16 = 0;
                while (si < socket_count) : (si += 1) {
                    offset += 2; // tag + addr_idx
                    if (offset >= data.len) return null;
                    const port_offset = readCompactU16(data[offset..]) orelse return null;
                    offset += compactU16Size(port_offset);
                }
                // Skip extensions
                if (offset >= data.len) return null;
                const ext_count = readCompactU16(data[offset..]) orelse return null;
                offset += compactU16Size(ext_count);
                offset += ext_count * 4;
            },
            1 => { // Vote: index(1) + pubkey(32) + txn(variable) + wallclock(8)
                offset += 1 + 32; // index + pubkey
                // Transaction is variable - estimate ~100 bytes
                offset += 100 + 8;
            },
            2 => { // LowestSlot: index(1) + pubkey(32) + root(8) + slot(8) + slots_len(8) + stash_len(8) + wallclock(8)
                offset += 1 + 32 + 8 + 8 + 8 + 8 + 8;
            },
            3, 4 => { // AccountHashes/LegacySnapshotHashes: pubkey(32) + hashes_len(8) + hashes + wallclock(8)
                offset += 32;
                if (offset + 8 > data.len) return null;
                const hashes_len = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8 + hashes_len * 40 + 8;
            },
            5 => { // EpochSlots: variable - use estimate
                offset += 200;
            },
            6 => { // LegacyVersion: pubkey(32) + wallclock(8) + version(6) + has_commit(1) + commit?(4)
                offset += 32 + 8 + 6 + 1;
                if (offset < data.len and data[offset - 1] != 0) offset += 4;
            },
            7 => { // Version: LegacyVersion + feature_set(4)
                offset += 32 + 8 + 6 + 1;
                if (offset < data.len and data[offset - 1] != 0) offset += 4;
                offset += 4;
            },
            8 => { // NodeInstance: pubkey(32) + wallclock(8) + timestamp(8) + token(8)
                offset += 32 + 8 + 8 + 8;
            },
            9 => { // DuplicateShred: variable - use estimate
                offset += 200;
            },
            10 => { // SnapshotHashes: pubkey(32) + full(40) + inc_len(8) + incs + wallclock(8)
                offset += 32 + 40;
                if (offset + 8 > data.len) return null;
                const inc_len = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8 + inc_len * 40 + 8;
            },
            else => {
                // Unknown type - can't determine size
                return null;
            },
        }
        
        return if (offset <= data.len) offset else null;
    }
    
    /// Read a compact_u16 value
    fn readCompactU16(data: []const u8) ?u16 {
        if (data.len == 0) return null;
        if (data[0] & 0x80 == 0) {
            return data[0];
        }
        if (data.len < 2) return null;
        if (data[1] & 0x80 == 0) {
            return @as(u16, @intCast(data[0] & 0x7F)) | (@as(u16, @intCast(data[1])) << 7);
        }
        if (data.len < 3) return null;
        return @as(u16, @intCast(data[0] & 0x7F)) | 
               (@as(u16, @intCast(data[1] & 0x7F)) << 7) |
               (@as(u16, @intCast(data[2])) << 14);
    }
    
    /// Get size of compact_u16 encoding
    fn compactU16Size(value: u16) usize {
        if (value < 0x80) return 1;
        if (value < 0x4000) return 2;
        return 3;
    }

    fn handlePullRequest(self: *Self, pkt: *const packet.Packet) !void {
        _ = self;
        _ = pkt;
        // TODO: build and send pull response (low priority - we're a light client)
    }

    fn handlePullResponse(self: *Self, pkt: *const packet.Packet) !void {
        self.table.stats.pull_responses_received += 1;
        
        // Parse PULL_RESPONSE: [enum_tag(4)] + [pubkey(32)] + [vec_len(8)] + [crds_values...]
        // Note: PULL_RESPONSE has pubkey after tag (unlike PUSH which has it before vec_len)
        if (pkt.len < 44) return; // 4 + 32 + 8
        
        const data = pkt.data[0..pkt.len];
        var offset: usize = 4; // Skip enum tag
        
        // Skip sender pubkey (PULL_RESPONSE has pubkey here)
        offset += 32;
        
        // Read number of CrdsValues
        if (offset + 8 > data.len) return;
        const num_values = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        
        // Parse each CrdsValue - properly parse to get exact size (like Firedancer)
        var values_parsed: u64 = 0;
        var contact_infos_found: u64 = 0;
        var i: u64 = 0;
        
        while (i < num_values and offset + 68 < data.len) : (i += 1) {
            // Each CrdsValue: [signature(64)] + [enum_tag(4)] + [data...]
            const crds_tag = std.mem.readInt(u32, data[offset + 64 ..][0..4], .little);
            
            // Try to parse ContactInfo
            if (crds_tag == 0 or crds_tag == 11) {
                if (try self.parseCrdsValue(data[offset..])) |peer_info| {
                    self.table.upsertContact(peer_info) catch {};
                    contact_infos_found += 1;
                }
            }
            values_parsed += 1;
            
            // Get exact size of this CrdsValue by parsing it
            const value_size = getCrdsValueSize(data[offset..], crds_tag) orelse break;
            offset += value_size;
        }
        
        if (contact_infos_found > 0) {
            const total = self.table.stats.values_received + contact_infos_found;
            if (total < 20 or total % 100 == 0) {
                std.debug.print("[Gossip] PULL_RESPONSE: found {} ContactInfos ({} values scanned, {} total peers)\n", 
                    .{ contact_infos_found, values_parsed, self.table.contactCount() });
            }
        }
        
        self.table.stats.values_received += contact_infos_found;
    }
    
    /// Parse a CrdsValue and extract ContactInfo if it's a ContactInfo type
    fn parseCrdsValue(self: *Self, data: []const u8) !?ContactInfo {
        _ = self;
        
        // CrdsValue format: [signature(64)] + [enum_tag(4)] + [data...]
        if (data.len < 68) return null;
        
        // Skip signature
        var offset: usize = 64;
        
        // Read CrdsData enum tag
        const crds_tag = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        
        // Debug: track tags we see (only first few times)
        const S = struct {
            var tag_counts: [20]u32 = [_]u32{0} ** 20;
            var logged: bool = false;
        };
        if (crds_tag < 20) {
            S.tag_counts[crds_tag] += 1;
            if (!S.logged and S.tag_counts[0] + S.tag_counts[11] > 50) {
                S.logged = true;
                std.debug.print("[Gossip] CRDS tag stats: tag0={} tag11={} tag1={} tag2={} tag3={}\n", .{
                    S.tag_counts[0], S.tag_counts[11], S.tag_counts[1], S.tag_counts[2], S.tag_counts[3],
                });
            }
        }
        
        // Only parse ContactInfo (tag 11) and LegacyContactInfo (tag 0)
        if (crds_tag == 11) {
            // Modern ContactInfo - parse pubkey and gossip socket
            const result = parseModernContactInfo(data[offset..]) catch |err| {
                std.debug.print("[Gossip] Failed to parse modern ContactInfo: {}\n", .{err});
                return null;
            };
            return result;
        } else if (crds_tag == 0) {
            // LegacyContactInfo - parse pubkey and gossip socket
            const result = parseLegacyContactInfo(data[offset..]) catch |err| {
                std.debug.print("[Gossip] Failed to parse legacy ContactInfo: {}\n", .{err});
                return null;
            };
            return result;
        }
        
        return null;
    }
    
    /// Parse LegacyContactInfo to extract peer address
    fn parseLegacyContactInfo(data: []const u8) !?ContactInfo {
        // Format: pubkey(32) + 10x sockets + wallclock(8) + shred_version(2)
        if (data.len < 134) {
            // Debug: track why parsing fails
            const S = struct {
                var too_short: u32 = 0;
            };
            S.too_short += 1;
            if (S.too_short < 5) {
                std.debug.print("[Gossip] LegacyContactInfo too short: {} bytes (need 134)\n", .{data.len});
            }
            return null;
        }
        
        var info = ContactInfo{
            .pubkey = undefined,
            .gossip_addr = packet.SocketAddr.UNSPECIFIED,
            .tpu_addr = packet.SocketAddr.UNSPECIFIED,
            .tpu_fwd_addr = packet.SocketAddr.UNSPECIFIED,
            .tvu_addr = packet.SocketAddr.UNSPECIFIED,
            .tvu_fwd_addr = packet.SocketAddr.UNSPECIFIED,
            .repair_addr = packet.SocketAddr.UNSPECIFIED,
            .serve_repair_addr = packet.SocketAddr.UNSPECIFIED,
            .rpc_addr = packet.SocketAddr.UNSPECIFIED,
            .wallclock = 0,
            .shred_version = 0,
            .version = .{ .major = 0, .minor = 0, .patch = 0, .commit = null },
        };
        
        @memcpy(&info.pubkey.data, data[0..32]);
        
        var offset: usize = 32;
        
        // Parse sockets: gossip, tvu, tvu_forwards, repair, tpu, ...
        // Each socket: [family(4)] + [ip(4 or 16)] + [port(2)]
        inline for (0..10) |i| {
            if (offset + 6 > data.len) return null;
            const family = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            
            if (family == 0) { // IPv4
                if (offset + 6 > data.len) return null;
                const ip = data[offset..][0..4].*;
                offset += 4;
                const port_val = std.mem.readInt(u16, data[offset..][0..2], .little);
                offset += 2;
                
                const addr = packet.SocketAddr.ipv4(ip, port_val);
                
                switch (i) {
                    0 => info.gossip_addr = addr,
                    1 => info.tvu_addr = addr,
                    3 => info.repair_addr = addr,
                    4 => info.tpu_addr = addr,
                    9 => info.serve_repair_addr = addr,
                    7 => info.rpc_addr = addr,
                    else => {},
                }
            } else {
                // IPv6 - skip
                offset += 22;
            }
        }
        
        // Parse wallclock and shred_version
        if (offset + 10 <= data.len) {
            info.wallclock = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;
            info.shred_version = std.mem.readInt(u16, data[offset..][0..2], .little);
        }
        
        // Validate - must have valid gossip address
        if (info.gossip_addr.port() == 0) {
            const S = struct {
                var no_gossip: u32 = 0;
            };
            S.no_gossip += 1;
            if (S.no_gossip < 5) {
                std.debug.print("[Gossip] LegacyContactInfo has no gossip port\n", .{});
            }
            return null;
        }
        
        return info;
    }
    
    /// Parse modern ContactInfo to extract peer address
    /// Reference: Firedancer fd_gossip_msg_parse.c:440-525
    fn parseModernContactInfo(data: []const u8) !?ContactInfo {
        if (data.len < 32) return null; // Need at least pubkey
        
        var info = ContactInfo{
            .pubkey = undefined,
            .gossip_addr = packet.SocketAddr.UNSPECIFIED,
            .tpu_addr = packet.SocketAddr.UNSPECIFIED,
            .tpu_fwd_addr = packet.SocketAddr.UNSPECIFIED,
            .tvu_addr = packet.SocketAddr.UNSPECIFIED,
            .tvu_fwd_addr = packet.SocketAddr.UNSPECIFIED,
            .repair_addr = packet.SocketAddr.UNSPECIFIED,
            .serve_repair_addr = packet.SocketAddr.UNSPECIFIED,
            .rpc_addr = packet.SocketAddr.UNSPECIFIED,
            .wallclock = 0,
            .shred_version = 0,
            .version = .{ .major = 0, .minor = 0, .patch = 0, .commit = null },
        };
        
        var offset: usize = 0;
        
        // 1. Pubkey (32 bytes)
        @memcpy(&info.pubkey.data, data[offset..][0..32]);
        offset += 32;
        
        // 2. Wallclock varint (milliseconds)
        var wallclock_varint: u64 = 0;
        var shift: u32 = 0;
        while (offset < data.len) {
            if (shift >= 64) return null; // Varint too large
            const byte = data[offset];
            offset += 1;
            wallclock_varint |= (@as(u64, byte & 0x7F) << @intCast(shift));
            if ((byte & 0x80) == 0) break;
            shift += 7;
        }
        info.wallclock = wallclock_varint;
        
        // 3. Instance creation wallclock (8 bytes, microseconds)
        if (offset + 8 > data.len) return null;
        _ = std.mem.readInt(u64, data[offset..][0..8], .little); // Skip for now
        offset += 8;
        
        // 4. Shred version (2 bytes)
        if (offset + 2 > data.len) return null;
        info.shred_version = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;
        
        // 5. Version info (varints + u32s) - parse to skip correctly
        // Firedancer fd_gossip_msg_parse.c:462 - version_parse()
        // Format: major(varint) + minor(varint) + patch(varint) + commit(u32) + feature_set(u32) + client(varint)
        // Skip major varint
        while (offset < data.len) {
            const byte = data[offset];
            offset += 1;
            if ((byte & 0x80) == 0) break;
        }
        // Skip minor varint
        while (offset < data.len) {
            const byte = data[offset];
            offset += 1;
            if ((byte & 0x80) == 0) break;
        }
        // Skip patch varint
        while (offset < data.len) {
            const byte = data[offset];
            offset += 1;
            if ((byte & 0x80) == 0) break;
        }
        // Skip commit (u32) + feature_set (u32) = 8 bytes
        if (offset + 8 > data.len) return null;
        offset += 8;
        // Skip client varint
        while (offset < data.len) {
            const byte = data[offset];
            offset += 1;
            if ((byte & 0x80) == 0) break;
        }
        
        // 6. Addresses array: [count(compact_u16)] + [addresses...]
        // Firedancer uses compact_u16, NOT regular varint! (fd_gossip_msg_parse.c:465)
        if (offset >= data.len) return null;
        var addr_count: u16 = 0;
        var addr_count_bytes: usize = 0;
        // Compact_u16 decoding (from fd_compact_u16.h)
        if (data[offset] & 0x80 == 0) {
            // 1-byte format: [0x00, 0x80)
            addr_count = data[offset];
            addr_count_bytes = 1;
        } else if (offset + 1 < data.len and (data[offset + 1] & 0x80) == 0) {
            // 2-byte format: [0x80, 0x4000)
            addr_count = @as(u16, @intCast(data[offset] & 0x7F)) | (@as(u16, @intCast(data[offset + 1])) << 7);
            addr_count_bytes = 2;
        } else if (offset + 2 < data.len) {
            // 3-byte format: [0x4000, 0x10000)
            addr_count = @as(u16, @intCast(data[offset] & 0x7F)) | 
                        (@as(u16, @intCast(data[offset + 1] & 0x7F)) << 7) |
                        (@as(u16, @intCast(data[offset + 2])) << 14);
            addr_count_bytes = 3;
        } else {
            return null; // Invalid compact_u16
        }
        offset += addr_count_bytes;
        
        // Each address: [enum_discriminant(4)] + [ip(4 or 16)]
        // Firedancer fd_gossip_msg_parse.c:476-489
        var addresses: [16][4]u8 = undefined;
        var addr_idx: u16 = 0;
        while (addr_idx < addr_count and offset + 8 <= data.len) : (addr_idx += 1) {
            const is_ip6 = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            if (is_ip6 == 0) {
                // IPv4
                @memcpy(&addresses[@intCast(addr_idx)], data[offset..][0..4]);
                offset += 4;
            } else {
                // IPv6 - skip for now
                offset += 16;
                addresses[@intCast(addr_idx)] = .{ 0, 0, 0, 0 }; // Mark as null
            }
        }
        
        // 7. Socket entries: [count(compact_u16)] + [entries...]
        // Firedancer uses compact_u16, NOT regular varint! (fd_gossip_msg_parse.c:499)
        if (offset >= data.len) return null;
        var socket_count: u16 = 0;
        var socket_count_bytes: usize = 0;
        // Compact_u16 decoding (from fd_compact_u16.h)
        if (data[offset] & 0x80 == 0) {
            // 1-byte format: [0x00, 0x80)
            socket_count = data[offset];
            socket_count_bytes = 1;
        } else if (offset + 1 < data.len and (data[offset + 1] & 0x80) == 0) {
            // 2-byte format: [0x80, 0x4000)
            socket_count = @as(u16, @intCast(data[offset] & 0x7F)) | (@as(u16, @intCast(data[offset + 1])) << 7);
            socket_count_bytes = 2;
        } else if (offset + 2 < data.len) {
            // 3-byte format: [0x4000, 0x10000)
            socket_count = @as(u16, @intCast(data[offset] & 0x7F)) | 
                          (@as(u16, @intCast(data[offset + 1] & 0x7F)) << 7) |
                          (@as(u16, @intCast(data[offset + 2])) << 14);
            socket_count_bytes = 3;
        } else {
            return null; // Invalid compact_u16
        }
        offset += socket_count_bytes;
        
        // Each socket entry: [tag(1)] + [addr_index(1)] + [port_offset(compact_u16)]
        // Ports are cumulative offsets (Firedancer fd_gossip_msg_parse.c:505-514)
        var cur_port: u16 = 0;
        var i: u16 = 0;
        while (i < socket_count and offset < data.len) : (i += 1) {
            if (offset >= data.len) break;
            const tag = data[offset];
            offset += 1;
            if (offset >= data.len) break;
            const addr_index = data[offset];
            offset += 1;
            
            // Parse port_offset as compact_u16 (Firedancer fd_gossip_msg_parse.c:512)
            if (offset >= data.len) break;
            var port_offset: u16 = 0;
            var port_offset_bytes: usize = 0;
            // Compact_u16 decoding
            if (data[offset] & 0x80 == 0) {
                // 1-byte format
                port_offset = data[offset];
                port_offset_bytes = 1;
            } else if (offset + 1 < data.len and (data[offset + 1] & 0x80) == 0) {
                // 2-byte format
                port_offset = @as(u16, @intCast(data[offset] & 0x7F)) | (@as(u16, @intCast(data[offset + 1])) << 7);
                port_offset_bytes = 2;
            } else if (offset + 2 < data.len) {
                // 3-byte format
                port_offset = @as(u16, @intCast(data[offset] & 0x7F)) | 
                             (@as(u16, @intCast(data[offset + 1] & 0x7F)) << 7) |
                             (@as(u16, @intCast(data[offset + 2])) << 14);
                port_offset_bytes = 3;
            } else {
                break; // Invalid compact_u16
            }
            offset += port_offset_bytes;
            
            // Ports are cumulative offsets (Firedancer fd_gossip_msg_parse.c:514)
            cur_port = @as(u16, @intCast(@as(u32, cur_port) + @as(u32, port_offset)));
            
            // Map socket tag to ContactInfo field (Firedancer fd_gossip_msg_parse.c:519-523)
            if (addr_index < addr_count and addresses[addr_index][0] != 0) {
                const ip = addresses[addr_index];
                const addr = packet.SocketAddr.ipv4(ip, cur_port);
                
                switch (tag) {
                    0 => info.gossip_addr = addr,      // gossip
                    4 => info.serve_repair_addr = addr, // serve_repair
                    2 => info.rpc_addr = addr,         // rpc
                    5 => info.tpu_addr = addr,         // tpu
                    10 => info.tvu_addr = addr,        // tvu
                    else => {},
                }
            }
        }
        
        // Validate - must have valid gossip address
        if (info.gossip_addr.port() == 0) return null;
        
        return info;
    }

    /// Run one iteration of the gossip protocol
    pub fn tick(self: *Self) !void {
        if (self.sock == null) return error.NotStarted;

        // Receive and process incoming packets
        var batch = try packet.PacketBatch.init(self.allocator, 64);
        defer batch.deinit();

        _ = try self.sock.?.recvBatch(&batch);
        try self.processPackets(&batch);

        // Prune stale contacts periodically
        _ = self.table.pruneStale(self.config.contact_timeout_ms);
    }

    /// Process incoming messages (called from main loop)
    /// This does the full gossip communication cycle
    pub fn processMessages(self: *Self) !void {
        if (self.sock == null) return;

        // Non-blocking receive
        var batch = packet.PacketBatch.init(self.allocator, 16) catch return;
        defer batch.deinit();

        // Try to receive packets
        _ = self.sock.?.recvBatch(&batch) catch return;

        // Process received packets
        self.processPackets(&batch) catch {};

        // Do periodic gossip tasks with timing
        const now = std.time.milliTimestamp();
        
        // Send pull requests every 1 second (to discover peers)
        if (now - self.last_pull_time >= 1000) {
            self.sendPullRequests() catch {};
            self.last_pull_time = now;
            
            // Log pull attempt for debugging
            if (self.table.contactCount() == 0 and self.entrypoints.items.len > 0) {
                std.debug.print("[Gossip] Sending pull to {d} entrypoints (no peers yet)\n", .{self.entrypoints.items.len});
            }
        }
        
        // Push our contact info every 2 seconds
        if (now - self.last_push_time >= 2000) {
            self.pushToPeers() catch {};
            self.last_push_time = now;
        }
        
        // Ping entrypoints every 5 seconds
        if (now - self.last_ping_time >= 5000) {
            self.pingEntrypoints() catch {};
            self.last_ping_time = now;
        }
    }

    /// Ping all entrypoints
    fn pingEntrypoints(self: *Self) !void {
        for (self.entrypoints.items) |ep| {
            self.sendPing(ep) catch {};
            std.debug.print("[Gossip] Sent PING to {}.{}.{}.{}:{}\n", .{
                ep.addr[0], ep.addr[1], ep.addr[2], ep.addr[3], ep.port(),
            });
        }
    }

    /// Stop the gossip service
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.sock) |*s| {
            s.deinit();
            self.sock = null;
        }
    }

    /// Get statistics
    pub fn getStats(self: *const Self) GossipTable.Stats {
        return self.table.stats;
    }

    /// Get number of known peers
    pub fn peerCount(self: *const Self) usize {
        return self.table.contactCount();
    }
    
    /// Run the gossip service loop (call from a dedicated thread)
    /// Optimized: Pre-converts interval configs and caches timestamp
    pub fn run(self: *Self) !void {
        self.running.store(true, .release);
        
        std.log.info("[Gossip] Starting gossip loop", .{});
        
        // Pre-convert config intervals to i64 to avoid repeated casts
        const pull_interval: i64 = @intCast(self.config.pull_interval_ms);
        const push_interval: i64 = @intCast(self.config.push_interval_ms);
        const ping_interval: i64 = @intCast(self.config.ping_interval_ms);
        
        // Pre-allocate packet batch to avoid per-iteration allocation
        var batch = packet.PacketBatch.init(self.allocator, 64) catch {
            std.log.err("[Gossip] Failed to allocate packet batch", .{});
            return error.OutOfMemory;
        };
        defer batch.deinit();
        
        while (self.running.load(.acquire)) {
            // Single timestamp call per iteration
            const now = std.time.milliTimestamp();
            
            // 1. Receive and process incoming packets (reuse batch)
            self.receiveAndProcessWithBatch(&batch) catch |err| {
                if (err != error.WouldBlock) {
                    std.log.warn("[Gossip] Receive error: {}", .{err});
                }
            };
            
            // 2. Periodic pull from peers
            if (now - self.last_pull_time >= pull_interval) {
                self.sendPullRequests() catch {};
                self.last_pull_time = now;
            }
            
            // 3. Periodic push to peers
            if (now - self.last_push_time >= push_interval) {
                self.pushToPeers() catch {};
                self.last_push_time = now;
            }
            
            // 4. Periodic ping (health check)
            if (now - self.last_ping_time >= ping_interval) {
                self.pingEntrypoints() catch {};
                self.last_ping_time = now;
            }
            
            // 5. Prune stale contacts (only occasionally - every 10 seconds)
            if (@mod(now, 10000) < 100) {
                _ = self.table.pruneStale(self.config.contact_timeout_ms);
            }
            
            // Small sleep to prevent busy loop
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        
        std.log.info("[Gossip] Gossip loop stopped", .{});
    }
    
    /// Receive and process with reusable batch (avoids allocation)
    fn receiveAndProcessWithBatch(self: *Self, batch: *packet.PacketBatch) !void {
        if (self.sock == null) return;
        
        // Clear the batch for reuse
        batch.clear();
        
        // Non-blocking receive
        const received = self.sock.?.recvBatch(batch) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        
        if (received > 0) {
            try self.processPackets(batch);
        }
    }
    
    /// Receive and process incoming packets
    fn receiveAndProcess(self: *Self) !void {
        if (self.sock == null) return;
        
        var batch = try packet.PacketBatch.init(self.allocator, 64);
        defer batch.deinit();
        
        // Non-blocking receive
        const received = self.sock.?.recvBatch(&batch) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        
        if (received > 0) {
            try self.processPackets(&batch);
        }
    }
    
    /// Send pull requests to random peers
    fn sendPullRequests(self: *Self) !void {
        if (self.sock == null) return;
        
        // Pull from entrypoints if no peers yet
        if (self.table.contactCount() == 0) {
            for (self.entrypoints.items) |ep| {
                try self.sendPullRequest(ep);
            }
            return;
        }
        
        // Pull from random peers
        var iter = self.table.contacts.iterator();
        var count: usize = 0;
        while (iter.next()) |entry| {
            if (count >= 3) break; // Pull from max 3 peers
            try self.sendPullRequest(entry.value_ptr.gossip_addr);
            count += 1;
        }
        
        self.table.stats.pull_requests_sent += count;
    }
    
    /// Send a pull request to a peer (bincode format with modern ContactInfo, properly signed)
    fn sendPullRequest(self: *Self, target: packet.SocketAddr) !void {
        if (self.sock == null) return;
        if (self.modern_contact_info == null) return;
        
        // CRITICAL: Update wallclock before each send (Firedancer rejects wallclock >15s old)
        self.modern_contact_info.?.wallclock_ms = @intCast(std.time.milliTimestamp());
        
        var pkt = packet.Packet.init();
        
        // Sign the CrdsValue (CrdsData = modern ContactInfo for Firedancer)
        var signature: ?core.Signature = null;
        if (self.keypair) |kp| {
            var signable: [520]u8 = undefined;
            // Use modern ContactInfo signable data (required by Firedancer)
            const signable_len = bincode.getContactInfoSignableData(
                &self.modern_contact_info.?,
                &signable,
            ) catch 0;
            if (signable_len > 0) {
                signature = kp.sign(signable[0..signable_len]);
            }
        }
        
        // Build proper bincode-formatted pull request with modern ContactInfo (for Firedancer)
        const len = bincode.buildPullRequestWithContactInfo(
            &pkt.data,
            &self.modern_contact_info.?,
            signature,
        ) catch |err| {
            std.debug.print("[Gossip] Failed to build pull request: {}\n", .{err});
            return;
        };
        
        pkt.len = @intCast(len);
        pkt.src_addr = target;
        
        _ = try self.sock.?.send(&pkt);
    }
    
    /// Push our CRDS values to random peers
    fn pushToPeers(self: *Self) !void {
        if (self.sock == null) return;
        if (self.table.self_info == null) return;
        
        // Get random peers to push to
        const fanout = @min(self.config.max_push_fanout, self.table.contactCount());
        if (fanout == 0) {
            // Push to entrypoints if no peers
            for (self.entrypoints.items) |ep| {
                try self.sendContactInfo(ep);
            }
            return;
        }
        
        var iter = self.table.contacts.iterator();
        var count: usize = 0;
        while (iter.next()) |entry| {
            if (count >= fanout) break;
            try self.sendContactInfo(entry.value_ptr.gossip_addr);
            count += 1;
        }
    }
    
    /// Send our contact info to a peer (bincode format with LegacyContactInfo, properly signed)
    fn sendContactInfo(self: *Self, target: packet.SocketAddr) !void {
        if (self.sock == null) return;
        if (self.modern_contact_info == null) return;
        
        // CRITICAL: Update wallclock before each send (Firedancer rejects wallclock >15s old)
        self.modern_contact_info.?.wallclock_ms = @intCast(std.time.milliTimestamp());
        
        var pkt = packet.Packet.init();
        
        // Sign the CrdsValue (CrdsData = modern ContactInfo for Firedancer)
        var signature: ?core.Signature = null;
        if (self.keypair) |kp| {
            var signable: [520]u8 = undefined;
            const signable_len = bincode.getContactInfoSignableData(
                &self.modern_contact_info.?,
                &signable,
            ) catch 0;
            if (signable_len > 0) {
                signature = kp.sign(signable[0..signable_len]);
            }
        }
        
        // Build proper bincode-formatted push message with modern ContactInfo (for Firedancer)
        const len = bincode.buildPushMessageWithContactInfo(
            &pkt.data,
            self.identity,
            &self.modern_contact_info.?,
            signature,
        ) catch |err| {
            std.debug.print("[Gossip] Failed to build push message: {}\n", .{err});
            return;
        };
        
        pkt.len = @intCast(len);
        pkt.src_addr = target;
        
        _ = try self.sock.?.send(&pkt);
    }
    
    /// Set our own contact info
    /// IMPORTANT: `ip` MUST be the validator's public IP for the network to send shreds!
    pub fn setSelfInfo(self: *Self, ip: [4]u8, gossip_port: u16, tpu_port: u16, tvu_port: u16, repair_port: u16, rpc_port: u16) void {
        self.public_ip = ip;
        
        self.table.self_info = ContactInfo.initSelf(
            self.identity,
            ip,
            gossip_port,
            tpu_port,
            tvu_port,
            repair_port,
            rpc_port,
        );
        
        // Create bincode-formatted LegacyContactInfo for Agave compatibility
        self.legacy_contact_info = bincode.LegacyContactInfo.initSelf(
            self.identity,
            ip,
            gossip_port,
            tvu_port,
            repair_port,
            tpu_port,
            rpc_port,
            self.shred_version,
        );
        
        // Create modern ContactInfo (required by Firedancer - tag 11)
        self.modern_contact_info = bincode.ContactInfo.initSelf(
            self.identity,
            ip,
            gossip_port,
            tvu_port,
            repair_port,
            tpu_port,
            rpc_port,
            self.shred_version,
        );
        
        // Log the advertised addresses
        std.debug.print("[Gossip] Advertising contact info (modern format for Firedancer):\n", .{});
        std.debug.print("   IP: {d}.{d}.{d}.{d}\n", .{ ip[0], ip[1], ip[2], ip[3] });
        std.debug.print("   Gossip: port {d}\n", .{gossip_port});
        std.debug.print("   TPU: port {d}\n", .{tpu_port});
        std.debug.print("   TVU: port {d}\n", .{tvu_port});
        std.debug.print("   Repair: port {d}\n", .{repair_port});
        std.debug.print("   RPC: port {d}\n", .{rpc_port});
        std.debug.print("   Shred Version: {d}\n", .{self.shred_version});
    }
    
    /// Set the shred version (for cluster compatibility)
    pub fn setShredVersion(self: *Self, version: u16) void {
        self.shred_version = version;
        std.debug.print("[Gossip] Set shred version to {d}\n", .{version});
        
        // Update legacy contact info if already set
        if (self.legacy_contact_info) |*info| {
            info.shred_version = version;
        }
    }
    
    /// Set the keypair for signing gossip messages
    /// CRITICAL: Without a keypair, messages won't be signed and will be ignored by peers!
    pub fn setKeypair(self: *Self, keypair: *const core.Keypair) void {
        self.keypair = keypair;
        std.debug.print("[Gossip] Keypair set - messages will now be signed\n", .{});
    }
    
    /// Sign data using our keypair (called by bincode message builders)
    /// Returns a valid signature if keypair is set, otherwise returns zero signature
    fn signData(self: *const Self, data: []const u8) core.Signature {
        if (self.keypair) |kp| {
            return kp.sign(data);
        }
        // No keypair - return zero signature (messages will likely be rejected)
        std.debug.print("[Gossip] WARNING: No keypair set, message unsigned!\n", .{});
        return core.Signature{ .data = [_]u8{0} ** 64 };
    }
};

/// Cluster type enum (matches core.Config.Cluster)
pub const ClusterType = enum {
    mainnet,
    testnet,
    devnet,
    localnet,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "contact info init" {
    const identity = [_]u8{1} ** 32;
    const info = ContactInfo.initSelf(identity, 8001, 8002, 8003, 8899);

    try std.testing.expectEqual(@as(u16, 8001), info.gossip_addr.port());
    try std.testing.expectEqual(@as(u16, 8002), info.tpu_addr.port());
}

test "gossip table" {
    var table = GossipTable.init(std.testing.allocator);
    defer table.deinit();

    const identity = [_]u8{1} ** 32;
    const info = ContactInfo.initSelf(identity, 8001, 8002, 8003, 8899);

    try table.upsertContact(info);
    try std.testing.expectEqual(@as(usize, 1), table.contactCount());

    const retrieved = table.getContact(identity);
    try std.testing.expect(retrieved != null);
}

test "gossip service init" {
    const identity = [_]u8{0} ** 32;
    var service = GossipService.init(std.testing.allocator, identity, .{});
    defer service.deinit();

    try std.testing.expectEqual(@as(usize, 0), service.table.contactCount());
}
