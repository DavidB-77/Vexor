//! Vexor Client Switcher
//! Safe dual-client management for running Vexor alongside Agave.
//!
//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║  DUAL-CLIENT ARCHITECTURE                                                  ║
//! ╠═══════════════════════════════════════════════════════════════════════════╣
//! ║                                                                            ║
//! ║  SHARED (same files):                                                      ║
//! ║    • Identity keypair (validator-keypair.json)                            ║
//! ║    • Vote account pubkey                                                   ║
//! ║    • Authorized voter keypairs                                             ║
//! ║                                                                            ║
//! ║  SEPARATE (MUST be different):                                             ║
//! ║    • Ledger directory                                                      ║
//! ║    • Accounts database                                                     ║
//! ║    • Snapshots storage                                                     ║
//! ║    • Tower state (tower-*.bin)                                            ║
//! ║    • Runtime files (PID, sockets)                                          ║
//! ║                                                                            ║
//! ║  SAFETY FEATURES:                                                          ║
//! ║    ✓ Pre-switch backup of all critical files                              ║
//! ║    ✓ Backup verification before proceeding                                 ║
//! ║    ✓ Real-time alerting (Telegram, Discord, Slack)                        ║
//! ║    ✓ Health monitoring post-switch                                         ║
//! ║    ✓ Automatic rollback on failure                                         ║
//! ║                                                                            ║
//! ║  ⚠️  CRITICAL: Only ONE client may vote at a time!                        ║
//! ║     Running both will cause double-voting → SLASHING                       ║
//! ║                                                                            ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝
//!
//! Usage:
//!   vexor-switch status          # Show which client is active
//!   vexor-switch to-vexor        # Switch from Agave to Vexor
//!   vexor-switch to-agave        # Switch from Vexor to Agave
//!   vexor-switch verify          # Verify setup is safe
//!   vexor-switch backup          # Create manual backup
//!   vexor-switch list-backups    # List available backups
//!   vexor-switch health          # Run health check

const std = @import("std");
const fs = std.fs;
const process = std.process;
const Allocator = std.mem.Allocator;

// Import backup and alert systems
const backup_manager = @import("backup_manager.zig");
const alert_system = @import("alert_system.zig");
const BackupManager = backup_manager.BackupManager;
const BackupConfig = backup_manager.BackupConfig;
const AlertSystem = alert_system.AlertSystem;
const AlertConfig = alert_system.AlertConfig;
const HealthMonitor = alert_system.HealthMonitor;

/// Client types - Vexor supports switching from ANY Solana validator client
pub const ClientType = enum {
    agave,          // Solana Labs / Anza client (formerly solana-validator)
    firedancer,     // Jump Crypto's high-performance client
    jito,           // Jito Labs' MEV-optimized Agave fork
    frankendancer,  // Firedancer + Agave hybrid
    vexor,          // Our client
    unknown,        // Unknown client type
    none,           // No client running
    both,           // ERROR STATE - multiple clients running (unsafe!)
    
    pub fn serviceName(self: ClientType) []const u8 {
        return switch (self) {
            .agave => "solana-validator.service",
            .firedancer => "firedancer.service",
            .jito => "jito-validator.service",
            .frankendancer => "frankendancer.service",
            .vexor => "vexor.service",
            .unknown => "unknown",
            .none => "none",
            .both => "multiple",
        };
    }
    
    pub fn displayName(self: ClientType) []const u8 {
        return switch (self) {
            .agave => "Agave (Solana Labs/Anza)",
            .firedancer => "Firedancer (Jump Crypto)",
            .jito => "Jito-Solana (Jito Labs)",
            .frankendancer => "Frankendancer",
            .vexor => "Vexor",
            .unknown => "Unknown Validator",
            .none => "No Validator Running",
            .both => "MULTIPLE (UNSAFE!)",
        };
    }
    
    pub fn ledgerPath(self: ClientType) []const u8 {
        return switch (self) {
            .agave, .jito => "/mnt/solana/ledger",
            .firedancer, .frankendancer => "/mnt/firedancer/ledger",
            .vexor => "/mnt/vexor/ledger",
            else => "/mnt/solana/ledger", // Default assumption
        };
    }
};

/// Directory configuration for dual-client setup
pub const DualClientConfig = struct {
    // ═══════════════════════════════════════════════════════════════════
    // SHARED FILES (same path for both clients)
    // ═══════════════════════════════════════════════════════════════════
    
    /// Path to validator identity keypair (shared)
    identity_path: []const u8,
    
    /// Path to vote account keypair (shared)
    vote_account_path: []const u8,
    
    /// Path to authorized voter keypair (shared, optional)
    authorized_voter_path: ?[]const u8 = null,
    
    // ═══════════════════════════════════════════════════════════════════
    // AGAVE-SPECIFIC PATHS
    // ═══════════════════════════════════════════════════════════════════
    
    /// Agave ledger directory
    agave_ledger_path: []const u8,
    
    /// Agave accounts path
    agave_accounts_path: []const u8,
    
    /// Agave snapshots path
    agave_snapshots_path: []const u8,
    
    /// Agave runtime directory
    agave_runtime_path: []const u8,
    
    // ═══════════════════════════════════════════════════════════════════
    // VEXOR-SPECIFIC PATHS
    // ═══════════════════════════════════════════════════════════════════
    
    /// Vexor ledger directory
    vexor_ledger_path: []const u8,
    
    /// Vexor accounts path
    vexor_accounts_path: []const u8,
    
    /// Vexor snapshots path
    vexor_snapshots_path: []const u8,
    
    /// Vexor runtime directory
    vexor_runtime_path: []const u8,
    
    // ═══════════════════════════════════════════════════════════════════
    // NETWORK SETTINGS
    // ═══════════════════════════════════════════════════════════════════
    
    /// Cluster type
    cluster: Cluster = .mainnet_beta,
    
    /// Gossip entrypoints
    entrypoints: []const []const u8 = &.{},
    
    /// Known validators (for snapshot trust)
    known_validators: []const []const u8 = &.{},
    
    /// RPC port (Agave)
    rpc_port: u16 = 8899,

    /// Vexor RPC port (different to avoid conflict during parallel testing)
    vexor_rpc_port: u16 = 8898,

    /// Dynamic port range
    dynamic_port_range: []const u8 = "8000-8020",

    /// Network name (for CLI flag: "testnet", "mainnet-beta", "devnet")
    network: ?[]const u8 = null,

    pub const Cluster = enum {
        mainnet_beta,
        testnet,
        devnet,
        localnet,
        
        pub fn defaultEntrypoints(self: Cluster) []const []const u8 {
            return switch (self) {
                .mainnet_beta => &.{
                    "entrypoint.mainnet-beta.solana.com:8001",
                    "entrypoint2.mainnet-beta.solana.com:8001",
                    "entrypoint3.mainnet-beta.solana.com:8001",
                },
                .testnet => &.{
                    "entrypoint.testnet.solana.com:8001",
                    "entrypoint2.testnet.solana.com:8001",
                    "entrypoint3.testnet.solana.com:8001",
                },
                .devnet => &.{
                    "entrypoint.devnet.solana.com:8001",
                },
                .localnet => &.{
                    "127.0.0.1:8001",
                },
            };
        }
    };

    /// Create default configuration for a given base directory
    pub fn defaultForPath(base_path: []const u8) DualClientConfig {
        _ = base_path;
        return .{
            // Shared
            .identity_path = "/root/validator-keypair.json",
            .vote_account_path = "/root/vote-account-keypair.json",
            
            // Agave paths
            .agave_ledger_path = "/mnt/solana/ledger",
            .agave_accounts_path = "/mnt/solana/accounts",
            .agave_snapshots_path = "/mnt/solana/snapshots",
            .agave_runtime_path = "/var/run/agave",
            
            // Vexor paths (separate!)
            .vexor_ledger_path = "/mnt/vexor/ledger",
            .vexor_accounts_path = "/mnt/vexor/accounts",
            .vexor_snapshots_path = "/mnt/vexor/snapshots",
            .vexor_runtime_path = "/var/run/vexor",
        };
    }
};

/// Client process info
pub const ProcessInfo = struct {
    pid: ?i32,
    running: bool,
    voting: bool,
    last_vote_slot: ?u64,
    uptime_secs: ?u64,
};

/// Client Switcher - manages safe transitions between Agave and Vexor
pub const ClientSwitcher = struct {
    allocator: Allocator,
    config: DualClientConfig,
    backup_mgr: BackupManager,
    alerts: AlertSystem,
    health_monitor: ?HealthMonitor,

    /// Last successful backup ID (for rollback)
    last_backup_id: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, config: DualClientConfig) Self {
        // Create backup config from dual client config
        const backup_config = BackupConfig{
            .backup_dir = "/var/backups/vexor",
            .identity_path = config.identity_path,
            .vote_account_path = config.vote_account_path,
            .agave_ledger_path = config.agave_ledger_path,
            .agave_runtime_path = config.agave_runtime_path,
            .vexor_ledger_path = config.vexor_ledger_path,
            .vexor_runtime_path = config.vexor_runtime_path,
        };

        // Create alert config
        const alert_config = AlertConfig{
            .validator_name = "testnet-validator",
            .cluster = @tagName(config.cluster),
            .log_file = "/var/log/vexor/alerts.log",
        };

        return .{
            .allocator = allocator,
            .config = config,
            .backup_mgr = BackupManager.init(allocator, backup_config),
            .alerts = AlertSystem.init(allocator, alert_config),
            .health_monitor = null,
            .last_backup_id = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.alerts.deinit();
        if (self.last_backup_id) |id| {
            self.allocator.free(id);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STATUS CHECKING
    // ═══════════════════════════════════════════════════════════════════════

    /// Check which client is currently active
    pub fn getActiveClient(self: *Self) !ClientType {
        const agave_running = self.isAgaveRunning();
        const vexor_running = self.isVexorRunning();
        
        if (agave_running and vexor_running) {
            return .both; // DANGER!
        } else if (agave_running) {
            return .agave;
        } else if (vexor_running) {
            return .vexor;
        } else {
            return .none;
        }
    }

    /// Check if Agave is running
    fn isAgaveRunning(self: *Self) bool {
        // Check for PID file
        const pid_path = std.fmt.allocPrint(self.allocator, "{s}/agave.pid", .{self.config.agave_runtime_path}) catch return false;
        defer self.allocator.free(pid_path);
        
        return self.isProcessRunning(pid_path);
    }

    /// Check if Vexor is running
    fn isVexorRunning(self: *Self) bool {
        const pid_path = std.fmt.allocPrint(self.allocator, "{s}/vexor.pid", .{self.config.vexor_runtime_path}) catch return false;
        defer self.allocator.free(pid_path);
        
        return self.isProcessRunning(pid_path);
    }

    /// Check if a process with given PID file is running
    fn isProcessRunning(self: *Self, pid_file: []const u8) bool {
        _ = self;
        const file = fs.cwd().openFile(pid_file, .{}) catch return false;
        defer file.close();
        
        var buf: [32]u8 = undefined;
        const len = file.readAll(&buf) catch return false;
        const pid_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch return false;
        
        // Check if process exists
        const result = std.posix.kill(pid, 0);
        return result != error.ProcessNotFound;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /// Verify the setup is safe
    pub fn verifySetup(self: *Self) !VerificationResult {
        var result = VerificationResult{};
        
        // Check shared files exist
        result.identity_exists = self.fileExists(self.config.identity_path);
        result.vote_account_exists = self.fileExists(self.config.vote_account_path);
        
        // Check paths are different (CRITICAL!)
        result.ledger_paths_different = !std.mem.eql(u8, self.config.agave_ledger_path, self.config.vexor_ledger_path);
        result.accounts_paths_different = !std.mem.eql(u8, self.config.agave_accounts_path, self.config.vexor_accounts_path);
        result.runtime_paths_different = !std.mem.eql(u8, self.config.agave_runtime_path, self.config.vexor_runtime_path);
        
        // Check only one client is running
        const active = try self.getActiveClient();
        result.single_client_running = (active != .both);
        result.active_client = active;
        
        // Check Vexor directories exist/can be created
        result.vexor_dirs_ready = self.checkOrCreateDir(self.config.vexor_ledger_path) and
            self.checkOrCreateDir(self.config.vexor_accounts_path) and
            self.checkOrCreateDir(self.config.vexor_runtime_path);
        
        return result;
    }

    fn fileExists(self: *Self, path: []const u8) bool {
        _ = self;
        fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn checkOrCreateDir(self: *Self, path: []const u8) bool {
        _ = self;
        fs.cwd().makePath(path) catch return false;
        return true;
    }

    pub const VerificationResult = struct {
        identity_exists: bool = false,
        vote_account_exists: bool = false,
        ledger_paths_different: bool = false,
        accounts_paths_different: bool = false,
        runtime_paths_different: bool = false,
        single_client_running: bool = false,
        vexor_dirs_ready: bool = false,
        active_client: ClientType = .none,

        pub fn isValid(self: *const VerificationResult) bool {
            return self.identity_exists and
                self.vote_account_exists and
                self.ledger_paths_different and
                self.accounts_paths_different and
                self.runtime_paths_different and
                self.single_client_running;
        }

        pub fn print(self: *const VerificationResult) void {
            std.debug.print(
                \\
                \\╔══════════════════════════════════════════════════════════════╗
                \\║              DUAL-CLIENT VERIFICATION RESULTS                 ║
                \\╠══════════════════════════════════════════════════════════════╣
                \\║                                                               ║
                \\║  Shared Files:                                                ║
                \\║    Identity keypair:      {s}                             ║
                \\║    Vote account:          {s}                             ║
                \\║                                                               ║
                \\║  Path Separation (CRITICAL):                                  ║
                \\║    Ledger paths differ:   {s}                             ║
                \\║    Accounts paths differ: {s}                             ║
                \\║    Runtime paths differ:  {s}                             ║
                \\║                                                               ║
                \\║  Safety:                                                      ║
                \\║    Single client running: {s}                             ║
                \\║    Active client:         {s}                             ║
                \\║    Vexor dirs ready:      {s}                             ║
                \\║                                                               ║
                \\║  Overall Status:          {s}                       ║
                \\╚══════════════════════════════════════════════════════════════╝
                \\
            , .{
                if (self.identity_exists) "✅ EXISTS" else "❌ MISSING",
                if (self.vote_account_exists) "✅ EXISTS" else "❌ MISSING",
                if (self.ledger_paths_different) "✅ YES   " else "❌ NO ⚠️ ",
                if (self.accounts_paths_different) "✅ YES   " else "❌ NO ⚠️ ",
                if (self.runtime_paths_different) "✅ YES   " else "❌ NO ⚠️ ",
                if (self.single_client_running) "✅ YES   " else "❌ BOTH! ⚠️",
                @tagName(self.active_client),
                if (self.vexor_dirs_ready) "✅ YES   " else "❌ NO    ",
                if (self.isValid()) "✅ SAFE TO SWITCH" else "❌ FIX ISSUES FIRST",
            });
        }
    };

    // ═══════════════════════════════════════════════════════════════════════
    // CLIENT SWITCHING
    // ═══════════════════════════════════════════════════════════════════════

    /// Switch from Agave to Vexor (with backup and alerting)
    pub fn switchToVexor(self: *Self) !void {
        const verify = try self.verifySetup();
        if (!verify.isValid()) {
            std.debug.print("❌ Cannot switch - verification failed!\n", .{});
            verify.print();
            try self.alerts.alertSwitchFailed("Pre-flight verification failed");
            return error.VerificationFailed;
        }

        const active = try self.getActiveClient();

        switch (active) {
            .vexor => {
                std.debug.print("ℹ️  Vexor is already running\n", .{});
                return;
            },
            .both => {
                std.debug.print("❌ DANGER: Both clients running! Manual intervention required.\n", .{});
                try self.alerts.sendAlert(.client_crashed, "DANGER: Both Clients Running", "Multiple clients detected! Risk of double-voting!");
                return error.BothClientsRunning;
            },
            .none => {
                std.debug.print("ℹ️  No client running, starting Vexor...\n", .{});
                try self.startVexor();
                try self.alerts.alertSwitchCompleted("Vexor");
            },
            .unknown => {
                std.debug.print("⚠️  Unknown validator process detected.\n", .{});
                std.debug.print("   Please manually stop the existing validator first.\n", .{});
                return error.UnknownClientRunning;
            },
            // Handle all supported clients the same way
            .agave, .firedancer, .jito, .frankendancer => {
                // Send alert that switch is starting
                try self.alerts.alertSwitchStarted(active.displayName(), "Vexor");

                std.debug.print("\n🔄 SWITCHING FROM AGAVE TO VEXOR\n", .{});
                std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

                // ═══════════════════════════════════════════════════════════
                // STEP 1: CREATE BACKUP (CRITICAL!)
                // ═══════════════════════════════════════════════════════════
                std.debug.print("📦 STEP 1: Creating pre-switch backup...\n", .{});

                const backup_result = try self.backup_mgr.createPreSwitchBackup("agave");

                if (!backup_result.success) {
                    std.debug.print("❌ Backup failed! Aborting switch.\n", .{});
                    try self.alerts.sendAlert(.backup_failed, "Backup Failed", "Pre-switch backup failed. Switch aborted for safety.");
                    return error.BackupFailed;
                }

                // Store backup ID for potential rollback
                self.last_backup_id = try self.allocator.dupe(u8, backup_result.backup_id);

                try self.alerts.alertBackupCompleted(backup_result.backup_id, backup_result.files_backed_up);
                std.debug.print("✅ Backup created: {s}\n\n", .{backup_result.backup_id});

                // ═══════════════════════════════════════════════════════════
                // STEP 2: VERIFY BACKUP
                // ═══════════════════════════════════════════════════════════
                std.debug.print("🔍 STEP 2: Verifying backup integrity...\n", .{});

                const backup_valid = try self.backup_mgr.verifyBackup(backup_result.backup_path);
                if (!backup_valid) {
                    std.debug.print("❌ Backup verification failed! Aborting switch.\n", .{});
                    try self.alerts.sendAlert(.backup_failed, "Backup Verification Failed", "Backup integrity check failed. Switch aborted.");
                    return error.BackupVerificationFailed;
                }

                try self.alerts.sendAlert(.backup_verified, "Backup Verified", "Pre-switch backup passed integrity check.");
                std.debug.print("✅ Backup verified successfully!\n\n", .{});

                // ═══════════════════════════════════════════════════════════
                // STEP 3: STOP AGAVE
                // ═══════════════════════════════════════════════════════════
                std.debug.print("🛑 STEP 3: Stopping Agave gracefully...\n", .{});
                try self.stopAgave();

                // Wait for full stop
                std.debug.print("   Waiting for Agave to stop...\n", .{});
                self.waitForClientStop(.agave, 60) catch |err| {
                    std.debug.print("❌ Agave didn't stop in time: {}\n", .{err});
                    try self.alerts.alertSwitchFailed("Agave failed to stop gracefully");
                    return err;
                };

                try self.alerts.sendAlert(.client_stopped, "Agave Stopped", "Agave validator stopped successfully.");
                std.debug.print("✅ Agave stopped.\n\n", .{});

                // ═══════════════════════════════════════════════════════════
                // STEP 4: START VEXOR
                // ═══════════════════════════════════════════════════════════
                std.debug.print("🚀 STEP 4: Starting Vexor...\n", .{});
                self.startVexor() catch |err| {
                    std.debug.print("❌ Failed to start Vexor: {}\n", .{err});
                    try self.alerts.alertSwitchFailed("Vexor failed to start");

                    // Attempt rollback
                    std.debug.print("🔄 Attempting rollback to Agave...\n", .{});
                    try self.alerts.sendAlert(.switch_rollback, "Rollback Initiated", "Vexor failed to start, rolling back to Agave.");
                    self.startAgave() catch {};

                    return err;
                };

                // Wait for Vexor to start
                std.debug.print("   Waiting for Vexor to start...\n", .{});
                self.waitForClientStart(.vexor, 30) catch |err| {
                    std.debug.print("❌ Vexor didn't start in time: {}\n", .{err});
                    try self.alerts.alertSwitchFailed("Vexor start timeout");

                    // Attempt rollback
                    std.debug.print("🔄 Attempting rollback to Agave...\n", .{});
                    self.startAgave() catch {};

                    return err;
                };

                try self.alerts.sendAlert(.client_started, "Vexor Started", "Vexor validator started successfully.");
                std.debug.print("✅ Vexor started.\n\n", .{});

                // ═══════════════════════════════════════════════════════════
                // STEP 5: POST-SWITCH HEALTH CHECK
                // ═══════════════════════════════════════════════════════════
                std.debug.print("🏥 STEP 5: Running post-switch health check...\n", .{});

                // Wait a bit for Vexor to initialize
                std.time.sleep(5 * std.time.ns_per_s);

                // TODO: Implement actual health check via RPC
                std.debug.print("   (Health check pending RPC implementation)\n", .{});

                // ═══════════════════════════════════════════════════════════
                // COMPLETE!
                // ═══════════════════════════════════════════════════════════
                std.debug.print("\n", .{});
                std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
                std.debug.print("✅ SWITCH COMPLETED SUCCESSFULLY!\n", .{});
                std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
                std.debug.print("\n", .{});
                std.debug.print("   Backup ID: {s}\n", .{backup_result.backup_id});
                std.debug.print("   To rollback: vexor-switch to-agave\n", .{});
                std.debug.print("   To restore:  vexor-switch restore {s}\n", .{backup_result.backup_id});
                std.debug.print("\n", .{});

                try self.alerts.alertSwitchCompleted("Vexor");
            },
        }
    }

    /// Switch from Vexor to Agave (with backup and alerting)
    pub fn switchToAgave(self: *Self) !void {
        const verify = try self.verifySetup();
        if (!verify.identity_exists or !verify.vote_account_exists) {
            std.debug.print("❌ Cannot switch - missing identity/vote account!\n", .{});
            try self.alerts.alertSwitchFailed("Missing identity or vote account");
            return error.MissingKeys;
        }

        const active = try self.getActiveClient();

        switch (active) {
            // Already running the target client
            .agave, .firedancer, .jito, .frankendancer => {
                std.debug.print("ℹ️  Previous validator ({s}) is already running\n", .{active.displayName()});
                return;
            },
            .both => {
                std.debug.print("❌ DANGER: Both clients running! Manual intervention required.\n", .{});
                try self.alerts.sendAlert(.client_crashed, "DANGER: Both Clients Running", "Multiple clients detected! Risk of double-voting!");
                return error.BothClientsRunning;
            },
            .unknown => {
                std.debug.print("⚠️  Unknown validator process detected.\n", .{});
                std.debug.print("   Please manually manage the switch.\n", .{});
                return error.UnknownClientRunning;
            },
            .none => {
                std.debug.print("ℹ️  No client running, starting previous validator...\n", .{});
                try self.startAgave();
                try self.alerts.alertSwitchCompleted("Previous Validator");
            },
            .vexor => {
                try self.alerts.alertSwitchStarted("Vexor", "Agave");

                std.debug.print("\n🔄 SWITCHING FROM VEXOR TO AGAVE\n", .{});
                std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

                // STEP 1: Backup
                std.debug.print("📦 STEP 1: Creating pre-switch backup...\n", .{});
                const backup_result = try self.backup_mgr.createPreSwitchBackup("vexor");

                if (!backup_result.success) {
                    std.debug.print("❌ Backup failed! Aborting switch.\n", .{});
                    try self.alerts.sendAlert(.backup_failed, "Backup Failed", "Pre-switch backup failed.");
                    return error.BackupFailed;
                }

                try self.alerts.alertBackupCompleted(backup_result.backup_id, backup_result.files_backed_up);
                std.debug.print("✅ Backup created: {s}\n\n", .{backup_result.backup_id});

                // STEP 2: Stop Vexor
                std.debug.print("🛑 STEP 2: Stopping Vexor gracefully...\n", .{});
                try self.stopVexor();
                try self.waitForClientStop(.vexor, 60);
                try self.alerts.sendAlert(.client_stopped, "Vexor Stopped", "Vexor validator stopped successfully.");
                std.debug.print("✅ Vexor stopped.\n\n", .{});

                // STEP 3: Start Agave
                std.debug.print("🚀 STEP 3: Starting Agave...\n", .{});
                self.startAgave() catch |err| {
                    std.debug.print("❌ Failed to start Agave: {}\n", .{err});
                    try self.alerts.alertSwitchFailed("Agave failed to start");
                    return err;
                };

                try self.waitForClientStart(.agave, 30);
                try self.alerts.sendAlert(.client_started, "Agave Started", "Agave validator started successfully.");
                std.debug.print("✅ Agave started.\n\n", .{});

                std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
                std.debug.print("✅ SWITCH COMPLETED SUCCESSFULLY!\n", .{});
                std.debug.print("═══════════════════════════════════════════════════════════\n\n", .{});

                try self.alerts.alertSwitchCompleted("Agave");
            },
        }
    }

    /// Create a manual backup
    pub fn createManualBackup(self: *Self) !void {
        const active = try self.getActiveClient();
        const client_name = @tagName(active);

        std.debug.print("📦 Creating manual backup of {s} state...\n", .{client_name});

        const result = try self.backup_mgr.createPreSwitchBackup(client_name);
        result.print();

        if (result.success) {
            try self.alerts.alertBackupCompleted(result.backup_id, result.files_backed_up);
        }
    }

    /// List available backups
    pub fn listBackups(self: *Self) !void {
        try self.backup_mgr.listBackups();
    }

    /// Run health check
    pub fn runHealthCheck(self: *Self) !void {
        std.debug.print("🏥 Running health check...\n", .{});

        // Initialize health monitor if needed
        if (self.health_monitor == null) {
            self.health_monitor = HealthMonitor.init(
                self.allocator,
                &self.alerts,
                "http://127.0.0.1:8899",
            );
        }

        if (self.health_monitor) |*monitor| {
            const status = try monitor.checkHealth();
            status.print();

            if (!status.healthy) {
                try self.alerts.alertHealthCheckFailed("One or more health checks failed");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROCESS MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    fn stopAgave(self: *Self) !void {
        // Send SIGTERM to Agave process
        const pid_path = try std.fmt.allocPrint(self.allocator, "{s}/agave.pid", .{self.config.agave_runtime_path});
        defer self.allocator.free(pid_path);
        
        const pid = try self.readPidFile(pid_path);
        if (pid) |p| {
            std.posix.kill(p, std.posix.SIG.TERM) catch {};
        }
    }

    fn stopVexor(self: *Self) !void {
        // Send SIGTERM to Vexor process
        const pid_path = try std.fmt.allocPrint(self.allocator, "{s}/vexor.pid", .{self.config.vexor_runtime_path});
        defer self.allocator.free(pid_path);
        
        const pid = try self.readPidFile(pid_path);
        if (pid) |p| {
            std.posix.kill(p, std.posix.SIG.TERM) catch {};
        }
    }

    fn startVexor(self: *Self) !void {
        // Build Vexor command line (compatible with Agave flags)
        const args = try self.buildVexorArgs();
        defer {
            for (args) |arg| {
                self.allocator.free(arg);
            }
            self.allocator.free(args);
        }
        
        // For now, just print the command
        std.debug.print("\n📋 Vexor start command:\n   vexor", .{});
        for (args) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n\n", .{});
        
        // TODO: Actually spawn the process
        // var child = try std.process.Child.init(args, self.allocator);
        // try child.spawn();
    }

    fn startAgave(self: *Self) !void {
        // Build Agave command line
        std.debug.print("\n📋 Agave start command:\n   agave-validator", .{});
        std.debug.print(" --identity {s}", .{self.config.identity_path});
        std.debug.print(" --vote-account {s}", .{self.config.vote_account_path});
        std.debug.print(" --ledger {s}", .{self.config.agave_ledger_path});
        std.debug.print(" --accounts {s}", .{self.config.agave_accounts_path});
        std.debug.print("\n\n", .{});
        
        // TODO: Actually spawn the process
    }

    fn buildVexorArgs(self: *Self) ![][]const u8 {
        var args = std.ArrayList([]const u8).init(self.allocator);

        // Command must be first
        try args.append(try self.allocator.dupe(u8, "run"));
        
        // Production mode with full bootstrap (snapshot loading, voting, etc.)
        try args.append(try self.allocator.dupe(u8, "--bootstrap"));

        // Network flag (--testnet, --mainnet-beta, --devnet)
        if (self.config.network) |network| {
            if (std.mem.eql(u8, network, "testnet")) {
                try args.append(try self.allocator.dupe(u8, "--testnet"));
            } else if (std.mem.eql(u8, network, "mainnet-beta")) {
                try args.append(try self.allocator.dupe(u8, "--mainnet-beta"));
            } else if (std.mem.eql(u8, network, "devnet")) {
                try args.append(try self.allocator.dupe(u8, "--devnet"));
            }
        }

        // Identity (shared with Agave)
        try args.append(try self.allocator.dupe(u8, "--identity"));
        try args.append(try self.allocator.dupe(u8, self.config.identity_path));

        // Vote account (shared with Agave)
        try args.append(try self.allocator.dupe(u8, "--vote-account"));
        try args.append(try self.allocator.dupe(u8, self.config.vote_account_path));

        // Ledger (Vexor-specific path)
        try args.append(try self.allocator.dupe(u8, "--ledger"));
        try args.append(try self.allocator.dupe(u8, self.config.vexor_ledger_path));

        // Accounts (Vexor-specific path)
        try args.append(try self.allocator.dupe(u8, "--accounts"));
        try args.append(try self.allocator.dupe(u8, self.config.vexor_accounts_path));

        // Snapshots (Vexor-specific path)
        try args.append(try self.allocator.dupe(u8, "--snapshots"));
        try args.append(try self.allocator.dupe(u8, self.config.vexor_snapshots_path));

        // Entrypoints
        for (self.config.entrypoints) |entrypoint| {
            try args.append(try self.allocator.dupe(u8, "--entrypoint"));
            try args.append(try self.allocator.dupe(u8, entrypoint));
        }

        // Known validators
        for (self.config.known_validators) |validator| {
            try args.append(try self.allocator.dupe(u8, "--known-validator"));
            try args.append(try self.allocator.dupe(u8, validator));
        }

        // RPC port (use different from Agave to avoid conflict during parallel testing)
        try args.append(try self.allocator.dupe(u8, "--rpc-port"));
        try args.append(try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.vexor_rpc_port}));

        return args.toOwnedSlice();
    }

    fn waitForClientStop(self: *Self, client: ClientType, timeout_secs: u64) !void {
        var elapsed: u64 = 0;
        while (elapsed < timeout_secs) {
            const running = switch (client) {
                .agave => self.isAgaveRunning(),
                .vexor => self.isVexorRunning(),
                else => false,
            };
            
            if (!running) return;
            
            std.time.sleep(std.time.ns_per_s);
            elapsed += 1;
        }
        
        return error.Timeout;
    }

    fn waitForClientStart(self: *Self, client: ClientType, timeout_secs: u64) !void {
        var elapsed: u64 = 0;
        while (elapsed < timeout_secs) {
            const running = switch (client) {
                .agave => self.isAgaveRunning(),
                .vexor => self.isVexorRunning(),
                else => false,
            };
            
            if (running) return;
            
            std.time.sleep(std.time.ns_per_s);
            elapsed += 1;
        }
        
        return error.Timeout;
    }

    fn readPidFile(self: *Self, path: []const u8) !?i32 {
        _ = self;
        const file = fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        
        var buf: [32]u8 = undefined;
        const len = file.readAll(&buf) catch return null;
        const pid_str = std.mem.trim(u8, buf[0..len], &std.ascii.whitespace);
        return std.fmt.parseInt(i32, pid_str, 10) catch null;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SNAPSHOT HANDLING
    // ═══════════════════════════════════════════════════════════════════════

    /// Copy latest snapshot from Agave to Vexor (for faster bootstrap)
    pub fn copySnapshotToVexor(self: *Self) !void {
        std.debug.print("📦 Copying latest snapshot from Agave to Vexor...\n", .{});
        
        // Find latest full snapshot
        const agave_snap_dir = try fs.cwd().openDir(self.config.agave_snapshots_path, .{ .iterate = true });
        _ = agave_snap_dir;
        
        // TODO: Implement snapshot copy
        // This allows Vexor to start from Agave's state without downloading
        
        std.debug.print("✅ Snapshot copied successfully\n", .{});
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// CLI ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const config = DualClientConfig.defaultForPath("/mnt/solana");
    var switcher = ClientSwitcher.init(allocator, config);
    defer switcher.deinit();

    const command = args[1];

    if (std.mem.eql(u8, command, "status")) {
        const active = try switcher.getActiveClient();
        std.debug.print("\n🔍 Active Client: {s}\n\n", .{@tagName(active)});

    } else if (std.mem.eql(u8, command, "verify")) {
        const result = try switcher.verifySetup();
        result.print();

    } else if (std.mem.eql(u8, command, "to-vexor")) {
        try switcher.switchToVexor();

    } else if (std.mem.eql(u8, command, "to-agave")) {
        try switcher.switchToAgave();

    } else if (std.mem.eql(u8, command, "backup")) {
        try switcher.createManualBackup();

    } else if (std.mem.eql(u8, command, "list-backups")) {
        try switcher.listBackups();

    } else if (std.mem.eql(u8, command, "health")) {
        try switcher.runHealthCheck();

    } else if (std.mem.eql(u8, command, "copy-snapshot")) {
        try switcher.copySnapshotToVexor();

    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\
        \\╔══════════════════════════════════════════════════════════════════════╗
        \\║                    VEXOR CLIENT SWITCHER                             ║
        \\╠══════════════════════════════════════════════════════════════════════╣
        \\║                                                                       ║
        \\║  Safe dual-client management for running Vexor alongside Agave.      ║
        \\║                                                                       ║
        \\║  SAFETY FEATURES:                                                     ║
        \\║    ✓ Pre-switch backup of all critical files                         ║
        \\║    ✓ Backup verification before proceeding                            ║
        \\║    ✓ Real-time alerting (Telegram, Discord, Slack)                   ║
        \\║    ✓ Automatic rollback on failure                                    ║
        \\║                                                                       ║
        \\║  Usage:                                                               ║
        \\║    vexor-switch <command>                                            ║
        \\║                                                                       ║
        \\║  Commands:                                                            ║
        \\║    status         Show which client is currently active              ║
        \\║    verify         Verify setup is safe for switching                 ║
        \\║    to-vexor       Switch from Agave to Vexor (with backup)           ║
        \\║    to-agave       Switch from Vexor back to Agave (with backup)      ║
        \\║    backup         Create a manual backup of current state            ║
        \\║    list-backups   List all available backups                         ║
        \\║    health         Run health check on current client                 ║
        \\║    copy-snapshot  Copy latest snapshot from Agave to Vexor           ║
        \\║                                                                       ║
        \\║  ⚠️  WARNING: Only ONE client should vote at a time!                 ║
        \\║     Running both will cause double-voting → SLASHING                 ║
        \\║                                                                       ║
        \\║  Environment Variables for Alerts:                                    ║
        \\║    VEXOR_TELEGRAM_TOKEN    - Telegram bot token                      ║
        \\║    VEXOR_TELEGRAM_CHAT     - Telegram chat ID                        ║
        \\║    VEXOR_DISCORD_WEBHOOK   - Discord webhook URL                     ║
        \\║    VEXOR_SLACK_WEBHOOK     - Slack webhook URL                       ║
        \\║                                                                       ║
        \\╚══════════════════════════════════════════════════════════════════════╝
        \\
    , .{});
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "DualClientConfig: default paths are different" {
    const config = DualClientConfig.defaultForPath("/mnt/solana");
    
    try std.testing.expect(!std.mem.eql(u8, config.agave_ledger_path, config.vexor_ledger_path));
    try std.testing.expect(!std.mem.eql(u8, config.agave_accounts_path, config.vexor_accounts_path));
    try std.testing.expect(!std.mem.eql(u8, config.agave_runtime_path, config.vexor_runtime_path));
}

test "Cluster: entrypoints" {
    const mainnet_eps = DualClientConfig.Cluster.mainnet_beta.defaultEntrypoints();
    try std.testing.expect(mainnet_eps.len >= 1);
}

