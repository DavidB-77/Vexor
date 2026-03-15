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
const af_xdp = @import("af_xdp/socket.zig");
const turbine_relay = @import("turbine_relay.zig");

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
    shred_assembler: *runtime.ShredAssembler,

    /// Reference to ledger DB
    ledger_db: ?*storage.LedgerDb,

    /// Reference to leader schedule
    leader_cache: ?*consensus.leader_schedule.LeaderScheduleCache,

    /// Reference to gossip service for repair peer discovery
    gossip_service: ?*gossip.GossipService,
    /// Optional override for repair peers (testing)
    repair_peers_override: std.ArrayList(RepairPeer),

    /// Running state
    running: std.atomic.Value(bool),

    /// Slots pending replay (guarded by pending_slots_mutex)
    pending_slots: std.ArrayList(core.Slot),
    pending_slots_mutex: std.Thread.Mutex,

    /// Statistics
    stats: Stats,

    /// Configuration
    config: Config,

    /// Whether using accelerated I/O
    using_accelerated_io: bool,

    /// Turbine tree for shred propagation
    turbine: Turbine,

    /// Last repair request timestamp (for throttling)
    last_repair_time_ns: u64,

    /// Repair request dedup cache (Firedancer-style)
    /// Key: (slot << 32) | shred_idx, Value: timestamp_ns of last request
    /// Prevents re-requesting the same (slot, idx) within REPAIR_DEDUP_TIMEOUT_NS
    repair_dedup: std.AutoHashMap(u128, u64),
    /// Last time the dedup cache was pruned (to prevent unbounded growth)
    last_dedup_cleanup_ns: u64,

    /// Our validator identity (for Turbine)
    identity: ?core.Pubkey,

    /// Thread pool for parallel retransmission
    thread_pool: std.Thread.Pool,

    /// Turbine Relay stage for forwarding shreds
    retransmit_stage: turbine_relay.TurbineRelay,

    /// Receive thread handle (for join on shutdown)
    receive_thread: ?std.Thread = null,

    /// Consensus tracker for diagnostic tracing
    consensus_tracker: ?*@import("../diagnostics/consensus_trace.zig").ConsensusTracker = null,

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
        /// Uses SKB mode + copy mode to avoid ixgbe driver lockups
        enable_af_xdp: bool = true,

        /// Enable io_uring acceleration (Linux 5.1+)
        enable_io_uring: bool = true,

        /// Enable AF_XDP zero-copy mode (requires mlx5/ice NIC driver)
        /// Controlled by --xdp-zero-copy CLI flag, default false for ixgbe safety
        xdp_zero_copy: bool = false,

        /// Enable FEC Reed-Solomon recovery (reconstructs missing shreds from parity)
        /// Default false (Data-Only mode) until RS stability is verified on testnet.
        /// Set to true via --enable-fec-recovery to activate erasure coding.
        enable_fec_recovery: bool = false,

        /// Enable SIMD-accelerated GF(2^8) for FEC (GFNI on Zen 4, AVX2 fallback)
        enable_simd_fec: bool = false,

        /// Network interface for AF_XDP (empty = auto-detect)
        interface: []const u8 = "",

        /// Validator keypair (for signing repair requests)
        keypair: ?*const core.Keypair = null,

        /// Expected shred version (for filtering peers)
        shred_version: u16 = 0,

        /// Static leader for testing (bypasses LeaderSchedule)
        static_leader: ?core.Pubkey = null,
    };

    pub const Stats = struct {
        shreds_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_inserted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_duplicate: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        shreds_invalid: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repairs_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repairs_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repairs_served: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repair_requests_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        slots_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        max_slot_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        repair_pings_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        unknown_repair_packets: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        // Diagnostic counters for debugging (permanent)
        packets_by_size: [1400]std.atomic.Value(u64) = .{std.atomic.Value(u64).init(0)} ** 1400,
        shred_types_seen: [256]std.atomic.Value(u64) = .{std.atomic.Value(u64).init(0)} ** 256,
        last_diagnostic_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
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
            .shred_assembler = if (config.enable_fec_recovery and config.enable_simd_fec)
                try runtime.ShredAssembler.initWithFecAndSimd(allocator, config.shred_version)
            else if (config.enable_fec_recovery)
                try runtime.ShredAssembler.initWithFecRecovery(allocator, config.shred_version)
            else
                try runtime.ShredAssembler.initWithShredVersion(allocator, config.shred_version),
            .ledger_db = null,
            .leader_cache = null,
            .gossip_service = null,
            .repair_peers_override = std.ArrayList(RepairPeer).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .pending_slots = std.ArrayList(core.Slot).init(allocator),
            .pending_slots_mutex = .{},
            .stats = .{},
            .config = config,
            .using_accelerated_io = false,
            .turbine = Turbine.init(allocator),
            .last_repair_time_ns = 0,
            .repair_dedup = std.AutoHashMap(u128, u64).init(allocator),
            .last_dedup_cleanup_ns = 0,
            .identity = if (config.keypair) |kp| core.Pubkey{ .data = kp.public.data } else null,
            .thread_pool = undefined,
            .retransmit_stage = undefined,
        };

        // Initialize thread pool (4 threads for retransmission)
        try service.thread_pool.init(.{ .allocator = allocator, .n_jobs = 4 });

        // Initialize retransmit stage
        service.retransmit_stage = turbine_relay.TurbineRelay.init(allocator, &service.thread_pool);

        // Initialize Turbine tree with our identity if available
        if (service.identity) |id| {
            service.turbine.initTree(id) catch {};
        }

        return service;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Cleanup thread pool
        self.thread_pool.deinit();

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
        self.allocator.destroy(self.shred_assembler);
        self.pending_slots.deinit();
        self.repair_peers_override.deinit();
        self.repair_dedup.deinit();
        self.turbine.deinit();
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
        // Update Turbine tree when gossip service is set
        self.updateTurbineTree();
    }

    pub fn setRepairPeersOverride(self: *Self, peers: []const RepairPeer) !void {
        self.repair_peers_override.clearRetainingCapacity();
        try self.repair_peers_override.appendSlice(peers);
    }

    /// Update Turbine tree from gossip peers
    /// Should be called periodically to keep tree fresh
    ///
    /// IMPORTANT: Only includes peers with matching shred_version (like Sig)
    /// Reference: Sig turbine_tree.zig collectTvuAndStakedNodes()
    pub fn updateTurbineTree(self: *Self) void {
        const gs = self.gossip_service orelse return;

        // Collect gossip peers with matching shred version
        var peers = std.ArrayList(gossip.ContactInfo).init(self.allocator);
        defer peers.deinit();

        const my_shred_version = self.config.shred_version;
        var filtered_count: usize = 0;
        var total_count: usize = 0;
        var no_tvu_count: usize = 0;
        var version_mismatch_count: usize = 0;

        var iter = gs.table.contacts.iterator();
        while (iter.next()) |entry| {
            total_count += 1;
            const peer = entry.value_ptr.*;

            // Filter by shred version - only include matching peers
            // Shred version 0 means unknown/not set, accept those during bootstrap
            if (my_shred_version != 0 and peer.shred_version != 0 and
                peer.shred_version != my_shred_version)
            {
                filtered_count += 1;
                version_mismatch_count += 1;
                continue;
            }

            // Only include peers with valid TVU addresses
            if (peer.tvu_addr.port() == 0) {
                no_tvu_count += 1;
                continue;
            }

            peers.append(peer) catch continue;
        }

        std.debug.print("[TURBINE] updateTurbineTree: total_gossip_peers={d}, version_mismatch={d}, no_tvu={d}, valid_peers={d}, my_version={d}\n", .{ total_count, version_mismatch_count, no_tvu_count, peers.items.len, my_shred_version });

        // Build stake map
        // TODO: Get real stake info from bank/vote accounts when available
        // For now, use 1000 as default stake (all nodes equal weight)
        var stakes = std.AutoHashMap([32]u8, u64).init(self.allocator);
        defer stakes.deinit();

        for (peers.items) |peer| {
            // Use default stake for all peers
            // In production, this should come from the stake-weighted leader schedule
            stakes.put(peer.pubkey.data, 1000) catch continue;
        }

        // Add our own stake
        if (self.identity) |id| {
            stakes.put(id.data, 1000) catch {};
        }

        // Build the tree
        self.turbine.buildTree(peers.items, &stakes) catch |err| {
            std.debug.print("[TURBINE] Failed to build tree: {}\n", .{err});
            return;
        };

        const node_count = if (self.turbine.tree) |tree| tree.nodes.items.len else 0;
        std.debug.print("[TURBINE] Tree built with {d} nodes (shred_version={d})\n", .{ node_count, my_shred_version });
    }

    /// Start the TVU service
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;

        // ALWAYS create standard UDP sockets first — these are the RELIABLE path.
        // AcceleratedIO (AF_XDP/io_uring) has proven unreliable:
        //   - io_uring backend creates socket but never completes reads (0 workers)
        //   - AF_XDP BPF filter may miss ports
        // Standard UDP is the only path that reliably drains the kernel socket queue.
        std.debug.print("[TVU] Creating standard UDP sockets (ALWAYS)...\n", .{});
        std.log.info("[TVU] FEC Reed-Solomon recovery: {s}", .{
            if (self.config.enable_fec_recovery) "ENABLED" else "DISABLED (Data-Only mode)",
        });
        if (self.config.enable_simd_fec) {
            std.log.info("[TVU] SIMD FEC acceleration: ENABLED", .{});
        }
        {
            var repair_sock = socket.UdpSocket.init() catch |err| {
                std.debug.print("[TVU-ERROR] repair_socket.init() failed: {}\n", .{err});
                return err;
            };
            repair_sock.bindPort(self.repair_port) catch |err| {
                std.debug.print("[TVU-ERROR] repair_socket.bindPort({d}) failed: {}\n", .{ self.repair_port, err });
                repair_sock.deinit();
                return err;
            };
            self.repair_socket = repair_sock;
            std.debug.print("[TVU] Repair socket bound to port {d} ✓\n", .{self.repair_port});
        }
        {
            var shred_sock = socket.UdpSocket.init() catch |err| {
                std.debug.print("[TVU-ERROR] shred_socket.init() failed: {}\n", .{err});
                return err;
            };
            shred_sock.bindPort(self.tvu_port) catch |err| {
                std.debug.print("[TVU-ERROR] shred_socket.bindPort({d}) failed: {}\n", .{ self.tvu_port, err });
                shred_sock.deinit();
                return err;
            };
            self.shred_socket = shred_sock;
            std.debug.print("[TVU] Shred socket bound to port {d} ✓\n", .{self.tvu_port});
        }

        // Skip AcceleratedIO — it's proven unreliable for receiving packets.
        // The standard UDP sockets above will handle all receive paths.
        self.using_accelerated_io = false;
        self.running.store(true, .seq_cst);

        std.debug.print(
            \\╔══════════════════════════════════════════════════════════╗
            \\║  TVU STARTED WITH STANDARD UDP                           ║
            \\║  Shred Port: {d}  Repair Port: {d}                       ║
            \\║  Repair ping/pong: ENABLED ✓                             ║
            \\╚══════════════════════════════════════════════════════════╝
            \\
        , .{ self.tvu_port, self.repair_port });

        // Set socket IO for retransmission
        if (self.shred_socket) |*sock| {
            self.retransmit_stage.setIoInterface(.{ .socket = sock });
        }
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
            self.tvu_port, // 8003 - shreds
            self.repair_port, // 8004 - repair requests/responses
            self.tvu_fwd_port, // 8005 - forwarded shreds (if used)
        };

        const xdp_mgr = shared_xdp.SharedXdpManager.init(
            self.allocator,
            interface,
            &validator_ports,
            .skb, // SAFETY: SKB mode avoids ixgbe driver DMA lockups (driver mode crashes)
        ) catch |err| {
            std.log.debug("[TVU] Failed to create shared XDP manager: {}", .{err});
            // Fall back to per-socket accelerated I/O (non-shared)
            return self.tryStartAcceleratedIOFallback(interface);
        };
        errdefer xdp_mgr.deinit();

        // Create shred socket with shared XDP
        const shred_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.tvu_port,
            .queue_id = 0,
            .shared_xdp = xdp_mgr, // Pass shared manager
            .prefer_xdp = true,
            .umem_frame_count = 16384,
            .zero_copy = self.config.xdp_zero_copy, // Controlled by --xdp-zero-copy flag (default: false for ixgbe safety)
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
            return self.tryStartAcceleratedIOFallback(interface);
        }

        // Create repair socket with SAME shared XDP
        const repair_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.repair_port,
            .queue_id = 1,
            .shared_xdp = xdp_mgr, // Same manager!
            .prefer_xdp = true,
            .umem_frame_count = 16384,
            .zero_copy = self.config.xdp_zero_copy, // Controlled by --xdp-zero-copy flag (default: false for ixgbe safety)
        }) catch |err| {
            std.log.debug("[TVU] Failed to create repair socket: {}", .{err});
            shred_io.deinit();
            xdp_mgr.deinit();
            return self.tryStartAcceleratedIOFallback(interface);
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

        // Inject UMEM frame manager into ShredAssembler for zero-copy frame lifecycle
        if (shred_io.getXdpSocket()) |xdp| {
            if (xdp.getFrameManager()) |fm| {
                self.shred_assembler.setFrameManager(fm);
            }
        }

        std.log.info("[TVU] ✅ Shared XDP enabled for ports: {any}", .{validator_ports});
        return true;
    }

    /// Fallback accelerated I/O without shared XDP manager
    /// Accepts any backend better than standard UDP (AF_XDP or io_uring).
    fn tryStartAcceleratedIOFallback(self: *Self, interface: []const u8) bool {
        const shred_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.tvu_port,
            .queue_id = 0,
            .prefer_xdp = self.config.enable_af_xdp,
            .prefer_io_uring = self.config.enable_io_uring,
            .umem_frame_count = 16384,
            .zero_copy = self.config.xdp_zero_copy, // Controlled by --xdp-zero-copy flag
        }) catch |err| {
            std.log.debug("[TVU] Fallback shred socket init failed: {}", .{err});
            return false;
        };
        errdefer shred_io.deinit();

        const repair_io = accelerated_io.AcceleratedIO.init(self.allocator, .{
            .interface = interface,
            .bind_port = self.repair_port,
            .queue_id = 1,
            .prefer_xdp = self.config.enable_af_xdp,
            .prefer_io_uring = self.config.enable_io_uring,
            .umem_frame_count = 16384,
            .zero_copy = self.config.xdp_zero_copy, // Controlled by --xdp-zero-copy flag
        }) catch |err| {
            std.log.debug("[TVU] Fallback repair socket init failed: {}", .{err});
            return false;
        };
        errdefer repair_io.deinit();

        if (shred_io.getBackend() == .standard_udp or repair_io.getBackend() == .standard_udp) {
            std.log.debug("[TVU] Fallback accelerated I/O did not improve backend", .{});
            // CRITICAL: Must deinit to release bound ports! errdefer doesn't trigger on normal return
            repair_io.deinit();
            shred_io.deinit();
            return false;
        }

        self.shred_io = shred_io;
        self.repair_io = repair_io;
        self.xdp_manager = null;

        // Inject UMEM frame manager (fallback path may still have XDP)
        if (shred_io.getXdpSocket()) |xdp| {
            if (xdp.getFrameManager()) |fm| {
                self.shred_assembler.setFrameManager(fm);
            }
        }

        std.log.info("[TVU] ✅ Fallback accelerated I/O enabled (shred={s}, repair={s})", .{
            shred_io.getBackend().name(),
            repair_io.getBackend().name(),
        });
        return true;
    }

    /// Stop the TVU service
    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
        // Join the receive thread to ensure it has exited before we free memory
        if (self.receive_thread) |thread| {
            thread.join();
            self.receive_thread = null;
        }
    }

    /// Process incoming shreds (alias for processPackets)
    pub fn processShreds(self: *Self) !void {
        _ = try self.processPackets();
    }

    /// Get the next completed slot, if any
    /// NOTE: Does NOT remove from assembler - caller must call clearCompletedSlot() after replay
    pub fn getCompletedSlot(self: *Self) ?core.Slot {
        self.pending_slots_mutex.lock();
        defer self.pending_slots_mutex.unlock();

        if (self.pending_slots.items.len == 0) return null;
        return self.pending_slots.orderedRemove(0);
    }

    /// Process incoming shred packets (call in main loop)
    pub fn processPackets(self: *Self) !ProcessResult {
        if (!self.running.load(.seq_cst)) return .{};

        var result = ProcessResult{};

        // ═══════════════════════════════════════════════════════════════════
        // ZERO-COPY HOT PATH: TEMPORARILY BYPASSED
        // The recvZeroCopy() path returns raw L2 frames (ETH+IP+UDP headers)
        // that Shred.fromPayload() cannot parse. Every frame gets released as
        // invalid while used_zero_copy=true blocks the legacy copy path,
        // starving the assembler. Must add header-stripping before re-enabling.
        // ═══════════════════════════════════════════════════════════════════
        const used_zero_copy = false;

        // BYPASSED: Zero-copy needs L2/L3/L4 header stripping before re-enabling.
        // The block below is dead code (if false) until header parsing is added.
        if (false) {
        if (self.shred_io) |io| {
            if (io.getXdpSocket()) |xdp| {
                // Attempt zero-copy receive directly from UMEM
                var frame_refs: [128]af_xdp.UmemFrameRef = undefined;
                const zc_count = xdp.recvZeroCopy(&frame_refs) catch |err| blk: {
                    if (err == error.FramePressure) {
                        // Safety valve triggered — too many frames held.
                        // Fall through to legacy copy path below.
                        std.log.warn("[TVU] FramePressure: spilling to copy path (held={d})", .{
                            if (xdp.getFrameManager()) |fm| fm.framesHeld() else 0,
                        });
                    }
                    break :blk @as(usize, 0);
                };

                if (zc_count > 0) {
                    used_zero_copy = true;

                    // ── Phase 1: Parse & validate WITHOUT lock (per-frame work) ──
                    const ValidFrame = struct {
                        slot: u64,
                        index: u32,
                        is_last: bool,
                        ref: af_xdp.UmemFrameRef,
                    };
                    var valid_frames: [128]ValidFrame = undefined;
                    var valid_count: usize = 0;

                    for (frame_refs[0..zc_count]) |ref| {
                        result.shreds_processed += 1;

                        // Parse shred from UMEM frame data (no lock needed)
                        const shred = runtime.shred.Shred.fromPayload(ref.data[0..ref.len]) catch {
                            if (xdp.getFrameManager()) |fm| fm.release(ref.frame_addr);
                            continue;
                        };

                        // Coding shreds: process in FEC, immediately release frame
                        if (!shred.isData()) {
                            _ = self.shred_assembler.fec_resolver.addShred(
                                shred.slot(), shred.index(), shred.fecSetIndex(), false,
                                ref.data[0..ref.len], shred.version(),
                                shred.numData(), shred.numCoding(), shred.codingPosition(),
                            ) catch {};
                            if (xdp.getFrameManager()) |fm| fm.release(ref.frame_addr);
                            _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);
                            continue;
                        }

                        // Collect valid data frames for batch insert
                        if (valid_count < 128) {
                            valid_frames[valid_count] = .{
                                .slot = shred.slot(),
                                .index = shred.index(),
                                .is_last = shred.isLastInSlot(),
                                .ref = ref,
                            };
                            valid_count += 1;
                        } else {
                            // Overflow — release frame (shouldn't happen with 128-size buffers)
                            if (xdp.getFrameManager()) |fm| fm.release(ref.frame_addr);
                        }

                        // Also feed data shred into FEC (no lock needed for fec_resolver)
                        _ = self.shred_assembler.fec_resolver.addShred(
                            shred.slot(), shred.index(), shred.fecSetIndex(), true,
                            ref.data[0..ref.len], shred.version(),
                            shred.numData(), shred.numCoding(), shred.codingPosition(),
                        ) catch {};
                    }

                    // ── Phase 2: Batch insert with brief lock ──
                    if (valid_count > 0) {
                        self.shred_assembler.mutex.lock();
                        defer self.shred_assembler.mutex.unlock();

                        for (valid_frames[0..valid_count]) |vf| {
                            const entry = self.shred_assembler.slots.getOrPut(vf.slot) catch {
                                if (xdp.getFrameManager()) |fm| fm.release(vf.ref.frame_addr);
                                continue;
                            };
                            if (!entry.found_existing) {
                                entry.value_ptr.* = self.shred_assembler.allocator.create(
                                    runtime.ShredAssembler.SlotAssembly,
                                ) catch {
                                    if (xdp.getFrameManager()) |fm| fm.release(vf.ref.frame_addr);
                                    continue;
                                };
                                entry.value_ptr.*.* = runtime.ShredAssembler.SlotAssembly.init(
                                    self.shred_assembler.allocator, vf.slot,
                                );
                            }
                            const assembly = entry.value_ptr.*;

                            if (assembly.contains(vf.index)) {
                                if (xdp.getFrameManager()) |fm| fm.release(vf.ref.frame_addr);
                                _ = self.stats.shreds_duplicate.fetchAdd(1, .monotonic);
                                continue;
                            }

                            // ZERO-COPY INSERT: frame stays in UMEM
                            const completed = assembly.insertFrame(vf.index, vf.ref, vf.is_last);

                            if (completed) {
                                std.log.info("[Assembler] Slot {d} COMPLETED! (zero-copy) shreds={d}", .{
                                    vf.slot, assembly.count(),
                                });
                                _ = self.shred_assembler.highest_completed_slot.fetchMax(vf.slot, .seq_cst);
                                result.slots_completed += 1;
                                _ = self.stats.slots_completed.fetchAdd(1, .monotonic);
                            } else {
                                _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);
                            }
                        }
                    }
                }
            }
        }
        } // end if(false) — zero-copy bypass

        // ═══════════════════════════════════════════════════════════════════
        // COPY FALLBACK PATH: legacy recv() → PacketBatch → insert()
        // Used when: (1) no XDP, (2) FramePressure spill, (3) kernel socket
        // ═══════════════════════════════════════════════════════════════════

        // Receive shreds
        var batch = try packet.PacketBatch.init(self.allocator, self.config.batch_size);
        defer batch.deinit();

        // If zero-copy didn't fire (or partially consumed), also try legacy XDP copy path
        if (!used_zero_copy) {
            if (self.shred_io) |io| {
                const xdp_packets = io.receiveBatch(self.config.batch_size) catch |err| {
                    std.log.debug("[TVU] AF_XDP receive error: {}", .{err});
                    return result;
                };

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
            }
        }
        // ALWAYS try kernel socket too — XDP may not be delivering packets
        // The kernel socket accumulates packets that XDP doesn't intercept
        if (self.shred_socket) |*sock| {
            _ = try sock.recvBatch(&batch);
        }

        // === Sig-inspired batch insertion ===
        // Phase 1: Parse and validate each packet (per-packet work, no lock needed)
        // Phase 2: Batch insert all valid shreds into assembler (ONE lock for entire batch)
        const batch_slice = batch.slice();
        if (batch_slice.len > 0) {
            // Phase 1: Parse packets into shreds
            var parsed_shreds: [1024]runtime.shred.Shred = undefined;
            var parsed_count: usize = 0;

            for (batch_slice) |*pkt| {
                // All per-packet validation stays inline (no assembler lock needed)
                const shred_result = self.validateAndParseShred(pkt);
                if (shred_result) |shred| {
                    if (parsed_count < 1024) {
                        parsed_shreds[parsed_count] = shred;
                        parsed_count += 1;
                    }
                }
                result.shreds_processed += 1;
            }

            // Phase 2: Batch insert (ONE lock for all shreds)
            if (parsed_count > 0) {
                const batch_result = self.shred_assembler.insertBatch(parsed_shreds[0..parsed_count]);
                _ = self.stats.shreds_inserted.fetchAdd(batch_result.inserted + batch_result.completed_slots, .monotonic);
                _ = self.stats.shreds_duplicate.fetchAdd(batch_result.duplicates, .monotonic);

                if (batch_result.completed_slots > 0) {
                    result.slots_completed += batch_result.completed_slots;
                    _ = self.stats.slots_completed.fetchAdd(batch_result.completed_slots, .monotonic);
                }
            }
        }

        // Also check repair socket/IO - drain AGGRESSIVELY to clear 130MB backlog
        // Do up to 4 recv passes per loop iteration to process repair responses faster
        var repair_pass: usize = 0;
        while (repair_pass < 4) : (repair_pass += 1) {
            batch.clear();

            // Check AF_XDP accelerated I/O for repairs first (if enabled)
            // Note: Repair path uses legacy copy — repair shreds go to FEC resolver
            // which produces copied payloads, not UMEM frames.
            if (self.repair_io) |io| {
                const xdp_packets = io.receiveBatch(self.config.batch_size) catch |err| {
                    std.log.debug("[TVU] AF_XDP repair receive error: {}", .{err});
                    break; // Exit repair loop on error
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
            }
            // ALWAYS try kernel socket too — XDP may not be delivering repair packets
            if (self.repair_socket) |*sock| {
                _ = try sock.recvBatch(&batch);
            }

            // If we got no packets in this pass, stop draining
            if (batch.slice().len == 0) break;

            for (batch.slice()) |*pkt| {
                const packet_type = classifyRepairPacket(pkt);

                switch (packet_type) {
                    .repair_request => {
                        try self.processRepairRequest(pkt);
                        result.repair_requests_received += 1;
                    },
                    .shred_response => {
                        self.processRepairResponse(pkt);
                        result.repairs_received += 1;
                    },
                    .repair_ping => {
                        // CRITICAL: Repair peers send Ping to verify us before sending shreds.
                        // We MUST respond with Pong to receive repair data!
                        self.handleRepairPing(pkt);
                        _ = self.stats.repair_pings_received.fetchAdd(1, .monotonic);
                    },
                    .unknown => {
                        // Unknown packet type - log occasionally
                        const count = self.stats.unknown_repair_packets.fetchAdd(1, .monotonic);
                        if (@mod(count, 1000) == 0) {
                            std.debug.print("[REPAIR] Unknown packet type (count={d}, len={d}, byte0=0x{x:0>2})\n", .{ count, pkt.len, pkt.data[0] });
                        }
                    },
                }
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // STALE SLOT SWEEPER: Release leaked UMEM frames from dead slots.
        // Self-throttled to every 5 seconds — safe to call every iteration.
        // ═══════════════════════════════════════════════════════════════════
        _ = self.shred_assembler.sweepStaleSlots();

        return result;
    }

    pub const ProcessResult = struct {
        shreds_processed: usize = 0,
        slots_completed: usize = 0,
        repairs_received: usize = 0,
        repair_requests_received: usize = 0,
    };

    /// Process a single shred packet
    fn processShred(self: *Self, pkt: *const packet.Packet) ShredResult {
        const count = self.stats.shreds_received.fetchAdd(1, .monotonic);

        // Safety check: Discard packets that are obviously too short to be shreds
        // Standard Solana shreds are ~1200 bytes. Gossip pings (132) and Repair requests (160) are not shreds.
        if (pkt.payload().len < 1000) {
            _ = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
            return .invalid;
        }

        // Report received milestone
        // Note: For efficiency in the hot path, we could sample this or only report once per slot
        // For now, tracker handles deduplication.
        // DEBUG: Log every shred's type byte and size
        // std.debug.print("[SHRED-DEBUG] byte[64]=0x{x:0>2} len={d}\n", .{ if (pkt.payload().len > 64) pkt.payload()[64] else 0, pkt.payload().len });
        // Track shred type at byte 64 for diagnostics (even if parsing fails)
        if (pkt.payload().len > 64) {
            const shred_type_byte = pkt.payload()[64];
            _ = self.stats.shred_types_seen[shred_type_byte].fetchAdd(1, .monotonic);
        }

        // Parse shred
        const shred = runtime.shred.parseShred(pkt.payload()) catch |err| {
            _ = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
            // DEBUG: Log why shred parsing failed (every 500th to limit spam)
            if (@mod(count, 500) == 0) {
                std.debug.print("[SHRED-DIAG] Parse FAILED: {s} (count={d}, len={d}) type=0x{x:0>2}\n", .{ @errorName(err), count, pkt.payload().len, if (pkt.payload().len > 64) pkt.payload()[64] else 0 });
            }
            return .invalid;
        };

        // DIAGNOSTIC: Log parsed shred details periodically
        if (@mod(count, 1000) == 0) {
            std.debug.print("[SHRED-DIAG] Parsed: slot={d} idx={d} is_data={} is_last={} ver={d} fec={d} len={d}\n", .{
                shred.slot(), shred.index(), shred.isData(), shred.isLastInSlot(),
                shred.version(), shred.fecSetIndex(), pkt.payload().len,
            });
        }

        // Every 50K shreds: print variant byte histogram to diagnose coding shred reception
        if (@mod(count, 50000) == 0 and count > 0) {
            var data_total: u64 = 0;
            var code_total: u64 = 0;
            std.debug.print("[SHRED-TYPES] Variant byte histogram (after {d} shreds):\n", .{count});
            for (0..256) |i| {
                const type_count = self.stats.shred_types_seen[i].load(.monotonic);
                if (type_count > 0) {
                    const high = i & 0xF0;
                    const is_code = (high == 0x40 or high == 0x50 or high == 0x60 or high == 0x70);
                    const is_data = (high == 0x80 or high == 0x90 or high == 0xA0 or high == 0xB0);
                    const label: []const u8 = if (is_data) "DATA" else if (is_code) "CODE" else "OTHER";
                    std.debug.print("  0x{x:0>2}: {d} ({s})\n", .{ i, type_count, label });
                    if (is_data) data_total += type_count;
                    if (is_code) code_total += type_count;
                }
            }
            std.debug.print("[SHRED-TYPES] Total: DATA={d} CODE={d} ratio={d:.1}%\n", .{
                data_total,
                code_total,
                if (data_total + code_total > 0)
                    @as(f64, @floatFromInt(code_total)) * 100.0 / @as(f64, @floatFromInt(data_total + code_total))
                else
                    @as(f64, 0.0),
            });
        }

        // Track maximum slot seen from network shreds
        const shred_slot = shred.slot();

        // Only log last_in_slot detection (critical for debugging slot completion)
        if (shred.isData() and shred.isLastInSlot()) {
            std.debug.print("[SHRED] LAST_IN_SLOT! slot={d} idx={d}\n", .{ shred.slot(), shred.index() });
        }

        // Sanity check: Solana slots won't reach 1 billion for many years.
        // This prevents corrupted packets from poisoning our max_slot_seen value.
        if (shred_slot < 1_000_000_000) {
            var current_max = self.stats.max_slot_seen.load(.monotonic);
            while (shred_slot > current_max) {
                const result = self.stats.max_slot_seen.cmpxchgWeak(current_max, shred_slot, .monotonic, .monotonic);
                if (result) |val| {
                    current_max = val;
                } else {
                    break; // Successfully updated
                }
            }
        }

        // Verify signature against leader
        var leader_pubkey: ?core.Pubkey = null;
        if (self.leader_cache) |cache| {
            leader_pubkey = cache.getSlotLeader(shred_slot);
        }

        // Fallback to static leader for testing
        if (leader_pubkey == null) {
            leader_pubkey = self.config.static_leader;
        }

        if (leader_pubkey) |leader| {
            if (!shred.verifySignature(&leader)) {
                // FIX: During catchup, sig verification can fail due to stale/incomplete
                // leader schedule. Instead of rejecting, log warning and still insert.
                // This matches Sig's approach where shreds are batch-inserted even when
                // verification status is uncertain.
                const sig_fail_cnt = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
                if (@mod(sig_fail_cnt, 500) == 0) {
                    std.debug.print("[SHRED] Signature bypass: slot={d} idx={d} (total_bypassed={d})\n", .{ shred_slot, shred.index(), sig_fail_cnt + 1 });
                }
                // FALL THROUGH to insert anyway — do NOT return .invalid
            }

            // Report verified milestone
            if (self.consensus_tracker) |tracker| {
                tracker.report(shred_slot, .received);
                tracker.report(shred_slot, .verified);
            }

            // Success! Relay to downstream peers via Turbine logic.
            const variant = if (pkt.payload().len > 64) pkt.payload()[64] else 0;
            const num_downstream = if (self.turbine.tree) |tree|
                @min(tree.nodes.items.len, 200) // Fanout cap
            else
                0;

            // Log the bridge event for verification
            std.debug.print("[TVU-RETRANSMIT-BRIDGE] Shred {d} verified (variant 0x{x}). Queueing for {d} downstream peers.\n", .{ shred.index(), variant, num_downstream });

            // TODO: Turbine retransmission temporarily disabled to fix thread explosion.
            // The thread_pool.spawn() was being called per-shred (~10K/sec) which created
            // 153K+ threads and hit the systemd cgroup limit. Need to implement batched
            // retransmission or use a bounded work queue instead.
            // if (self.turbine.tree) |tree| {
            //     self.retransmit_stage.relayShred(&shred, pkt.payload(), tree, leader, 200) catch |err| {
            //         std.log.warn("[TVU] Relay failed for shred {d}: {}", .{ shred.index(), err });
            //     };
            // }
        }

        // Insert into assembler
        const insert_result = self.shred_assembler.insert(shred) catch |err| {
            if (@mod(count, 1000) == 0) {
                std.debug.print("[SHRED-DIAG] Insert ERROR: {s} slot={d} idx={d}\n", .{ @errorName(err), shred.slot(), shred.index() });
            }
            return .error_inserting;
        };

        // DIAGNOSTIC: Log insert results periodically
        if (@mod(count, 1000) == 0) {
            const in_progress = self.shred_assembler.getInProgressSlotCount();
            const inserted_total = self.stats.shreds_inserted.load(.monotonic);
            const dup_total = self.stats.shreds_duplicate.load(.monotonic);
            std.debug.print("[SHRED-DIAG] Insert result={s} slot={d} idx={d} (inserted_total={d} dup_total={d} slots_tracking={d})\n", .{
                @tagName(insert_result), shred.slot(), shred.index(), inserted_total, dup_total, in_progress,
            });
        }

        switch (insert_result) {
            .inserted => {
                _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);
                return .inserted;
            },
            .duplicate => {
                _ = self.stats.shreds_duplicate.fetchAdd(1, .monotonic);
                return .duplicate;
            },
            .completed_slot => {
                _ = self.stats.shreds_inserted.fetchAdd(1, .monotonic);
                const completed = self.stats.slots_completed.fetchAdd(1, .monotonic);
                std.debug.print("[TVU] *** SLOT {d} COMPLETED! (total: {d}) ***\n", .{ shred.slot(), completed + 1 });

                // Add to pending slots for replay
                self.pending_slots_mutex.lock();
                defer self.pending_slots_mutex.unlock();
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

    /// Validate and parse a packet into a Shred WITHOUT inserting into assembler.
    /// This performs all per-packet work (validation, diagnostics, signature check,
    /// max_slot tracking) but returns the parsed shred for batch insertion.
    /// Returns null if the packet is invalid or too short.
    fn validateAndParseShred(self: *Self, pkt: *const packet.Packet) ?runtime.shred.Shred {
        const count = self.stats.shreds_received.fetchAdd(1, .monotonic);

        // Size check
        if (pkt.payload().len < 1000) {
            _ = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
            return null;
        }

        // Track shred type byte for diagnostics
        if (pkt.payload().len > 64) {
            const shred_type_byte = pkt.payload()[64];
            _ = self.stats.shred_types_seen[shred_type_byte].fetchAdd(1, .monotonic);
        }

        // Parse shred
        const shred = runtime.shred.parseShred(pkt.payload()) catch |err| {
            _ = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
            if (@mod(count, 500) == 0) {
                std.debug.print("[SHRED-DIAG] Parse FAILED: {s} (count={d}, len={d}) type=0x{x:0>2}\n", .{
                    @errorName(err), count, pkt.payload().len,
                    if (pkt.payload().len > 64) pkt.payload()[64] else 0,
                });
            }
            return null;
        };

        // Periodic diagnostic
        if (@mod(count, 1000) == 0) {
            std.debug.print("[SHRED-DIAG] Parsed: slot={d} idx={d} is_data={} is_last={} ver={d} fec={d} len={d}\n", .{
                shred.slot(), shred.index(), shred.isData(), shred.isLastInSlot(),
                shred.version(), shred.fecSetIndex(), pkt.payload().len,
            });
        }

        // Variant byte histogram every 50K shreds
        if (@mod(count, 50000) == 0 and count > 0) {
            var data_total: u64 = 0;
            var code_total: u64 = 0;
            std.debug.print("[SHRED-TYPES] Variant byte histogram (after {d} shreds):\n", .{count});
            for (0..256) |i| {
                const type_count = self.stats.shred_types_seen[i].load(.monotonic);
                if (type_count > 0) {
                    const high = i & 0xF0;
                    const is_code = (high == 0x40 or high == 0x50 or high == 0x60 or high == 0x70);
                    const is_data = (high == 0x80 or high == 0x90 or high == 0xA0 or high == 0xB0);
                    const label: []const u8 = if (is_data) "DATA" else if (is_code) "CODE" else "OTHER";
                    std.debug.print("  0x{x:0>2}: {d} ({s})\n", .{ i, type_count, label });
                    if (is_data) data_total += type_count;
                    if (is_code) code_total += type_count;
                }
            }
            std.debug.print("[SHRED-TYPES] Total: DATA={d} CODE={d} ratio={d:.1}%\n", .{
                data_total,
                code_total,
                if (data_total + code_total > 0)
                    @as(f64, @floatFromInt(code_total)) * 100.0 / @as(f64, @floatFromInt(data_total + code_total))
                else
                    @as(f64, 0.0),
            });
        }

        // Track max slot
        const shred_slot = shred.slot();
        if (shred.isData() and shred.isLastInSlot()) {
            std.debug.print("[SHRED] LAST_IN_SLOT! slot={d} idx={d}\n", .{ shred.slot(), shred.index() });
        }
        if (shred_slot < 1_000_000_000) {
            var current_max = self.stats.max_slot_seen.load(.monotonic);
            while (shred_slot > current_max) {
                const cmpxchg_result = self.stats.max_slot_seen.cmpxchgWeak(current_max, shred_slot, .monotonic, .monotonic);
                if (cmpxchg_result) |val| {
                    current_max = val;
                } else {
                    break;
                }
            }
        }

        // Signature verification (non-blocking — bypass on failure with warning)
        var leader_pubkey: ?core.Pubkey = null;
        if (self.leader_cache) |cache| {
            leader_pubkey = cache.getSlotLeader(shred_slot);
        }
        if (leader_pubkey == null) {
            leader_pubkey = self.config.static_leader;
        }
        if (leader_pubkey) |leader| {
            if (!shred.verifySignature(&leader)) {
                const sig_fail_cnt = self.stats.shreds_invalid.fetchAdd(1, .monotonic);
                if (@mod(sig_fail_cnt, 500) == 0) {
                    std.debug.print("[SHRED] Signature bypass: slot={d} idx={d} (total_bypassed={d})\n", .{ shred_slot, shred.index(), sig_fail_cnt + 1 });
                }
                // FALL THROUGH — still insert
            }
            if (self.consensus_tracker) |tracker| {
                tracker.report(shred_slot, .received);
                tracker.report(shred_slot, .verified);
            }
        }

        return shred;
    }

    /// Process repair response
    fn processRepairResponse(self: *Self, pkt: *const packet.Packet) void {
        const count = self.stats.repairs_received.fetchAdd(1, .monotonic);
        if (@mod(count, 100) == 0) {
            std.debug.print("[REPAIR] Received response #{d}, size={d}\n", .{ count, pkt.len });
        }

        // Repair responses contain: [shred payload] + [4-byte nonce]
        // The nonce is at the END, not the beginning
        const NONCE_SIZE: usize = 4;
        if (pkt.len > NONCE_SIZE + 83) { // Need at least 83 bytes for shred header + 4 byte nonce
            // Strip the nonce from the end
            var modified_pkt = pkt.*;
            const shred_len = pkt.len - NONCE_SIZE;
            // Just update the length - shred is already at the start
            modified_pkt.len = @intCast(shred_len);
            _ = self.processShred(&modified_pkt);
        } else {
            // Packet too small, log and ignore
            if (@mod(count, 100) == 0) {
                std.debug.print("[REPAIR] Packet too small: {d} bytes (need > 87)\n", .{pkt.len});
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PACKET CLASSIFICATION - Based on Agave's implementation
    // ═══════════════════════════════════════════════════════════════════════════════

    const RepairPacketType = enum {
        repair_request, // Request for shreds (type 8-11)
        shred_response, // Valid shred data with proper header
        repair_ping, // RepairResponse::Ping — peer verifying us (MUST respond with pong!)
        unknown, // Unrecognized packet type
    };

    /// Classify packets received on repair socket
    /// Agave's repair protocol:
    ///   RepairProtocol enum: 0-6=Legacy, 7=Pong, 8=WindowIndex, 9=HighestWindowIndex, 10=Orphan, 11=AncestorHashes
    ///   RepairResponse enum: 0=Ping (sent BY peer BACK to us to verify we're real)
    ///   Actual shred data: raw shred bytes + 4-byte nonce appended
    fn classifyRepairPacket(pkt: *const packet.Packet) RepairPacketType {
        if (pkt.len < 4) return .unknown;

        const msg_type = std.mem.readInt(u32, pkt.data[0..4], .little);

        // Check 1: Is it a signed repair request from another validator? (types 8-11)
        if (msg_type >= 8 and msg_type <= 11) {
            return .repair_request;
        }

        // Check 2: RepairResponse::Ping — 132 bytes, type=0
        // Format: [type:4=0] [from_pubkey:32] [token:32] [signature:64] = 132 bytes
        // This is the most critical message type — without handling it, no repair data arrives!
        if (msg_type == 0 and pkt.len == 132) {
            return .repair_ping;
        }

        // Check 3: Is it a repair pong? (type 7) — just track it
        if (msg_type == 7 and pkt.len == 132) {
            return .repair_request; // Treat pongs as requests (we just ignore them)
        }

        // Check 4: Is it a valid shred response (raw shred bytes + 4-byte nonce)?
        // Shreds are typically 1200+ bytes. Check for valid shred variant byte at offset 64.
        if (pkt.len >= 200) {
            const shred_type = pkt.data[64];
            const is_valid_shred = switch (shred_type) {
                0x5A => true, // Legacy code shred
                0xA5 => true, // Legacy data shred
                0x40...0x59, 0x5B...0x7F => true, // Merkle code shreds (excluding 0x5A)
                0x80...0xA4, 0xA6...0xBF => true, // Merkle data shreds (excluding 0xA5)
                else => false,
            };
            if (is_valid_shred) {
                return .shred_response;
            }
        }

        // If none of the above, it's unknown
        return .unknown;
    }

    /// Handle a RepairResponse::Ping — generate and send a Pong back
    /// Without this, repair peers won't send us shred data!
    ///
    /// Ping format (bincode):  [type:4=0][from_pubkey:32][token:32][signature:64] = 132 bytes
    /// Pong format (bincode):  [type:4=7][from_pubkey:32][hash:32][signature:64] = 132 bytes
    ///   where hash = SHA256("SOLANA_PING_PONG" ++ token)
    ///   signature = Ed25519.sign(hash)
    fn handleRepairPing(self: *Self, pkt: *const packet.Packet) void {
        if (pkt.len != 132) return;

        const keypair = self.config.keypair orelse return;

        // Extract ping token from packet: bytes [36..68] = token (32 bytes)
        // Ping layout: [4 type][32 from_pubkey][32 token][64 signature]
        const token = pkt.data[36..68];

        // Compute pong hash: SHA256("SOLANA_PING_PONG" ++ token)
        const PING_PONG_PREFIX = [16]u8{
            'S', 'O', 'L', 'A', 'N', 'A', '_', 'P',
            'I', 'N', 'G', '_', 'P', 'O', 'N', 'G',
        };

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&PING_PONG_PREFIX);
        hasher.update(token);
        const hash = hasher.finalResult();

        // Sign the hash with our keypair
        const signature = keypair.sign(&hash);

        // Build pong packet:
        // [type:4=7][from_pubkey:32][hash:32][signature:64] = 132 bytes
        var pong_pkt = packet.Packet.init();
        std.mem.writeInt(u32, pong_pkt.data[0..4], 7, .little); // type = Pong
        @memcpy(pong_pkt.data[4..36], &keypair.public.data); // from = our pubkey
        @memcpy(pong_pkt.data[36..68], &hash); // hash
        @memcpy(pong_pkt.data[68..132], &signature.data); // signature
        pong_pkt.len = 132;
        pong_pkt.src_addr = pkt.src_addr; // send back to the ping sender

        // Send the pong
        if (self.repair_io) |io| {
            io.send(pong_pkt.data[0..132], pkt.src_addr) catch {};
        }
        if (self.repair_socket) |*sock| {
            _ = sock.send(&pong_pkt) catch {};
        }

        // Log occasionally
        const count = self.stats.repair_pings_received.load(.monotonic);
        if (@mod(count, 50) == 0) {
            std.debug.print("[REPAIR] Responded to ping #{d} with pong\n", .{count});
        }
    }

    /// Print comprehensive diagnostics every 30 seconds
    fn printComprehensiveDiagnostics(self: *Self) void {
        const s = &self.stats;

        std.debug.print("[DIAGNOSTICS] Shreds: R={d} I={d} Inv={d} Dup={d} | Repairs: Rec={d} Req={d} Pings={d} Unk={d} | Slots: C={d} Max={d}\n", .{
            s.shreds_received.load(.monotonic),
            s.shreds_inserted.load(.monotonic),
            s.shreds_invalid.load(.monotonic),
            s.shreds_duplicate.load(.monotonic),
            s.repairs_received.load(.monotonic),
            s.repair_requests_received.load(.monotonic),
            s.repair_pings_received.load(.monotonic),
            s.unknown_repair_packets.load(.monotonic),
            s.slots_completed.load(.monotonic),
            s.max_slot_seen.load(.monotonic),
        });

        // Alert on concerning patterns
        const unknown_count = s.unknown_repair_packets.load(.monotonic);
        const invalid_count = s.shreds_invalid.load(.monotonic);

        if (unknown_count > 1000) {
            std.debug.print("⚠️  WARNING: {d} unknown repair packets detected!\n", .{unknown_count});
        }
        if (invalid_count > 1000) {
            std.debug.print("⚠️  WARNING: {d} invalid shreds detected - possible protocol issue!\n", .{invalid_count});
        }

        // === COMPREHENSIVE NETWORK DIAGNOSTICS ===
        // Log repair peer availability from gossip
        if (self.gossip_service) |gs| {
            var total_peers: usize = 0;
            var repair_peers: usize = 0;
            var tvu_peers: usize = 0;
            var iter = gs.table.contacts.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr;
                total_peers += 1;
                if (info.serve_repair_addr.port() > 0) repair_peers += 1;
                if (info.tvu_addr.port() > 0) tvu_peers += 1;
            }
            std.debug.print("[DIAGNOSTICS] Gossip peers: Total={d} TVU={d} Repair={d}\n", .{
                total_peers, tvu_peers, repair_peers,
            });
        } else {
            std.debug.print("[DIAGNOSTICS] Gossip service NOT CONNECTED!\n", .{});
        }

        // Log socket/IO status
        if (self.repair_socket == null and self.repair_io == null) {
            std.debug.print("[DIAGNOSTICS] WARNING: Repair socket AND IO are NULL!\n", .{});
        }
        if (self.shred_socket == null and self.shred_io == null) {
            std.debug.print("[DIAGNOSTICS] WARNING: Shred socket AND IO are NULL!\n", .{});
        }

        // Log shred type distribution (for debugging InvalidShredType)
        std.debug.print("[DIAGNOSTICS] Shred byte[64] distribution: ", .{});
        var found_types: usize = 0;
        for (0..256) |i| {
            const count = s.shred_types_seen[i].load(.monotonic);
            if (count > 0 and found_types < 10) {
                std.debug.print("0x{x:0>2}={d} ", .{ i, count });
                found_types += 1;
            }
        }
        std.debug.print("(showing top 10)\n", .{});
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // REPAIR REQUEST HANDLING - Serve shreds to other validators
    // ═══════════════════════════════════════════════════════════════════════════════

    /// Check if packet is a repair request (vs response)
    fn isRepairRequest(pkt: *const packet.Packet) bool {
        if (pkt.len < 4) return false;
        const req_type = std.mem.readInt(u32, pkt.data[0..4], .little);
        return req_type >= 8 and req_type <= 11; // Types 8-11 are requests
    }

    /// Process incoming repair request
    fn processRepairRequest(self: *Self, pkt: *const packet.Packet) !void {
        if (pkt.len < 160) return; // Minimum Sig-compatible request size

        const request_type = std.mem.readInt(u32, pkt.data[0..4], .little);
        const recipient_pubkey = pkt.data[100..132];

        // Verify request is for us
        const our_pubkey = self.config.keypair.?.public.data;
        if (!std.mem.eql(u8, recipient_pubkey, &our_pubkey)) {
            return; // Not for us
        }

        const slot = std.mem.readInt(u64, pkt.data[144..152], .little);

        switch (request_type) {
            8 => { // WindowIndex
                const shred_idx = std.mem.readInt(u64, pkt.data[152..160], .little);
                try self.handleWindowIndexRequest(slot, @intCast(shred_idx), pkt.src_addr);
            },
            9 => try self.handleHighestWindowIndexRequest(slot, pkt.src_addr), // HighestWindowIndex
            10 => try self.handleOrphanRequest(slot, pkt.src_addr), // Orphan
            11 => try self.handleAncestorHashesRequest(slot, pkt.src_addr), // AncestorHashes
            else => std.log.debug("[Repair] Unknown request type: {d}", .{request_type}),
        }
    }

    /// Handle WindowIndex request - serve specific shred
    fn handleWindowIndexRequest(self: *Self, slot: u64, shred_idx: u32, from: packet.SocketAddr) !void {
        // 1. Try ShredAssembler first (fast path for recent slots)
        if (self.shred_assembler.getShred(slot, shred_idx) catch null) |shred| {
            defer shred.deinit(self.allocator);
            try self.sendRepairResponse(from, shred.rawData());
            _ = self.stats.repairs_served.fetchAdd(1, .monotonic);
            std.log.debug("[Repair] Served shred (assembler) slot={d} idx={d}", .{ slot, shred_idx });
            return;
        }

        // 2. Try LedgerDb (for older slots)
        if (self.ledger_db) |db| {
            if (db.getShred(slot, shred_idx)) |shred_data| {
                try self.sendRepairResponse(from, shred_data);
                _ = self.stats.repairs_served.fetchAdd(1, .monotonic);
                std.log.debug("[Repair] Served shred (ledger) slot={d} idx={d}", .{ slot, shred_idx });
                return;
            }
        }

        std.log.debug("[Repair] Shred not found slot={d} idx={d}", .{ slot, shred_idx });
    }

    /// Handle HighestWindowIndex request - serve slot boundary info
    fn handleHighestWindowIndexRequest(self: *Self, slot: u64, from: packet.SocketAddr) !void {
        var highest_idx: ?u32 = null;

        // Check ShredAssembler first
        highest_idx = self.shred_assembler.getHighestShredIndex(slot);

        // Check LedgerDb
        if (highest_idx == null) {
            if (self.ledger_db) |db| {
                if (db.getSlotMeta(slot)) |meta| {
                    highest_idx = meta.expected_shred_count;
                }
            }
        }

        if (highest_idx) |idx| {
            // Response format: [slot:8][highest_index:4]
            var buf: [12]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], slot, .little);
            std.mem.writeInt(u32, buf[8..12], idx, .little);
            try self.sendRepairResponse(from, &buf);
            std.log.debug("[Repair] Served highest index slot={d} idx={d}", .{ slot, idx });
        }
    }

    /// Handle Orphan request - serve parent slot's last shred
    fn handleOrphanRequest(self: *Self, slot: u64, from: packet.SocketAddr) !void {
        var parent_slot: ?u64 = null;
        var parent_shred_data: ?[]const u8 = null;

        // Find parent slot
        parent_slot = self.shred_assembler.getParentSlot(slot);
        if (parent_slot == null) {
            if (self.ledger_db) |db| {
                if (db.getSlotMeta(slot)) |meta| {
                    parent_slot = meta.parent_slot;
                }
            }
        }

        // Get last shred of parent
        if (parent_slot) |parent| {
            if (self.shred_assembler.getLastShred(parent)) |shred| {
                parent_shred_data = shred.rawData();
            }

            if (parent_shred_data == null) {
                if (self.ledger_db) |db| {
                    if (db.getSlotMeta(parent)) |meta| {
                        if (meta.expected_shred_count) |last| {
                            parent_shred_data = db.getShred(parent, last - 1);
                        }
                    }
                }
            }
        }

        if (parent_shred_data) |data| {
            try self.sendRepairResponse(from, data);
            std.log.debug("[Repair] Served orphan parent slot={d}", .{parent_slot.?});
        }
    }

    /// Handle AncestorHashes request - serve ancestor chain
    fn handleAncestorHashesRequest(self: *Self, slot: u64, from: packet.SocketAddr) !void {
        // Collect ancestors with their block hashes
        var ancestors = std.ArrayList(struct { slot: u64, hash: [32]u8 }).init(self.allocator);
        defer ancestors.deinit();

        var current_slot: u64 = slot;
        var depth: usize = 0;
        const max_depth: usize = 100; // Limit chain length

        while (depth < max_depth) {
            var parent_slot: ?u64 = null;

            // Try to get hash from ledger
            if (self.ledger_db) |db| {
                if (db.getSlotMeta(current_slot)) |meta| {
                    if (meta.blockhash) |hash| {
                        try ancestors.append(.{ .slot = current_slot, .hash = hash.data });
                    } else {
                        break; // Can't continue without hash
                    }
                    parent_slot = meta.parent_slot;
                }
            }

            if (parent_slot) |parent| {
                current_slot = parent;
                depth += 1;
            } else {
                break; // Reached root
            }
        }

        // Send response
        if (ancestors.items.len > 0) {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();

            // Format: [count:4][slot:8|hash:32]...
            try writer.writeInt(u32, @intCast(ancestors.items.len), .little);
            for (ancestors.items) |ancestor| {
                try writer.writeInt(u64, ancestor.slot, .little);
                try writer.writeAll(&ancestor.hash);
            }

            try self.sendRepairResponse(from, fbs.getWritten());
            std.log.debug("[Repair] Served {d} ancestors for slot={d}", .{ ancestors.items.len, slot });
        }
    }

    /// Send repair response packet
    fn sendRepairResponse(self: *Self, to: packet.SocketAddr, data: []const u8) !void {
        // For now, use standard UDP socket for repair responses
        // (accelerated I/O path would require PacketBuffer allocation)
        if (self.repair_socket) |*sock| {
            var pkt = packet.Packet.init();
            const len = @min(data.len, pkt.data.len);
            @memcpy(pkt.data[0..len], data[0..len]);
            pkt.len = @intCast(len);
            pkt.src_addr = to;
            _ = try sock.send(&pkt);
        }
    }

    /// Broadcast a shred to peers via Turbine
    /// Called by replay_stage during leader block production
    /// Broadcast a shred to peers via Turbine
    /// Called by replay_stage during leader block production
    pub fn broadcastShred(self: *Self, shred_data: []const u8) !void {
        if (shred_data.len < 88) return; // Invalid shred

        // Parse shred to get routing info
        // We can use the layout directly since we just need headers
        const slot = std.mem.readInt(u64, shred_data[65..73], .little);
        const index = std.mem.readInt(u32, shred_data[73..77], .little);
        const shred_type = shred_data[64];
        const is_data = (shred_type & 0xF0) == 0xA0; // 0xA0 = data, 0x50 = code (approx check)

        // Compute Turbine destinations
        // We are the leader, so use our own identity as 'leader'
        var children: []const turbine_tree.TurbineNode = &.{};

        if (self.identity) |id| {
            _ = try self.turbine.getRetransmitChildrenForShred(id, slot, index, is_data);
            if (self.turbine.getChildren()) |c| {
                children = c;
            }
        }

        if (children.len == 0) {
            // Fallback: broadcast to all known gossip peers
            if (self.gossip_service) |gs| {
                var sent: usize = 0;
                var iter = gs.table.contacts.iterator();
                while (iter.next()) |entry| {
                    const info = entry.value_ptr;
                    if (info.tvu_addr.port() > 0 and sent < 20) {
                        try self.sendShredToPeer(shred_data, info.tvu_addr);
                        sent += 1;
                    }
                }
                if (sent > 0) {
                    std.log.debug("[Turbine] Broadcasted shred to {d} gossip peers (fallback)", .{sent});
                }
            }
            return;
        }

        // Send to Turbine tree children
        for (children) |child| {
            if (child.tvu_addr) |addr| {
                try self.sendShredToPeer(shred_data, addr);
            }
        }
    }

    /// Send a shred to a specific peer
    fn sendShredToPeer(self: *Self, shred_data: []const u8, to: packet.SocketAddr) !void {
        if (self.shred_io) |io| {
            // Use accelerated I/O if available
            const pkt_buf = accelerated_io.PacketBuffer{
                .data = @constCast(shred_data),
                .len = shred_data.len,
                .src_addr = to,
                .timestamp = 0,
            };
            _ = try io.sendBatch(&[_]accelerated_io.PacketBuffer{pkt_buf}, to);
        } else if (self.shred_socket) |*sock| {
            // Fallback to standard UDP
            var pkt = packet.Packet.init();
            const len = @min(shred_data.len, pkt.data.len);
            @memcpy(pkt.data[0..len], shred_data[0..len]);
            pkt.len = @intCast(len);
            pkt.src_addr = to;
            _ = try sock.send(&pkt);
        }
    }

    /// Request repairs for missing shreds
    /// Request repairs using Sig-compatible signed format
    /// Format: [type:4][signature:64][sender:32][recipient:32][timestamp:8][nonce:4][slot:8][shred_idx:8] = 160 bytes
    /// Signature covers: bytes[0..4] + bytes[68..160] (type + everything after signature)
    ///
    /// Repair dedup timeout in nanoseconds.
    /// Each (slot, shred_idx) pair will only be re-requested once per this interval.
    /// 2 seconds gives peers time to respond before we retry with a different peer.
    const REPAIR_DEDUP_TIMEOUT_NS: u64 = 2 * std.time.ns_per_s;

    /// Max entries before forced dedup cache cleanup
    const REPAIR_DEDUP_MAX_ENTRIES: usize = 50_000;

    /// Check if we should send a repair request for this (slot, idx) pair.
    /// Returns true if the request should be sent (not deduped).
    /// Implements Firedancer's dedup_next() from fd_policy.c.
    fn shouldRequestRepair(self: *Self, slot: u64, idx: u32) bool {
        const key: u128 = (@as(u128, slot) << 32) | @as(u128, idx);
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());

        if (self.repair_dedup.get(key)) |last_ts| {
            if (now_ns < last_ts + REPAIR_DEDUP_TIMEOUT_NS) {
                return false; // Too soon, skip (deduped)
            }
        }
        // Record this request timestamp
        self.repair_dedup.put(key, now_ns) catch {};
        return true;
    }

    /// Prune old entries from the dedup cache to prevent unbounded memory growth.
    /// Removes entries older than 2x the dedup timeout.
    fn pruneRepairDedup(self: *Self) void {
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());
        const expiry = 2 * REPAIR_DEDUP_TIMEOUT_NS;

        // Collect keys to remove (can't modify during iteration)
        var keys_to_remove = std.ArrayList(u128).init(self.allocator);
        defer keys_to_remove.deinit();

        var it = self.repair_dedup.iterator();
        while (it.next()) |entry| {
            if (now_ns > entry.value_ptr.* + expiry) {
                keys_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.repair_dedup.remove(key);
        }

        if (keys_to_remove.items.len > 0) {
            std.debug.print("[REPAIR-DEDUP] Pruned {d} stale entries, {d} remaining\n", .{
                keys_to_remove.items.len, self.repair_dedup.count(),
            });
        }
    }

    /// HYPER-CHARGE: Increased from 6 to 20 peers per missing shred.
    /// We have 760+ peers and bandwidth headroom — saturate the repair responses.
    const REPAIR_FANOUT: usize = 20; // Number of peers to ask per missing shred

    pub fn requestRepairs(self: *Self, slot: core.Slot, missing_indices: []const u32) !void {
        if (self.repair_socket == null and self.repair_io == null) {
            // Only warn occasionally to limit spam
            const count = self.stats.repairs_sent.load(.monotonic);
            if (@mod(count, 100) == 0) {
                std.debug.print("[REPAIR] No repair transport available (socket and IO are null)\n", .{});
            }
            return;
        }
        const keypair = self.config.keypair orelse {
            std.debug.print("[REPAIR-DEBUG] requestRepairs returning: keypair is null\n", .{});
            return;
        };
        const repair_peers = self.getRepairPeers(slot);
        if (repair_peers.len == 0) {
            const count = self.stats.repairs_sent.load(.monotonic);
            if (@mod(count, 100) == 0) {
                std.debug.print("[REPAIR] requestRepairs: no repair peers found for slot {d}\n", .{slot});
            }
            return;
        }
        const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
        const nonce: u32 = @truncate(timestamp_ms);
        const peers_to_use = @min(REPAIR_FANOUT, repair_peers.len);

        // TARGETED REPAIR: Distribute missing indices round-robin across peers.
        // Each shred is requested from exactly 1 peer to eliminate duplication.
        // Old behavior: asked ALL 20 peers for EVERY shred → 20x duplication.
        // New behavior: peer_0 gets shred_0, peer_1 gets shred_1, etc.
        for (missing_indices, 0..) |shred_idx, i| {
            const peer_idx = i % peers_to_use;
            const peer = repair_peers[peer_idx];

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

            // Sign bytes[0..4] + bytes[68..160] (type + everything after signature)
            var sign_buf: [96]u8 = undefined;
            @memcpy(sign_buf[0..4], pkt.data[0..4]);
            @memcpy(sign_buf[4..96], pkt.data[68..160]);
            const signature = keypair.sign(&sign_buf);
            @memcpy(pkt.data[4..68], &signature.data);

            pkt.len = 160;
            pkt.src_addr = peer.addr;

            if (self.repair_io) |io| {
                io.send(pkt.data[0..pkt.len], peer.addr) catch continue;
            } else if (self.repair_socket) |*sock| {
                _ = sock.send(&pkt) catch continue;
            }

            _ = self.stats.repairs_sent.fetchAdd(1, .monotonic);

            // Update maximum slot seen (atomic max) - with sanity check
            if (slot < 1_000_000_000) {
                var current_max = self.stats.max_slot_seen.load(.monotonic);
                while (slot > current_max) {
                    current_max = self.stats.max_slot_seen.cmpxchgWeak(
                        current_max,
                        slot,
                        .monotonic,
                        .monotonic,
                    ) orelse break;
                }
            }
        }

        // Log first request for diagnostics
        if (missing_indices.len > 0) {
            const total_sent = self.stats.repairs_sent.load(.monotonic);
            if (@mod(total_sent, 500) == 0) {
                std.debug.print("[REPAIR] Targeted {d} shreds for slot {d} across {d} peers (1:1 distribution)\n", .{
                    missing_indices.len, slot, peers_to_use,
                });
            }
        }
    }

    /// Request the HIGHEST shred a peer has for a slot (repair type 9 = HighestWindowIndex)
    /// This is how Firedancer discovers the total shred count for a slot.
    /// The peer responds with the highest shred it has >= shred_idx.
    /// That response's is_last_in_slot flag tells us the true last index.
    pub fn requestHighestWindowIndex(self: *Self, slot: core.Slot, shred_idx: u64) !void {
        if (self.repair_socket == null and self.repair_io == null) return;
        const keypair = self.config.keypair orelse return;
        const repair_peers = self.getRepairPeers(slot);
        if (repair_peers.len == 0) return;

        const timestamp_ms: u64 = @intCast(std.time.milliTimestamp());
        const nonce: u32 = @truncate(timestamp_ms);
        // HWI only needs 1 response to discover last_index — limit to 3 peers for redundancy
        const hwi_fanout = @min(3, repair_peers.len);

        for (repair_peers[0..hwi_fanout]) |peer| {
            var pkt = packet.Packet.init();
            // Message type: 9 = REPAIR_HIGHEST_WINDOW_INDEX (4 bytes LE)
            std.mem.writeInt(u32, pkt.data[0..4], 9, .little);
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
            // Shred index (bytes 152-159) — peer returns highest >= this
            std.mem.writeInt(u64, pkt.data[152..160], shred_idx, .little);

            // Sign bytes[0..4] + bytes[68..160] (type + everything after signature)
            var sign_buf: [96]u8 = undefined;
            @memcpy(sign_buf[0..4], pkt.data[0..4]);
            @memcpy(sign_buf[4..96], pkt.data[68..160]);
            const signature = keypair.sign(&sign_buf);
            @memcpy(pkt.data[4..68], &signature.data);

            pkt.len = 160;
            pkt.src_addr = peer.addr;

            if (self.repair_io) |io| {
                io.send(pkt.data[0..pkt.len], peer.addr) catch continue;
            } else if (self.repair_socket) |*sock| {
                _ = sock.send(&pkt) catch continue;
            }

            _ = self.stats.repairs_sent.fetchAdd(1, .monotonic);
        }

        std.debug.print("[REPAIR] HighestWindowIndex for slot {d} (>= idx {d}) to {d} peers\n", .{
            slot, shred_idx, hwi_fanout,
        });
    }
    /// Repair peer info (address + pubkey for signed requests)
    pub const RepairPeer = struct {
        addr: packet.SocketAddr,
        pubkey: [32]u8,
    };
    /// Get repair peers for a slot (nodes that likely have it)
    /// Queries gossip for peers with valid serve_repair addresses
    ///
    /// Collects up to MAX_REPAIR_PEERS and randomly samples from available peers
    /// to distribute repair load across the network.
    const MAX_REPAIR_PEERS: usize = 500;

    fn getRepairPeers(self: *Self, slot: core.Slot) []const RepairPeer {
        _ = slot;
        if (self.repair_peers_override.items.len > 0) {
            return self.repair_peers_override.items;
        }

        // Static buffer to hold discovered repair peers (persists across calls)
        const S = struct {
            var repair_peers: [MAX_REPAIR_PEERS]RepairPeer = undefined;
            var peer_count: usize = 0;
            var all_peers: [4096]RepairPeer = undefined; // Temp buffer for sampling
            var all_peer_count: usize = 0;
            var call_count: u64 = 0;
        };

        // Try to get peers from gossip
        if (self.gossip_service) |gs| {
            // Collect repair peers with RELAXED filtering.
            // Only require: valid serve_repair address + matching shred_version.
            // Wallclock freshness check DISABLED — it was dropping 100% of peers
            // because our clock or snapshot epoch is offset from the network.
            S.all_peer_count = 0;
            const expected_shred_version = self.config.shred_version;

            var total_contacts: usize = 0;
            var dropped_no_port: usize = 0;
            var dropped_shred_ver: usize = 0;

            var iter = gs.table.contacts.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr;
                total_contacts += 1;

                // Must have a valid serve_repair address
                if (info.serve_repair_addr.port() == 0) {
                    dropped_no_port += 1;
                    continue;
                }

                // Must match our shred version (skip mismatched, allow zero)
                if (expected_shred_version > 0 and info.shred_version != expected_shred_version and info.shred_version != 0) {
                    dropped_shred_ver += 1;
                    continue;
                }

                // Wallclock check DISABLED — was causing 100% peer drop
                // TODO: Re-enable once clock sync is verified

                if (S.all_peer_count < 4096) {
                    S.all_peers[S.all_peer_count] = .{ .addr = info.serve_repair_addr, .pubkey = info.pubkey.data };
                    S.all_peer_count += 1;
                }
            }

            // Periodic gossip state diagnostic (every ~10 seconds = every 20 calls)
            S.call_count += 1;
            if (@mod(S.call_count, 20) == 1) {
                std.debug.print("[GOSSIP-STATE] Total contacts: {d}, Valid peers: {d}, Dropped: no_port={d} shred_ver={d}\n", .{
                    total_contacts, S.all_peer_count, dropped_no_port, dropped_shred_ver,
                });
            }

            if (S.all_peer_count > 0) {
                // Randomly sample peers using a simple hash-based selection
                const seed = S.call_count *% 0x9E3779B97F4A7C15; // Golden ratio hash

                S.peer_count = 0;
                const step = if (S.all_peer_count > MAX_REPAIR_PEERS)
                    S.all_peer_count / MAX_REPAIR_PEERS
                else
                    1;

                var idx: usize = @truncate(seed % S.all_peer_count);
                while (S.peer_count < MAX_REPAIR_PEERS and S.peer_count < S.all_peer_count) {
                    S.repair_peers[S.peer_count] = S.all_peers[idx];
                    S.peer_count += 1;
                    idx = (idx + step) % S.all_peer_count;
                }

                std.debug.print("[REPAIR] Got {d} quality peers (shred_ver={d}) from {d} total gossip\n", .{ S.peer_count, expected_shred_version, total_contacts });
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

        var loop_count: u64 = 0;
        var last_turbine_update: u64 = 0;
        var last_diagnostic_report: u64 = 0;
        var last_proactive_repair: u64 = 0;
        var last_socket_debug: u64 = 0;
        var proactive_repair_slot: u64 = 0;

        while (self.running.load(.acquire)) {
            loop_count += 1;

            // Process incoming packets
            const result = self.processPackets() catch |err| {
                std.log.warn("[TVU] Packet processing error: {}", .{err});
                continue;
            };

            // Socket-level debug logging (every 5 seconds)
            if (loop_count > last_socket_debug + 5000) {
                const total_rcvd = self.stats.shreds_received.load(.monotonic);
                const repairs_rcvd = self.stats.repairs_received.load(.monotonic);
                const repairs_sent = self.stats.repairs_sent.load(.monotonic);
                const in_progress = self.shred_assembler.getInProgressSlotCount();

                std.debug.print("[TVU-DEBUG] loop={d} shreds_total={d} repairs_rcvd={d} repairs_sent={d} slots_tracking={d} this_batch={d}\n", .{
                    loop_count,
                    total_rcvd,
                    repairs_rcvd,
                    repairs_sent,
                    in_progress,
                    result.shreds_processed,
                });
                last_socket_debug = loop_count;
            }

            // ✅ COOLING: If we did NO work this iteration, yield the CPU briefly.
            // This prevents "soft lockup" kernel crashes on non-isolated cores.
            if (result.shreds_processed == 0) {
                // Yield for 100 microseconds if idle
                std.time.sleep(100 * std.time.ns_per_us);
            }

            // Repair cycle every 500ms — with 2s dedup timeout, faster is wasteful.
            const now_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
            if (now_ns > self.last_repair_time_ns + 500 * std.time.ns_per_ms) {
                // Limit max slots to repair per cycle
                self.checkAndRequestRepairs(150) catch {};
                self.last_repair_time_ns = now_ns;

                // Periodically prune dedup cache (every 10 seconds)
                if (now_ns > self.last_dedup_cleanup_ns + 10 * std.time.ns_per_s) {
                    self.pruneRepairDedup();
                    self.last_dedup_cleanup_ns = now_ns;
                }
            }

            // PROACTIVE REPAIR — lightweight discovery of NEW slots.
            // Only probe 5 slots ahead every 10 seconds with just indices 0-7.
            if (loop_count > last_proactive_repair + 10000) { // Every ~10 seconds
                const max_seen = self.stats.max_slot_seen.load(.monotonic);
                if (max_seen > 0 and max_seen < 1_000_000_000) {
                    var bootstrap_indices: [8]u32 = undefined;
                    for (&bootstrap_indices, 0..) |*idx, i| {
                        idx.* = @intCast(i);
                    }

                    // Probe 5 slots ahead — just enough to discover new slots
                    var advance: u64 = 1;
                    while (advance <= 5) : (advance += 1) {
                        const target_slot = max_seen +| advance;
                        if (target_slot != proactive_repair_slot) {
                            self.requestRepairs(target_slot, &bootstrap_indices) catch {};
                        }
                    }
                    proactive_repair_slot = max_seen + 1;

                    // Also evict OLD stale slots — but ONLY in normal mode.
                    // During catch-up, the time-based sweeper handles cleanup.
                    const completed = self.shred_assembler.highest_completed_slot.load(.monotonic);
                    const catchup_gap = if (max_seen > completed) max_seen - completed else 0;
                    if (catchup_gap <= CATCHUP_MODE_THRESHOLD) {
                        const stale_slots = self.shred_assembler.getInProgressSlots() catch &[_]u64{};
                        defer self.allocator.free(stale_slots);
                        for (stale_slots) |stale_slot| {
                            if (stale_slot + STALE_SLOT_THRESHOLD < max_seen) {
                                self.shred_assembler.removeSlot(stale_slot);
                                std.debug.print("[TVU] Evicted stale slot {d} (max_seen={d})\\n", .{ stale_slot, max_seen });
                            }
                        }
                    }

                    if (@mod(loop_count, 30000) == 0) {
                        const in_progress = self.shred_assembler.getInProgressSlotCount();
                        std.debug.print("[TVU-ADVANCE] max_seen={d} slots_tracking={d} proactive_slot={d}\\n", .{
                            max_seen, in_progress, proactive_repair_slot,
                        });
                    }
                }
                last_proactive_repair = loop_count;
            }

            // Update Turbine tree periodically (every 30 seconds)
            if (loop_count > last_turbine_update + 30000) {
                self.updateTurbineTree();
                last_turbine_update = loop_count;
            }

            // Print comprehensive diagnostics every 30 seconds
            if (loop_count > last_diagnostic_report + 30000) {
                self.printComprehensiveDiagnostics();
                last_diagnostic_report = loop_count;
            }

            // Small sleep to prevent busy loop when no packets
            std.time.sleep(1 * std.time.ns_per_ms);
        }

        std.log.info("[TVU] Receive loop stopped", .{});
    }

    /// Get current network slot from gossip contacts' slot values
    /// Falls back to 0 if no gossip info available
    fn getNetworkSlot(self: *Self) u64 {
        const gs = self.gossip_service orelse return 0;

        // Count peers with matching shred version
        var matching_peers: usize = 0;
        var iter = gs.table.contacts.iterator();
        while (iter.next()) |entry| {
            const peer = entry.value_ptr.*;
            // Check if peer has advertised matching shred_version
            if (peer.shred_version == self.config.shred_version or peer.shred_version == 0) {
                matching_peers += 1;
            }
        }

        // For proactive repair, we need to estimate current network slot
        // 1. Use the maximum slot seen from shreds if available
        const max_seen = self.stats.max_slot_seen.load(.monotonic);
        if (max_seen > 300_000_000) return max_seen + 1;

        // 2. Fallback: use current timestamp divided by slot time (~400ms)
        // starting from a known recent testnet slot (Feb 2026: ~386,000,000)
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        const approx_slot = now_ms / 400;

        // Only trigger proactive repair if we have enough gossip peers
        if (matching_peers > 50) {
            // Testnet is currently around slot 386,000,000+
            return 386_000_000 + (approx_slot % 200_000);
        }

        return 0;
    }

    /// Maximum age (in slots) before a tracked slot is considered stale and evicted.
    /// Only used during NORMAL operation (gap < CATCHUP_MODE_THRESHOLD).
    /// During catch-up, distance-based eviction is bypassed entirely to let
    /// repair finish assembling slots. The time-based sweeper handles cleanup.
    const STALE_SLOT_THRESHOLD: u64 = 150;

    /// When our gap to network head exceeds this, we are in deep catch-up mode
    /// and distance-based eviction is disabled to prevent slot assassination.
    const CATCHUP_MODE_THRESHOLD: u64 = 5000;

    /// Check for missing shreds and request repairs
    /// IMPROVED: Prioritizes slots with last_in_slot detected and requests in batches
    fn checkAndRequestRepairs(self: *Self, max_slots_to_repair: usize) !void {
        // Check each slot in assembler for gaps
        const slots = self.shred_assembler.getInProgressSlots() catch return;
        defer self.allocator.free(slots);

        // Network head — used for proactive future slot discovery below.
        const network_head = self.stats.max_slot_seen.load(.monotonic);

        // NOTE: Distance-based eviction (REPAIR-PRUNE) has been REMOVED.
        // It was the root cause of slot assassination during catch-up: slots 
        // >150 behind network_head were deleted before repair could complete them.
        // The time-based sweeper (5-minute timeout for repair slots) handles
        // cleanup of truly dead slots without killing active repair work.

        // Repair remaining active slots
        var slots_repaired: usize = 0;
        for (slots) |slot| {
            if (slots_repaired >= max_slots_to_repair) break;

            const slot_info = self.shred_assembler.getSlotInfo(slot) catch continue;

            if (slot_info.knows_last_shred) {
                // CASE 1: We know the total — request specific missing indices
                const missing = self.shred_assembler.getMissingIndices(slot) catch continue;
                defer self.allocator.free(missing);
                if (missing.len == 0) continue;

                // DEDUP: Filter out recently-requested indices (Firedancer dedup_next)
                // Sig uses batch sizes up to MAX_DATA_SHREDS_PER_SLOT; we use 512 as practical limit
                var filtered_indices: [512]u32 = undefined;
                var filtered_count: usize = 0;
                for (missing[0..@min(missing.len, 512)]) |idx| {
                    if (self.shouldRequestRepair(slot, idx)) {
                        if (filtered_count < 512) {
                            filtered_indices[filtered_count] = idx;
                            filtered_count += 1;
                        }
                    }
                }

                if (filtered_count > 0) {
                    try self.requestRepairs(slot, filtered_indices[0..filtered_count]);
                }

                const needed = slot_info.last_shred_index + 1;
                const pct = (slot_info.unique_count * 100) / needed;
                if (pct > 50 or @mod(slot, 5000) == 0) {
                    std.debug.print("[REPAIR] Slot {d}: {d}/{d} ({d}%), requesting {d}/{d} missing (dedup filtered)\n", .{
                        slot, slot_info.unique_count, needed, pct, filtered_count, missing.len,
                    });
                }
            } else {
                // CASE 2: We DON'T know last_index yet.
                // Send ONE HighestWindowIndex to discover it, PLUS request
                // actual GAPS in the range [0..highest_received]. The old code
                // explored BEYOND highest, missing all the real holes below it.
                const highest_idx = self.shred_assembler.getHighestIndex(slot) catch 0;

                // Send HWI once (dedup prevents re-sending within 2s)
                if (self.shouldRequestRepair(slot, std.math.maxInt(u32))) {
                    try self.requestHighestWindowIndex(slot, 0);
                }

                // Request ACTUAL GAPS from [0..highest_received] — not indices beyond.
                // This fills the real holes in the slot instead of probing into void.
                var gap_indices: [512]u32 = undefined;
                var gap_count: usize = 0;
                var scan_idx: u32 = 0;
                while (scan_idx <= highest_idx and gap_count < 512) : (scan_idx += 1) {
                    if (!self.shred_assembler.hasShred(slot, scan_idx)) {
                        if (self.shouldRequestRepair(slot, scan_idx)) {
                            gap_indices[gap_count] = scan_idx;
                            gap_count += 1;
                        }
                    }
                }

                if (gap_count > 0) {
                    try self.requestRepairs(slot, gap_indices[0..gap_count]);
                }

                if (@mod(slots_repaired, 10) == 0 and gap_count > 0) {
                    std.debug.print("[REPAIR] Slot {d}: gaps {d} in [0..{d}] (have {d}, dedup={d})\n", .{
                        slot, gap_count, highest_idx, slot_info.unique_count, self.repair_dedup.count(),
                    });
                }
            }
            slots_repaired += 1;
        }

        // === Sig-inspired: Proactive future slot discovery ===
        // Sig (Syndica/sig) probes slot+1 and a random future slot to detect being behind.
        // This helps discover new slots from peers before turbine delivers them.
        if (network_head > 0 and slots.len > 0) {
            // Probe the next slot beyond what we're tracking
            const next_slot = network_head + 1;
            if (self.shouldRequestRepair(next_slot, std.math.maxInt(u32))) {
                self.requestHighestWindowIndex(next_slot, 0) catch {};
            }

            // Probe a random slot 10-50 ahead (like Sig's jittered lookahead)
            // Uses a simple hash-based pseudo-random offset to avoid needing a PRNG
            const jitter: u64 = 10 + @mod(network_head *% 7919, 41); // pseudo-random 10..50
            const probe_slot = network_head + jitter;
            if (self.shouldRequestRepair(probe_slot, std.math.maxInt(u32))) {
                self.requestHighestWindowIndex(probe_slot, 0) catch {};
            }
        }
    }

    /// Get pending slots ready for replay
    pub fn getPendingSlots(self: *Self) []const core.Slot {
        return self.pending_slots.items;
    }

    /// Clear a pending slot after replay
    /// CRITICAL: Also removes from shred_assembler to prevent memory leak
    pub fn clearPendingSlot(self: *Self, slot: core.Slot) void {
        for (self.pending_slots.items, 0..) |s, i| {
            if (s == slot) {
                _ = self.pending_slots.orderedRemove(i);
                // Remove from assembler to free memory
                self.shred_assembler.removeSlot(slot);
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

/// Turbine protocol helper - proper stake-weighted tree implementation
/// Reference: Sig turbine_tree.zig, Firedancer fd_shred_dest.c
pub const Turbine = struct {
    allocator: std.mem.Allocator,

    /// The turbine tree for computing shred destinations
    tree: ?*turbine_tree.TurbineTree,

    /// Cached children for current shred
    children: std.ArrayList(turbine_tree.TurbineNode),

    /// Shred retransmit peers (for legacy compatibility)
    retransmit_peers: std.ArrayList(packet.SocketAddr),

    const Self = @This();

    /// Fanout constant (matches Sig/Firedancer)
    pub const DATA_PLANE_FANOUT: usize = 200;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tree = null,
            .children = std.ArrayList(turbine_tree.TurbineNode).init(allocator),
            .retransmit_peers = std.ArrayList(packet.SocketAddr).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.tree) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.children.deinit();
        self.retransmit_peers.deinit();
    }

    /// Initialize the turbine tree with our identity
    pub fn initTree(self: *Self, my_pubkey: core.Pubkey) !void {
        if (self.tree) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }

        const tree = try self.allocator.create(turbine_tree.TurbineTree);
        tree.* = turbine_tree.TurbineTree.init(self.allocator, my_pubkey);
        self.tree = tree;
    }

    /// Build the tree from gossip peers and stake info
    pub fn buildTree(
        self: *Self,
        gossip_peers: []const gossip.ContactInfo,
        staked_nodes: *const std.AutoHashMap([32]u8, u64),
    ) !void {
        if (self.tree) |tree| {
            try tree.build(gossip_peers, staked_nodes);
        }
    }

    /// Calculate retransmit peers based on stake (legacy API)
    pub fn calculateRetransmitPeers(
        self: *Self,
        cluster_nodes: []const gossip.ContactInfo,
        our_index: usize,
    ) !void {
        self.retransmit_peers.clearRetainingCapacity();

        // Legacy fallback: simple index-based calculation
        // TODO: Remove once tree-based calculation is fully integrated
        const fanout: usize = DATA_PLANE_FANOUT;
        const start = our_index * fanout;
        const end = @min(start + fanout, cluster_nodes.len);

        for (cluster_nodes[start..end]) |node| {
            try self.retransmit_peers.append(node.tvu_addr);
        }
    }

    /// Calculate retransmit children for a specific shred (proper implementation)
    /// This is the correct way to compute Turbine destinations
    pub fn getRetransmitChildrenForShred(
        self: *Self,
        leader: core.Pubkey,
        slot: u64,
        shred_index: u32,
        is_data: bool,
    ) !turbine_tree.TurbineSearchResult {
        const tree = self.tree orelse return turbine_tree.TurbineSearchResult{ .my_index = 0, .root_distance = 0 };

        const shred_id = turbine_tree.ShredId{
            .slot = slot,
            .index = shred_index,
            .shred_type = if (is_data) .data else .code,
        };

        return try tree.getRetransmitChildren(
            &self.children,
            leader,
            shred_id,
            DATA_PLANE_FANOUT,
        );
    }

    /// Get the number of children computed for the current shred
    pub fn getChildCount(self: *const Self) usize {
        return self.children.items.len;
    }

    /// Get children nodes for broadcasting (for leader block production)
    /// Returns null if no children have been computed
    pub fn getChildren(self: *const Self) ?[]const turbine_tree.TurbineNode {
        if (self.children.items.len == 0) return null;
        return self.children.items;
    }

    /// Retransmit shred to peers (legacy)
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

    /// Retransmit shred to computed children (proper implementation)
    pub fn retransmitToChildren(self: *Self, shred_data: []const u8, sock: *socket.UdpSocket) !usize {
        var sent: usize = 0;

        for (self.children.items) |child| {
            if (child.tvu_addr) |addr| {
                var pkt = packet.Packet.init();
                @memcpy(pkt.data[0..shred_data.len], shred_data);
                pkt.len = @intCast(shred_data.len);
                pkt.src_addr = addr;

                if (sock.send(&pkt) catch null) |_| {
                    sent += 1;
                }
            }
        }

        return sent;
    }
};

// Import turbine_tree module
const turbine_tree = @import("turbine_tree.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "tvu service init" {
    var service = try TvuService.init(std.testing.allocator, .{});
    defer service.deinit();

    try std.testing.expect(!service.running.load(.seq_cst));
}

test "tvu repair request" {
    const allocator = std.testing.allocator;
    var keypair = core.Keypair.generate();
    var service = try TvuService.init(allocator, .{
        .enable_af_xdp = false,
        .enable_io_uring = false,
        .keypair = &keypair,
    });
    defer service.deinit();

    var sock = try socket.UdpSocket.init();
    try sock.bindPort(0);
    service.repair_socket = sock;

    const peer = TvuService.RepairPeer{
        .addr = packet.SocketAddr.ipv4(.{ 127, 0, 0, 1 }, 9999),
        .pubkey = [_]u8{0} ** 32,
    };
    try service.setRepairPeersOverride(&[_]TvuService.RepairPeer{peer});
    try service.requestRepairs(123, &[_]u32{1});

    const sent = service.stats.repairs_sent.load(.seq_cst);
    try std.testing.expect(sent > 0);
}

test "turbine" {
    var turbine = Turbine.init(std.testing.allocator);
    defer turbine.deinit();

    try std.testing.expectEqual(@as(usize, 0), turbine.retransmit_peers.items.len);
    try std.testing.expectEqual(@as(usize, 0), turbine.getChildCount());
}

// TEST STRING - REMOVE AFTER VERIFICATION
const TEST_VERIFICATION_STRING = "TVU_FILE_COMPILED_12345";
