//! Vexor Configuration
//!
//! Handles all validator configuration including:
//! - Command line argument parsing
//! - Configuration file loading (TOML)
//! - Environment variable overrides
//! - Sensible defaults

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    allocator: Allocator,

    // ═══════════════════════════════════════════════════════════════════════
    // IDENTITY
    // ═══════════════════════════════════════════════════════════════════════
    identity_path: ?[]const u8 = null,
    vote_account_path: ?[]const u8 = null,

    // ═══════════════════════════════════════════════════════════════════════
    // PATHS
    // ═══════════════════════════════════════════════════════════════════════
    ledger_path: []const u8 = "/mnt/ledger",
    ledger_dir: ?[]const u8 = null, // Alias for compatibility
    accounts_path: []const u8 = "/mnt/accounts",
    accounts_dir: ?[]const u8 = null, // Alias for compatibility
    snapshots_path: []const u8 = "/mnt/snapshots",
    snapshots_dir: ?[]const u8 = null, // Alias for compatibility
    ramdisk_path: ?[]const u8 = "/mnt/ramdisk", // Tier-0 hot storage

    // ═══════════════════════════════════════════════════════════════════════
    // NETWORK
    // ═══════════════════════════════════════════════════════════════════════
    rpc_port: u16 = 8899,
    rpc_bind_address: []const u8 = "0.0.0.0",
    gossip_port: u16 = 8001,
    tpu_port: u16 = 8003,
    tvu_port: u16 = 8004,
    repair_port: u16 = 8005,
    dynamic_port_range: PortRange = .{ .start = 8100, .end = 8200 },
    entrypoints: []const []const u8 = &.{},
    
    /// Public IP address for gossip advertisement
    /// If null, will attempt auto-detection or use 0.0.0.0 (broken)
    /// IMPORTANT: This MUST be set for the network to send shreds to this validator!
    public_ip: ?[4]u8 = null,
    
    /// Network interface for AF_XDP (empty = auto-detect)
    /// Example: "enp1s0f0", "eth0"
    interface: []const u8 = "",

    // ═══════════════════════════════════════════════════════════════════════
    // CLUSTER
    // ═══════════════════════════════════════════════════════════════════════
    cluster: Cluster = .mainnet_beta,
    expected_genesis_hash: ?[]const u8 = null,
    expected_shred_version: ?u16 = null,

    // ═══════════════════════════════════════════════════════════════════════
    // PERFORMANCE
    // ═══════════════════════════════════════════════════════════════════════
    max_threads: ?usize = null, // null = auto-detect
    banking_threads: usize = 4,
    replay_threads: usize = 4,
    
    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════
    snapshot_interval_slots: u64 = 500,
    accounts_hash_interval_slots: u64 = 100,
    max_snapshot_age_slots: u64 = 500,
    enable_ramdisk: bool = true,
    ramdisk_size_gb: usize = 32, // GB for tier-0 storage

    // ═══════════════════════════════════════════════════════════════════════
    // FEATURES (toggles)
    // ═══════════════════════════════════════════════════════════════════════
    enable_gpu: bool = false,
    enable_af_xdp: bool = true,
    enable_auto_optimize: bool = true,
    enable_metrics: bool = true,
    enable_rpc: bool = true,
    enable_voting: bool = true, // Submit votes (set to false for RPC nodes)

    // ═══════════════════════════════════════════════════════════════════════
    // LIMITS
    // ═══════════════════════════════════════════════════════════════════════
    max_ledger_shreds: usize = 50_000_000,
    max_accounts_cache_size: usize = 10_000_000,

    pub const PortRange = struct {
        start: u16,
        end: u16,
    };

    pub const Cluster = enum {
        mainnet_beta, // Official name used by Solana
        testnet,
        devnet,
        localnet,

        // Alias for backward compatibility
        pub const mainnet = Cluster.mainnet_beta;

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
                },
                .devnet => &.{
                    "entrypoint.devnet.solana.com:8001",
                    "entrypoint2.devnet.solana.com:8001",
                },
                .localnet => &.{},
            };
        }

        pub fn genesisHash(self: Cluster) ?[]const u8 {
            return switch (self) {
                .mainnet_beta => "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
                .testnet => "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY",
                .devnet => "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",
                .localnet => null,
            };
        }
    };

    /// Load configuration from command line args and/or config file
    pub fn load(allocator: Allocator, args: []const []const u8) !*Config {
        var config = try allocator.create(Config);
        config.* = Config{
            .allocator = allocator,
        };

        // Accumulate entrypoints from CLI
        var entrypoint_list = std.ArrayList([]const u8).init(allocator);

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--identity")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.identity_path = args[i];
            } else if (std.mem.eql(u8, arg, "--vote-account")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.vote_account_path = args[i];
            } else if (std.mem.eql(u8, arg, "--ledger")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.ledger_path = args[i];
            } else if (std.mem.eql(u8, arg, "--accounts")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.accounts_path = args[i];
            } else if (std.mem.eql(u8, arg, "--rpc-port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.rpc_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--gossip-port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.gossip_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--cluster")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.cluster = std.meta.stringToEnum(Cluster, args[i]) orelse return error.InvalidCluster;
            } else if (std.mem.eql(u8, arg, "--testnet")) {
                config.cluster = .testnet;
            } else if (std.mem.eql(u8, arg, "--mainnet-beta") or std.mem.eql(u8, arg, "--mainnet")) {
                config.cluster = .mainnet_beta;
            } else if (std.mem.eql(u8, arg, "--devnet")) {
                config.cluster = .devnet;
            } else if (std.mem.eql(u8, arg, "--localnet")) {
                config.cluster = .localnet;
            } else if (std.mem.eql(u8, arg, "--enable-gpu") or std.mem.eql(u8, arg, "--cuda")) {
                // --cuda is Agave compatibility alias
                config.enable_gpu = true;
            } else if (std.mem.eql(u8, arg, "--enable-af-xdp")) {
                config.enable_af_xdp = true;
            } else if (std.mem.eql(u8, arg, "--disable-af-xdp")) {
                config.enable_af_xdp = false;
            } else if (std.mem.eql(u8, arg, "--interface")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.interface = args[i];
            } else if (std.mem.eql(u8, arg, "--enable-ramdisk")) {
                config.enable_ramdisk = true;
            } else if (std.mem.eql(u8, arg, "--disable-ramdisk")) {
                config.enable_ramdisk = false;
            } else if (std.mem.eql(u8, arg, "--snapshots")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.snapshots_path = args[i];
            } else if (std.mem.eql(u8, arg, "--log")) {
                i += 1;
                // Log path - handled by runtime
            } else if (std.mem.eql(u8, arg, "--known-validator")) {
                i += 1;
                // Known validator pubkey - can repeat
            } else if (std.mem.eql(u8, arg, "--only-known-rpc")) {
                // Only connect to known validators
            } else if (std.mem.eql(u8, arg, "--limit-ledger-size")) {
                // Optional value follows
                if (i + 1 < args.len and args[i + 1][0] != '-') {
                    i += 1;
                    config.max_ledger_shreds = try std.fmt.parseInt(usize, args[i], 10);
                }
            } else if (std.mem.eql(u8, arg, "--no-voting")) {
                config.vote_account_path = null;
            } else if (std.mem.eql(u8, arg, "--ramdisk-size")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.ramdisk_size_gb = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--disable-auto-optimize")) {
                config.enable_auto_optimize = false;
            } else if (std.mem.eql(u8, arg, "--entrypoint")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                // Accumulate entrypoint to list
                try entrypoint_list.append(args[i]);
            } else if (std.mem.eql(u8, arg, "--public-ip") or std.mem.eql(u8, arg, "--gossip-host")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                // Parse IP address (e.g., "38.92.24.174")
                config.public_ip = parseIpv4(args[i]) orelse return error.InvalidIpAddress;
            } else if (std.mem.eql(u8, arg, "--tvu-port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.tvu_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--repair-port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                config.repair_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--dynamic-port-range")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                // Parse "8000-10000" format
                var parts = std.mem.splitScalar(u8, args[i], '-');
                const start_str = parts.next() orelse return error.InvalidPortRange;
                const end_str = parts.next() orelse return error.InvalidPortRange;
                config.dynamic_port_range = .{
                    .start = try std.fmt.parseInt(u16, start_str, 10),
                    .end = try std.fmt.parseInt(u16, end_str, 10),
                };
            } else if (std.mem.eql(u8, arg, "--config")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                try config.loadFromFile(args[i]);
            }
            // Add more argument parsing as needed
        }

        // Use CLI entrypoints if provided, otherwise use cluster defaults
        if (entrypoint_list.items.len > 0) {
            config.entrypoints = try entrypoint_list.toOwnedSlice();
            std.debug.print("[Config] Using {d} CLI-provided entrypoints\n", .{config.entrypoints.len});
        } else {
            config.entrypoints = config.cluster.defaultEntrypoints();
            std.debug.print("[Config] Using default entrypoints for {s}\n", .{@tagName(config.cluster)});
        }

        return config;
    }

    /// Load configuration from a TOML file
    pub fn loadFromFile(self: *Config, path: []const u8) !void {
        _ = self;
        _ = path;
        // TODO: Implement TOML parsing
        // For now, this is a placeholder
    }

    pub fn deinit(self: *Config) void {
        self.allocator.destroy(self);
    }

    /// Validate the configuration
    pub fn validate(self: *const Config) !void {
        if (self.identity_path == null) {
            return error.IdentityRequired;
        }

        if (self.vote_account_path == null) {
            std.debug.print("Warning: No vote account specified. Running as non-voting node.\n", .{});
        }

        if (self.dynamic_port_range.start >= self.dynamic_port_range.end) {
            return error.InvalidPortRange;
        }
        
        if (self.public_ip == null) {
            std.debug.print("\n⚠️  WARNING: No --public-ip specified!\n", .{});
            std.debug.print("   The network won't know where to send shreds.\n", .{});
            std.debug.print("   Use: --public-ip <YOUR_PUBLIC_IP>\n\n", .{});
        }
    }
    
    /// Get the public IP as bytes for socket addresses
    pub fn getPublicIpBytes(self: *const Config) [4]u8 {
        return self.public_ip orelse .{ 0, 0, 0, 0 };
    }
};

/// Parse an IPv4 address string like "192.168.1.1" into bytes
fn parseIpv4(ip_str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, ip_str, '.');
    
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return null; // Too many octets
        result[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    
    if (i != 4) return null; // Too few octets
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "config defaults" {
    const allocator = std.testing.allocator;
    const config = try Config.load(allocator, &.{});
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 8899), config.rpc_port);
    try std.testing.expectEqual(@as(u16, 8001), config.gossip_port);
    try std.testing.expectEqual(Config.Cluster.mainnet_beta, config.cluster);
}

test "config with args" {
    const allocator = std.testing.allocator;
    const args = &.{ "--rpc-port", "9000", "--cluster", "testnet" };
    const config = try Config.load(allocator, args);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 9000), config.rpc_port);
    try std.testing.expectEqual(Config.Cluster.testnet, config.cluster);
}

test "cluster entrypoints" {
    const mainnet_entrypoints = Config.Cluster.mainnet.defaultEntrypoints();
    try std.testing.expect(mainnet_entrypoints.len > 0);

    const genesis = Config.Cluster.mainnet.genesisHash();
    try std.testing.expect(genesis != null);
}

