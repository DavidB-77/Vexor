//! Vexor Auto-Diagnosis System
//! Automatically detects issues and matches them against the issue database.

const std = @import("std");
const Allocator = std.mem.Allocator;
const issue_db = @import("issue_database.zig");

/// Result of running a diagnosis command
pub const DiagnosisResult = struct {
    command: []const u8,
    output: []const u8,
    exit_code: u8,
    success: bool,
};

/// Detected issue with context
pub const DetectedIssue = struct {
    issue: issue_db.KnownIssue,
    diagnosis_output: []const u8,
    confidence: Confidence,
    
    pub const Confidence = enum {
        high,    // Clear match
        medium,  // Likely match
        low,     // Possible match
    };
};

/// Auto-diagnosis engine
pub const AutoDiagnosis = struct {
    allocator: Allocator,
    detected_issues: std.ArrayList(DetectedIssue),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .detected_issues = std.ArrayList(DetectedIssue).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.detected_issues.deinit();
    }
    
    /// Run full diagnosis
    pub fn runFullDiagnosis(self: *Self) !void {
        // Check each category
        try self.checkMasqueQuic();
        try self.checkAfXdp();
        try self.checkStorage();
        try self.checkSystemTuning();
    }
    
    /// Check MASQUE/QUIC issues
    fn checkMasqueQuic(self: *Self) !void {
        // Check QUIC ports
        const port_check = runShellCommand(self.allocator, "ss -ulnp | grep -E '880[1-9]|8810' || echo 'ports_available'") catch "error";
        defer self.allocator.free(port_check);
        
        if (std.mem.indexOf(u8, port_check, "ports_available") == null) {
            // Ports are in use, check if firewall is blocking
            const fw_check = runShellCommand(self.allocator, "nft list ruleset 2>/dev/null | grep -c 8801 || iptables -L -n 2>/dev/null | grep -c 8801 || echo '0'") catch "0";
            defer self.allocator.free(fw_check);
            
            const count = std.fmt.parseInt(u32, std.mem.trim(u8, fw_check, &std.ascii.whitespace), 10) catch 0;
            if (count == 0) {
                try self.detected_issues.append(.{
                    .issue = issue_db.MASQUE001,
                    .diagnosis_output = "QUIC ports 8801-8810 not explicitly allowed in firewall",
                    .confidence = .high,
                });
            }
        }
        
        // Check TLS/QUIC capability
        const tls_check = runShellCommand(self.allocator, "openssl version | grep -E '1\\.[1-9]|3\\.' || echo 'old_openssl'") catch "error";
        defer self.allocator.free(tls_check);
        
        if (std.mem.indexOf(u8, tls_check, "old_openssl") != null) {
            try self.detected_issues.append(.{
                .issue = issue_db.MASQUE003,
                .diagnosis_output = "OpenSSL version may not support TLS 1.3 required for QUIC",
                .confidence = .medium,
            });
        }
    }
    
    /// Check AF_XDP issues
    fn checkAfXdp(self: *Self) !void {
        // Check binary capabilities (try multiple common paths)
        const caps = runShellCommand(self.allocator, "getcap /home/solana/bin/vexor/vexor 2>/dev/null || getcap /opt/vexor/bin/vexor 2>/dev/null || echo 'no_caps'") catch "error";
        defer self.allocator.free(caps);
        
        if (std.mem.indexOf(u8, caps, "cap_net_raw") == null) {
            try self.detected_issues.append(.{
                .issue = issue_db.AFXDP001,
                .diagnosis_output = "Vexor binary missing AF_XDP capabilities",
                .confidence = .high,
            });
        }
        
        // Check libbpf
        const libbpf = runShellCommand(self.allocator, "ldconfig -p 2>/dev/null | grep -i libbpf || echo 'not_found'") catch "error";
        defer self.allocator.free(libbpf);
        
        if (std.mem.indexOf(u8, libbpf, "not_found") != null) {
            try self.detected_issues.append(.{
                .issue = issue_db.AFXDP003,
                .diagnosis_output = "libbpf not found in system libraries",
                .confidence = .high,
            });
        }
        
        // Check driver XDP support
        const driver = runShellCommand(self.allocator, "readlink -f /sys/class/net/eth0/device/driver 2>/dev/null | xargs basename || echo 'unknown'") catch "unknown";
        defer self.allocator.free(driver);
        
        const driver_name = std.mem.trim(u8, driver, &std.ascii.whitespace);
        if (!isXdpCapableDriver(driver_name)) {
            try self.detected_issues.append(.{
                .issue = issue_db.AFXDP002,
                .diagnosis_output = try std.fmt.allocPrint(self.allocator, "Network driver '{s}' may not support AF_XDP", .{driver_name}),
                .confidence = .medium,
            });
        }
    }
    
    /// Check storage issues
    fn checkStorage(self: *Self) !void {
        // Check ramdisk
        const ramdisk = runShellCommand(self.allocator, "mount | grep '/mnt/vexor/ramdisk.*tmpfs' || echo 'not_mounted'") catch "error";
        defer self.allocator.free(ramdisk);
        
        if (std.mem.indexOf(u8, ramdisk, "not_mounted") != null) {
            // Check if we have enough RAM for ramdisk
            const mem = runShellCommand(self.allocator, "grep MemAvailable /proc/meminfo | awk '{print $2}'") catch "0";
            defer self.allocator.free(mem);
            
            const mem_kb = std.fmt.parseInt(u64, std.mem.trim(u8, mem, &std.ascii.whitespace), 10) catch 0;
            if (mem_kb > 32 * 1024 * 1024) { // > 32GB available
                try self.detected_issues.append(.{
                    .issue = issue_db.STOR001,
                    .diagnosis_output = "Ramdisk not mounted but sufficient RAM available",
                    .confidence = .high,
                });
            }
        }
        
        // Check disk type
        const disk = runShellCommand(self.allocator, "lsblk -d -o NAME,ROTA | grep -E '^sd|^nvme' | head -1") catch "";
        defer self.allocator.free(disk);
        
        if (std.mem.indexOf(u8, disk, " 1") != null) { // ROTA=1 means HDD
            try self.detected_issues.append(.{
                .issue = issue_db.STOR002,
                .diagnosis_output = "Rotational disk (HDD) detected - NVMe strongly recommended",
                .confidence = .high,
            });
        }
    }
    
    /// Check system tuning issues
    fn checkSystemTuning(self: *Self) !void {
        // Check network buffers
        const rmem = runShellCommand(self.allocator, "sysctl -n net.core.rmem_max") catch "0";
        defer self.allocator.free(rmem);
        
        const rmem_val = std.fmt.parseInt(u64, std.mem.trim(u8, rmem, &std.ascii.whitespace), 10) catch 0;
        if (rmem_val < 134217728) {
            try self.detected_issues.append(.{
                .issue = issue_db.TUNE001,
                .diagnosis_output = try std.fmt.allocPrint(self.allocator, "net.core.rmem_max={d} (recommend: 134217728)", .{rmem_val}),
                .confidence = .high,
            });
        }
        
        // Check huge pages
        const hugepages = runShellCommand(self.allocator, "sysctl -n vm.nr_hugepages") catch "0";
        defer self.allocator.free(hugepages);
        
        const hp_val = std.fmt.parseInt(u64, std.mem.trim(u8, hugepages, &std.ascii.whitespace), 10) catch 0;
        if (hp_val == 0) {
            try self.detected_issues.append(.{
                .issue = issue_db.TUNE002,
                .diagnosis_output = "Huge pages not enabled",
                .confidence = .medium,
            });
        }
        
        // Check file limits
        const nofile = runShellCommand(self.allocator, "ulimit -n") catch "0";
        defer self.allocator.free(nofile);
        
        const nofile_val = std.fmt.parseInt(u64, std.mem.trim(u8, nofile, &std.ascii.whitespace), 10) catch 0;
        if (nofile_val < 1000000) {
            try self.detected_issues.append(.{
                .issue = issue_db.TUNE003,
                .diagnosis_output = try std.fmt.allocPrint(self.allocator, "NOFILE limit={d} (recommend: 1000000)", .{nofile_val}),
                .confidence = .high,
            });
        }
    }
    
    /// Get summary of detected issues
    pub fn getSummary(self: *Self) struct { total: usize, fixable: usize, critical: usize } {
        var fixable: usize = 0;
        var critical: usize = 0;
        
        for (self.detected_issues.items) |di| {
            if (di.issue.auto_fix != null) fixable += 1;
            if (di.issue.severity == .critical or di.issue.severity == .high) critical += 1;
        }
        
        return .{
            .total = self.detected_issues.items.len,
            .fixable = fixable,
            .critical = critical,
        };
    }
};

/// Check if driver supports XDP
fn isXdpCapableDriver(driver: []const u8) bool {
    const xdp_drivers = [_][]const u8{
        "i40e", "ice", "mlx5_core", "mlx4_en", "ixgbe", "igb", "igc", "virtio", "veth", "e1000e", "ena",
    };
    for (xdp_drivers) |xdp_driver| {
        if (std.mem.indexOf(u8, driver, xdp_driver) != null) return true;
    }
    return false;
}

/// Run a shell command and return output
fn runShellCommand(allocator: Allocator, cmd: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", cmd },
    });
    allocator.free(result.stderr);
    return result.stdout;
}

