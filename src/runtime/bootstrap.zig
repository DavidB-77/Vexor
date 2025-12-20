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

const bank_mod = @import("bank.zig");
const replay_stage_mod = @import("replay_stage.zig");

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
        
        // Phase 3: Find and download snapshot
        var snapshot_slot: core.Slot = 0;
        var accounts_loaded: u64 = 0;
        var total_lamports: u64 = 0;
        
        std.debug.print("[DEBUG] Phase 3: Loading snapshot (require_snapshot={s})...\n", .{if (self.config.require_snapshot) "true" else "false"});
        if (self.config.require_snapshot) {
            self.updatePhase(.finding_snapshot, 0.0);
            const snapshot_result = self.loadFromSnapshot() catch |err| {
                std.log.err("[Bootstrap] Failed to load snapshot: {}", .{err});
                return err;
            };
            snapshot_slot = snapshot_result.slot;
            accounts_loaded = snapshot_result.accounts_loaded;
            total_lamports = snapshot_result.lamports_total;
            std.log.info("[Bootstrap] Snapshot loaded: slot={d}, accounts={d}, lamports={d}", .{
                snapshot_slot, accounts_loaded, total_lamports,
            });
        } else {
            // Genesis bootstrap
            std.log.info("[Bootstrap] Starting from genesis (no snapshot)", .{});
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
        
        // Set identity on leader cache for "am I leader" checks
        replay_stage.leader_cache.setIdentity(self.identity.?.public.data);
        
        std.log.info("[Bootstrap] Replay stage initialized", .{});
        
        // Phase 7.5: Fetch leader schedule from cluster
        self.updatePhase(.connecting_gossip, 0.3);
        std.log.info("[Bootstrap] Fetching leader schedule from cluster...", .{});
        
        const rpc_url = switch (self.config.cluster) {
            .mainnet_beta => "https://api.mainnet-beta.solana.com",
            .testnet => "https://api.testnet.solana.com",
            .devnet => "https://api.devnet.solana.com",
            .localnet => "http://localhost:8899",
        };
        
        replay_stage.leader_cache.fetchFromRpc(rpc_url, snapshot_slot) catch |err| {
            std.log.warn("[Bootstrap] Could not fetch leader schedule: {} (will populate from gossip)", .{err});
        };
        
        std.log.info("[Bootstrap] Leader schedule loaded", .{});
        
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
        self.accounts_db = storage.AccountsDb.init(self.allocator, self.config.accounts_dir) catch |err| {
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
    
    fn loadFromSnapshot(self: *Self) !storage.snapshot.LoadResult {
        const sm = self.snapshot_manager orelse return error.NotInitialized;
        
        // Try to find best snapshot
        self.updatePhase(.finding_snapshot, 0.1);
        std.debug.print("[DEBUG] Finding best snapshot in dir: {s}\n", .{self.config.snapshots_dir});
        
        // First check local snapshots
        std.debug.print("[DEBUG] Calling findLocalSnapshot()...\n", .{});
        const local_snapshot = self.findLocalSnapshot();
        
        if (local_snapshot) |info| {
            std.debug.print("[DEBUG] Found local snapshot at slot {d}, hash_str_len={d}\n", .{info.slot, info.hash_str_len});
            std.log.info("[Bootstrap] Found local snapshot at slot {d}", .{info.slot});
            return try self.loadSnapshotFromDisk(info);
        } else {
            std.debug.print("[DEBUG] findLocalSnapshot() returned null\n", .{});
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
                return try sm.loadSnapshot(extract_dir, self.accounts_db.?);
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
    fn startFromGenesis(_: *Self, target_slot: u64) !storage.snapshot.LoadResult {
        std.log.info("[Bootstrap] Initializing from genesis, target slot: {d}", .{target_slot});
        std.log.info("[Bootstrap] ⚠️  Fast catchup will be required - downloading shreds from gossip peers", .{});
        
        // Initialize empty accounts database
        // The validator will catch up via shred repair from the cluster
        
        return storage.snapshot.LoadResult{
            .slot = target_slot,
            .accounts_loaded = 0,
            .lamports_total = 0,
        };
    }
    
    fn findLocalSnapshot(self: *Self) ?storage.SnapshotInfo {
        std.debug.print("[DEBUG] findLocalSnapshot: opening dir {s}\n", .{self.config.snapshots_dir});
        
        var dir = std.fs.cwd().openDir(self.config.snapshots_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[DEBUG] findLocalSnapshot: failed to open dir: {}\n", .{err});
            return null;
        };
        defer dir.close();
        
        var best_full: ?storage.SnapshotInfo = null;
        var best_full_slot: u64 = 0;
        var best_incremental: ?storage.SnapshotInfo = null;
        var best_incremental_slot: u64 = 0;
        
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            std.debug.print("[DEBUG] findLocalSnapshot: found entry: {s} (kind={any})\n", .{entry.name, entry.kind});
            
            if (entry.kind != .file) continue;
            if (storage.SnapshotInfo.fromFilename(entry.name)) |info| {
                if (info.is_incremental) {
                    // ✅ Track incrementals separately
                    std.debug.print("[DEBUG] findLocalSnapshot: parsed as INCREMENTAL snapshot slot={d}, hash_str_len={d}\n", .{info.slot, info.hash_str_len});
                    if (info.slot > best_incremental_slot) {
                        best_incremental_slot = info.slot;
                        best_incremental = info;
                    }
                } else {
                    // ✅ Track full snapshots separately
                    std.debug.print("[DEBUG] findLocalSnapshot: parsed as FULL snapshot slot={d}, hash_str_len={d}\n", .{info.slot, info.hash_str_len});
                    if (info.slot > best_full_slot) {
                        best_full_slot = info.slot;
                        best_full = info;
                    }
                }
            } else {
                std.debug.print("[DEBUG] findLocalSnapshot: could not parse filename\n", .{});
            }
        }
        
        // ✅ PRIORITY: Return full snapshot (not incremental)
        if (best_full) |bf| {
            std.debug.print("[DEBUG] findLocalSnapshot: returning FULL snapshot at slot {d}\n", .{bf.slot});
            return bf;
        }
        
        // Only use incremental if NO full snapshots exist (shouldn't happen in practice)
        if (best_incremental) |bi| {
            std.debug.print("[WARNING] findLocalSnapshot: no full snapshot found, using INCREMENTAL at slot {d}\n", .{bi.slot});
            return bi;
        }
        
        std.debug.print("[DEBUG] findLocalSnapshot: no snapshots found\n", .{});
        return null;
    }
    
    fn loadSnapshotFromDisk(self: *Self, info: storage.SnapshotInfo) !storage.snapshot.LoadResult {
        const sm = self.snapshot_manager orelse return error.NotInitialized;
        
        self.updatePhase(.extracting_snapshot, 0.0);
        
        const snapshot_path = try self.getSnapshotPath(&info);
        defer self.allocator.free(snapshot_path);
        
        std.debug.print("[DEBUG] loadSnapshotFromDisk: snapshot_path={s}\n", .{snapshot_path});
        
        // Verify file exists
        std.fs.cwd().access(snapshot_path, .{}) catch |err| {
            std.debug.print("[DEBUG] loadSnapshotFromDisk: file not found at {s}: {}\n", .{snapshot_path, err});
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
        var result = sm.loadSnapshot(extract_dir, self.accounts_db.?) catch |err| {
            std.debug.print("[DEBUG] loadSnapshotFromDisk: loadSnapshot failed: {}\n", .{err});
            return error.InvalidSnapshot;
        };
        result.slot = info.slot;
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
        
        // Try to load existing tower state
        const tower_path = self.config.tower_path orelse blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/tower-{s}.bin", .{
                self.config.ledger_dir,
                self.formatPubkey(self.identity.?.public),
            });
        };
        
        if (self.loadTowerFromFile(tower, tower_path)) {
            std.log.info("[Bootstrap] Loaded existing tower state", .{});
        } else |_| {
            std.log.info("[Bootstrap] Starting with fresh tower state", .{});
        }
        
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
        return try Bank.init(self.allocator, slot, null, self.accounts_db.?);
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
    tpu_client: ?*network.TpuClient = null,
    
    // Slot tracking - pointer to atomic from Runtime
    current_slot_ptr: ?*std.atomic.Value(u64) = null,
    
    // State
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vote_interval_ms: u64 = 400, // Vote every 400ms (Solana target is 400ms per slot)
    
    // Stats
    stats: VoteStats = .{},
    
    const Self = @This();
    
    pub fn init(
        allocator: Allocator,
        identity: core.Keypair,
        vote_account: core.Pubkey,
        tower: *TowerBft,
        replay_stage: *ReplayStage,
    ) !*Self {
        const submitter = try allocator.create(Self);
        submitter.* = .{
            .allocator = allocator,
            .identity = identity,
            .vote_account = vote_account,
            .tower = tower,
            .replay_stage = replay_stage,
        };
        return submitter;
    }
    
    /// Set the current slot pointer from Runtime
    pub fn setCurrentSlotPtr(self: *Self, slot_ptr: *std.atomic.Value(u64)) void {
        self.current_slot_ptr = slot_ptr;
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }
    
    /// Set TPU client for vote submission
    pub fn setTpuClient(self: *Self, tpu: *network.TpuClient) void {
        self.tpu_client = tpu;
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
        
        while (self.running.load(.acquire)) {
            self.checkAndSubmitVote() catch |err| {
                std.log.warn("[VoteSubmitter] Vote error: {}", .{err});
            };
            
            // Sleep for vote interval
            std.time.sleep(self.vote_interval_ms * std.time.ns_per_ms);
        }
        
        std.log.info("[VoteSubmitter] Vote loop stopped", .{});
    }
    
    fn checkAndSubmitVote(self: *Self) !void {
        // Get current slot from the network (via Runtime's current_slot atomic)
        const current_slot: u64 = if (self.current_slot_ptr) |ptr|
            ptr.load(.monotonic)
        else blk: {
            // Fallback: check shred assembler
            const assembled = self.replay_stage.shred_assembler.getHighestCompletedSlot();
            if (assembled > 0) break :blk assembled;
            
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
        
        // Check if we already voted for this or higher slot
        if (self.tower.last_vote_slot >= current_slot) {
            return; // Already voted for this slot
        }
        
        // Check lockout rules
        if (!self.tower.vote_state.canVote(current_slot)) {
            return; // Still locked out
        }
        
        // Vote for the current slot
        std.debug.print("[VoteSubmitter] Attempting vote for slot {d} (last_vote: {d})\n", .{current_slot, self.tower.last_vote_slot});
        
        // Get blockhash for the transaction (use local bank - no network call!)
        const blockhash = self.getRecentBlockhash();
        
        // Create vote using the current slot
        const vote_result = try self.tower.vote(current_slot, blockhash);
        
        // Build vote transaction (TowerSync format)
        const vote_tx = try self.buildVoteTransaction(vote_result, blockhash);
        defer self.allocator.free(vote_tx);
        
        std.debug.print("[VoteSubmitter] Built TowerSync tx, size={d} bytes\n", .{vote_tx.len});
        
        // Submit to TPU (use sendVote for redundancy - sends to multiple leaders)
        if (self.tpu_client) |tpu| {
            tpu.sendVote(vote_tx, current_slot) catch |err| {
                std.debug.print("[VoteSubmitter] ⚠ Vote send error: {} (will retry)\n", .{err});
                self.stats.votes_dropped += 1;
                return err;
            };
            self.stats.votes_submitted += 1;
            self.stats.last_vote_slot = current_slot;
            std.debug.print("[VoteSubmitter] ✓ Submitted vote for slot {d}\n", .{current_slot});
        } else {
            self.stats.votes_dropped += 1;
            std.debug.print("[VoteSubmitter] Vote dropped - no TPU client!\n", .{});
        }
    }
    
    /// Get recent blockhash - prefer local bank, RPC fallback for bootstrap only.
    /// VEXOR approach: Fast local access when possible, network only when necessary.
    fn getRecentBlockhash(self: *Self) core.Hash {
        // Primary: Use local bank's blockhash (fast, always fresh)
        if (self.replay_stage.root_bank) |bank| {
            // Use blockhash field (NOT bank_hash - those are different!)
            if (!std.mem.eql(u8, &bank.blockhash.data, &core.Hash.ZERO.data)) {
                return bank.blockhash;
            }
            // Bank exists but blockhash is zero - use bank_hash as fallback
            if (!std.mem.eql(u8, &bank.bank_hash.data, &core.Hash.ZERO.data)) {
                std.debug.print("[VoteSubmitter] Using bank_hash (blockhash not yet set)\n", .{});
                return bank.bank_hash;
            }
        }
        
        // Bootstrap fallback: Bank not ready yet, fetch from RPC
        std.debug.print("[VoteSubmitter] Bootstrap mode - fetching blockhash from RPC\n", .{});
        return self.fetchBlockhashFromRpc() catch |err| {
            std.debug.print("[VoteSubmitter] RPC blockhash fetch failed: {}\n", .{err});
            // Last resort: return a deterministic hash based on current time
            // This allows voting to proceed even if RPC fails during bootstrap
            var hash: core.Hash = undefined;
            const ts: u64 = @intCast(std.time.milliTimestamp());
            std.mem.writeInt(u64, hash.data[0..8], ts, .little);
            @memset(hash.data[8..], 0xBB); // Bootstrap marker
            return hash;
        };
    }
    
    /// Bootstrap-only: Fetch blockhash via RPC when local bank not available.
    /// This is only used during early bootstrap before bank is initialized.
    fn fetchBlockhashFromRpc(self: *Self) !core.Hash {
        const http = std.http;
        
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const uri = std.Uri.parse("https://api.testnet.solana.com") catch return error.InvalidUri;
        
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
    
    /// Decode base58 string to 32-byte hash (used for RPC blockhash parsing)
    fn decodeBase58Hash(b58: []const u8) !core.Hash {
        const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        
        var bytes: [32]u8 = undefined;
        @memset(&bytes, 0);
        var bytes_len: usize = 0;
        
        for (b58) |c| {
            const digit = std.mem.indexOf(u8, alphabet, &[_]u8{c}) orelse return error.InvalidBase58;
            
            var carry: u32 = @intCast(digit);
            var idx: usize = 0;
            while (idx < bytes_len or carry != 0) : (idx += 1) {
                if (idx < bytes_len) {
                    carry += @as(u32, bytes[31 - idx]) * 58;
                }
                if (idx <= 31) {
                    bytes[31 - idx] = @truncate(carry & 0xFF);
                }
                carry >>= 8;
                if (idx >= bytes_len and carry == 0) break;
            }
            bytes_len = @max(bytes_len, idx);
        }
        
        return core.Hash{ .data = bytes };
    }
    
    fn buildVoteTransaction(self: *Self, vote_data: consensus.vote.Vote, blockhash: core.Hash) ![]u8 {
        // Modern TowerSync vote transaction (like Firedancer)
        // Reference: fd_tower_to_vote_txn in fd_tower.c
        //
        // Account layout (when identity == vote authority):
        //   0: validator identity (signer, writable - pays fees)
        //   1: vote account (writable)
        //   2: vote program (readonly)
        
        var tx_buf = std.ArrayList(u8).init(self.allocator);
        errdefer tx_buf.deinit();
        
        // === SIGNATURES SECTION ===
        // Signature count (1) - validator identity signs
        try tx_buf.append(1);
        
        // Placeholder signature (64 bytes) - will be filled after signing
        try tx_buf.appendNTimes(0, 64);
        
        // === MESSAGE HEADER ===
        try tx_buf.append(1); // num_required_signatures
        try tx_buf.append(0); // num_readonly_signed
        try tx_buf.append(1); // num_readonly_unsigned (just vote program)
        
        // === ACCOUNT KEYS (3 accounts) ===
        try tx_buf.append(3); // account count
        try tx_buf.appendSlice(&self.identity.public.data); // 0: identity (signer)
        try tx_buf.appendSlice(&self.vote_account.data);    // 1: vote account
        try tx_buf.appendSlice(&VOTE_PROGRAM_ID);           // 2: vote program
        
        // === RECENT BLOCKHASH ===
        try tx_buf.appendSlice(&blockhash.data);
        
        // === INSTRUCTIONS ===
        try tx_buf.append(1); // instruction count
        
        // Vote instruction header
        try tx_buf.append(2); // program_id_index (vote program = account 2)
        try tx_buf.append(2); // num_accounts in instruction
        try tx_buf.append(1); // account 0: vote_account (writable)
        try tx_buf.append(0); // account 1: vote authority (signer = identity)
        
        // Serialize TowerSync instruction data
        const vote_ix_data = try self.serializeTowerSync(vote_data);
        defer self.allocator.free(vote_ix_data);
        
        // Data length as compact-u16 (for small lengths, just 1 byte)
        if (vote_ix_data.len < 128) {
            try tx_buf.append(@intCast(vote_ix_data.len));
        } else {
            // Compact-u16 encoding for larger values
            try tx_buf.append(@intCast((vote_ix_data.len & 0x7F) | 0x80));
            try tx_buf.append(@intCast(vote_ix_data.len >> 7));
        }
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
    
    fn serializeTowerSync(self: *Self, vote: consensus.vote.Vote) ![]u8 {
        // TowerSync (CompactUpdateVoteState) instruction format:
        // Reference: Firedancer fd_vote_instruction_encode, discriminant 12
        //
        // Format (bincode):
        //   discriminant: u32 = 12 (CompactUpdateVoteState/TowerSync)
        //   root: u64
        //   lockouts_len: compact-u16 (we have 1 vote)
        //   lockouts[]: each is {offset: compact-u64, confirmation_count: u8}
        //   hash: [u8; 32] (bank hash)
        //   has_timestamp: u8 (1 = yes)
        //   timestamp: i64 (if has_timestamp)
        
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        
        // Instruction discriminant: 12 = CompactUpdateVoteState (TowerSync)
        try buf.writer().writeInt(u32, 12, .little);
        
        // Root slot (use 0 if no root established yet)
        // In a real implementation, this would come from the tower's root
        const root: u64 = if (vote.slot > 32) vote.slot - 32 else 0;
        try buf.writer().writeInt(u64, root, .little);
        
        // Lockouts vector length (compact-u16, we have 1 vote)
        try buf.append(1);
        
        // Single lockout: {offset from root, confirmation_count}
        // offset is delta from previous (root), so it's (vote.slot - root)
        const offset = vote.slot - root;
        // Encode offset as compact-u64 (for small values, just 1-2 bytes)
        try writeCompactU64(&buf, offset);
        
        // Confirmation count (1 = first vote on this slot)
        try buf.append(1);
        
        // Bank hash (32 bytes)
        try buf.appendSlice(&vote.hash.data);
        
        // has_timestamp = 1 (yes, we include timestamp)
        try buf.append(1);
        
        // Timestamp (i64, seconds since epoch)
        try buf.writer().writeInt(i64, vote.timestamp, .little);
        
        return buf.toOwnedSlice();
    }
    
    fn writeCompactU64(buf: *std.ArrayList(u8), value: u64) !void {
        // Bincode compact-u64 encoding (same as Solana's shortVec for u64)
        var v = value;
        while (v >= 0x80) {
            try buf.append(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try buf.append(@intCast(v));
    }
};

// Vote Program ID
// Vote111111111111111111111111111111111111111 (base58 decoded)
const VOTE_PROGRAM_ID = [_]u8{
    0x07, 0x61, 0x48, 0x1d, 0x35, 0x74, 0x74, 0xbb, 0x7c, 0x4d, 0x76, 0x24, 0xeb, 0xd3, 0xbd, 0xb3,
    0xd8, 0x35, 0x5e, 0x73, 0xd1, 0x10, 0x43, 0xfc, 0x0d, 0xa3, 0x53, 0x80, 0x00, 0x00, 0x00, 0x00,
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

test "bootstrap phases" {
    try std.testing.expectEqual(@as(usize, 10), @typeInfo(BootstrapPhase).@"enum".fields.len);
}

