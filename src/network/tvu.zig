//! Vexor TVU (Transaction Validation Unit)
//!
//! Handles shred reception, repair, and replay coordination.
//! Uses UDP (NOT QUIC) for shreds - optimal for small packets with erasure coding.
//!
//! Pipeline:
//! 1. Receive shreds via AF_XDP (kernel bypass) or UDP fallback
//! 2. Verify shred signatures (parallel/batched)
//! 3. Insert into shred assembler
//! 4. Request repairs for missing shreds
//! 5. Trigger replay when slots complete
//!
//! Performance notes:
//! - AF_XDP: ~10M pps (kernel bypass)
//! - Standard UDP: ~1M pps
//! - QUIC would be slower due to protocol overhead

const std = @import("std");
const core = @import("../core/root.zig");
const packet = @import("packet.zig");
const socket = @import("socket.zig");
const gossip = @import("gossip.zig");
const runtime = @import("../runtime/root.zig");
const consensus = @import("../consensus/root.zig");
const storage = @import("../storage/root.zig");
const accelerated_io = @import("accelerated_io.zig");
const shared_xdp = @import("af_xdp/shared_xdp.zig");

/// TVU service for shred processing
pub const TvuService = struct {
    allocator: std.mem.Allocator,

    /// High-performance I/O for shreds (AF_XDP when available)
    shred_io: ?*accelerated_io.AcceleratedIO,

    /// High-performance I/O for repairs
    repair_io: ?*accelerated_io.AcceleratedIO,

    /// Shared XDP manager (for multi-socket AF_XDP)
    xdp_manager: ?*shared_xdp.SharedXdpManager,

    /// Legacy UDP socket for shreds (fallback)
    shred_socket: ?socket.UdpSocket,

    /// Legacy UDP socket for repairs (fallback)
    repair_socket: ?socket.UdpSocket,

    /// Port configuration
    tvu_port: u16,
    tvu_fwd_port: u16,
    repair_port: u16,

    /// Shred assembler
    shred_assembler: runtime.ShredAssembler,

    /// Reference to ledger DB
    ledger_db: ?*storage.LedgerDb,

    /// Reference to leader schedule
    leader_cache: ?*consensus.leader_schedule.LeaderScheduleCache,

    /// Reference to gossip service for repair peer discovery
    gossip_service: ?*gossip.GossipService,

    /// Running state
    running: std.atomic.Value(bool),

    /// Slots pending replay
    pending_slots: std.ArrayList(core.Slot),

    /// Statistics
    stats: Stats,

    /// Configuration
    config: Config,

    /// Whether using accelerated I/O
    using_accelerated_io: bool,

    const Self = @This();

    pub const Config = struct {
        /// TVU port (for receiving shreds)
        tvu_port: u16 = 8001,

        /// TVU forward port
        tvu_fwd_port: u16 = 8002,

        /// Repair port
        repair_port: u16 = 8003,

        /// Packet batch size
        batch_size: usize = 128,

        /// Maximum slots to track for repair
        max_repair_slots: usize = 100,

        /// Repair request interval (ms)
        repair_interval_ms: u64 = 100,

        /// Enable AF_XDP acceleration (requires root/CAP_NET_RAW)
        enable_af_xdp: bool = true,

        /// Network interface for AF_XDP (empty = auto-detect)
        interface: []const u8 = "",

        /// Validator keypair (for signing repair requests)
        keypair: ?*const core.Keypair = null,
    };

    pub const Stats = struct {
        shreds_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_inserted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_duplicate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_invalid: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repairs_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repairs_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        slots_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        max_slot_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const service = try allocator.create(Self);
        service.* = .{
            .allocator = allocator,
            .shred_io = null,
            .repair_io = null,
            .xdp_manager = null,
            .shred_socket = null,
            .repair_socket = null,
            .tvu_port = config.tvu_port,
            .tvu_fwd_port = config.tvu_fwd_port,
            .repair_port = config.repair_port,
            .shred_assembler = runtime.ShredAssembler.init(allocator),
            .ledger_db = null,
            .leader_cache = null,
            .gossip_service = null,
            .running = std.atomic.Value(bool).init(false),
            .pending_slots = std.ArrayList(core.Slot).init(allocator),
            .stats = .{},
            .config = config,
            .using_accelerated_io = false,
        };
        return service;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Cleanup accelerated I/O
        if (self.shred_io) |io| {
            io.deinit();
        }
        if (self.repair_io) |io| {
            io.deinit();
        }

        // Cleanup shared XDP manager (must be after sockets)
        if (self.xdp_manager) |mgr| {
            mgr.detach() catch {};
            mgr.deinit();
        }

        // Cleanup legacy sockets
        if (self.shred_socket) |*sock| {
            sock.deinit();
        }
        if (self.repair_socket) |*sock| {
            sock.deinit();
        }

        self.shred_assembler.deinit();
        self.pending_slots.deinit();
        self.allocator.destroy(self);
    }

    /// Set external references
    pub fn setLedgerDb(self: *Self, db: *storage.LedgerDb) void {
        self.ledger_db = db;
    }

    pub fn setLeaderCache(self: *Self, cache: *consensus.leader_schedule.LeaderScheduleCache) void {
        self.leader_cache = cache;
    }

    pub fn setGossipService(self: *Self, gs: *gossip.GossipService) void {
        self.gossip_service = gs;
    }

    /// Start the TVU service
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;

        // Try AF_XDP acceleration first (kernel bypass - 10x faster)
        if (self.config.enable_af_xdp) {
            if (false and self.tryStartAcceleratedIO()) {
                self.using_accelerated_io = true;
                self.running.store(true, .seq_cst);
                std.debug.print(
                    \\╔══════════════════════════════════════════════════════════╗
                    \\║  TVU STARTED WITH AF_XDP ACCELERATION ⚡                  ║
                    \\║  Port: {}                                               ║
                    \\║  Expected: ~10M packets/sec                              ║
                    \\╚══════════════════════════════════════════════════════════╝
                    \\
                , .{self.tvu_port});
                return;
            }
            std.debug.print("[TVU] AF_XDP not available, falling back to standard UDP\n", .{});
        }

        // Fallback: Standard UDP sockets
        var shred_sock = try socket.UdpSocket.init();
        errdefer shred_sock.deinit();
        try shred_sock.bindPort(self.tvu_port);
        self.shred_socket = shred_sock;

        var repair_sock = try socket.UdpSocket.init();
        errdefer repair_sock.deinit();
        try repair_sock.bindPort(self.repair_port);
        self.repair_socket = repair_sock;

        self.using_accelerated_io = false;
        self.running.store(true, .seq_cst);
        std.debug.print("[TVU] Started with standard UDP on port {} (~1M pps)\n", .{self.tvu_port});
    }

    /// Try to start with accelerated I/O (AF_XDP with shared XDP program)
    fn tryStartAcceleratedIO(self: *Self) bool {
        // Auto-detect interface if not specified
        const interface = if (self.config.interface.len == 0) blk: {
            const detected = accelerated_io.detectDefaultInterface(self.allocator) catch {
                std.log.warn("[TVU] Failed to auto-detect network interface", .{});
                break :blk "eth0"; // Fallback
            };
            std.log.info("[TVU] Auto-detected interface: {s}", .{detected});
            break :blk detected;
        } else self.config.interface;

        // Create shared XDP manager for ALL validator ports
        const validator_ports = [_]u16{
            self.tvu_port,      // 8003 - shreds
            self.repair_port,   // 8004 - repair requests/responses
            self.tvu_fwd_port,  // 8005 - forwarded shreds (if used)
        };

        const xdp_mgr = shared_xdp.SharedXdpManager.init(
            self.allocator,
            interface,
            &validator_ports,
            .driver, // Use driver mode for best performance
        ) catch |err| {
            std.log.debug("[TVU] Failed to create shared XDP manager: {}", .{err});
            return false;
        };
        errdefer xdp_mgr.deinit();

        // Create shred socket with shared XDP
        const shred_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.tvu_port,
            .queue_id = 0,
            .shared_xdp = xdp_mgr,  // Pass shared manager
            .prefer_xdp = true,
            .umem_frame_count = 4096,
            .zero_copy = true,
        }) catch |err| {
            std.log.debug("[TVU] Failed to create shred socket: {}", .{err});
            xdp_mgr.deinit();
            return false;
        };
        errdefer shred_io.deinit();

        // Check if we actually got kernel bypass
        if (!shred_io.isKernelBypass()) {
            std.log.debug("[TVU] Shred socket didn't get kernel bypass", .{});
            shred_io.deinit();
            xdp_mgr.deinit();
            return false;
        }

        // Create repair socket with SAME shared XDP
        const repair_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.repair_port,
            .queue_id = 1,
            .shared_xdp = xdp_mgr,  // Same manager!
            .prefer_xdp = true,
            .umem_frame_count = 4096,
            .zero_copy = true,
        }) catch |err| {
            std.log.debug("[TVU] Failed to create repair socket: {}", .{err});
            shred_io.deinit();
            xdp_mgr.deinit();
            return false;
        };
        errdefer repair_io.deinit();

        // NOW attach XDP program (after all sockets registered)
        xdp_mgr.attach() catch |err| {
            std.log.warn("[TVU] Failed to attach shared XDP program: {}", .{err});
            repair_io.deinit();
            shred_io.deinit();
            xdp_mgr.deinit();
            return false;
        };

        self.shred_io = shred_io;
        self.repair_io = repair_io;
        self.xdp_manager = xdp_mgr;

        std.log.info("[TVU] ✅ Shared XDP enabled for ports: {any}", .{validator_ports});
        return true;
    }

    /// Stop the TVU service
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
    }

    /// Process incoming shreds (alias for processPackets)
    pub fn processShreds(self: *Self) !void {
        _ = try self.processPackets();
    }

    /// Get the next completed slot, if any
    pub fn getCompletedSlot(self: *Self) ?core.Slot {
        if (self.pending_slots.items.len == 0) return null;
        return self.pending_slots.orderedRemove(0);
    }

    /// Get shreds for a specific slot
    pub fn getShredsForSlot(self: *Self, slot: core.Slot) ![]runtime.Shred {
        return try self.shred_assembler.getShredsForSlot(slot);
    }

    /// Process incoming shred packets (call in main loop)
    pub fn processPackets(self: *Self) !ProcessResult {
        if (!self.running.load(.seq_cst)) return .{};

        var result = ProcessResult{};

        // Receive shreds
        var batch = try packet.PacketBatch.init(self.allocator, self.config.batch_size);
        defer batch.deinit();

        // Check AF_XDP accelerated I/O first (if enabled)
        if (self.shred_io) |io| {
            const xdp_packets = io.receiveBatch(self.config.batch_size) catch |err| {
                std.log.debug("[TVU] AF_XDP receive error: {}", .{err});
                return result; // Return empty result on error
            };
            
            // Convert PacketBuffer to Packet and add to batch
            for (xdp_packets) |*xdp_pkt| {
                if (batch.push()) |pkt| {
                    const copy_len = @min(xdp_pkt.len, pkt.data.len);
                    @memcpy(pkt.data[0..copy_len], xdp_pkt.payload()[0..copy_len]);
                    pkt.len = @intCast(copy_len);
                    pkt.src_addr = xdp_pkt.src_addr;
                    pkt.timestamp_ns = @intCast(xdp_pkt.timestamp);
                    pkt.flags = .{};
                }
            }
        } else if (self.shred_socket) |*sock| {
            // Fallback to standard UDP socket
            _ = try sock.recvBatch(&batch);
        }

        // Process each packet
        for (batch.slice()) |*pkt| {
            const shred_result = self.processShred(pkt);
            result.shreds_processed += 1;

            if (shred_result == .completed_slot) {
                result.slots_completed += 1;
            }
        }

        // Also check repair socket/IO
        batch.clear();
        
        // Check AF_XDP accelerated I/O for repairs first (if enabled)
        if (self.repair_io) |io| {
            const xdp_packets = io.receiveBatch(self.config.batch_size) catch |err| {
                std.log.debug("[TVU] AF_XDP repair receive error: {}", .{err});
                return result; // Return current result on error
            };
            
            // Convert PacketBuffer to Packet and add to batch
            for (xdp_packets) |*xdp_pkt| {
                if (batch.push()) |pkt| {
                    const copy_len = @min(xdp_pkt.len, pkt.data.len);
                    @memcpy(pkt.data[0..copy_len], xdp_pkt.payload()[0..copy_len]);
                    pkt.len = @intCast(copy_len);
                    pkt.src_addr = xdp_pkt.src_addr;
                    pkt.timestamp_ns = @intCast(xdp_pkt.timestamp);
                    pkt.flags = .{ .repair = true };
                }
            }
        } else if (self.repair_socket) |*sock| {
            // Fallback to standard UDP socket
            _ = try sock.recvBatch(&batch);
        }

        for (batch.slice()) |*pkt| {
            self.processRepairResponse(pkt);
            result.repairs_received += 1;
        }

        return result;
    }

    pub const ProcessResult = struct {
        shreds_processed: usize = 0,
        slots_completed: usize = 0,
        repairs_received: usize = 0,
    };

    /// Process a single shred packet
    fn processShred(self: *Self, pkt: *const packet.Packet) ShredResult {
        // DEBUG: Log every packet received
        const pkt_count = self.stats.shreds_received.load(.monotonic);
        if (@mod(pkt_count, 50) == 0) {
            std.log.info("[TVU] Packet #{d} len={d} first4: {x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ pkt_count, pkt.len, pkt.data[0], pkt.data[1], pkt.data[2], pkt.data[3] });
        }
        const count = self.stats.shreds_received.fetchAdd(1, .monotonic);

        // Parse shred
        const shred = runtime.shred.parseShred(pkt.payload()) catch {
            const invalid_count = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
            if (@mod(invalid_count, 100) == 0) {
                std.debug.print("[SHRED] Parse failed #{d}, pkt_len={d}\n", .{ invalid_count, pkt.len });
            }
            return .invalid;
        };
        
        // Log every 100th shred
        if (@mod(count, 100) == 0) {
            std.debug.print("[SHRED] Received #{d} slot={d} idx={d}\n", .{ count, shred.slot(), shred.index() });
        }
        
        // Track maximum slot seen from network shreds
        const shred_slot = shred.slot();
        var current_max = self.stats.max_slot_seen.load(.monotonic);
        while (shred_slot > current_max) {
            const result = self.stats.max_slot_seen.cmpxchgWeak(
                current_max, shred_slot, .monotonic, .monotonic
            );
            if (result) |val| {
                current_max = val;
            } else {
                break; // Successfully updated
            }
        }

        // Verify signature against leader
        if (self.leader_cache) |cache| {
            if (cache.getSlotLeader(shred_slot)) |leader_bytes| {
                const leader = core.Pubkey{ .data = leader_bytes };
                if (!shred.verifySignature(&leader)) {
                    _ = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
                    return .invalid;
                }
            }
        }

        // Insert into assembler
        const insert_result = self.shred_assembler.insert(shred) catch {
            return .error_inserting;
        };

        switch (insert_result) {
            .inserted => {
                _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);

                // Store in ledger
                if (self.ledger_db) |db| {
                    db.insertShred(shred.slot(), shred.index(), pkt.payload()) catch {};
                }

                return .inserted;
            },
            .duplicate => {
                _ = self.stats.shreds_duplicate.fetchAdd(1, .monotonic);
                return .duplicate;
            },
            .completed_slot => {
                _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);
                _ = self.stats.slots_completed.fetchAdd(1, .monotonic);

                // Add to pending slots for replay
                self.pending_slots.append(shred.slot()) catch {};

                return .completed_slot;
            },
        }
    }

    const ShredResult = enum {
        inserted,
        duplicate,
        invalid,
        completed_slot,
        error_inserting,
    };

    /// Process repair response
    fn processRepairResponse(self: *Self, pkt: *const packet.Packet) void {
        const count = self.stats.repairs_received.fetchAdd(1, .monotonic);
        if (@mod(count, 100) == 0) {
            std.debug.print("[REPAIR] Received response #{d}, size={d}\n", .{ count, pkt.len });
        }
        // Treat as regular shred
        _ = self.processShred(pkt);
    }

    /// Request repairs for missing shreds
    /// Request repairs using modern signed format (Firedancer-compatible)
    /// Format: [type:4][signature:64][sender:32][recipient:32][timestamp:8][nonce:4][slot:8][shred_idx:8] = 160 bytes
    pub fn requestRepairs(self: *Self, slot: core.Slot, missing_indices: []const u32) !void {
        if (self.repair_socket == null) return;
        const keypair = self.config.keypair orelse return;
        const repair_peers = self.getRepairPeers(slot);
        if (repair_peers.len == 0) return;
        const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
        const nonce: u32 = @truncate(timestamp_ms);
        for (missing_indices) |shred_idx| {
            for (repair_peers[0..@min(3, repair_peers.len)]) |peer| {
                var pkt = packet.Packet.init();
                // Message type: 8 = REPAIR_WINDOW_INDEX (4 bytes LE)
                std.mem.writeInt(u32, pkt.data[0..4], 8, .little);
                // Sender pubkey (bytes 68-99)
                @memcpy(pkt.data[68..100], &keypair.public.data);
                // Recipient pubkey (bytes 100-131)
                @memcpy(pkt.data[100..132], &peer.pubkey);
                // Timestamp in ms (bytes 132-139)
                std.mem.writeInt(u64, pkt.data[132..140], timestamp_ms, .little);
                // Nonce (bytes 140-143)
                std.mem.writeInt(u32, pkt.data[140..144], nonce, .little);
                // Slot (bytes 144-151)
                std.mem.writeInt(u64, pkt.data[144..152], slot, .little);
                // Shred index (bytes 152-159)
                std.mem.writeInt(u64, pkt.data[152..160], shred_idx, .little);
                // Sign bytes 68-159 (everything after signature)
                const signature = keypair.sign(pkt.data[68..160]);
                @memcpy(pkt.data[4..68], &signature.data);
                pkt.len = 160;
                pkt.src_addr = peer.addr;
                _ = self.repair_socket.?.send(&pkt) catch continue;
                _ = self.stats.repairs_sent.fetchAdd(1, .monotonic);
            }
            if (shred_idx == missing_indices[0]) {
                std.debug.print("[REPAIR] Signed request for slot {d} idx {d} to {d} peers\n", .{
                    slot, shred_idx, @min(3, repair_peers.len),
                });
            }
        }
    }
    /// Repair peer info (address + pubkey for signed requests)
    const RepairPeer = struct {
        addr: packet.SocketAddr,
        pubkey: [32]u8,
    };
    /// Get repair peers for a slot (nodes that likely have it)
    /// Queries gossip for peers with valid serve_repair addresses
    fn getRepairPeers(self: *Self, slot: core.Slot) []const RepairPeer {
        _ = slot;
        
        // Static buffer to hold discovered repair peers (persists across calls)
        const S = struct {
            var repair_peers: [5]RepairPeer = undefined;
            var peer_count: usize = 0;
        };
        
        // Try to get peers from gossip
        if (self.gossip_service) |gs| {
            S.peer_count = 0;
            var iter = gs.table.contacts.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr;
                // Check if peer has a valid serve_repair address (port > 0)
                if (info.serve_repair_addr.port() > 0) {
                    S.repair_peers[S.peer_count] = .{ .addr = info.serve_repair_addr, .pubkey = info.pubkey.data };
                    S.peer_count += 1;
                    if (S.peer_count >= 5) break;
                }
            }
            
            if (S.peer_count > 0) {
                std.debug.print("[REPAIR] Got {d} peers from gossip\n", .{S.peer_count});
                return S.repair_peers[0..S.peer_count];
            }
        }
        
        // Fallback: hardcoded testnet repair peers
        std.debug.print("[REPAIR] Using fallback hardcoded peers (gossip had 0)\n", .{});
        const static_repair_peers = &[_]RepairPeer{
            .{ .addr = packet.SocketAddr.ipv4(.{ 192, 155, 103, 41 }, 8013), .pubkey = [_]u8{0} ** 32 },
            .{ .addr = packet.SocketAddr.ipv4(.{ 104, 250, 133, 50 }, 8012), .pubkey = [_]u8{0} ** 32 },
            .{ .addr = packet.SocketAddr.ipv4(.{ 147, 28, 169, 89 }, 8013), .pubkey = [_]u8{0} ** 32 },
        };
        return static_repair_peers;
    }
    
    /// Run the TVU receive loop (call from dedicated thread)
    pub fn run(self: *Self) void {
        std.debug.print("[TVU-THREAD] run() called, starting...\n", .{});
        self.running.store(true, .release);
        
        std.log.info("[TVU] Starting receive loop on port {}", .{self.tvu_port});
        
        while (self.running.load(.acquire)) {
            // Process incoming packets
            _ = self.processPackets() catch |err| {
                std.log.warn("[TVU] Packet processing error: {}", .{err});
                continue;
            };
            
            // Check for missing shreds and request repairs
            self.checkAndRequestRepairs() catch {};
            
            // Small sleep to prevent busy loop when no packets
            std.time.sleep(1 * std.time.ns_per_ms);
        }
        
        std.log.info("[TVU] Receive loop stopped", .{});
    }
    
    /// Check for missing shreds and request repairs
    fn checkAndRequestRepairs(self: *Self) !void {
        // Check each slot in assembler for gaps
        const slots = self.shred_assembler.getInProgressSlots() catch return;
        
        for (slots) |slot| {
            const missing = self.shred_assembler.getMissingIndices(slot) catch continue;
            if (missing.len > 0) {
                try self.requestRepairs(slot, missing);
            }
        }
    }

    /// Get pending slots ready for replay
    pub fn getPendingSlots(self: *Self) []const core.Slot {
        return self.pending_slots.items;
    }

    /// Clear a pending slot after replay
    pub fn clearPendingSlot(self: *Self, slot: core.Slot) void {
        for (self.pending_slots.items, 0..) |s, i| {
            if (s == slot) {
                _ = self.pending_slots.orderedRemove(i);
                break;
            }
        }
    }

    /// Print statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print(
            \\
            \\═══ TVU Statistics ═══
            \\Shreds received:  {}
            \\Shreds inserted:  {}
            \\Shreds duplicate: {}
            \\Shreds invalid:   {}
            \\Repairs sent:     {}
            \\Repairs received: {}
            \\Slots completed:  {}
            \\══════════════════════
            \\
        , .{
            self.stats.shreds_received.load(.seq_cst),
            self.stats.shreds_inserted.load(.seq_cst),
            self.stats.shreds_duplicate.load(.seq_cst),
            self.stats.shreds_invalid.load(.seq_cst),
            self.stats.repairs_sent.load(.seq_cst),
            self.stats.repairs_received.load(.seq_cst),
            self.stats.slots_completed.load(.seq_cst),
        });
    }
};

/// Turbine protocol helper
pub const Turbine = struct {
    allocator: std.mem.Allocator,

    /// Shred retransmit tree
    retransmit_peers: std.ArrayList(packet.SocketAddr),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .retransmit_peers = std.ArrayList(packet.SocketAddr).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.retransmit_peers.deinit();
    }

    /// Calculate retransmit peers based on stake
    pub fn calculateRetransmitPeers(
        self: *Self,
        cluster_nodes: []const gossip.ContactInfo,
        our_index: usize,
    ) !void {
        self.retransmit_peers.clearRetainingCapacity();

        // Turbine tree calculation
        // Each node forwards to a subset of peers based on position in tree
        const fanout: usize = 200;

        const start = our_index * fanout;
        const end = @min(start + fanout, cluster_nodes.len);

        for (cluster_nodes[start..end]) |node| {
            try self.retransmit_peers.append(node.tvu_addr);
        }
    }

    /// Retransmit shred to peers
    pub fn retransmit(self: *Self, shred_data: []const u8, sock: *socket.UdpSocket) !usize {
        var sent: usize = 0;

        for (self.retransmit_peers.items) |peer| {
            var pkt = packet.Packet.init();
            @memcpy(pkt.data[0..shred_data.len], shred_data);
            pkt.len = @intCast(shred_data.len);
            pkt.src_addr = peer;

            if (sock.send(&pkt) catch null) |_| {
                sent += 1;
            }
        }

        return sent;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "tvu service init" {
    var service = try TvuService.init(std.testing.allocator, .{});
    defer service.deinit();

    try std.testing.expect(!service.running.load(.seq_cst));
}

test "turbine" {
    var turbine = Turbine.init(std.testing.allocator);
    defer turbine.deinit();

    try std.testing.expectEqual(@as(usize, 0), turbine.retransmit_peers.items.len);
}
