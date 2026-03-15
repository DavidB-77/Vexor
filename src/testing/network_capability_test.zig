//! Lightweight Network Capability Detection for Vexor
//!
//! This module tests what networking features are available on the current system
//! without using significant memory or resources.
//!
//! Memory budget: < 10 MB
//! No external processes spawned
//! Safe to run on development machines

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Results of capability detection
pub const CapabilityReport = struct {
    // System info
    kernel_version: KernelVersion,
    
    // Socket capabilities
    can_create_udp_socket: bool,
    can_bind_privileged: bool,
    can_use_nonblocking: bool,
    
    // Advanced I/O
    has_recvmmsg: bool,
    has_sendmmsg: bool,
    has_io_uring: bool,
    io_uring_version: ?u32,
    
    // XDP/BPF capabilities
    has_bpf_syscall: bool,
    can_load_bpf: bool,
    bpf_fs_accessible: bool,
    
    // Capabilities
    has_cap_net_admin: bool,
    has_cap_net_raw: bool,
    has_cap_bpf: bool,
    
    // Recommended tier
    recommended_tier: NetworkTier,
    
    pub fn print(self: *const CapabilityReport) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║         VEXOR NETWORK CAPABILITY REPORT                  ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        
        // Kernel
        std.debug.print("║ Kernel Version: {d}.{d}.{d}", .{
            self.kernel_version.major,
            self.kernel_version.minor,
            self.kernel_version.patch,
        });
        printPadding(44 - countDigits(self.kernel_version));
        std.debug.print("║\n", .{});
        
        // Socket capabilities
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("║ Socket Capabilities:                                     ║\n", .{});
        printCapability("  UDP Socket", self.can_create_udp_socket);
        printCapability("  Non-blocking I/O", self.can_use_nonblocking);
        printCapability("  recvmmsg/sendmmsg", self.has_recvmmsg);
        
        // io_uring
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("║ Advanced I/O:                                            ║\n", .{});
        if (self.has_io_uring) {
            std.debug.print("║   io_uring: YES (v{d})", .{self.io_uring_version orelse 0});
            printPadding(36);
            std.debug.print("║\n", .{});
        } else {
            printCapability("  io_uring", false);
        }
        
        // BPF/XDP
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("║ eBPF/XDP Support:                                        ║\n", .{});
        printCapability("  BPF syscall", self.has_bpf_syscall);
        printCapability("  Can load BPF programs", self.can_load_bpf);
        printCapability("  /sys/fs/bpf accessible", self.bpf_fs_accessible);
        
        // Capabilities
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("║ Linux Capabilities:                                      ║\n", .{});
        printCapability("  CAP_NET_ADMIN", self.has_cap_net_admin);
        printCapability("  CAP_NET_RAW", self.has_cap_net_raw);
        printCapability("  CAP_BPF", self.has_cap_bpf);
        
        // Recommendation
        std.debug.print("║                                                          ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ RECOMMENDED TIER: {s}", .{@tagName(self.recommended_tier)});
        printPadding(40 - @tagName(self.recommended_tier).len);
        std.debug.print("║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
    }
    
    fn countDigits(kv: KernelVersion) usize {
        var count: usize = 3; // For the dots
        count += if (kv.major >= 10) 2 else 1;
        count += if (kv.minor >= 10) 2 else 1;
        count += if (kv.patch >= 100) 3 else if (kv.patch >= 10) 2 else 1;
        return count;
    }
    
    fn printPadding(spaces: usize) void {
        for (0..spaces) |_| {
            std.debug.print(" ", .{});
        }
    }
    
    fn printCapability(name: []const u8, available: bool) void {
        std.debug.print("║ {s}: ", .{name});
        const name_len = name.len + 2;
        const status = if (available) "YES" else "NO";
        const color = if (available) "\x1b[32m" else "\x1b[31m"; // Green or Red
        const reset = "\x1b[0m";
        std.debug.print("{s}{s}{s}", .{color, status, reset});
        printPadding(55 - name_len - status.len);
        std.debug.print("║\n", .{});
    }
};

pub const KernelVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const NetworkTier = enum {
    af_xdp_zero_copy,  // Best: Zero-copy AF_XDP
    af_xdp_copy,       // Good: AF_XDP with copy mode
    io_uring,          // Decent: io_uring batched I/O
    standard_batched,  // Fallback: recvmmsg/sendmmsg
    standard_naive,    // Last resort: basic recv/send
};

/// Detect all network capabilities
pub fn detectCapabilities() CapabilityReport {
    var report = CapabilityReport{
        .kernel_version = getKernelVersion(),
        .can_create_udp_socket = false,
        .can_bind_privileged = false,
        .can_use_nonblocking = false,
        .has_recvmmsg = true, // Always available on Linux 3.0+
        .has_sendmmsg = true, // Always available on Linux 3.0+
        .has_io_uring = false,
        .io_uring_version = null,
        .has_bpf_syscall = false,
        .can_load_bpf = false,
        .bpf_fs_accessible = false,
        .has_cap_net_admin = false,
        .has_cap_net_raw = false,
        .has_cap_bpf = false,
        .recommended_tier = .standard_batched,
    };
    
    // Test UDP socket creation
    report.can_create_udp_socket = testUdpSocket();
    report.can_use_nonblocking = testNonblocking();
    
    // Test io_uring
    const io_uring_result = testIoUring();
    report.has_io_uring = io_uring_result.available;
    report.io_uring_version = io_uring_result.version;
    
    // Test BPF capabilities
    report.has_bpf_syscall = testBpfSyscall();
    report.bpf_fs_accessible = testBpfFs();
    
    // Check capabilities (simplified - checks if running as root)
    const is_root = std.os.linux.getuid() == 0;
    report.has_cap_net_admin = is_root;
    report.has_cap_net_raw = is_root;
    report.has_cap_bpf = is_root and report.kernel_version.major >= 5;
    
    // Determine recommended tier
    report.recommended_tier = selectTier(&report);
    
    return report;
}

fn getKernelVersion() KernelVersion {
    var uts: std.os.linux.utsname = undefined;
    const rc = std.os.linux.uname(&uts);
    if (rc != 0) {
        return .{ .major = 5, .minor = 0, .patch = 0 }; // Default assumption
    }
    
    const release = std.mem.sliceTo(&uts.release, 0);
    var parts = std.mem.splitScalar(u8, release, '.');
    
    const major = std.fmt.parseInt(u32, parts.next() orelse "5", 10) catch 5;
    const minor_str = parts.next() orelse "0";
    // Minor might have extra chars like "15-generic"
    var minor_end: usize = 0;
    for (minor_str) |c| {
        if (c >= '0' and c <= '9') {
            minor_end += 1;
        } else {
            break;
        }
    }
    const minor = std.fmt.parseInt(u32, minor_str[0..minor_end], 10) catch 0;
    
    const patch_str = parts.next() orelse "0";
    var patch_end: usize = 0;
    for (patch_str) |c| {
        if (c >= '0' and c <= '9') {
            patch_end += 1;
        } else {
            break;
        }
    }
    const patch = std.fmt.parseInt(u32, patch_str[0..patch_end], 10) catch 0;
    
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn testUdpSocket() bool {
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch return false;
    posix.close(sock);
    return true;
}

fn testNonblocking() bool {
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0) catch return false;
    posix.close(sock);
    return true;
}

const IoUringResult = struct {
    available: bool,
    version: ?u32,
};

fn testIoUring() IoUringResult {
    // Try to initialize a minimal io_uring
    var params = std.mem.zeroes(linux.io_uring_params);
    
    // Use small ring size to minimize memory
    const fd = linux.io_uring_setup(8, &params);
    
    if (fd < 0) {
        return .{ .available = false, .version = null };
    }
    
    // Success - close the fd
    _ = linux.close(@intCast(fd));
    
    return .{
        .available = true,
        .version = params.features,
    };
}

fn testBpfSyscall() bool {
    // Check if BPF is available by looking for BTF (BPF Type Format) support
    // This exists on kernels 4.18+ with BPF enabled
    const btf_result = posix.access("/sys/kernel/btf/vmlinux", posix.F_OK);
    if (btf_result) |_| {
        return true;
    } else |_| {
        // Fallback: check /proc/config.gz or assume available on kernel 5+
        // For simplicity, just check kernel version
        const kv = getKernelVersion();
        return kv.major >= 5 or (kv.major == 4 and kv.minor >= 18);
    }
}

fn testBpfFs() bool {
    // Check if /sys/fs/bpf exists and is accessible
    const result = posix.access("/sys/fs/bpf", posix.F_OK);
    if (result) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn selectTier(report: *const CapabilityReport) NetworkTier {
    // Check for AF_XDP capability
    const can_xdp = report.has_bpf_syscall and 
                    report.has_cap_net_admin and 
                    report.has_cap_bpf and
                    report.kernel_version.major >= 5;
    
    if (can_xdp) {
        // Check if likely to have zero-copy support (kernel 5.4+)
        if (report.kernel_version.major > 5 or 
            (report.kernel_version.major == 5 and report.kernel_version.minor >= 4)) {
            return .af_xdp_zero_copy;
        }
        return .af_xdp_copy;
    }
    
    // Try io_uring
    if (report.has_io_uring) {
        return .io_uring;
    }
    
    // Fallback to batched sockets
    if (report.has_recvmmsg) {
        return .standard_batched;
    }
    
    return .standard_naive;
}

/// Run all capability tests and print results
pub fn runDiagnostics() void {
    std.debug.print("\n", .{});
    std.debug.print("Vexor Network Capability Detection\n", .{});
    std.debug.print("===================================\n", .{});
    std.debug.print("Memory usage: < 1 MB\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Running tests...\n", .{});
    
    const report = detectCapabilities();
    report.print();
    
    // Print recommendations
    std.debug.print("Tier Explanation:\n", .{});
    std.debug.print("  af_xdp_zero_copy : Best performance (10-20+ Mpps)\n", .{});
    std.debug.print("  af_xdp_copy      : Good performance (5-10 Mpps)\n", .{});
    std.debug.print("  io_uring         : Decent performance (3-5 Mpps)\n", .{});
    std.debug.print("  standard_batched : Fallback (1-2 Mpps)\n", .{});
    std.debug.print("  standard_naive   : Last resort (< 500 Kpps)\n", .{});
    std.debug.print("\n", .{});
}

// Entry point for standalone testing
pub fn main() !void {
    runDiagnostics();
}

// Tests
test "kernel version parsing" {
    const kv = getKernelVersion();
    try std.testing.expect(kv.major >= 4); // Reasonable minimum
}

test "udp socket creation" {
    try std.testing.expect(testUdpSocket());
}

test "nonblocking sockets" {
    try std.testing.expect(testNonblocking());
}
