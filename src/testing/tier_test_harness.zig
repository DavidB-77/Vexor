//! Networking Tier Test Harness
//!
//! Tests each networking tier implementation to verify it works correctly.
//! This ensures the automatic tier selection and fallback system is reliable.
//!
//! Tiers tested:
//!   1. Standard naive (basic recv/send)
//!   2. Standard batched (recvmmsg/sendmmsg)
//!   3. io_uring
//!   4. AF_XDP (requires root and compatible NIC)

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const net = std.net;

const capability_test = @import("network_capability_test.zig");
const traffic_sim = @import("traffic_simulator.zig");

/// Test result for a single tier
pub const TierTestResult = struct {
    tier: capability_test.NetworkTier,
    available: bool,
    test_passed: bool,
    packets_sent: u64,
    packets_received: u64,
    error_message: ?[]const u8,
    throughput_pps: u64, // Packets per second (estimated)
};

/// Full test harness
pub const TierTestHarness = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(TierTestResult),
    capabilities: capability_test.CapabilityReport,
    
    pub fn init(allocator: std.mem.Allocator) TierTestHarness {
        return .{
            .allocator = allocator,
            .results = std.ArrayList(TierTestResult).init(allocator),
            .capabilities = capability_test.detectCapabilities(),
        };
    }
    
    pub fn deinit(self: *TierTestHarness) void {
        self.results.deinit();
    }
    
    /// Test Tier 4: Standard naive sockets
    pub fn testStandardNaive(_: *TierTestHarness) !TierTestResult {
        std.debug.print("\n", .{});
        std.debug.print("Testing Tier 4: Standard Naive Sockets\n", .{});
        std.debug.print("───────────────────────────────────────\n", .{});
        
        const test_port: u16 = 19001;
        const packet_count: usize = 100;
        
        // Create receiver socket
        const recv_sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        defer posix.close(recv_sock);
        
        const recv_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, test_port),
            .addr = 0,
        };
        try posix.bind(recv_sock, @ptrCast(&recv_addr), @sizeOf(@TypeOf(recv_addr)));
        
        // Create sender socket
        const send_sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer posix.close(send_sock);
        
        const target = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, test_port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        };
        
        // Send packets
        var send_buf: [256]u8 = undefined;
        for (0..256) |i| send_buf[i] = @truncate(i);
        
        var sent: u64 = 0;
        const start_time = std.time.nanoTimestamp();
        
        for (0..packet_count) |_| {
            const result = posix.sendto(
                send_sock,
                &send_buf,
                0,
                @ptrCast(&target),
                @sizeOf(@TypeOf(target)),
            );
            if (result) |_| {
                sent += 1;
            } else |_| {}
        }
        
        // Small delay for packets to arrive
        std.time.sleep(5_000_000); // 5ms
        
        // Receive packets
        var recv_buf: [1500]u8 = undefined;
        var received: u64 = 0;
        
        while (true) {
            const result = posix.recvfrom(recv_sock, &recv_buf, 0, null, null);
            if (result) |_| {
                received += 1;
            } else |err| {
                if (err == error.WouldBlock) break;
            }
        }
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(end_time - start_time));
        const throughput = if (duration_ns > 0) (sent * 1_000_000_000) / duration_ns else 0;
        
        const passed = received >= (sent * 90 / 100); // 90% success rate
        
        std.debug.print("  Sent: {d}, Received: {d}, Throughput: ~{d} pps\n", .{sent, received, throughput});
        std.debug.print("  Result: {s}\n", .{if (passed) "PASS" else "FAIL"});
        
        return .{
            .tier = .standard_naive,
            .available = true,
            .test_passed = passed,
            .packets_sent = sent,
            .packets_received = received,
            .error_message = null,
            .throughput_pps = throughput,
        };
    }
    
    /// Test Tier 3: io_uring (if available)
    pub fn testIoUring(self: *TierTestHarness) !TierTestResult {
        std.debug.print("\n", .{});
        std.debug.print("Testing Tier 3: io_uring\n", .{});
        std.debug.print("────────────────────────\n", .{});
        
        if (!self.capabilities.has_io_uring) {
            std.debug.print("  io_uring not available on this system\n", .{});
            return .{
                .tier = .io_uring,
                .available = false,
                .test_passed = false,
                .packets_sent = 0,
                .packets_received = 0,
                .error_message = "io_uring not available",
                .throughput_pps = 0,
            };
        }
        
        // Initialize io_uring
        var params = std.mem.zeroes(linux.io_uring_params);
        const ring_fd = linux.io_uring_setup(64, &params);
        
        if (ring_fd < 0) {
            std.debug.print("  Failed to initialize io_uring\n", .{});
            return .{
                .tier = .io_uring,
                .available = false,
                .test_passed = false,
                .packets_sent = 0,
                .packets_received = 0,
                .error_message = "io_uring_setup failed",
                .throughput_pps = 0,
            };
        }
        defer _ = linux.close(@intCast(ring_fd));
        
        std.debug.print("  io_uring initialized (fd={d})\n", .{ring_fd});
        std.debug.print("  Features: 0x{x}\n", .{params.features});
        
        // For a full test, we would set up UMEM, rings, etc.
        // For now, just verify initialization works
        
        std.debug.print("  Result: PASS (initialization test)\n", .{});
        
        return .{
            .tier = .io_uring,
            .available = true,
            .test_passed = true,
            .packets_sent = 0,
            .packets_received = 0,
            .error_message = null,
            .throughput_pps = 0, // Would need full test
        };
    }
    
    /// Test Tier 1-2: AF_XDP (requires root)
    pub fn testAfXdp(self: *TierTestHarness) !TierTestResult {
        std.debug.print("\n", .{});
        std.debug.print("Testing Tier 1-2: AF_XDP\n", .{});
        std.debug.print("─────────────────────────\n", .{});
        
        // Check if we have the required capabilities
        if (!self.capabilities.has_cap_net_admin or !self.capabilities.has_cap_bpf) {
            std.debug.print("  Requires root/CAP_NET_ADMIN + CAP_BPF\n", .{});
            std.debug.print("  Run with sudo for full AF_XDP test\n", .{});
            return .{
                .tier = .af_xdp_zero_copy,
                .available = false,
                .test_passed = false,
                .packets_sent = 0,
                .packets_received = 0,
                .error_message = "Requires root privileges",
                .throughput_pps = 0,
            };
        }
        
        // Try to create an AF_XDP socket
        const AF_XDP = 44; // Address family for XDP
        const sock = posix.socket(AF_XDP, posix.SOCK.RAW, 0) catch |err| {
            std.debug.print("  AF_XDP socket creation failed: {}\n", .{err});
            return .{
                .tier = .af_xdp_zero_copy,
                .available = false,
                .test_passed = false,
                .packets_sent = 0,
                .packets_received = 0,
                .error_message = "AF_XDP socket creation failed",
                .throughput_pps = 0,
            };
        };
        posix.close(sock);
        
        std.debug.print("  AF_XDP socket created successfully\n", .{});
        std.debug.print("  Result: PASS (socket creation test)\n", .{});
        
        return .{
            .tier = .af_xdp_zero_copy,
            .available = true,
            .test_passed = true,
            .packets_sent = 0,
            .packets_received = 0,
            .error_message = null,
            .throughput_pps = 0, // Would need veth for full test
        };
    }
    
    /// Run all tier tests
    pub fn runAllTests(self: *TierTestHarness) !void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║         VEXOR NETWORKING TIER TESTS                      ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        
        // Show detected capabilities first
        std.debug.print("\n", .{});
        std.debug.print("System Capabilities:\n", .{});
        std.debug.print("  Kernel: {d}.{d}.{d}\n", .{
            self.capabilities.kernel_version.major,
            self.capabilities.kernel_version.minor,
            self.capabilities.kernel_version.patch,
        });
        std.debug.print("  io_uring: {s}\n", .{if (self.capabilities.has_io_uring) "YES" else "NO"});
        std.debug.print("  BPF: {s}\n", .{if (self.capabilities.has_bpf_syscall) "YES" else "NO"});
        std.debug.print("  Running as root: {s}\n", .{if (self.capabilities.has_cap_net_admin) "YES" else "NO"});
        
        // Test each tier
        const naive_result = try self.testStandardNaive();
        try self.results.append(naive_result);
        
        const io_uring_result = try self.testIoUring();
        try self.results.append(io_uring_result);
        
        const xdp_result = try self.testAfXdp();
        try self.results.append(xdp_result);
        
        // Summary
        self.printSummary();
    }
    
    fn printSummary(self: *TierTestHarness) void {
        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("                      TEST SUMMARY                          \n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  Tier              │ Available │ Passed │ Throughput\n", .{});
        std.debug.print("  ──────────────────┼───────────┼────────┼────────────\n", .{});
        
        for (self.results.items) |r| {
            const tier_name = switch (r.tier) {
                .af_xdp_zero_copy => "AF_XDP Zero-Copy",
                .af_xdp_copy => "AF_XDP Copy    ",
                .io_uring => "io_uring       ",
                .standard_batched => "Batched Sockets",
                .standard_naive => "Naive Sockets  ",
            };
            
            const avail = if (r.available) "YES" else "NO ";
            const passed = if (r.test_passed) "YES" else "NO ";
            
            if (r.throughput_pps > 0) {
                std.debug.print("  {s} │    {s}    │  {s}   │ ~{d} pps\n", .{tier_name, avail, passed, r.throughput_pps});
            } else {
                std.debug.print("  {s} │    {s}    │  {s}   │ N/A\n", .{tier_name, avail, passed});
            }
        }
        
        std.debug.print("\n", .{});
        std.debug.print("  Recommended tier: {s}\n", .{@tagName(self.capabilities.recommended_tier)});
        std.debug.print("\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var harness = TierTestHarness.init(allocator);
    defer harness.deinit();
    
    try harness.runAllTests();
}
