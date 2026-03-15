//! ╔═══════════════════════════════════════════════════════════════════════════╗
//! ║                              VEXOR                                        ║
//! ║           High-Performance Solana Validator Client                        ║
//! ║                                                                           ║
//! ║  Velox (swift) + Fulgor (brilliance) = Vexor                             ║
//! ║  Lightning-fast • Lightweight • Consumer-grade hardware                   ║
//! ╚═══════════════════════════════════════════════════════════════════════════╝
//!
//! A next-generation Solana validator client built in Zig for:
//! - Maximum performance (targeting 1M+ TPS)
//! - Minimal resource footprint
//! - Consumer-grade hardware compatibility
//! - Automatic system optimization
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                         VEXOR RUNTIME                           │
//! ├─────────────┬─────────────┬─────────────┬─────────────┬─────────┤
//! │  NETWORK    │  CONSENSUS  │   STORAGE   │   CRYPTO    │ OPTIM.  │
//! │  ─────────  │  ─────────  │   ───────   │   ──────    │ ─────── │
//! │  AF_XDP     │  Tower BFT  │  RAM Disk   │  Ed25519    │ HW Det. │
//! │  QUIC       │  Alpenglow  │  NVMe SSD   │  BLS        │ Tuning  │
//! │  TPU/TVU    │  Votor      │  AccountsDB │  GPU(opt)   │ LLM(?)  │
//! └─────────────┴─────────────┴─────────────┴─────────────┴─────────┘

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const os = std.os;

// Global signal handler flag
var signal_received: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn signalHandler(sig: c_int) callconv(.C) void {
    const sig_u: u32 = @intCast(sig);
    // Only handle once to avoid loop
    const prev = signal_received.swap(sig_u, .seq_cst);
    if (prev != 0) {
        // Already handling a signal, just exit
        std.posix.exit(128 + @as(u8, @intCast(sig)));
    }

    // Write to stderr directly (async-signal-safe)
    const msg = switch (sig) {
        2 => "[SIGNAL] Received SIGINT (2)\n",
        15 => "[SIGNAL] Received SIGTERM (15)\n",
        1 => "[SIGNAL] Received SIGHUP (1)\n",
        6 => "[SIGNAL] Received SIGABRT (6)\n",
        11 => "[SIGNAL] Received SIGSEGV (11) - SEGFAULT!\n",
        else => "[SIGNAL] Received unknown signal\n",
    };
    _ = std.posix.write(2, msg) catch {};

    // For SIGSEGV, try to print a stack trace
    if (sig == 11) {
        // Use builtin debug to try to get stack trace
        std.debug.dumpCurrentStackTrace(null);
    }

    // Exit with signal code
    std.posix.exit(128 + @as(u8, @intCast(sig)));
}

fn installSignalHandlers() void {
    const signals = [_]u6{ 1, 2, 6, 11, 15 }; // SIGHUP, SIGINT, SIGABRT, SIGSEGV, SIGTERM
    for (signals) |sig| {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(sig, &act, null) catch {};
    }
    std.debug.print("[SIGNAL] Signal handlers installed for SIGHUP, SIGINT, SIGABRT, SIGSEGV, SIGTERM\n", .{});
}

// ══════════════════════════════════════════════════════════════════════════════
// MODULE IMPORTS
// ══════════════════════════════════════════════════════════════════════════════
pub const core = @import("core/root.zig");
pub const network = @import("network/root.zig");
pub const consensus = @import("consensus/root.zig");
pub const storage = @import("storage/root.zig");
pub const crypto = @import("crypto/root.zig");
pub const optimizer = @import("optimizer/root.zig");
pub const runtime = @import("runtime/root.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const rpc = @import("rpc/root.zig");
pub const installer = @import("tools/installer.zig");

// ══════════════════════════════════════════════════════════════════════════════
// VERSION & BUILD INFO
// ══════════════════════════════════════════════════════════════════════════════
pub const version = build_options.version;
pub const build_mode = build_options.build_mode;

pub const features = struct {
    pub const gpu = build_options.gpu_enabled;
    pub const af_xdp = build_options.af_xdp_enabled;
    pub const ramdisk = build_options.ramdisk_enabled;
    pub const alpenglow = build_options.alpenglow_enabled;
    pub const auto_optimize = build_options.auto_optimize_enabled;
};

// ══════════════════════════════════════════════════════════════════════════════
// MAIN ENTRY POINT
// ══════════════════════════════════════════════════════════════════════════════
pub fn main() !void {
    // Install signal handlers FIRST to catch any crashes
    installSignalHandlers();

    // Initialize allocator
    // Fast GPA for bulk bootstrap — safety checks isolated to cache_arena in AccountsDb
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print banner
    printBanner();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Handle commands
    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run") or std.mem.eql(u8, command, "validator")) {
        runValidator(allocator, args[2..]) catch |err| {
            const sig = signal_received.load(.seq_cst);
            std.debug.print("\n[FATAL] Validator exited with error: {}\n", .{err});
            std.debug.print("[FATAL] Signal received: {d}\n", .{sig});
            std.debug.print("[FATAL] Timestamp: {d}\n", .{std.time.timestamp()});
            return err;
        };
        const sig = signal_received.load(.seq_cst);
        std.debug.print("\n[EXIT] Validator returned normally (no error) - THIS SHOULD NOT HAPPEN!\n", .{});
        std.debug.print("[EXIT] Signal received: {d}\n", .{sig});
        std.debug.print("[EXIT] Timestamp: {d}\n", .{std.time.timestamp()});
    } else if (std.mem.eql(u8, command, "rpc")) {
        // RPC mode - add --no-voting flag
        var rpc_args = try allocator.alloc([]const u8, args.len - 1);
        defer allocator.free(rpc_args);
        rpc_args[0] = "--no-voting";
        for (args[2..], 0..) |arg, i| {
            rpc_args[i + 1] = arg;
        }
        try runValidator(allocator, rpc_args[0 .. args.len - 2 + 1]);
    } else if (std.mem.eql(u8, command, "version")) {
        printVersion();
    } else if (std.mem.eql(u8, command, "info")) {
        try printSystemInfo(allocator);
    } else if (std.mem.eql(u8, command, "optimize")) {
        try runOptimizer(allocator);
    } else if (std.mem.eql(u8, command, "diagnose") or std.mem.eql(u8, command, "health")) {
        try runDiagnostics(allocator);
    } else if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// VALIDATOR RUNTIME
// ══════════════════════════════════════════════════════════════════════════════
fn runValidator(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // 🔍 THREAD LEAK DEBUGGING: Initialize tracer FIRST before ANY other code
    // This must be the VERY FIRST thing to catch all thread spawns
    diagnostics.thread_trace.initGlobal(allocator) catch |err| {
        std.debug.print("[THREAD-TRACE] WARNING: Failed to initialize tracer: {}\n", .{err});
    };

    std.debug.print("\n🚀 Starting Vexor Validator...\n\n", .{});

    // Check for production/bootstrap and debug modes
    var use_bootstrap = false;
    var debug_mode = false;
    var dashboard_cli_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--bootstrap") or
            std.mem.eql(u8, arg, "--production") or
            std.mem.eql(u8, arg, "--full-start"))
        {
            use_bootstrap = true;
        }
        if (std.mem.eql(u8, arg, "--debug") or
            std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "-v"))
        {
            debug_mode = true;
        }
        if (std.mem.eql(u8, arg, "--dashboard")) {
            dashboard_cli_mode = true;
        }
    }

    if (debug_mode) {
        std.debug.print("🔧 DEBUG MODE ENABLED - Verbose logging active\n\n", .{});
        std.debug.print("System Info:\n", .{});
        std.debug.print("  OS: {s}\n", .{@tagName(@import("builtin").os.tag)});
        std.debug.print("  Arch: {s}\n", .{@tagName(@import("builtin").cpu.arch)});
        std.debug.print("  Build: {s}\n", .{if (@import("builtin").mode == .Debug) "Debug" else "Release"});
        std.debug.print("\n", .{});
    }

    // Initialize test mode if enabled
    try diagnostics.testing.initTestMode(allocator, args);
    const test_mode = diagnostics.testing.global_test_config.test_mode;

    // Initialize metrics
    try diagnostics.metrics.initMetrics(allocator);

    // Initialize diagnostics engine first (for error tracking throughout startup)
    std.debug.print("📊 Initializing diagnostics engine...\n", .{});
    try diagnostics.initGlobal(allocator, .{
        .min_severity = if (diagnostics.testing.global_test_config.verbose) .debug else .info,
        .auto_remediate = !test_mode, // Disable auto-remediate in test mode
        .console_output = true,
        .colored_output = true,
    });
    defer diagnostics.deinitGlobal();

    // Start dashboard stream server if enabled
    var dashboard_server: ?diagnostics.DashboardStreamServer = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--enable-dashboard")) {
            std.debug.print("📊 Starting dashboard stream server...\n", .{});
            dashboard_server = diagnostics.DashboardStreamServer.init(allocator, 8910);
            try dashboard_server.?.start();
            break;
        }
    }
    defer if (dashboard_server) |*ds| ds.deinit();
    defer diagnostics.metrics.deinitMetrics();

    diagnostics.logInfo(.core_init, "Vexor validator starting");

    // Load configuration
    const config = try core.Config.load(allocator, args);
    defer config.deinit();
    diagnostics.logInfo(.core_config, "Configuration loaded");

    // Initialize InfluxDB reporter for Solana Foundation dashboard compatibility
    // Uses SOLANA_METRICS_CONFIG environment variable (same as Agave)
    const cluster_name = @tagName(config.cluster);
    const identity_str = if (config.identity_path) |_| "vexor" else "unknown";
    const influx_enabled = diagnostics.influx_reporter.initFromEnv(allocator, identity_str, cluster_name) catch false;
    if (influx_enabled) {
        std.debug.print("📊 InfluxDB metrics enabled (Solana Foundation compatible)\n", .{});
    }

    // Run unified audit and optimization system (replaces separate optimizer + installer calls)
    if (features.auto_optimize and config.enable_auto_optimize) {
        diagnostics.logInfo(.diagnostics, "Unified audit and optimization starting");
        try installer.runAuditAndOptimize(allocator, .{
            .auto_fix_low_risk = true,
            .request_permissions = !test_mode, // Skip permission requests in test mode
            .apply_tuning = true,
            .debug = debug_mode,
            .comprehensive = true, // Check EVERYTHING
            .backup_dir = "/var/backups/vexor",
            .dry_run = false, // Set to true for testing (no actual changes)
        });
        diagnostics.logInfo(.diagnostics, "Unified audit and optimization complete");
    } else {
        diagnostics.logInfo(.diagnostics, "Unified audit and optimization skipped");
    }

    // Initialize runtime
    var validator_runtime = try runtime.Runtime.init(allocator, config);
    defer validator_runtime.deinit();

    // Start validator
    std.debug.print("✅ Validator initialized\n", .{});
    diagnostics.logInfo(.core_init, "Validator initialization complete");

    // Enable dashboard CLI mode if requested
    if (dashboard_cli_mode) {
        validator_runtime.setDashboardMode(true);
    }

    if (use_bootstrap) {
        // Production mode: Full bootstrap with snapshot download, tower loading, voting
        std.debug.print("📦 Starting PRODUCTION MODE (with snapshot bootstrap)...\n\n", .{});
        diagnostics.logInfo(.core_init, "Production bootstrap starting");

        const result = try validator_runtime.startWithBootstrap();

        std.debug.print("✅ Bootstrap complete!\n", .{});
        std.debug.print("   Start slot: {d}\n", .{result.start_slot});
        std.debug.print("   Accounts loaded: {d}\n", .{result.accounts_loaded});
        std.debug.print("   Total lamports: {d}\n\n", .{result.total_lamports});
        diagnostics.logInfo(.core_init, "Production bootstrap complete");
    } else {
        // Quick mode: Networking only (for testing)
        std.debug.print("📡 Starting QUICK MODE (networking only)...\n\n", .{});
        diagnostics.logInfo(.core_init, "Quick start (no snapshot)");
        try validator_runtime.start();
    }

    // Run until shutdown signal
    try validator_runtime.run();
}

fn runOptimizer(allocator: std.mem.Allocator) !void {
    std.debug.print("\n⚡ Vexor System Optimizer\n", .{});
    std.debug.print("─────────────────────────\n\n", .{});

    try optimizer.runInteractive(allocator);
}

fn runDiagnostics(allocator: std.mem.Allocator) !void {
    std.debug.print("\n🔍 Vexor Diagnostics & Health Check\n", .{});
    std.debug.print("───────────────────────────────────\n\n", .{});

    // Initialize diagnostics for health checks
    const diag_engine = try diagnostics.DiagnosticsEngine.init(allocator, .{
        .console_output = false,
        .auto_remediate = false,
    });
    defer diag_engine.deinit();

    // Run health checks
    const health_status = diag_engine.health_monitor.runChecks();

    // Display results
    std.debug.print("📊 Health Score: {d}/100\n", .{health_status.score});
    std.debug.print("✅ Checks Passed: {d}/{d}\n\n", .{ health_status.checks_passed, health_status.checks_run });

    if (health_status.healthy) {
        std.debug.print("\x1b[32m✓ System is healthy\x1b[0m\n\n", .{});
    } else {
        std.debug.print("\x1b[33m⚠ Issues detected:\x1b[0m\n\n", .{});
    }

    // Show any issues
    for (health_status.issues) |issue| {
        const severity_color = issue.severity.toColor();
        std.debug.print("  {s}[{s}]\x1b[0m {s}: {s}\n", .{
            severity_color,
            issue.severity.toString(),
            issue.component.toString(),
            issue.message,
        });
        if (issue.metric_value) |val| {
            std.debug.print("         Value: {d:.2} (threshold: {d:.2})\n", .{
                val,
                issue.threshold orelse 0,
            });
        }
    }

    // System info summary
    std.debug.print("\n📋 System Summary:\n", .{});

    const mem_info = try optimizer.detectMemory();
    const mem_used_pct = 100.0 - (@as(f64, @floatFromInt(mem_info.available)) / @as(f64, @floatFromInt(mem_info.total)) * 100.0);
    std.debug.print("  Memory: {d:.1}% used ({d:.1} GB / {d:.1} GB)\n", .{
        mem_used_pct,
        @as(f64, @floatFromInt(mem_info.total - mem_info.available)) / (1024 * 1024 * 1024),
        @as(f64, @floatFromInt(mem_info.total)) / (1024 * 1024 * 1024),
    });

    // Component status
    std.debug.print("\n🔌 Components:\n", .{});
    std.debug.print("  Diagnostics Engine: \x1b[32m●\x1b[0m Active\n", .{});
    std.debug.print("  Health Monitor: \x1b[32m●\x1b[0m Running\n", .{});
    std.debug.print("  Auto-Remediation: {s}\n", .{if (features.auto_optimize) "\x1b[32m●\x1b[0m Enabled" else "\x1b[90m○\x1b[0m Disabled"});
    std.debug.print("  LLM Assistant: \x1b[90m○\x1b[0m Not configured\n", .{});

    std.debug.print("\n💡 Run 'vexor optimize' to apply system optimizations\n", .{});
    std.debug.print("💡 Run 'vexor validator' with --enable-llm-assist for AI diagnostics\n\n", .{});
}

// ══════════════════════════════════════════════════════════════════════════════
// OUTPUT HELPERS
// ══════════════════════════════════════════════════════════════════════════════
fn printBanner() void {
    const banner =
        \\
        \\  ██╗   ██╗███████╗██╗  ██╗ ██████╗ ██████╗ 
        \\  ██║   ██║██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗
        \\  ██║   ██║█████╗   ╚███╔╝ ██║   ██║██████╔╝
        \\  ╚██╗ ██╔╝██╔══╝   ██╔██╗ ██║   ██║██╔══██╗
        \\   ╚████╔╝ ███████╗██╔╝ ██╗╚██████╔╝██║  ██║
        \\    ╚═══╝  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝
        \\
        \\  Solana Validator Client v{s} [{s}]
        \\  ═══════════════════════════════════════════
        \\
    ;
    std.debug.print(banner, .{ version, build_mode });
}

fn printVersion() void {
    std.debug.print("Vexor v{s}\n", .{version});
    std.debug.print("Build: {s}\n", .{build_mode});
    std.debug.print("Zig: {}\n", .{builtin.zig_version});

    std.debug.print("\nFeatures:\n", .{});
    std.debug.print("  GPU Acceleration: {}\n", .{features.gpu});
    std.debug.print("  AF_XDP Networking: {}\n", .{features.af_xdp});
    std.debug.print("  RAM Disk Storage: {}\n", .{features.ramdisk});
    std.debug.print("  Alpenglow Consensus: {}\n", .{features.alpenglow});
    std.debug.print("  Auto-Optimizer: {}\n", .{features.auto_optimize});
}

fn printUsage() void {
    const usage =
        \\
        \\Usage: vexor <command> [options]
        \\
        \\Commands:
        \\  run, validator    Start the validator (consensus mode)
        \\  rpc               Start as RPC node (non-voting)
        \\  optimize          System optimizer and audit tool
        \\  diagnose, health  Run health checks and diagnostics
        \\  info              Show system information
        \\  version           Show version information
        \\  help              Show this help message
        \\
        \\Role Selection (like Agave/Firedancer):
        \\  --validator                    Run as consensus validator (default)
        \\  --rpc                          Run as RPC node (non-voting)
        \\  --no-voting                    Alias for --rpc
        \\
        \\Network Selection (like Agave/Firedancer):
        \\  --mainnet-beta                 Connect to Mainnet Beta (production)
        \\  --testnet                      Connect to Testnet (default)
        \\  --devnet                       Connect to Devnet
        \\  --localnet                     Connect to local test cluster
        \\
        \\Validator Options (compatible with Agave/Firedancer):
        \\  --identity <KEYPAIR>           Path to validator identity keypair
        \\  --vote-account <KEYPAIR>       Path to vote account keypair
        \\  --authorized-voter <KEYPAIR>   Path to authorized voter keypair
        \\  --ledger <DIR>                 Use DIR as ledger location
        \\  --accounts <DIR>               Use DIR for accounts location
        \\  --snapshots <DIR>              Use DIR for snapshots location
        \\  --log <PATH>                   Log to file at PATH (use - for stdout)
        \\
        \\Network Options:
        \\  --entrypoint <HOST:PORT>       Cluster entrypoint address
        \\  --known-validator <PUBKEY>     Known validator pubkey (repeatable)
        \\  --expected-genesis-hash <HASH> Expected genesis block hash
        \\  --expected-shred-version <VER> Expected shred version
        \\  --rpc-port <PORT>              RPC port (default: 8899)
        \\  --rpc-url <URL>                Override RPC URL (e.g., local test-validator)
        \\  --rpc-bind-address <ADDR>      RPC bind address (default: 0.0.0.0)
        \\  --dynamic-port-range <LOW-HIGH> Dynamic port range (default: 8000-10000)
        \\  --gossip-port <PORT>           Gossip port (default: 8001)
        \\  --tvu-port <PORT>              TVU (shred receive) port (default: 8004)
        \\  --public-ip <IP>               PUBLIC IP for gossip advertisement (REQUIRED!)
        \\                                 e.g., --public-ip 203.0.113.1
        \\  --only-known-rpc               Only connect to known validators
        \\
        \\Performance Options:
        \\  --limit-ledger-size [SHREDS]   Limit ledger to SHREDS (default: 500GB worth)
        \\  --account-index <INDEX>        Enable account index (program-id, spl-token-*)
        \\  --no-voting                    Run as non-voting replica
        \\  --cuda                         Enable CUDA GPU acceleration
        \\
        \\Vexor-specific Options:
        \\  --bootstrap, --production      Enable PRODUCTION mode with full bootstrap:
        \\                                 - Download snapshot from cluster
        \\                                 - Load accounts database
        \\                                 - Load/create Tower BFT state
        \\                                 - Enable voting (if vote account provided)
        \\  --debug, -v, --verbose         Enable DEBUG mode with verbose logging:
        \\                                 - Detailed startup info
        \\                                 - AF_XDP/io_uring diagnostics
        \\                                 - Snapshot loading progress
        \\                                 - Helpful error messages
        \\  --enable-gpu                   Enable GPU signature verification
        \\  --enable-af-xdp                Enable AF_XDP kernel bypass networking
        \\  --xdp-zero-copy                Enable AF_XDP zero-copy mode (~30M pps)
        \\                                 Requires NIC driver support (mlx5, ice)
        \\                                 Falls back to copy mode if unsupported
        \\  --enable-io-uring              Enable io_uring UDP acceleration
        \\  --disable-io-uring             Disable io_uring UDP acceleration
        \\  --enable-quic                  Enable QUIC TPU send path
        \\  --disable-quic                 Disable QUIC TPU send path
        \\  --force-quic                   Force QUIC-only (no UDP fallback)
        \\  --no-force-quic                Allow UDP fallback (default)
        \\  --enable-h3-datagram           Enable HTTP/3 datagram capsule mode (experimental)
        \\  --disable-h3-datagram          Disable HTTP/3 datagram capsule mode
        \\  --enable-quic-coalesce         Enable QUIC stream coalescing for batches
        \\  --disable-quic-coalesce        Disable QUIC stream coalescing for batches
        \\  --quic-target <HOST:PORT>      Override QUIC target (local testing)
        \\  --quic-insecure                Allow self-signed QUIC certs (local)
        \\  --quic-batch-size <N>          Override QUIC batch size (1-32, 0=auto)
        \\  --shred-version <N>            Override gossip shred version (localnet)
        \\  --interface <NAME>             Network interface for AF_XDP (e.g., enp1s0f0, eth0)
        \\                                 Default: auto-detect from routing table
        \\  --enable-ramdisk               Enable RAM disk for hot storage
        \\  --ramdisk-size <GB>            RAM disk size in GB (default: 32)
        \\  --enable-fast-catchup          Enable experimental fast catchup
        \\  --fast-catchup-threads <N>     Number of threads for fast catchup (default: 8)
        \\  --disable-auto-optimize        Disable automatic system optimization
        \\  --enable-dashboard             Enable admin dashboard stream server
        \\  --dashboard-port <PORT>        Dashboard stream port (default: 8910)
        \\  --dashboard                    Enable CLI performance dashboard display
        \\  --metrics-port <PORT>          Prometheus metrics port (default: 9090)
        \\
        \\Testing & Debugging Options:
        \\  --test-mode                    Enable test mode (shows [TEST] prefix in logs)
        \\  --verbose, -v                  Enable verbose debug logging
        \\  --profile                      Enable performance profiling
        \\  --mock-data                    Use mock data instead of network
        \\  --enable-feature=<FEAT>        Enable specific feature (e.g., masque, bpf)
        \\  --disable-feature=<FEAT>       Disable specific feature (e.g., af_xdp)
        \\  --inject-fault=<SPEC>          Inject fault for testing (e.g., network_delay:100ms)
        \\
        \\Examples:
        \\  # Start testnet validator (consensus mode)
        \\  vexor validator --testnet \
        \\    --identity ~/validator-keypair.json \
        \\    --vote-account ~/vote-account-keypair.json \
        \\    --ledger /mnt/ledger
        \\
        \\  # Start mainnet validator (production - use with caution!)
        \\  vexor validator --mainnet-beta \
        \\    --identity ~/validator-keypair.json \
        \\    --vote-account ~/vote-account-keypair.json \
        \\    --ledger /mnt/ledger
        \\
        \\  # Start as RPC node (non-voting)
        \\  vexor rpc --testnet \
        \\    --identity ~/rpc-keypair.json \
        \\    --ledger /mnt/ledger \
        \\    --rpc-port 8899
        \\
        \\  # Run with Vexor performance optimizations
        \\  vexor validator --testnet \
        \\    --identity ~/validator-keypair.json \
        \\    --enable-af-xdp \
        \\    --enable-ramdisk \
        \\    --ramdisk-size 64
        \\
        \\  # System optimization & diagnostics
        \\  vexor optimize
        \\  vexor diagnose
        \\  vexor info
        \\
        \\Note: Vexor CLI is designed for compatibility with Agave (solana-validator)
        \\      and Firedancer to enable seamless switching between clients.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printSystemInfo(allocator: std.mem.Allocator) !void {
    std.debug.print("\n📊 System Information\n", .{});
    std.debug.print("─────────────────────\n\n", .{});

    // CPU info
    const cpu_info = try optimizer.detectCpu(allocator);
    defer allocator.free(cpu_info.model);
    std.debug.print("CPU: {s}\n", .{cpu_info.model});
    std.debug.print("  Cores: {d}\n", .{cpu_info.cores});
    std.debug.print("  Threads: {d}\n", .{cpu_info.threads});

    // Memory info
    const mem_info = try optimizer.detectMemory();
    std.debug.print("\nMemory: {d:.1} GB total\n", .{@as(f64, @floatFromInt(mem_info.total)) / (1024 * 1024 * 1024)});
    std.debug.print("  Available: {d:.1} GB\n", .{@as(f64, @floatFromInt(mem_info.available)) / (1024 * 1024 * 1024)});

    // GPU info (if enabled)
    if (features.gpu) {
        std.debug.print("\nGPU: ", .{});
        if (try crypto.gpu.detect()) |gpu| {
            std.debug.print("{s}\n", .{gpu.name});
            std.debug.print("  VRAM: {d} GB\n", .{gpu.vram_gb});
        } else {
            std.debug.print("Not detected\n", .{});
        }
    }

    std.debug.print("\n", .{});
}

// ══════════════════════════════════════════════════════════════════════════════
// TESTS
// ══════════════════════════════════════════════════════════════════════════════
test "version info" {
    try std.testing.expect(version.len > 0);
}

test "feature flags" {
    // Just verify feature flags are accessible
    _ = features.gpu;
    _ = features.af_xdp;
    _ = features.ramdisk;
    _ = features.alpenglow;
    _ = features.auto_optimize;
    _ = features.auto_optimize;
}

test {
    // Enable consensus tests
    std.testing.refAllDecls(consensus);
    _ = @import("consensus/tests_forks.zig");
    // Only test block producer for now to avoid breaking on unrelated modules
    _ = runtime.BlockProducer;
}
