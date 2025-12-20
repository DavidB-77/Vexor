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
            .tpu_client = null,
            .replay_stage = null,
            .identity = null,
            .vote_account = null,
            .running = std.atomic.Value(bool).init(false),
            .current_slot = std.atomic.Value(u64).init(0),
            .current_epoch = std.atomic.Value(u64).init(0),
            .stats = RuntimeStats{},
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
        self.tvu_service = try network.tvu.TvuService.init(self.allocator, .{
            .tvu_port = self.config.tvu_port,
            .tvu_fwd_port = self.config.tvu_port + 1,
            .repair_port = self.config.repair_port,
            .enable_af_xdp = self.config.enable_af_xdp,
            .interface = self.config.interface,
            .identity = self.identity.?.public.data,
        });
        
        // Connect TVU to gossip for repair peer discovery
        if (self.gossip_service) |gs| {
            self.tvu_service.?.setGossipService(gs);
        }

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
            .testnet => &[_][]const u8{ "https://api.testnet.solana.com" },
            .devnet => &[_][]const u8{ "https://api.devnet.solana.com" },
            .localnet => &[_][]const u8{ "http://localhost:8899" },
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
            
            vote_submitter.start();
            std.log.info("[Bootstrap] Vote submitter started", .{});
            std.debug.print("[DEBUG] Vote submitter started successfully!\n", .{});
        } else {
            std.debug.print("[DEBUG] Vote submitter NOT started - enable_voting={}, vote_account={}\n", .{self.config.enable_voting, self.vote_account != null});
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
        self.tvu_service = try network.tvu.TvuService.init(self.allocator, .{
            .tvu_port = self.config.tvu_port,
            .tvu_fwd_port = self.config.tvu_port + 1,
            .repair_port = self.config.repair_port,
            .enable_af_xdp = self.config.enable_af_xdp,
            .interface = self.config.interface,
            .identity = self.identity.?.public.data,
        });
        
        // Connect TVU to gossip for repair peer discovery
        if (self.gossip_service) |gs| {
            self.tvu_service.?.setGossipService(gs);
        }

        // Initialize TPU client for vote submission
        // Reference: Firedancer fd_quic_tile.c - TPU client initialization
        if (self.config.enable_voting) {
            self.tpu_client = try network.TpuClient.init(self.allocator);
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

        // Update current slot if this is newer
        const current = self.current_slot.load(.seq_cst);
        if (slot > current) {
            self.current_slot.store(slot, .seq_cst);
        }

        // Trigger replay if we have a replay stage
        if (self.replay_stage) |rs| {
            if (self.tvu_service) |tvu| {
                const shreds = tvu.getShredsForSlot(slot) catch return;
                defer self.allocator.free(shreds);
                try rs.onShreds(shreds);
            }
        }
    }

    /// Main run loop
    pub fn run(self: *Self) !void {
        std.debug.print("🚀 Vexor validator running\n", .{});
        std.debug.print("   Press Ctrl+C to stop\n\n", .{});

        // Start gossip
        if (self.gossip_service) |gs| {
            try gs.start();
            std.log.info("Gossip service started", .{});
        }

        // Start TVU
        if (self.tvu_service) |tvu| {
            tvu.start() catch |err| {
                std.log.warn("TVU start failed (non-fatal): {}", .{err});
            };
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

            // Process TVU shreds
            if (self.tvu_service) |tvu| {
                if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: tvu.process\n", .{loop_count});
                tvu.processShreds() catch {};

                // Check for completed slots and trigger replay
                if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: tvu.getCompleted\n", .{loop_count});
                while (tvu.getCompletedSlot()) |slot| {
                    self.onSlotCompleted(slot) catch {};
                }
                
                // Sync current slot from network max slot (even if we haven't completed slots)
                const network_max = tvu.stats.max_slot_seen.load(.monotonic);
                const current = self.current_slot.load(.seq_cst);
                if (network_max > current + 10) { // Only sync if we're significantly behind
                    // Jump to catch up - we'll request repairs from here
                    self.current_slot.store(network_max - 10, .seq_cst);
                }
                
                // Proactively request repairs for catch-up (every 5 seconds)
                if (@mod(loop_count, 50000) == 0) {
                    self.requestCatchUpRepairs(tvu);
                }
            }

            // Update slot counter
            if (loop_count <= 3) std.debug.print("[LOOP] iter {d}: processSlot\n", .{loop_count});
            try self.processSlot();
            
            // Status update every 10 seconds
            const now = std.time.milliTimestamp();
            if (now - last_status_time > 10000) {
                self.printStatus(loop_count);
                last_status_time = now;
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
        
        // Request repairs for the next 10 slots we're missing
        var slot = current_slot;
        var repairs_requested: usize = 0;
        const max_repairs = 10;
        
        while (repairs_requested < max_repairs) : (slot += 1) {
            // Request shred indices 0-63 for each slot (typical slot has ~64 shreds)
            var missing_indices: [64]u32 = undefined;
            for (0..64) |i| {
                missing_indices[i] = @intCast(i);
            }
            
            tvu.requestRepairs(slot, &missing_indices) catch continue;
            repairs_requested += 1;
        }
        
        if (repairs_requested > 0) {
            std.debug.print("[CatchUp] Requested repairs for slots {d}-{d}\n", .{
                current_slot, current_slot + repairs_requested - 1,
            });
        }
    }
    
    /// Print detailed status including TVU and gossip stats
    fn printStatus(self: *Self, loop_count: u64) void {
        const slot = self.current_slot.load(.seq_cst);
        
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
            std.debug.print("║  TVU: completed={d:<6}  network_slot={d:<12}     ║\n", .{slots_completed, max_slot});
        }
        
        // Gossip stats
        if (self.gossip_service) |gs| {
            const peers = gs.table.contactCount();
            const stats = gs.table.stats;
            std.debug.print("║  Gossip: peers={d:<4} values_rcvd={d:<8} pulls={d:<6} ║\n", .{
                peers, stats.values_received, stats.pull_requests_sent,
            });
        }
        
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});
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
}

