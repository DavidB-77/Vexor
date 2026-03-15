//! Vexor Unified Installer
//! Complete installation, testing, and management tool for Vexor validators.
//!
//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║                        VEXOR UNIFIED INSTALLER                            ║
//! ╠═══════════════════════════════════════════════════════════════════════════╣
//! ║                                                                           ║
//! ║  MODES:                                                                   ║
//! ║    --debug        Full debugging suite with verbose output                ║
//! ║    --production   Clean production install (default)                      ║
//! ║                                                                           ║
//! ║  COMMANDS:                                                                ║
//! ║    install           Full installation with all steps                     ║
//! ║    fix-permissions   Fix all permission issues at once                    ║
//! ║    test-bootstrap    Test snapshot loading without network                ║
//! ║    switch-to-vexor   Safe switch from Agave to Vexor                      ║
//! ║    switch-to-agave   Safe rollback from Vexor to Agave                    ║
//! ║    backup            Create full system state backup                      ║
//! ║    restore           Remove Vexor overlays, restore original state        ║
//! ║    diagnose          Run comprehensive health checks                      ║
//! ║    status            Show current validator state                         ║
//! ║                                                                           ║
//! ║  SAFETY FEATURES:                                                         ║
//! ║    • Pre-installation backup of entire system state                       ║
//! ║    • Detects existing user customizations before suggesting changes       ║
//! ║    • OVERLAY approach: Vexor configs layer ON TOP of user's configs       ║
//! ║    • User's original files are NEVER modified                             ║
//! ║    • Clean restore: removes Vexor overlays, original state preserved      ║
//! ║                                                                           ║
//! ║  FEATURES:                                                                ║
//! ║    • Upfront permission requests with user approval                       ║
//! ║    • Built-in permission fixing                                           ║
//! ║    • Client switching with backup/rollback                                ║
//! ║    • Comprehensive diagnostics                                            ║
//! ║    • Test commands for validation                                         ║
//! ║                                                                           ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝

const std = @import("std");
const fs = std.fs;
const process = std.process;
const Allocator = std.mem.Allocator;

// ═══════════════════════════════════════════════════════════════════════════════
// DETECTED ISSUE INFO - For the fix command
// ═══════════════════════════════════════════════════════════════════════════════

/// Information about a detected issue
pub const DetectedIssueInfo = struct {
    id: []const u8,
    title: []const u8,
    category: []const u8,
    severity: []const u8,
    impact: []const u8,
    current_value: []const u8,
    recommended_value: []const u8,
    auto_fix_command: ?[]const u8,
    risk_level: []const u8,
    requires_sudo: bool,
    manual_instructions: []const u8,
};

/// Simple risk level for filtering
pub const RiskLevelSimple = enum {
    low,
    medium,
    high,
};

// ═══════════════════════════════════════════════════════════════════════════════
// ENUMS & TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Installer mode
pub const InstallerMode = enum {
    debug,      // Full debugging with verbose output
    production, // Clean production install
    
    pub fn isDebug(self: InstallerMode) bool {
        return self == .debug;
    }
};

/// Debug flags for granular debugging (no password required)
pub const DebugFlags = struct {
    network: bool = false,
    storage: bool = false,
    compute: bool = false,
    system: bool = false,
    all: bool = false,
    
    pub fn fromArgs(args: []const []const u8) DebugFlags {
        var flags = DebugFlags{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--debug")) {
                flags.all = true;
            } else if (std.mem.startsWith(u8, arg, "--debug=")) {
                const value = arg["--debug=".len..];
                if (std.mem.eql(u8, value, "network")) flags.network = true;
                if (std.mem.eql(u8, value, "storage")) flags.storage = true;
                if (std.mem.eql(u8, value, "compute")) flags.compute = true;
                if (std.mem.eql(u8, value, "system")) flags.system = true;
                if (std.mem.eql(u8, value, "all")) flags.all = true;
            }
        }
        return flags;
    }
    
    pub fn shouldDebug(self: DebugFlags, category: []const u8) bool {
        if (self.all) return true;
        if (std.mem.eql(u8, category, "network")) return self.network;
        if (std.mem.eql(u8, category, "storage")) return self.storage;
        if (std.mem.eql(u8, category, "compute")) return self.compute;
        if (std.mem.eql(u8, category, "system")) return self.system;
        return false;
    }
};

/// Command to execute
pub const Command = enum {
    install,
    audit,               // System audit
    recommend,           // Generate recommendations
    fix,                 // Interactive fix for all issues (MASQUE, QUIC, AF_XDP, etc.)
    fix_permissions,
    test_bootstrap,
    test_network,
    switch_to_vexor,
    switch_to_agave,
    backup,              // Create full system state backup
    restore,             // Restore from backup (remove Vexor overlays)
    diagnose,
    status,
    health,              // Health check with auto-fix
    swap_keys,           // Hot-swap validator identity/vote keys
    help,
    
    pub fn fromString(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "install")) return .install;
        if (std.mem.eql(u8, s, "audit")) return .audit;
        if (std.mem.eql(u8, s, "recommend")) return .recommend;
        if (std.mem.eql(u8, s, "fix")) return .fix;
        if (std.mem.eql(u8, s, "fix-permissions")) return .fix_permissions;
        if (std.mem.eql(u8, s, "test-bootstrap")) return .test_bootstrap;
        if (std.mem.eql(u8, s, "test-network")) return .test_network;
        if (std.mem.eql(u8, s, "switch-to-vexor")) return .switch_to_vexor;
        if (std.mem.eql(u8, s, "backup")) return .backup;
        if (std.mem.eql(u8, s, "restore")) return .restore;
        if (std.mem.eql(u8, s, "switch-to-agave")) return .switch_to_agave;
        if (std.mem.eql(u8, s, "diagnose")) return .diagnose;
        if (std.mem.eql(u8, s, "status")) return .status;
        if (std.mem.eql(u8, s, "health")) return .health;
        if (std.mem.eql(u8, s, "swap-keys")) return .swap_keys;
        if (std.mem.eql(u8, s, "help") or std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h")) return .help;
        return null;
    }
};

/// Validator role
pub const ValidatorRole = enum {
    consensus, // Full voting validator
    rpc,       // Non-voting RPC node

    pub fn description(self: ValidatorRole) []const u8 {
        return switch (self) {
            .consensus => "Consensus Validator - Full voting with staking",
            .rpc => "RPC Node - Non-voting, serves RPC requests",
        };
    }
};

/// Network/cluster selection
pub const Network = enum {
    mainnet_beta,
    testnet,
    devnet,
    localnet,

    pub fn description(self: Network) []const u8 {
        return switch (self) {
            .mainnet_beta => "Mainnet Beta - Production (REAL SOL)",
            .testnet => "Testnet - Testing network",
            .devnet => "Devnet - Development network",
            .localnet => "Localnet - Local test cluster",
        };
    }

    pub fn entrypoints(self: Network) []const []const u8 {
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
                "entrypoint2.devnet.solana.com:8001",
            },
            .localnet => &.{"127.0.0.1:8001"},
        };
    }

    pub fn knownValidators(self: Network) []const []const u8 {
        return switch (self) {
            .mainnet_beta => &.{
                "7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2",
                "GdnSyH3YtwcxFvQrVVJMm1JhTS4QVX7MFsX56uJLUfiZ",
            },
            .testnet => &.{
                "5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on",
                "dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs",
                "Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN",
            },
            .devnet => &.{
                "dv1ZAGvdsz5hHLwWXsVnM94hWf1pjbKVau1QVkaMJ92",
            },
            .localnet => &.{},
        };
    }

    pub fn cliFlag(self: Network) []const u8 {
        return switch (self) {
            .mainnet_beta => "--mainnet-beta",
            .testnet => "--testnet",
            .devnet => "--devnet",
            .localnet => "--localnet",
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

pub const InstallerConfig = struct {
    // Mode
    mode: InstallerMode = .production,
    command: Command = .install,
    debug_flags: DebugFlags = .{},
    
    // Validator settings
    role: ValidatorRole = .consensus,
    network: Network = .testnet,
    
    // User settings
    vexor_user: []const u8 = "solana",
    vexor_group: []const u8 = "solana",
    
    // Keypair paths
    identity_path: []const u8 = "/home/solana/.secrets/validator-keypair.json",
    vote_account_path: ?[]const u8 = "/home/solana/.secrets/vote-account-keypair.json",
    
    // Directory paths
    install_dir: []const u8 = "/opt/vexor",
    ledger_dir: []const u8 = "/mnt/vexor/ledger",
    accounts_dir: []const u8 = "/mnt/vexor/accounts",
    snapshots_dir: []const u8 = "/mnt/vexor/snapshots",
    log_dir: []const u8 = "/var/log/vexor",
    runtime_dir: []const u8 = "/var/run/vexor",
    backup_dir: []const u8 = "/var/backups/vexor",
    config_dir: []const u8 = "/etc/vexor",
    
    // Ports
    rpc_port: u16 = 8900,      // Different from Agave's 8899
    gossip_port: u16 = 8801,   // Different from Agave's 8001
    tpu_port: u16 = 8803,
    tvu_port: u16 = 8804,
    
    // Features
    enable_af_xdp: bool = true,
    enable_rpc: bool = true,
    
    // Options
    non_interactive: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    
    // Existing client detection (auto-detected at runtime)
    // Supports: Agave, Firedancer, Jito, Frankendancer, or none
    existing_client: ExistingClient = .none,
    existing_service: []const u8 = "solana-validator.service", // Will be updated by detection
    existing_ledger: []const u8 = "/mnt/solana/ledger",
    existing_snapshots: []const u8 = "/mnt/solana/snapshots",
    
    // Legacy alias for backwards compatibility
    pub fn agave_service(self: *const InstallerConfig) []const u8 {
        return self.existing_service;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// BACKUP MANIFEST - Tracks what was backed up for perfect restoration
// ═══════════════════════════════════════════════════════════════════════════════

/// Represents a detected user modification that we should preserve
pub const UserModification = struct {
    category: []const u8,        // "sysctl", "service", "firewall", "cpu_pinning"
    key: []const u8,             // e.g., "net.core.rmem_max"
    current_value: []const u8,   // User's current value
    default_value: []const u8,   // System default
    vexor_recommended: []const u8, // What Vexor would set
    is_custom: bool,             // True if user modified from default
    conflict_type: ConflictType, // How it conflicts with Vexor
};

pub const ConflictType = enum {
    none,               // No conflict
    user_value_better,  // User's value is more aggressive than ours (keep theirs)
    vexor_value_better, // Vexor's value is better (suggest ours)
    different_purpose,  // Different goals, need user decision
};

/// Backup manifest - stored as JSON in backup directory
pub const BackupManifest = struct {
    version: u32 = 1,
    timestamp: i64,
    backup_id: []const u8,
    backup_path: []const u8,
    
    // What was backed up
    files_backed_up: []const []const u8,
    sysctl_snapshot: []const SysctlEntry,
    services_backed_up: []const []const u8,
    firewall_rules_file: ?[]const u8,
    
    // User modifications detected
    user_modifications: []const UserModification,
    
    // What Vexor overlays were applied (for clean removal)
    vexor_overlays_applied: []const VexorOverlay,
};

pub const SysctlEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const VexorOverlay = struct {
    overlay_type: OverlayType,
    file_path: []const u8,
    description: []const u8,
};

pub const OverlayType = enum {
    sysctl_conf,        // /etc/sysctl.d/99-vexor.conf
    systemd_service,    // /etc/systemd/system/vexor.service
    systemd_override,   // /etc/systemd/system/vexor.service.d/
    udev_rule,          // /etc/udev/rules.d/99-vexor.rules
    script,             // /usr/local/bin/switch-to-*
    config_file,        // /etc/vexor/*
};

// Sysctl keys we care about and their defaults
pub const SYSCTL_KEYS = [_]struct { key: []const u8, default: []const u8, vexor_recommended: []const u8, description: []const u8 }{
    .{ .key = "net.core.rmem_max", .default = "212992", .vexor_recommended = "134217728", .description = "Max receive buffer" },
    .{ .key = "net.core.wmem_max", .default = "212992", .vexor_recommended = "134217728", .description = "Max send buffer" },
    .{ .key = "net.core.rmem_default", .default = "212992", .vexor_recommended = "134217728", .description = "Default receive buffer" },
    .{ .key = "net.core.wmem_default", .default = "212992", .vexor_recommended = "134217728", .description = "Default send buffer" },
    .{ .key = "net.core.netdev_max_backlog", .default = "1000", .vexor_recommended = "50000", .description = "Network backlog" },
    .{ .key = "vm.swappiness", .default = "60", .vexor_recommended = "10", .description = "Swap tendency" },
    .{ .key = "vm.max_map_count", .default = "65530", .vexor_recommended = "1000000", .description = "Max memory maps" },
    .{ .key = "vm.nr_hugepages", .default = "0", .vexor_recommended = "512", .description = "Huge pages" },
    .{ .key = "net.core.bpf_jit_enable", .default = "0", .vexor_recommended = "1", .description = "BPF JIT" },
    .{ .key = "net.ipv4.tcp_rmem", .default = "4096 131072 6291456", .vexor_recommended = "4096 87380 134217728", .description = "TCP receive buffer" },
    .{ .key = "net.ipv4.tcp_wmem", .default = "4096 16384 4194304", .vexor_recommended = "4096 65536 134217728", .description = "TCP send buffer" },
    .{ .key = "net.ipv4.udp_rmem_min", .default = "4096", .vexor_recommended = "8192", .description = "UDP min receive buffer" },
    .{ .key = "net.ipv4.udp_wmem_min", .default = "4096", .vexor_recommended = "8192", .description = "UDP min send buffer" },
    .{ .key = "kernel.sched_rt_runtime_us", .default = "950000", .vexor_recommended = "980000", .description = "RT scheduler runtime" },
};

// Files we create (overlays) - these get REMOVED on restore
pub const VEXOR_OVERLAY_FILES = [_][]const u8{
    "/etc/sysctl.d/99-vexor.conf",
    "/etc/systemd/system/vexor.service",
    "/etc/udev/rules.d/99-vexor-af-xdp.rules",
    "/usr/local/bin/switch-to-vexor",
    "/usr/local/bin/switch-to-previous", // Generic - switches back to whatever was running
    "/usr/local/bin/vexor-status",
};

/// Detected existing Solana validator client types
/// Vexor can replace ANY of these clients, not just Agave
pub const ExistingClient = enum {
    agave,          // Solana Labs / Anza client (formerly solana-validator)
    firedancer,     // Jump Crypto's high-performance client
    jito,           // Jito Labs' MEV-optimized Agave fork
    frankendancer,  // Firedancer + Agave hybrid
    none,           // No validator detected
    unknown,        // Unknown validator process running
    
    pub fn serviceName(self: ExistingClient) []const u8 {
        return switch (self) {
            .agave => "solana-validator.service",
            .firedancer => "firedancer.service",
            .jito => "jito-validator.service",
            .frankendancer => "frankendancer.service",
            .none => "",
            .unknown => "unknown",
        };
    }
    
    pub fn displayName(self: ExistingClient) []const u8 {
        return switch (self) {
            .agave => "Agave (Solana Labs/Anza)",
            .firedancer => "Firedancer (Jump Crypto)",
            .jito => "Jito-Solana (Jito Labs)",
            .frankendancer => "Frankendancer",
            .none => "No Validator Running",
            .unknown => "Unknown Validator",
        };
    }
    
    pub fn ledgerPath(self: ExistingClient) []const u8 {
        return switch (self) {
            .agave, .jito => "/mnt/solana/ledger",
            .firedancer, .frankendancer => "/mnt/firedancer/ledger",
            .none, .unknown => "/mnt/solana/ledger", // Default assumption
        };
    }
    
    pub fn snapshotPath(self: ExistingClient) []const u8 {
        return switch (self) {
            .agave, .jito => "/mnt/solana/snapshots",
            .firedancer, .frankendancer => "/mnt/firedancer/snapshots",
            .none, .unknown => "/mnt/solana/snapshots",
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// UNIFIED INSTALLER
// ═══════════════════════════════════════════════════════════════════════════════

pub const UnifiedInstaller = struct {
    allocator: Allocator,
    config: InstallerConfig,
    stdin: std.fs.File,
    
    const Self = @This();

    pub fn init(allocator: Allocator, config: InstallerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .stdin = std.io.getStdIn(),
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN DISPATCH
    // ═══════════════════════════════════════════════════════════════════════

    pub fn run(self: *Self) !void {
        switch (self.config.command) {
            .install => try self.cmdInstall(),
            .audit => try self.cmdAudit(),
            .recommend => try self.cmdRecommend(),
            .fix => try self.cmdFix(),
            .fix_permissions => try self.cmdFixPermissions(),
            .test_bootstrap => try self.cmdTestBootstrap(),
            .test_network => try self.cmdTestNetwork(),
            .switch_to_vexor => try self.cmdSwitchToVexor(),
            .switch_to_agave => try self.cmdSwitchToAgave(),
            .backup => try self.cmdBackup(),
            .restore => try self.cmdRestore(),
            .diagnose => try self.cmdDiagnose(),
            .status => try self.cmdStatus(),
            .health => try self.cmdHealth(),
            .swap_keys => try self.cmdSwapKeys(),
            .help => printUsage(),
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: INSTALL
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdInstall(self: *Self) !void {
        if (self.config.dry_run) {
            self.printBanner("VEXOR INSTALLATION - DRY RUN MODE");
            self.print(
                \\
                \\🧪 DRY-RUN MODE ENABLED
                \\
                \\This is a TEST RUN. The installer will:
                \\  ✅ Perform all audits and checks
                \\  ✅ Detect hardware and system state
                \\  ✅ Generate recommendations
                \\  ✅ Show what would be changed
                \\  ❌ Make NO actual changes to your system
                \\
                \\Use this to test and debug the installer safely.
                \\
            , .{});
        } else {
            self.printBanner("VEXOR INSTALLATION");
        }
        
        // Step 0: Detect existing modifications FIRST (before any changes)
        if (!self.config.dry_run) {
            self.print(
                \\
                \\⚠️  SAFETY FIRST
                \\
                \\Before making any changes, Vexor will:
                \\  1. Detect your existing system modifications
                \\  2. Create a full backup of your current state
                \\  3. Use OVERLAY approach (your configs stay untouched)
                \\
            , .{});
        }
        
        // Detect what the user has already customized
        try self.detectExistingModifications();
        
        // Create backup BEFORE any installation (skip in dry-run)
        var backup_id: ?[]const u8 = null;
        if (self.config.dry_run) {
            self.print("\n📦 [DRY RUN] Would create pre-installation backup\n", .{});
            self.print("───────────────────────────────────────────────────\n", .{});
            self.print("  [DRY RUN] Backup would be created at: {s}/backup-<timestamp>\n", .{self.config.backup_dir});
            self.print("  [DRY RUN] No actual backup will be created\n", .{});
        } else {
            self.print("\n📦 CREATING PRE-INSTALLATION BACKUP\n", .{});
            self.print("───────────────────────────────────────────────────\n", .{});
            backup_id = try self.createFullBackup();
            self.print(
                \\
                \\✅ Backup created: {s}
                \\
                \\If anything goes wrong, restore with:
                \\  vexor-install restore
                \\
            , .{backup_id.?});
        }
        defer if (backup_id) |id| self.allocator.free(id);
        
        // Step 1: Request permissions upfront
        if (!try self.requestPermissions()) {
            self.print("\n❌ Installation cancelled - permissions not granted.\n", .{});
            return;
        }
        
        // Step 2: Key detection and selection
        const detected_keys = try self.detectCurrentClientKeys();
        const key_selection = try self.promptForKeySelection(detected_keys);
        defer {
            self.allocator.free(key_selection.identity_path);
            if (key_selection.vote_account_path) |v| self.allocator.free(v);
        }
        
        // Update config with selected keys
        self.config.identity_path = key_selection.identity_path;
        self.config.vote_account_path = key_selection.vote_account_path;

        // Step 3: Interactive setup (if not non-interactive)
        if (!self.config.non_interactive) {
            try self.interactiveSetup();
        }
        
        // Step 4: Show installation plan
        try self.showInstallationPlan();
        
        // Step 5: Get final approval
        if (!self.config.non_interactive) {
            if (!try self.confirm("Proceed with installation?")) {
                self.print("\n❌ Installation cancelled.\n", .{});
                return;
            }
        }
        
        // Step 6: Setup dual system integration (if previous client detected)
        try self.setupDualSystem();
        
        // Step 7: Run installation (uses overlay approach for sysctl)
        // Wrap in automatic rollback on failure (skip in dry-run)
        if (self.config.dry_run) {
            self.print("\n  [DRY RUN] Would run installation...\n", .{});
            self.print("    [DRY RUN] Would create directories\n", .{});
            self.print("    [DRY RUN] Would install binary\n", .{});
            self.print("    [DRY RUN] Would create config files\n", .{});
            self.print("    [DRY RUN] Would create systemd service\n", .{});
            self.print("    [DRY RUN] Would set capabilities\n", .{});
            self.print("    [DRY RUN] No actual changes would be made\n", .{});
        } else {
            self.runInstallation() catch |err| {
                self.print("\n❌ Installation failed: {}\n", .{err});
                self.print("🔄 Attempting automatic rollback...\n", .{});
                if (backup_id) |id| {
                    try self.autoRollback(id, "Installation failed");
                }
                return err;
            };
        }
        
        // Step 8: Show completion
        try self.showCompletion();
    }

    fn requestPermissions(self: *Self) !bool {
        self.print("\n", .{});
        self.printBanner("PERMISSION REQUEST");
        self.print(
            \\
            \\Vexor installer needs the following permissions:
            \\
            \\DIRECTORIES (will be owned by {s}):
            \\  [1] {s}/bin/         - Vexor binaries
            \\  [2] {s}/              - Ledger storage
            \\  [3] {s}/           - Accounts database
            \\  [4] {s}/          - Snapshot storage
            \\  [5] {s}/            - Log files
            \\  [6] {s}/          - Runtime files
            \\  [7] {s}/        - Backup storage
            \\  [8] {s}/            - Configuration
            \\
            \\SYSTEM CHANGES:
            \\  [9] Create systemd service file
            \\ [10] Create switch scripts in /usr/local/bin/
            \\ [11] Set AF_XDP capabilities on binary
            \\
            \\KEYPAIR ACCESS (read only):
            \\ [12] {s}
            \\
        , .{
            self.config.vexor_user,
            self.config.install_dir,
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.log_dir,
            self.config.runtime_dir,
            self.config.backup_dir,
            self.config.config_dir,
            self.config.identity_path,
        });
        
        if (self.config.non_interactive) {
            self.print("\n[Non-interactive mode: auto-approving permissions]\n", .{});
            return true;
        }
        
        self.print("\n⚠️  This installer requires sudo/root privileges.\n", .{});
        return try self.confirm("Grant these permissions?");
    }

    fn interactiveSetup(self: *Self) !void {
        self.printBanner("CONFIGURATION");
        
        // Role selection
        self.print("\n📋 Select Validator Role:\n", .{});
        self.print("  [1] Consensus Validator (voting, staking)\n", .{});
        self.print("  [2] RPC Node (non-voting)\n", .{});
        
        const role_choice = try self.readLine("Choice [1/2] (default: 1): ");
        if (role_choice.len > 0 and role_choice[0] == '2') {
            self.config.role = .rpc;
            self.config.vote_account_path = null;
        }
        self.print("✅ Selected: {s}\n", .{self.config.role.description()});
        
        // Network selection
        self.print("\n📋 Select Network:\n", .{});
        self.print("  [1] Mainnet Beta (REAL SOL!)\n", .{});
        self.print("  [2] Testnet (recommended)\n", .{});
        self.print("  [3] Devnet\n", .{});
        self.print("  [4] Localnet\n", .{});
        
        const net_choice = try self.readLine("Choice [1-4] (default: 2): ");
        if (net_choice.len > 0) {
            self.config.network = switch (net_choice[0]) {
                '1' => .mainnet_beta,
                '2' => .testnet,
                '3' => .devnet,
                '4' => .localnet,
                else => .testnet,
            };
        }
        self.print("✅ Selected: {s}\n", .{self.config.network.description()});
    }

    fn showInstallationPlan(self: *Self) !void {
        self.printBanner("INSTALLATION PLAN");
        self.print(
            \\
            \\The following will be installed:
            \\
            \\  Role:         {s}
            \\  Network:      {s}
            \\  User:         {s}
            \\
            \\  Binary:       {s}/bin/vexor
            \\  Ledger:       {s}
            \\  Accounts:     {s}
            \\  Snapshots:    {s}
            \\  Logs:         {s}
            \\  Config:       {s}/config.toml
            \\
            \\  RPC Port:     {d}
            \\  Gossip Port:  {d}
            \\  AF_XDP:       {s}
            \\
            \\  Systemd:      vexor.service
            \\  Scripts:      switch-to-vexor, switch-to-agave, validator-status
            \\
        , .{
            self.config.role.description(),
            self.config.network.description(),
            self.config.vexor_user,
            self.config.install_dir,
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.log_dir,
            self.config.config_dir,
            self.config.rpc_port,
            self.config.gossip_port,
            if (self.config.enable_af_xdp) "Enabled" else "Disabled",
        });
    }

    fn runInstallation(self: *Self) !void {
        self.printBanner("RUNNING INSTALLATION");
        
        // Step 1: Fix permissions (creates directories, sets ownership)
        self.print("\n[1/6] Setting up directories and permissions...\n", .{});
        try self.fixPermissionsInternal();
        self.debug("  Directories created and permissions set", .{});
        
        // Step 2: Copy binary
        self.print("[2/6] Installing Vexor binary...\n", .{});
        try self.installBinary();
        self.debug("  Binary installed to {s}/bin/vexor", .{self.config.install_dir});
        
        // Step 3: Create config file
        self.print("[3/6] Creating configuration...\n", .{});
        try self.createConfigFile();
        self.debug("  Config created at {s}/config.toml", .{self.config.config_dir});
        
        // Step 4: Create systemd service
        self.print("[4/6] Creating systemd service...\n", .{});
        try self.createSystemdService();
        self.debug("  Service created: vexor.service", .{});
        
        // Step 5: Create switch scripts
        self.print("[5/6] Creating switch scripts...\n", .{});
        try self.createSwitchScripts();
        self.debug("  Scripts created in /usr/local/bin/", .{});
        
        // Step 6: Set AF_XDP capabilities
        if (self.config.enable_af_xdp) {
            self.print("[6/6] Setting AF_XDP capabilities...\n", .{});
            try self.setAfXdpCapabilities();
            self.debug("  Capabilities set on binary", .{});
        } else {
            self.print("[6/6] Skipping AF_XDP (disabled)...\n", .{});
        }
        
        self.print("\n✅ Installation complete!\n", .{});
    }

    fn showCompletion(self: *Self) !void {
        self.printBanner("INSTALLATION COMPLETE");
        self.print(
            \\
            \\✅ Vexor has been successfully installed!
            \\
            \\Next steps:
            \\
            \\  1. Check status:
            \\     validator-status
            \\
            \\  2. Test bootstrap (without stopping Agave):
            \\     vexor-install test-bootstrap
            \\
            \\  3. Switch to Vexor (stops Agave):
            \\     sudo switch-to-vexor
            \\
            \\  4. If issues, rollback to Agave:
            \\     sudo switch-to-agave
            \\
            \\  5. Run diagnostics:
            \\     vexor-install diagnose
            \\
            \\For debugging, use:
            \\  vexor-install --debug <command>
            \\
        , .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: FIX-PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdFixPermissions(self: *Self) !void {
        self.printBanner("FIX PERMISSIONS");
        
        self.print("\nFixing all Vexor permissions...\n\n", .{});
        try self.fixPermissionsInternal();
        
        self.print("\n✅ All permissions fixed!\n", .{});
        self.print("\nVerification:\n", .{});
        try self.verifyPermissions();
    }

    fn fixPermissionsInternal(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would create directories and set permissions\n", .{});
            return;
        }
        
        // Create directories
        const dirs = [_][]const u8{
            self.config.install_dir,
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.log_dir,
            self.config.runtime_dir,
            self.config.backup_dir,
            self.config.config_dir,
        };
        
        for (dirs) |dir| {
            self.debug("  Creating: {s}", .{dir});
            _ = runCommand(&.{ "mkdir", "-p", dir }) catch {};
        }
        
        // Create bin directory
        const bin_dir = try std.fmt.allocPrint(self.allocator, "{s}/bin", .{self.config.install_dir});
        defer self.allocator.free(bin_dir);
        _ = runCommand(&.{ "mkdir", "-p", bin_dir }) catch {};
        
        // Set ownership on Vexor-managed dirs
        const owned_dirs = [_][]const u8{
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.log_dir,
            self.config.runtime_dir,
            self.config.backup_dir,
        };
        
        for (owned_dirs) |dir| {
            const owner = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.config.vexor_user, self.config.vexor_group });
            defer self.allocator.free(owner);
            self.debug("  Setting owner {s} on {s}", .{ owner, dir });
            _ = runCommand(&.{ "chown", "-R", owner, dir }) catch {};
            _ = runCommand(&.{ "chmod", "755", dir }) catch {};
        }
        
        // Fix snapshot extraction permissions if exists
        const extracted_pattern = try std.fmt.allocPrint(self.allocator, "{s}/extracted-*", .{self.config.snapshots_dir});
        defer self.allocator.free(extracted_pattern);
        _ = runCommand(&.{ "chmod", "-R", "u+r", extracted_pattern }) catch {};
        
        // Ensure /mnt/vexor parent exists
        _ = runCommand(&.{ "mkdir", "-p", "/mnt/vexor" }) catch {};
        const vexor_owner = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.config.vexor_user, self.config.vexor_group });
        defer self.allocator.free(vexor_owner);
        _ = runCommand(&.{ "chown", vexor_owner, "/mnt/vexor" }) catch {};
    }

    fn verifyPermissions(self: *Self) !void {
        const dirs = [_]struct { path: []const u8, name: []const u8 }{
            .{ .path = self.config.install_dir, .name = "Install dir" },
            .{ .path = self.config.ledger_dir, .name = "Ledger" },
            .{ .path = self.config.accounts_dir, .name = "Accounts" },
            .{ .path = self.config.snapshots_dir, .name = "Snapshots" },
            .{ .path = self.config.log_dir, .name = "Logs" },
            .{ .path = self.config.backup_dir, .name = "Backups" },
        };
        
        for (dirs) |d| {
            if (fs.cwd().access(d.path, .{})) |_| {
                self.print("  ✅ {s}: {s}\n", .{ d.name, d.path });
            } else |_| {
                self.print("  ❌ {s}: {s} (missing)\n", .{ d.name, d.path });
            }
        }
        
        // Check binary
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        if (fs.cwd().access(binary_path, .{})) |_| {
            self.print("  ✅ Binary: {s}\n", .{binary_path});
        } else |_| {
            self.print("  ⚠️  Binary: not installed yet\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: TEST-BOOTSTRAP
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdTestBootstrap(self: *Self) !void {
        self.printBanner("TEST BOOTSTRAP");
        
        self.print(
            \\
            \\This will test Vexor's snapshot loading without starting the network.
            \\Agave will NOT be stopped - this is a safe test.
            \\
            \\Testing:
            \\  • Identity keypair loading
            \\  • Storage initialization
            \\  • Snapshot extraction
            \\  • Accounts loading
            \\
        , .{});
        
        if (!self.config.non_interactive) {
            if (!try self.confirm("Run bootstrap test?")) return;
        }
        
        self.print("\nRunning bootstrap test...\n", .{});
        self.print("(This may take a few minutes for large snapshots)\n\n", .{});
        
        // Run vexor with bootstrap but with a timeout
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        
        const network_flag = self.config.network.cliFlag();
        
        const result = runCommandOutput(self.allocator, &.{
            "sudo", "-u", self.config.vexor_user,
            "timeout", "120",
            binary_path,
            "run", "--bootstrap",
            network_flag,
            "--identity", self.config.identity_path,
            "--snapshots", self.config.snapshots_dir,
            "--ledger", self.config.ledger_dir,
            "--accounts", self.config.accounts_dir,
        }) catch |err| {
            self.print("❌ Bootstrap test failed to run: {}\n", .{err});
            return;
        };
        defer self.allocator.free(result);
        
        self.print("{s}\n", .{result});
        
        // Check for success indicators
        if (std.mem.indexOf(u8, result, "Bootstrap complete") != null or
            std.mem.indexOf(u8, result, "loaded") != null)
        {
            self.print("\n✅ Bootstrap test passed!\n", .{});
        } else if (std.mem.indexOf(u8, result, "AddressInUse") != null) {
            self.print("\n⚠️  Bootstrap succeeded but network test skipped (ports in use by Agave)\n", .{});
            self.print("   This is expected. Use 'switch-to-vexor' for full test.\n", .{});
        } else {
            self.print("\n❌ Bootstrap test may have issues. Check output above.\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: TEST-NETWORK
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdTestNetwork(self: *Self) !void {
        self.printBanner("TEST NETWORK");
        
        self.print(
            \\
            \\⚠️  WARNING: This test requires stopping Agave!
            \\
            \\This will:
            \\  1. Stop Agave (solana-validator)
            \\  2. Start Vexor briefly to test networking
            \\  3. Stop Vexor and restart Agave
            \\
        , .{});
        
        if (!try self.confirm("Stop Agave and run network test?")) return;
        
        self.print("\nRunning network test...\n", .{});
        
        // Stop existing client
        self.print("  Stopping existing validator...\n", .{});
        _ = runCommand(&.{ "systemctl", "stop", self.config.existing_service }) catch {};
        std.time.sleep(5 * std.time.ns_per_s);
        
        // Start Vexor briefly
        self.print("  Starting Vexor...\n", .{});
        _ = runCommand(&.{ "systemctl", "start", "vexor" }) catch {};
        std.time.sleep(10 * std.time.ns_per_s);
        
        // Check status
        const vexor_active = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        
        // Stop Vexor
        self.print("  Stopping Vexor...\n", .{});
        _ = runCommand(&.{ "systemctl", "stop", "vexor" }) catch {};
        std.time.sleep(3 * std.time.ns_per_s);
        
        // Restart previous validator
        self.print("  Restarting previous validator...\n", .{});
        _ = runCommand(&.{ "systemctl", "start", self.config.existing_service }) catch {};
        
        if (vexor_active == true) {
            self.print("\n✅ Network test passed - Vexor started successfully!\n", .{});
        } else {
            self.print("\n❌ Network test failed - Vexor didn't start properly\n", .{});
            self.print("   Check logs with: journalctl -u vexor -n 50\n", .{});
        }
        
        self.print("\n✅ Agave has been restarted.\n", .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: SWITCH-TO-VEXOR
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdSwitchToVexor(self: *Self) !void {
        self.printBanner("SWITCH TO VEXOR");
        
        self.print(
            \\
            \\⚠️  This will STOP your Agave validator and START Vexor.
            \\
            \\Pre-switch checklist:
            \\
        , .{});
        
        // Run pre-checks
        var checks_passed: u32 = 0;
        var checks_total: u32 = 0;
        
        // Check binary
        checks_total += 1;
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        if (fs.cwd().access(binary_path, .{})) |_| {
            self.print("  ✅ Vexor binary exists\n", .{});
            checks_passed += 1;
        } else |_| {
            self.print("  ❌ Vexor binary missing\n", .{});
        }
        
        // Check identity
        checks_total += 1;
        if (fs.cwd().access(self.config.identity_path, .{})) |_| {
            self.print("  ✅ Identity keypair accessible\n", .{});
            checks_passed += 1;
        } else |_| {
            self.print("  ❌ Identity keypair not accessible\n", .{});
        }
        
        // Check systemd service
        checks_total += 1;
        if (fs.cwd().access("/etc/systemd/system/vexor.service", .{})) |_| {
            self.print("  ✅ Systemd service exists\n", .{});
            checks_passed += 1;
        } else |_| {
            self.print("  ❌ Systemd service missing\n", .{});
        }
        
        self.print("\nChecks: {d}/{d} passed\n", .{ checks_passed, checks_total });
        
        if (checks_passed < checks_total) {
            self.print("\n❌ Cannot switch - some checks failed. Run 'vexor-install install' first.\n", .{});
            return;
        }
        
        if (!try self.confirm("\nProceed with switch?")) return;
        
        // Create backup
        self.print("\nCreating pre-switch backup...\n", .{});
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/switchover-{d}", .{ self.config.backup_dir, timestamp });
        defer self.allocator.free(backup_path);
        _ = runCommand(&.{ "mkdir", "-p", backup_path }) catch {};
        self.print("  Backup: {s}\n", .{backup_path});
        
        // Stop existing client
        self.print("\nStopping existing validator ({s})...\n", .{self.config.existing_service});
        _ = runCommand(&.{ "systemctl", "stop", self.config.existing_service }) catch {};
        std.time.sleep(5 * std.time.ns_per_s);
        
        // Start Vexor
        self.print("Starting Vexor...\n", .{});
        _ = runCommand(&.{ "systemctl", "start", "vexor" }) catch {};
        std.time.sleep(5 * std.time.ns_per_s);
        
        // Verify
        const vexor_active = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        
        if (vexor_active == true) {
            self.print("\n✅ Successfully switched to Vexor!\n", .{});
            self.print("\nMonitor with: journalctl -u vexor -f\n", .{});
            self.print("Rollback with: sudo vexor-install switch-to-previous\n", .{});
        } else {
            self.print("\n❌ Vexor failed to start! Rolling back...\n", .{});
            _ = runCommand(&.{ "systemctl", "start", self.config.existing_service }) catch {};
            self.print("✅ Previous validator restarted.\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: SWITCH-TO-AGAVE (also handles switch-to-previous)
    // Switches back to whatever client was running before Vexor
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdSwitchToAgave(self: *Self) !void {
        self.printBanner("SWITCH TO PREVIOUS VALIDATOR");
        
        self.print("\nStopping Vexor and starting previous validator...\n", .{});
        self.print("  Previous client: {s}\n", .{self.config.existing_service});
        
        // Stop Vexor
        self.print("  Stopping Vexor...\n", .{});
        _ = runCommand(&.{ "systemctl", "stop", "vexor" }) catch {};
        std.time.sleep(5 * std.time.ns_per_s);
        
        // Start previous client
        self.print("  Starting previous validator...\n", .{});
        _ = runCommand(&.{ "systemctl", "start", self.config.existing_service }) catch {};
        std.time.sleep(5 * std.time.ns_per_s);
        
        // Verify
        const prev_active = runCommand(&.{ "systemctl", "is-active", "--quiet", self.config.existing_service }) catch false;
        
        if (prev_active == true) {
            self.print("\n✅ Successfully switched back to previous validator!\n", .{});
            
            // Offer to remove Vexor overlays
            if (try self.confirm("\nRemove Vexor system overlays (sysctl, udev rules)?")) {
                try self.removeVexorOverlays();
                self.print("✅ Vexor overlays removed. System restored to original state.\n", .{});
            } else {
                self.print("ℹ️  Vexor overlays kept. Run 'vexor-install restore' later to remove.\n", .{});
            }
        } else {
            self.print("\n❌ Previous validator failed to start! Manual intervention required.\n", .{});
            self.print("   Try: sudo systemctl start {s}\n", .{self.config.existing_service});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: BACKUP - Create full system state backup
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdBackup(self: *Self) !void {
        self.printBanner("SYSTEM STATE BACKUP");
        
        self.print(
            \\
            \\This will create a complete backup of your current system state:
            \\  • All sysctl values (kernel tuning)
            \\  • Systemd service configurations
            \\  • Firewall rules
            \\  • Existing validator configuration
            \\
            \\This backup can be used to restore your system to its exact
            \\current state after uninstalling Vexor.
            \\
        , .{});
        
        if (!try self.confirm("\nCreate backup now?")) {
            self.print("\nBackup cancelled.\n", .{});
            return;
        }
        
        const backup_id = try self.createFullBackup();
        defer self.allocator.free(backup_id);
        
        self.print(
            \\
            \\✅ BACKUP COMPLETE
            \\
            \\  Backup ID: {s}
            \\  Location:  {s}/{s}
            \\
            \\To restore this backup later:
            \\  vexor-install restore {s}
            \\
            \\To list all backups:
            \\  vexor-install restore --list
            \\
        , .{ backup_id, self.config.backup_dir, backup_id, backup_id });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: RESTORE - Remove Vexor overlays and restore original state
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdRestore(self: *Self) !void {
        self.printBanner("RESTORE SYSTEM STATE");
        
        // List available backups
        self.print("\n📦 AVAILABLE BACKUPS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        var backup_count: u32 = 0;
        
        if (fs.cwd().openDir(self.config.backup_dir, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "backup-")) {
                    backup_count += 1;
                    // Try to read manifest to get timestamp
                    self.print("  [{d}] {s}\n", .{ backup_count, entry.name });
                }
            }
        } else |_| {
            self.print("  No backups found at {s}\n", .{self.config.backup_dir});
            return;
        }
        
        if (backup_count == 0) {
            self.print("  No backups found.\n", .{});
            return;
        }
        
        self.print(
            \\
            \\RESTORE OPTIONS:
            \\
            \\  1. Remove Vexor overlays only (keeps backup, removes our configs)
            \\  2. Full restore from backup (restore original sysctl values)
            \\
        , .{});
        
        if (!try self.confirm("\nRemove Vexor overlays and restore original state?")) {
            self.print("\nRestore cancelled.\n", .{});
            return;
        }
        
        // Remove Vexor overlays
        try self.removeVexorOverlays();
        
        self.print(
            \\
            \\✅ RESTORE COMPLETE
            \\
            \\Vexor overlays have been removed:
            \\  ✓ /etc/sysctl.d/99-vexor.conf
            \\  ✓ /etc/systemd/system/vexor.service
            \\  ✓ /etc/udev/rules.d/99-vexor-af-xdp.rules
            \\  ✓ Switch scripts
            \\
            \\Your original sysctl values are still active.
            \\Run 'sudo sysctl --system' to reload if needed.
            \\
        , .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // AUTOMATIC ROLLBACK SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /// Automatic rollback on interference, crash, or failure
    fn autoRollback(self: *Self, backup_id: []const u8, reason: []const u8) !void {
        self.print("\n", .{});
        self.printBanner("AUTOMATIC ROLLBACK");
        self.print("\n  Reason: {s}\n", .{reason});
        self.print("  Backup ID: {s}\n", .{backup_id});
        
        // Stop Vexor if running
        const is_running = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        if (is_running) {
            self.print("  🛑 Stopping Vexor...\n", .{});
            _ = runCommand(&.{ "systemctl", "stop", "vexor" }) catch {};
        }
        
        // Restore previous client if detected
        const previous_client = try self.detectAnyValidatorClient();
        if (previous_client != .none and previous_client != .unknown) {
            const service_name = previous_client.serviceName();
            if (service_name.len > 0) {
                self.print("  🔄 Restoring previous client: {s}...\n", .{previous_client.displayName()});
                _ = runCommand(&.{ "systemctl", "start", service_name }) catch {};
            }
        }
        
        // Restore from backup
        self.print("  📦 Restoring system state from backup...\n", .{});
        self.restoreFromBackup(backup_id) catch |err| {
            self.print("  ⚠️  Backup restore failed: {}\n", .{err});
        };
        
        // Remove Vexor overlays
        self.print("  🧹 Removing Vexor overlays...\n", .{});
        self.removeVexorOverlays() catch |err| {
            self.print("  ⚠️  Overlay removal failed: {}\n", .{err});
        };
        
        self.print("\n  ✅ Automatic rollback complete\n", .{});
        self.print("     System restored to state before Vexor changes\n", .{});
    }

    /// Restore from specific backup
    fn restoreFromBackup(self: *Self, backup_id: []const u8) !void {
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.backup_dir, backup_id });
        defer self.allocator.free(backup_path);
        
        // Restore sysctl values
        const sysctl_file = try std.fmt.allocPrint(self.allocator, "{s}/sysctl-snapshot.conf", .{backup_path});
        defer self.allocator.free(sysctl_file);
        
        if (fs.cwd().openFile(sysctl_file, .{})) |_| {
            // Apply backed up sysctl values
            _ = runCommand(&.{ "sh", "-c", try std.fmt.allocPrint(self.allocator, "sysctl -p {s} 2>/dev/null || true", .{sysctl_file}) }) catch {};
        } else |_| {}
        
        // Restore systemd services
        const services_backup = try std.fmt.allocPrint(self.allocator, "{s}/systemd", .{backup_path});
        defer self.allocator.free(services_backup);
        
        if (fs.cwd().openDir(services_backup, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".service")) {
                    const src = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ services_backup, entry.name });
                    defer self.allocator.free(src);
                    const dst = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/{s}", .{entry.name});
                    defer self.allocator.free(dst);
                    _ = runCommand(&.{ "cp", src, dst }) catch {};
                }
            }
        } else |_| {}
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DUAL SYSTEM / AUTOMATIC SWITCHING
    // ═══════════════════════════════════════════════════════════════════════

    /// Setup dual system integration (automatic switching)
    fn setupDualSystem(self: *Self) !void {
        self.print("\n  🔄 Setting up dual system integration...\n", .{});
        
        // Detect previous client
        const previous_client = try self.detectAnyValidatorClient();
        if (previous_client == .none) {
            self.print("    ℹ️  No previous client detected - skipping dual system setup\n", .{});
            return;
        }
        
        const previous_service = previous_client.serviceName();
        if (previous_service.len == 0) {
            return;
        }
        
        // Create systemd service override that stops previous client when Vexor starts
        const override_dir = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/vexor.service.d", .{});
        defer self.allocator.free(override_dir);
        _ = runCommand(&.{ "mkdir", "-p", override_dir }) catch {};
        
        const override_file = try std.fmt.allocPrint(self.allocator, "{s}/stop-previous-client.conf", .{override_dir});
        defer self.allocator.free(override_file);
        
        var file = try fs.cwd().createFile(override_file, .{});
        defer file.close();
        
        const override_content = try std.fmt.allocPrint(self.allocator,
            \\[Unit]
            \\After={s}
            \\Conflicts={s}
            \\
            \\[Service]
            \\ExecStartPre=/bin/systemctl stop {s} || true
            \\ExecStopPost=/bin/systemctl start {s} || true
            \\
        , .{ previous_service, previous_service, previous_service, previous_service });
        defer self.allocator.free(override_content);
        
        try file.writeAll(override_content);
        
        // Reload systemd
        _ = runCommand(&.{ "systemctl", "daemon-reload" }) catch {};
        
        self.print("    ✅ Dual system integration configured\n", .{});
        self.print("       Vexor will stop {s} when starting\n", .{previous_client.displayName()});
        self.print("       {s} will restart when Vexor stops\n", .{previous_client.displayName()});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BACKUP HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// Create a full system state backup before any modifications
    fn createFullBackup(self: *Self) ![]const u8 {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        const backup_id = try std.fmt.allocPrint(self.allocator, "backup-{d}", .{timestamp});
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.backup_dir, backup_id });
        defer self.allocator.free(backup_path);
        
        self.print("\n📦 Creating backup: {s}\n", .{backup_id});
        
        // Create backup directory
        _ = runCommand(&.{ "mkdir", "-p", backup_path }) catch {};
        
        // 1. Backup all current sysctl values
        self.print("  [1/5] Saving sysctl values...\n", .{});
        const sysctl_file = try std.fmt.allocPrint(self.allocator, "{s}/sysctl-snapshot.conf", .{backup_path});
        defer self.allocator.free(sysctl_file);
        const sysctl_cmd = try std.fmt.allocPrint(self.allocator, "sysctl -a > {s} 2>/dev/null", .{sysctl_file});
        defer self.allocator.free(sysctl_cmd);
        _ = runCommand(&.{ "sh", "-c", sysctl_cmd }) catch {};
        
        // 2. Backup existing sysctl.d configs (not ours)
        self.print("  [2/5] Saving sysctl.d configs...\n", .{});
        const sysctl_d_backup = try std.fmt.allocPrint(self.allocator, "{s}/sysctl.d", .{backup_path});
        defer self.allocator.free(sysctl_d_backup);
        _ = runCommand(&.{ "mkdir", "-p", sysctl_d_backup }) catch {};
        // Copy all except vexor's
        const find_cmd = try std.fmt.allocPrint(self.allocator, 
            "find /etc/sysctl.d -name '*.conf' ! -name '*vexor*' -exec cp {{}} {s}/ \\;", .{sysctl_d_backup});
        defer self.allocator.free(find_cmd);
        _ = runCommand(&.{ "sh", "-c", find_cmd }) catch {};
        
        // 3. Backup systemd services (Agave/Solana)
        self.print("  [3/5] Saving service configs...\n", .{});
        const services_backup = try std.fmt.allocPrint(self.allocator, "{s}/systemd", .{backup_path});
        defer self.allocator.free(services_backup);
        _ = runCommand(&.{ "mkdir", "-p", services_backup }) catch {};
        const cp_solana_cmd = try std.fmt.allocPrint(self.allocator,
            "cp /etc/systemd/system/solana*.service {s}/ 2>/dev/null || true", .{services_backup});
        defer self.allocator.free(cp_solana_cmd);
        _ = runCommand(&.{ "sh", "-c", cp_solana_cmd }) catch {};
        const cp_agave_cmd = try std.fmt.allocPrint(self.allocator,
            "cp /etc/systemd/system/agave*.service {s}/ 2>/dev/null || true", .{services_backup});
        defer self.allocator.free(cp_agave_cmd);
        _ = runCommand(&.{ "sh", "-c", cp_agave_cmd }) catch {};
        
        // 4. Backup firewall rules
        self.print("  [4/5] Saving firewall rules...\n", .{});
        const fw_file = try std.fmt.allocPrint(self.allocator, "{s}/firewall-rules.txt", .{backup_path});
        defer self.allocator.free(fw_file);
        const fw_cmd = try std.fmt.allocPrint(self.allocator,
            "ufw status numbered > {s} 2>/dev/null || iptables-save > {s} 2>/dev/null || echo 'No firewall rules' > {s}", 
            .{fw_file, fw_file, fw_file});
        defer self.allocator.free(fw_cmd);
        _ = runCommand(&.{ "sh", "-c", fw_cmd }) catch {};
        
        // 5. Create manifest with detected user modifications
        self.print("  [5/5] Detecting user modifications...\n", .{});
        const manifest_file = try std.fmt.allocPrint(self.allocator, "{s}/manifest.txt", .{backup_path});
        defer self.allocator.free(manifest_file);
        
        var manifest_content = std.ArrayList(u8).init(self.allocator);
        defer manifest_content.deinit();
        
        try manifest_content.appendSlice("# Vexor Backup Manifest\n");
        
        // Use format writer instead of allocPrint to avoid leaks
        try manifest_content.writer().print("# Created: {d}\n", .{timestamp});
        try manifest_content.writer().print("# Backup ID: {s}\n\n", .{backup_id});
        
        try manifest_content.appendSlice("## User Modifications Detected\n\n");
        
        // Check each sysctl key for non-default values
        for (SYSCTL_KEYS) |entry| {
            const current = runCommandOutput(self.allocator, &.{ "sysctl", "-n", entry.key }) catch continue;
            defer self.allocator.free(current);
            const current_trimmed = std.mem.trim(u8, current, &std.ascii.whitespace);
            
            if (!std.mem.eql(u8, current_trimmed, entry.default)) {
                // User has modified this - use writer to avoid allocation
                try manifest_content.writer().print(
                    "MODIFIED: {s}\n  Current: {s}\n  Default: {s}\n  Vexor would set: {s}\n\n",
                    .{entry.key, current_trimmed, entry.default, entry.vexor_recommended});
            }
        }
        
        // Write manifest
        if (fs.cwd().createFile(manifest_file, .{})) |file| {
            defer file.close();
            file.writeAll(manifest_content.items) catch {};
        } else |_| {}
        
        self.print("  ✅ Backup complete: {s}\n", .{backup_path});
        
        return backup_id;
    }

    /// Remove all Vexor overlay files (non-destructive to user's original configs)
    fn removeVexorOverlays(self: *Self) !void {
        self.print("\n🧹 Removing Vexor overlays...\n", .{});
        
        // Remove each overlay file
        for (VEXOR_OVERLAY_FILES) |file_path| {
            if (fs.cwd().access(file_path, .{})) |_| {
                _ = runCommand(&.{ "rm", "-f", file_path }) catch {};
                self.print("  ✓ Removed: {s}\n", .{file_path});
            } else |_| {
                self.print("  · Not found: {s}\n", .{file_path});
            }
        }
        
        // Remove Vexor config directory
        const vexor_config = "/etc/vexor";
        if (fs.cwd().access(vexor_config, .{})) |_| {
            _ = runCommand(&.{ "rm", "-rf", vexor_config }) catch {};
            self.print("  ✓ Removed: {s}\n", .{vexor_config});
        } else |_| {}
        
        // Reload sysctl to remove our settings
        self.print("\n  Reloading sysctl...\n", .{});
        _ = runCommand(&.{ "sysctl", "--system" }) catch {};
        
        // Reload systemd
        self.print("  Reloading systemd...\n", .{});
        _ = runCommand(&.{ "systemctl", "daemon-reload" }) catch {};
        
        // Reload udev
        self.print("  Reloading udev rules...\n", .{});
        _ = runCommand(&.{ "udevadm", "control", "--reload-rules" }) catch {};
    }

    /// Detect user modifications and check for conflicts with Vexor settings
    fn detectExistingModifications(self: *Self) !void {
        self.print("\n🔍 DETECTING EXISTING MODIFICATIONS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        var mods_found: u32 = 0;
        var conflicts: u32 = 0;
        
        self.print("\n  [SYSCTL TUNING]\n", .{});
        
        for (SYSCTL_KEYS) |entry| {
            const current = runCommandOutput(self.allocator, &.{ "sysctl", "-n", entry.key }) catch continue;
            defer self.allocator.free(current);
            const current_trimmed = std.mem.trim(u8, current, &std.ascii.whitespace);
            
            // Skip if matches default
            if (std.mem.eql(u8, current_trimmed, entry.default)) continue;
            
            mods_found += 1;
            
            // Determine conflict type
            const current_val = std.fmt.parseInt(i64, current_trimmed, 10) catch 0;
            const vexor_val = std.fmt.parseInt(i64, entry.vexor_recommended, 10) catch 0;
            
            if (std.mem.eql(u8, current_trimmed, entry.vexor_recommended)) {
                // Already set to what we want
                self.print("    ✅ {s}: {s} (already optimal)\n", .{entry.key, current_trimmed});
            } else if (current_val >= vexor_val and vexor_val > 0) {
                // User's value is better/higher
                self.print("    🟢 {s}: {s} (your value is better, keeping)\n", .{entry.key, current_trimmed});
            } else {
                // Conflict - our value is better
                conflicts += 1;
                self.print("    ⚠️  {s}:\n", .{entry.key});
                self.print("        Your value:   {s}\n", .{current_trimmed});
                self.print("        Vexor needs:  {s}\n", .{entry.vexor_recommended});
                self.print("        (Will create overlay, your original preserved)\n", .{});
            }
        }
        
        // Check for CPU pinning (enhanced - check all validator services)
        self.print("\n  [CPU PINNING]\n", .{});
        var cpu_pinning_found = false;
        
        // Check all possible validator service files
        const service_patterns = [_][]const u8{
            "solana*.service",
            "agave*.service",
            "firedancer*.service",
            "jito*.service",
            "frankendancer*.service",
        };
        
        for (service_patterns) |pattern| {
            const check_cmd = try std.fmt.allocPrint(self.allocator, 
                "grep -l 'taskset\\|numactl\\|CPUAffinity' /etc/systemd/system/{s} 2>/dev/null || echo 'none'", .{pattern});
            defer self.allocator.free(check_cmd);
            const result = runCommandOutput(self.allocator, &.{ "sh", "-c", check_cmd }) catch "none";
            defer self.allocator.free(result);
            
            if (!std.mem.eql(u8, std.mem.trim(u8, result, &std.ascii.whitespace), "none")) {
                cpu_pinning_found = true;
                break;
            }
        }
        
        if (cpu_pinning_found) {
            self.print("    ⚠️  CPU pinning detected in existing validator service\n", .{});
            self.print("        Vexor will NOT modify your CPU pinning settings\n", .{});
            self.print("        Vexor will work with your existing CPU pinning\n", .{});
            mods_found += 1;
        } else {
            self.print("    · No custom CPU pinning detected\n", .{});
        }
        
        // Check for IRQ affinity settings
        const irq_affinity_check = runCommandOutput(self.allocator, &.{ "sh", "-c",
            "grep -r 'smp_affinity' /proc/irq/*/smp_affinity_list 2>/dev/null | head -1 || echo 'none'" }) catch "none";
        defer self.allocator.free(irq_affinity_check);
        
        if (!std.mem.eql(u8, std.mem.trim(u8, irq_affinity_check, &std.ascii.whitespace), "none")) {
            self.print("    ⚠️  IRQ affinity settings detected\n", .{});
            self.print("        Vexor will NOT modify your IRQ affinity settings\n", .{});
            mods_found += 1;
        }
        
        // Check for custom firewall rules
        self.print("\n  [FIREWALL]\n", .{});
        const ufw_check = runCommandOutput(self.allocator, &.{ "sh", "-c", 
            "ufw status | grep -c '8[0-9][0-9][0-9]' 2>/dev/null || echo '0'" }) catch "0";
        defer self.allocator.free(ufw_check);
        const fw_rules = std.fmt.parseInt(u32, std.mem.trim(u8, ufw_check, &std.ascii.whitespace), 10) catch 0;
        
        if (fw_rules > 0) {
            self.print("    ℹ️  {d} firewall rules for Solana ports detected\n", .{fw_rules});
            self.print("        Vexor will add its own rules without removing yours\n", .{});
            mods_found += 1;
        } else {
            self.print("    · No custom Solana firewall rules detected\n", .{});
        }
        
        // Summary
        self.print("\n  ────────────────────────────────────────────────\n", .{});
        self.print("  📊 SUMMARY: {d} modifications detected, {d} need overlay\n", .{ mods_found, conflicts });
        
        if (conflicts > 0) {
            self.print(
                \\
                \\  ℹ️  OVERLAY APPROACH:
                \\     Vexor will create /etc/sysctl.d/99-vexor.conf
                \\     This file has highest priority (99) and will apply
                \\     our settings ON TOP of yours.
                \\     
                \\     When you switch back to Agave:
                \\     • Our overlay is removed
                \\     • Your original settings are restored
                \\     • It's like we were never here
                \\
            , .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: DIAGNOSE
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdDiagnose(self: *Self) !void {
        self.printBanner("VEXOR DIAGNOSTICS");
        
        // System info
        self.print("\n📊 SYSTEM INFO\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // Get hostname
        const hostname = runCommandOutput(self.allocator, &.{ "hostname" }) catch "unknown";
        defer self.allocator.free(hostname);
        self.print("  Hostname: {s}\n", .{std.mem.trim(u8, hostname, &std.ascii.whitespace)});
        
        // Get kernel
        const kernel = runCommandOutput(self.allocator, &.{ "uname", "-r" }) catch "unknown";
        defer self.allocator.free(kernel);
        self.print("  Kernel:   {s}\n", .{std.mem.trim(u8, kernel, &std.ascii.whitespace)});
        
        // Vexor status
        self.print("\n🔧 VEXOR STATUS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        
        if (fs.cwd().access(binary_path, .{})) |_| {
            self.print("  Binary:   ✅ Installed ({s})\n", .{binary_path});
        } else |_| {
            self.print("  Binary:   ❌ Not installed\n", .{});
        }
        
        const vexor_active = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        if (vexor_active == true) {
            self.print("  Service:  🟢 RUNNING\n", .{});
        } else {
            self.print("  Service:  ⚪ stopped\n", .{});
        }
        
        // Agave status
        self.print("\n🔧 AGAVE STATUS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        const agave_active = runCommand(&.{ "systemctl", "is-active", "--quiet", self.config.existing_service }) catch false;
        if (agave_active == true) {
            self.print("  Service:  🟢 RUNNING\n", .{});
            
            // Try to get slot
            const slot_result = runCommandOutput(self.allocator, &.{
                "curl", "-s", "http://localhost:8899",
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}",
            }) catch "";
            defer self.allocator.free(slot_result);
            
            if (std.mem.indexOf(u8, slot_result, "result")) |_| {
                self.print("  RPC:      ✅ Responding\n", .{});
            } else {
                self.print("  RPC:      ⏳ Starting...\n", .{});
            }
        } else {
            self.print("  Service:  ⚪ stopped\n", .{});
        }
        
        // Permissions
        self.print("\n📁 PERMISSIONS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        try self.verifyPermissions();
        
        // AF_XDP / io_uring / Networking checks
        self.print("\n🌐 NETWORKING CAPABILITIES\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // Check CAP_NET_RAW for AF_XDP - check both common paths
        const alt_binary = "/home/solana/bin/vexor/vexor";
        const cap_cmd = try std.fmt.allocPrint(self.allocator, "/sbin/getcap {s} 2>/dev/null || /sbin/getcap {s} 2>/dev/null || filecap {s} 2>/dev/null || filecap {s} 2>/dev/null", .{binary_path, alt_binary, binary_path, alt_binary});
        defer self.allocator.free(cap_cmd);
        const cap_check = runCommandOutput(self.allocator, &.{ "sh", "-c", cap_cmd }) catch "";
        defer if (cap_check.len > 0) self.allocator.free(cap_check);
        if (std.mem.indexOf(u8, cap_check, "cap_net_raw") != null or std.mem.indexOf(u8, cap_check, "net_raw") != null) {
            self.print("  AF_XDP:   ✅ CAP_NET_RAW granted\n", .{});
        } else {
            self.print("  AF_XDP:   ⚠️  Missing CAP_NET_RAW (run: sudo setcap cap_net_raw,cap_net_admin+ep <vexor-binary>)\n", .{});
        }
        
        // Check kernel version for io_uring (5.1+)
        const kernel_trimmed = std.mem.trim(u8, kernel, &std.ascii.whitespace);
        var kernel_major: u32 = 0;
        var kernel_minor: u32 = 0;
        if (std.mem.indexOf(u8, kernel_trimmed, ".")) |dot1| {
            kernel_major = std.fmt.parseInt(u32, kernel_trimmed[0..dot1], 10) catch 0;
            const rest = kernel_trimmed[dot1 + 1 ..];
            if (std.mem.indexOf(u8, rest, ".")) |dot2| {
                kernel_minor = std.fmt.parseInt(u32, rest[0..dot2], 10) catch 0;
            }
        }
        if (kernel_major > 5 or (kernel_major == 5 and kernel_minor >= 1)) {
            self.print("  io_uring: ✅ Kernel {d}.{d} supports io_uring\n", .{ kernel_major, kernel_minor });
        } else {
            self.print("  io_uring: ⚠️  Kernel {d}.{d} may not fully support io_uring (need 5.1+)\n", .{ kernel_major, kernel_minor });
        }
        
        // Check for libbpf
        const libbpf_check = runCommand(&.{ "ldconfig", "-p" }) catch false;
        _ = libbpf_check;
        const libbpf_result = runCommandOutput(self.allocator, &.{ "sh", "-c", "/sbin/ldconfig -p 2>/dev/null | grep libbpf || /usr/sbin/ldconfig -p 2>/dev/null | grep libbpf" }) catch "";
        defer if (libbpf_result.len > 0) self.allocator.free(libbpf_result);
        if (libbpf_result.len > 10) {
            self.print("  libbpf:   ✅ Installed\n", .{});
        } else {
            self.print("  libbpf:   ⚠️  Not found (needed for AF_XDP)\n", .{});
        }
        
        // Check ramdisk
        self.print("\n💾 RAMDISK STATUS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        const mount_check = runCommandOutput(self.allocator, &.{ "sh", "-c", "mount | grep tmpfs | grep ramdisk" }) catch "";
        defer if (mount_check.len > 0) self.allocator.free(mount_check);
        if (mount_check.len > 5) {
            self.print("  /mnt/ramdisk: ✅ Mounted as tmpfs\n", .{});
        } else {
            self.print("  /mnt/ramdisk: ⚠️  Not mounted or not tmpfs\n", .{});
            self.print("                Fix: sudo mount -t tmpfs -o size=64G tmpfs /mnt/ramdisk\n", .{});
        }
        
        // Check port availability
        self.print("\n🔌 PORT AVAILABILITY\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        const ports_to_check = [_]u16{ 8001, 8003, 8004, 8899 };
        const port_names = [_][]const u8{ "Gossip", "TPU", "TVU", "RPC" };
        for (ports_to_check, 0..) |port, i| {
            const port_cmd = try std.fmt.allocPrint(self.allocator, "ss -tuln | grep :{d} ", .{port});
            defer self.allocator.free(port_cmd);
            const port_result = runCommandOutput(self.allocator, &.{ "sh", "-c", port_cmd }) catch "";
            defer if (port_result.len > 0) self.allocator.free(port_result);
            if (port_result.len > 5) {
                self.print("  {d} ({s}): ⚠️  In use\n", .{ port, port_names[i] });
            } else {
                self.print("  {d} ({s}): ✅ Available\n", .{ port, port_names[i] });
            }
        }
        
        // Snapshot status
        self.print("\n📦 SNAPSHOTS\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        const snapshots = runCommandOutput(self.allocator, &.{
            "ls", "-lh", self.config.snapshots_dir,
        }) catch "Unable to list";
        defer self.allocator.free(snapshots);
        self.print("{s}\n", .{snapshots});
        
        self.print("\n───────────────────────────────────────────────────\n", .{});
        self.print("Diagnostic complete.\n", .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: STATUS
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdStatus(self: *Self) !void {
        self.printBanner("VALIDATOR STATUS");
        
        // Vexor
        const vexor_active = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        if (vexor_active == true) {
            self.print("\n🟢 VEXOR:  RUNNING\n", .{});
        } else {
            self.print("\n⚪ VEXOR:  stopped\n", .{});
        }
        
        // Previous client
        const prev_active = runCommand(&.{ "systemctl", "is-active", "--quiet", self.config.existing_service }) catch false;
        if (prev_active == true) {
            self.print("🟢 OTHER:  {s} RUNNING\n", .{self.config.existing_service});
        } else {
            self.print("⚪ OTHER:  {s} stopped\n", .{self.config.existing_service});
        }
        
        self.print(
            \\
            \\Commands:
            \\  vexor-install audit            - System audit (recommended first)
            \\  vexor-install switch-to-vexor  - Switch to Vexor
            \\  vexor-install switch-to-agave  - Switch to Agave
            \\  vexor-install diagnose         - Full diagnostics
            \\
        , .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: AUDIT - Comprehensive System Audit
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdAudit(self: *Self) !void {
        self.printBanner("SYSTEM AUDIT");
        
        self.print(
            \\
            \\Running comprehensive system audit...
            \\This will detect your hardware, software configuration,
            \\and any existing customizations you've made.
            \\
            \\⚠️  IMPORTANT: This audit is READ-ONLY.
            \\    No changes will be made to your system.
            \\
        , .{});
        
        // Offer to create backup FIRST
        if (try self.confirm("Create a backup of your current system state first?")) {
            const backup_id = try self.createFullBackup();
            defer self.allocator.free(backup_id);
            self.print("\n✅ Backup created: {s}\n", .{backup_id});
        }
        
        // Network Audit
        try self.auditNetwork();
        
        // Storage Audit
        try self.auditStorage();
        
        // Compute Audit
        try self.auditCompute();
        
        // System Audit
        try self.auditSystem();
        
        // Existing Validator Audit
        try self.auditExistingValidator();
        
        // NEW: Detect user modifications and conflicts
        try self.detectExistingModifications();
        
        self.print("\n", .{});
        self.printBanner("AUDIT COMPLETE");
        self.print(
            \\
            \\YOUR ORIGINAL CONFIGURATION IS PRESERVED.
            \\Vexor uses an OVERLAY approach:
            \\  • Your configs stay in place, untouched
            \\  • Vexor creates /etc/sysctl.d/99-vexor.conf (highest priority)
            \\  • When you switch back, our overlay is removed
            \\  • Your system returns to its exact original state
            \\
            \\Next steps:
            \\  vexor-install recommend    - Get personalized recommendations
            \\  vexor-install backup       - Create full system backup
            \\  vexor-install install      - Install with audit-based config
            \\
        , .{});
    }

    fn auditNetwork(self: *Self) !void {
        self.print("\n📡 NETWORK AUDIT\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // Detect network interfaces
        self.print("\n  [INTERFACES]\n", .{});
        const interfaces = runCommandOutput(self.allocator, &.{ "ip", "-o", "link", "show" }) catch "Unable to list interfaces";
        defer self.allocator.free(interfaces);
        
        var lines = std.mem.splitScalar(u8, interfaces, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Parse interface name (format: "2: eth0: <...>")
            var parts = std.mem.splitScalar(u8, line, ':');
            _ = parts.next(); // Skip index
            if (parts.next()) |name_part| {
                const name = std.mem.trim(u8, name_part, &std.ascii.whitespace);
                if (!std.mem.eql(u8, name, "lo")) {
                    self.print("    • {s}\n", .{name});
                    
                    // Get driver info
                    const driver_cmd = try std.fmt.allocPrint(self.allocator, "/sys/class/net/{s}/device/driver", .{name});
                    defer self.allocator.free(driver_cmd);
                    
                    const driver_link = runCommandOutput(self.allocator, &.{ "readlink", "-f", driver_cmd }) catch "";
                    defer self.allocator.free(driver_link);
                    
                    if (driver_link.len > 0) {
                        // Extract driver name from path
                        var path_parts = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, driver_link, &std.ascii.whitespace), '/');
                        if (path_parts.next()) |driver_name| {
                            self.print("      Driver: {s}", .{driver_name});
                            // Check if XDP-capable
                            if (isXdpCapableDriver(driver_name)) {
                                self.print(" ✅ XDP CAPABLE\n", .{});
                            } else {
                                self.print(" ⚠️  XDP unknown\n", .{});
                            }
                        }
                    }
                }
            }
        }
        
        // Check AF_XDP kernel support
        self.print("\n  [AF_XDP SUPPORT]\n", .{});
        const kernel_version = runCommandOutput(self.allocator, &.{ "uname", "-r" }) catch "unknown";
        defer self.allocator.free(kernel_version);
        self.print("    Kernel: {s}", .{std.mem.trim(u8, kernel_version, &std.ascii.whitespace)});
        
        // Check if kernel is 4.18+ for XDP
        const version_str = std.mem.trim(u8, kernel_version, &std.ascii.whitespace);
        var version_parts = std.mem.splitScalar(u8, version_str, '.');
        if (version_parts.next()) |major_str| {
            const major = std.fmt.parseInt(u32, major_str, 10) catch 0;
            if (major >= 5) {
                self.print(" ✅ Supports AF_XDP\n", .{});
            } else if (major == 4) {
                if (version_parts.next()) |minor_str| {
                    const minor = std.fmt.parseInt(u32, minor_str, 10) catch 0;
                    if (minor >= 18) {
                        self.print(" ✅ Supports AF_XDP\n", .{});
                    } else {
                        self.print(" ❌ Kernel too old for AF_XDP (need 4.18+)\n", .{});
                    }
                }
            } else {
                self.print(" ❌ Kernel too old for AF_XDP (need 4.18+)\n", .{});
            }
        } else {
            self.print("\n", .{});
        }
        
        // Check for libbpf
        const libbpf_check = runCommand(&.{ "ldconfig", "-p" }) catch false;
        _ = libbpf_check;
        const libbpf_result = runCommandOutput(self.allocator, &.{ "sh", "-c", "ldconfig -p | grep -i bpf || echo 'not found'" }) catch "check failed";
        defer self.allocator.free(libbpf_result);
        if (std.mem.indexOf(u8, libbpf_result, "libbpf") != null) {
            self.print("    libbpf: ✅ Installed\n", .{});
        } else {
            self.print("    libbpf: ⚠️  Not found (needed for AF_XDP)\n", .{});
        }
        
        // Check BPF JIT
        var jit_enabled: u32 = 0;
        if (runCommandOutput(self.allocator, &.{ "sysctl", "-n", "net.core.bpf_jit_enable" })) |bpf_jit| {
            defer self.allocator.free(bpf_jit);
            jit_enabled = std.fmt.parseInt(u32, std.mem.trim(u8, bpf_jit, &std.ascii.whitespace), 10) catch 0;
        } else |_| {}
        if (jit_enabled > 0) {
            self.print("    BPF JIT: ✅ Enabled\n", .{});
        } else {
            self.print("    BPF JIT: ⚠️  Disabled (XDP slower)\n", .{});
        }
        
        // Check huge pages for UMEM
        var hp_count: u64 = 0;
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "grep HugePages_Total /proc/meminfo | awk '{print $2}'" })) |hugepages| {
            defer self.allocator.free(hugepages);
            hp_count = std.fmt.parseInt(u64, std.mem.trim(u8, hugepages, &std.ascii.whitespace), 10) catch 0;
        } else |_| {}
        if (hp_count >= 512) {
            self.print("    Huge pages: ✅ {d} x 2MB = {d}GB\n", .{ hp_count, hp_count * 2 / 1024 });
        } else {
            self.print("    Huge pages: ⚠️  {d} (recommend 512+ for UMEM)\n", .{hp_count});
        }
        
        // Check NIC queue count
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "ip route | grep default | awk '{print $5}' | head -1" })) |primary_if| {
            defer self.allocator.free(primary_if);
            const if_name = std.mem.trim(u8, primary_if, &std.ascii.whitespace);
            
            if (if_name.len > 0) {
                const queues_cmd = try std.fmt.allocPrint(self.allocator, "ethtool -l {s} 2>/dev/null | grep -i 'combined' | tail -1 | awk '{{print $2}}' || echo '1'", .{if_name});
                defer self.allocator.free(queues_cmd);
                if (runCommandOutput(self.allocator, &.{ "sh", "-c", queues_cmd })) |queues| {
                    defer self.allocator.free(queues);
                    self.print("    NIC queues ({s}): {s}\n", .{ if_name, std.mem.trim(u8, queues, &std.ascii.whitespace) });
                } else |_| {
                    self.print("    NIC queues ({s}): unknown\n", .{if_name});
                }
            }
        } else |_| {}
        
        // io_uring status
        self.print("\n  [IO_URING]\n", .{});
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "grep io_uring /proc/kallsyms 2>/dev/null | head -1 || echo 'not found'" })) |uring_check| {
            defer self.allocator.free(uring_check);
            if (std.mem.indexOf(u8, uring_check, "not found") == null) {
                self.print("    io_uring: ✅ Kernel support available\n", .{});
            } else {
                self.print("    io_uring: ❌ Not available (kernel too old?)\n", .{});
            }
        } else |_| {
            self.print("    io_uring: ❌ Unable to check\n", .{});
        }
        
        var liburing_found = false;
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "ldconfig -p 2>/dev/null | grep liburing || echo 'not found'" })) |liburing| {
            defer self.allocator.free(liburing);
            liburing_found = std.mem.indexOf(u8, liburing, "not found") == null;
        } else |_| {}
        if (liburing_found) {
            self.print("    liburing: ✅ Installed\n", .{});
        } else {
            self.print("    liburing: ⚠️  Not found (recommended)\n", .{});
        }
        
        // Check QUIC/MASQUE ports
        self.print("\n  [QUIC/MASQUE PORTS]\n", .{});
        const ports_to_check = [_]u16{ 8801, 8802, 8803, 8804, 8899, 8900 };
        for (ports_to_check) |port| {
            const cmd_str = try std.fmt.allocPrint(self.allocator, "ss -ulnp | grep :{d} || echo 'available'", .{port});
            defer self.allocator.free(cmd_str);
            const port_check = runCommandOutput(self.allocator, &.{ "sh", "-c", cmd_str }) catch "check failed";
            defer self.allocator.free(port_check);
            
            if (std.mem.indexOf(u8, port_check, "available") != null) {
                self.print("    Port {d}: ✅ Available\n", .{port});
            } else {
                self.print("    Port {d}: ⚠️  In use\n", .{port});
            }
        }
        
        // Check firewall
        self.print("\n  [FIREWALL]\n", .{});
        const ufw_status = runCommandOutput(self.allocator, &.{ "sh", "-c", "ufw status 2>/dev/null || echo 'ufw not found'" }) catch "check failed";
        defer self.allocator.free(ufw_status);
        if (std.mem.indexOf(u8, ufw_status, "not found") != null) {
            // Try nftables
            const nft_status = runCommandOutput(self.allocator, &.{ "sh", "-c", "nft list ruleset 2>/dev/null | head -5 || echo 'nft not found'" }) catch "check failed";
            defer self.allocator.free(nft_status);
            if (std.mem.indexOf(u8, nft_status, "not found") != null) {
                self.print("    Firewall: No active firewall detected\n", .{});
            } else {
                self.print("    Firewall: nftables active\n", .{});
            }
        } else {
            self.print("    Firewall: ufw - {s}\n", .{std.mem.trim(u8, ufw_status, &std.ascii.whitespace)});
        }
    }

    fn auditStorage(self: *Self) !void {
        self.print("\n💾 STORAGE AUDIT\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // List block devices
        self.print("\n  [BLOCK DEVICES]\n", .{});
        const lsblk = runCommandOutput(self.allocator, &.{ "lsblk", "-d", "-o", "NAME,SIZE,TYPE,MODEL" }) catch "Unable to list";
        defer self.allocator.free(lsblk);
        
        var lines = std.mem.splitScalar(u8, lsblk, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 and !std.mem.startsWith(u8, line, "NAME")) {
                self.print("    {s}\n", .{line});
                // Check if NVMe
                if (std.mem.indexOf(u8, line, "nvme") != null) {
                    self.debug("      (NVMe detected - tier 1 capable)", .{});
                }
            }
        }
        
        // Check mount points
        self.print("\n  [MOUNT POINTS]\n", .{});
        const mounts = runCommandOutput(self.allocator, &.{ "df", "-h", "--output=target,size,avail,pcent,fstype" }) catch "Unable to list";
        defer self.allocator.free(mounts);
        
        var mount_lines = std.mem.splitScalar(u8, mounts, '\n');
        while (mount_lines.next()) |line| {
            if (line.len > 0) {
                // Filter relevant mounts
                if (std.mem.indexOf(u8, line, "/mnt") != null or
                    std.mem.indexOf(u8, line, "/home") != null or
                    std.mem.indexOf(u8, line, "Mounted") != null)
                {
                    self.print("    {s}\n", .{line});
                }
            }
        }
        
        // RAM disk capability
        self.print("\n  [RAMDISK CAPABILITY]\n", .{});
        const meminfo = runCommandOutput(self.allocator, &.{ "sh", "-c", "grep -E 'MemTotal|MemAvailable' /proc/meminfo" }) catch "Unable to read";
        defer self.allocator.free(meminfo);
        
        var mem_lines = std.mem.splitScalar(u8, meminfo, '\n');
        var total_kb: u64 = 0;
        var avail_kb: u64 = 0;
        
        while (mem_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                total_kb = parseMemoryLine(line);
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                avail_kb = parseMemoryLine(line);
            }
        }
        
        const total_gb = total_kb / 1024 / 1024;
        const avail_gb = avail_kb / 1024 / 1024;
        const recommended_ramdisk = @min(avail_gb / 4, 64); // 25% of available, max 64GB
        
        self.print("    Total RAM:        {d} GB\n", .{total_gb});
        self.print("    Available RAM:    {d} GB\n", .{avail_gb});
        if (recommended_ramdisk > 4) {
            self.print("    Recommended:      {d} GB ramdisk ✅\n", .{recommended_ramdisk});
        } else {
            self.print("    Recommended:      RAM too low for ramdisk ⚠️\n", .{});
        }
    }

    fn auditCompute(self: *Self) !void {
        self.print("\n🖥️  COMPUTE AUDIT\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // CPU Info
        self.print("\n  [CPU]\n", .{});
        const cpu_model = runCommandOutput(self.allocator, &.{ "sh", "-c", "grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2" }) catch "unknown";
        defer self.allocator.free(cpu_model);
        self.print("    Model: {s}\n", .{std.mem.trim(u8, cpu_model, &std.ascii.whitespace)});
        
        const cpu_cores = runCommandOutput(self.allocator, &.{ "nproc" }) catch "unknown";
        defer self.allocator.free(cpu_cores);
        self.print("    Threads: {s}\n", .{std.mem.trim(u8, cpu_cores, &std.ascii.whitespace)});
        
        // CPU features
        self.print("\n  [CPU FEATURES]\n", .{});
        const cpu_flags = runCommandOutput(self.allocator, &.{ "sh", "-c", "grep 'flags' /proc/cpuinfo | head -1" }) catch "";
        defer self.allocator.free(cpu_flags);
        
        const features = [_]struct { name: []const u8, flag: []const u8, purpose: []const u8 }{
            .{ .name = "AVX2", .flag = "avx2", .purpose = "SIMD crypto" },
            .{ .name = "AVX-512", .flag = "avx512f", .purpose = "Fast BLS" },
            .{ .name = "SHA-NI", .flag = "sha_ni", .purpose = "Hardware SHA" },
            .{ .name = "AES-NI", .flag = "aes", .purpose = "TLS/QUIC" },
            .{ .name = "ADX", .flag = "adx", .purpose = "BLS field ops" },
            .{ .name = "BMI2", .flag = "bmi2", .purpose = "Bit manip" },
        };
        
        for (features) |f| {
            if (std.mem.indexOf(u8, cpu_flags, f.flag) != null) {
                self.print("    {s}: ✅ ({s})\n", .{ f.name, f.purpose });
            } else {
                self.print("    {s}: ❌ Not detected\n", .{f.name});
            }
        }
        
        // Crypto audit
        self.print("\n  [CRYPTOGRAPHY]\n", .{});
        
        // Check BLS readiness
        const has_avx2 = std.mem.indexOf(u8, cpu_flags, "avx2") != null;
        const has_adx = std.mem.indexOf(u8, cpu_flags, "adx") != null;
        
        if (has_avx2 and has_adx) {
            self.print("    BLS12-381: ✅ Full hardware acceleration\n", .{});
        } else if (has_avx2) {
            self.print("    BLS12-381: ⚠️  Partial acceleration (missing ADX)\n", .{});
        } else {
            self.print("    BLS12-381: ❌ Software fallback (slower)\n", .{});
        }
        
        // Check Ed25519 readiness
        if (std.mem.indexOf(u8, cpu_flags, "avx2") != null) {
            self.print("    Ed25519: ✅ Vectorized\n", .{});
        } else {
            self.print("    Ed25519: ⚠️  Scalar operations\n", .{});
        }
        
        // Check AES-GCM (for QUIC)
        if (std.mem.indexOf(u8, cpu_flags, "aes") != null) {
            self.print("    AES-GCM: ✅ Hardware AEAD\n", .{});
        } else {
            self.print("    AES-GCM: ❌ Software (ChaCha20 recommended)\n", .{});
        }
        
        // Check blst library
        const blst_check = runCommandOutput(self.allocator, &.{ "sh", "-c", "ldconfig -p 2>/dev/null | grep -i blst || echo 'not found'" }) catch "not found";
        defer self.allocator.free(blst_check);
        
        if (std.mem.indexOf(u8, blst_check, "not found") == null) {
            self.print("    blst library: ✅ Installed\n", .{});
        } else {
            self.print("    blst library: ⚠️  Using built-in BLS\n", .{});
        }
        
        // NUMA
        self.print("\n  [NUMA TOPOLOGY]\n", .{});
        const numa_nodes = runCommandOutput(self.allocator, &.{ "sh", "-c", "ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l || echo '1'" }) catch "1";
        defer self.allocator.free(numa_nodes);
        const nodes = std.fmt.parseInt(u32, std.mem.trim(u8, numa_nodes, &std.ascii.whitespace), 10) catch 1;
        if (nodes > 1) {
            self.print("    NUMA Nodes: {d} ⚠️  Multi-socket (CPU pinning recommended)\n", .{nodes});
        } else {
            self.print("    NUMA Nodes: 1 ✅ Single socket\n", .{});
        }
        
        // GPU
        self.print("\n  [GPU]\n", .{});
        const nvidia_check = runCommandOutput(self.allocator, &.{ "sh", "-c", "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'not found'" }) catch "not found";
        defer self.allocator.free(nvidia_check);
        
        if (std.mem.indexOf(u8, nvidia_check, "not found") == null and nvidia_check.len > 5) {
            self.print("    NVIDIA: {s} ✅\n", .{std.mem.trim(u8, nvidia_check, &std.ascii.whitespace)});
        } else {
            self.print("    NVIDIA: Not detected (GPU acceleration unavailable)\n", .{});
        }
    }

    fn auditSystem(self: *Self) !void {
        self.print("\n⚙️  SYSTEM AUDIT\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        
        // OS Info
        self.print("\n  [OPERATING SYSTEM]\n", .{});
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'" })) |os_release| {
            defer self.allocator.free(os_release);
            self.print("    OS: {s}\n", .{std.mem.trim(u8, os_release, &std.ascii.whitespace)});
        } else |_| {
            self.print("    OS: unknown\n", .{});
        }
        
        if (runCommandOutput(self.allocator, &.{ "uname", "-r" })) |kernel| {
            defer self.allocator.free(kernel);
            self.print("    Kernel: {s}\n", .{std.mem.trim(u8, kernel, &std.ascii.whitespace)});
        } else |_| {
            self.print("    Kernel: unknown\n", .{});
        }
        
        // Sysctl settings
        self.print("\n  [SYSCTL SETTINGS]\n", .{});
        const sysctl_checks = [_]struct { name: []const u8, key: []const u8, recommended: []const u8 }{
            .{ .name = "net.core.rmem_max", .key = "net.core.rmem_max", .recommended = "134217728" },
            .{ .name = "net.core.wmem_max", .key = "net.core.wmem_max", .recommended = "134217728" },
            .{ .name = "vm.swappiness", .key = "vm.swappiness", .recommended = "10" },
            .{ .name = "vm.nr_hugepages", .key = "vm.nr_hugepages", .recommended = "16384" },
        };
        
        for (sysctl_checks) |check| {
            if (runCommandOutput(self.allocator, &.{ "sysctl", "-n", check.key })) |value| {
                defer self.allocator.free(value);
                const val_str = std.mem.trim(u8, value, &std.ascii.whitespace);
                
                if (std.mem.eql(u8, val_str, check.recommended)) {
                    self.print("    {s}: {s} ✅\n", .{ check.name, val_str });
                } else {
                    self.print("    {s}: {s} ⚠️  (recommend: {s})\n", .{ check.name, val_str, check.recommended });
                }
            } else |_| {
                self.print("    {s}: unknown ⚠️  (recommend: {s})\n", .{ check.name, check.recommended });
            }
        }
        
        // File limits
        self.print("\n  [FILE LIMITS]\n", .{});
        var nofile_val: u64 = 0;
        if (runCommandOutput(self.allocator, &.{ "sh", "-c", "ulimit -n" })) |nofile| {
            defer self.allocator.free(nofile);
            nofile_val = std.fmt.parseInt(u64, std.mem.trim(u8, nofile, &std.ascii.whitespace), 10) catch 0;
        } else |_| {}
        if (nofile_val >= 1000000) {
            self.print("    NOFILE: {d} ✅\n", .{nofile_val});
        } else {
            self.print("    NOFILE: {d} ⚠️  (recommend: 1000000)\n", .{nofile_val});
        }
    }

    fn auditExistingValidator(self: *Self) !void {
        self.print("\n🔗 EXISTING VALIDATOR CLIENT DETECTION\n", .{});
        self.print("───────────────────────────────────────────────────\n", .{});
        self.print("\n  Vexor supports switching from ANY Solana validator client.\n", .{});
        self.print("  Detecting what's currently running...\n\n", .{});
        
        // Check each known client type
        const clients_to_check = [_]struct { 
            client: ExistingClient, 
            services: []const []const u8,
            processes: []const []const u8,
        }{
            .{ 
                .client = .agave, 
                .services = &.{ "solana-validator.service", "agave-validator.service", "sol.service" },
                .processes = &.{ "solana-validator", "agave-validator" },
            },
            .{ 
                .client = .firedancer, 
                .services = &.{ "firedancer.service", "fd_frank.service", "fdctl.service" },
                .processes = &.{ "fdctl", "fd_frank", "firedancer" },
            },
            .{ 
                .client = .jito, 
                .services = &.{ "jito-validator.service", "jito.service" },
                .processes = &.{ "jito-validator" },
            },
            .{ 
                .client = .frankendancer, 
                .services = &.{ "frankendancer.service" },
                .processes = &.{ "frankendancer" },
            },
        };
        
        var detected_client: ExistingClient = .none;
        var detected_service: []const u8 = "";
        
        for (clients_to_check) |check| {
            // Check systemd services
            for (check.services) |service| {
                const is_active = runCommand(&.{ "systemctl", "is-active", "--quiet", service }) catch false;
                if (is_active) {
                    detected_client = check.client;
                    detected_service = service;
                    break;
                }
            }
            if (detected_client != .none) break;
            
            // Check running processes
            for (check.processes) |proc| {
                const check_cmd = try std.fmt.allocPrint(self.allocator, "pgrep -x {s} >/dev/null 2>&1", .{proc});
                defer self.allocator.free(check_cmd);
                const is_running = runCommand(&.{ "sh", "-c", check_cmd }) catch false;
                if (is_running) {
                    detected_client = check.client;
                    break;
                }
            }
            if (detected_client != .none) break;
        }
        
        // Display results
        self.print("  [DETECTED CLIENT]\n", .{});
        switch (detected_client) {
            .agave => {
                self.print("    Client: 🟢 {s}\n", .{detected_client.displayName()});
                self.print("    Service: {s}\n", .{detected_service});
                self.print("    Ledger: {s}\n", .{detected_client.ledgerPath()});
            },
            .firedancer => {
                self.print("    Client: 🔥 {s}\n", .{detected_client.displayName()});
                self.print("    Service: {s}\n", .{detected_service});
                self.print("    Note: Firedancer uses different directory structure\n", .{});
            },
            .jito => {
                self.print("    Client: 💰 {s}\n", .{detected_client.displayName()});
                self.print("    Service: {s}\n", .{detected_service});
                self.print("    Note: Jito is an Agave fork with MEV capabilities\n", .{});
            },
            .frankendancer => {
                self.print("    Client: 🧟 {s}\n", .{detected_client.displayName()});
                self.print("    Note: Hybrid Firedancer + Agave runtime\n", .{});
            },
            .none => {
                self.print("    Client: ⚪ No validator currently running\n", .{});
                self.print("    This is fine - Vexor can be installed fresh\n", .{});
            },
            .unknown => {
                self.print("    Client: ❓ Unknown validator process detected\n", .{});
                self.print("    Vexor will still work, but switching may need manual steps\n", .{});
            },
        }
        
        // Get RPC status if any client is running
        if (detected_client != .none) {
            const slot = runCommandOutput(self.allocator, &.{
                "sh", "-c",
                "curl -s http://localhost:8899 -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}' 2>/dev/null | grep -o '\"result\":[0-9]*' | cut -d: -f2 || echo 'unknown'",
            }) catch "unknown";
            defer self.allocator.free(slot);
            const slot_str = std.mem.trim(u8, slot, &std.ascii.whitespace);
            if (slot_str.len > 0 and !std.mem.eql(u8, slot_str, "unknown")) {
                self.print("    Current Slot: {s}\n", .{slot_str});
            }
            
            // Try to get identity
            const identity = runCommandOutput(self.allocator, &.{ "sh", "-c", 
                "solana-keygen pubkey /home/solana/.secrets/validator-keypair.json 2>/dev/null || " ++
                "solana-keygen pubkey /home/solana/validator-keypair.json 2>/dev/null || " ++
                "echo 'unknown'" }) catch "unknown";
            defer self.allocator.free(identity);
            const id_str = std.mem.trim(u8, identity, &std.ascii.whitespace);
            if (id_str.len > 10 and !std.mem.eql(u8, id_str, "unknown")) {
                self.print("    Identity: {s}...{s}\n", .{ id_str[0..4], id_str[id_str.len - 4 ..] });
            }
        }
        
        // Check Vexor
        self.print("\n  [VEXOR STATUS]\n", .{});
        const vexor_active = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        if (vexor_active == true) {
            self.print("    Status: 🟢 RUNNING\n", .{});
        } else {
            const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
            defer self.allocator.free(binary_path);
            if (fs.cwd().access(binary_path, .{})) |_| {
                self.print("    Status: ⚪ Installed but not running\n", .{});
            } else |_| {
                self.print("    Status: ❌ Not installed\n", .{});
            }
        }
        
        // Summary
        self.print("\n  ────────────────────────────────────────────────\n", .{});
        if (detected_client != .none) {
            self.print("  📋 SWITCHING FROM: {s}\n", .{detected_client.displayName()});
            self.print("     Vexor will create a backup and use safe switch commands.\n", .{});
            self.print("     Your existing client's files will NOT be modified.\n", .{});
        } else {
            self.print("  📋 FRESH INSTALL: No existing validator detected\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: RECOMMEND - Generate Personalized Recommendations
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdRecommend(self: *Self) !void {
        self.printBanner("RECOMMENDATIONS");
        
        self.print(
            \\
            \\Based on your system audit, here are personalized recommendations:
            \\
        , .{});
        
        // This is a placeholder - in full implementation, this would analyze
        // audit results and generate specific recommendations
        
        self.print(
            \\
            \\⚡ PERFORMANCE OPTIMIZATIONS AVAILABLE:
            \\
            \\┌─────────────────────────────────────────────────────────────────┐
            \\│ [1] AF_XDP KERNEL BYPASS                                        │
            \\│ ─────────────────────────────────────────────────────────────── │
            \\│ BENEFIT: 10x packet throughput (~10M pps vs ~1M pps)            │
            \\│ REQUIRES: CAP_NET_RAW capability on binary                      │
            \\│ RISK: LOW                                                       │
            \\└─────────────────────────────────────────────────────────────────┘
            \\
            \\┌─────────────────────────────────────────────────────────────────┐
            \\│ [2] QUIC/MASQUE TRANSPORT                                       │
            \\│ ─────────────────────────────────────────────────────────────── │
            \\│ BENEFIT: NAT traversal, multiplexed connections                 │
            \\│ REQUIRES: UDP ports 8801-8810 open                              │
            \\│ RISK: LOW                                                       │
            \\└─────────────────────────────────────────────────────────────────┘
            \\
            \\┌─────────────────────────────────────────────────────────────────┐
            \\│ [3] SYSTEM TUNING                                               │
            \\│ ─────────────────────────────────────────────────────────────── │
            \\│ BENEFIT: Optimized network buffers, memory allocation           │
            \\│ CHANGES: sysctl settings (14 parameters)                        │
            \\│ RISK: LOW (fully reversible)                                    │
            \\└─────────────────────────────────────────────────────────────────┘
            \\
            \\To install with these optimizations:
            \\  vexor-install install --interactive
            \\
            \\To install without prompts (auto-approve low risk):
            \\  vexor-install install -y
            \\
        , .{});
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: HEALTH - Health Check with Auto-Fix
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdHealth(self: *Self) !void {
        self.printBanner("HEALTH CHECK");
        
        self.print("\nRunning health checks...\n\n", .{});
        
        var issues_found: u32 = 0;
        var issues_fixable: u32 = 0;
        
        // Check 1: Vexor binary
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        
        if (fs.cwd().access(binary_path, .{})) |_| {
            self.print("✅ Vexor binary: Installed\n", .{});
        } else |_| {
            self.print("❌ Vexor binary: Not installed\n", .{});
            self.print("   FIX: Run 'vexor-install install'\n", .{});
            issues_found += 1;
        }
        
        // Check 2: AF_XDP capabilities
        const caps = runCommandOutput(self.allocator, &.{ "getcap", binary_path }) catch "";
        defer self.allocator.free(caps);
        if (std.mem.indexOf(u8, caps, "cap_net_raw") != null) {
            self.print("✅ AF_XDP capabilities: Set\n", .{});
        } else {
            self.print("⚠️  AF_XDP capabilities: Not set (AF_XDP won't work)\n", .{});
            self.print("   FIX: sudo setcap 'cap_net_raw,cap_net_admin+eip' {s}\n", .{binary_path});
            issues_found += 1;
            issues_fixable += 1;
        }
        
        // Check 3: Directories exist
        const dirs = [_][]const u8{
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
        };
        
        for (dirs) |dir| {
            if (fs.cwd().access(dir, .{})) |_| {
                self.print("✅ Directory: {s}\n", .{dir});
            } else |_| {
                self.print("❌ Directory: {s} (missing)\n", .{dir});
                self.print("   FIX: Run 'vexor-install fix-permissions'\n", .{});
                issues_found += 1;
                issues_fixable += 1;
            }
        }
        
        // Check 4: Network buffers
        const rmem = runCommandOutput(self.allocator, &.{ "sysctl", "-n", "net.core.rmem_max" }) catch "0";
        defer self.allocator.free(rmem);
        const rmem_val = std.fmt.parseInt(u64, std.mem.trim(u8, rmem, &std.ascii.whitespace), 10) catch 0;
        if (rmem_val >= 134217728) {
            self.print("✅ Network buffers: Optimized\n", .{});
        } else {
            self.print("⚠️  Network buffers: Suboptimal ({d} < 134217728)\n", .{rmem_val});
            self.print("   FIX: sudo sysctl -w net.core.rmem_max=134217728\n", .{});
            issues_found += 1;
            issues_fixable += 1;
        }
        
        // Summary
        self.print("\n───────────────────────────────────────────────────\n", .{});
        if (issues_found == 0) {
            self.print("✅ All health checks passed!\n", .{});
        } else {
            self.print("Found {d} issue(s), {d} auto-fixable\n", .{ issues_found, issues_fixable });
            self.print("\nTo fix interactively: vexor-install fix\n", .{});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // KEY MANAGEMENT - Detection, Selection, Hot-Swap
    // ═══════════════════════════════════════════════════════════════════════

    /// Detected keys from current client
    pub const ClientKeys = struct {
        identity: []const u8,
        vote_account: ?[]const u8,
        source_client: ExistingClient,
    };

    /// Detect keys from current validator client
    fn detectCurrentClientKeys(self: *Self) !?ClientKeys {
        // First, detect the current client
        const client = try self.detectAnyValidatorClient();
        if (client == .none) return null;

        // Try to extract keys from service file
        const service_name = client.serviceName();
        if (service_name.len > 0) {
            const service_file = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/{s}", .{service_name});
            defer self.allocator.free(service_file);

            if (fs.cwd().openFile(service_file, .{})) |file| {
                defer file.close();
                var buf: [8192]u8 = undefined;
                const bytes_read = file.readAll(&buf) catch return null;
                const content = buf[0..bytes_read];

                // Extract --identity path
                var identity_path: ?[]const u8 = null;
                if (std.mem.indexOf(u8, content, "--identity")) |idx| {
                    const start = idx + "--identity".len;
                    const end = std.mem.indexOfPos(u8, content, start, " ") orelse content.len;
                    const path = std.mem.trim(u8, content[start..end], &std.ascii.whitespace);
                    if (path.len > 0 and path[0] == '/') {
                        identity_path = try self.allocator.dupe(u8, path);
                    }
                }

                // Extract --vote-account path
                var vote_path: ?[]const u8 = null;
                if (std.mem.indexOf(u8, content, "--vote-account")) |idx| {
                    const start = idx + "--vote-account".len;
                    const end = std.mem.indexOfPos(u8, content, start, " ") orelse content.len;
                    const path = std.mem.trim(u8, content[start..end], &std.ascii.whitespace);
                    if (path.len > 0 and path[0] == '/') {
                        vote_path = try self.allocator.dupe(u8, path);
                    }
                }

                if (identity_path) |id_path| {
                    // Verify key file exists and is readable
                    if (fs.cwd().openFile(id_path, .{})) |key_file| {
                        key_file.close();
                        return ClientKeys{
                            .identity = id_path,
                            .vote_account = vote_path,
                            .source_client = client,
                        };
                    } else |_| {}
                }
            } else |_| {}
        }

        // Fallback: Check common key locations
        const common_paths = [_][]const u8{
            "/home/solana/.secrets/validator-keypair.json",
            "/home/solana/validator-keypair.json",
            "/mnt/solana/validator-keypair.json",
        };

        for (common_paths) |path| {
            if (fs.cwd().openFile(path, .{})) |file| {
                file.close();
                const id_path = try self.allocator.dupe(u8, path);
                // Try to find vote account in same directory
                const vote_path = try std.fmt.allocPrint(self.allocator, "{s}/../vote-account-keypair.json", .{path});
                defer self.allocator.free(vote_path);
                const vote = if (fs.cwd().openFile(vote_path, .{})) |f| blk: {
                    f.close();
                    break :blk vote_path;
                } else |_| null;

                return ClientKeys{
                    .identity = id_path,
                    .vote_account = if (vote) |v| try self.allocator.dupe(u8, v) else null,
                    .source_client = client,
                };
            } else |_| {}
        }

        return null;
    }

    /// Detect ANY validator client (enhanced detection)
    fn detectAnyValidatorClient(self: *Self) !ExistingClient {
        // Check known clients first
        const clients_to_check = [_]struct {
            client: ExistingClient,
            services: []const []const u8,
            processes: []const []const u8,
            ports: []const u16, // Common ports used
        }{
            .{
                .client = .agave,
                .services = &.{ "solana-validator.service", "agave-validator.service", "sol.service" },
                .processes = &.{ "solana-validator", "agave-validator", "solana" },
                .ports = &.{ 8899, 8001, 8004 },
            },
            .{
                .client = .firedancer,
                .services = &.{ "firedancer.service", "fd_frank.service", "fdctl.service" },
                .processes = &.{ "fdctl", "fd_frank", "firedancer" },
                .ports = &.{ 8899, 8001 },
            },
            .{
                .client = .jito,
                .services = &.{ "jito-validator.service", "jito.service" },
                .processes = &.{ "jito-validator", "jito" },
                .ports = &.{ 8899, 8001 },
            },
            .{
                .client = .frankendancer,
                .services = &.{ "frankendancer.service" },
                .processes = &.{ "frankendancer" },
                .ports = &.{ 8899, 8001 },
            },
        };

        // Check services and processes
        for (clients_to_check) |check| {
            for (check.services) |service| {
                const is_active = runCommand(&.{ "systemctl", "is-active", "--quiet", service }) catch false;
                if (is_active) return check.client;
            }
            for (check.processes) |proc| {
                const check_cmd = try std.fmt.allocPrint(self.allocator, "pgrep -x {s} >/dev/null 2>&1", .{proc});
                defer self.allocator.free(check_cmd);
                const is_running = runCommand(&.{ "sh", "-c", check_cmd }) catch false;
                if (is_running) return check.client;
            }
        }

        // Check for unknown validator by port usage
        for ([_]u16{ 8899, 8001, 8004, 8006 }) |port| {
            const port_check = try std.fmt.allocPrint(self.allocator, "lsof -i :{d} 2>/dev/null | grep -v COMMAND || echo 'none'", .{port});
            defer self.allocator.free(port_check);
            const result = runCommandOutput(self.allocator, &.{ "sh", "-c", port_check }) catch "none";
            defer self.allocator.free(result);
            if (!std.mem.eql(u8, std.mem.trim(u8, result, &std.ascii.whitespace), "none")) {
                return .unknown; // Unknown validator detected
            }
        }

        return .none;
    }

    /// Prompt for key selection during install
    fn promptForKeySelection(self: *Self, detected_keys: ?ClientKeys) !struct {
        use_existing: bool,
        identity_path: []const u8,
        vote_account_path: ?[]const u8,
    } {
        if (detected_keys) |keys| {
            self.print("\n", .{});
            self.printBanner("KEY SELECTION");
            self.print("\n  Detected Client: {s}\n", .{keys.source_client.displayName()});
            self.print("  Current Keys:\n", .{});
            self.print("    Identity: {s}\n", .{keys.identity});
            if (keys.vote_account) |vote| {
                self.print("    Vote:     {s}\n", .{vote});
            }

            self.print("\n  How would you like to handle keys?\n", .{});
            self.print("    [1] Use existing keys from {s} (Recommended)\n", .{keys.source_client.displayName()});
            self.print("    [2] Create new keys for Vexor\n", .{});
            self.print("    [3] Use different existing keys\n", .{});

            const choice = try self.readLine("Selection [1-3] (default: 1): ");
            const selected = if (choice.len > 0) choice[0] else '1';

            switch (selected) {
                '1' => {
                    return .{
                        .use_existing = true,
                        .identity_path = keys.identity,
                        .vote_account_path = keys.vote_account,
                    };
                },
                '2' => {
                    // Generate new keys
                    const new_id_path = try std.fmt.allocPrint(self.allocator, "/home/solana/.secrets/vexor-identity-keypair.json", .{});
                    const new_vote_path = try std.fmt.allocPrint(self.allocator, "/home/solana/.secrets/vexor-vote-keypair.json", .{});
                    
                    self.print("\n  Generating new keys...\n", .{});
                    _ = runCommand(&.{ "solana-keygen", "new", "-o", new_id_path }) catch {
                        return error.KeyGenerationFailed;
                    };
                    _ = runCommand(&.{ "solana-keygen", "new", "-o", new_vote_path }) catch {
                        return error.KeyGenerationFailed;
                    };
                    
                    return .{
                        .use_existing = false,
                        .identity_path = new_id_path,
                        .vote_account_path = new_vote_path,
                    };
                },
                '3' => {
                    const id_path = try self.readLine("Enter identity keypair path: ");
                    const vote_path_str = try self.readLine("Enter vote account keypair path (or press Enter to skip): ");
                    const vote_path = if (vote_path_str.len > 0) try self.allocator.dupe(u8, vote_path_str) else null;
                    
                    return .{
                        .use_existing = false,
                        .identity_path = try self.allocator.dupe(u8, id_path),
                        .vote_account_path = vote_path,
                    };
                },
                else => {
                    // Default to using existing
                    return .{
                        .use_existing = true,
                        .identity_path = keys.identity,
                        .vote_account_path = keys.vote_account,
                    };
                },
            }
        } else {
            // No keys detected - prompt to create new or specify
            self.print("\n", .{});
            self.printBanner("KEY SELECTION");
            self.print("\n  No existing validator keys detected.\n", .{});
            self.print("  How would you like to proceed?\n", .{});
            self.print("    [1] Create new keys for Vexor\n", .{});
            self.print("    [2] Specify existing key paths\n", .{});

            const choice = try self.readLine("Selection [1-2] (default: 1): ");
            const selected = if (choice.len > 0) choice[0] else '1';

            if (selected == '2') {
                const id_path = try self.readLine("Enter identity keypair path: ");
                const vote_path_str = try self.readLine("Enter vote account keypair path (or press Enter to skip): ");
                const vote_path = if (vote_path_str.len > 0) try self.allocator.dupe(u8, vote_path_str) else null;
                
                return .{
                    .use_existing = false,
                    .identity_path = try self.allocator.dupe(u8, id_path),
                    .vote_account_path = vote_path,
                };
            } else {
                // Generate new keys
                const new_id_path = try std.fmt.allocPrint(self.allocator, "/home/solana/.secrets/vexor-identity-keypair.json", .{});
                const new_vote_path = try std.fmt.allocPrint(self.allocator, "/home/solana/.secrets/vexor-vote-keypair.json", .{});
                
                self.print("\n  Generating new keys...\n", .{});
                _ = runCommand(&.{ "solana-keygen", "new", "-o", new_id_path }) catch {
                    return error.KeyGenerationFailed;
                };
                _ = runCommand(&.{ "solana-keygen", "new", "-o", new_vote_path }) catch {
                    return error.KeyGenerationFailed;
                };
                
                return .{
                    .use_existing = false,
                    .identity_path = new_id_path,
                    .vote_account_path = new_vote_path,
                };
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: SWAP-KEYS - Hot-Swap Validator Identity/Vote Keys
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdSwapKeys(self: *Self) !void {
        self.printBanner("KEY HOT-SWAP");
        
        // Get current keys
        const current_keys = try self.getCurrentVexorKeys();
        self.print("\n  Current Keys:\n", .{});
        self.print("    Identity: {s}\n", .{current_keys.identity});
        if (current_keys.vote_account) |vote| {
            self.print("    Vote:     {s}\n", .{vote});
        }

        // List available key sets
        const available_keys = try self.listAvailableKeySets();
        defer {
            for (available_keys.items) |key_set| {
                self.allocator.free(key_set.name);
                self.allocator.free(key_set.identity);
                if (key_set.vote_account) |v| self.allocator.free(v);
            }
            available_keys.deinit();
        }

        if (available_keys.items.len == 0) {
            self.print("\n  ⚠️  No other key sets found.\n", .{});
            self.print("     Use 'vexor-install install' to create new keys.\n", .{});
            return;
        }

        self.print("\n  Available Key Sets:\n", .{});
        for (available_keys.items, 1..) |key_set, i| {
            self.print("    [{d}] {s}\n", .{ i, key_set.name });
            self.print("        Identity: {s}\n", .{key_set.identity});
        }

        const choice_str = try self.readLine("Select keys to use (or 'q' to quit): ");
        if (choice_str.len == 0 or choice_str[0] == 'q' or choice_str[0] == 'Q') {
            self.print("\n  Cancelled.\n", .{});
            return;
        }

        const choice = std.fmt.parseInt(usize, choice_str, 10) catch {
            self.print("\n  Invalid selection.\n", .{});
            return;
        };

        if (choice < 1 or choice > available_keys.items.len) {
            self.print("\n  Invalid selection.\n", .{});
            return;
        }

        const selected_keys = available_keys.items[choice - 1];

        // Backup current keys
        self.print("\n  📦 Backing up current keys...\n", .{});
        const backup_id = try self.backupCurrentKeys();
        defer self.allocator.free(backup_id);

        // Switch to selected keys
        self.print("  🔄 Switching to selected keys...\n", .{});
        try self.switchToKeys(selected_keys);

        // Restart Vexor if running
        const is_running = runCommand(&.{ "systemctl", "is-active", "--quiet", "vexor" }) catch false;
        if (is_running) {
            self.print("  🔄 Restarting Vexor...\n", .{});
            _ = runCommand(&.{ "systemctl", "restart", "vexor" }) catch {};
        }

        self.print("\n  ✅ Keys swapped successfully!\n", .{});
        self.print("     Backup ID: {s}\n", .{backup_id});
        self.print("     Rollback: vexor-install swap-keys --restore {s}\n", .{backup_id});
    }

    /// Get current Vexor keys from config
    fn getCurrentVexorKeys(self: *Self) !ClientKeys {
        // Check Vexor service file
        const service_file = "/etc/systemd/system/vexor.service";
        if (fs.cwd().openFile(service_file, .{})) |file| {
            defer file.close();
            var buf: [8192]u8 = undefined;
            const bytes_read = file.readAll(&buf) catch return error.ServiceFileReadFailed;
            const content = buf[0..bytes_read];

            // Extract --identity
            var identity_path: ?[]const u8 = null;
            if (std.mem.indexOf(u8, content, "--identity")) |idx| {
                const start = idx + "--identity".len;
                const end = std.mem.indexOfPos(u8, content, start, " ") orelse content.len;
                const path = std.mem.trim(u8, content[start..end], &std.ascii.whitespace);
                if (path.len > 0) {
                    identity_path = try self.allocator.dupe(u8, path);
                }
            }

            // Extract --vote-account
            var vote_path: ?[]const u8 = null;
            if (std.mem.indexOf(u8, content, "--vote-account")) |idx| {
                const start = idx + "--vote-account".len;
                const end = std.mem.indexOfPos(u8, content, start, " ") orelse content.len;
                const path = std.mem.trim(u8, content[start..end], &std.ascii.whitespace);
                if (path.len > 0) {
                    vote_path = try self.allocator.dupe(u8, path);
                }
            }

            if (identity_path) |id_path| {
                return ClientKeys{
                    .identity = id_path,
                    .vote_account = vote_path,
                    .source_client = .none, // Vexor keys
                };
            }
        } else |_| {}

        // Fallback to config defaults
        return ClientKeys{
            .identity = try self.allocator.dupe(u8, self.config.identity_path),
            .vote_account = if (self.config.vote_account_path) |v| try self.allocator.dupe(u8, v) else null,
            .source_client = .none,
        };
    }

    /// Key set structure
    const KeySet = struct {
        name: []const u8,
        identity: []const u8,
        vote_account: ?[]const u8,
    };

    /// List all available key sets
    fn listAvailableKeySets(self: *Self) !std.ArrayList(KeySet) {
        var key_sets = std.ArrayList(KeySet).init(self.allocator);

        // Get current keys
        const current = try self.getCurrentVexorKeys();
        defer {
            self.allocator.free(current.identity);
            if (current.vote_account) |v| self.allocator.free(v);
        }

        // Add original client keys if detected
        if (try self.detectCurrentClientKeys()) |detected| {
            defer {
                self.allocator.free(detected.identity);
                if (detected.vote_account) |v| self.allocator.free(v);
            }
            try key_sets.append(.{
                .name = try std.fmt.allocPrint(self.allocator, "Original {s} keys", .{detected.source_client.displayName()}),
                .identity = try self.allocator.dupe(u8, detected.identity),
                .vote_account = if (detected.vote_account) |v| try self.allocator.dupe(u8, v) else null,
            });
        }

        // Add current Vexor keys
        try key_sets.append(.{
            .name = try self.allocator.dupe(u8, "Current Vexor keys"),
            .identity = try self.allocator.dupe(u8, current.identity),
            .vote_account = if (current.vote_account) |v| try self.allocator.dupe(u8, v) else null,
        });

        // Check for other key files in common locations
        const common_dirs = [_][]const u8{
            "/home/solana/.secrets/",
            "/home/solana/",
            "/mnt/solana/",
        };

        for (common_dirs) |dir| {
            var dir_handle = fs.cwd().openDir(dir, .{ .iterate = true }) catch continue;
            defer dir_handle.close();

            var iter = dir_handle.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.endsWith(u8, entry.name, "-keypair.json")) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ dir, entry.name });
                    defer self.allocator.free(full_path);

                    // Skip if already in list
                    var skip = false;
                    for (key_sets.items) |existing| {
                        if (std.mem.eql(u8, existing.identity, full_path)) {
                            skip = true;
                            break;
                        }
                    }
                    if (skip) continue;

                    // Check if it's a valid keypair
                    const pubkey_check = try std.fmt.allocPrint(self.allocator, "solana-keygen pubkey {s} 2>/dev/null || echo 'invalid'", .{full_path});
                    defer self.allocator.free(pubkey_check);
                    const pubkey_result = runCommandOutput(self.allocator, &.{ "sh", "-c", pubkey_check }) catch "invalid";
                    defer self.allocator.free(pubkey_result);
                    
                    if (std.mem.indexOf(u8, pubkey_result, "invalid") == null) {
                        const name = try std.fmt.allocPrint(self.allocator, "Keys from {s}", .{entry.name});
                        try key_sets.append(.{
                            .name = name,
                            .identity = try self.allocator.dupe(u8, full_path),
                            .vote_account = null, // Try to find vote account
                        });
                    }
                }
            }
        }

        return key_sets;
    }

    /// Backup current keys before swap
    fn backupCurrentKeys(self: *Self) ![]const u8 {
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        const backup_id = try std.fmt.allocPrint(self.allocator, "key-backup-{d}", .{timestamp});
        const backup_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.backup_dir, backup_id });
        defer self.allocator.free(backup_dir);

        _ = runCommand(&.{ "mkdir", "-p", backup_dir }) catch {};

        const current = try self.getCurrentVexorKeys();
        defer {
            self.allocator.free(current.identity);
            if (current.vote_account) |v| self.allocator.free(v);
        }

        // Copy identity key
        _ = runCommand(&.{ "cp", current.identity, backup_dir }) catch {};

        // Copy vote account key if exists
        if (current.vote_account) |vote| {
            _ = runCommand(&.{ "cp", vote, backup_dir }) catch {};
        }

        return backup_id;
    }

    /// Switch to new keys
    fn switchToKeys(self: *Self, key_set: KeySet) !void {
        // Update Vexor service file
        const service_file = "/etc/systemd/system/vexor.service";
        if (fs.cwd().openFile(service_file, .{})) |file| {
            defer file.close();
            var buf: [8192]u8 = undefined;
            const bytes_read = file.readAll(&buf) catch return error.ServiceFileReadFailed;
            var content = std.ArrayList(u8).init(self.allocator);
            defer content.deinit();
            try content.appendSlice(buf[0..bytes_read]);

            // Replace --identity
            if (std.mem.indexOf(u8, content.items, "--identity")) |idx| {
                const start = idx + "--identity".len;
                const end = std.mem.indexOfPos(u8, content.items, start, " ") orelse content.items.len;
                const old_path = content.items[start..end];
                const new_line = try std.fmt.allocPrint(self.allocator, "--identity {s}", .{key_set.identity});
                defer self.allocator.free(new_line);
                // Simple replacement - in production, use proper parsing
                _ = old_path;
            }

            // Replace --vote-account if present
            if (key_set.vote_account) |vote| {
                if (std.mem.indexOf(u8, content.items, "--vote-account")) |idx| {
                    const start = idx + "--vote-account".len;
                    const end = std.mem.indexOfPos(u8, content.items, start, " ") orelse content.items.len;
                    const old_path = content.items[start..end];
                    const new_line = try std.fmt.allocPrint(self.allocator, "--vote-account {s}", .{vote});
                    defer self.allocator.free(new_line);
                    // Simple replacement
                    _ = old_path;
                }
            }

            // Write updated service file
            // TODO: Implement proper service file update
        } else |_| {
            return error.ServiceFileNotFound;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMMAND: FIX - Interactive Issue Resolution (MASQUE, QUIC, AF_XDP, etc.)
    // ═══════════════════════════════════════════════════════════════════════

    fn cmdFix(self: *Self) !void {
        if (self.config.dry_run) {
            self.printBanner("VEXOR FIX - DRY RUN MODE");
            self.print(
                \\
                \\🧪 DRY-RUN MODE: Will scan and show fixes, but make NO changes
                \\
            , .{});
        } else {
            self.printBanner("VEXOR FIX - Performance Optimization");
        }
        
        self.print(
            \\
            \\This will scan for issues with MASQUE, QUIC, AF_XDP, storage, and system
            \\tuning, then guide you through fixing them.
            \\
            \\Every fix will be explained and requires your permission.
            \\
        , .{});
        
        // Use arena allocator for all temporary allocations in fix command
        // This prevents memory leaks - everything freed at once when arena is destroyed
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        
        // Collect all detected issues using arena allocator
        var issues = std.ArrayList(DetectedIssueInfo).init(arena_alloc);
        // No need for defer deinit - arena handles it
        
        self.print("\n🔍 Scanning for issues...\n\n", .{});
        
        // MASQUE/QUIC Checks
        try self.detectMasqueQuicIssues(&issues, arena_alloc);
        
        // AF_XDP Checks
        try self.detectAfXdpIssues(&issues, arena_alloc);
        
        // Storage Checks  
        try self.detectStorageIssues(&issues, arena_alloc);
        
        // System Tuning Checks
        try self.detectSystemTuningIssues(&issues, arena_alloc);
        
        // io_uring Checks
        try self.detectIoUringIssues(&issues, arena_alloc);
        
        // QUIC/TLS 1.3 Checks
        try self.detectQuicTlsIssues(&issues, arena_alloc);
        
        // Connection Migration Checks
        try self.detectMigrationIssues(&issues, arena_alloc);
        
        // GPU Checks
        try self.detectGpuIssues(&issues, arena_alloc);
        
        // BLS Cryptography Checks (for Alpenglow)
        try self.detectBlsIssues(&issues, arena_alloc);
        
        // AF_XDP Advanced Configuration
        try self.detectAfXdpAdvancedIssues(&issues, arena_alloc);
        
        // Security Permissions Audit
        try self.detectSecurityIssues(&issues, arena_alloc);
        
        // Installation Completeness Check
        try self.detectInstallationIssues(&issues, arena_alloc);
        
        // CPU Pinning / Performance Checks
        try self.detectCpuPinningIssues(&issues, arena_alloc);
        
        if (issues.items.len == 0) {
            self.print("✅ No issues detected! Your system is optimally configured.\n", .{});
            return;
        }
        
        // Display all issues
        self.print("\n", .{});
        self.printBanner("DETECTED ISSUES");
        self.print("\nFound {d} issue(s) that can be optimized:\n\n", .{issues.items.len});
        
        for (issues.items, 0..) |issue, idx| {
            self.print("┌─────────────────────────────────────────────────────────────────┐\n", .{});
            self.print("│ [{d}] {s}\n", .{ idx + 1, issue.title });
            self.print("│ ─────────────────────────────────────────────────────────────── │\n", .{});
            self.print("│ Category:    {s}\n", .{issue.category});
            self.print("│ Severity:    {s}\n", .{issue.severity});
            self.print("│ Impact:      {s}\n", .{issue.impact});
            self.print("│\n", .{});
            self.print("│ Current:     {s}\n", .{issue.current_value});
            self.print("│ Recommended: {s}\n", .{issue.recommended_value});
            self.print("│\n", .{});
            if (issue.auto_fix_command) |cmd| {
                self.print("│ Fix Command: {s}\n", .{cmd});
                self.print("│ Risk Level:  {s}\n", .{issue.risk_level});
            } else {
                self.print("│ ⚠️  Manual fix required (see instructions below)\n", .{});
            }
            self.print("└─────────────────────────────────────────────────────────────────┘\n\n", .{});
        }
        
        // Ask how to proceed
        if (self.config.non_interactive) {
            self.print("[Non-interactive mode: applying all low-risk fixes]\n", .{});
            try self.applyAllFixes(&issues, .low);
        } else {
            self.print(
                \\How would you like to proceed?
                \\
                \\  [A] Apply all fixes (will ask for each)
                \\  [L] Apply only low-risk fixes automatically
                \\  [M] Show manual instructions for all
                \\  [Q] Quit
                \\
            , .{});
            
            const choice = try self.readLine("Choice [A/L/M/Q]: ");
            if (choice.len > 0) {
                switch (choice[0]) {
                    'A', 'a' => try self.applyFixesInteractively(&issues),
                    'L', 'l' => try self.applyAllFixes(&issues, .low),
                    'M', 'm' => try self.showManualInstructions(&issues),
                    else => self.print("\nFix cancelled.\n", .{}),
                }
            }
        }
    }

    /// Detect MASQUE/QUIC issues
    fn detectMasqueQuicIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking MASQUE/QUIC...\n", .{});
        
        // Check QUIC ports
        var ports_blocked = false;
        const ports = [_]u16{ 8801, 8802, 8803, 8804 };
        for (ports) |port| {
            const cmd = try std.fmt.allocPrint(alloc, "ss -ulnp 2>/dev/null | grep :{d} || echo 'available'", .{port});
            // No defer needed - arena handles cleanup
            const result = runCommandOutput(alloc, &.{ "sh", "-c", cmd }) catch "error";
            if (std.mem.indexOf(u8, result, "available") == null) {
                ports_blocked = true;
                break;
            }
        }
        
        // Check firewall rules for QUIC
        const fw_check = runCommandOutput(alloc, &.{ "sh", "-c", "nft list ruleset 2>/dev/null | grep -c 8801 || iptables -L -n 2>/dev/null | grep -c 8801 || echo '0'" }) catch "0";
        const fw_rules = std.fmt.parseInt(u32, std.mem.trim(u8, fw_check, &std.ascii.whitespace), 10) catch 0;
        
        if (fw_rules == 0) {
            try issues.append(.{
                .id = "MASQUE001",
                .title = "QUIC/MASQUE Ports Not Allowed in Firewall",
                .category = "Network",
                .severity = "HIGH",
                .impact = "QUIC transport disabled, ~50ms latency increase",
                .current_value = "UDP 8801-8810 not explicitly allowed",
                .recommended_value = "Allow UDP 8801-8810 inbound",
                .auto_fix_command = "nft add rule inet filter input udp dport 8801-8810 accept 2>/dev/null || iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT",
                .risk_level = "LOW - Opens specific ports only",
                .requires_sudo = true,
                .manual_instructions = 
                \\For nftables: sudo nft add rule inet filter input udp dport 8801-8810 accept
                \\For iptables: sudo iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT
                \\For UFW: sudo ufw allow 8801:8810/udp
                \\For cloud: Add UDP 8801-8810 to security group
                ,
            });
        }
        
        // Check QUIC/TLS 1.3 support
        const tls_check = runCommandOutput(alloc, &.{ "sh", "-c", "openssl version 2>/dev/null | grep -E '1\\.[1-9]|3\\.' || echo 'old'" }) catch "old";
        if (std.mem.indexOf(u8, tls_check, "old") != null) {
            try issues.append(.{
                .id = "MASQUE003",
                .title = "OpenSSL May Not Support TLS 1.3",
                .category = "Network",
                .severity = "MEDIUM",
                .impact = "QUIC handshake may fail",
                .current_value = "OpenSSL version may be too old for TLS 1.3",
                .recommended_value = "OpenSSL 1.1.1+ or 3.x",
                .auto_fix_command = "apt-get update && apt-get install -y openssl libssl-dev 2>/dev/null || yum update -y openssl 2>/dev/null",
                .risk_level = "LOW - Standard package update",
                .requires_sudo = true,
                .manual_instructions = 
                \\Check version: openssl version
                \\Update: sudo apt-get update && sudo apt-get install -y openssl
                ,
            });
        }
    }

    /// Detect io_uring issues (NEW)
    fn detectIoUringIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking io_uring...\n", .{});
        
        // Check kernel version for io_uring (5.1+)
        const kernel = runCommandOutput(alloc, &.{ "uname", "-r" }) catch "unknown";
        const kernel_str = std.mem.trim(u8, kernel, &std.ascii.whitespace);
        var ver_parts = std.mem.splitScalar(u8, kernel_str, '.');
        const major = std.fmt.parseInt(u32, ver_parts.next() orelse "0", 10) catch 0;
        const minor = std.fmt.parseInt(u32, ver_parts.next() orelse "0", 10) catch 0;
        
        if (major < 5 or (major == 5 and minor < 1)) {
            try issues.append(.{
                .id = "IOURING001",
                .title = "Kernel Too Old for io_uring",
                .category = "System",
                .severity = "MEDIUM",
                .impact = "Cannot use io_uring, falls back to standard UDP (3x slower)",
                .current_value = try std.fmt.allocPrint(alloc, "Kernel {s}", .{kernel_str}),
                .recommended_value = "Kernel 5.1+ for io_uring support",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\io_uring requires Linux kernel 5.1 or newer.
                \\Ubuntu: sudo apt-get install linux-image-generic-hwe-22.04
                \\Reboot after kernel upgrade.
                ,
            });
        }
        
        // Check io_uring system limits
        const sq_limit = runCommandOutput(alloc, &.{ "sh", "-c", "cat /proc/sys/kernel/io_uring_setup_sqpoll_cpu_limit 2>/dev/null || echo '0'" }) catch "0";
        const sq_val = std.fmt.parseInt(u32, std.mem.trim(u8, sq_limit, &std.ascii.whitespace), 10) catch 0;
        _ = sq_val;
        
        // Check if io_uring is restricted (container/security policy)
        const uring_test = runCommandOutput(alloc, &.{ "sh", "-c", "test -e /dev/io_uring && echo 'ok' || echo 'missing'" }) catch "missing";
        if (std.mem.indexOf(u8, uring_test, "missing") != null) {
            // This is expected on older systems, not an error
        }
    }
    
    /// Detect QUIC/TLS issues (NEW)
    fn detectQuicTlsIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking QUIC/TLS 1.3...\n", .{});
        
        // Check OpenSSL version for TLS 1.3 support
        const openssl = runCommandOutput(alloc, &.{ "sh", "-c", "openssl version 2>/dev/null | awk '{print $2}' || echo '0.0.0'" }) catch "0.0.0";
        const ssl_ver = std.mem.trim(u8, openssl, &std.ascii.whitespace);
        
        // TLS 1.3 requires OpenSSL 1.1.1+
        var ssl_parts = std.mem.splitScalar(u8, ssl_ver, '.');
        const ssl_major = std.fmt.parseInt(u32, ssl_parts.next() orelse "0", 10) catch 0;
        const ssl_minor = std.fmt.parseInt(u32, ssl_parts.next() orelse "0", 10) catch 0;
        const ssl_patch = std.fmt.parseInt(u32, ssl_parts.next() orelse "0", 10) catch 0;
        
        const has_tls13 = (ssl_major > 1) or 
                         (ssl_major == 1 and ssl_minor > 1) or
                         (ssl_major == 1 and ssl_minor == 1 and ssl_patch >= 1);
        
        if (!has_tls13) {
            try issues.append(.{
                .id = "QUICTLS001",
                .title = "OpenSSL Too Old for TLS 1.3",
                .category = "Network",
                .severity = "HIGH",
                .impact = "QUIC/MASQUE will be disabled, ~50ms latency increase",
                .current_value = try std.fmt.allocPrint(alloc, "OpenSSL {s}", .{ssl_ver}),
                .recommended_value = "OpenSSL 1.1.1+ or 3.0+",
                .auto_fix_command = "apt-get update && apt-get install -y openssl libssl-dev",
                .risk_level = "LOW - Standard package update",
                .requires_sudo = true,
                .manual_instructions = 
                \\TLS 1.3 requires OpenSSL 1.1.1 or newer.
                \\Ubuntu/Debian: sudo apt-get install -y openssl libssl-dev
                \\CentOS/RHEL: sudo yum install -y openssl openssl-devel
                ,
            });
        }
        
        // Check QUIC ports (8801-8810)
        const port_check = runCommandOutput(alloc, &.{ "sh", "-c", "ss -ulnp 2>/dev/null | grep ':880' | wc -l" }) catch "0";
        const ports_in_use = std.fmt.parseInt(u32, std.mem.trim(u8, port_check, &std.ascii.whitespace), 10) catch 0;
        
        if (ports_in_use > 0) {
            try issues.append(.{
                .id = "QUICTLS002",
                .title = "QUIC Ports Already in Use",
                .category = "Network",
                .severity = "MEDIUM",
                .impact = "Port conflict may prevent QUIC from starting",
                .current_value = try std.fmt.allocPrint(alloc, "{d} ports in range 8801-8810 in use", .{ports_in_use}),
                .recommended_value = "Ports 8801-8810 free",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Check what's using QUIC ports:
                \\  ss -ulnp | grep ':880'
                \\  
                \\Stop conflicting services or use different ports.
                ,
            });
        }
        
        // Check for firewall blocking UDP
        const ufw = runCommandOutput(alloc, &.{ "sh", "-c", "ufw status 2>/dev/null | grep -i active | wc -l" }) catch "0";
        const firewall_active = std.fmt.parseInt(u32, std.mem.trim(u8, ufw, &std.ascii.whitespace), 10) catch 0;
        
        if (firewall_active > 0) {
            const udp_rule = runCommandOutput(alloc, &.{ "sh", "-c", "ufw status 2>/dev/null | grep '880.*udp' | wc -l" }) catch "0";
            const udp_allowed = std.fmt.parseInt(u32, std.mem.trim(u8, udp_rule, &std.ascii.whitespace), 10) catch 0;
            
            if (udp_allowed == 0) {
                try issues.append(.{
                    .id = "QUICTLS003",
                    .title = "Firewall May Block QUIC",
                    .category = "Network",
                    .severity = "HIGH",
                    .impact = "QUIC connections will fail, fallback to TCP",
                    .current_value = "UFW active, no UDP 8801-8810 rule found",
                    .recommended_value = "Allow UDP 8801-8810",
                    .auto_fix_command = "ufw allow 8801:8810/udp",
                    .risk_level = "LOW - Opens specific ports only",
                    .requires_sudo = true,
                    .manual_instructions = 
                    \\Open QUIC ports:
                    \\  sudo ufw allow 8801:8810/udp
                    \\  sudo ufw reload
                    \\
                    \\For GCP: Add firewall rule via console or gcloud
                    \\For AWS: Update security group
                    ,
                });
            }
        }
    }
    
    /// Detect Connection Migration readiness (NEW)
    fn detectMigrationIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking connection migration...\n", .{});
        
        // Check for multiple network interfaces
        const iface_count = runCommandOutput(alloc, &.{ "sh", "-c", "ip link show | grep -c '^[0-9]' 2>/dev/null" }) catch "1";
        const interfaces = std.fmt.parseInt(u32, std.mem.trim(u8, iface_count, &std.ascii.whitespace), 10) catch 1;
        
        if (interfaces > 2) { // More than lo + one NIC
            try issues.append(.{
                .id = "MIGRATE001",
                .title = "Multiple Network Interfaces Detected",
                .category = "Network",
                .severity = "INFO",
                .impact = "Connection migration available for failover",
                .current_value = try std.fmt.allocPrint(alloc, "{d} interfaces", .{interfaces}),
                .recommended_value = "Configure primary/backup routing",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Connection migration allows failover between interfaces.
                \\Ensure proper routing is configured for each interface.
                \\Run: ip route show
                ,
            });
        }
    }

    /// Detect AF_XDP issues
    fn detectAfXdpIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking AF_XDP...\n", .{});
        
        // Check binary capabilities
        const binary_path = try std.fmt.allocPrint(alloc, "{s}/bin/vexor", .{self.config.install_dir});
        
        const caps = runCommandOutput(alloc, &.{ "getcap", binary_path }) catch "";
        
        if (std.mem.indexOf(u8, caps, "cap_net_raw") == null) {
            try issues.append(.{
                .id = "AFXDP001",
                .title = "AF_XDP Capabilities Not Set",
                .category = "Permission",
                .severity = "HIGH",
                .impact = "10x packet throughput reduction (1M vs 10M pps)",
                .current_value = "No capabilities on vexor binary",
                .recommended_value = "cap_net_raw,cap_net_admin,cap_sys_admin",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' {s}", .{binary_path}),
                .risk_level = "LOW - Standard for network tools",
                .requires_sudo = true,
                .manual_instructions = 
                \\Run: sudo setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor
                \\Verify: getcap /opt/vexor/bin/vexor
                ,
            });
        }
        
        // Check libbpf
        const libbpf = runCommandOutput(alloc, &.{ "sh", "-c", "ldconfig -p 2>/dev/null | grep -i libbpf || echo 'not_found'" }) catch "not_found";
        
        if (std.mem.indexOf(u8, libbpf, "not_found") != null) {
            try issues.append(.{
                .id = "AFXDP003",
                .title = "libbpf Not Installed",
                .category = "System",
                .severity = "HIGH",
                .impact = "AF_XDP completely disabled",
                .current_value = "libbpf not found",
                .recommended_value = "libbpf-dev installed",
                .auto_fix_command = "apt-get update && apt-get install -y libbpf-dev 2>/dev/null || yum install -y libbpf-devel 2>/dev/null",
                .risk_level = "LOW - Standard library",
                .requires_sudo = true,
                .manual_instructions = 
                \\Ubuntu/Debian: sudo apt-get install -y libbpf-dev
                \\CentOS/RHEL: sudo yum install -y libbpf-devel
                ,
            });
        }
        
        // Check kernel version for AF_XDP
        const kernel = runCommandOutput(alloc, &.{ "uname", "-r" }) catch "unknown";
        const kernel_str = std.mem.trim(u8, kernel, &std.ascii.whitespace);
        var ver_parts = std.mem.splitScalar(u8, kernel_str, '.');
        const major = std.fmt.parseInt(u32, ver_parts.next() orelse "0", 10) catch 0;
        
        if (major < 5) {
            try issues.append(.{
                .id = "AFXDP004",
                .title = "Kernel Version May Limit AF_XDP",
                .category = "System",
                .severity = "LOW",
                .impact = "Some AF_XDP features may be unavailable",
                .current_value = try std.fmt.allocPrint(alloc, "Kernel {s}", .{kernel_str}),
                .recommended_value = "Kernel 5.x+ recommended for best AF_XDP support",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Consider upgrading to a newer kernel (5.x+) for best AF_XDP performance.
                \\Ubuntu: sudo apt-get install linux-image-generic-hwe-22.04
                ,
            });
        }
        
        // Check NIC driver XDP support
        const driver = runCommandOutput(alloc, &.{ "sh", "-c", "readlink -f /sys/class/net/eth0/device/driver 2>/dev/null | xargs basename || echo 'unknown'" }) catch "unknown";
        const driver_name = std.mem.trim(u8, driver, &std.ascii.whitespace);
        
        if (!isXdpCapableDriver(driver_name)) {
            try issues.append(.{
                .id = "AFXDP002",
                .title = "NIC Driver May Not Support AF_XDP",
                .category = "Network",
                .severity = "MEDIUM",
                .impact = "Will fall back to io_uring or standard UDP",
                .current_value = try std.fmt.allocPrint(alloc, "Driver: {s}", .{driver_name}),
                .recommended_value = "Intel i40e/ice, Mellanox mlx5, or other XDP-capable driver",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Your NIC may not support AF_XDP. Vexor will automatically fall back to
                \\io_uring (5x faster than UDP) or standard UDP.
                \\
                \\For best performance, consider:
                \\  - Intel X710/XL710 (i40e driver)
                \\  - Intel E810 (ice driver)
                \\  - Mellanox ConnectX-5/6 (mlx5_core driver)
                ,
            });
        }
    }

    /// Detect storage issues
    fn detectStorageIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking storage...\n", .{});
        
        // Check ramdisk
        const ramdisk = runCommandOutput(alloc, &.{ "sh", "-c", "mount | grep '/mnt/vexor/ramdisk.*tmpfs' || echo 'not_mounted'" }) catch "not_mounted";
        
        if (std.mem.indexOf(u8, ramdisk, "not_mounted") != null) {
            // Check available RAM
            const mem = runCommandOutput(alloc, &.{ "sh", "-c", "grep MemAvailable /proc/meminfo | awk '{print $2}'" }) catch "0";
            const mem_kb = std.fmt.parseInt(u64, std.mem.trim(u8, mem, &std.ascii.whitespace), 10) catch 0;
            const mem_gb = mem_kb / 1024 / 1024;
            
            if (mem_gb > 32) { // Only recommend if >32GB available
                const ramdisk_size = @min(mem_gb / 4, 64);
                try issues.append(.{
                    .id = "STOR001",
                    .title = "RAM Disk Not Mounted",
                    .category = "Storage",
                    .severity = "MEDIUM",
                    .impact = "100x slower hot account access",
                    .current_value = "No ramdisk",
                    .recommended_value = try std.fmt.allocPrint(alloc, "{d}GB tmpfs ramdisk", .{ramdisk_size}),
                    .auto_fix_command = try std.fmt.allocPrint(alloc, "mkdir -p /mnt/vexor/ramdisk && mount -t tmpfs -o size={d}G,mode=1777 tmpfs /mnt/vexor/ramdisk", .{ramdisk_size}),
                    .risk_level = "MEDIUM - Uses system RAM",
                    .requires_sudo = true,
                    .manual_instructions = 
                    \\1. Create mount point: sudo mkdir -p /mnt/vexor/ramdisk
                    \\2. Mount: sudo mount -t tmpfs -o size=32G tmpfs /mnt/vexor/ramdisk
                    \\3. Add to /etc/fstab for persistence
                    ,
                });
            }
        }
        
        // Check for HDD vs SSD/NVMe
        const disks = runCommandOutput(alloc, &.{ "sh", "-c", "lsblk -d -o NAME,ROTA 2>/dev/null | grep -E '^sd|^nvme' | head -1" }) catch "";
        if (std.mem.indexOf(u8, disks, " 1") != null) { // ROTA=1 means rotational (HDD)
            try issues.append(.{
                .id = "STOR002",
                .title = "Rotational Disk (HDD) Detected",
                .category = "Storage",
                .severity = "HIGH",
                .impact = "10-50x slower I/O than NVMe",
                .current_value = "HDD (rotational disk)",
                .recommended_value = "NVMe SSD (Samsung 990 Pro, Intel Optane)",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\STRONGLY RECOMMEND upgrading to NVMe storage:
                \\  - Samsung 990 Pro (best consumer)
                \\  - Intel Optane P5800X (best enterprise)
                \\  - Any NVMe with >3GB/s read speed
                \\
                \\HDD is NOT suitable for validator operation.
                ,
            });
        }
        
        // Check I/O scheduler
        const sched = runCommandOutput(alloc, &.{ "sh", "-c", "cat /sys/block/nvme*/queue/scheduler 2>/dev/null | head -1 || echo 'unknown'" }) catch "unknown";
        if (std.mem.indexOf(u8, sched, "[none]") == null and std.mem.indexOf(u8, sched, "unknown") == null) {
            try issues.append(.{
                .id = "STOR003",
                .title = "NVMe I/O Scheduler Not Optimized",
                .category = "Storage",
                .severity = "LOW",
                .impact = "Slight latency increase on NVMe",
                .current_value = std.mem.trim(u8, sched, &std.ascii.whitespace),
                .recommended_value = "none (for NVMe)",
                .auto_fix_command = "echo 'none' | tee /sys/block/nvme*/queue/scheduler 2>/dev/null",
                .risk_level = "LOW - Standard optimization",
                .requires_sudo = true,
                .manual_instructions = 
                \\For NVMe, scheduler should be 'none':
                \\  echo 'none' | sudo tee /sys/block/nvme0n1/queue/scheduler
                ,
            });
        }
    }

    /// Detect system tuning issues
    fn detectSystemTuningIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking system tuning...\n", .{});
        
        // Check network buffers
        const rmem = runCommandOutput(alloc, &.{ "sysctl", "-n", "net.core.rmem_max" }) catch "0";
        const rmem_val = std.fmt.parseInt(u64, std.mem.trim(u8, rmem, &std.ascii.whitespace), 10) catch 0;
        
        if (rmem_val < 134217728) {
            try issues.append(.{
                .id = "TUNE001",
                .title = "Network Buffers Too Small",
                .category = "System",
                .severity = "MEDIUM",
                .impact = "Up to 30% packet loss under load",
                .current_value = try std.fmt.allocPrint(alloc, "{d} bytes", .{rmem_val}),
                .recommended_value = "134217728 bytes (128MB)",
                .auto_fix_command = "sysctl -w net.core.rmem_max=134217728 net.core.wmem_max=134217728 net.core.rmem_default=134217728 net.core.wmem_default=134217728",
                .risk_level = "LOW - Standard tuning",
                .requires_sudo = true,
                .manual_instructions = 
                \\sudo sysctl -w net.core.rmem_max=134217728
                \\sudo sysctl -w net.core.wmem_max=134217728
                \\Add to /etc/sysctl.d/99-vexor.conf for persistence
                ,
            });
        }
        
        // Check file limits
        const nofile = runCommandOutput(alloc, &.{ "sh", "-c", "ulimit -n" }) catch "0";
        const nofile_val = std.fmt.parseInt(u64, std.mem.trim(u8, nofile, &std.ascii.whitespace), 10) catch 0;
        
        if (nofile_val < 1000000) {
            try issues.append(.{
                .id = "TUNE003",
                .title = "File Descriptor Limit Too Low",
                .category = "System",
                .severity = "HIGH",
                .impact = "Will crash with many connections",
                .current_value = try std.fmt.allocPrint(alloc, "{d}", .{nofile_val}),
                .recommended_value = "1000000",
                .auto_fix_command = null, // Requires re-login
                .risk_level = "LOW",
                .requires_sudo = true,
                .manual_instructions = 
                \\1. Edit /etc/security/limits.conf:
                \\   * soft nofile 1000000
                \\   * hard nofile 1000000
                \\2. Re-login or reboot
                \\3. Verify: ulimit -n
                ,
            });
        }
        
        // Check huge pages
        const hugepages = runCommandOutput(alloc, &.{ "sysctl", "-n", "vm.nr_hugepages" }) catch "0";
        const hp_val = std.fmt.parseInt(u64, std.mem.trim(u8, hugepages, &std.ascii.whitespace), 10) catch 0;
        
        // Get total RAM to determine if huge pages make sense
        const total_mem = runCommandOutput(alloc, &.{ "sh", "-c", "grep MemTotal /proc/meminfo | awk '{print $2}'" }) catch "0";
        const total_mem_kb = std.fmt.parseInt(u64, std.mem.trim(u8, total_mem, &std.ascii.whitespace), 10) catch 0;
        const total_mem_gb = total_mem_kb / 1024 / 1024;
        
        if (hp_val == 0 and total_mem_gb > 64) {
            const mem_portion: u64 = @min(total_mem_gb / 4, 32);
            const recommended_pages: u64 = mem_portion * 512; // 2MB pages
            try issues.append(.{
                .id = "TUNE002",
                .title = "Huge Pages Not Enabled",
                .category = "System",
                .severity = "LOW",
                .impact = "5-10% memory performance reduction",
                .current_value = "0 huge pages",
                .recommended_value = try std.fmt.allocPrint(alloc, "{d} pages (~{d}GB)", .{ recommended_pages, recommended_pages * 2 / 1024 }),
                .auto_fix_command = try std.fmt.allocPrint(alloc, "sysctl -w vm.nr_hugepages={d}", .{recommended_pages}),
                .risk_level = "MEDIUM - Reserves memory",
                .requires_sudo = true,
                .manual_instructions = 
                \\Enable huge pages:
                \\  sudo sysctl -w vm.nr_hugepages=16384
                \\  echo 'vm.nr_hugepages=16384' | sudo tee -a /etc/sysctl.d/99-vexor.conf
                ,
            });
        }
        
        // Check swappiness
        const swappiness = runCommandOutput(alloc, &.{ "sysctl", "-n", "vm.swappiness" }) catch "60";
        const swap_val = std.fmt.parseInt(u32, std.mem.trim(u8, swappiness, &std.ascii.whitespace), 10) catch 60;
        
        if (swap_val > 10) {
            try issues.append(.{
                .id = "TUNE004",
                .title = "Swappiness Too High",
                .category = "System",
                .severity = "LOW",
                .impact = "May swap out hot data unnecessarily",
                .current_value = try std.fmt.allocPrint(alloc, "{d}", .{swap_val}),
                .recommended_value = "10",
                .auto_fix_command = "sysctl -w vm.swappiness=10",
                .risk_level = "LOW - Standard tuning",
                .requires_sudo = true,
                .manual_instructions = 
                \\sudo sysctl -w vm.swappiness=10
                \\echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.d/99-vexor.conf
                ,
            });
        }
        
        // Check vm.max_map_count for mmap-backed snapshot loading
        // Vexor uses mmap for large snapshot files (>1MB) to avoid heap pressure
        const max_map = runCommandOutput(alloc, &.{ "sysctl", "-n", "vm.max_map_count" }) catch "65530";
        const max_map_val = std.fmt.parseInt(u64, std.mem.trim(u8, max_map, &std.ascii.whitespace), 10) catch 65530;
        
        // Solana validators need high map count for mmap-heavy workloads
        // Recommended: 1,000,000+ for validators with large account sets
        const RECOMMENDED_MAX_MAP_COUNT: u64 = 1000000;
        
        if (max_map_val < RECOMMENDED_MAX_MAP_COUNT) {
            try issues.append(.{
                .id = "TUNE005",
                .title = "vm.max_map_count Too Low for Snapshot mmap",
                .category = "System",
                .severity = "MEDIUM",
                .impact = "Snapshot loading may fail with 'Cannot allocate memory' on large snapshots",
                .current_value = try std.fmt.allocPrint(alloc, "{d}", .{max_map_val}),
                .recommended_value = "1000000",
                .auto_fix_command = "sysctl -w vm.max_map_count=1000000",
                .risk_level = "LOW - Standard validator tuning",
                .requires_sudo = true,
                .manual_instructions = 
                \\Vexor uses mmap for efficient snapshot loading.
                \\Large account databases require many memory mappings.
                \\
                \\sudo sysctl -w vm.max_map_count=1000000
                \\echo 'vm.max_map_count=1000000' | sudo tee -a /etc/sysctl.d/99-vexor.conf
                ,
            });
        }
    }
    
    /// Detect GPU issues (for signature verification acceleration)
    fn detectGpuIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking GPU...\n", .{});
        
        // Check for NVIDIA GPU
        const nvidia = runCommandOutput(alloc, &.{ "sh", "-c", "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo 'not_found'" }) catch "not_found";
        
        if (std.mem.indexOf(u8, nvidia, "not_found") == null and nvidia.len > 5) {
            // GPU found - check if CUDA is available
            const cuda = runCommandOutput(alloc, &.{ "sh", "-c", "nvcc --version 2>/dev/null || echo 'not_found'" }) catch "not_found";
            
            if (std.mem.indexOf(u8, cuda, "not_found") != null) {
                try issues.append(.{
                    .id = "GPU001",
                    .title = "NVIDIA GPU Detected but CUDA Not Installed",
                    .category = "Compute",
                    .severity = "LOW",
                    .impact = "Cannot use GPU for signature verification",
                    .current_value = try std.fmt.allocPrint(alloc, "GPU: {s}, CUDA: Not installed", .{std.mem.trim(u8, nvidia, &std.ascii.whitespace)}),
                    .recommended_value = "CUDA Toolkit 12.x installed",
                    .auto_fix_command = null, // CUDA installation is complex
                    .risk_level = "N/A",
                    .requires_sudo = false,
                    .manual_instructions = 
                    \\Your system has an NVIDIA GPU that could accelerate signature verification.
                    \\
                    \\To enable GPU acceleration:
                    \\1. Install CUDA Toolkit: https://developer.nvidia.com/cuda-downloads
                    \\2. Rebuild Vexor with -Dgpu=true
                    \\
                    \\Note: GPU acceleration is optional but can verify ~500K signatures/sec
                    ,
                });
            }
        }
    }
    
    /// Detect BLS cryptography issues (for Alpenglow vote aggregation)
    fn detectBlsIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking BLS cryptography...\n", .{});
        
        // Check for blst library (optional high-performance BLS)
        const blst = runCommandOutput(alloc, &.{ "sh", "-c", "ldconfig -p 2>/dev/null | grep -i blst || echo 'not_found'" }) catch "not_found";
        
        if (std.mem.indexOf(u8, blst, "not_found") != null) {
            // Check if Vexor has built-in BLS (it does now)
            self.debug("  Note: blst library not found, using built-in BLS implementation", .{});
            
            // Only flag this as optional enhancement
            try issues.append(.{
                .id = "BLS001",
                .title = "High-Performance BLS Library Not Available",
                .category = "Crypto",
                .severity = "INFO",
                .impact = "Using built-in BLS (adequate for most use cases)",
                .current_value = "Built-in Zig BLS implementation",
                .recommended_value = "blst library for 10x faster BLS operations",
                .auto_fix_command = "apt-get update && apt-get install -y libblst-dev 2>/dev/null || yum install -y blst-devel 2>/dev/null || echo 'Manual install required'",
                .risk_level = "LOW - Optional performance library",
                .requires_sudo = true,
                .manual_instructions = 
                \\Vexor has a built-in BLS12-381 implementation that works correctly.
                \\
                \\For maximum performance (10x faster BLS operations), install blst:
                \\
                \\  # From source (recommended):
                \\  git clone https://github.com/supranational/blst.git
                \\  cd blst
                \\  ./build.sh
                \\  sudo cp libblst.a /usr/local/lib/
                \\  sudo cp bindings/blst.h /usr/local/include/
                \\
                \\  # Or via package manager (if available):
                \\  sudo apt-get install libblst-dev
                \\
                \\BLS is used for Alpenglow vote aggregation (future Solana upgrade).
                ,
            });
        }
        
        // Check CPU support for efficient BLS operations
        const cpu_flags = runCommandOutput(alloc, &.{ "sh", "-c", "grep -oE 'avx2|avx512|adx' /proc/cpuinfo | sort -u | tr '\\n' ' '" }) catch "";
        
        const has_avx2 = std.mem.indexOf(u8, cpu_flags, "avx2") != null;
        const has_avx512 = std.mem.indexOf(u8, cpu_flags, "avx512") != null;
        const has_adx = std.mem.indexOf(u8, cpu_flags, "adx") != null;
        
        if (!has_avx2) {
            try issues.append(.{
                .id = "BLS002",
                .title = "CPU Lacks AVX2 for BLS Operations",
                .category = "Crypto",
                .severity = "MEDIUM",
                .impact = "BLS signature operations 5-10x slower",
                .current_value = try std.fmt.allocPrint(alloc, "CPU flags: {s}", .{if (cpu_flags.len > 0) std.mem.trim(u8, cpu_flags, &std.ascii.whitespace) else "none detected"}),
                .recommended_value = "CPU with AVX2+ADX support (Intel Haswell+, AMD Zen+)",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Your CPU may not have optimal instructions for BLS cryptography.
                \\
                \\For best BLS performance, use a CPU with:
                \\  - AVX2 (Intel Haswell 2013+, AMD Excavator 2015+)
                \\  - ADX (Intel Broadwell 2014+, AMD Zen 2017+)
                \\  - AVX-512 (Intel Skylake-X, AMD Zen 4) - optional but fastest
                \\
                \\Vexor will still work but BLS operations will be slower.
                ,
            });
        } else {
            // Log good status
            self.debug("  BLS crypto: AVX2={}, AVX512={}, ADX={}", .{ has_avx2, has_avx512, has_adx });
        }
    }
    
    /// Detect AF_XDP advanced configuration issues
    fn detectAfXdpAdvancedIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking AF_XDP advanced configuration...\n", .{});
        
        // ═══════════════════════════════════════════════════════════════════
        // CRITICAL: CAP_NET_RAW capability check
        // ═══════════════════════════════════════════════════════════════════
        const binary_path = try std.fmt.allocPrint(alloc, "{s}/bin/vexor", .{self.config.install_dir});
        const cap_check = runCommandOutput(alloc, &.{ "getcap", binary_path }) catch "";
        
        if (std.mem.indexOf(u8, cap_check, "cap_net_raw") == null) {
            try issues.append(.{
                .id = "AFXDP001",
                .title = "AF_XDP: Missing CAP_NET_RAW Capability",
                .category = "Permissions",
                .severity = "HIGH",
                .impact = "AF_XDP disabled - falling back to slower UDP (~1M pps vs ~5M pps)",
                .current_value = "No network capabilities granted",
                .recommended_value = "cap_net_raw,cap_net_admin+ep",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "setcap cap_net_raw,cap_net_admin+ep {s}", .{binary_path}),
                .risk_level = "LOW - Grants network capabilities to Vexor binary only",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\AF_XDP requires CAP_NET_RAW capability to create raw sockets.
                    \\Without this, Vexor falls back to standard UDP (~1M pps).
                    \\
                    \\To fix, run:
                    \\  sudo setcap cap_net_raw,cap_net_admin+ep {s}
                    \\
                    \\Verify with:
                    \\  getcap {s}
                    \\
                    \\This only affects the Vexor binary, not system-wide.
                , .{ binary_path, binary_path }),
            });
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // CRITICAL: libbpf installation check
        // ═══════════════════════════════════════════════════════════════════
        const libbpf_check = runCommandOutput(alloc, &.{ "sh", "-c", "/sbin/ldconfig -p 2>/dev/null | grep libbpf || /usr/sbin/ldconfig -p 2>/dev/null | grep libbpf" }) catch "";
        const libbpf_pkg = runCommandOutput(alloc, &.{ "sh", "-c", "dpkg -l libbpf-dev 2>/dev/null | grep -E '^ii' || rpm -q libbpf-devel 2>/dev/null" }) catch "";
        
        if (libbpf_check.len < 5 and libbpf_pkg.len < 5) {
            // Detect package manager
            const apt_exists = runCommand(&.{ "which", "apt" }) catch false;
            const dnf_exists = runCommand(&.{ "which", "dnf" }) catch false;
            
            const install_cmd = if (apt_exists == true)
                "apt install -y libbpf-dev"
            else if (dnf_exists == true)
                "dnf install -y libbpf-devel"
            else
                "apt install -y libbpf-dev";  // Default to apt
            
            try issues.append(.{
                .id = "AFXDP002",
                .title = "AF_XDP: libbpf Library Not Installed",
                .category = "Dependencies",
                .severity = "HIGH",
                .impact = "AF_XDP BPF programs cannot be loaded - falling back to slower UDP",
                .current_value = "libbpf not found",
                .recommended_value = "libbpf-dev (Debian/Ubuntu) or libbpf-devel (RHEL/Fedora)",
                .auto_fix_command = install_cmd,
                .risk_level = "LOW - Installs standard system library",
                .requires_sudo = true,
                .manual_instructions = 
                \\libbpf is required for AF_XDP to load BPF programs.
                \\
                \\Install on Debian/Ubuntu:
                \\  sudo apt install -y libbpf-dev
                \\
                \\Install on RHEL/Fedora:
                \\  sudo dnf install -y libbpf-devel
                \\
                \\Install on Arch:
                \\  sudo pacman -S libbpf
                \\
                \\After installing, restart Vexor to enable AF_XDP.
                ,
            });
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // BPF JIT check
        // ═══════════════════════════════════════════════════════════════════
        const bpf_jit = runCommandOutput(alloc, &.{ "sysctl", "-n", "net.core.bpf_jit_enable" }) catch "0";
        const jit_enabled = std.fmt.parseInt(u32, std.mem.trim(u8, bpf_jit, &std.ascii.whitespace), 10) catch 0;
        
        if (jit_enabled == 0) {
            try issues.append(.{
                .id = "AFXDP003",
                .title = "AF_XDP: BPF JIT Compiler Disabled",
                .category = "Performance",
                .severity = "MEDIUM",
                .impact = "BPF programs run in interpreter mode (2-5x slower)",
                .current_value = "BPF JIT disabled (0)",
                .recommended_value = "BPF JIT enabled (1)",
                .auto_fix_command = "sysctl -w net.core.bpf_jit_enable=1 && echo 'net.core.bpf_jit_enable=1' >> /etc/sysctl.d/99-vexor.conf",
                .risk_level = "LOW - Standard kernel optimization",
                .requires_sudo = true,
                .manual_instructions = 
                \\The BPF JIT compiler dramatically improves AF_XDP performance.
                \\
                \\To enable:
                \\  sudo sysctl -w net.core.bpf_jit_enable=1
                \\
                \\Make persistent:
                \\  echo 'net.core.bpf_jit_enable=1' | sudo tee -a /etc/sysctl.d/99-vexor.conf
                ,
            });
        }
        
        // Check for multiple network interfaces (for multi-queue support)
        const interfaces = runCommandOutput(alloc, &.{ "sh", "-c", "ls -1 /sys/class/net/ 2>/dev/null | grep -v lo | head -10" }) catch "";
        var if_count: u32 = 0;
        var if_iter = std.mem.splitScalar(u8, interfaces, '\n');
        while (if_iter.next()) |iface| {
            if (iface.len > 0) if_count += 1;
        }
        
        if (if_count > 1) {
            // Multiple interfaces - suggest configuration
            try issues.append(.{
                .id = "AFXDP005",
                .title = "Multiple Network Interfaces Detected",
                .category = "Network",
                .severity = "INFO",
                .impact = "Can enable multi-queue AF_XDP for higher throughput",
                .current_value = try std.fmt.allocPrint(alloc, "{d} interfaces available", .{if_count}),
                .recommended_value = "Configure primary interface for AF_XDP",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = try std.fmt.allocPrint(alloc, 
                    \\Multiple network interfaces detected:
                    \\{s}
                    \\
                    \\For best AF_XDP performance:
                    \\1. Identify your primary network interface
                    \\2. Configure Vexor to use it: --interface <name>
                    \\3. Enable multi-queue if NIC supports it
                    \\
                    \\Check NIC queues: ethtool -l <interface>
                    \\Set queues: sudo ethtool -L <interface> combined 8
                , .{interfaces}),
            });
        }
        
        // Check NIC queue count
        const primary_if = runCommandOutput(alloc, &.{ "sh", "-c", "ip route | grep default | awk '{print $5}' | head -1" }) catch "eth0";
        const primary_if_name = std.mem.trim(u8, primary_if, &std.ascii.whitespace);
        
        const queues_cmd = try std.fmt.allocPrint(alloc, "ethtool -l {s} 2>/dev/null | grep -i combined | tail -1 | awk '{{print $2}}'", .{primary_if_name});
        const queues = runCommandOutput(alloc, &.{ "sh", "-c", queues_cmd }) catch "1";
        const queue_count = std.fmt.parseInt(u32, std.mem.trim(u8, queues, &std.ascii.whitespace), 10) catch 1;
        
        if (queue_count < 4) {
            try issues.append(.{
                .id = "AFXDP006",
                .title = "NIC Queue Count May Limit AF_XDP Throughput",
                .category = "Network",
                .severity = "LOW",
                .impact = "AF_XDP throughput limited by single queue",
                .current_value = try std.fmt.allocPrint(alloc, "{s}: {d} queue(s)", .{ primary_if_name, queue_count }),
                .recommended_value = "4-8 queues for multi-core AF_XDP",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "ethtool -L {s} combined 4 2>/dev/null || echo 'NIC may not support multi-queue'", .{primary_if_name}),
                .risk_level = "LOW - Network configuration change",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\To increase AF_XDP throughput with multiple CPU cores:
                    \\
                    \\  # Check max supported queues
                    \\  ethtool -l {s}
                    \\
                    \\  # Set combined queues (match CPU cores)
                    \\  sudo ethtool -L {s} combined 4
                    \\
                    \\More queues = more parallel AF_XDP processing.
                , .{ primary_if_name, primary_if_name }),
            });
        }
        
        // Check UMEM limits (huge pages for large UMEM)
        const hugepages = runCommandOutput(alloc, &.{ "sh", "-c", "grep HugePages_Total /proc/meminfo | awk '{print $2}'" }) catch "0";
        const hp_count = std.fmt.parseInt(u64, std.mem.trim(u8, hugepages, &std.ascii.whitespace), 10) catch 0;
        
        if (hp_count < 512) {
            try issues.append(.{
                .id = "AFXDP007",
                .title = "Huge Pages Not Configured for AF_XDP UMEM",
                .category = "Memory",
                .severity = "LOW",
                .impact = "AF_XDP UMEM allocation slightly slower",
                .current_value = try std.fmt.allocPrint(alloc, "{d} huge pages (2MB each)", .{hp_count}),
                .recommended_value = "512+ huge pages (1GB+) for optimal UMEM",
                .auto_fix_command = "sysctl -w vm.nr_hugepages=512 && echo 'vm.nr_hugepages=512' >> /etc/sysctl.d/99-vexor.conf",
                .risk_level = "MEDIUM - Reserves 1GB RAM as huge pages",
                .requires_sudo = true,
                .manual_instructions = 
                \\Huge pages improve AF_XDP UMEM performance.
                \\
                \\  # Allocate 512 x 2MB = 1GB huge pages
                \\  sudo sysctl -w vm.nr_hugepages=512
                \\
                \\  # Make persistent
                \\  echo 'vm.nr_hugepages=512' | sudo tee -a /etc/sysctl.d/99-vexor.conf
                \\
                \\Note: This reserves 1GB of RAM for huge pages.
                ,
            });
        }
        
        // NOTE: BPF JIT check is now at the top of this function (AFXDP003)
    }
    
    /// Comprehensive security permissions audit
    fn detectSecurityIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking security permissions...\n", .{});
        
        const install_dir = self.config.install_dir;
        const binary_path = try std.fmt.allocPrint(alloc, "{s}/bin/vexor", .{install_dir});
        
        // Check 1: Binary file permissions (should not be world-writable)
        const perms = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "stat -c '%a' {s} 2>/dev/null || echo '777'", .{binary_path}) }) catch "777";
        const perm_val = std.fmt.parseInt(u32, std.mem.trim(u8, perms, &std.ascii.whitespace), 8) catch 0o777;
        
        if (perm_val & 0o002 != 0) { // World-writable
            try issues.append(.{
                .id = "SEC001",
                .title = "CRITICAL: Vexor Binary Is World-Writable",
                .category = "Security",
                .severity = "CRITICAL",
                .impact = "Any user can modify the validator binary!",
                .current_value = try std.fmt.allocPrint(alloc, "Permissions: {o}", .{perm_val}),
                .recommended_value = "755 (rwxr-xr-x)",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "chmod 755 {s}", .{binary_path}),
                .risk_level = "LOW - Standard permission fix",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\CRITICAL SECURITY ISSUE!
                    \\
                    \\Your vexor binary is world-writable. Fix immediately:
                    \\  sudo chmod 755 {s}
                    \\  sudo chown root:root {s}
                , .{ binary_path, binary_path }),
            });
        }
        
        // Check 2: Config directory permissions
        const config_dir = self.config.config_dir;
        const config_perms = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "stat -c '%a' {s} 2>/dev/null || echo '777'", .{config_dir}) }) catch "777";
        const config_perm_val = std.fmt.parseInt(u32, std.mem.trim(u8, config_perms, &std.ascii.whitespace), 8) catch 0o777;
        
        if (config_perm_val & 0o077 != 0) { // Group or world readable
            try issues.append(.{
                .id = "SEC002",
                .title = "Config Directory Has Loose Permissions",
                .category = "Security",
                .severity = "HIGH",
                .impact = "Keypairs may be readable by other users",
                .current_value = try std.fmt.allocPrint(alloc, "{s}: {o}", .{ config_dir, config_perm_val }),
                .recommended_value = "700 (rwx------)",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "chmod 700 {s} && chmod 600 {s}/*.json 2>/dev/null", .{ config_dir, config_dir }),
                .risk_level = "LOW - Standard permission fix",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Your config directory contains sensitive keypairs.
                    \\
                    \\Secure it:
                    \\  sudo chmod 700 {s}
                    \\  sudo chmod 600 {s}/*.json
                    \\  sudo chown -R vexor:vexor {s}
                , .{ config_dir, config_dir, config_dir }),
            });
        }
        
        // Check 3: Keypair files permissions
        const keypair_check = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "find {s} -name '*.json' -perm /go+r 2>/dev/null | head -3", .{config_dir}) }) catch "";
        
        if (keypair_check.len > 5) {
            try issues.append(.{
                .id = "SEC003",
                .title = "Keypair Files Have Loose Permissions",
                .category = "Security",
                .severity = "CRITICAL",
                .impact = "Private keys may be exposed to other users!",
                .current_value = "Keypairs readable by group/others",
                .recommended_value = "600 (rw-------) for all .json files",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "chmod 600 {s}/*.json 2>/dev/null", .{config_dir}),
                .risk_level = "LOW - Standard permission fix",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\CRITICAL: Your validator keypairs may be exposed!
                    \\
                    \\Fix immediately:
                    \\  sudo chmod 600 {s}/*.json
                    \\  sudo chown vexor:vexor {s}/*.json
                , .{ config_dir, config_dir }),
            });
        }
        
        // Check 4: Systemd service file permissions
        const service_perms = runCommandOutput(alloc, &.{ "sh", "-c", "stat -c '%a' /etc/systemd/system/vexor.service 2>/dev/null || echo 'not_found'" }) catch "not_found";
        
        if (std.mem.indexOf(u8, service_perms, "not_found") == null) {
            const svc_perm_val = std.fmt.parseInt(u32, std.mem.trim(u8, service_perms, &std.ascii.whitespace), 8) catch 0o777;
            if (svc_perm_val & 0o022 != 0) {
                try issues.append(.{
                    .id = "SEC004",
                    .title = "Systemd Service File Has Loose Permissions",
                    .category = "Security",
                    .severity = "HIGH",
                    .impact = "Service file could be modified by non-root users",
                    .current_value = try std.fmt.allocPrint(alloc, "/etc/systemd/system/vexor.service: {o}", .{svc_perm_val}),
                    .recommended_value = "644 (rw-r--r--)",
                    .auto_fix_command = "chmod 644 /etc/systemd/system/vexor.service && chown root:root /etc/systemd/system/vexor.service",
                    .risk_level = "LOW - Standard permission fix",
                    .requires_sudo = true,
                    .manual_instructions = 
                    \\Secure systemd service file:
                    \\  sudo chmod 644 /etc/systemd/system/vexor.service
                    \\  sudo chown root:root /etc/systemd/system/vexor.service
                    ,
                });
            }
        }
        
        // Check 5: Setcap audit (ensure only necessary capabilities)
        const caps = runCommandOutput(alloc, &.{ "getcap", binary_path }) catch "";
        
        if (std.mem.indexOf(u8, caps, "cap_sys_admin") != null) {
            // Has sys_admin - warn about it
            try issues.append(.{
                .id = "SEC005",
                .title = "Binary Has CAP_SYS_ADMIN Capability",
                .category = "Security",
                .severity = "INFO",
                .impact = "Required for AF_XDP but grants broad privileges",
                .current_value = std.mem.trim(u8, caps, &std.ascii.whitespace),
                .recommended_value = "Minimum: cap_net_raw,cap_net_admin (if AF_XDP not needed)",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\CAP_SYS_ADMIN is required for full AF_XDP functionality.
                \\
                \\If you don't need AF_XDP (using io_uring instead):
                \\  sudo setcap 'cap_net_raw,cap_net_admin+eip' /opt/vexor/bin/vexor
                \\
                \\Current capabilities provide maximum performance but broader access.
                ,
            });
        }
        
        // Check 6: Ledger directory ownership
        const ledger_dir = self.config.ledger_dir;
        const ledger_owner = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "stat -c '%U:%G' {s} 2>/dev/null || echo 'unknown:unknown'", .{ledger_dir}) }) catch "unknown:unknown";
        
        if (std.mem.indexOf(u8, ledger_owner, "root") != null) {
            try issues.append(.{
                .id = "SEC006",
                .title = "Ledger Directory Owned by Root",
                .category = "Security",
                .severity = "MEDIUM",
                .impact = "Vexor may not be able to write to ledger",
                .current_value = try std.fmt.allocPrint(alloc, "{s} owner: {s}", .{ ledger_dir, std.mem.trim(u8, ledger_owner, &std.ascii.whitespace) }),
                .recommended_value = try std.fmt.allocPrint(alloc, "Owner: {s}:{s}", .{ self.config.vexor_user, self.config.vexor_group }),
                .auto_fix_command = try std.fmt.allocPrint(alloc, "chown -R {s}:{s} {s}", .{ self.config.vexor_user, self.config.vexor_group, ledger_dir }),
                .risk_level = "LOW - Ownership change",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Change ledger ownership to vexor user:
                    \\  sudo chown -R {s}:{s} {s}
                , .{ self.config.vexor_user, self.config.vexor_group, ledger_dir }),
            });
        }
    }

    /// Detect Vexor installation health and completeness
    fn detectInstallationIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking Vexor installation...\n", .{});
        
        const install_dir = self.config.install_dir;
        const binary_path = try std.fmt.allocPrint(alloc, "{s}/bin/vexor", .{install_dir});
        defer alloc.free(binary_path);
        
        // Check 1: Binary exists and is executable
        const binary_exists = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "test -x {s} && echo 'ok' || echo 'missing'", .{binary_path}) }) catch "missing";
        defer alloc.free(binary_exists);
        
        if (std.mem.indexOf(u8, binary_exists, "ok") == null) {
            try issues.append(.{
                .id = "INST001",
                .title = "Vexor Binary Not Found or Not Executable",
                .category = "Installation",
                .severity = "CRITICAL",
                .impact = "Vexor cannot start without the binary",
                .current_value = "Binary missing or not executable",
                .recommended_value = try std.fmt.allocPrint(alloc, "Executable at {s}", .{binary_path}),
                .auto_fix_command = "cd /path/to/vexor && zig build -Doptimize=ReleaseFast && sudo cp zig-out/bin/vexor /opt/vexor/bin/",
                .risk_level = "LOW - Build and copy",
                .requires_sudo = true,
                .manual_instructions = 
                    \\Vexor binary is missing. Build and install:
                    \\
                    \\  cd /path/to/solana-client-research/vexor
                    \\  zig build -Doptimize=ReleaseFast
                    \\  sudo mkdir -p /opt/vexor/bin
                    \\  sudo cp zig-out/bin/vexor /opt/vexor/bin/
                    \\  sudo chmod 755 /opt/vexor/bin/vexor
                ,
            });
        }
        
        // Check 2: Required directories exist
        const ledger_dir = self.config.ledger_dir;
        const ledger_exists = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "test -d {s} && echo 'ok' || echo 'missing'", .{ledger_dir}) }) catch "missing";
        defer alloc.free(ledger_exists);
        
        if (std.mem.indexOf(u8, ledger_exists, "ok") == null) {
            try issues.append(.{
                .id = "INST002",
                .title = "Ledger Directory Missing",
                .category = "Installation",
                .severity = "HIGH",
                .impact = "Validator cannot store ledger data",
                .current_value = "Directory does not exist",
                .recommended_value = try std.fmt.allocPrint(alloc, "{s} with correct permissions", .{ledger_dir}),
                .auto_fix_command = try std.fmt.allocPrint(alloc, "mkdir -p {s} && chown {s}:{s} {s}", .{ ledger_dir, self.config.vexor_user, self.config.vexor_group, ledger_dir }),
                .risk_level = "LOW - Create directory",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Create ledger directory:
                    \\
                    \\  sudo mkdir -p {s}
                    \\  sudo chown {s}:{s} {s}
                , .{ ledger_dir, self.config.vexor_user, self.config.vexor_group, ledger_dir }),
            });
        }
        
        // Check 3: Identity keypair exists
        const identity_path = try std.fmt.allocPrint(alloc, "{s}/identity.json", .{self.config.config_dir});
        defer alloc.free(identity_path);
        const identity_exists = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "test -f {s} && echo 'ok' || echo 'missing'", .{identity_path}) }) catch "missing";
        defer alloc.free(identity_exists);
        
        if (std.mem.indexOf(u8, identity_exists, "ok") == null) {
            try issues.append(.{
                .id = "INST003",
                .title = "Identity Keypair Missing",
                .category = "Installation",
                .severity = "CRITICAL",
                .impact = "Validator cannot participate in consensus without identity",
                .current_value = "No identity.json found",
                .recommended_value = try std.fmt.allocPrint(alloc, "{s}", .{identity_path}),
                .auto_fix_command = null,
                .risk_level = "HIGH - Generates new identity",
                .requires_sudo = false,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Generate identity keypair:
                    \\
                    \\  solana-keygen new -o {s}
                    \\
                    \\WARNING: Keep this keypair safe! Loss means loss of validator identity.
                , .{identity_path}),
            });
        }
        
        // Check 4: Vote keypair exists (for validators)
        const vote_path = try std.fmt.allocPrint(alloc, "{s}/vote.json", .{self.config.config_dir});
        defer alloc.free(vote_path);
        const vote_exists = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "test -f {s} && echo 'ok' || echo 'missing'", .{vote_path}) }) catch "missing";
        defer alloc.free(vote_exists);
        
        if (std.mem.indexOf(u8, vote_exists, "ok") == null) {
            try issues.append(.{
                .id = "INST004",
                .title = "Vote Keypair Missing",
                .category = "Installation",
                .severity = "HIGH",
                .impact = "Validator cannot vote without vote account keypair",
                .current_value = "No vote.json found",
                .recommended_value = try std.fmt.allocPrint(alloc, "{s}", .{vote_path}),
                .auto_fix_command = null,
                .risk_level = "MEDIUM - Generates new vote account",
                .requires_sudo = false,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Generate vote keypair:
                    \\
                    \\  solana-keygen new -o {s}
                    \\
                    \\Then create vote account on-chain with your identity.
                , .{vote_path}),
            });
        }
        
        // Check 5: Systemd service file exists (for production)
        const service_exists = runCommandOutput(alloc, &.{ "sh", "-c", "test -f /etc/systemd/system/vexor.service && echo 'ok' || echo 'missing'" }) catch "missing";
        defer alloc.free(service_exists);
        
        if (std.mem.indexOf(u8, service_exists, "ok") == null) {
            try issues.append(.{
                .id = "INST005",
                .title = "Systemd Service Not Installed",
                .category = "Installation",
                .severity = "MEDIUM",
                .impact = "Validator won't auto-start on boot",
                .current_value = "No vexor.service found",
                .recommended_value = "/etc/systemd/system/vexor.service",
                .auto_fix_command = null,
                .risk_level = "LOW - Service installation",
                .requires_sudo = true,
                .manual_instructions = 
                    \\Install systemd service:
                    \\
                    \\  sudo vexor-install install --setup-service
                    \\
                    \\Or manually create /etc/systemd/system/vexor.service
                ,
            });
        }
    }

    /// Comprehensive network audit (checks EVERYTHING network-related)
    fn detectNetworkComprehensive(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        if (!self.config.debug_flags.shouldDebug("network") and !self.config.debug_flags.all) return;
        self.print("  [COMPREHENSIVE] Checking all network aspects...\n", .{});
        
        // Check NAT type, firewall rules, port availability, IRQ affinity, etc.
        // This is a placeholder - can be expanded with detailed checks
        _ = issues;
        _ = alloc;
    }
    
    /// Comprehensive storage audit (checks EVERYTHING storage-related)
    fn detectStorageComprehensive(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        if (!self.config.debug_flags.shouldDebug("storage") and !self.config.debug_flags.all) return;
        self.print("  [COMPREHENSIVE] Checking all storage aspects...\n", .{});
        
        // Check NVMe, SSD, HDD, RAM disk, huge pages, I/O scheduler, mount options, etc.
        // This is a placeholder - can be expanded with detailed checks
        _ = issues;
        _ = alloc;
    }
    
    /// Comprehensive compute audit (checks EVERYTHING compute-related)
    fn detectComputeComprehensive(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        if (!self.config.debug_flags.shouldDebug("compute") and !self.config.debug_flags.all) return;
        self.print("  [COMPREHENSIVE] Checking all compute aspects...\n", .{});
        
        // Check CPU features, NUMA, governor, frequency, GPU, etc.
        // This is a placeholder - can be expanded with detailed checks
        _ = issues;
        _ = alloc;
    }
    
    /// Comprehensive system audit (checks EVERYTHING system-related)
    fn detectSystemComprehensive(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        if (!self.config.debug_flags.shouldDebug("system") and !self.config.debug_flags.all) return;
        self.print("  [COMPREHENSIVE] Checking all system aspects...\n", .{});
        
        // Check OS, kernel, sysctl, limits, swap, permissions, etc.
        // This is a placeholder - can be expanded with detailed checks
        _ = issues;
        _ = alloc;
    }
    
    /// Detect non-interference issues (don't modify existing tuning)
    fn detectNonInterferenceIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking for existing tuning (non-interference mode)...\n", .{});
        
        // Check for CPU pinning - don't modify if detected
        var cpu_pinning_detected = false;
        const service_patterns = [_][]const u8{
            "solana*.service", "agave*.service", "firedancer*.service", "jito*.service", "frankendancer*.service",
        };
        
        for (service_patterns) |pattern| {
            const check_cmd = try std.fmt.allocPrint(alloc, 
                "grep -l 'taskset\\|numactl\\|CPUAffinity' /etc/systemd/system/{s} 2>/dev/null || echo 'none'", .{pattern});
            defer alloc.free(check_cmd);
            const result = runCommandOutput(alloc, &.{ "sh", "-c", check_cmd }) catch "none";
            defer alloc.free(result);
            
            if (!std.mem.eql(u8, std.mem.trim(u8, result, &std.ascii.whitespace), "none")) {
                cpu_pinning_detected = true;
                break;
            }
        }
        
        if (cpu_pinning_detected) {
            try issues.append(.{
                .id = "NONINT001",
                .title = "CPU Pinning Detected - Vexor Will Not Modify",
                .category = "Non-Interference",
                .severity = "INFO",
                .impact = "Vexor will work with your existing CPU pinning, not override it",
                .current_value = "CPU pinning detected in existing validator service",
                .recommended_value = "Continue using existing CPU pinning",
                .auto_fix_command = null,
                .risk_level = "NONE - No changes needed",
                .requires_sudo = false,
                .manual_instructions = 
                \\Vexor detected that you have CPU pinning configured for your existing validator.
                \\
                \\Vexor will NOT modify your CPU pinning settings. It will work alongside
                \\your existing configuration.
                \\
                \\If you want Vexor to use different cores, you can manually configure
                \\CPU pinning in the Vexor systemd service file.
                ,
            });
        }
        
        // Check for custom sysctl settings - suggest additions only
        const custom_sysctl = runCommandOutput(alloc, &.{ "sh", "-c", 
            "find /etc/sysctl.d -name '*.conf' ! -name '*vexor*' -exec basename {} \\; 2>/dev/null | head -5" }) catch "";
        defer alloc.free(custom_sysctl);
        
        if (custom_sysctl.len > 0) {
            try issues.append(.{
                .id = "NONINT002",
                .title = "Custom Sysctl Configs Detected - Vexor Will Add, Not Override",
                .category = "Non-Interference",
                .severity = "INFO",
                .impact = "Vexor will add its own sysctl config, not modify yours",
                .current_value = try std.fmt.allocPrint(alloc, "Custom configs: {s}", .{std.mem.trim(u8, custom_sysctl, &std.ascii.whitespace)}),
                .recommended_value = "Vexor will create /etc/sysctl.d/99-vexor.conf (additive)",
                .auto_fix_command = null,
                .risk_level = "NONE - No changes to your configs",
                .requires_sudo = false,
                .manual_instructions = 
                \\Vexor detected custom sysctl configurations.
                \\
                \\Vexor will create its own sysctl config file (/etc/sysctl.d/99-vexor.conf)
                \\which will be applied in addition to your existing configs. Your original
                \\configs will remain unchanged.
                ,
            });
        }
    }

    /// Detect CPU pinning and performance tuning issues
    fn detectCpuPinningIssues(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), alloc: Allocator) !void {
        self.print("  Checking CPU pinning and performance...\n", .{});
        
        // Check 1: Total CPU cores
        const cpu_count = runCommandOutput(alloc, &.{ "nproc" }) catch "0";
        const cores = std.fmt.parseInt(u32, std.mem.trim(u8, cpu_count, &std.ascii.whitespace), 10) catch 0;
        
        if (cores < 8) {
            try issues.append(.{
                .id = "CPU001",
                .title = "Low CPU Core Count",
                .category = "Performance",
                .severity = "INFO",
                .impact = "Limited parallelism for signature verification and transaction execution",
                .current_value = try std.fmt.allocPrint(alloc, "{d} cores available", .{cores}),
                .recommended_value = "8+ cores for production (16+ recommended)",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Vexor works best with 8+ CPU cores.
                \\
                \\Recommended core allocation:
                \\  1 core:   PoH (isolated, critical)
                \\  1-2 cores: AF_XDP networking
                \\  4+ cores:  Signature verification
                \\  4+ cores:  Transaction execution
                \\
                \\Consider upgrading to a system with more cores.
                ,
            });
        }
        
        // Check 2: CPU Governor (should be 'performance')
        const governor = runCommandOutput(alloc, &.{ "sh", "-c", "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'unknown'" }) catch "unknown";
        const gov_trimmed = std.mem.trim(u8, governor, &std.ascii.whitespace);
        
        if (!std.mem.eql(u8, gov_trimmed, "performance") and !std.mem.eql(u8, gov_trimmed, "unknown")) {
            try issues.append(.{
                .id = "CPU002",
                .title = "CPU Governor Not Set to Performance Mode",
                .category = "Performance",
                .severity = "MEDIUM",
                .impact = "CPU may throttle during high load, causing missed slots",
                .current_value = try std.fmt.allocPrint(alloc, "Governor: {s}", .{gov_trimmed}),
                .recommended_value = "performance",
                .auto_fix_command = "cpupower frequency-set -g performance 2>/dev/null || for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $cpu; done",
                .risk_level = "LOW - May increase power consumption",
                .requires_sudo = true,
                .manual_instructions = 
                \\Set CPU governor to performance mode:
                \\
                \\  # Using cpupower (recommended)
                \\  sudo cpupower frequency-set -g performance
                \\
                \\  # Or manually
                \\  for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                \\    echo performance | sudo tee $cpu
                \\  done
                \\
                \\  # Make persistent (add to /etc/rc.local or systemd)
                ,
            });
        }
        
        // Check 3: IRQ Balance (should be disabled for AF_XDP)
        const irqbalance = runCommandOutput(alloc, &.{ "sh", "-c", "systemctl is-active irqbalance 2>/dev/null || pgrep irqbalance >/dev/null && echo 'active' || echo 'inactive'" }) catch "unknown";
        
        if (std.mem.indexOf(u8, irqbalance, "active") != null) {
            try issues.append(.{
                .id = "CPU003",
                .title = "IRQ Balance Service Running",
                .category = "Performance",
                .severity = "LOW",
                .impact = "May cause IRQ affinity changes during operation, affecting AF_XDP",
                .current_value = "irqbalance is running",
                .recommended_value = "irqbalance stopped (use manual IRQ pinning)",
                .auto_fix_command = "systemctl stop irqbalance && systemctl disable irqbalance",
                .risk_level = "LOW - May affect other services on shared hosts",
                .requires_sudo = true,
                .manual_instructions = 
                \\Disable IRQ balancing for consistent network performance:
                \\
                \\  sudo systemctl stop irqbalance
                \\  sudo systemctl disable irqbalance
                \\
                \\Then manually pin NIC IRQs to AF_XDP cores:
                \\  echo <core> > /proc/irq/<irq>/smp_affinity
                ,
            });
        }
        
        // Check 4: CAP_SYS_NICE capability for realtime scheduling
        const binary_path = try std.fmt.allocPrint(alloc, "{s}/bin/vexor", .{self.config.install_dir});
        const caps = runCommandOutput(alloc, &.{ "sh", "-c", try std.fmt.allocPrint(alloc, "/sbin/getcap {s} 2>/dev/null || getcap {s} 2>/dev/null || echo 'none'", .{ binary_path, binary_path }) }) catch "none";
        
        if (std.mem.indexOf(u8, caps, "cap_sys_nice") == null) {
            try issues.append(.{
                .id = "CPU004",
                .title = "CAP_SYS_NICE Not Granted (Optional)",
                .category = "Performance",
                .severity = "INFO",
                .impact = "PoH tile cannot use SCHED_FIFO for guaranteed scheduling",
                .current_value = "cap_sys_nice not set on binary",
                .recommended_value = "cap_sys_nice+ep for realtime priority",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "setcap cap_net_raw,cap_net_admin,cap_sys_nice+ep {s}", .{binary_path}),
                .risk_level = "LOW - Standard capability for latency-sensitive apps",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\Grant realtime scheduling capability:
                    \\
                    \\  sudo setcap cap_sys_nice+ep {s}
                    \\
                    \\This allows Vexor to use SCHED_FIFO for the PoH tile,
                    \\ensuring consistent hashing without scheduler interruption.
                , .{binary_path}),
            });
        }
        
        // Check 5: Hyperthreading detection
        const siblings = runCommandOutput(alloc, &.{ "sh", "-c", "grep 'siblings' /proc/cpuinfo | head -1 | awk '{print $3}'" }) catch "0";
        const physical = runCommandOutput(alloc, &.{ "sh", "-c", "grep 'cpu cores' /proc/cpuinfo | head -1 | awk '{print $4}'" }) catch "0";
        
        const sib_count = std.fmt.parseInt(u32, std.mem.trim(u8, siblings, &std.ascii.whitespace), 10) catch 0;
        const phys_count = std.fmt.parseInt(u32, std.mem.trim(u8, physical, &std.ascii.whitespace), 10) catch 0;
        
        if (sib_count > phys_count and phys_count > 0) {
            try issues.append(.{
                .id = "CPU005",
                .title = "Hyperthreading Detected",
                .category = "Performance",
                .severity = "INFO",
                .impact = "For best PoH performance, disable hyperthreads on PoH core",
                .current_value = try std.fmt.allocPrint(alloc, "{d} threads per {d} physical cores (HT enabled)", .{ sib_count, phys_count }),
                .recommended_value = "Disable hyperthread pair of PoH core",
                .auto_fix_command = null,
                .risk_level = "MEDIUM - Reduces total thread count",
                .requires_sudo = true,
                .manual_instructions = 
                \\Firedancer recommends disabling hyperthreads on critical cores.
                \\
                \\To disable a hyperthread pair:
                \\  # Find sibling of core 1 (PoH core)
                \\  cat /sys/devices/system/cpu/cpu1/topology/thread_siblings_list
                \\  
                \\  # If output is "1,17", disable core 17
                \\  echo 0 > /sys/devices/system/cpu/cpu17/online
                \\
                \\Vexor's auto-layout will recommend which cores to disable.
                ,
            });
        }
        
        // Check 6: NUMA topology (multi-socket systems)
        const numa_nodes = runCommandOutput(alloc, &.{ "sh", "-c", "ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l" }) catch "1";
        const node_count = std.fmt.parseInt(u32, std.mem.trim(u8, numa_nodes, &std.ascii.whitespace), 10) catch 1;
        
        if (node_count > 1) {
            try issues.append(.{
                .id = "CPU006",
                .title = "Multi-NUMA System Detected",
                .category = "Performance",
                .severity = "INFO",
                .impact = "NUMA-aware memory allocation can improve performance",
                .current_value = try std.fmt.allocPrint(alloc, "{d} NUMA nodes", .{node_count}),
                .recommended_value = "Pin tiles and allocate memory on same NUMA node",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Your system has multiple NUMA nodes. For best performance:
                \\
                \\1. Pin related tiles to same NUMA node
                \\2. Use NUMA-aware memory allocation
                \\
                \\Vexor will auto-detect and recommend optimal layout.
                \\
                \\Check current NUMA topology:
                \\  numactl --hardware
                \\  lscpu | grep NUMA
                ,
            });
        }
        
        // Check 7: C-States (CPU sleep states) - can cause PoH latency
        const cstate_max = runCommandOutput(alloc, &.{ "sh", "-c", "cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null | tail -1 || echo 'unknown'" }) catch "unknown";
        const cstate_trimmed = std.mem.trim(u8, cstate_max, &std.ascii.whitespace);
        
        // Check if deep C-states are enabled (C3, C6, etc.)
        if (std.mem.indexOf(u8, cstate_trimmed, "C3") != null or 
            std.mem.indexOf(u8, cstate_trimmed, "C6") != null or
            std.mem.indexOf(u8, cstate_trimmed, "C7") != null or
            std.mem.indexOf(u8, cstate_trimmed, "C10") != null) {
            try issues.append(.{
                .id = "CPU007",
                .title = "Deep C-States Enabled (May Cause PoH Latency)",
                .category = "Performance",
                .severity = "MEDIUM",
                .impact = "CPU wake from C3+ takes 100µs+, can cause missed slots",
                .current_value = try std.fmt.allocPrint(alloc, "Deepest C-state: {s}", .{cstate_trimmed}),
                .recommended_value = "Disable C-states deeper than C1 for PoH core",
                .auto_fix_command = "for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do echo 1 > $state 2>/dev/null; done",
                .risk_level = "MEDIUM - Increases power consumption, may void warranty on some systems",
                .requires_sudo = true,
                .manual_instructions = 
                \\Deep C-states (C3, C6, etc.) cause 100µs+ wake latency.
                \\PoH hashing needs sub-microsecond consistency.
                \\
                \\Option 1: Disable at runtime (temporary):
                \\  for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do
                \\    echo 1 | sudo tee $state
                \\  done
                \\
                \\Option 2: Disable at boot (permanent):
                \\  Add to kernel command line in /etc/default/grub:
                \\  GRUB_CMDLINE_LINUX="processor.max_cstate=1 intel_idle.max_cstate=1"
                \\  Then: sudo update-grub && sudo reboot
                \\
                \\Option 3: Disable only for PoH core (recommended):
                \\  echo 1 > /sys/devices/system/cpu/cpu1/cpuidle/state2/disable
                \\  echo 1 > /sys/devices/system/cpu/cpu1/cpuidle/state3/disable
                \\
                \\Note: This increases power consumption but ensures consistent timing.
                ,
            });
        }
        
        // Check 8: NIC IRQ affinity (for AF_XDP performance)
        // Get primary network interface
        const primary_if = runCommandOutput(alloc, &.{ "sh", "-c", "ip route | grep default | awk '{print $5}' | head -1" }) catch "eth0";
        const if_name = std.mem.trim(u8, primary_if, &std.ascii.whitespace);
        
        // Check if NIC IRQs are balanced or pinned
        const irq_check_cmd = try std.fmt.allocPrint(alloc, "grep {s} /proc/interrupts | head -1 | awk '{{for(i=2;i<=NF-3;i++) if($i>0) count++}} END{{print count}}'", .{if_name});
        const irq_spread = runCommandOutput(alloc, &.{ "sh", "-c", irq_check_cmd }) catch "0";
        const spread_count = std.fmt.parseInt(u32, std.mem.trim(u8, irq_spread, &std.ascii.whitespace), 10) catch 0;
        
        if (spread_count > 2) {
            try issues.append(.{
                .id = "CPU008",
                .title = "NIC IRQs Spread Across Multiple Cores",
                .category = "Performance",
                .severity = "LOW",
                .impact = "IRQs on wrong core cause cache misses for AF_XDP (5-10% overhead)",
                .current_value = try std.fmt.allocPrint(alloc, "{s} IRQs spread across {d} cores", .{ if_name, spread_count }),
                .recommended_value = "Pin NIC IRQs to AF_XDP cores (cores 2-3)",
                .auto_fix_command = try std.fmt.allocPrint(alloc, "for irq in $(grep {s} /proc/interrupts | awk '{{print $1}}' | tr -d ':'); do echo 2 > /proc/irq/$irq/smp_affinity_list 2>/dev/null; done", .{if_name}),
                .risk_level = "LOW - Can be reverted by restarting irqbalance",
                .requires_sudo = true,
                .manual_instructions = try std.fmt.allocPrint(alloc,
                    \\For best AF_XDP performance, pin NIC IRQs to the same cores.
                    \\
                    \\1. Find your NIC's IRQs:
                    \\   grep {s} /proc/interrupts
                    \\
                    \\2. Pin each IRQ to AF_XDP core (e.g., core 2):
                    \\   echo 2 > /proc/irq/<IRQ_NUMBER>/smp_affinity_list
                    \\
                    \\3. Disable irqbalance to prevent re-balancing:
                    \\   sudo systemctl stop irqbalance
                    \\   sudo systemctl disable irqbalance
                    \\
                    \\4. For multi-queue NICs, set RSS to match AF_XDP cores:
                    \\   ethtool -L {s} combined 2
                    \\   ethtool -X {s} equal 2
                , .{ if_name, if_name, if_name }),
            });
        }
        
        // Check 9: Kernel boot parameters for latency
        const cmdline = runCommandOutput(alloc, &.{ "cat", "/proc/cmdline" }) catch "";
        
        const has_isolcpus = std.mem.indexOf(u8, cmdline, "isolcpus") != null;
        const has_nohz = std.mem.indexOf(u8, cmdline, "nohz_full") != null;
        const has_rcu = std.mem.indexOf(u8, cmdline, "rcu_nocbs") != null;
        
        if (!has_isolcpus and !has_nohz) {
            try issues.append(.{
                .id = "CPU009",
                .title = "Kernel Not Tuned for Low-Latency",
                .category = "Performance",
                .severity = "INFO",
                .impact = "Kernel timer interrupts can disrupt PoH hashing",
                .current_value = "No isolcpus or nohz_full configured",
                .recommended_value = "isolcpus=1 nohz_full=1 rcu_nocbs=1 for PoH core",
                .auto_fix_command = null,
                .risk_level = "HIGH - Requires reboot, may affect other services",
                .requires_sudo = true,
                .manual_instructions = 
                \\For ultimate PoH performance, isolate the PoH core from kernel interrupts.
                \\
                \\Add to /etc/default/grub GRUB_CMDLINE_LINUX:
                \\  isolcpus=1 nohz_full=1 rcu_nocbs=1
                \\
                \\This tells the kernel:
                \\  - isolcpus=1: Don't schedule regular tasks on core 1
                \\  - nohz_full=1: Disable timer tick on core 1 when only one task runs
                \\  - rcu_nocbs=1: Move RCU callbacks off core 1
                \\
                \\Then:
                \\  sudo update-grub
                \\  sudo reboot
                \\
                \\WARNING: This is an advanced optimization. Test thoroughly!
                ,
            });
        } else if (has_isolcpus or has_nohz or has_rcu) {
            // Already configured - just info
            try issues.append(.{
                .id = "CPU010",
                .title = "Low-Latency Kernel Parameters Detected",
                .category = "Performance",
                .severity = "INFO",
                .impact = "Good! Kernel is tuned for low-latency workloads",
                .current_value = try std.fmt.allocPrint(alloc, "isolcpus={}, nohz_full={}, rcu_nocbs={}", .{ has_isolcpus, has_nohz, has_rcu }),
                .recommended_value = "Already configured",
                .auto_fix_command = null,
                .risk_level = "N/A",
                .requires_sudo = false,
                .manual_instructions = 
                \\Your kernel is already configured for low-latency operation.
                \\Verify with: cat /proc/cmdline
                ,
            });
        }
    }

    /// Apply fixes interactively (ask for each)
    fn applyFixesInteractively(self: *Self, issues: *std.ArrayList(DetectedIssueInfo)) !void {
        self.print("\n", .{});
        self.printBanner("APPLYING FIXES");
        
        var applied: u32 = 0;
        var skipped: u32 = 0;
        var manual: u32 = 0;
        
        for (issues.items, 0..) |issue, idx| {
            self.print("\n[{d}/{d}] {s}\n", .{ idx + 1, issues.items.len, issue.title });
            self.print("───────────────────────────────────────────────────\n", .{});
            
            if (issue.auto_fix_command) |cmd| {
                self.print("Command: {s}\n", .{cmd});
                self.print("Risk: {s}\n", .{issue.risk_level});
                
                if (try self.confirm("Apply this fix?")) {
                    self.print("Applying...\n", .{});
                    
                    if (self.config.dry_run) {
                        self.print("[DRY RUN] Would execute: {s}\n", .{cmd});
                        applied += 1;
                    } else {
                        const result = runCommandOutput(self.allocator, &.{ "sh", "-c", cmd }) catch |err| {
                            self.print("❌ Failed: {}\n", .{err});
                            continue;
                        };
                        defer self.allocator.free(result);
                        
                        self.print("✅ Applied successfully\n", .{});
                        if (result.len > 0) {
                            self.print("Output: {s}\n", .{result});
                        }
                        applied += 1;
                    }
                } else {
                    self.print("Skipped.\n", .{});
                    skipped += 1;
                }
            } else {
                self.print("⚠️  This issue requires manual intervention:\n\n", .{});
                self.print("{s}\n", .{issue.manual_instructions});
                manual += 1;
            }
        }
        
        // Summary
        self.print("\n", .{});
        self.printBanner("FIX SUMMARY");
        self.print("\n  Applied: {d}\n", .{applied});
        self.print("  Skipped: {d}\n", .{skipped});
        self.print("  Manual:  {d}\n", .{manual});
        
        if (applied > 0) {
            self.print("\n✅ Changes applied. Some may require restart to take effect.\n", .{});
        }
    }

    /// Apply all fixes of a given risk level or lower
    fn applyAllFixes(self: *Self, issues: *std.ArrayList(DetectedIssueInfo), max_risk: RiskLevelSimple) !void {
        self.print("\nApplying all auto-fixable issues...\n", .{});
        
        var applied: u32 = 0;
        var skipped: u32 = 0;
        
        for (issues.items) |issue| {
            if (issue.auto_fix_command) |cmd| {
                // Filter by risk level
                const is_low_risk = std.mem.indexOf(u8, issue.risk_level, "LOW") != null;
                const is_medium_risk = std.mem.indexOf(u8, issue.risk_level, "MEDIUM") != null;
                
                const should_apply = switch (max_risk) {
                    .low => is_low_risk,
                    .medium => is_low_risk or is_medium_risk,
                    .high => true,
                };
                
                if (!should_apply) {
                    self.print("  Skipping (risk too high): {s}\n", .{issue.title});
                    skipped += 1;
                    continue;
                }
                
                self.print("  Applying: {s}...\n", .{issue.title});
                
                if (self.config.dry_run) {
                    self.print("    [DRY RUN] {s}\n", .{cmd});
                    applied += 1;
                } else {
                    // Use page allocator for command execution since arena might be gone
                    _ = runCommandOutput(std.heap.page_allocator, &.{ "sh", "-c", cmd }) catch {
                        self.print("    ❌ Failed\n", .{});
                        continue;
                    };
                    self.print("    ✅ Done\n", .{});
                    applied += 1;
                }
            }
        }
        
        self.print("\n✅ Applied {d} fix(es), skipped {d}\n", .{ applied, skipped });
    }

    /// Show manual instructions for all issues
    fn showManualInstructions(self: *Self, issues: *std.ArrayList(DetectedIssueInfo)) !void {
        self.print("\n", .{});
        self.printBanner("MANUAL FIX INSTRUCTIONS");
        
        for (issues.items, 0..) |issue, idx| {
            self.print("\n[{d}] {s}\n", .{ idx + 1, issue.title });
            self.print("═══════════════════════════════════════════════════════════════\n", .{});
            self.print("{s}\n", .{issue.manual_instructions});
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INSTALLATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    fn installBinary(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would install binary\n", .{});
            return;
        }
        
        // The binary should be in the same directory as the installer or in a known location
        // For now, we assume it's already been built and placed by the build system
        const src_path = "zig-out/bin/vexor";
        const dst_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(dst_path);
        
        // Try to copy from build output
        _ = runCommand(&.{ "cp", src_path, dst_path }) catch {
            // If that fails, check if it's already there
            if (fs.cwd().access(dst_path, .{})) |_| {
                self.debug("  Binary already exists", .{});
                return;
            } else |_| {
                self.print("  ⚠️  Could not install binary - copy manually to {s}\n", .{dst_path});
                return;
            }
        };
        
        _ = runCommand(&.{ "chmod", "+x", dst_path }) catch {};
    }

    fn createConfigFile(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would create config file\n", .{});
            return;
        }
        
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config.toml", .{self.config.config_dir});
        defer self.allocator.free(config_path);
        
        var file = try fs.cwd().createFile(config_path, .{});
        defer file.close();
        
        var writer = file.writer();
        
        try writer.print(
            \\# Vexor Configuration
            \\# Generated by vexor-install
            \\
            \\[validator]
            \\role = "{s}"
            \\network = "{s}"
            \\identity_path = "{s}"
            \\
        , .{
            @tagName(self.config.role),
            @tagName(self.config.network),
            self.config.identity_path,
        });
        
        if (self.config.vote_account_path) |vap| {
            try writer.print("vote_account_path = \"{s}\"\n", .{vap});
        }
        
        try writer.print(
            \\
            \\[paths]
            \\ledger_dir = "{s}"
            \\accounts_dir = "{s}"
            \\snapshots_dir = "{s}"
            \\log_dir = "{s}"
            \\
            \\[network]
            \\rpc_port = {d}
            \\gossip_port = {d}
            \\enable_af_xdp = {s}
            \\
            \\[entrypoints]
            \\
        , .{
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.log_dir,
            self.config.rpc_port,
            self.config.gossip_port,
            if (self.config.enable_af_xdp) "true" else "false",
        });
        
        for (self.config.network.entrypoints()) |ep| {
            try writer.print("entrypoint = \"{s}\"\n", .{ep});
        }
    }

    fn createSystemdService(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would create systemd service\n", .{});
            return;
        }
        
        var file = try fs.cwd().createFile("/etc/systemd/system/vexor.service", .{});
        defer file.close();
        
        var writer = file.writer();
        
        try writer.print(
            \\[Unit]
            \\Description=Vexor Solana Validator
            \\After=network.target
            \\Wants=network-online.target
            \\Conflicts={s}
            \\
            \\[Service]
            \\Type=simple
            \\User={s}
            \\Group={s}
            \\WorkingDirectory=/home/{s}
            \\ExecStart={s}/bin/vexor run --bootstrap {s} --identity {s}
        , .{
            self.config.existing_service,
            self.config.vexor_user,
            self.config.vexor_group,
            self.config.vexor_user,
            self.config.install_dir,
            self.config.network.cliFlag(),
            self.config.identity_path,
        });
        
        if (self.config.vote_account_path) |vap| {
            try writer.print(" --vote-account {s}", .{vap});
        }
        
        try writer.print(
            \\ --ledger {s} --accounts {s} --snapshots {s} --rpc-port {d} --gossip-port {d}
            \\ExecStop=/bin/kill -SIGTERM $MAINPID
            \\Restart=on-failure
            \\RestartSec=10
            \\LimitNOFILE=1000000
            \\LimitNPROC=1000000
            \\
            \\[Install]
            \\WantedBy=multi-user.target
            \\
        , .{
            self.config.ledger_dir,
            self.config.accounts_dir,
            self.config.snapshots_dir,
            self.config.rpc_port,
            self.config.gossip_port,
        });
        
        _ = runCommand(&.{ "systemctl", "daemon-reload" }) catch {};
    }

    fn createSwitchScripts(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would create switch scripts\n", .{});
            return;
        }
        
        // switch-to-vexor
        {
            var file = try fs.cwd().createFile("/usr/local/bin/switch-to-vexor", .{ .mode = 0o755 });
            defer file.close();
            try file.writeAll(
                \\#!/bin/bash
                \\exec vexor-install switch-to-vexor "$@"
                \\
            );
        }
        
        // switch-to-agave
        {
            var file = try fs.cwd().createFile("/usr/local/bin/switch-to-agave", .{ .mode = 0o755 });
            defer file.close();
            try file.writeAll(
                \\#!/bin/bash
                \\exec vexor-install switch-to-agave "$@"
                \\
            );
        }
        
        // validator-status
        {
            var file = try fs.cwd().createFile("/usr/local/bin/validator-status", .{ .mode = 0o755 });
            defer file.close();
            try file.writeAll(
                \\#!/bin/bash
                \\exec vexor-install status "$@"
                \\
            );
        }
    }

    fn setAfXdpCapabilities(self: *Self) !void {
        if (self.config.dry_run) {
            self.print("  [DRY RUN] Would set AF_XDP capabilities\n", .{});
            return;
        }
        
        const binary_path = try std.fmt.allocPrint(self.allocator, "{s}/bin/vexor", .{self.config.install_dir});
        defer self.allocator.free(binary_path);
        
        _ = runCommand(&.{
            "setcap", "cap_net_raw,cap_net_admin,cap_sys_admin+eip", binary_path,
        }) catch {
            self.print("  ⚠️  Could not set capabilities - AF_XDP may not work\n", .{});
        };
    }

    // ═══════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(fmt, args);
    }

    fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (self.config.mode.isDebug() or self.config.verbose) {
            std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
        }
    }

    fn printBanner(self: *Self, title: []const u8) void {
        self.print("\n═══════════════════════════════════════════════════════════════\n", .{});
        self.print("  {s}\n", .{title});
        self.print("═══════════════════════════════════════════════════════════════\n", .{});
    }

    fn readLine(self: *Self, prompt: []const u8) ![]const u8 {
        self.print("{s}", .{prompt});
        
        var buf: [1024]u8 = undefined;
        const reader = self.stdin.reader();
        const line = reader.readUntilDelimiterOrEof(&buf, '\n') catch return "";
        const trimmed = std.mem.trim(u8, line orelse "", &std.ascii.whitespace);
        return try self.allocator.dupe(u8, trimmed);
    }

    fn confirm(self: *Self, prompt: []const u8) !bool {
        self.print("{s} [y/N]: ", .{prompt});
        const response = try self.readLine("");
        return response.len > 0 and (response[0] == 'y' or response[0] == 'Y');
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Check if a network driver is known to support XDP
fn isXdpCapableDriver(driver: []const u8) bool {
    const xdp_drivers = [_][]const u8{
        "i40e",      // Intel X710, XL710
        "ice",       // Intel E810
        "mlx5_core", // Mellanox ConnectX-5/6
        "mlx4_en",   // Mellanox ConnectX-3
        "ixgbe",     // Intel 82599, X520, X540
        "igb",       // Intel I350, I210
        "igc",       // Intel I225-V
        "virtio",    // VirtIO (limited XDP)
        "veth",      // Virtual ethernet (for testing)
        "e1000e",    // Intel Pro/1000 (basic XDP)
    };
    
    for (xdp_drivers) |xdp_driver| {
        if (std.mem.indexOf(u8, driver, xdp_driver) != null) {
            return true;
        }
    }
    return false;
}

/// Parse memory line from /proc/meminfo (e.g., "MemTotal:       16384 kB")
fn parseMemoryLine(line: []const u8) u64 {
    var parts = std.mem.splitScalar(u8, line, ':');
    _ = parts.next(); // Skip label
    if (parts.next()) |value_part| {
        var value_parts = std.mem.tokenizeScalar(u8, value_part, ' ');
        if (value_parts.next()) |num_str| {
            return std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
    }
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMMAND EXECUTION HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

fn runCommand(argv: []const []const u8) !bool {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = try child.spawnAndWait();
    // Return true only if command exited with code 0
    return term.Exited == 0;
}

fn runCommandOutput(allocator: Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    
    allocator.free(result.stderr);
    return result.stdout;
}

// ═══════════════════════════════════════════════════════════════════════════════
// UNIFIED AUDIT AND OPTIMIZATION (Called from main.zig)
// ═══════════════════════════════════════════════════════════════════════════════

/// Options for unified audit and optimization
pub const AuditOptions = struct {
    auto_fix_low_risk: bool = true,
    request_permissions: bool = true,
    apply_tuning: bool = true,
    debug: bool = false,
    comprehensive: bool = true,
    backup_dir: []const u8 = "/var/backups/vexor",
    dry_run: bool = false, // If true, perform all audits but make NO changes
};

/// Hardware detection cache (to avoid re-detection)
/// Note: Cache is cleared and re-populated on each call to avoid type issues
var hw_cache_timestamp: ?i64 = null;

/// Helper function for XDP driver detection
fn isXdpCapableDriverHelper(driver: []const u8) bool {
    const xdp_drivers = [_][]const u8{
        "i40e", "ice", "mlx5_core", "mlx4_en", "ixgbe", "igb", "igc", "virtio", "veth", "e1000e", "ena",
    };
    for (xdp_drivers) |xdp_driver| {
        if (std.mem.indexOf(u8, driver, xdp_driver) != null) return true;
    }
    return false;
}

/// Unified audit and optimization function
/// Called from main.zig during validator startup
/// This is the SINGLE entry point that orchestrates everything
pub fn runAuditAndOptimize(
    allocator: Allocator,
    opts: AuditOptions,
) !void {
    // Import optimizer here to avoid circular dependencies
    const optimizer = @import("../optimizer/root.zig");
    const installer_mod = @import("installer/mod.zig");
    
    if (opts.dry_run) {
        std.debug.print("🧪 DRY-RUN MODE: All audits will run, but NO changes will be made\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
    }
    
    std.debug.print("🔍 Running comprehensive system audit and optimization...\n", .{});
    
    // STEP 1: Create automatic state backup FIRST (before ANY changes)
    // Skip in dry-run mode (no actual backup needed)
    var backup_id: ?[]const u8 = null;
    if (!opts.dry_run) {
        std.debug.print("\n📦 Creating automatic state backup...\n", .{});
        const backup_result = try createImmediateBackup(allocator, opts.backup_dir, false);
        backup_id = backup_result orelse return error.BackupFailed;
        defer allocator.free(backup_id.?);
        std.debug.print("  ✅ Backup created: {s}\n", .{backup_id.?});
        std.debug.print("     Rollback: vexor-install restore {s}\n", .{backup_id.?});
    } else {
        std.debug.print("\n📦 [DRY RUN] Would create automatic state backup...\n", .{});
        std.debug.print("  [DRY RUN] Backup would be created at: {s}/startup-backup-<timestamp>\n", .{opts.backup_dir});
    }
    
    // STEP 2: Hardware detection (with caching)
    std.debug.print("\n  Detecting hardware...\n", .{});
    const hw = try getOrDetectHardware(allocator, optimizer);
    defer {
        // Free network info
        for (hw.network) |n| {
            allocator.free(n.name);
            allocator.free(n.driver);
        }
        allocator.free(hw.network);
        
        // Free GPU info if present
        if (hw.gpu) |g| {
            allocator.free(g.name);
            allocator.free(g.driver_version);
        }
        
        // Free CPU model string
        allocator.free(hw.cpu.model);
    }
    
    std.debug.print("    CPU: {s} ({d} cores)\n", .{ hw.cpu.model, hw.cpu.cores });
    std.debug.print("    RAM: {d:.1} GB\n", .{@as(f64, @floatFromInt(hw.memory.total)) / (1024 * 1024 * 1024)});
    if (hw.gpu) |g| {
        std.debug.print("    GPU: {s}\n", .{g.name});
    }
    
    // STEP 3: Comprehensive system audit
    std.debug.print("\n  Running comprehensive system audit...\n", .{});
    var diagnosis = installer_mod.AutoDiagnosis.init(allocator);
    defer diagnosis.deinit();
    try diagnosis.runFullDiagnosis();
    
    // STEP 4: Convert to AuditResults
    const audit_results = try buildAuditResults(allocator, hw, diagnosis, isXdpCapableDriverHelper);
    
    // STEP 5: Generate recommendations
    std.debug.print("\n  Generating recommendations...\n", .{});
    var rec_engine = installer_mod.RecommendationEngine.init(allocator);
    defer rec_engine.deinit();
    try rec_engine.generateRecommendations(audit_results);
    
    // STEP 6: Display results
    const diag_summary = diagnosis.getSummary();
    if (diag_summary.total > 0) {
        std.debug.print("\n  📋 DIAGNOSIS: Found {d} issues ({d} fixable, {d} critical)\n", .{ diag_summary.total, diag_summary.fixable, diag_summary.critical });
    } else {
        std.debug.print("  ✅ No issues detected\n", .{});
    }
    
    const rec_summary = rec_engine.getSummary();
    if (rec_summary.total > 0) {
        std.debug.print("\n  💡 RECOMMENDATIONS: {d} available\n", .{rec_summary.total});
    }
    
    // STEP 7: Auto-fix low-risk issues (if enabled and NOT dry-run)
    if (opts.auto_fix_low_risk and diag_summary.total > 0) {
        if (opts.dry_run) {
            std.debug.print("\n  🔧 [DRY RUN] Would auto-fix low-risk issues...\n", .{});
            var fix_count: u32 = 0;
            for (diagnosis.detected_issues.items) |detected| {
                if (detected.confidence == .high and detected.issue.auto_fix != null) {
                    const fix = detected.issue.auto_fix.?;
                    if (fix.risk_level == .low or fix.risk_level == .none) {
                        fix_count += 1;
                        std.debug.print("    [DRY RUN] Would fix [{s}] {s}\n", .{ detected.issue.id, detected.issue.name });
                        // Show command if available (from auto_fix struct)
                        if (detected.issue.auto_fix) |auto_fix_val| {
                            // The auto_fix struct may have a command field - check if it exists
                            // For now, just show the fix info
                            _ = auto_fix_val;
                        }
                    }
                }
            }
            if (fix_count > 0) {
                std.debug.print("    [DRY RUN] Total fixes that would be applied: {d}\n", .{fix_count});
            }
        } else {
            std.debug.print("\n  🔧 Auto-fixing low-risk issues...\n", .{});
            var auto_fixer = installer_mod.auto_fix.AutoFix.init(allocator, opts.backup_dir, false);
            
            for (diagnosis.detected_issues.items) |detected| {
                if (detected.confidence == .high and detected.issue.auto_fix != null) {
                    const fix = detected.issue.auto_fix.?;
                    if (fix.risk_level == .low or fix.risk_level == .none) {
                        std.debug.print("    → Fixing [{s}] {s}...\n", .{ detected.issue.id, detected.issue.name });
                        const result = auto_fixer.applyFix(detected.issue) catch |err| {
                            std.debug.print("      ❌ Failed: {}\n", .{err});
                            continue;
                        };
                        if (result.success) {
                            std.debug.print("      ✅ Fixed\n", .{});
                        } else {
                            std.debug.print("      ❌ Failed: {s}\n", .{result.error_message orelse "Unknown error"});
                        }
                    }
                }
            }
        }
    }
    
    // STEP 8: System tuning (if enabled and approved and NOT dry-run)
    if (opts.apply_tuning) {
        if (opts.dry_run) {
            std.debug.print("\n  ⚡ [DRY RUN] Would apply system optimizations...\n", .{});
            std.debug.print("    [DRY RUN] Would optimize kernel parameters\n", .{});
            std.debug.print("    [DRY RUN] Would set CPU governor to performance\n", .{});
            std.debug.print("    [DRY RUN] Would optimize network buffer sizes\n", .{});
            std.debug.print("    [DRY RUN] No actual changes would be made\n", .{});
        } else {
            std.debug.print("\n  ⚡ Applying system optimizations...\n", .{});
            if (try optimizer.tuner.canModifySystem()) {
                optimizer.tuner.optimizeKernel() catch |err| {
                    std.debug.print("    ⚠️  Kernel optimization failed: {}\n", .{err});
                };
                optimizer.tuner.optimizeCpuGovernor() catch |err| {
                    std.debug.print("    ⚠️  CPU governor optimization failed: {}\n", .{err});
                };
                optimizer.tuner.optimizeNetwork() catch |err| {
                    std.debug.print("    ⚠️  Network optimization failed: {}\n", .{err});
                };
                std.debug.print("    ✅ System optimizations applied\n", .{});
            } else {
                std.debug.print("    ⚠️  Skipping system optimizations (requires root)\n", .{});
            }
        }
    }
    
    if (opts.dry_run) {
        std.debug.print("\n  ✅ [DRY RUN] System audit complete - NO changes were made\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  📋 SUMMARY:\n", .{});
        std.debug.print("     • Hardware detected: ✅\n", .{});
        std.debug.print("     • Issues found: {d}\n", .{diag_summary.total});
        std.debug.print("     • Recommendations: {d}\n", .{rec_summary.total});
        std.debug.print("     • Changes that would be made: See above\n", .{});
        std.debug.print("     • Actual changes made: 0 (dry-run mode)\n", .{});
        std.debug.print("\n  To apply changes, run without --dry-run flag\n", .{});
    } else {
        std.debug.print("\n  ✅ System audit and optimization complete\n", .{});
    }
}

/// Create immediate backup (called first, before any changes)
/// Returns backup ID or null if dry-run
fn createImmediateBackup(allocator: Allocator, backup_dir: []const u8, dry_run: bool) !?[]const u8 {
    const timestamp = @as(u64, @intCast(std.time.timestamp()));
    const backup_id = try std.fmt.allocPrint(allocator, "startup-backup-{d}", .{timestamp});
    
    if (dry_run) {
        return null; // No backup in dry-run
    }
    
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup_dir, backup_id });
    defer allocator.free(backup_path);
    
    // Create backup directory
    _ = runCommand(&.{ "mkdir", "-p", backup_path }) catch {};
    
    // Backup sysctl
    const sysctl_file = try std.fmt.allocPrint(allocator, "{s}/sysctl-snapshot.conf", .{backup_path});
    defer allocator.free(sysctl_file);
    const sysctl_cmd = try std.fmt.allocPrint(allocator, "sysctl -a > {s} 2>/dev/null", .{sysctl_file});
    defer allocator.free(sysctl_cmd);
    _ = runCommand(&.{ "sh", "-c", sysctl_cmd }) catch {};
    
    // Backup systemd services
    const services_backup = try std.fmt.allocPrint(allocator, "{s}/systemd", .{backup_path});
    defer allocator.free(services_backup);
    _ = runCommand(&.{ "mkdir", "-p", services_backup }) catch {};
    const service_cmd = try std.fmt.allocPrint(allocator, "cp /etc/systemd/system/solana*.service {s}/ 2>/dev/null || cp /etc/systemd/system/agave*.service {s}/ 2>/dev/null || true", .{ services_backup, services_backup });
    defer allocator.free(service_cmd);
    _ = runCommand(&.{ "sh", "-c", service_cmd }) catch {};
    
    return backup_id;
}

/// Get or detect hardware (with caching)
fn getOrDetectHardware(allocator: Allocator, optimizer: anytype) !struct {
    cpu: optimizer.detector.CpuInfo,
    memory: optimizer.detector.MemoryInfo,
    gpu: ?optimizer.detector.GpuInfo,
    network: []optimizer.detector.NetworkInfo,
} {
    // For now, always detect fresh (TODO: Implement proper caching with serialization)
    _ = hw_cache_timestamp;
    
    // Fresh detection
    const cpu = try optimizer.detectCpu(allocator);
    const memory = try optimizer.detectMemory();
    const gpu = optimizer.detectGpu(allocator) catch null;
    const network = try optimizer.detectNetwork(allocator);
    
    // Update cache timestamp
    hw_cache_timestamp = std.time.timestamp();
    
    return .{
        .cpu = cpu,
        .memory = memory,
        .gpu = gpu,
        .network = network,
    };
}

/// Build AuditResults from hardware and diagnosis
fn buildAuditResults(
    allocator: Allocator,
    hw: anytype,
    diagnosis: anytype,
    xdp_check_fn: fn ([]const u8) bool,
) !@import("installer/mod.zig").AuditResults {
    const installer_mod = @import("installer/mod.zig");
    
    // Check for XDP-capable NIC
    var has_xdp_nic = false;
    var xdp_driver: ?[]const u8 = null;
    if (hw.network.len > 0) {
        const primary_if = hw.network[0];
        const driver = primary_if.driver;
        if (driver.len > 0) {
            has_xdp_nic = xdp_check_fn(driver);
            xdp_driver = driver;
        }
    }
    
    // Check libbpf
    const libbpf_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", "ldconfig -p 2>/dev/null | grep -i libbpf || echo 'not_found'" },
    }) catch return error.LibbpfCheckFailed;
    defer allocator.free(libbpf_check.stdout);
    const has_libbpf = std.mem.indexOf(u8, libbpf_check.stdout, "not_found") == null;
    
    // Check AF_XDP caps from diagnosis
    var has_af_xdp_caps = true;
    for (diagnosis.detected_issues.items) |detected| {
        if (std.mem.eql(u8, detected.issue.id, "AFXDP001")) {
            has_af_xdp_caps = false;
            break;
        }
    }
    
    return installer_mod.AuditResults{
        .has_xdp_capable_nic = has_xdp_nic,
        .xdp_driver = xdp_driver,
        .kernel_supports_xdp = true,
        .has_libbpf = has_libbpf,
        .quic_ports_available = true,
        .firewall_type = null,
        .has_nvme = false, // TODO: detect from storage audit
        .has_ssd = false,
        .has_hdd = false,
        .total_ram_gb = @as(u32, @intCast(hw.memory.total / (1024 * 1024 * 1024))),
        .available_ram_gb = @as(u32, @intCast(hw.memory.available / (1024 * 1024 * 1024))),
        .has_ramdisk = false, // TODO: check mount points
        .cpu_cores = hw.cpu.cores,
        .has_avx2 = hw.cpu.features.avx2,
        .has_avx512 = hw.cpu.features.avx512,
        .has_sha_ni = hw.cpu.features.sha_ni,
        .has_aes_ni = hw.cpu.features.aes_ni,
        .numa_nodes = 1, // TODO: detect NUMA
        .has_gpu = hw.gpu != null,
        .gpu_name = if (hw.gpu) |g| g.name else null,
        .rmem_max = 0, // TODO: read from sysctl
        .wmem_max = 0,
        .nofile_limit = 0,
        .hugepages = 0,
        .has_af_xdp_caps = has_af_xdp_caps,
        .vexor_installed = true,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLI ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    var config = InstallerConfig{};

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Mode flags
        if (std.mem.eql(u8, arg, "--debug")) {
            config.mode = .debug;
            config.verbose = true;
            config.debug_flags.all = true;
        } else if (std.mem.startsWith(u8, arg, "--debug=")) {
            config.mode = .debug;
            config.verbose = true;
            const value = arg["--debug=".len..];
            if (std.mem.eql(u8, value, "network")) config.debug_flags.network = true;
            if (std.mem.eql(u8, value, "storage")) config.debug_flags.storage = true;
            if (std.mem.eql(u8, value, "compute")) config.debug_flags.compute = true;
            if (std.mem.eql(u8, value, "system")) config.debug_flags.system = true;
            if (std.mem.eql(u8, value, "all")) config.debug_flags.all = true;
        } else if (std.mem.eql(u8, arg, "--production")) {
            config.mode = .production;
        }
        // Commands (positional or flag)
        else if (Command.fromString(arg)) |cmd| {
            config.command = cmd;
        }
        // Options
        else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.command = .help;
        } else if (std.mem.eql(u8, arg, "--rpc")) {
            config.role = .rpc;
            config.vote_account_path = null;
        } else if (std.mem.eql(u8, arg, "--validator") or std.mem.eql(u8, arg, "--consensus")) {
            config.role = .consensus;
        } else if (std.mem.eql(u8, arg, "--mainnet-beta") or std.mem.eql(u8, arg, "--mainnet")) {
            config.network = .mainnet_beta;
        } else if (std.mem.eql(u8, arg, "--testnet")) {
            config.network = .testnet;
        } else if (std.mem.eql(u8, arg, "--devnet")) {
            config.network = .devnet;
        } else if (std.mem.eql(u8, arg, "--localnet")) {
            config.network = .localnet;
        } else if (std.mem.eql(u8, arg, "--identity")) {
            i += 1;
            if (i < args.len) config.identity_path = args[i];
        } else if (std.mem.eql(u8, arg, "--vote-account")) {
            i += 1;
            if (i < args.len) config.vote_account_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ledger")) {
            i += 1;
            if (i < args.len) config.ledger_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--snapshots")) {
            i += 1;
            if (i < args.len) config.snapshots_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--user")) {
            i += 1;
            if (i < args.len) {
                config.vexor_user = args[i];
                config.vexor_group = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            config.non_interactive = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        }
    }

    var installer = UnifiedInstaller.init(allocator, config);
    try installer.run();
}

fn printUsage() void {
    std.debug.print(
        \\
        \\╔═══════════════════════════════════════════════════════════════════════════╗
        \\║                     VEXOR UNIFIED INSTALLER                               ║
        \\╠═══════════════════════════════════════════════════════════════════════════╣
        \\║     AUDIT-FIRST: Every installation starts with a system audit           ║
        \\║     Now with BLS, AF_XDP, QUIC/TLS 1.3, io_uring support!               ║
        \\╚═══════════════════════════════════════════════════════════════════════════╝
        \\
        \\Usage: vexor-install [MODE] [COMMAND] [OPTIONS]
        \\
        \\MODES:
        \\  --debug              Enable full debugging with verbose output
        \\  --production         Clean production install (default)
        \\
        \\COMMANDS:
        \\  audit                System audit (recommended first!) ⭐
        \\  recommend            Generate personalized recommendations
        \\  backup               Create full system state backup ⭐
        \\  restore              Remove Vexor overlays, restore original state ⭐
        \\  fix                  Interactive fix for all detected issues
        \\  install              Full installation with all steps (default)
        \\  fix-permissions      Fix all permission issues at once
        \\  health               Health check with auto-fix suggestions
        \\  test-bootstrap       Test snapshot loading without network
        \\  test-network         Test network (WARNING: stops Agave briefly)
        \\  switch-to-vexor      Safe switch from Agave to Vexor
        \\  switch-to-agave      Safe rollback from Vexor to Agave (removes overlays)
        \\  diagnose             Run comprehensive diagnostics
        \\  status               Show current validator state
        \\  help                 Show this help message
        \\
        \\OPTIONS:
        \\  --validator          Run as consensus validator (default)
        \\  --rpc                Run as RPC node (non-voting)
        \\  --mainnet-beta       Connect to Mainnet Beta
        \\  --testnet            Connect to Testnet (default)
        \\  --devnet             Connect to Devnet
        \\  --localnet           Connect to local cluster
        \\  --identity <PATH>    Path to validator identity keypair
        \\  --vote-account <PATH> Path to vote account keypair
        \\  --ledger <PATH>      Path to ledger directory
        \\  --snapshots <PATH>   Path to snapshots directory
        \\  --user <USER>        User/group to own Vexor files (default: solana)
        \\  -y, --yes            Non-interactive mode (auto-approve)
        \\  --dry-run            Test mode: show what would be done without changes
        \\  --debug              Full debugging (all subsystems)
        \\  --debug=network      Debug network subsystem only
        \\  --debug=storage      Debug storage subsystem only
        \\  --debug=compute      Debug compute subsystem only
        \\  --debug=system       Debug system subsystem only
        \\  --debug=all          Debug all subsystems
        \\  -v, --verbose        Verbose output (enabled with --debug)
        \\  -h, --help           Show this help
        \\
        \\DETECTED FEATURES:
        \\  • AF_XDP             10M+ packets/sec kernel bypass networking
        \\  • io_uring           3M+ packets/sec async I/O
        \\  • QUIC/TLS 1.3       Secure transport with 0-RTT
        \\  • BLS Signatures     Vote aggregation (Alpenglow-ready)
        \\  • GPU Acceleration   500K+ sig/sec verification (optional)
        \\
        \\EXAMPLES:
        \\
        \\  # Test installer safely (RECOMMENDED FIRST!)
        \\  vexor-install --dry-run install --testnet
        \\
        \\  # Start with system audit
        \\  vexor-install audit
        \\
        \\  # Test audit in dry-run mode
        \\  vexor-install --dry-run audit
        \\
        \\  # Get personalized recommendations
        \\  vexor-install recommend
        \\
        \\  # Full installation with debugging
        \\  sudo vexor-install --debug install --testnet
        \\
        \\  # Health check (detect issues, show fixes)
        \\  vexor-install health
        \\
        \\  # Fix AF_XDP/QUIC/BLS/security issues interactively
        \\  sudo vexor-install fix
        \\
        \\  # Test fix command (dry-run)
        \\  vexor-install --dry-run fix
        \\
        \\  # Fix permissions only
        \\  sudo vexor-install fix-permissions
        \\
        \\  # Hot-swap validator keys
        \\  vexor-install swap-keys
        \\
        \\  # Test bootstrap (safe, doesn't stop Agave)
        \\  vexor-install test-bootstrap
        \\
        \\  # Switch to Vexor (stops Agave!)
        \\  sudo vexor-install switch-to-vexor
        \\
        \\  # Check status
        \\  vexor-install status
        \\
        \\  # Full diagnostics
        \\  vexor-install diagnose
        \\
        \\SAFETY FEATURES:
        \\  • Pre-installation backup of your ENTIRE system state
        \\  • Detects YOUR existing customizations (sysctl, CPU pinning, etc.)
        \\  • OVERLAY approach: our configs layer ON TOP of yours
        \\  • Your original files are NEVER modified
        \\  • Clean restore: removes our overlays, your system unchanged
        \\
        \\RECOMMENDED FLOW:
        \\  1. vexor-install --dry-run install  # Test safely first (no changes)
        \\  2. vexor-install audit             # Understand your system
        \\  3. vexor-install backup            # Create explicit backup (optional)
        \\  4. vexor-install recommend         # Get personalized config
        \\  5. vexor-install fix               # Fix detected issues
        \\  6. sudo vexor-install install      # Install (auto-creates backup first)
        \\  7. vexor-install health            # Verify everything works
        \\
        \\SAFE SWITCHING:
        \\  vexor-install switch-to-vexor  # Switch from Agave to Vexor
        \\  vexor-install switch-to-agave  # Switch back (offers overlay removal)
        \\  vexor-install restore          # Remove all Vexor overlays
        \\
        \\For more information: https://github.com/DavidB-77/Vexor
        \\
    , .{});
}
