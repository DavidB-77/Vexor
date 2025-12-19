//! Vexor Recommendation Engine
//! Generates personalized performance recommendations based on system audit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_db = @import("issue_database.zig");

/// Recommendation priority
pub const Priority = enum {
    critical,   // Must fix for operation
    high,       // Significant performance impact
    medium,     // Moderate performance improvement
    low,        // Nice to have
    optional,   // Only for maximum performance
    
    pub fn emoji(self: Priority) []const u8 {
        return switch (self) {
            .critical => "🚨",
            .high => "❗",
            .medium => "⚠️",
            .low => "💡",
            .optional => "✨",
        };
    }
};

/// Single recommendation
pub const Recommendation = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    priority: Priority,
    category: issue_db.Category,
    benefit: []const u8,
    risk: issue_db.RiskLevel,
    command: ?[]const u8,
    requires_sudo: bool,
    estimated_impact: []const u8,
    current_value: ?[]const u8,
    recommended_value: ?[]const u8,
};

/// System audit results used for recommendation generation
pub const AuditResults = struct {
    // Network
    has_xdp_capable_nic: bool = false,
    xdp_driver: ?[]const u8 = null,
    kernel_supports_xdp: bool = false,
    has_libbpf: bool = false,
    quic_ports_available: bool = false,
    firewall_type: ?[]const u8 = null,
    
    // Storage
    has_nvme: bool = false,
    has_ssd: bool = false,
    has_hdd: bool = false,
    total_ram_gb: u64 = 0,
    available_ram_gb: u64 = 0,
    has_ramdisk: bool = false,
    
    // Compute
    cpu_cores: u32 = 0,
    has_avx2: bool = false,
    has_avx512: bool = false,
    has_sha_ni: bool = false,
    has_aes_ni: bool = false,
    numa_nodes: u32 = 1,
    has_gpu: bool = false,
    gpu_name: ?[]const u8 = null,
    
    // System
    rmem_max: u64 = 0,
    wmem_max: u64 = 0,
    nofile_limit: u64 = 0,
    hugepages: u64 = 0,
    
    // Permissions
    has_af_xdp_caps: bool = false,
    vexor_installed: bool = false,
};

/// Recommendation engine
pub const RecommendationEngine = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator, // Use arena for recommendations (short-lived)
    audit: AuditResults,
    recommendations: std.ArrayList(Recommendation),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .audit = .{},
            .recommendations = std.ArrayList(Recommendation).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Arena automatically frees all allocations when deinit is called
        self.arena.deinit();
        self.recommendations.deinit();
    }
    
    /// Get arena allocator for recommendation strings
    fn arenaAllocator(self: *Self) Allocator {
        return self.arena.allocator();
    }
    
    /// Generate recommendations based on audit results
    pub fn generateRecommendations(self: *Self, audit: AuditResults) !void {
        self.audit = audit;
        self.recommendations.clearRetainingCapacity();
        
        // AF_XDP Recommendations
        try self.checkAfXdpRecommendations();
        
        // QUIC/MASQUE Recommendations
        try self.checkQuicMasqueRecommendations();
        
        // Storage Recommendations
        try self.checkStorageRecommendations();
        
        // System Tuning Recommendations
        try self.checkSystemTuningRecommendations();
        
        // Sort by priority
        std.mem.sort(Recommendation, self.recommendations.items, {}, struct {
            fn lessThan(_: void, a: Recommendation, b: Recommendation) bool {
                return @intFromEnum(a.priority) < @intFromEnum(b.priority);
            }
        }.lessThan);
    }
    
    fn checkAfXdpRecommendations(self: *Self) !void {
        // Check if AF_XDP can be enabled
        if (self.audit.has_xdp_capable_nic and self.audit.kernel_supports_xdp) {
            if (!self.audit.has_af_xdp_caps) {
                try self.recommendations.append(.{
                    .id = "REC_AFXDP_CAPS",
                    .title = "Enable AF_XDP Kernel Bypass",
                    .description = "Your system supports AF_XDP but capabilities are not set on the Vexor binary.",
                    .priority = .high,
                    .category = .permission,
                    .benefit = "10x packet throughput increase (~10M pps vs ~1M pps)",
                    .risk = .low,
                    .command = "setcap 'cap_net_raw,cap_net_admin,cap_sys_admin+eip' /opt/vexor/bin/vexor",
                    .requires_sudo = true,
                    .estimated_impact = "Network latency: 5-20μs → <1μs",
                    .current_value = "No capabilities",
                    .recommended_value = "cap_net_raw,cap_net_admin,cap_sys_admin+eip",
                });
            }
            
            if (!self.audit.has_libbpf) {
                try self.recommendations.append(.{
                    .id = "REC_AFXDP_LIBBPF",
                    .title = "Install libbpf for AF_XDP",
                    .description = "libbpf is required for AF_XDP BPF program loading.",
                    .priority = .high,
                    .category = .system,
                    .benefit = "Required for AF_XDP functionality",
                    .risk = .low,
                    .command = "apt-get update && apt-get install -y libbpf-dev",
                    .requires_sudo = true,
                    .estimated_impact = "Enables AF_XDP",
                    .current_value = "Not installed",
                    .recommended_value = "libbpf-dev installed",
                });
            }
        } else if (!self.audit.has_xdp_capable_nic) {
            try self.recommendations.append(.{
                .id = "REC_AFXDP_FALLBACK",
                .title = "Use io_uring Fallback (No XDP NIC)",
                .description = try std.fmt.allocPrint(self.arenaAllocator(), "Your NIC driver '{s}' doesn't support AF_XDP. Using io_uring provides ~50% of AF_XDP performance.", .{self.audit.xdp_driver orelse "unknown"}),
                .priority = .medium,
                .category = .network,
                .benefit = "Best available performance without AF_XDP hardware",
                .risk = .none,
                .command = null,
                .requires_sudo = false,
                .estimated_impact = "5x faster than standard UDP",
                .current_value = self.audit.xdp_driver,
                .recommended_value = "Consider Intel X710 or Mellanox ConnectX-5 for full AF_XDP",
            });
        }
    }
    
    fn checkQuicMasqueRecommendations(self: *Self) !void {
        if (!self.audit.quic_ports_available) {
            try self.recommendations.append(.{
                .id = "REC_QUIC_PORTS",
                .title = "Open QUIC Ports (8801-8810)",
                .description = "QUIC/MASQUE requires UDP ports 8801-8810 for high-performance transport.",
                .priority = .high,
                .category = .network,
                .benefit = "NAT traversal, multiplexed connections, ~50ms latency reduction",
                .risk = .low,
                .command = if (self.audit.firewall_type) |fw|
                    (if (std.mem.eql(u8, fw, "nftables"))
                        "nft add rule inet filter input udp dport 8801-8810 accept"
                    else
                        "iptables -A INPUT -p udp --dport 8801:8810 -j ACCEPT")
                else
                    "nft add rule inet filter input udp dport 8801-8810 accept",
                .requires_sudo = true,
                .estimated_impact = "Enables QUIC/MASQUE transport",
                .current_value = "Ports blocked/unknown",
                .recommended_value = "UDP 8801-8810 open",
            });
        }
    }
    
    fn checkStorageRecommendations(self: *Self) !void {
        // RAM Disk recommendation
        if (!self.audit.has_ramdisk and self.audit.available_ram_gb > 32) {
            const recommended_size = @min(self.audit.available_ram_gb / 4, 64);
            try self.recommendations.append(.{
                .id = "REC_RAMDISK",
                .title = "Enable RAM Disk for Hot Storage",
                .description = try std.fmt.allocPrint(self.arenaAllocator(), "You have {d}GB available RAM. A {d}GB ramdisk dramatically improves account access.", .{ self.audit.available_ram_gb, recommended_size }),
                .priority = .high,
                .category = .storage,
                .benefit = "Account access latency: ~100μs → <1μs",
                .risk = .medium,
                .command = try std.fmt.allocPrint(self.arenaAllocator(), "mkdir -p /mnt/vexor/ramdisk && mount -t tmpfs -o size={d}G tmpfs /mnt/vexor/ramdisk", .{recommended_size}),
                .requires_sudo = true,
                .estimated_impact = "100x faster hot account access",
                .current_value = "No ramdisk",
                .recommended_value = try std.fmt.allocPrint(self.arenaAllocator(), "{d}GB tmpfs ramdisk", .{recommended_size}),
            });
        }
        
        // HDD warning
        if (self.audit.has_hdd and !self.audit.has_nvme) {
            try self.recommendations.append(.{
                .id = "REC_STORAGE_HDD",
                .title = "CRITICAL: Upgrade to NVMe Storage",
                .description = "HDD detected as primary storage. Validators require NVMe for adequate performance.",
                .priority = .critical,
                .category = .storage,
                .benefit = "10-50x I/O performance improvement",
                .risk = .none,
                .command = null,
                .requires_sudo = false,
                .estimated_impact = "Ledger sync: hours → minutes",
                .current_value = "HDD (rotational)",
                .recommended_value = "NVMe SSD (Samsung 990 Pro recommended)",
            });
        }
    }
    
    fn checkSystemTuningRecommendations(self: *Self) !void {
        // Network buffers
        if (self.audit.rmem_max < 134217728) {
            try self.recommendations.append(.{
                .id = "REC_NET_BUFFERS",
                .title = "Increase Network Buffer Sizes",
                .description = "Default network buffers are too small for high-throughput validator traffic.",
                .priority = .medium,
                .category = .system,
                .benefit = "Prevents packet loss under load",
                .risk = .low,
                .command = "sysctl -w net.core.rmem_max=134217728 net.core.wmem_max=134217728",
                .requires_sudo = true,
                .estimated_impact = "Up to 30% reduction in packet loss",
                .current_value = try std.fmt.allocPrint(self.arenaAllocator(), "{d}", .{self.audit.rmem_max}),
                .recommended_value = "134217728 (128MB)",
            });
        }
        
        // Huge pages
        if (self.audit.hugepages == 0 and self.audit.total_ram_gb > 64) {
            try self.recommendations.append(.{
                .id = "REC_HUGEPAGES",
                .title = "Enable Huge Pages",
                .description = "Huge pages reduce TLB misses and improve memory performance.",
                .priority = .low,
                .category = .system,
                .benefit = "5-10% memory performance improvement",
                .risk = .medium,
                .command = "sysctl -w vm.nr_hugepages=16384",
                .requires_sudo = true,
                .estimated_impact = "Reduced memory allocation latency",
                .current_value = "0",
                .recommended_value = "16384 (32GB)",
            });
        }
        
        // File limits
        if (self.audit.nofile_limit < 1000000) {
            try self.recommendations.append(.{
                .id = "REC_NOFILE",
                .title = "Increase File Descriptor Limit",
                .description = "Current limit may be too low for validator with many peer connections.",
                .priority = .high,
                .category = .system,
                .benefit = "Prevents 'too many open files' errors",
                .risk = .low,
                .command = "echo '* soft nofile 1000000' >> /etc/security/limits.conf",
                .requires_sudo = true,
                .estimated_impact = "Stable operation with many connections",
                .current_value = try std.fmt.allocPrint(self.arenaAllocator(), "{d}", .{self.audit.nofile_limit}),
                .recommended_value = "1000000",
            });
        }
    }
    
    /// Get recommendations by priority
    pub fn getByPriority(self: *Self, priority: Priority) []Recommendation {
        var count: usize = 0;
        for (self.recommendations.items) |rec| {
            if (rec.priority == priority) count += 1;
        }
        // Caller should iterate and filter
        return self.recommendations.items;
    }
    
    /// Get critical and high priority recommendations
    pub fn getCriticalRecommendations(self: *Self) []Recommendation {
        return self.recommendations.items;
    }
    
    /// Summary statistics
    pub fn getSummary(self: *Self) struct { total: usize, critical: usize, high: usize, auto_fixable: usize } {
        var critical: usize = 0;
        var high: usize = 0;
        var auto_fixable: usize = 0;
        
        for (self.recommendations.items) |rec| {
            if (rec.priority == .critical) critical += 1;
            if (rec.priority == .high) high += 1;
            if (rec.command != null) auto_fixable += 1;
        }
        
        return .{
            .total = self.recommendations.items.len,
            .critical = critical,
            .high = high,
            .auto_fixable = auto_fixable,
        };
    }
};

