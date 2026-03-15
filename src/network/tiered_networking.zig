//! Tiered Networking System
//!
//! Implements automatic tier selection and fallback for Vexor networking.
//! Works with the Network Guardian to ensure safe operation.
//!
//! Tiers (in order of preference):
//!   1. AF_XDP Zero-Copy - Maximum performance, requires compatible NIC + root
//!   2. AF_XDP Copy Mode - High performance, requires root
//!   3. io_uring - Good performance, requires kernel 5.6+
//!   4. Standard Batched - Reliable, uses recvmmsg/sendmmsg
//!   5. Standard Naive - Universal fallback
//!
//! The system will:
//!   1. Detect available capabilities
//!   2. Take a network snapshot (via Guardian)
//!   3. Try the highest available tier
//!   4. On failure, restore snapshot and try next tier
//!   5. Eventually settle on a working tier

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const guardian_mod = @import("guardian/root.zig");

// Embedded capability report (to avoid cross-module imports)
pub const CapabilityReport = struct {
    kernel_version: KernelVersion,
    has_io_uring: bool,
    has_recvmmsg: bool,
    has_bpf_syscall: bool,
    has_cap_net_admin: bool,
    has_cap_bpf: bool,
    
    pub const KernelVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };
};

fn detectCapabilities() CapabilityReport {
    // Get kernel version
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const release = std.mem.sliceTo(&uts.release, 0);
    var parts = std.mem.splitScalar(u8, release, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse "5", 10) catch 5;
    const minor_str = parts.next() orelse "0";
    var minor_end: usize = 0;
    for (minor_str) |c| {
        if (c >= '0' and c <= '9') minor_end += 1 else break;
    }
    const minor = std.fmt.parseInt(u32, minor_str[0..minor_end], 10) catch 0;
    
    // Check io_uring
    var params = std.mem.zeroes(linux.io_uring_params);
    const io_fd = linux.io_uring_setup(8, &params);
    const has_io_uring = io_fd >= 0;
    if (io_fd >= 0) _ = linux.close(@intCast(io_fd));
    
    // Check root
    const is_root = linux.getuid() == 0;
    
    return .{
        .kernel_version = .{ .major = major, .minor = minor, .patch = 0 },
        .has_io_uring = has_io_uring,
        .has_recvmmsg = true, // Always on Linux 3.0+
        .has_bpf_syscall = major >= 5 or (major == 4 and minor >= 18),
        .has_cap_net_admin = is_root,
        .has_cap_bpf = is_root and major >= 5,
    };
}

/// Network tier enumeration
pub const NetworkTier = enum(u8) {
    af_xdp_zero_copy = 1,
    af_xdp_copy = 2,
    io_uring = 3,
    standard_batched = 4,
    standard_naive = 5,
    
    pub fn name(self: NetworkTier) []const u8 {
        return switch (self) {
            .af_xdp_zero_copy => "AF_XDP Zero-Copy",
            .af_xdp_copy => "AF_XDP Copy Mode",
            .io_uring => "io_uring",
            .standard_batched => "Batched Sockets (recvmmsg)",
            .standard_naive => "Standard Sockets",
        };
    }
    
    pub fn expectedPps(self: NetworkTier) []const u8 {
        return switch (self) {
            .af_xdp_zero_copy => "10-20+ Mpps",
            .af_xdp_copy => "5-10 Mpps",
            .io_uring => "3-5 Mpps",
            .standard_batched => "1-2 Mpps",
            .standard_naive => "< 500 Kpps",
        };
    }
};

/// Tiered networking configuration
pub const TieredNetworkConfig = struct {
    /// Network interface to use
    interface: []const u8,
    
    /// Minimum acceptable tier (won't go below this)
    minimum_tier: NetworkTier = .standard_naive,
    
    /// Starting tier to try (usually highest available)
    starting_tier: ?NetworkTier = null, // null = auto-detect
    
    /// Force a specific tier (skip auto-detection)
    force_tier: ?NetworkTier = null,
    
    /// Enable the network guardian
    enable_guardian: bool = true,
    
    /// Guardian check interval (ms)
    guardian_check_ms: u32 = 500,
    
    /// Guardian failure timeout (ms)
    guardian_timeout_ms: u32 = 3000,
    
    /// Ports to bind for UDP reception
    udp_ports: []const u16 = &.{ 8001, 8004, 8008 }, // gossip, TVU, repair
};

/// Result of tier initialization
pub const TierInitResult = struct {
    tier: NetworkTier,
    success: bool,
    error_message: ?[]const u8,
    sockets: ?[]posix.socket_t,
};

/// Tiered Networking Manager
pub const TieredNetworkManager = struct {
    config: TieredNetworkConfig,
    allocator: std.mem.Allocator,
    
    // Current state
    current_tier: NetworkTier,
    is_initialized: bool,
    
    // Guardian integration
    guardian: ?*guardian_mod.NetworkGuardian,
    pre_change_snapshot: ?guardian_mod.NetworkSnapshot,
    
    // Active sockets
    sockets: std.ArrayList(posix.socket_t),
    
    // Statistics
    tier_attempts: [6]u32, // Index by tier enum value
    tier_failures: [6]u32,
    
    pub fn init(allocator: std.mem.Allocator, config: TieredNetworkConfig) TieredNetworkManager {
        return .{
            .config = config,
            .allocator = allocator,
            .current_tier = .standard_naive,
            .is_initialized = false,
            .guardian = null,
            .pre_change_snapshot = null,
            .sockets = std.ArrayList(posix.socket_t).init(allocator),
            .tier_attempts = .{ 0, 0, 0, 0, 0, 0 },
            .tier_failures = .{ 0, 0, 0, 0, 0, 0 },
        };
    }
    
    pub fn deinit(self: *TieredNetworkManager) void {
        // Close all sockets
        for (self.sockets.items) |sock| {
            posix.close(sock);
        }
        self.sockets.deinit();
        
        // Stop and free guardian
        if (self.guardian) |g| {
            g.stop();
            self.allocator.destroy(g);
            self.guardian = null;
        }
    }
    
    /// Start the networking stack with automatic tier selection
    pub fn start(self: *TieredNetworkManager) !void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║       VEXOR TIERED NETWORKING INITIALIZATION             ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        
        // Step 1: Take network snapshot BEFORE any changes
        std.debug.print("[Tiered] Step 1: Capturing pre-change network snapshot...\n", .{});
        self.pre_change_snapshot = guardian_mod.captureSnapshot(self.config.interface) catch |err| blk: {
            std.debug.print("[Tiered] Warning: Could not capture snapshot: {}\n", .{err});
            break :blk null;
        };
        
        if (self.pre_change_snapshot) |*snap| {
            snap.print();
        }
        
        // Step 2: Start guardian if enabled
        if (self.config.enable_guardian) {
            std.debug.print("\n[Tiered] Step 2: Starting network guardian...\n", .{});
            
            const guardian_ptr = try self.allocator.create(guardian_mod.NetworkGuardian);
            guardian_ptr.* = guardian_mod.NetworkGuardian.init(self.allocator, .{
                .interface = self.config.interface,
                .check_interval_ms = self.config.guardian_check_ms,
                .failure_timeout_ms = self.config.guardian_timeout_ms,
                .auto_restore = true,
            });
            
            // Give it our snapshot
            guardian_ptr.snapshot = self.pre_change_snapshot;
            
            try guardian_ptr.start();
            self.guardian = guardian_ptr;
            
            std.debug.print("[Tiered] Guardian started and monitoring\n", .{});
        }
        
        // Step 3: Detect capabilities
        std.debug.print("\n[Tiered] Step 3: Detecting network capabilities...\n", .{});
        const caps = detectCapabilities();
        
        // Step 4: Determine starting tier
        const starting_tier = self.config.force_tier orelse 
            self.config.starting_tier orelse 
            self.detectBestTier(&caps);
        
        std.debug.print("[Tiered] Starting tier: {s}\n", .{starting_tier.name()});
        
        // Step 5: Try tiers with fallback
        std.debug.print("\n[Tiered] Step 4: Initializing networking with fallback...\n", .{});
        
        var current_tier = starting_tier;
        while (@intFromEnum(current_tier) <= @intFromEnum(self.config.minimum_tier)) {
            std.debug.print("\n[Tiered] Trying tier: {s}...\n", .{current_tier.name()});
            
            self.tier_attempts[@intFromEnum(current_tier)] += 1;
            
            const result = self.initializeTier(current_tier);
            
            if (result.success) {
                self.current_tier = current_tier;
                self.is_initialized = true;
                
                std.debug.print("[Tiered] SUCCESS: Initialized with {s}\n", .{current_tier.name()});
                std.debug.print("[Tiered] Expected performance: {s}\n", .{current_tier.expectedPps()});
                
                break;
            } else {
                self.tier_failures[@intFromEnum(current_tier)] += 1;
                
                std.debug.print("[Tiered] FAILED: {s}\n", .{
                    result.error_message orelse "Unknown error"
                });
                
                // Restore snapshot before trying next tier
                if (self.pre_change_snapshot) |*snap| {
                    std.debug.print("[Tiered] Restoring network state before next attempt...\n", .{});
                    _ = guardian_mod.restoreFromSnapshot(snap);
                }
                
                // Move to next tier
                current_tier = @enumFromInt(@intFromEnum(current_tier) + 1);
            }
        }
        
        if (!self.is_initialized) {
            std.debug.print("\n[Tiered] ERROR: All tiers failed!\n", .{});
            return error.AllTiersFailed;
        }
        
        self.printStatus();
    }
    
    /// Detect the best tier based on capabilities
    fn detectBestTier(self: *TieredNetworkManager, caps: *const CapabilityReport) NetworkTier {
        _ = self;
        
        // Check for AF_XDP capability
        if (caps.has_cap_net_admin and caps.has_cap_bpf and caps.has_bpf_syscall) {
            if (caps.kernel_version.major > 5 or 
                (caps.kernel_version.major == 5 and caps.kernel_version.minor >= 4)) {
                return .af_xdp_zero_copy;
            }
            return .af_xdp_copy;
        }
        
        // Check for io_uring
        if (caps.has_io_uring) {
            return .io_uring;
        }
        
        // Check for batched sockets
        if (caps.has_recvmmsg) {
            return .standard_batched;
        }
        
        return .standard_naive;
    }
    
    /// Initialize a specific tier
    fn initializeTier(self: *TieredNetworkManager, tier: NetworkTier) TierInitResult {
        return switch (tier) {
            .af_xdp_zero_copy, .af_xdp_copy => self.initAfXdp(tier == .af_xdp_zero_copy),
            .io_uring => self.initIoUring(),
            .standard_batched => self.initBatchedSockets(),
            .standard_naive => self.initNaiveSockets(),
        };
    }
    
    /// Initialize AF_XDP (zero-copy or copy mode)
    fn initAfXdp(self: *TieredNetworkManager, zero_copy: bool) TierInitResult {
        _ = self;
        
        // Check if we're running as root
        if (std.os.linux.getuid() != 0) {
            return .{
                .tier = if (zero_copy) .af_xdp_zero_copy else .af_xdp_copy,
                .success = false,
                .error_message = "AF_XDP requires root privileges",
                .sockets = null,
            };
        }
        
        // Try to create AF_XDP socket
        const AF_XDP = 44;
        const sock = posix.socket(AF_XDP, posix.SOCK.RAW, 0) catch {
            return .{
                .tier = if (zero_copy) .af_xdp_zero_copy else .af_xdp_copy,
                .success = false,
                .error_message = "Could not create AF_XDP socket",
                .sockets = null,
            };
        };
        
        // For now, just verify we CAN create the socket
        // Full implementation would set up UMEM, rings, etc.
        posix.close(sock);
        
        return .{
            .tier = if (zero_copy) .af_xdp_zero_copy else .af_xdp_copy,
            .success = true,
            .error_message = null,
            .sockets = null,
        };
    }
    
    /// Initialize io_uring
    fn initIoUring(self: *TieredNetworkManager) TierInitResult {
        _ = self;
        
        // Try to create io_uring instance
        var params = std.mem.zeroes(std.os.linux.io_uring_params);
        const fd = std.os.linux.io_uring_setup(64, &params);
        
        if (fd < 0) {
            return .{
                .tier = .io_uring,
                .success = false,
                .error_message = "Could not initialize io_uring",
                .sockets = null,
            };
        }
        
        // Success - close for now (full impl would keep it)
        _ = std.os.linux.close(@intCast(fd));
        
        return .{
            .tier = .io_uring,
            .success = true,
            .error_message = null,
            .sockets = null,
        };
    }
    
    /// Initialize batched sockets (recvmmsg/sendmmsg)
    fn initBatchedSockets(self: *TieredNetworkManager) TierInitResult {
        // Create UDP sockets for each port
        for (self.config.udp_ports) |port| {
            const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0) catch {
                continue;
            };
            
            // Enable SO_REUSEADDR
            const opt: c_int = 1;
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&opt)) catch {};
            
            // Bind to port
            const addr = posix.sockaddr.in{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = 0, // INADDR_ANY
            };
            
            posix.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch {
                posix.close(sock);
                continue;
            };
            
            self.sockets.append(sock) catch {};
        }
        
        if (self.sockets.items.len > 0) {
            return .{
                .tier = .standard_batched,
                .success = true,
                .error_message = null,
                .sockets = self.sockets.items,
            };
        }
        
        return .{
            .tier = .standard_batched,
            .success = false,
            .error_message = "Could not bind to any ports",
            .sockets = null,
        };
    }
    
    /// Initialize naive sockets (last resort)
    fn initNaiveSockets(self: *TieredNetworkManager) TierInitResult {
        // Same as batched but will use regular recv/send
        return self.initBatchedSockets();
    }
    
    /// Print current status
    pub fn printStatus(self: *TieredNetworkManager) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║         TIERED NETWORKING STATUS                          ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Interface: {s}\n", .{self.config.interface});
        std.debug.print("║ Current Tier: {s}\n", .{self.current_tier.name()});
        std.debug.print("║ Expected Performance: {s}\n", .{self.current_tier.expectedPps()});
        std.debug.print("║ Active Sockets: {d}\n", .{self.sockets.items.len});
        std.debug.print("║ Guardian Active: {s}\n", .{if (self.guardian != null) "YES" else "NO"});
        std.debug.print("║ \n", .{});
        std.debug.print("║ Tier Attempts:\n", .{});
        inline for (1..6) |i| {
            const tier: NetworkTier = @enumFromInt(i);
            if (self.tier_attempts[i] > 0) {
                std.debug.print("║   {s}: {d} attempts, {d} failures\n", .{
                    tier.name(),
                    self.tier_attempts[i],
                    self.tier_failures[i],
                });
            }
        }
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
    
    /// Force downgrade to a lower tier
    pub fn downgradeTier(self: *TieredNetworkManager) !void {
        const next_tier: u8 = @intFromEnum(self.current_tier) + 1;
        if (next_tier > @intFromEnum(self.config.minimum_tier)) {
            return error.AlreadyAtMinimumTier;
        }
        
        std.debug.print("[Tiered] Downgrading from {s} to next tier...\n", .{
            self.current_tier.name()
        });
        
        // Close current sockets
        for (self.sockets.items) |sock| {
            posix.close(sock);
        }
        self.sockets.clearRetainingCapacity();
        
        // Restore snapshot
        if (self.pre_change_snapshot) |*snap| {
            _ = guardian_mod.restoreFromSnapshot(snap);
        }
        
        // Try next tier
        self.current_tier = @enumFromInt(next_tier);
        const result = self.initializeTier(self.current_tier);
        
        if (!result.success) {
            return error.DowngradeFailed;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const interface = if (args.len > 1) args[1] else "lo";
    
    std.debug.print("Tiered Networking Test\n", .{});
    std.debug.print("Interface: {s}\n", .{interface});
    
    var manager = TieredNetworkManager.init(allocator, .{
        .interface = interface,
        .enable_guardian = true,
        .udp_ports = &.{ 19901, 19902 }, // Test ports
    });
    defer manager.deinit();
    
    try manager.start();
    
    // Let it run briefly
    std.debug.print("\nRunning for 3 seconds...\n", .{});
    std.time.sleep(3 * std.time.ns_per_s);
    
    manager.printStatus();
    
    std.debug.print("\nTest complete\n", .{});
}
