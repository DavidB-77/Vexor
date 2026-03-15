//! Vexor Runtime Module
//!
//! Main validator runtime coordinating all subsystems.

const std = @import("std");
const core = @import("../core/root.zig");
const network = @import("../network/root.zig");
const consensus = @import("../consensus/root.zig");
const storage = @import("../storage/root.zig");
const crypto = @import("../crypto/root.zig");
const optimizer = @import("../optimizer/root.zig");

pub const bank = @import("bank.zig");
pub const transaction = @import("transaction.zig");
pub const shred = @import("shred.zig");
pub const entry = @import("entry.zig");
pub const replay_stage = @import("replay_stage.zig");
pub const genesis = @import("genesis.zig");
pub const vote_program = @import("vote_program.zig");
pub const native_programs = @import("native_programs.zig");
const consensus_trace = @import("../diagnostics/consensus_trace.zig");
const diagnostics = @import("../diagnostics/root.zig");
const performance_display = @import("../diagnostics/performance_display.zig");
pub const stake_program = @import("stake_program.zig");
pub const fork_manager = @import("fork_manager.zig");
pub const block_producer = @import("block_producer.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const banking_stage = @import("banking_stage.zig");

// New modules for full implementation
pub const fec_resolver = @import("fec_resolver.zig");
pub const bmtree = @import("bmtree.zig");
pub const shredder = @import("shredder.zig");

// BPF Virtual Machine for executing Solana programs
pub const bpf = @import("bpf/root.zig");

// Re-exports
pub const Bank = bank.Bank;
pub const Transaction = bank.Transaction;
pub const ParsedTransaction = transaction.ParsedTransaction;
pub const Shred = shred.Shred;
pub const ShredAssembler = shred.ShredAssembler;
pub const Entry = entry.Entry;
pub const EntryParser = entry.EntryParser;
pub const ReplayStage = replay_stage.ReplayStage;
pub const GenesisConfig = genesis.GenesisConfig;
pub const EpochSchedule = genesis.EpochSchedule;
pub const ClusterType = genesis.ClusterType;
pub const VoteState = vote_program.VoteState;
pub const VoteInstruction = vote_program.VoteInstruction;
pub const VoteTransactionBuilder = vote_program.VoteTransactionBuilder;
pub const SystemInstruction = native_programs.SystemInstruction;
pub const SystemProgram = native_programs.SystemProgram;
pub const InstructionContext = native_programs.InstructionContext;
pub const ProgramResult = native_programs.ProgramResult;
pub const program_ids = native_programs.program_ids;
pub const StakeState = stake_program.StakeState;

// FEC and Merkle tree exports
pub const FecResolver = fec_resolver.FecResolver;
pub const FecSet = fec_resolver.FecSet;
pub const GaloisField = fec_resolver.GaloisField;
pub const MerkleTree = bmtree.MerkleTree;
pub const ShredMerkleTree = bmtree.ShredMerkleTree;
pub const Shredder = shredder.Shredder;
pub const BlockBuilder = shredder.BlockBuilder;
pub const StakeInstruction = stake_program.StakeInstruction;
pub const StakeProgram = stake_program.StakeProgram;
pub const Delegation = stake_program.Delegation;
pub const ForkManager = fork_manager.ForkManager;
pub const ForkEntry = fork_manager.ForkEntry;
pub const BlockProducer = block_producer.BlockProducer;
pub const ValidatorBootstrap = bootstrap.ValidatorBootstrap;
pub const BootstrapConfig = bootstrap.BootstrapConfig;
pub const BootstrapResult = bootstrap.BootstrapResult;
pub const VoteSubmitter = bootstrap.VoteSubmitter;
pub const BankingStage = banking_stage.BankingStage;
pub const BankingConfig = banking_stage.BankingConfig;
pub const TransactionScheduler = banking_stage.TransactionScheduler;

// BPF VM types
pub const BpfVm = bpf.BpfVm;
pub const VmContext = bpf.VmContext;
pub const ElfLoader = bpf.ElfLoader;
pub const LoadedProgram = bpf.LoadedProgram;
pub const ProgramCache = bpf.ProgramCache;
pub const ComputeBudget = bpf.ComputeBudget;

/// Main validator runtime
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: *const core.Config,

    // Subsystems
    network_manager: ?*network.NetworkManager,
    consensus_engine: ?*consensus.ConsensusEngine,
    storage_manager: ?*storage.StorageManager,
    rpc_server: ?*network.RpcHttpServer,
    gossip_service: ?*network.GossipService,
    tvu_service: ?*network.tvu.TvuService,
    tpu_service: ?*network.tpu.TpuService,
    banking_stage: ?*BankingStage,
    tpu_client: ?*network.TpuClient,
    replay_stage: ?*ReplayStage,

    // Identity
    identity: ?core.Keypair,
    vote_account: ?core.Pubkey,

    // State
    running: std.atomic.Value(bool),
    current_slot: std.atomic.Value(u64),
    current_epoch: std.atomic.Value(u64),

    // Statistics
    stats: RuntimeStats,

    // Diagnostics
    consensus_tracker: consensus_trace.ConsensusTracker,

    // Dashboard mode (enabled via --dashboard flag)
    dashboard_mode: bool,
    dashboard_start_time: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: *const core.Config) !*Self {
        const runtime = try allocator.create(Self);
        runtime.* = .{
            .allocator = allocator,
            .config = config,
            .network_manager = null,
            .consensus_engine = null,
            .storage_manager = null,
            .rpc_server = null,
            .gossip_service = null,
            .tvu_service = null,
            .tpu_service = null,
            .banking_stage = null,
            .tpu_client = null,
            .replay_stage = null,
            .identity = null,
            .vote_account = null,
            .running = std.atomic.Value(bool).init(false),
            .current_slot = std.atomic.Value(u64).init(0),
            .current_epoch = std.atomic.Value(u64).init(0),
            .stats = RuntimeStats{},
            .consensus_tracker = consensus_trace.ConsensusTracker.init(),
            .dashboard_mode = false,
            .dashboard_start_time = std.time.timestamp(),
        };

        return runtime;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.rpc_server) |rpc| rpc.deinit();
        if (self.gossip_service) |gs| {
            self.allocator.destroy(gs);
        }
        if (self.tvu_service) |tvu| tvu.deinit();
        if (self.replay_stage) |rs| rs.deinit();
        if (self.network_manager) |nm| nm.deinit();
        if (self.consensus_engine) |ce| ce.deinit();
        if (self.storage_manager) |sm| sm.deinit();

        self.allocator.destroy(self);
    }

    /// Start the validator (quick mode - networking only, no snapshot)
    pub fn start(self: *Self) !void {
        if (self.running.load(.seq_cst)) return;

        // Load identity keypair
        self.identity = try self.loadIdentity();
        self.vote_account = try self.loadVoteAccount();

        var id_buf: [44]u8 = undefined;
        const id_str = self.formatPubkey(self.identity.?.public, &id_buf);
        std.log.info("Identity: {s}", .{id_str});
        if (self.vote_account) |va| {
            var va_buf: [44]u8 = undefined;
            const va_str = self.formatPubkey(va, &va_buf);
            std.log.info("Vote Account: {s}", .{va_str});
        }

        // Initialize storage
        self.storage_manager = try storage.StorageManager.init(self.allocator, self.config);

        // Initialize RPC server
        self.rpc_server = try network.RpcHttpServer.init(self.allocator, .{
            .port = self.config.rpc_port,
            .bind_address = "0.0.0.0",
        });
        try self.rpc_server.?.start();
        std.log.info("RPC server listening on port {d}", .{self.config.rpc_port});

        // Initialize gossip service
        self.gossip_service = try self.allocator.create(network.GossipService);
        self.gossip_service.?.* = network.GossipService.init(self.allocator, self.identity.?.public, .{
            .gossip_port = self.config.gossip_port,
        });

        // Set our contact info with PUBLIC IP for network to find us
        self.gossip_service.?.setSelfInfo(
            self.config.getPublicIpBytes(),
            self.config.gossip_port,
            self.config.tpu_port,
            self.config.tvu_port,
            self.config.repair_port,
            self.config.rpc_port,
        );

        // Set keypair for signing gossip messages (CRITICAL for peer acceptance)
        if (self.identity) |*kp| {
            self.gossip_service.?.setKeypair(kp);
        }

        // Add entrypoints
        for (self.config.entrypoints) |ep| {
            // Parse "host:port" format
            if (std.mem.indexOf(u8, ep, ":")) |colon_idx| {
                const host = ep[0..colon_idx];
                const port_str = ep[colon_idx + 1 ..];
                const port = std.fmt.parseInt(u16, port_str, 10) catch 8001;
                self.gossip_service.?.addEntrypoint(host, port) catch {};
            }
        }

        // Initialize TVU service for shred reception
        var shred_version = self.config.shred_version_override orelse self.config.expected_shred_version orelse 0;
        if (shred_version == 0 and self.config.cluster == .testnet) {
            shred_version = 27350;
        }

        self.tvu_service = try network.tvu.TvuService.init(self.allocator, .{
            .tvu_port = self.config.tvu_port,
            .tvu_fwd_port = self.config.tvu_port + 1,
            .repair_port = self.config.repair_port,
            .enable_af_xdp = self.config.enable_af_xdp,
            .xdp_zero_copy = self.config.xdp_zero_copy,
            .enable_fec_recovery = self.config.enable_fec_recovery,
            .enable_simd_fec = self.config.enable_simd_fec,
            .interface = self.config.interface,
            .keypair = if (self.identity) |*id| id else null,
            .shred_version = shred_version,
        });

        // Connect TVU to gossip for repair peer discovery
        if (self.gossip_service) |gs| {
            self.tvu_service.?.setGossipService(gs);
        }
        self.tvu_service.?.consensus_tracker = &self.consensus_tracker;

        // Initialize replay stage (deferred - requires bank initialization)
        // Will be initialized when we have accounts_db, ledger_db, and consensus
        self.replay_stage = null;

        // Initialize consensus engine
        self.consensus_engine = try consensus.ConsensusEngine.init(self.allocator, self.identity.?.public);

        self.running.store(true, .seq_cst);
        self.stats.start_time = std.time.timestamp();
    }

    /// Start the validator with full bootstrap (production mode - with snapshot)
    /// This is the recommended mode for production validators.
    pub fn startWithBootstrap(self: *Self) !BootstrapResult {
        if (self.running.load(.seq_cst)) return error.AlreadyRunning;

        std.log.info("═══════════════════════════════════════════════════════", .{});
        std.log.info("  VEXOR VALIDATOR - Production Bootstrap", .{});
        std.log.info("═══════════════════════════════════════════════════════", .{});

        // Determine RPC endpoints based on cluster
        const rpc_endpoints = switch (self.config.cluster) {
            .mainnet_beta => &[_][]const u8{ "https://api.mainnet-beta.solana.com", "https://solana-api.projectserum.com" },
            .testnet => &[_][]const u8{"https://api.testnet.solana.com"},
            .devnet => &[_][]const u8{"https://api.devnet.solana.com"},
            .localnet => &[_][]const u8{"http://localhost:8899"},
        };

        // Create bootstrap config
        const bootstrap_config = BootstrapConfig{
            .identity_path = self.config.identity_path orelse return error.NoIdentityPath,
            .vote_account_path = self.config.vote_account_path,
            .ledger_dir = self.config.ledger_dir orelse "/mnt/vexor/ledger",
            .accounts_dir = self.config.accounts_dir orelse "/mnt/vexor/accounts",
            .snapshots_dir = self.config.snapshots_dir orelse "/mnt/vexor/snapshots",
            .rpc_endpoints = rpc_endpoints,
            .entrypoints = self.config.entrypoints,
            .cluster = self.config.cluster,
            .enable_voting = self.config.enable_voting,
        };

        // Run bootstrap sequence
        std.debug.print("[DEBUG] Creating ValidatorBootstrap...\n", .{});
        var validator_bootstrap = ValidatorBootstrap.init(self.allocator, bootstrap_config) catch |err| {
            std.debug.print("[DEBUG] ValidatorBootstrap.init failed: {}\n", .{err});
            return err;
        };
        defer validator_bootstrap.deinit();
        std.debug.print("[DEBUG] ValidatorBootstrap created successfully\n", .{});

        // Set progress callback for logging
        validator_bootstrap.setProgressCallback(struct {
            fn callback(phase: bootstrap.BootstrapPhase, progress: f64) void {
                std.log.info("[Bootstrap] Phase: {s} ({d:.1}%)", .{ @tagName(phase), progress * 100 });
            }
        }.callback);

        std.debug.print("[DEBUG] Starting bootstrap()...\n", .{});
        const result = validator_bootstrap.bootstrap() catch |err| {
            std.debug.print("[DEBUG] bootstrap() failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] bootstrap() completed successfully\n", .{});

        // Store results
        self.identity = validator_bootstrap.identity;
        self.vote_account = validator_bootstrap.vote_account;
        self.replay_stage = result.replay_stage;
        self.consensus_engine = result.replay_stage.consensus_engine;

        std.debug.print("[DEBUG] Stored bootstrap results\n", .{});
        std.debug.print("[DEBUG] identity set: {}\n", .{self.identity != null});
        std.debug.print("[DEBUG] vote_account set: {}\n", .{self.vote_account != null});
        std.debug.print("[DEBUG] enable_voting: {}\n", .{self.config.enable_voting});

        // Initialize networking
        try self.initializeNetworking();

        // Start vote submitter if voting is enabled
        if (self.config.enable_voting and self.vote_account != null) {
            std.debug.print("[DEBUG] Starting vote submitter...\n", .{});
            const vote_submitter = try VoteSubmitter.init(
                self.allocator,
                self.identity.?,
                self.vote_account.?,
                result.tower,
                result.replay_stage,
                rpc_endpoints[0],
                true, // ALWAYS use RPC fallback for vote delivery
            );

            // Connect current slot pointer so VoteSubmitter knows what slot we're at
            vote_submitter.setCurrentSlotPtr(&self.current_slot);
            std.debug.print("[DEBUG] Current slot pointer connected to vote submitter\n", .{});

            // CRITICAL: Connect TPU client for vote submission
            if (self.tpu_client) |tpu| {
                vote_submitter.setTpuClient(tpu);
                std.debug.print("[DEBUG] TPU client connected to vote submitter\n", .{});
            } else {
                std.debug.print("[DEBUG] WARNING: No TPU client available for vote submission!\n", .{});
            }

            // Connect gossip service for shred broadcasting during block production
            if (self.gossip_service) |gs| {
                vote_submitter.setGossipService(gs);
            }

            // Connect TVU service for Turbine tree access during block production
            if (self.tvu_service) |tvu| {
                vote_submitter.setTvuService(tvu);
            }

            // Connect TPU service for transaction queue access (banking stage)
            if (self.tpu_service) |tpu_svc| {
                vote_submitter.setTpuService(tpu_svc);
            }

            vote_submitter.start();
            std.log.info("[Bootstrap] Vote submitter started (block production: ENABLED)", .{});
            std.debug.print("[DEBUG] Vote submitter started successfully!\n", .{});
        } else {
            std.debug.print("[DEBUG] Vote submitter NOT started - enable_voting={}, vote_account={}\n", .{ self.config.enable_voting, self.vote_account != null });
        }

        self.running.store(true, .seq_cst);
        self.stats.start_time = std.time.timestamp();
        self.current_slot.store(result.start_slot, .seq_cst);

        std.log.info("═══════════════════════════════════════════════════════", .{});
        std.log.info("  Bootstrap Complete! Starting from slot {d}", .{result.start_slot});
        std.log.info("  Accounts: {d} | Lamports: {d}", .{ result.accounts_loaded, result.total_lamports });
        std.log.info("═══════════════════════════════════════════════════════", .{});

        return result;
    }

    /// Initialize networking components
    fn initializeNetworking(self: *Self) !void {
        // Initialize RPC server
        self.rpc_server = try network.RpcHttpServer.init(self.allocator, .{
            .port = self.config.rpc_port,
            .bind_address = "0.0.0.0",
        });
        try self.rpc_server.?.start();
        std.log.info("RPC server listening on port {d}", .{self.config.rpc_port});

        // Initialize gossip service
        self.gossip_service = try self.allocator.create(network.GossipService);
        self.gossip_service.?.* = network.GossipService.init(self.allocator, self.identity.?.public, .{
            .gossip_port = self.config.gossip_port,
        });

        // Set our contact info with PUBLIC IP for network to find us
        self.gossip_service.?.setSelfInfo(
            self.config.getPublicIpBytes(),
            self.config.gossip_port,
            self.config.tpu_port,
            self.config.tvu_port,
            self.config.repair_port,
            self.config.rpc_port,
        );

        // Set keypair for signing gossip messages (CRITICAL for peer acceptance)
        if (self.identity) |*kp| {
            self.gossip_service.?.setKeypair(kp);
        }

        // Add entrypoints
        for (self.config.entrypoints) |ep| {
            if (std.mem.indexOf(u8, ep, ":")) |colon_idx| {
                const host = ep[0..colon_idx];
                const port_str = ep[colon_idx + 1 ..];
                const port = std.fmt.parseInt(u16, port_str, 10) catch 8001;
                self.gossip_service.?.addEntrypoint(host, port) catch {};
            }
        }

        // Initialize TVU service
        var shred_version = self.config.shred_version_override orelse self.config.expected_shred_version orelse 0;
        if (shred_version == 0 and self.config.cluster == .testnet) {
            shred_version = 27350; // Default testnet version for Feb 2026
        }

        self.tvu_service = try network.tvu.TvuService.init(self.allocator, .{
            .tvu_port = self.config.tvu_port,
            .tvu_fwd_port = self.config.tvu_port + 1,
            .repair_port = self.config.repair_port,
            .enable_af_xdp = self.config.enable_af_xdp,
            .xdp_zero_copy = self.config.xdp_zero_copy,
            .enable_fec_recovery = self.config.enable_fec_recovery,
            .enable_simd_fec = self.config.enable_simd_fec,
            .interface = self.config.interface,
            .keypair = if (self.identity) |*id| id else null,
            .shred_version = shred_version,
        });

        // Connect TVU to gossip for repair peer discovery
        if (self.gossip_service) |gs| {
            self.tvu_service.?.setGossipService(gs);
        }

        // Initialize TPU service for transaction reception
        self.tpu_service = try network.tpu.TpuService.init(self.allocator, .{
            .tpu_port = self.config.tpu_port,
            .tpu_fwd_port = self.config.tpu_port + 1,
            .tpu_quic_port = self.config.tpu_port + 6,
            .enable_quic = true,
        });

        // Initialize banking stage for transaction execution
        self.banking_stage = try BankingStage.init(self.allocator, .{
            .num_threads = 4,
        });

        // Link TPU service queue to BankingStage via high-performance callback
        // This enables the "zero-copy" path where TPU pushes directly to BankingStage's lock-free queue,
        // matching the low-latency architecture of Firedancer.
        self.tpu_service.?.setTransactionCallback(self, onTpuVerifiedTransaction);

        // Integrate BankingStage with ReplayStage if already exists
        if (self.replay_stage) |rs| {
            rs.banking_stage = self.banking_stage;
            rs.consensus_tracker = &self.consensus_tracker;
        }

        // Initialize TPU client for vote submission
        // Reference: Firedancer fd_quic_tile.c - TPU client initialization
        if (self.config.enable_voting) {
            self.tpu_client = try network.TpuClient.initDefault(self.allocator);
            errdefer if (self.tpu_client) |tpu| tpu.deinit();

            // Connect to gossip service for leader discovery
            if (self.gossip_service) |gs| {
                self.tpu_client.?.setGossipService(gs);
            }

            // Connect to leader schedule for slot->leader lookup
            // This is CRITICAL for vote submission - we need to know where to send votes!
            if (self.replay_stage) |rs| {
                self.tpu_client.?.setLeaderSchedule(&rs.leader_cache);
                rs.setTpuClient(self.tpu_client.?);
            }

            std.log.info("[Network] TPU client initialized for vote submission", .{});
        }
    }

    /// Stop the validator
    pub fn stop(self: *Self) void {
        if (!self.running.load(.seq_cst)) return;

        self.running.store(false, .seq_cst);

        if (self.rpc_server) |rpc| rpc.stop();
        if (self.gossip_service) |gs| gs.stop();
        if (self.tvu_service) |tvu| tvu.stop();
        if (self.tpu_client) |tpu| tpu.deinit();
        if (self.network_manager) |nm| nm.stop();
    }

    /// Called when a slot is fully received
    fn onSlotCompleted(self: *Self, slot: core.Slot) !void {
        self.stats.slots_processed += 1;
        std.debug.print("[Runtime] Slot {d} completed (total processed: {d})\n", .{ slot, self.stats.slots_processed });

        // Update current slot if this is newer
        const current = self.current_slot.load(.seq_cst);
        if (slot > current) {
            self.current_slot.store(slot, .seq_cst);
            self.consensus_tracker.report(slot, .rooted);
        }

        // ═══════════════════════════════════════════════════════════════
        // REPLAY RE-ENABLED — The original SIGSEGV was caused by unclamped
        // shred sizes (fixed in shred.zig:997). assembleSlot() returns a
        // fresh caller-owned buffer (memcpy'd from shreds under mutex),
        // so there is zero use-after-free risk.
        //
        // Memory ownership:
        //   assembleSlot() → allocs new buffer → replay reads it → defer free
        //   removeSlot()   → frees assembler's internal shred storage (separate)
        // ═══════════════════════════════════════════════════════════════
        if (self.tvu_service) |tvu| {
            // Step 1: Assemble the slot's entry data (mutex-protected, returns owned copy)
            const assembled_data = tvu.shred_assembler.assembleSlot(slot) catch |err| {
                std.debug.print("[Runtime] assembleSlot({d}) failed: {} (non-fatal)\n", .{ slot, err });
                tvu.shred_assembler.removeSlot(slot);
                return;
            };

            if (assembled_data) |data| {
                // Step 2: Replay the slot — parse entries → execute txs → freeze bank → update root_bank
                defer self.allocator.free(data);

                std.debug.print("[Runtime-TRACE] slot={d} assembled data_len={d}, replay_stage={}\n", .{
                    slot, data.len, self.replay_stage != null,
                });

                if (self.replay_stage) |replay| {
                    std.debug.print("[Runtime-TRACE] slot={d} calling replay.onSlotCompleted...\n", .{slot});
                    replay.onSlotCompleted(slot, data) catch |err| {
                        std.debug.print("[Runtime-TRACE] slot={d} REPLAY FAILED: {} (data_len={d})\n", .{ slot, err, data.len });
                    };
                    std.debug.print("[Runtime-TRACE] slot={d} replay.onSlotCompleted returned OK\n", .{slot});
                } else {
                    std.debug.print("[Runtime-TRACE] slot={d} replay_stage IS NULL!\n", .{slot});
                }
            }

            // Step 3: Free assembler's internal shred storage (independent of assembled buffer)
            tvu.shred_assembler.removeSlot(slot);
        }
    }

    /// Main run loop
    pub fn run(self: *Self) !void {
        std.debug.print("🚀 Vexor validator running\n", .{});
        std.debug.print("   Press Ctrl+C to stop\n\n", .{});

        // Initialize thread tracer for leak detection
        diagnostics.thread_trace.initGlobal(self.allocator) catch {
            std.debug.print("[ThreadTrace] Warning: Failed to initialize thread tracer\n", .{});
        };

        // Start TVU FIRST (so its io_uring/socket setup doesn't clobber gossip fd)
        if (self.tvu_service) |tvu| {
            tvu.start() catch |err| {
                std.log.warn("TVU start failed (non-fatal): {}", .{err});
            };
            // Spawn dedicated TVU receive thread (processes packets + requests repairs)
            // Store the handle so stop() can join it before deinit frees memory
            tvu.receive_thread = std.Thread.spawn(.{}, network.tvu.TvuService.run, .{tvu}) catch |err| blk: {
                std.log.warn("TVU thread spawn failed: {}", .{err});
                break :blk null;
            };
            std.log.info("TVU receive thread spawned", .{});
        }

        // Start TPU (non-fatal - don't let TPU port conflict prevent gossip)
        if (self.tpu_service) |tpu| {
            tpu.start() catch |err| {
                std.log.warn("TPU start failed (non-fatal): {} — gossip will still work", .{err});
                std.debug.print("[TPU] ⚠️ Failed to start: {} (port {d} may be in use)\n", .{ err, self.config.tpu_port });
            };
            std.log.info("TPU service started", .{});
        }

        // Start BankingStage
        if (self.banking_stage) |banking| {
            _ = std.Thread.spawn(.{}, BankingStage.run, .{banking}) catch |err| {
                std.log.warn("BankingStage thread spawn failed: {}", .{err});
            };
            std.log.info("BankingStage worker thread spawned", .{});
        }

        // Start gossip LAST - after all other services have allocated their sockets/fds
        // This prevents the gossip socket from being clobbered by io_uring/AF_XDP 
        // initialization which may create and destroy intermediate file descriptors
        if (self.gossip_service) |gs| {
            try gs.start();
            std.log.info("Gossip service started", .{});

            // Verify the gossip socket survived all other initialization
            if (gs.sock) |*s| {
                const port = s.boundPort();
                std.debug.print("[Gossip] POST-INIT verify: fd={d} port={any}\n", .{ s.fd, port });
                if (port == null or port.? != self.config.gossip_port) {
                    std.debug.print("[Gossip] ❌ GOSSIP SOCKET DEAD AFTER INIT! Recreating...\n", .{});
                    // Try to recreate
                    gs.stop();
                    try gs.start();
                    if (gs.sock) |*s2| {
                        std.debug.print("[Gossip] Recreated: fd={d} port={any}\n", .{ s2.fd, s2.boundPort() });
                    }
                }
            } else {
                std.debug.print("[Gossip] ❌ GOSSIP SOCKET IS NULL AFTER START!\n", .{});
            }
        }

        std.debug.print("[DEBUG] About to enter main loop, running={}\n", .{self.running.load(.seq_cst)});

        var loop_count: u64 = 0;
        var last_status_time = std.time.milliTimestamp();
        std.debug.print("[DEBUG] Entering main loop now...\n", .{});

        while (self.running.load(.seq_cst)) {
            loop_count += 1;

            // Log first few iterations to debug
            if (loop_count <= 3) {
                std.debug.print("[LOOP] iter {d}: start\n", .{loop_count});
            }

            // Accept RPC connections
            if (self.rpc_server) |rpc| {
                if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: rpc.accept\n", .{loop_count});
                rpc.acceptConnection() catch {};
            }

            // Process gossip messages
            if (self.gossip_service) |gs| {
                if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: gossip.process\n", .{loop_count});
                gs.processMessages() catch {};
            }

            // Process TVU shreds - DEPRECATED in main loop (now handled by dedicated TVU-THREAD)
            // Still check for completed slots if necessary, but don't block on receive
            if (self.tvu_service) |tvu| {
                // Check for completed slots and trigger replay
                while (tvu.getCompletedSlot()) |slot| {
                    self.onSlotCompleted(slot) catch {};
                }

                // Process TPU transactions and push to BankingStage
                if (self.tpu_service) |tpu| {
                    _ = tpu.processPackets() catch {};

                    if (self.banking_stage) |banking| {
                        // Drain verified transactions from TPU queue and push to BankingStage
                        const q_txs = tpu.tx_queue.drain(128) catch &[_]network.tpu.QueuedTransaction{};
                        defer self.allocator.free(q_txs);

                        for (q_txs) |q_tx| {
                            // Parse and convert to bank transaction
                            const parsed = tpu.tx_parser.parseFromSlice(q_tx.data[0..q_tx.len]) catch continue;
                            const bank_tx = parsed.toBankTransaction(self.allocator) catch continue;

                            banking.queueTransaction(bank_tx, .tpu) catch |err| {
                                std.log.warn("[Runtime] Failed to queue transaction: {}", .{err});
                            };
                        }
                    }
                }

                // Sync current slot from network max slot (even if we haven't completed slots)
                // Use saturating arithmetic to avoid integer overflow panics
                const network_max = tvu.stats.max_slot_seen.load(.monotonic);
                const current = self.current_slot.load(.seq_cst);
                if (network_max > 10 and network_max < 1_000_000_000 and network_max > (current +| 10)) {
                    // Jump to catch up - we'll request repairs from here
                    self.current_slot.store(network_max -| 10, .seq_cst);

                    // Check if we need to refresh leader schedule for new epoch
                    const network_epoch = network_max / 432000;
                    const cached_epoch = self.current_epoch.load(.seq_cst);
                    if (network_epoch > cached_epoch) {
                        std.debug.print("[Runtime] Epoch change detected: {d} -> {d}, refreshing leader schedule\n", .{ cached_epoch, network_epoch });
                        self.current_epoch.store(network_epoch, .seq_cst);
                        // Refresh leader schedule in background (don't block main loop)
                        self.refreshLeaderScheduleAsync(network_max);
                    }
                }

                // Proactively request repairs for catch-up (every 5 seconds)
                if (@mod(loop_count, 50000) == 0) {
                    self.requestCatchUpRepairs(tvu);
                }
            }

            // Update slot counter
            if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: processSlot\n", .{loop_count});
            self.processSlot() catch {};

            // Status update every 1 second for higher resolution TPS
            const now = std.time.milliTimestamp();
            if (now -| last_status_time > 1000) {
                self.printStatus(loop_count);
                last_status_time = now;

                // Thread trace report every 30 seconds to detect leaks
                if (@mod(loop_count, 30) == 0) {
                    diagnostics.thread_trace.printReport();
                    // Also print kernel thread breakdown (io_uring, kworkers, etc)
                    diagnostics.thread_trace.printKernelThreadReport();
                }

                // Quick io_uring worker check every 5 seconds for early leak detection
                if (@mod(loop_count, 5) == 0) {
                    const io_workers = diagnostics.thread_trace.checkIoUringWorkers();
                    if (io_workers > 100) {
                        std.debug.print("\n🚨🚨🚨 ALERT: io_uring worker explosion detected: {d} workers 🚨🚨🚨\n", .{io_workers});
                        std.debug.print("    This indicates unbounded IORING worker pool scaling!\n", .{});
                        std.debug.print("    Apply IORING_REGISTER_IOWQ_MAX_WORKERS to cap workers.\n\n", .{});
                    }
                }
            }

            // Brief sleep to prevent busy spinning
            if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: sleep\n", .{loop_count});
            std.time.sleep(100_000); // 100µs
        }

        std.debug.print("\n✋ Validator stopped\n", .{});
    }

    fn processSlot(self: *Self) !void {
        // DON'T increment slot here - it should be driven by TVU shreds
        // The current_slot is updated in onSlotCompleted() when shreds are received
        const slot = self.current_slot.load(.seq_cst);

        // Update RPC context
        if (self.rpc_server) |rpc| {
            rpc.updateContext(slot, self.current_epoch.load(.seq_cst));
        }

        // Only log periodically (not every loop)
        // Slot logging is now done in status update
    }

    /// Update current slot when a new slot is completed from TVU
    fn updateSlotFromNetwork(self: *Self, slot: core.Slot) void {
        const current = self.current_slot.load(.seq_cst);
        if (slot > current) {
            self.current_slot.store(slot, .seq_cst);
            self.stats.slots_processed += 1;

            // Update epoch if needed (432,000 slots per epoch on mainnet)
            const epoch = slot / 432000;
            self.current_epoch.store(epoch, .seq_cst);
        }
    }

    /// Request repairs for catch-up (used when behind the network)
    fn requestCatchUpRepairs(self: *Self, tvu: *network.tvu.TvuService) void {
        const current_slot = self.current_slot.load(.seq_cst);
        const max_seen = tvu.stats.max_slot_seen.load(.monotonic);
        
        // Start from max_seen (latest we know about) to keep advancing
        const start_slot = if (max_seen > 0 and max_seen < 1_000_000_000) max_seen else current_slot;

        // Request repairs for the next 20 slots ahead of our latest known
        var slot = start_slot;
        var repairs_requested: usize = 0;
        const max_repairs = 20;

        while (repairs_requested < max_repairs) : (slot += 1) {
            // Request shred indices 0-127 for each slot (typical slot has 30-200+ shreds)
            var missing_indices: [128]u32 = undefined;
            for (0..128) |i| {
                missing_indices[i] = @intCast(i);
            }

            tvu.requestRepairs(slot, &missing_indices) catch continue;
            repairs_requested += 1;
        }

        if (repairs_requested > 0) {
            std.debug.print("[CatchUp] Requested repairs for slots {d}-{d} (max_seen={d})\\n", .{
                start_slot, start_slot + repairs_requested - 1, max_seen,
            });
        }
    }

    /// Refresh leader schedule for new epoch (called when catching up from old snapshot)
    fn refreshLeaderScheduleAsync(self: *Self, network_slot: core.Slot) void {
        // Use replay_stage's leader_cache to fetch new schedule
        if (self.replay_stage) |rs| {
            // Determine RPC URL from config
            const rpc_url: []const u8 = switch (self.config.cluster) {
                .mainnet_beta => "https://api.mainnet-beta.solana.com",
                .testnet => "https://api.testnet.solana.com",
                .devnet => "https://api.devnet.solana.com",
                .localnet => "http://localhost:8899",
            };

            // Fetch schedule synchronously (the fetchFromRpc operation is quick
            // as most time is spent waiting for network which doesn't block CPU)
            std.debug.print("[Runtime] Fetching leader schedule for slot {d} from {s}\n", .{ network_slot, rpc_url });
            rs.leader_cache.fetchFromRpc(rpc_url, network_slot) catch |err| {
                std.debug.print("[Runtime] Leader schedule refresh failed: {}\n", .{err});
            };
        }
    }

    /// Print detailed status including TVU and gossip stats
    fn printStatus(self: *Self, loop_count: u64) void {
        const slot = self.current_slot.load(.seq_cst);

        // Dashboard mode: Show rich TPS dashboard with performance metrics
        if (self.dashboard_mode) {
            // Clear screen and move cursor to top
            std.debug.print("\x1b[2J\x1b[H", .{});

            const now = std.time.timestamp();
            const uptime_s: f64 = @floatFromInt(now - self.dashboard_start_time);

            // Collect metrics for dashboard
            var shreds_rcvd: u64 = 0;
            var shreds_inserted: u64 = 0;
            var slots_completed: u64 = 0;
            var network_slot: u64 = 0;
            var peers: usize = 0;
            var tps: f64 = 0.0;
            var root_slot: u64 = 0;

            if (self.tvu_service) |tvu| {
                shreds_rcvd = tvu.stats.shreds_received.load(.monotonic);
                shreds_inserted = tvu.stats.shreds_inserted.load(.monotonic);
                slots_completed = tvu.stats.slots_completed.load(.monotonic);
                network_slot = tvu.stats.max_slot_seen.load(.monotonic);
            }

            if (self.gossip_service) |gs| {
                peers = gs.table.contactCount();
            }

            if (self.tpu_service) |tpu| {
                const received = tpu.stats.transactions_received.load(.monotonic);
                const time_now = std.time.milliTimestamp();
                const time_delta = time_now - self.stats.last_calc_time;
                const tx_delta = received -| self.stats.last_tx_count;
                tps = if (time_delta > 0)
                    (@as(f64, @floatFromInt(tx_delta)) / @as(f64, @floatFromInt(time_delta))) * 1000.0
                else
                    0.0;
                self.stats.last_tx_count = received;
                self.stats.last_calc_time = time_now;
            }

            var nw_tps: f64 = 0.0;
            if (self.replay_stage) |rs| {
                if (rs.rootSlot()) |root| {
                    root_slot = root;
                }
                const successful = rs.stats.successful_txs.load(.monotonic);
                const failed = rs.stats.failed_txs.load(.monotonic);
                const total_replayed = successful + failed;

                const time_now = std.time.milliTimestamp();
                const time_delta = time_now - self.stats.last_calc_time;
                const tx_delta = total_replayed -| self.stats.last_replay_tx_count;

                nw_tps = if (time_delta > 0)
                    (@as(f64, @floatFromInt(tx_delta)) / @as(f64, @floatFromInt(time_delta))) * 1000.0
                else
                    0.0;

                self.stats.last_replay_tx_count = total_replayed;
            }

            // Update calculation time (shared between TPU and Network TPS)
            self.stats.last_calc_time = std.time.milliTimestamp();

            // Print rich dashboard
            std.debug.print(
                \\
                \\\x1b[1;36m┌─────────────────────────────────────────────────────────────────────┐\x1b[0m
                \\\x1b[1;36m│\x1b[0m                    \x1b[1;37mVEXOR PERFORMANCE DASHBOARD\x1b[0m                    \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
                \\\x1b[1;36m│\x1b[0m  \x1b[1;33mSlot (Current):\x1b[0m    {d:<12}  \x1b[1;36m│\x1b[0m  \x1b[1;33mNetwork Slot:\x1b[0m {d:<12} \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m│\x1b[0m  \x1b[1;33mNetwork TPS:\x1b[0m       {d:<12.2}  \x1b[1;36m│\x1b[0m  \x1b[1;33mTPU TPS:\x1b[0m      {d:<12.2} \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m├─────────────────────────────────────────────────────────────────────┤\x1b[0m
                \\\x1b[1;36m│\x1b[0m  \x1b[1;32mShreds Received:\x1b[0m   {d:<12}  \x1b[1;36m│\x1b[0m  Inserted: {d:<12}    \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m│\x1b[0m  \x1b[1;32mSlots Completed:\x1b[0m   {d:<12}  \x1b[1;36m│\x1b[0m  Peers:    {d:<12}    \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m│\x1b[0m  \x1b[1;32mRoot Slot:\x1b[0m         {d:<12}  \x1b[1;36m│\x1b[0m  Uptime:   {d:>7.1}s          \x1b[1;36m│\x1b[0m
                \\\x1b[1;36m└─────────────────────────────────────────────────────────────────────┘\x1b[0m
                \\
            , .{
                slot,
                network_slot,
                nw_tps,
                tps,
                shreds_rcvd,
                shreds_inserted,
                slots_completed,
                peers,
                root_slot,
                uptime_s,
            });

            // Consensus trace (compact)
            self.consensus_tracker.printTraceBoard();
            return;
        }

        // Normal status mode
        std.debug.print("\n╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  VEXOR STATUS                                             ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║  Loops: {d:<12}  Slot: {d:<15}          ║\n", .{ loop_count, slot });

        // TVU stats
        if (self.tvu_service) |tvu| {
            const shreds_rcvd = tvu.stats.shreds_received.load(.monotonic);
            const shreds_inserted = tvu.stats.shreds_inserted.load(.monotonic);
            const shreds_invalid = tvu.stats.shreds_invalid.load(.monotonic);
            const slots_completed = tvu.stats.slots_completed.load(.monotonic);

            std.debug.print("║  TVU: rcvd={d:<8} inserted={d:<8} invalid={d:<6}  ║\n", .{
                shreds_rcvd, shreds_inserted, shreds_invalid,
            });
            const max_slot = tvu.stats.max_slot_seen.load(.monotonic);
            std.debug.print("║  TVU: completed={d:<6}  network_slot={d:<12}     ║\n", .{ slots_completed, max_slot });
        }

        // TPU stats
        if (self.tpu_service) |tpu| {
            const received = tpu.stats.transactions_received.load(.monotonic);
            const received_quic = tpu.stats.transactions_received_quic.load(.monotonic);
            const queue_len = tpu.tx_queue.len();

            // Calculate real-time TPS
            const now = std.time.milliTimestamp();
            const time_delta = now - self.stats.last_calc_time;
            const tx_delta = received -| self.stats.last_tx_count;
            const tps = if (time_delta > 0)
                (@as(f64, @floatFromInt(tx_delta)) / @as(f64, @floatFromInt(time_delta))) * 1000.0
            else
                0.0;

            self.stats.last_tx_count = received;
            self.stats.last_calc_time = now;

            std.debug.print("║  TPU: rcvd={d:<8} quic={d:<8} queue={d:<8}      ║\n", .{
                received, received_quic, queue_len,
            });
            std.debug.print("║  TPU: TPS={d:<10.2}                                    ║\n", .{tps});
        }

        // Finality stats
        if (self.replay_stage) |rs| {
            if (rs.rootSlot()) |root| {
                const now = std.time.timestamp();
                if (root > self.stats.last_root_slot) {
                    self.stats.last_root_slot = root;
                    self.stats.last_root_time = now;
                }
                const finality_delay = now - self.stats.last_root_time;
                std.debug.print("║  Finality: Root={d:<10}  Delay={d:<4}s                   ║\n", .{
                    root, finality_delay,
                });
            }
        }

        // Gossip stats
        if (self.gossip_service) |gs| {
            const peers = gs.table.contactCount();
            const stats = gs.table.stats;
            std.debug.print("║  Gossip: peers={d:<4} values_rcvd={d:<8} pulls={d:<6} ║\n", .{
                peers, stats.values_received, stats.pull_requests_sent,
            });
        }

        // Consensus Trace Board
        self.consensus_tracker.printTraceBoard();

        std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});
    }

    /// Enable or disable dashboard mode
    pub fn setDashboardMode(self: *Self, enabled: bool) void {
        self.dashboard_mode = enabled;
        if (enabled) {
            self.dashboard_start_time = std.time.timestamp();
            std.debug.print("📊 Dashboard mode enabled\n", .{});
        }
    }

    fn onTpuVerifiedTransaction(ctx: ?*anyopaque, tx: ParsedTransaction) void {
        const self = @as(*Runtime, @ptrCast(@alignCast(ctx orelse return)));
        if (self.banking_stage) |banking| {
            // Fast-path: Convert to bank transaction and push to incoming queue
            const bank_tx = tx.toBankTransaction(self.allocator) catch |err| {
                std.log.debug("[Runtime] Failed to convert transaction for BankingStage: {}", .{err});
                return;
            };
            banking.queueTransaction(bank_tx, .tpu) catch {};
        }
    }

    fn loadIdentity(self: *Self) !core.Keypair {
        if (self.config.identity_path) |path| {
            return core.loadKeypairFromFile(self.allocator, path) catch |err| {
                std.log.warn("Failed to load identity from {s}: {}", .{ path, err });
                return self.generateDefaultIdentity();
            };
        }
        return self.generateDefaultIdentity();
    }

    fn loadVoteAccount(self: *Self) !?core.Pubkey {
        if (self.config.vote_account_path) |path| {
            const keypair = core.loadKeypairFromFile(self.allocator, path) catch {
                return null;
            };
            return keypair.public;
        }
        return null;
    }

    fn generateDefaultIdentity(self: *Self) core.Keypair {
        _ = self;
        // Generate random keypair for testing
        var keypair: core.Keypair = undefined;
        std.crypto.random.bytes(&keypair.secret);
        // Derive public key (simplified)
        @memcpy(keypair.public.data[0..32], keypair.secret[32..64]);
        return keypair;
    }

    fn getClusterType(self: *Self) core.Config.Cluster {
        return self.config.cluster;
    }

    fn formatPubkey(self: *Self, pubkey: core.Pubkey, buf: *[44]u8) []const u8 {
        _ = self;
        // Simple hex format for now (base58 encoding would be better)
        const len = std.fmt.bufPrint(buf, "{x:0>8}...{x:0>8}", .{
            std.mem.readInt(u32, pubkey.data[0..4], .big),
            std.mem.readInt(u32, pubkey.data[28..32], .big),
        }) catch return "unknown";
        return len;
    }
};

/// Runtime statistics
pub const RuntimeStats = struct {
    start_time: i64 = 0,
    slots_processed: u64 = 0,
    transactions_processed: u64 = 0,
    votes_sent: u64 = 0,
    blocks_produced: u64 = 0,

    // Metrics for real-time calculation
    last_tx_count: u64 = 0,
    last_replay_tx_count: u64 = 0,
    last_calc_time: i64 = 0,
    last_root_slot: u64 = 0,
    last_root_time: i64 = 0,

    pub fn uptime(self: *const RuntimeStats) i64 {
        if (self.start_time == 0) return 0;
        return std.time.timestamp() - self.start_time;
    }

    pub fn slotsPerSecond(self: *const RuntimeStats) f64 {
        const up = self.uptime();
        if (up == 0) return 0;
        return @as(f64, @floatFromInt(self.slots_processed)) / @as(f64, @floatFromInt(up));
    }
};

/// Slot processor
pub const SlotProcessor = struct {
    allocator: std.mem.Allocator,
    slot: core.Slot,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot: core.Slot) Self {
        return .{
            .allocator = allocator,
            .slot = slot,
        };
    }

    /// Process all entries in a slot
    pub fn process(self: *Self) !SlotResult {
        _ = self;
        // TODO: Implement slot processing
        return SlotResult{
            .slot = 0,
            .transactions = 0,
            .successful = 0,
            .failed = 0,
        };
    }
};

pub const SlotResult = struct {
    slot: core.Slot,
    transactions: u64,
    successful: u64,
    failed: u64,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "runtime stats" {
    var stats = RuntimeStats{};
    stats.slots_processed = 100;
    try std.testing.expectEqual(@as(u64, 100), stats.slots_processed);
}

test {
    std.testing.refAllDecls(@This());
    // Shred subsystem test suite
    _ = @import("test_shred_assembler.zig");
    _ = @import("test_fec_resolver.zig");
    _ = @import("test_assembly_pipeline.zig");
    _ = @import("test_rs_recovery.zig");
    _ = @import("merkle_diagnostics.zig");
}
