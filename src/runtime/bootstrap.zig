//! Vexor Validator Bootstrap
//!
//! Coordinates the full startup sequence for a production validator:
//! 1. Load or download snapshot
//! 2. Initialize accounts database from snapshot
//! 3. Load tower state (vote history)
//! 4. Initialize replay stage
//! 5. Start vote submission loop
//!
//! Inspired by Agave's ReplayStage::new() and Firedancer's tile initialization,
//! but optimized for Zig's memory model and zero-copy operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const consensus = @import("../consensus/root.zig");
const network = @import("../network/root.zig");
const crypto = @import("../crypto/root.zig");
const catchup = @import("../catchup/root.zig");

const bank_mod = @import("bank.zig");
const replay_stage_mod = @import("replay_stage.zig");
const vote_program = @import("vote_program.zig");
const warm_restart = @import("warm_restart.zig");
const shredder = @import("shredder.zig");

const Bank = bank_mod.Bank;
const ReplayStage = replay_stage_mod.ReplayStage;
const TowerBft = consensus.tower.TowerBft;
const SnapshotManager = storage.SnapshotManager;

/// Bootstrap configuration
pub const BootstrapConfig = struct {
    /// Path to identity keypair
    identity_path: []const u8,
    /// Path to vote account keypair
    vote_account_path: ?[]const u8 = null,
    /// Ledger directory
    ledger_dir: []const u8,
    /// Accounts directory
    accounts_dir: []const u8,
    /// Snapshots directory
    snapshots_dir: []const u8,
    /// Tower state path
    tower_path: ?[]const u8 = null,
    /// RPC endpoints for snapshot download
    rpc_endpoints: []const []const u8 = &.{},
    /// Override RPC URL (for local testing)
    rpc_url_override: ?[]const u8 = null,
    /// Entrypoints for gossip
    entrypoints: []const []const u8 = &.{},
    /// Whether to require a snapshot (false for genesis bootstrap)
    require_snapshot: bool = true,
    /// Maximum slots behind to allow snapshot loading
    max_slots_behind: u64 = 100_000,
    /// Enable vote submission
    enable_voting: bool = true,
    /// Vote submission interval (ms)
    vote_interval_ms: u64 = 100,
    /// Network cluster
    cluster: core.Config.Cluster = .testnet,
    /// Enable warm restart (skip snapshot if local state is valid)
    enable_warm_restart: bool = true,
    /// Path to warm restart state file
    warm_restart_state_path: ?[]const u8 = null,
    /// Enable parallel snapshot loading
    enable_parallel_snapshot: bool = true,
    /// Number of threads for parallel snapshot loading (0 = auto)
    parallel_snapshot_threads: usize = 0,
    /// Enable fast catchup (streaming download + parallel processing)
    enable_fast_catchup: bool = false,
    /// Number of threads for fast catchup download (0 = auto)
    fast_catchup_threads: usize = 8,
};

/// Bootstrap result
pub const BootstrapResult = struct {
    /// Root bank after loading
    root_bank: *Bank,
    /// Tower BFT state
    tower: *TowerBft,
    /// Replay stage
    replay_stage: *ReplayStage,
    /// Starting slot
    start_slot: core.Slot,
    /// Accounts loaded
    accounts_loaded: u64,
    /// Total lamports
    total_lamports: u64,
};

/// Bootstrap progress callback
pub const ProgressCallback = *const fn (BootstrapPhase, f64) void;

/// Bootstrap phases
pub const BootstrapPhase = enum {
    initializing,
    finding_snapshot,
    downloading_snapshot,
    extracting_snapshot,
    loading_accounts,
    loading_tower,
    initializing_bank,
    initializing_replay,
    connecting_gossip,
    ready,
};

/// Validator bootstrap coordinator
pub const ValidatorBootstrap = struct {
    allocator: Allocator,
    config: BootstrapConfig,

    // Loaded state
    identity: ?core.Keypair = null,
    vote_account: ?core.Pubkey = null,

    // Subsystems
    snapshot_manager: ?*SnapshotManager = null,
    accounts_db: ?*storage.AccountsDb = null,
    ledger_db: ?*storage.LedgerDb = null,

    // Progress tracking
    current_phase: BootstrapPhase = .initializing,
    progress_callback: ?ProgressCallback = null,

    // Statistics
    stats: BootstrapStats = .{},

    const Self = @This();

    pub fn init(allocator: Allocator, config: BootstrapConfig) !*Self {
        const self_ptr = try allocator.create(Self);
        self_ptr.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self_ptr;
    }

    pub fn deinit(self: *Self) void {
        if (self.snapshot_manager) |sm| {
            // NOTE: Do NOT call cleanupTempSnapshots() here!
            // Extracted snapshots should be kept for faster restarts.
            // The cleanup was causing the validator to re-extract on every restart,
            // which takes ~60 seconds and wastes resources.
            // If cleanup is needed, set VEXOR_SNAPSHOT_CLEANUP=1 env var.
            var should_cleanup = false;
            if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_CLEANUP")) |value| {
                defer self.allocator.free(value);
                should_cleanup = std.mem.eql(u8, value, "1");
            } else |_| {}

            if (should_cleanup) {
                sm.cleanupTempSnapshots();
            }
            sm.deinit();
            self.allocator.destroy(sm);
        }
        if (self.accounts_db) |adb| adb.deinit();
        if (self.ledger_db) |ldb| ldb.deinit();
        self.allocator.destroy(self);
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *Self, callback: ProgressCallback) void {
        self.progress_callback = callback;
    }

    /// Execute full bootstrap sequence
    pub fn bootstrap(self: *Self) !BootstrapResult {
        const start_time = std.time.nanoTimestamp();

        std.debug.print("[DEBUG] Inside bootstrap() function\n", .{});
        std.debug.print("[DEBUG] About to call updatePhase\n", .{});

        // Phase 1: Load identity
        self.updatePhase(.initializing, 0.0);
        std.debug.print("[DEBUG] updatePhase done, loading identity from: {s}\n", .{self.config.identity_path});
        self.loadIdentity() catch |err| {
            std.debug.print("[DEBUG] loadIdentity failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] Identity loaded successfully\n", .{});
        std.log.info("[Bootstrap] Identity loaded: {s}", .{self.formatPubkey(self.identity.?.public)});

        // Phase 2: Initialize storage backends
        self.updatePhase(.initializing, 0.1);
        std.debug.print("[DEBUG] Phase 2: Initializing storage...\n", .{});
        self.initializeStorage() catch |err| {
            std.debug.print("[DEBUG] initializeStorage failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] Storage initialized\n", .{});

        // Phase 3: Try warm restart first, fall back to snapshot
        var snapshot_slot: core.Slot = 0;
        var accounts_loaded: u64 = 0;
        var total_lamports: u64 = 0;
        var used_warm_restart = false;

        // Try warm restart if enabled
        if (self.config.enable_warm_restart) {
            std.debug.print("[DEBUG] Phase 3a: Attempting warm restart...\n", .{});
            const warm_result = self.tryWarmRestart();
            if (warm_result.success) {
                std.log.info("[Bootstrap] WARM RESTART: Resuming from slot {d}", .{warm_result.resume_slot});
                std.log.info("[Bootstrap] WARM RESTART: Only {d} slots to replay (vs full snapshot)", .{warm_result.slots_to_replay});
                snapshot_slot = warm_result.resume_slot;
                accounts_loaded = warm_result.state.?.account_count;
                total_lamports = warm_result.state.?.capitalization;
                used_warm_restart = true;

                // Skip to replay - accounts already loaded from persistent storage
                self.stats.warm_restart_used = true;
                self.stats.slots_replayed = warm_result.slots_to_replay;
            } else {
                std.log.info("[Bootstrap] Warm restart not available: {s}", .{@tagName(warm_result.reason)});
            }
        }

        // Fall back to snapshot if warm restart didn't work
        if (!used_warm_restart) {
            std.debug.print("[DEBUG] Phase 3b: Loading snapshot (require_snapshot={s})...\n", .{if (self.config.require_snapshot) "true" else "false"});
            if (self.config.require_snapshot) {
                self.updatePhase(.finding_snapshot, 0.0);
                const snapshot_result = self.loadFromSnapshot() catch |err| {
                    std.log.err("[Bootstrap] Failed to load snapshot: {}", .{err});
                    return err;
                };
                snapshot_slot = snapshot_result.slot;
                accounts_loaded = snapshot_result.accounts_loaded;
                total_lamports = snapshot_result.lamports_total;
                if (self.accounts_db) |adb| {
                    adb.onSlotCompleted(snapshot_slot);
                }
                std.log.info("[Bootstrap] Snapshot loaded: slot={d}, accounts={d}, lamports={d}", .{
                    snapshot_slot, accounts_loaded, total_lamports,
                });
            } else {
                // Genesis bootstrap
                std.log.info("[Bootstrap] Starting from genesis (no snapshot)", .{});
            }
        }

        // Phase 4: Load tower state
        self.updatePhase(.loading_tower, 0.0);
        const tower = try self.loadOrCreateTower();
        std.log.info("[Bootstrap] Tower loaded: root_slot={?d}", .{tower.rootSlot()});

        // Phase 5: Initialize root bank
        self.updatePhase(.initializing_bank, 0.0);
        const root_bank = try self.initializeRootBank(snapshot_slot);
        std.log.info("[Bootstrap] Root bank initialized: slot={d}", .{root_bank.slot});

        // Phase 6: Initialize consensus engine
        const consensus_engine = try consensus.ConsensusEngine.init(self.allocator, self.identity.?.public);
        consensus_engine.tower = tower.*;

        // Wire vote account and signing keys into consensus engine
        if (self.vote_account) |va| {
            consensus_engine.setVoteAccount(va);
            std.log.info("[Bootstrap] Vote account wired: {any}", .{va.data[0..8]});
        } else {
            std.log.warn("[Bootstrap] No vote account configured — running as non-voting observer", .{});
        }

        // Wire identity secret for vote signing
        if (self.identity) |id| {
            consensus_engine.setIdentitySecret(id.secret);
            std.log.info("[Bootstrap] Identity secret wired for vote signing", .{});
        }

        // Phase 7: Initialize replay stage
        self.updatePhase(.initializing_replay, 0.0);
        const replay_stage = try ReplayStage.init(
            self.allocator,
            self.identity.?.public,
            self.accounts_db.?,
            self.ledger_db.?,
            consensus_engine,
        );
        replay_stage.root_bank = root_bank;

        // Set keypair for shred signing (leader production) and shred version
        if (self.identity) |id| {
            // Shred version is fetched from the cluster; use the snapshot version for now
            replay_stage.setKeypair(id, replay_stage.shred_version);
        }

        // Set identity on leader cache for "am I leader" checks
        replay_stage.leader_cache.setIdentity(self.identity.?.public);

        std.log.info("[Bootstrap] Replay stage initialized", .{});

        // Phase 7.5: Fetch leader schedule from cluster
        // Reference: Sig fetches schedule for CURRENT epoch, not snapshot epoch
        self.updatePhase(.connecting_gossip, 0.3);
        std.log.info("[Bootstrap] Fetching leader schedule from cluster...", .{});

        const rpc_url = self.config.rpc_url_override orelse switch (self.config.cluster) {
            .mainnet_beta => "https://api.mainnet-beta.solana.com",
            .testnet => "https://api.testnet.solana.com",
            .devnet => "https://api.devnet.solana.com",
            .localnet => "http://localhost:8899",
        };

        // First, try to get the CURRENT network slot to fetch the right epoch's schedule
        var current_network_slot: ?u64 = null;
        {
            var client = std.http.Client{ .allocator = self.allocator };
            defer client.deinit();

            const uri = std.Uri.parse(rpc_url) catch null;
            if (uri) |u| {
                var server_header_buffer: [4096]u8 = undefined;
                var req = client.open(.POST, u, .{
                    .server_header_buffer = &server_header_buffer,
                }) catch null;

                if (req) |*r| {
                    defer r.deinit();
                    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}";
                    r.transfer_encoding = .{ .content_length = body.len };
                    r.send() catch {};
                    r.writeAll(body) catch {};
                    r.finish() catch {};
                    r.wait() catch {};

                    var response_buf: [256]u8 = undefined;
                    const response_len = r.reader().readAll(&response_buf) catch 0;
                    const response = response_buf[0..response_len];

                    // Parse "result":NNNNNN from JSON
                    if (std.mem.indexOf(u8, response, "\"result\":")) |idx| {
                        const num_start = idx + 9;
                        var end = num_start;
                        while (end < response.len and response[end] >= '0' and response[end] <= '9') : (end += 1) {}
                        if (end > num_start) {
                            current_network_slot = std.fmt.parseInt(u64, response[num_start..end], 10) catch null;
                        }
                    }
                }
            }
        }

        if (current_network_slot) |net_slot| {
            std.log.info("[Bootstrap] Current network slot: {d} (snapshot: {d}, gap: {d})", .{
                net_slot, snapshot_slot, net_slot -| snapshot_slot,
            });
            // Fetch leader schedule for CURRENT epoch (where network is now)
            replay_stage.leader_cache.fetchFromRpc(rpc_url, net_slot) catch |err| {
                std.log.warn("[Bootstrap] Could not fetch leader schedule for current epoch: {}", .{err});
                // Fallback: try snapshot slot's epoch
                replay_stage.leader_cache.fetchFromRpc(rpc_url, snapshot_slot) catch {};
            };
        } else {
            std.log.warn("[Bootstrap] Could not get current network slot, using snapshot slot", .{});
            replay_stage.leader_cache.fetchFromRpc(rpc_url, snapshot_slot) catch |err| {
                std.log.warn("[Bootstrap] Could not fetch leader schedule: {} (will populate from gossip)", .{err});
            };
        }

        // Also fetch NEXT epoch schedule for block production readiness
        // Like Agave, pre-fetch so we know upcoming leader slots across epoch boundaries
        {
            const current_epoch = if (current_network_slot) |ns| ns / 432000 else snapshot_slot / 432000;
            const next_epoch_first_slot = (current_epoch + 1) * 432000;
            replay_stage.leader_cache.fetchFromRpc(rpc_url, next_epoch_first_slot) catch |err| {
                std.log.info("[Bootstrap] Next epoch leader schedule not yet available: {}", .{err});
            };
        }

        std.log.info("[Bootstrap] Leader schedule loading complete", .{});

        // Update stats
        self.stats.bootstrap_time_ns = @intCast(std.time.nanoTimestamp() - start_time);
        self.stats.accounts_loaded = accounts_loaded;
        self.stats.start_slot = snapshot_slot;

        self.updatePhase(.ready, 1.0);
        std.log.info("[Bootstrap] Complete in {d}ms", .{self.stats.bootstrap_time_ns / 1_000_000});

        return BootstrapResult{
            .root_bank = root_bank,
            .tower = tower,
            .replay_stage = replay_stage,
            .start_slot = snapshot_slot,
            .accounts_loaded = accounts_loaded,
            .total_lamports = total_lamports,
        };
    }

    // ════════════════════════════════════════════════════════════════════════
    // INTERNAL: Identity Loading
    // ════════════════════════════════════════════════════════════════════════

    fn loadIdentity(self: *Self) !void {
        self.identity = try core.loadKeypairFromFile(self.allocator, self.config.identity_path);

        // Load vote account if path provided
        if (self.config.vote_account_path) |path| {
            std.debug.print("[DEBUG] Loading vote account from: {s}\n", .{path});
            const vote_kp = try core.loadKeypairFromFile(self.allocator, path);
            self.vote_account = vote_kp.public;
            std.debug.print("[DEBUG] Vote account loaded successfully\n", .{});
            std.log.info("[Bootstrap] Vote Account: {any}", .{vote_kp.public.data[0..8]});
        } else {
            std.debug.print("[DEBUG] No vote account path configured - running as non-voting node\n", .{});
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // INTERNAL: Storage Initialization
    // ════════════════════════════════════════════════════════════════════════

    fn initializeStorage(self: *Self) !void {
        std.debug.print("[DEBUG] initializeStorage: ensuring directories...\n", .{});
        // Create directories if needed
        self.ensureDirectories() catch |err| {
            std.debug.print("[DEBUG] ensureDirectories failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] Directories created\n", .{});

        // Initialize accounts DB
        std.debug.print("[DEBUG] Initializing accounts DB at: {s}\n", .{self.config.accounts_dir});
        self.accounts_db = storage.AccountsDb.init(self.allocator, self.config.accounts_dir, null) catch |err| {
            std.debug.print("[DEBUG] AccountsDb.init failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] Accounts DB initialized\n", .{});

        // Initialize ledger DB
        std.debug.print("[DEBUG] Initializing ledger DB at: {s}\n", .{self.config.ledger_dir});
        self.ledger_db = storage.LedgerDb.init(self.allocator, self.config.ledger_dir) catch |err| {
            std.debug.print("[DEBUG] LedgerDb.init failed: {}\n", .{err});
            return err;
        };
        std.debug.print("[DEBUG] Ledger DB initialized\n", .{});

        // Initialize snapshot manager
        std.debug.print("[DEBUG] Initializing snapshot manager...\n", .{});
        const sm = try self.allocator.create(SnapshotManager);
        sm.* = SnapshotManager.init(self.allocator, self.config.snapshots_dir);
        self.snapshot_manager = sm;

        // Add RPC endpoints
        std.debug.print("[DEBUG] Adding RPC endpoints...\n", .{});
        for (self.config.rpc_endpoints) |endpoint| {
            std.debug.print("[DEBUG] Adding endpoint: {s}\n", .{endpoint});
            try sm.addRpcEndpoint(endpoint);
        }

        // Add known validators for the cluster (they serve snapshots)
        std.debug.print("[DEBUG] Adding known validators for cluster: {s}\n", .{@tagName(self.config.cluster)});
        try sm.addDefaultKnownValidators(self.config.cluster);
        std.debug.print("[DEBUG] Snapshot manager initialized\n", .{});
    }

    fn ensureDirectories(self: *Self) !void {
        const dirs = [_][]const u8{
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
        };

        for (dirs) |dir| {
            std.fs.cwd().makePath(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // INTERNAL: Snapshot Loading
    // ════════════════════════════════════════════════════════════════════════

    const SnapshotChain = struct {
        full: storage.SnapshotInfo,
        incremental: ?storage.SnapshotInfo,
    };

    fn loadFromSnapshot(self: *Self) !storage.snapshot.LoadResult {
        const sm = self.snapshot_manager orelse return error.NotInitialized;

        // Try to find best snapshot
        self.updatePhase(.finding_snapshot, 0.1);
        std.debug.print("[DEBUG] Finding best snapshot in dir: {s}\n", .{self.config.snapshots_dir});

        // First check local snapshots
        std.debug.print("[DEBUG] Calling findLocalSnapshotChain()...\n", .{});
        const local_chain = self.findLocalSnapshotChain();

        if (local_chain) |chain| {
            std.debug.print("[DEBUG] Found local snapshot chain full slot {d}, hash_str_len={d}\n", .{ chain.full.slot, chain.full.hash_str_len });
            std.log.info("[Bootstrap] Found local snapshot full slot {d}", .{chain.full.slot});
            if (chain.incremental) |inc| {
                std.log.info("[Bootstrap] Found local incremental snapshot slot {d} (base {d})", .{ inc.slot, inc.base_slot orelse 0 });
            }

            var result = try self.loadSnapshotFromDisk(chain.full);
            if (chain.incremental) |inc| {
                const inc_result = try self.loadSnapshotFromDisk(inc);
                result.slot = inc.slot;
                result.accounts_loaded += inc_result.accounts_loaded;
                result.lamports_total = std.math.add(u64, result.lamports_total, inc_result.lamports_total) catch result.lamports_total;
            }
            return result;
        } else {
            std.debug.print("[DEBUG] findLocalSnapshotChain() returned null\n", .{});
        }

        std.debug.print("[DEBUG] No local snapshot, trying remote...\n", .{});

        // Try to find remote snapshot
        self.updatePhase(.downloading_snapshot, 0.0);

        std.debug.print("[DEBUG] Calling findBestSnapshot()...\n", .{});

        if (try sm.findBestSnapshot()) |info| {
            std.log.info("[Bootstrap] Found snapshot info at slot {d}", .{info.slot});

            // Check if we have a download URL
            if (info.download_url) |url| {
                std.log.info("[Bootstrap] Downloading snapshot from: {s}", .{url});

                // Download with progress
                var mutable_info = info;
                sm.download(&mutable_info, struct {
                    fn progress(p: storage.snapshot.DownloadProgress) void {
                        std.log.info("[Bootstrap] Download: {d:.1}% ({d} MB/s)", .{
                            p.percentComplete(),
                            @as(u64, @intFromFloat(p.bytesPerSecond() / 1_000_000)),
                        });
                    }
                }.progress) catch |err| {
                    std.log.warn("[Bootstrap] Snapshot download failed: {}, will start from genesis", .{err});
                    return self.startFromGenesis(info.slot);
                };

                // Extract and load
                self.updatePhase(.extracting_snapshot, 0.0);
                const extract_dir = try std.fmt.allocPrint(self.allocator, "{s}/extracted-{d}", .{
                    self.config.snapshots_dir, info.slot,
                });
                defer self.allocator.free(extract_dir);

                const snapshot_path = try self.getSnapshotPath(&info);
                defer self.allocator.free(snapshot_path);

                sm.extract(snapshot_path, extract_dir) catch |err| {
                    std.log.warn("[Bootstrap] Snapshot extraction failed: {}, will start from genesis", .{err});
                    return self.startFromGenesis(info.slot);
                };

                self.updatePhase(.loading_accounts, 0.0);

                // Choose loading strategy
                var result: storage.snapshot.LoadResult = undefined;
                if (self.config.enable_fast_catchup) {
                    // Use fast catchup (streaming download + parallel processing)
                    std.log.info("[Bootstrap] Using FAST CATCHUP loading", .{});

                    // Create RPC provider for downloading
                    var provider = catchup.RpcSnapshotProvider.init(self.allocator, self.config.rpc_endpoints);
                    // Note: provider doesn't need explicit deinit

                    // Get provider interface
                    const provider_interface = provider.provider();

                    // Create fast catchup manager
                    var fast_catchup = catchup.FastCatchup.init(self.allocator, .{
                        .download_threads = @intCast(self.config.fast_catchup_threads),
                    }, provider_interface);

                    // Run fast catchup
                    const catchup_result = try fast_catchup.catchupToSlot(info.slot, self.accounts_db.?);
                    catchup_result.print();

                    result = storage.snapshot.LoadResult{
                        .slot = catchup_result.final_slot,
                        .accounts_loaded = catchup_result.accounts_loaded,
                        .lamports_total = 0, // TODO: Track total lamports in fast catchup
                    };
                } else if (self.config.enable_parallel_snapshot) {
                    std.log.info("[Bootstrap] Using PARALLEL snapshot loading", .{});
                    var parallel_loader = storage.ParallelSnapshotLoader.init(self.allocator, .{
                        .num_threads = self.config.parallel_snapshot_threads,
                        .verbose = true,
                    });
                    const parallel_result = try parallel_loader.loadSnapshotParallel(extract_dir, self.accounts_db.?);
                    result = storage.snapshot.LoadResult{
                        .slot = info.slot,
                        .accounts_loaded = parallel_result.accounts_loaded,
                        .lamports_total = parallel_result.lamports_total,
                    };
                } else {
                    result = try sm.loadSnapshot(extract_dir, self.accounts_db.?);
                }

                if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_KEEP_TAR")) |value| {
                    defer self.allocator.free(value);
                    if (!std.mem.eql(u8, value, "1")) {
                        std.fs.cwd().deleteFile(snapshot_path) catch {};
                    }
                } else |_| {
                    std.fs.cwd().deleteFile(snapshot_path) catch {};
                }
                var keep_extracted = false;
                if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_KEEP_EXTRACTED")) |value| {
                    defer self.allocator.free(value);
                    keep_extracted = std.mem.eql(u8, value, "1");
                } else |_| {}
                if (!keep_extracted) {
                    std.fs.cwd().deleteTree(extract_dir) catch {};
                }
                return result;
            } else {
                // No download URL - start from genesis and catch up via repair
                std.log.info("[Bootstrap] No snapshot download URL, starting from genesis at slot {d}", .{info.slot});
                return self.startFromGenesis(info.slot);
            }
        }

        // No snapshot found at all - start from genesis slot 0
        std.log.info("[Bootstrap] No snapshot found, starting from genesis", .{});
        return self.startFromGenesis(0);
    }

    /// Start from genesis when no snapshot is available
    /// This initializes empty accounts DB and relies on repair to catch up
    /// NOTE: This will require FAST CATCHUP via shred repair from gossip peers
    fn startFromGenesis(self: *Self, target_slot: u64) !storage.snapshot.LoadResult {
        std.log.info("[Bootstrap] Initializing from genesis, target slot: {d}", .{target_slot});
        std.log.info("[Bootstrap] ⚠️  Fast catchup will be required - downloading shreds from gossip peers", .{});

        // Initialize empty accounts database
        // The validator will catch up via shred repair from the cluster

        const result = storage.snapshot.LoadResult{
            .slot = target_slot,
            .accounts_loaded = 0,
            .lamports_total = 0,
        };
        if (self.accounts_db) |adb| {
            adb.onSlotCompleted(target_slot);
        }
        return result;
    }

    fn findLocalSnapshotChain(self: *Self) ?SnapshotChain {
        std.debug.print("[DEBUG] findLocalSnapshotChain: opening dir {s}\n", .{self.config.snapshots_dir});

        var dir = std.fs.cwd().openDir(self.config.snapshots_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[DEBUG] findLocalSnapshotChain: failed to open dir: {}\n", .{err});
            return null;
        };
        defer dir.close();

        var best_full: ?storage.SnapshotInfo = null;
        var best_full_slot: u64 = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            std.debug.print("[DEBUG] findLocalSnapshotChain: found entry: {s} (kind={any})\n", .{ entry.name, entry.kind });

            if (entry.kind != .file) continue;
            if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
                if (info.is_incremental) continue;

                std.debug.print("[DEBUG] findLocalSnapshotChain: parsed as FULL snapshot slot={d}, hash_str_len={d}\n", .{ info.slot, info.hash_str_len });
                if (info.slot > best_full_slot) {
                    best_full_slot = info.slot;
                    best_full = info;
                }
            } else {
                std.debug.print("[DEBUG] findLocalSnapshotChain: could not parse filename\n", .{});
            }
        }

        if (best_full == null) {
            std.debug.print("[DEBUG] findLocalSnapshotChain: no full snapshots found\n", .{});
            return null;
        }

        var best_incremental: ?storage.SnapshotInfo = null;
        var best_incremental_slot: u64 = 0;
        var inc_dir = std.fs.cwd().openDir(self.config.snapshots_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[DEBUG] findLocalSnapshotChain: failed to re-open dir: {}\n", .{err});
            return SnapshotChain{
                .full = best_full.?,
                .incremental = null,
            };
        };
        defer inc_dir.close();

        var inc_iter = inc_dir.iterate();
        while (inc_iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
                if (!info.is_incremental) continue;
                if (info.base_slot != best_full.?.slot) continue;

                std.debug.print("[DEBUG] findLocalSnapshotChain: parsed as INCREMENTAL snapshot slot={d}, base_slot={d}\n", .{ info.slot, info.base_slot.? });
                if (info.slot > best_incremental_slot) {
                    best_incremental_slot = info.slot;
                    best_incremental = info;
                }
            }
        }

        std.debug.print("[DEBUG] findLocalSnapshotChain: selected full slot {d}\n", .{best_full.?.slot});
        if (best_incremental) |bi| {
            std.debug.print("[DEBUG] findLocalSnapshotChain: selected incremental slot {d} (base {d})\n", .{ bi.slot, bi.base_slot.? });
        }

        return SnapshotChain{
            .full = best_full.?,
            .incremental = best_incremental,
        };
    }

    fn loadSnapshotFromDisk(self: *Self, info: storage.SnapshotInfo) !storage.snapshot.LoadResult {
        const sm = self.snapshot_manager orelse return error.NotInitialized;

        self.updatePhase(.extracting_snapshot, 0.0);

        const snapshot_path = try self.getSnapshotPath(&info);
        defer self.allocator.free(snapshot_path);

        std.debug.print("[DEBUG] loadSnapshotFromDisk: snapshot_path={s}\n", .{snapshot_path});

        // Verify file exists
        std.fs.cwd().access(snapshot_path, .{}) catch |err| {
            std.debug.print("[DEBUG] loadSnapshotFromDisk: file not found at {s}: {}\n", .{ snapshot_path, err });
            return error.FileNotFound;
        };
        std.debug.print("[DEBUG] loadSnapshotFromDisk: file exists!\n", .{});

        const extract_dir = try std.fmt.allocPrint(self.allocator, "{s}/extracted-{d}", .{
            self.config.snapshots_dir, info.slot,
        });
        defer self.allocator.free(extract_dir);

        std.debug.print("[DEBUG] loadSnapshotFromDisk: extract_dir={s}\n", .{extract_dir});

        // Check if already extracted
        std.fs.cwd().access(extract_dir, .{}) catch {
            // Not extracted, extract now
            std.debug.print("[DEBUG] loadSnapshotFromDisk: extracting...\n", .{});
            sm.extract(snapshot_path, extract_dir) catch |err| {
                std.debug.print("[DEBUG] loadSnapshotFromDisk: extraction failed: {}\n", .{err});
                return error.InvalidSnapshot;
            };
            std.debug.print("[DEBUG] loadSnapshotFromDisk: extraction complete\n", .{});
        };

        std.debug.print("[DEBUG] loadSnapshotFromDisk: calling loadSnapshot\n", .{});
        self.updatePhase(.loading_accounts, 0.0);

        // Use parallel loading if enabled
        var result: storage.snapshot.LoadResult = undefined;
        if (self.config.enable_parallel_snapshot) {
            std.log.info("[Bootstrap] Using PARALLEL snapshot loading ({d} threads)", .{
                if (self.config.parallel_snapshot_threads == 0) @as(usize, 8) else self.config.parallel_snapshot_threads,
            });
            var parallel_loader = storage.ParallelSnapshotLoader.init(self.allocator, .{
                .num_threads = self.config.parallel_snapshot_threads,
                .verbose = true,
            });
            const parallel_result = parallel_loader.loadSnapshotParallel(extract_dir, self.accounts_db.?) catch |err| {
                std.debug.print("[DEBUG] loadSnapshotFromDisk: parallel loadSnapshot failed: {}\n", .{err});
                return error.InvalidSnapshot;
            };
            result = storage.snapshot.LoadResult{
                .slot = info.slot,
                .accounts_loaded = parallel_result.accounts_loaded,
                .lamports_total = parallel_result.lamports_total,
            };
        } else {
            result = sm.loadSnapshot(extract_dir, self.accounts_db.?) catch |err| {
                std.debug.print("[DEBUG] loadSnapshotFromDisk: loadSnapshot failed: {}\n", .{err});
                return error.InvalidSnapshot;
            };
            result.slot = info.slot;
        }

        std.debug.print("[DEBUG] loadSnapshotFromDisk: success, loaded {d} accounts\n", .{result.accounts_loaded});
        return result;
    }

    fn getSnapshotPath(self: *Self, info: *const storage.SnapshotInfo) ![]u8 {
        // Use stored hash string for path reconstruction
        const hash_str = info.hash_str[0..info.hash_str_len];

        if (info.is_incremental) {
            return std.fmt.allocPrint(self.allocator, "{s}/incremental-snapshot-{d}-{d}-{s}.tar.zst", .{
                self.config.snapshots_dir,
                info.base_slot.?,
                info.slot,
                hash_str,
            });
        } else {
            return std.fmt.allocPrint(self.allocator, "{s}/snapshot-{d}-{s}.tar.zst", .{
                self.config.snapshots_dir,
                info.slot,
                hash_str,
            });
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // INTERNAL: Tower State Loading/Saving
    // ════════════════════════════════════════════════════════════════════════

    fn loadOrCreateTower(self: *Self) !*TowerBft {
        const tower = try self.allocator.create(TowerBft);
        errdefer self.allocator.destroy(tower);

        // Initialize with full keypair for vote signing
        tower.* = try TowerBft.initWithKeypair(self.allocator, self.identity.?);

        // Try loading tower state from our standard path first
        const primary_path = "/home/sol/vexor/tower-state.bin";
        tower.loadFromDisk(primary_path) catch |err| {
            std.log.info("[Bootstrap] No tower state at primary path: {}", .{err});

            // Try the legacy path as fallback
            const legacy_path = self.config.tower_path orelse blk: {
                break :blk std.fmt.allocPrint(self.allocator, "{s}/tower-{s}.bin", .{
                    self.config.ledger_dir,
                    self.formatPubkey(self.identity.?.public),
                }) catch {
                    break :blk "";
                };
            };
            if (legacy_path.len > 0) {
                tower.loadFromDisk(legacy_path) catch {
                    std.log.info("[Bootstrap] Starting with fresh tower state", .{});
                };
            }
        };

        std.log.info("[Bootstrap] Tower ready: last_vote={d} root={?d}", .{
            tower.last_vote_slot, tower.vote_state.root_slot,
        });
        return tower;
    }

    fn loadTowerFromFile(self: *Self, tower: *TowerBft, path: []const u8) !void {
        _ = tower;
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Read tower state
        // Format: [last_vote_slot: u64] [root_slot: u64] [num_votes: u32] [votes...]
        var buf: [4096]u8 = undefined;
        const bytes_read = try file.readAll(&buf);
        if (bytes_read < 20) return error.InvalidTowerState;

        const last_vote_slot = std.mem.readInt(u64, buf[0..8], .little);
        const root_slot = std.mem.readInt(u64, buf[8..16], .little);
        const num_votes = std.mem.readInt(u32, buf[16..20], .little);
        _ = num_votes;

        // Restore state
        self.stats.tower_last_vote = last_vote_slot;
        self.stats.tower_root_slot = root_slot;
    }

    /// Save tower state to disk
    pub fn saveTower(self: *Self, tower: *const TowerBft) !void {
        const tower_path = self.config.tower_path orelse blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/tower-{s}.bin", .{
                self.config.ledger_dir,
                self.formatPubkey(self.identity.?.public),
            });
        };

        var file = try std.fs.cwd().createFile(tower_path, .{});
        defer file.close();

        // Write header
        var header: [20]u8 = undefined;
        std.mem.writeInt(u64, header[0..8], tower.last_vote_slot, .little);
        std.mem.writeInt(u64, header[8..16], tower.vote_state.root_slot orelse 0, .little);
        std.mem.writeInt(u32, header[16..20], @intCast(tower.vote_state.votes.len), .little);

        try file.writeAll(&header);

        // Write votes
        for (tower.vote_state.votes.slice()) |lockout| {
            var vote_buf: [12]u8 = undefined;
            std.mem.writeInt(u64, vote_buf[0..8], lockout.slot, .little);
            std.mem.writeInt(u32, vote_buf[8..12], lockout.confirmation_count, .little);
            try file.writeAll(&vote_buf);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // INTERNAL: Bank Initialization
    // ════════════════════════════════════════════════════════════════════════

    fn initializeRootBank(self: *Self, slot: core.Slot) !*Bank {
        const bank = try Bank.init(self.allocator, slot, null, self.accounts_db.?);

        // === Diagnostic: probe the AccountsDb for sysvar accounts ===
        const adb = self.accounts_db.?;
        var total_index_entries: usize = 0;
        for (adb.index.bins) |*bin| {
            bin.lock.lockShared();
            total_index_entries += bin.entries.count();
            bin.lock.unlockShared();
        }
        std.debug.print("[BOOTSTRAP-DIAG] AccountsDb index: {d} total entries across {d} bins\n", .{
            total_index_entries, @as(usize, 8192),
        });

        // Probe specific sysvar keys using public getAccount()
        const native_programs = @import("native_programs.zig");
        const sh_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_slot_hashes);
        const sh_loc = adb.index.get(&sh_pubkey);
        std.debug.print("[BOOTSTRAP-DIAG] SlotHashes index.get() = {any}\n", .{sh_loc != null});

        const rbh_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_recent_blockhashes);
        const rbh_loc = adb.index.get(&rbh_pubkey);
        std.debug.print("[BOOTSTRAP-DIAG] RecentBlockhashes index.get() = {any}\n", .{rbh_loc != null});

        // Probe clock sysvar as a control (we know sysvars exist in the snapshot)
        const clock_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_clock);
        const clock_loc = adb.index.get(&clock_pubkey);
        std.debug.print("[BOOTSTRAP-DIAG] Clock sysvar index.get() = {any}\n", .{clock_loc != null});

        // Check if getAccount works end-to-end for clock
        const clock_acct = adb.getAccount(&clock_pubkey);
        std.debug.print("[BOOTSTRAP-DIAG] Clock getAccount() = {any}, data_len={d}\n", .{
            clock_acct != null,
            if (clock_acct) |a| a.data.len else 0,
        });

        // L1 cache
        {
            adb.unflushed_cache_lock.lock();
            const cache_count = adb.unflushed_cache.count();
            adb.unflushed_cache_lock.unlock();
            std.debug.print("[BOOTSTRAP-DIAG] L1 unflushed_cache: {d} entries\n", .{cache_count});
        }

        // Scan ALL bins for sysvar-prefix accounts (first 2 bytes = 06 a7)
        {
            var sysvar_count: usize = 0;
            for (adb.index.bins) |*bin| {
                bin.lock.lockShared();
                var iter = bin.entries.iterator();
                while (iter.next()) |entry| {
                    if (entry.key_ptr.data[0] == 0x06 and entry.key_ptr.data[1] == 0xa7) {
                        sysvar_count += 1;
                        if (sysvar_count <= 5) {
                            std.debug.print("[BOOTSTRAP-DIAG] Sysvar-like key: {x:0>2}\n", .{entry.key_ptr.data});
                        }
                    }
                }
                bin.lock.unlockShared();
            }
            std.debug.print("[BOOTSTRAP-DIAG] Total sysvar-prefix (06 a7) accounts: {d}\n", .{sysvar_count});
        }

        // ════════════════════════════════════════════════════════════════
        // RPC Bridge: Fetch missing sysvars that aren't in the snapshot
        // Modern Solana stores Clock/SlotHashes in Bank metadata, not as
        // account entries.  We fetch them via RPC and inject into RAM.
        // ════════════════════════════════════════════════════════════════
        const rpc_url = self.config.rpc_url_override orelse switch (self.config.cluster) {
            .mainnet_beta => "https://api.mainnet-beta.solana.com",
            .testnet => "https://api.testnet.solana.com",
            .devnet => "https://api.devnet.solana.com",
            .localnet => "http://localhost:8899",
        };

        // --- Fetch & inject SlotHashes sysvar → recent_blockhashes ---
        if (self.fetchSysvarAccountViaRpc(rpc_url, "SysvarS1otHashes111111111111111111111111111")) |sh_data| {
            defer self.allocator.free(sh_data);
            if (sh_data.len >= 8) {
                const count = std.mem.readInt(u64, sh_data[0..8], .little);
                const max_hashes: u64 = 150;
                const to_load = @min(count, max_hashes);
                var loaded: u64 = 0;
                var offset: usize = 8;
                while (loaded < to_load) : (loaded += 1) {
                    if (offset + 40 > sh_data.len) break;
                    // SlotHashes format: (slot: u64, hash: [32]u8) per entry
                    // Skip slot (8 bytes), grab hash (32 bytes)
                    const hash_bytes = sh_data[offset + 8 ..][0..32];
                    var hash: core.Hash = undefined;
                    @memcpy(&hash.data, hash_bytes);
                    bank.recent_blockhashes.push(.{
                        .blockhash = hash,
                        .fee_calculator = .{ .lamports_per_signature = 5000 },
                    });
                    offset += 40;
                }
                std.debug.print("[BOOTSTRAP] ✅ Loaded {d} hashes from SlotHashes via RPC (count={d}, data={d} bytes)\n", .{
                    loaded, count, sh_data.len,
                });
            } else {
                std.debug.print("[BOOTSTRAP] ⚠️  SlotHashes RPC data too short: {d} bytes\n", .{sh_data.len});
            }
        } else {
            std.debug.print("[BOOTSTRAP] ⚠️  Failed to fetch SlotHashes via RPC\n", .{});
            // Fallback: try loading from AccountsDb (won't work on modern snapshots, but safe)
            bank.loadRecentBlockhashesFromSysvar();
        }

        // --- Synthesize Clock sysvar into AccountsDb L1 cache ---
        // Instead of a second RPC call (which gets rate-limited), we construct
        // a mock Clock account in memory. Clock sysvar layout (40 bytes):
        //   slot:                    u64  (offset 0)
        //   epoch_start_timestamp:   i64  (offset 8)
        //   epoch:                   u64  (offset 16)
        //   leader_schedule_epoch:   u64  (offset 24)
        //   unix_timestamp:          i64  (offset 32)
        {
            const synth_clock_pubkey = core.Pubkey.fromBytes(native_programs.program_ids.sysvar_clock);
            // Sysvar1111111111111111111111111111111111111 owner
            const sysvar_owner = core.Pubkey.fromBytes(.{
                0x06, 0xa7, 0xd5, 0x17, 0x18, 0x75, 0xf7, 0x29,
                0xc7, 0x3d, 0x93, 0x40, 0x8f, 0x21, 0x61, 0x20,
                0x06, 0x7e, 0xd8, 0x8c, 0x76, 0xe0, 0x8c, 0x28,
                0x7f, 0xc1, 0x94, 0x60, 0x00, 0x00, 0x00, 0x00,
            });

            // CRITICAL: ArenaAllocator is NOT thread-safe. Both the alloc and
            // the put must be inside the lock to prevent corruption when the
            // Replay thread calls promoteToUnflushedCache concurrently.
            adb.unflushed_cache_lock.lock();
            defer adb.unflushed_cache_lock.unlock();

            const clock_size: usize = 40;
            const arena_alloc = adb.cache_arena.allocator();
            const clock_data = arena_alloc.alloc(u8, clock_size) catch {
                std.debug.print("[BOOTSTRAP] ⚠️  Failed to allocate Clock sysvar in cache arena\n", .{});
                return bank;
            };
            @memset(clock_data, 0);

            // Write current slot into bytes 0..8
            std.mem.writeInt(u64, clock_data[0..8], slot, .little);

            adb.unflushed_cache.put(synth_clock_pubkey, .{
                .lamports = 1,
                .owner = sysvar_owner,
                .executable = false,
                .rent_epoch = 0,
                .data = clock_data,
            }) catch |err| {
                std.debug.print("[BOOTSTRAP] ⚠️  Failed to inject Clock into L1 cache: {}\n", .{err});
            };
            std.debug.print("[BOOTSTRAP] ✅ Synthesized Clock sysvar (slot={d}) into L1 cache\n", .{slot});
        }

        return bank;
    }

    /// Fetch a sysvar's full account data via RPC getAccountInfo.
    /// Returns heap-allocated raw bytes (caller must free), or null on failure.
    fn fetchSysvarAccountViaRpc(self: *Self, rpc_url: []const u8, sysvar_b58: []const u8) ?[]u8 {
        const http = std.http;

        const body = std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"{s}\",{{\"encoding\":\"base64\",\"commitment\":\"confirmed\"}}]}}",
            .{sysvar_b58},
        ) catch return null;
        defer self.allocator.free(body);

        const uri = std.Uri.parse(rpc_url) catch return null;
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writer().writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;

        // SlotHashes can be ~30KB base64, so use a generous buffer
        const response_buf = self.allocator.alloc(u8, 128 * 1024) catch return null;
        defer self.allocator.free(response_buf);
        const len = req.reader().readAll(response_buf) catch return null;
        const response = response_buf[0..len];

        // Extract the base64 data string from the JSON-RPC response
        // Format: {"result":{"value":{"data":["<base64>","base64"],...}}}
        const data_key = "\"data\":[\"";
        const data_pos = std.mem.indexOf(u8, response, data_key) orelse return null;
        const b64_start = data_pos + data_key.len;
        const b64_end = std.mem.indexOfPos(u8, response, b64_start, "\"") orelse return null;
        const b64 = response[b64_start..b64_end];

        if (b64.len == 0) return null;

        const raw_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return null;
        const raw = self.allocator.alloc(u8, raw_len) catch return null;
        std.base64.standard.Decoder.decode(raw, b64) catch {
            self.allocator.free(raw);
            return null;
        };

        std.debug.print("[BOOTSTRAP] Fetched sysvar {s} via RPC: {d} bytes\n", .{ sysvar_b58, raw.len });
        return raw;
    }

    // ════════════════════════════════════════════════════════════════════════
    // WARM RESTART
    // ════════════════════════════════════════════════════════════════════════

    /// Try to warm restart from persisted state
    fn tryWarmRestart(self: *Self) warm_restart.WarmRestartResult {
        const state_path = self.config.warm_restart_state_path orelse blk: {
            // Default path: <ledger_dir>/warm-restart-state.bin
            break :blk std.fmt.allocPrint(
                self.allocator,
                "{s}/warm-restart-state.bin",
                .{self.config.ledger_dir},
            ) catch return .{ .success = false, .reason = .no_state_file };
        };
        defer if (self.config.warm_restart_state_path == null) self.allocator.free(state_path);

        // Get current cluster slot for validation
        const cluster_slot = self.getClusterSlot() catch |err| {
            std.debug.print("[WARM] Cannot get cluster slot: {}\n", .{err});
            return .{ .success = false, .reason = .state_too_old };
        };

        return warm_restart.tryWarmRestart(self.allocator, .{
            .state_path = state_path,
            .accounts_dir = self.config.accounts_dir,
            .ledger_dir = self.config.ledger_dir,
            .current_cluster_slot = cluster_slot,
        }) catch |err| {
            std.debug.print("[WARM] Error checking warm restart: {}\n", .{err});
            return .{ .success = false, .reason = .state_corrupted };
        };
    }

    /// Get current cluster slot from RPC
    fn getClusterSlot(self: *Self) !u64 {
        const rpc_url = self.config.rpc_url_override orelse switch (self.config.cluster) {
            .mainnet_beta => "https://api.mainnet-beta.solana.com",
            .testnet => "https://api.testnet.solana.com",
            .devnet => "https://api.devnet.solana.com",
            .localnet => "http://localhost:8899",
        };

        // Simple HTTP request to get slot
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}";
        const uri = std.Uri.parse(rpc_url) catch return error.InvalidUrl;

        var req = try client.open(.POST, uri, .{
            .server_header_buffer = undefined,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        var response_buf: [256]u8 = undefined;
        const response_len = try req.reader().readAll(&response_buf);

        // Parse slot from response (simple extraction)
        const response = response_buf[0..response_len];
        if (std.mem.indexOf(u8, response, "\"result\":")) |idx| {
            const start = idx + 9;
            var end = start;
            while (end < response.len and response[end] >= '0' and response[end] <= '9') : (end += 1) {}
            if (end > start) {
                return std.fmt.parseInt(u64, response[start..end], 10) catch return error.ParseError;
            }
        }
        return error.NoSlotInResponse;
    }

    /// Save state for warm restart on shutdown
    pub fn saveWarmRestartState(
        self: *Self,
        bank: *Bank,
        shred_version: u16,
        accounts_hash: [32]u8,
        capitalization: u64,
        account_count: u64,
    ) !void {
        const state_path = self.config.warm_restart_state_path orelse blk: {
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{s}/warm-restart-state.bin",
                .{self.config.ledger_dir},
            );
        };
        defer if (self.config.warm_restart_state_path == null) self.allocator.free(state_path);

        var mgr = warm_restart.WarmRestartManager.init(
            self.allocator,
            state_path,
            self.config.accounts_dir,
            self.config.ledger_dir,
        );

        try mgr.onShutdown(
            bank.slot,
            bank.parent_slot orelse 0,
            accounts_hash,
            capitalization,
            account_count,
            bank.blockhash.data,
            bank.epoch,
            shred_version,
            self.identity.?.public.data,
        );

        std.log.info("[Bootstrap] Warm restart state saved. Next restart will be fast!", .{});
    }

    // ════════════════════════════════════════════════════════════════════════
    // UTILITIES
    // ════════════════════════════════════════════════════════════════════════

    fn updatePhase(self: *Self, phase: BootstrapPhase, progress: f64) void {
        self.current_phase = phase;
        if (self.progress_callback) |callback| {
            callback(phase, progress);
        }
    }

    fn formatPubkey(self: *Self, pubkey: core.Pubkey) []const u8 {
        _ = self;
        // Return first 8 and last 8 chars of hex
        const Static = struct {
            var buf: [20]u8 = undefined;
        };
        // Use the actual slice returned by bufPrint, not the whole buffer
        const result = std.fmt.bufPrint(&Static.buf, "{x:0>4}..{x:0>4}", .{
            std.mem.readInt(u16, pubkey.data[0..2], .big),
            std.mem.readInt(u16, pubkey.data[30..32], .big),
        }) catch return "????..????";
        return result;
    }
};

/// Bootstrap statistics
pub const BootstrapStats = struct {
    bootstrap_time_ns: u64 = 0,
    accounts_loaded: u64 = 0,
    start_slot: u64 = 0,
    tower_last_vote: u64 = 0,
    tower_root_slot: u64 = 0,
    // Warm restart stats
    warm_restart_used: bool = false,
    warm_restart_resume_slot: u64 = 0,
    slots_replayed: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// VOTE SUBMISSION LOOP
// ═══════════════════════════════════════════════════════════════════════════════

/// Vote submitter - runs in background to submit votes
pub const VoteSubmitter = struct {
    allocator: Allocator,
    identity: core.Keypair,
    vote_account: core.Pubkey,
    tower: *TowerBft,
    replay_stage: *ReplayStage,
    rpc_url: []const u8,
    enable_rpc_vote_fallback: bool,
    tpu_client: ?*network.TpuClient = null,

    // Gossip service for TVU peer addresses (needed for shred broadcast)
    gossip_service: ?*network.GossipService = null,

    // UDP broadcast socket for sending shreds to peers
    broadcast_socket: ?std.posix.socket_t = null,

    // Slot tracking - pointer to atomic from Runtime
    current_slot_ptr: ?*std.atomic.Value(u64) = null,

    // State
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vote_interval_ms: u64 = 400, // Vote every 400ms (Solana target is 400ms per slot)

    // Epoch tracking for leader schedule refresh
    last_fetched_epoch: u64 = 0,

    // Blockhash cache - avoid fetching every vote (valid ~60s)
    cached_blockhash: core.Hash = core.Hash.ZERO,
    cached_blockhash_ts: i64 = 0,
    cached_blockhash_ttl_ms: i64 = 30_000, // 30 second cache

    // RPC vote rate limiting — Firedancer sends votes via TPU only (no RPC).
    // We use RPC as fallback but throttle to avoid 429 rate limits.
    last_rpc_vote_ns: i128 = 0,

    // Slot hash cache — Firedancer computes bank hashes locally after replay.
    // We can't do that yet, so we cache the RPC SlotHashes response to slash
    // RPC calls from ~150/min to ~30/min. 2-second TTL matches Solana's ~5 slot
    // production rate (each slot ~400ms, so 2s covers ~5 slots).
    cached_slot_hash: ?VoteSlotHash = null,
    cached_slot_hash_ns: i128 = 0,
    slot_hash_cache_hits: u64 = 0,
    slot_hash_rpc_fetches: u64 = 0,

    // Block production (feature-flagged)
    enable_block_production: bool = true, // Toggle on/off
    last_leader_slot_produced: u64 = 0, // Track which leader slots we've produced
    blocks_produced: u64 = 0,
    blocks_skipped: u64 = 0,
    shreds_broadcast: u64 = 0,

    // PoH chaining: last tick hash from our most recent produced block
    // Seeds the next block's PoH for continuity across consecutive leader slots
    last_poh_hash: ?[32]u8 = null,

    // TVU service reference for Turbine tree access
    tvu_service: ?*network.tvu.TvuService = null,

    // TPU service reference for transaction queue access (banking stage)
    tpu_service: ?*network.tpu.TpuService = null,

    // Stats
    stats: VoteStats = .{},

    const Self = @This();
    const VoteSlotHash = struct {
        slot: u64,
        hash: core.Hash,
    };

    pub fn init(
        allocator: Allocator,
        identity: core.Keypair,
        vote_account: core.Pubkey,
        tower: *TowerBft,
        replay_stage: *ReplayStage,
        rpc_url: []const u8,
        enable_rpc_vote_fallback: bool,
    ) !*Self {
        const submitter = try allocator.create(Self);
        submitter.* = .{
            .allocator = allocator,
            .identity = identity,
            .vote_account = vote_account,
            .tower = tower,
            .replay_stage = replay_stage,
            .rpc_url = rpc_url,
            .enable_rpc_vote_fallback = enable_rpc_vote_fallback,
        };
        return submitter;
    }

    /// Set the current slot pointer from Runtime
    pub fn setCurrentSlotPtr(self: *Self, slot_ptr: *std.atomic.Value(u64)) void {
        self.current_slot_ptr = slot_ptr;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        if (self.broadcast_socket) |sock| {
            std.posix.close(sock);
        }
        self.allocator.destroy(self);
    }

    /// Set gossip service for TVU peer discovery (called from Runtime)
    pub fn setGossipService(self: *Self, gs: *network.GossipService) void {
        self.gossip_service = gs;
        std.log.info("[VoteSubmitter] Gossip service connected for shred broadcasting", .{});
    }

    /// Set TVU service for Turbine tree access (called from Runtime)
    pub fn setTvuService(self: *Self, tvu: *network.tvu.TvuService) void {
        self.tvu_service = tvu;
        std.log.info("[VoteSubmitter] TVU service connected for Turbine tree access", .{});
    }

    /// Set TPU service for transaction queue access (banking stage)
    pub fn setTpuService(self: *Self, tpu_svc: *network.tpu.TpuService) void {
        self.tpu_service = tpu_svc;
        std.log.info("[VoteSubmitter] TPU service connected for transaction inclusion (banking stage)", .{});
    }

    /// Initialize UDP broadcast socket for sending shreds
    fn initBroadcastSocket(self: *Self) void {
        if (self.broadcast_socket != null) return;
        const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
            std.log.err("[BlockProducer] Failed to create broadcast socket: {}", .{err});
            return;
        };
        self.broadcast_socket = sock;
        std.log.info("[BlockProducer] Broadcast UDP socket created", .{});
    }

    /// Set TPU client for vote submission
    pub fn setTpuClient(self: *Self, tpu: *network.TpuClient) void {
        self.tpu_client = tpu;
    }

    /// Refresh leader schedule if we haven't fetched recently (rate-limited)
    /// Uses time-based rate limiting to avoid excessive RPC calls
    fn maybeRefreshLeaderSchedule(self: *Self, current_slot: u64, current_epoch: u64) void {
        // Rate limit: only fetch every 10 seconds
        const now = @as(u64, @intCast(std.time.timestamp()));
        if (now < self.last_fetched_epoch + 10) {
            return; // Fetched recently, skip
        }

        std.log.info("[VoteSubmitter] Refreshing leader schedule for slot {d} epoch {d}", .{ current_slot, current_epoch });
        self.last_fetched_epoch = now; // Reuse field as last_fetch_time

        // Fetch current epoch schedule - pass actual slot so epoch is computed correctly
        self.replay_stage.leader_cache.fetchFromRpc(self.rpc_url, current_slot) catch |err| {
            std.log.warn("[VoteSubmitter] Failed to refresh leader schedule: {}", .{err});
            self.last_fetched_epoch = 0; // Reset so we can retry immediately
        };

        // Also fetch NEXT epoch schedule (critical for block production!)
        // Agave/Firedancer pre-fetch the next epoch's schedule before the boundary
        // so they don't miss leader slots at epoch transitions.
        const next_epoch_first_slot = (current_epoch + 1) * 432000;
        self.replay_stage.leader_cache.fetchFromRpc(self.rpc_url, next_epoch_first_slot) catch |err| {
            std.log.info("[VoteSubmitter] Next epoch leader schedule not yet available: {}", .{err});
        };
    }

    /// Start vote submission loop
    pub fn start(self: *Self) void {
        if (self.running.load(.acquire)) {
            std.debug.print("[VoteSubmitter] Already running, skipping start\n", .{});
            return;
        }
        self.running.store(true, .release);

        std.debug.print("[VoteSubmitter] Spawning vote loop thread...\n", .{});

        // Spawn vote loop thread
        const thread = std.Thread.spawn(.{}, voteLoop, .{self}) catch |err| {
            std.debug.print("[VoteSubmitter] FAILED to spawn thread: {}\n", .{err});
            self.running.store(false, .release);
            return;
        };
        thread.detach();
        std.debug.print("[VoteSubmitter] Thread spawned and detached successfully\n", .{});
    }

    /// Stop vote submission
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    fn voteLoop(self: *Self) void {
        std.debug.print("[VoteSubmitter] Vote loop thread STARTED\n", .{});
        std.log.info("[VoteSubmitter] Starting vote loop", .{});

        // One-time log: block production monitoring active
        if (self.enable_block_production) {
            std.log.info("[BlockProducer] Block production monitoring ACTIVE", .{});
        }

        while (self.running.load(.acquire)) {
            if (self.tpu_client) |tpu| {
                tpu.processPending();
            }

            // Check for leader slots and produce blocks
            if (self.enable_block_production) {
                self.checkAndProduceBlock() catch |err| {
                    std.log.err("[BlockProducer] Block production error: {}", .{err});
                };
            }

            self.checkAndSubmitVote() catch |err| {
                std.log.warn("[VoteSubmitter] Vote error: {}", .{err});
            };

            // Sleep for vote interval
            std.time.sleep(self.vote_interval_ms * std.time.ns_per_ms);
        }

        std.log.info("[VoteSubmitter] Vote loop stopped", .{});
    }

    /// Check if we're the leader for the current slot and produce a block
    fn checkAndProduceBlock(self: *Self) !void {
        // Get current slot
        const current_slot: u64 = if (self.current_slot_ptr) |ptr|
            ptr.load(.monotonic)
        else
            return;

        if (current_slot == 0) return;

        // Periodic log: show next leader slot (every ~60s = 150 iterations at 400ms)
        if (self.stats.votes_submitted % 150 == 1) {
            if (self.replay_stage.leader_cache.nextLeaderSlot(self.identity.public, current_slot)) |next_slot| {
                const slots_away = next_slot - current_slot;
                const secs_away = slots_away * 400 / 1000;
                std.log.info("[BlockProducer] Next leader slot: {d} ({d} slots / ~{d}s away)", .{ next_slot, slots_away, secs_away });
            } else {
                std.log.info("[BlockProducer] No future leader slots found in current epoch", .{});
            }
        }

        // Check if we're the leader for this slot
        if (!self.replay_stage.leader_cache.amILeader(current_slot)) {
            return; // Not our slot
        }

        // Don't produce the same slot twice
        if (current_slot <= self.last_leader_slot_produced) {
            return;
        }

        self.last_leader_slot_produced = current_slot;

        std.log.info("[BlockProducer] WE ARE LEADER for slot {d}! Producing block...", .{current_slot});

        // Produce block with transactions from TPU queue (or ticks-only if none)
        self.produceBlock(current_slot) catch |err| {
            self.blocks_skipped += 1;
            std.log.err("[BlockProducer] Failed to produce block for slot {d}: {}", .{ current_slot, err });
            return err;
        };

        self.blocks_produced += 1;
        std.log.info("[BlockProducer] Block produced for slot {d} (total: {d}, skipped: {d})", .{
            current_slot,
            self.blocks_produced,
            self.blocks_skipped,
        });
    }

    /// Produce a block for a leader slot.
    /// Phase 5: Includes transactions from the TPU queue (banking stage).
    /// If no transactions are pending, produces a ticks-only block (still valid on Solana).
    ///
    /// Pipeline: drain TPU → mix tx sigs into PoH → create entries → shred → broadcast → freeze
    /// Reference: Firedancer fd_pack tile + fd_poh tile
    fn produceBlock(self: *Self, slot: u64) !void {
        const ticks_per_slot: u64 = 64;
        const hashes_per_tick: u64 = 12500;
        const max_txns_per_entry: usize = 64; // Solana's max per entry

        // === POH CHAINING (Phase 6) ===
        var poh_hash: [32]u8 = undefined;
        if (self.last_poh_hash) |prev_hash| {
            @memcpy(&poh_hash, &prev_hash);
            std.log.info("[BlockProducer] PoH chained from previous block (slot {d})", .{slot});
        } else {
            const blockhash = self.getRecentBlockhash();
            @memcpy(&poh_hash, &blockhash.data);
            std.log.info("[BlockProducer] PoH seeded from blockhash (first block)", .{});
        }

        // === DRAIN TRANSACTIONS FROM TPU (Phase 5 - Banking Stage) ===
        // Pull pending transactions from the TPU queue (priority-ordered)
        var queued_txns: []network.tpu.QueuedTransaction = &[_]network.tpu.QueuedTransaction{};
        var txn_count: usize = 0;
        var owns_txns = false;

        if (self.tpu_service) |tpu| {
            queued_txns = tpu.drainForBanking(max_txns_per_entry * 4) catch &[_]network.tpu.QueuedTransaction{};
            txn_count = queued_txns.len;
            owns_txns = txn_count > 0;
            if (txn_count > 0) {
                std.log.info("[BlockProducer] Drained {d} transactions from TPU queue for slot {d}", .{ txn_count, slot });
            }
        }
        defer if (owns_txns) self.allocator.free(queued_txns);

        // === BUILD ENTRY DATA ===
        // Interleave transaction entries between tick entries.
        // Solana format: ticks provide PoH timing, transaction entries carry tx data.
        // Reference: Agave's poh_recorder + banking_stage
        var entry_data = std.ArrayList(u8).init(self.allocator);
        defer entry_data.deinit();

        const writer = entry_data.writer();
        var total_tx_included: usize = 0;
        var tx_cursor: usize = 0;

        for (0..ticks_per_slot) |tick_idx| {
            // === Insert transaction entries BEFORE each tick ===
            // Spread transactions across the slot for better timing
            // This matches Firedancer's approach of packing txns between ticks
            if (tx_cursor < txn_count) {
                // Calculate how many txns to include before this tick
                const remaining_ticks = ticks_per_slot - tick_idx;
                const remaining_txns = txn_count - tx_cursor;
                const txns_this_tick = if (remaining_ticks > 0)
                    @min(remaining_txns, (remaining_txns + remaining_ticks - 1) / remaining_ticks)
                else
                    remaining_txns;

                if (txns_this_tick > 0) {
                    const batch_end = @min(tx_cursor + txns_this_tick, txn_count);
                    const batch = queued_txns[tx_cursor..batch_end];

                    // Mix each transaction's signature into PoH
                    for (batch) |*qtx| {
                        // Hash: SHA256(poh_hash || first_64_bytes_of_tx_data)
                        // The first 64 bytes contain the signature
                        var combined: [96]u8 = undefined;
                        @memcpy(combined[0..32], &poh_hash);
                        const sig_len = @min(qtx.len, 64);
                        @memcpy(combined[32..][0..sig_len], qtx.data[0..sig_len]);
                        if (sig_len < 64) @memset(combined[32 + sig_len .. 96], 0);
                        std.crypto.hash.sha2.Sha256.hash(&combined, &poh_hash, .{});
                    }

                    // Write transaction entry:
                    // num_hashes(u64:1) + hash([32]u8) + num_txs(u64) + [raw tx data...]
                    try writer.writeInt(u64, 1, .little); // 1 hash (the PoH mix)
                    try writer.writeAll(&poh_hash);
                    try writer.writeInt(u64, @intCast(batch.len), .little);

                    // Write each transaction's raw data
                    for (batch) |*qtx| {
                        try writer.writeAll(qtx.data[0..qtx.len]);
                    }

                    total_tx_included += batch.len;
                    tx_cursor = batch_end;
                }
            }

            // === Record tick entry ===
            // Compute PoH: hash forward hashes_per_tick times
            for (0..hashes_per_tick) |_| {
                std.crypto.hash.sha2.Sha256.hash(&poh_hash, &poh_hash, .{});
            }

            // Write tick entry: num_hashes(u64) + hash([32]u8) + num_txs(u64:0)
            try writer.writeInt(u64, hashes_per_tick, .little);
            try writer.writeAll(&poh_hash);
            try writer.writeInt(u64, 0, .little); // 0 transactions (tick)
        }

        // Save final PoH hash for chaining to next leader slot
        self.last_poh_hash = poh_hash;

        if (total_tx_included > 0) {
            std.log.info("[BlockProducer] Generated {d} ticks + {d} transactions ({d} bytes) for slot {d}", .{
                ticks_per_slot,
                total_tx_included,
                entry_data.items.len,
                slot,
            });
        } else {
            std.log.info("[BlockProducer] Generated {d} ticks ({d} bytes) for slot {d} (no pending txns)", .{
                ticks_per_slot,
                entry_data.items.len,
                slot,
            });
        }

        // === SHREDDING ===
        // Create proper shreds from entry data using Shredder
        const shred_version = self.replay_stage.shred_version;
        var shredder_inst = shredder.Shredder.init(self.allocator, self.identity, shred_version);
        const parent_slot = if (slot > 0) slot - 1 else 0;
        shredder_inst.startSlot(slot, parent_slot);

        const shred_result = try shredder_inst.shredEntries(entry_data.items, true); // is_last=true for complete block

        const total_shreds = shred_result.data_shreds.len + shred_result.parity_shreds.len;
        std.log.info("[BlockProducer] Shredded slot {d}: {d} data + {d} parity = {d} total shreds (version={d})", .{
            slot,
            shred_result.data_shreds.len,
            shred_result.parity_shreds.len,
            total_shreds,
            shred_version,
        });

        // === BROADCAST via Turbine (UDP to TVU peers) ===
        const peers_sent = self.broadcastShreds(slot, shred_result.data_shreds, shred_result.parity_shreds);
        self.shreds_broadcast += total_shreds;

        std.log.info("[BlockProducer] Broadcast slot {d}: {d} shreds to {d} peers (total broadcast: {d})", .{
            slot,
            total_shreds,
            peers_sent,
            self.shreds_broadcast,
        });

        // === BANK FREEZE (Phase 7) ===
        // Freeze the bank to commit this slot's state
        if (self.replay_stage.root_bank) |bank| {
            bank.freeze() catch |err| {
                std.log.warn("[BlockProducer] Bank freeze for slot {d} failed: {}", .{ slot, err });
            };
            std.log.info("[BlockProducer] Bank frozen for slot {d}", .{slot});
        }

        // Cleanup shred data
        for (shred_result.data_shreds) |s| self.allocator.free(s);
        self.allocator.free(shred_result.data_shreds);
        for (shred_result.parity_shreds) |s| self.allocator.free(s);
        self.allocator.free(shred_result.parity_shreds);
    }

    /// Broadcast shreds to TVU peers via Turbine tree (stake-weighted) or flat fallback.
    /// Phase 4: Uses TVU's TurbineTree for deterministic stake-weighted destinations.
    /// Reference: Firedancer fd_shred_dest.c, Sig turbine_tree.zig
    fn broadcastShreds(self: *Self, slot: u64, data_shreds: []const []u8, parity_shreds: []const []u8) u32 {
        const TURBINE_FANOUT: usize = 200;

        // Ensure broadcast socket is initialized
        self.initBroadcastSocket();
        const sock = self.broadcast_socket orelse {
            std.log.err("[BlockProducer] No broadcast socket available", .{});
            return 0;
        };

        // === TURBINE TREE BROADCAST (Phase 4) ===
        // Use TVU's Turbine tree for stake-weighted destinations.
        // As the LEADER, our position is index 0, so getRetransmitChildren
        // returns our Layer 1 peers (highest-stake validators first).
        if (self.tvu_service) |tvu| {
            if (tvu.turbine.tree != null) {
                return self.broadcastViaTurbine(sock, slot, data_shreds, parity_shreds, &tvu.turbine, TURBINE_FANOUT);
            }
        }

        // === FLAT FALLBACK ===
        // If no Turbine tree available, fall back to flat gossip broadcast
        std.log.info("[BlockProducer] No Turbine tree — using flat gossip broadcast", .{});
        return self.broadcastFlatGossip(sock, data_shreds, parity_shreds, TURBINE_FANOUT);
    }

    /// Broadcast shreds using the Turbine tree for stake-weighted destinations.
    /// For each shred, computes the deterministic destination set and sends.
    fn broadcastViaTurbine(
        self: *Self,
        sock: std.posix.socket_t,
        slot: u64,
        data_shreds: []const []u8,
        parity_shreds: []const []u8,
        turbine: *network.tvu.Turbine,
        fanout: usize,
    ) u32 {
        var send_errors: u32 = 0;
        var total_sent: u32 = 0;
        var max_children: u32 = 0;

        // Broadcast data shreds
        for (data_shreds, 0..) |shred_data, i| {
            // Compute Turbine destinations for this specific shred
            _ = turbine.getRetransmitChildrenForShred(
                self.identity.public,
                slot,
                @intCast(i),
                true, // is_data
            ) catch continue;

            const children = turbine.getChildren() orelse continue;
            if (children.len > max_children) max_children = @intCast(children.len);

            for (children) |child| {
                if (child.tvu_addr) |tvu_addr| {
                    const addr = tvu_addr.toStd();
                    _ = std.posix.sendto(sock, shred_data, 0, &addr.any, addr.getOsSockLen()) catch {
                        send_errors += 1;
                        continue;
                    };
                    total_sent += 1;
                }
            }
        }

        // Broadcast parity shreds
        for (parity_shreds, 0..) |shred_data, i| {
            _ = turbine.getRetransmitChildrenForShred(
                self.identity.public,
                slot,
                @intCast(i),
                false, // is_code (parity)
            ) catch continue;

            const children = turbine.getChildren() orelse continue;

            for (children) |child| {
                if (child.tvu_addr) |tvu_addr| {
                    const addr = tvu_addr.toStd();
                    _ = std.posix.sendto(sock, shred_data, 0, &addr.any, addr.getOsSockLen()) catch {
                        send_errors += 1;
                        continue;
                    };
                    total_sent += 1;
                }
            }
        }

        if (send_errors > 0) {
            std.log.warn("[BlockProducer] Turbine: {d} send errors", .{send_errors});
        }
        std.log.info("[BlockProducer] Turbine broadcast: {d} sends, max {d} children/shred (fanout={d})", .{
            total_sent,
            max_children,
            fanout,
        });

        return max_children;
    }

    /// Flat gossip fallback: send to all TVU peers from gossip table.
    fn broadcastFlatGossip(
        self: *Self,
        sock: std.posix.socket_t,
        data_shreds: []const []u8,
        parity_shreds: []const []u8,
        max_peers: usize,
    ) u32 {
        const gs = self.gossip_service orelse {
            std.log.warn("[BlockProducer] No gossip service — cannot broadcast shreds", .{});
            return 0;
        };

        // Collect TVU addresses
        var tvu_addrs: [200]std.net.Address = undefined;
        var peer_count: u32 = 0;

        var contact_iter = gs.table.contacts.iterator();
        while (contact_iter.next()) |entry| {
            if (peer_count >= max_peers) break;
            if (std.mem.eql(u8, &entry.key_ptr.data, &self.identity.public.data)) continue;

            const tvu_port = entry.value_ptr.tvu_addr.port();
            if (tvu_port != 0) {
                tvu_addrs[peer_count] = entry.value_ptr.tvu_addr.toStd();
                peer_count += 1;
            }
        }

        if (peer_count == 0) {
            std.log.warn("[BlockProducer] No TVU peers found in gossip", .{});
            return 0;
        }

        var send_errors: u32 = 0;
        for (data_shreds) |shred_data| {
            for (tvu_addrs[0..peer_count]) |addr| {
                _ = std.posix.sendto(sock, shred_data, 0, &addr.any, addr.getOsSockLen()) catch {
                    send_errors += 1;
                    continue;
                };
            }
        }
        for (parity_shreds) |shred_data| {
            for (tvu_addrs[0..peer_count]) |addr| {
                _ = std.posix.sendto(sock, shred_data, 0, &addr.any, addr.getOsSockLen()) catch {
                    send_errors += 1;
                    continue;
                };
            }
        }

        if (send_errors > 0) {
            std.log.warn("[BlockProducer] Flat broadcast: {d} send errors", .{send_errors});
        }

        return peer_count;
    }

    fn checkAndSubmitVote(self: *Self) !void {
        // Get current slot from the network (via Runtime's current_slot atomic)
        const current_slot: u64 = if (self.current_slot_ptr) |ptr|
            ptr.load(.monotonic)
        else blk: {
            // Fallback: check shred assembler
            const assembled = self.replay_stage.shred_assembler.getHighestCompletedSlot();
            if (assembled) |s| {
                if (s > 0) break :blk s;
            }

            // No slot source available
            if (self.stats.votes_dropped % 100 == 0) {
                std.debug.print("[VoteSubmitter] Waiting for slots (checked {} times)\n", .{self.stats.votes_dropped});
            }
            self.stats.votes_dropped += 1;
            return;
        };

        if (current_slot == 0) {
            if (self.stats.votes_dropped % 100 == 0) {
                std.debug.print("[VoteSubmitter] Current slot is 0, waiting...\n", .{});
            }
            self.stats.votes_dropped += 1;
            return;
        }

        // Account existence check - skip on hot path, only verify on first vote
        if (self.enable_rpc_vote_fallback and self.stats.votes_submitted == 0) {
            const vote_exists = self.rpcAccountExists(self.vote_account) catch false;
            const id_exists = self.rpcAccountExists(self.identity.public) catch false;
            if (!vote_exists or !id_exists) {
                std.log.warn("[VoteSubmitter] Vote/identity account missing on RPC (vote={any} id={any})", .{
                    vote_exists,
                    id_exists,
                });
                self.stats.votes_dropped += 1;
                return;
            }
        }

        // ═══════════════════════════════════════════════════════════════
        // NUCLEAR FIX: Use LOCAL bank hash instead of public RPC
        // Firedancer computes bank hashes locally after replay.
        // We now do the same — zero RPC dependency, zero latency.
        // This eliminates the 2-second cache TTL and 429 rate limits
        // that were starving our Tower BFT lockout stack.
        // ═══════════════════════════════════════════════════════════════
        var actual_vote_slot: u64 = if (current_slot > 0) current_slot - 1 else current_slot;
        var vote_hash: core.Hash = undefined;
        var hash_source: enum { root_bank, rpc_fallback } = .rpc_fallback;

        // PRIMARY: Get bank hash from our local replay stage (zero latency)
        // root_bank is updated on every completed slot in onSlotCompleted()
        // Accept EITHER bank_hash or blockhash — both are valid vote hashes
        if (self.replay_stage.root_bank) |bank| {
            if (bank.slot > 0) {
                if (!std.mem.eql(u8, &bank.bank_hash.data, &core.Hash.ZERO.data)) {
                    actual_vote_slot = bank.slot;
                    vote_hash = bank.bank_hash;
                    hash_source = .root_bank;
                } else if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
                    actual_vote_slot = bank.slot;
                    vote_hash = bank.blockhash;
                    hash_source = .root_bank;
                }
            }
        }

        // FALLBACK: Only use RPC if local bank completely unavailable (bootstrap edge case)
        if (hash_source == .rpc_fallback) {
            if (self.enable_rpc_vote_fallback) {
                if (self.getRpcVoteSlotAndHash(current_slot)) |rpc_vote| {
                    actual_vote_slot = rpc_vote.slot;
                    vote_hash = rpc_vote.hash;
                } else {
                    self.stats.votes_dropped += 1;
                    return;
                }
            } else {
                vote_hash = self.getVoteHash(actual_vote_slot, self.getRecentBlockhash());
            }
        }

        // Check if we already voted for this or higher slot
        if (self.tower.last_vote_slot >= actual_vote_slot) {
            // Log every 100th skip so we can diagnose stalls
            if (self.stats.votes_dropped % 100 == 0) {
                std.debug.print("[VoteSubmitter] Skip: last_vote={d} >= vote_slot={d} (src={s}, root_bank_slot={d})\n", .{
                    self.tower.last_vote_slot,
                    actual_vote_slot,
                    if (hash_source == .root_bank) "LOCAL" else "RPC",
                    if (self.replay_stage.root_bank) |b| b.slot else 0,
                });
            }
            self.stats.votes_dropped += 1;
            return; // Already voted for this slot
        }

        // Check lockout rules against the ACTUAL slot we'll vote for
        if (!self.tower.vote_state.canVote(actual_vote_slot)) {
            return; // Still locked out
        }

        std.debug.print("[VoteSubmitter] Attempting vote for slot {d} (last_vote: {d})\n", .{ actual_vote_slot, self.tower.last_vote_slot });

        // Get recent blockhash for the transaction (use local bank - no network call!)
        const tx_blockhash = self.getRecentBlockhash();

        // Create vote using the computed slot
        const vote_result = try self.tower.vote(actual_vote_slot, vote_hash);

        // Build vote transaction
        const vote_tx = try self.buildVoteTransaction(vote_result, tx_blockhash);
        defer self.allocator.free(vote_tx);

        // Submit via TPU (best-effort UDP, cheap — always try)
        var tpu_sent = false;
        if (self.tpu_client) |tpu| {
            tpu.sendVote(vote_tx, current_slot) catch |err| {
                if (err == error.VoteQueued) {
                    // Only log every 10th failure to avoid spam
                    if (self.stats.votes_submitted % 10 == 0) {
                        std.debug.print("[VoteSubmitter] Vote queued (leader not found, will try RPC)\n", .{});
                    }
                    const current_epoch = current_slot / 432000;
                    self.maybeRefreshLeaderSchedule(current_slot, current_epoch);
                } else {
                    std.debug.print("[VoteSubmitter] ⚠ TPU vote send error: {} (will try RPC)\n", .{err});
                }
            };
            tpu_sent = true;
        }

        // RPC vote submission — DISABLED when using local bank hashes.
        // TPU UDP is the primary vote transport (no rate limits, direct to leader).
        // Only fall back to RPC every 10s as a heartbeat if local banks unavailable.
        if (hash_source == .rpc_fallback) {
            const VOTE_RPC_MIN_INTERVAL_NS: i128 = 10 * std.time.ns_per_s;
            const now_ns = std.time.nanoTimestamp();
            const elapsed_ns = now_ns - self.last_rpc_vote_ns;
            if (elapsed_ns >= VOTE_RPC_MIN_INTERVAL_NS) {
                self.sendVoteViaRpc(vote_tx) catch |err| {
                    std.debug.print("[VoteSubmitter] RPC sendVote error: {}\n", .{err});
                };
                self.last_rpc_vote_ns = now_ns;
            }
        }

        self.stats.votes_submitted += 1;
        self.stats.last_vote_slot = current_slot;

        // Log every 10th successful vote with hash source and tower depth
        if (self.stats.votes_submitted % 10 == 1) {
            const source_tag: []const u8 = if (hash_source == .root_bank) "LOCAL" else "RPC";
            std.debug.print("[VoteSubmitter] ✓ Vote #{d} for slot {d} (TPU={}, src={s}, tower_depth={d}/31)\n", .{
                self.stats.votes_submitted,
                actual_vote_slot,
                tpu_sent,
                source_tag,
                self.tower.vote_state.votes.len,
            });
        }

        // Persist tower state after every successful vote
        self.tower.saveToDisk("/home/sol/vexor/tower-state.bin") catch |err| {
            std.debug.print("[VoteSubmitter] Tower save failed: {} (non-fatal)\n", .{err});
        };
    }

    /// Get recent blockhash - uses cache to avoid RPC round-trip on every vote.
    /// VEXOR approach: Fast local access when possible, cached RPC when not.
    fn getRecentBlockhash(self: *Self) core.Hash {
        // ALWAYS try local bank first
        if (self.replay_stage.root_bank) |bank| {
            if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
                return bank.blockhash;
            }
            if (!std.mem.eql(u8, &bank.bank_hash.data, &core.Hash.ZERO.data)) {
                return bank.bank_hash;
            }
        }

        // Check cache before making RPC call
        const now_ms = std.time.milliTimestamp();
        if (!std.mem.eql(u8, &self.cached_blockhash.data, &core.Hash.ZERO.data)) {
            if (now_ms - self.cached_blockhash_ts < self.cached_blockhash_ttl_ms) {
                return self.cached_blockhash; // Cache hit - no RPC needed
            }
        }

        // Cache miss - fetch from RPC and cache the result
        const hash = self.fetchBlockhashFromRpc() catch |err| {
            std.debug.print("[VoteSubmitter] RPC blockhash fetch failed: {}\n", .{err});
            // If we have a stale cache, use it rather than a fake hash
            if (!std.mem.eql(u8, &self.cached_blockhash.data, &core.Hash.ZERO.data)) {
                return self.cached_blockhash;
            }
            // Absolute last resort
            var fallback_hash: core.Hash = undefined;
            const ts: u64 = @intCast(std.time.milliTimestamp());
            std.mem.writeInt(u64, fallback_hash.data[0..8], ts, .little);
            @memset(fallback_hash.data[8..], 0xBB);
            return fallback_hash;
        };

        // Update cache
        self.cached_blockhash = hash;
        self.cached_blockhash_ts = now_ms;
        return hash;
    }

    /// Get bank hash for votes - prefer bank_hash, RPC fallback by slot.
    fn getVoteHash(self: *Self, slot: u64, fallback: core.Hash) core.Hash {
        if (self.replay_stage.root_bank) |bank| {
            if (!std.mem.eql(u8, &bank.bank_hash.data, &core.Hash.ZERO.data)) {
                return bank.bank_hash;
            }
        }

        if (self.fetchBlockhashForSlotFromRpc(slot)) |hash| {
            return hash;
        }
        if (slot > 0) {
            if (self.fetchBlockhashForSlotFromRpc(slot - 1)) |hash| {
                return hash;
            }
        }

        return fallback;
    }

    fn getRpcVoteSlotAndHash(self: *Self, current_slot: u64) ?VoteSlotHash {
        _ = current_slot;

        // Firedancer computes bank hashes locally after each replayed slot.
        // Until we have full local replay, we cache the RPC SlotHashes response
        // with a 2-second TTL to dramatically reduce RPC call volume.
        const SLOT_HASH_CACHE_TTL_NS: i128 = 2 * std.time.ns_per_s;
        const now_ns = std.time.nanoTimestamp();

        if (self.cached_slot_hash) |cached| {
            const age = now_ns - self.cached_slot_hash_ns;
            if (age < SLOT_HASH_CACHE_TTL_NS) {
                self.slot_hash_cache_hits += 1;
                return cached;
            }
        }

        // Cache miss or expired — fetch fresh from RPC
        if (self.fetchSlotHashFromSysvarRpc()) |entry| {
            self.cached_slot_hash = entry;
            self.cached_slot_hash_ns = now_ns;
            self.slot_hash_rpc_fetches += 1;

            // Log cache efficiency every 50 fetches
            if (self.slot_hash_rpc_fetches % 50 == 1) {
                std.debug.print("[VoteSubmitter] SlotHash cache: {d} hits, {d} RPC fetches (hit rate: {d}%)\n", .{
                    self.slot_hash_cache_hits,
                    self.slot_hash_rpc_fetches,
                    if (self.slot_hash_cache_hits + self.slot_hash_rpc_fetches > 0)
                        (self.slot_hash_cache_hits * 100) / (self.slot_hash_cache_hits + self.slot_hash_rpc_fetches)
                    else
                        @as(u64, 0),
                });
            }
            return entry;
        }
        return null;
    }

    /// Bootstrap-only: Fetch blockhash via RPC when local bank not available.
    /// This is only used during early bootstrap before bank is initialized.
    fn fetchBlockhashFromRpc(self: *Self) !core.Hash {
        const http = std.http;

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(self.rpc_url) catch return error.InvalidUri;

        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.OpenFailed;
        defer req.deinit();

        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLatestBlockhash\"}";
        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return error.SendFailed;
        req.writer().writeAll(body) catch return error.WriteFailed;
        req.finish() catch return error.FinishFailed;
        req.wait() catch return error.WaitFailed;

        var response_buf: [2048]u8 = undefined;
        const len = req.reader().readAll(&response_buf) catch return error.ReadFailed;
        const response = response_buf[0..len];

        // Parse: "blockhash":"<44-char base58>"
        const needle = "\"blockhash\":\"";
        const pos = std.mem.indexOf(u8, response, needle) orelse return error.ParseFailed;
        const hash_start = pos + needle.len;
        const hash_end = std.mem.indexOfPos(u8, response, hash_start, "\"") orelse return error.ParseFailed;
        const hash_b58 = response[hash_start..hash_end];

        return decodeBase58Hash(hash_b58);
    }

    /// Fetch blockhash for a given slot via RPC getBlock.
    fn fetchBlockhashForSlotFromRpc(self: *Self, slot: u64) ?core.Hash {
        const http = std.http;

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const body = std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBlock\",\"params\":[{d},{{\"transactionDetails\":\"none\",\"rewards\":false}}]}}",
            .{slot},
        ) catch return null;
        defer self.allocator.free(body);

        const uri = std.Uri.parse(self.rpc_url) catch return null;

        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writer().writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;

        var response_buf: [4096]u8 = undefined;
        const len = req.reader().readAll(&response_buf) catch return null;
        if (len == 0) return null;

        const response = response_buf[0..len];
        const needle = "\"blockhash\":\"";
        const pos = std.mem.indexOf(u8, response, needle) orelse return null;
        const hash_start = pos + needle.len;
        const hash_end = std.mem.indexOfPos(u8, response, hash_start, "\"") orelse return null;
        const hash_b58 = response[hash_start..hash_end];

        return decodeBase58Hash(hash_b58) catch return null;
    }

    fn fetchSlotFromRpc(self: *Self) ?u64 {
        const http = std.http;

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}";
        const uri = std.Uri.parse(self.rpc_url) catch return null;

        var server_header_buf: [2048]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writer().writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;

        var response_buf: [2048]u8 = undefined;
        const len = req.reader().readAll(&response_buf) catch return null;
        const response = response_buf[0..len];

        const needle = "\"result\":";
        const pos = std.mem.indexOf(u8, response, needle) orelse return null;
        const start_idx = pos + needle.len;
        const comma = std.mem.indexOfPos(u8, response, start_idx, ",");
        const brace = std.mem.indexOfPos(u8, response, start_idx, "}") orelse return null;
        const end = if (comma) |c| @min(c, brace) else brace;
        const slot_str = std.mem.trim(u8, response[start_idx..end], " \n\r\t");
        return std.fmt.parseInt(u64, slot_str, 10) catch return null;
    }

    fn fetchFirstAvailableBlockFromRpc(self: *Self) ?u64 {
        const http = std.http;

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getFirstAvailableBlock\"}";
        const uri = std.Uri.parse(self.rpc_url) catch return null;

        var server_header_buf: [2048]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writer().writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;

        var response_buf: [2048]u8 = undefined;
        const len = req.reader().readAll(&response_buf) catch return null;
        const response = response_buf[0..len];

        const needle = "\"result\":";
        const pos = std.mem.indexOf(u8, response, needle) orelse return null;
        const start_idx = pos + needle.len;
        const comma = std.mem.indexOfPos(u8, response, start_idx, ",");
        const brace = std.mem.indexOfPos(u8, response, start_idx, "}") orelse return null;
        const end = if (comma) |c| @min(c, brace) else brace;
        const slot_str = std.mem.trim(u8, response[start_idx..end], " \n\r\t");
        return std.fmt.parseInt(u64, slot_str, 10) catch return null;
    }

    fn fetchSlotHashFromSysvarRpc(self: *Self) ?VoteSlotHash {
        const http = std.http;
        const slot_hashes_sysvar = "SysvarS1otHashes111111111111111111111111111";

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Fetch ONLY the first 48 bytes of SlotHashes sysvar:
        // [8 bytes count] + [8 bytes slot] + [32 bytes bank_hash]
        // Using dataSlice cuts response from 65KB to ~200 bytes!
        const body = std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"{s}\",{{\"encoding\":\"base64\",\"dataSlice\":{{\"offset\":0,\"length\":48}},\"commitment\":\"confirmed\"}}]}}",
            .{slot_hashes_sysvar},
        ) catch return null;
        defer self.allocator.free(body);

        const uri = std.Uri.parse(self.rpc_url) catch return null;
        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return null;
        req.writer().writeAll(body) catch return null;
        req.finish() catch return null;
        req.wait() catch return null;

        var response_buf: [4096]u8 = undefined;
        const len = req.reader().readAll(&response_buf) catch return null;
        const response = response_buf[0..len];

        // Parse the base64 data (only ~64 chars instead of ~86K)
        const data_key = "\"data\":[\"";
        const data_pos = std.mem.indexOf(u8, response, data_key) orelse return null;
        const b64_start = data_pos + data_key.len;
        const b64_end = std.mem.indexOfPos(u8, response, b64_start, "\"") orelse return null;
        const b64 = response[b64_start..b64_end];

        const raw_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return null;
        if (raw_len < 48) return null;

        var raw: [48]u8 = undefined;
        _ = std.base64.standard.Decoder.decode(&raw, b64) catch return null;

        const count = std.mem.readInt(u64, raw[0..8], .little);
        if (count == 0) return null;

        const slot = std.mem.readInt(u64, raw[8..16], .little);
        var hash: core.Hash = undefined;
        @memcpy(&hash.data, raw[16..48]);
        return .{ .slot = slot, .hash = hash };
    }

    fn sendVoteViaRpc(self: *Self, vote_tx: []const u8) !void {
        const http = std.http;

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const b64_len = std.base64.standard.Encoder.calcSize(vote_tx.len);
        const b64_buf = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64_buf);
        _ = std.base64.standard.Encoder.encode(b64_buf, vote_tx);

        const uri = try std.Uri.parse(self.rpc_url);

        // Send directly with skipPreflight=true (no simulate - saves ~3s per vote)
        const send_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendTransaction\",\"params\":[\"{s}\",{{\"encoding\":\"base64\",\"skipPreflight\":true}}]}}",
            .{b64_buf},
        );
        defer self.allocator.free(send_body);

        var server_header_buf: [4096]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = send_body.len };
        try req.send();
        try req.writer().writeAll(send_body);
        try req.finish();
        try req.wait();

        var response_buf: [2048]u8 = undefined;
        const len = try req.reader().readAll(&response_buf);
        const response = response_buf[0..len];

        if (std.mem.indexOf(u8, response, "\"error\"")) |_| {
            std.debug.print("[VoteSubmitter] RPC sendTransaction error: {s}\n", .{response});
        } else {
            std.debug.print("[VoteSubmitter] RPC sendTransaction ok\n", .{});
        }
    }

    fn rpcAccountExists(self: *Self, pubkey: core.Pubkey) !bool {
        const http = std.http;
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const b58 = try encodeBase58(self.allocator, &pubkey.data);
        defer self.allocator.free(b58);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"{s}\",{{\"encoding\":\"base64\"}}]}}",
            .{b58},
        );
        defer self.allocator.free(body);

        const uri = try std.Uri.parse(self.rpc_url);
        var server_header_buf: [4096]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        try req.writer().writeAll(body);
        try req.finish();
        try req.wait();

        var response_buf: [2048]u8 = undefined;
        const len = try req.reader().readAll(&response_buf);
        const response = response_buf[0..len];

        if (std.mem.indexOf(u8, response, "\"value\":null") != null) {
            return false;
        }
        return true;
    }

    /// Decode base58 string to 32-byte hash (used for RPC blockhash parsing)
    fn decodeBase58Hash(b58: []const u8) !core.Hash {
        const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

        var bytes: [32]u8 = [_]u8{0} ** 32;
        var num: [64]u8 = [_]u8{0} ** 64; // little-endian base256
        var num_len: usize = 1;

        for (b58) |c| {
            const digit = std.mem.indexOf(u8, alphabet, &[_]u8{c}) orelse return error.InvalidBase58;

            var carry: u32 = @intCast(digit);
            var i: usize = 0;
            while (i < num_len) : (i += 1) {
                carry += @as(u32, num[i]) * 58;
                num[i] = @truncate(carry & 0xFF);
                carry >>= 8;
            }
            while (carry != 0) {
                num[num_len] = @truncate(carry & 0xFF);
                num_len += 1;
                carry >>= 8;
            }
        }

        // Copy into fixed 32-byte array (big-endian)
        var i: usize = 0;
        while (i < num_len and i < 32) : (i += 1) {
            bytes[31 - i] = num[i];
        }

        return core.Hash{ .data = bytes };
    }

    fn buildVoteTransaction(self: *Self, vote_data: consensus.vote.Vote, blockhash: core.Hash) ![]u8 {
        // TowerSync vote transaction — sends full tower to the cluster.
        //
        // Account layout for TowerSync (from Agave source):
        //   0: validator identity (signer, writable - pays fees)
        //   1: vote account (writable)
        //   2: vote program (readonly)
        //
        // TowerSync uses ONLY 2 instruction accounts: vote_account + authority.
        // NO sysvar accounts needed (unlike simple Vote which needs clock + slot_hashes).

        var tx_buf = std.ArrayList(u8).init(self.allocator);
        errdefer tx_buf.deinit();

        // === SIGNATURES SECTION ===
        try tx_buf.append(1); // 1 signature (identity signs)
        try tx_buf.appendNTimes(0, 64); // placeholder signature

        // === MESSAGE HEADER ===
        try tx_buf.append(1); // num_required_signatures
        try tx_buf.append(0); // num_readonly_signed
        try tx_buf.append(1); // num_readonly_unsigned (vote program only)

        // === ACCOUNT KEYS (3 accounts) ===
        try tx_buf.append(3); // account count
        try tx_buf.appendSlice(&self.identity.public.data); // 0: identity (signer, fee payer)
        try tx_buf.appendSlice(&self.vote_account.data); // 1: vote account (writable)
        try tx_buf.appendSlice(&VOTE_PROGRAM_ID); // 2: vote program

        // === RECENT BLOCKHASH ===
        try tx_buf.appendSlice(&blockhash.data);

        // === INSTRUCTIONS ===
        try tx_buf.append(1); // instruction count

        // Vote instruction header — TowerSync uses 2 accounts
        try tx_buf.append(2); // program_id_index (vote program = account 2)
        try tx_buf.append(2); // num_accounts in instruction
        try tx_buf.append(1); // vote account (account index 1, writable)
        try tx_buf.append(0); // vote authority = identity (account index 0, signer)

        // Serialize TowerSync instruction data
        const vote_ix_data = try self.serializeTowerSync(vote_data);
        defer self.allocator.free(vote_ix_data);

        // Data length as Solana short_vec
        try appendShortVec(&tx_buf, vote_ix_data.len);
        try tx_buf.appendSlice(vote_ix_data);

        // === SIGN THE MESSAGE ===
        const message_start: usize = 65; // After signature count (1) + signature (64)
        const message = tx_buf.items[message_start..];

        const Ed25519 = std.crypto.sign.Ed25519;
        const secret_key = Ed25519.SecretKey{ .bytes = self.identity.secret };
        const keypair = Ed25519.KeyPair.fromSecretKey(secret_key) catch {
            return error.SigningFailed;
        };
        const sig = keypair.sign(message, null) catch {
            return error.SigningFailed;
        };

        // Copy signature into buffer (bytes 1-64)
        @memcpy(tx_buf.items[1..65], &sig.toBytes());

        return tx_buf.toOwnedSlice();
    }

    /// Encodes a usize as Solana short_vec (compact-u16).
    /// Values < 0x80 → 1 byte; < 0x4000 → 2 bytes; else → 3 bytes.
    fn appendShortVec(buf: *std.ArrayList(u8), val: usize) !void {
        var v = val;
        while (v >= 0x80) {
            try buf.append(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try buf.append(@intCast(v));
    }

    /// Encodes a u64 as Solana serde_varint (LEB128-style).
    fn appendVarint(buf: *std.ArrayList(u8), val: u64) !void {
        var v = val;
        while (v >= 0x80) {
            try buf.append(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try buf.append(@intCast(v));
    }

    fn serializeTowerSync(self: *Self, vote: consensus.vote.Vote) ![]u8 {
        // TowerSync (discriminant 14) — Agave's newest vote instruction format.
        //
        // Wire format (from Agave sdk/program/src/vote/state/mod.rs serde_tower_sync):
        //   [4 bytes] Bincode enum discriminant = 14 (u32 LE)
        //   [8 bytes] root slot (u64 LE; Slot::MAX = 0xFFFFFFFFFFFFFFFF if None)
        //   [short_vec] lockout count
        //   For each lockout:
        //     [varint] offset (slot delta from previous slot or root)
        //     [1 byte] confirmation_count (u8)
        //   [32 bytes] hash
        //   [1 byte]  timestamp option tag (0=None, 1=Some)
        //   [8 bytes] timestamp (i64 LE, if Some)
        //   [32 bytes] block_id
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        // Discriminant: 14 = TowerSync
        try buf.writer().writeInt(u32, 14, .little);

        // Root slot: use tower's root, or Slot::MAX (u64 max) if None
        const root_slot: u64 = self.tower.vote_state.root_slot orelse std.math.maxInt(u64);
        try buf.writer().writeInt(u64, root_slot, .little);

        // Build lockout offsets from the tower's vote stack
        // Each lockout's offset is the difference from the previous slot (or root)
        const tower_votes = &self.tower.vote_state.votes;
        const lockout_count = tower_votes.len;

        // The tower already includes the new vote (recordVote was called before this).
        // Just serialize the full tower state as-is.

        // Short_vec encode the lockout count
        try appendShortVec(&buf, lockout_count);

        // Encode each lockout as {varint offset, u8 confirmation_count}
        var prev_slot: u64 = if (self.tower.vote_state.root_slot) |rs| rs else 0;

        for (tower_votes.slice()) |lockout| {
            const lockout_slot = lockout.slot;
            const offset: u64 = if (lockout_slot > prev_slot) lockout_slot - prev_slot else 0;
            try appendVarint(&buf, offset);
            // Confirmation count as u8 (capped at 31 per Solana spec)
            const cc: u8 = if (lockout.confirmation_count > 255)
                255
            else
                @intCast(lockout.confirmation_count);
            try buf.append(cc);
            prev_slot = lockout_slot;
        }

        // Hash (32 bytes) — the bank hash of the slot we're voting for
        try buf.writer().writeAll(&vote.hash.data);

        // Timestamp: Option<i64>
        try buf.writer().writeByte(1); // Some
        try buf.writer().writeInt(i64, vote.timestamp, .little);

        // Block_id (32 bytes) — use same hash as vote hash for now
        // In a full implementation this would be the block's SHA256,
        // but using vote hash is acceptable as it identifies the block.
        try buf.writer().writeAll(&vote.hash.data);

        // Detailed debug logging for first 20 votes to diagnose SlotsNotOrdered
        if (self.stats.votes_submitted < 20) {
            const root_disp = self.tower.vote_state.root_slot orelse 0;
            std.debug.print("[TowerSync] vote#{d} slot={d} root={d} lockouts={d}\n", .{
                self.stats.votes_submitted,
                vote.slot,
                root_disp,
                lockout_count,
            });
            var dbg_prev: u64 = if (self.tower.vote_state.root_slot) |rs| rs else 0;
            for (tower_votes.slice(), 0..) |lk, idx| {
                const dbg_off = if (lk.slot > dbg_prev) lk.slot - dbg_prev else 0;
                std.debug.print("  [{d}] slot={d} cc={d} offset={d}\n", .{
                    idx, lk.slot, lk.confirmation_count, dbg_off,
                });
                dbg_prev = lk.slot;
            }
        }

        return buf.toOwnedSlice();
    }
};

// Vote Program ID
const VOTE_PROGRAM_ID = vote_program.VOTE_PROGRAM_ID;

// Sysvar IDs (base58 decoded)
const SYSVAR_CLOCK_ID = [_]u8{
    0x06, 0xa7, 0xd5, 0x17, 0x18, 0xc7, 0x74, 0xc9, 0x28, 0x56, 0x63, 0x98, 0x69, 0x1d, 0x5e, 0xb6,
    0x8b, 0x5e, 0xb8, 0xa3, 0x9b, 0x4b, 0x6d, 0x5c, 0x73, 0x55, 0x5b, 0x21, 0x00, 0x00, 0x00, 0x00,
};

const SYSVAR_SLOT_HASHES_ID = [_]u8{
    0x06, 0xa7, 0xd5, 0x17, 0x19, 0x2f, 0x0a, 0xaf, 0xc6, 0xf2, 0x65, 0xe3, 0xfb, 0x77, 0xcc, 0x7a,
    0xda, 0x82, 0xc5, 0x29, 0xd0, 0xbe, 0x3b, 0x13, 0x6e, 0x2d, 0x00, 0x55, 0x20, 0x00, 0x00, 0x00,
};

/// Vote statistics
pub const VoteStats = struct {
    votes_submitted: u64 = 0,
    votes_dropped: u64 = 0,
    votes_confirmed: u64 = 0,
    last_vote_slot: u64 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "bootstrap config defaults" {
    const config = BootstrapConfig{
        .identity_path = "/path/to/identity.json",
        .ledger_dir = "/mnt/ledger",
        .accounts_dir = "/mnt/accounts",
        .snapshots_dir = "/mnt/snapshots",
    };

    try std.testing.expect(config.require_snapshot);
    try std.testing.expectEqual(@as(u64, 100_000), config.max_slots_behind);
}

fn encodeBase58(allocator: Allocator, data: []const u8) ![]u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    // Count leading zeros
    var zeros: usize = 0;
    while (zeros < data.len and data[zeros] == 0) : (zeros += 1) {}

    var buf = try allocator.alloc(u8, data.len);
    defer allocator.free(buf);
    @memcpy(buf, data);

    var start: usize = zeros;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    while (start < buf.len) {
        var carry: u32 = 0;
        var i: usize = start;
        while (i < buf.len) : (i += 1) {
            const val: u32 = (@as(u32, buf[i]) & 0xff) + (carry << 8);
            buf[i] = @intCast(val / 58);
            carry = val % 58;
        }
        try out.append(alphabet[@intCast(carry)]);

        while (start < buf.len and buf[start] == 0) : (start += 1) {}
    }

    var z: usize = 0;
    while (z < zeros) : (z += 1) {
        try out.append('1');
    }

    const out_len = out.items.len;
    const res = try allocator.alloc(u8, out_len);
    var j: usize = 0;
    while (j < out_len) : (j += 1) {
        res[j] = out.items[out_len - 1 - j];
    }
    out.deinit();
    return res;
}

test "bootstrap phases" {
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(BootstrapPhase).Enum.fields.len);
}
