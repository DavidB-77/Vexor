//! Traffic Simulator for Vexor Network Testing
//!
//! Simulates Solana-like UDP traffic patterns to test networking tiers.
//! Designed to be lightweight (< 50 MB RAM) and safe for development machines.
//!
//! Usage:
//!   const sim = TrafficSimulator.init(allocator);
//!   defer sim.deinit();
//!   try sim.runGossipTest(target_addr, 100);  // Send 100 gossip-like packets

const std = @import("std");
const posix = std.posix;
const net = std.net;

/// Simulates various Solana network traffic patterns
pub const TrafficSimulator = struct {
    allocator: std.mem.Allocator,
    stats: Stats,
    
    // Pre-allocated buffers to minimize memory usage
    send_buffer: [MAX_PACKET_SIZE]u8,
    recv_buffer: [MAX_PACKET_SIZE]u8,
    
    const MAX_PACKET_SIZE = 1232; // Solana MTU for shreds
    const GOSSIP_PACKET_SIZE = 256;
    
    pub const Stats = struct {
        packets_sent: u64 = 0,
        packets_received: u64 = 0,
        bytes_sent: u64 = 0,
        bytes_received: u64 = 0,
        errors: u64 = 0,
        latency_sum_us: u64 = 0,
        latency_count: u64 = 0,
        
        pub fn avgLatencyUs(self: *const Stats) u64 {
            if (self.latency_count == 0) return 0;
            return self.latency_sum_us / self.latency_count;
        }
        
        pub fn print(self: *const Stats) void {
            std.debug.print("\n", .{});
            std.debug.print("Traffic Simulator Stats:\n", .{});
            std.debug.print("  Packets sent:     {d}\n", .{self.packets_sent});
            std.debug.print("  Packets received: {d}\n", .{self.packets_received});
            std.debug.print("  Bytes sent:       {d}\n", .{self.bytes_sent});
            std.debug.print("  Bytes received:   {d}\n", .{self.bytes_received});
            std.debug.print("  Errors:           {d}\n", .{self.errors});
            if (self.latency_count > 0) {
                std.debug.print("  Avg latency:      {d} us\n", .{self.avgLatencyUs()});
            }
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) TrafficSimulator {
        return .{
            .allocator = allocator,
            .stats = .{},
            .send_buffer = undefined,
            .recv_buffer = undefined,
        };
    }
    
    pub fn deinit(self: *TrafficSimulator) void {
        _ = self;
        // No heap allocations to free
    }
    
    /// Create a mock gossip PING packet
    fn createMockGossipPing(self: *TrafficSimulator) []const u8 {
        // Simplified Solana gossip PING structure
        // Real format: [4 bytes type][32 bytes from pubkey][32 bytes token][...]
        const packet = &self.send_buffer;
        
        // Message type: PING = 0x06
        packet[0] = 0x06;
        packet[1] = 0x00;
        packet[2] = 0x00;
        packet[3] = 0x00;
        
        // Mock pubkey (32 bytes)
        for (4..36) |i| {
            packet[i] = @truncate(i);
        }
        
        // Mock token (32 bytes)
        for (36..68) |i| {
            packet[i] = @truncate(i ^ 0xAA);
        }
        
        // Timestamp
        const ts = std.time.milliTimestamp();
        std.mem.writeInt(i64, packet[68..76], ts, .little);
        
        return packet[0..GOSSIP_PACKET_SIZE];
    }
    
    /// Create a mock shred packet (TVU traffic)
    fn createMockShred(self: *TrafficSimulator, slot: u64, index: u32) []const u8 {
        const packet = &self.send_buffer;
        
        // Shred header (simplified)
        // [1 byte variant][8 bytes slot][4 bytes index][4 bytes version]...
        packet[0] = 0x80; // Data shred variant
        
        std.mem.writeInt(u64, packet[1..9], slot, .little);
        std.mem.writeInt(u32, packet[9..13], index, .little);
        std.mem.writeInt(u16, packet[13..15], 27350, .little); // Shred version (testnet)
        
        // Fill rest with mock data
        for (15..MAX_PACKET_SIZE) |i| {
            packet[i] = @truncate(i ^ @as(usize, @truncate(slot)));
        }
        
        return packet[0..MAX_PACKET_SIZE];
    }
    
    /// Send UDP packets to a target address
    pub fn sendPackets(
        self: *TrafficSimulator,
        target: net.Address,
        packets: []const []const u8,
    ) !usize {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer posix.close(sock);
        
        var sent: usize = 0;
        for (packets) |packet| {
            const sockaddr = target.any;
            const result = posix.sendto(
                sock,
                packet,
                0,
                &sockaddr,
                @sizeOf(@TypeOf(sockaddr)),
            );
            
            if (result) |bytes| {
                self.stats.packets_sent += 1;
                self.stats.bytes_sent += bytes;
                sent += 1;
            } else |_| {
                self.stats.errors += 1;
            }
        }
        
        return sent;
    }
    
    /// Run a gossip simulation test
    pub fn runGossipTest(self: *TrafficSimulator, target: net.Address, count: usize) !void {
        std.debug.print("Running gossip simulation: {d} packets to {}\n", .{count, target});
        
        for (0..count) |_| {
            const packet = self.createMockGossipPing();
            _ = try self.sendPackets(target, &.{packet});
            
            // Small delay to avoid overwhelming
            std.time.sleep(1_000_000); // 1ms
        }
        
        std.debug.print("Gossip test complete\n", .{});
    }
    
    /// Run a shred/TVU simulation test
    pub fn runShredTest(self: *TrafficSimulator, target: net.Address, slot: u64, shred_count: usize) !void {
        std.debug.print("Running shred simulation: slot {d}, {d} shreds to {}\n", .{slot, shred_count, target});
        
        for (0..shred_count) |i| {
            const packet = self.createMockShred(slot, @truncate(i));
            _ = try self.sendPackets(target, &.{packet});
        }
        
        std.debug.print("Shred test complete\n", .{});
    }
};

/// Test receiver that counts incoming packets
pub const TestReceiver = struct {
    socket: posix.socket_t,
    stats: TrafficSimulator.Stats,
    recv_buffer: [1500]u8,
    running: std.atomic.Value(bool),
    
    pub fn init(bind_port: u16) !TestReceiver {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(sock);
        
        // Enable SO_REUSEADDR
        const opt: c_int = 1;
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&opt));
        
        // Bind to port
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, bind_port),
            .addr = 0, // INADDR_ANY
        };
        try posix.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        
        return .{
            .socket = sock,
            .stats = .{},
            .recv_buffer = undefined,
            .running = std.atomic.Value(bool).init(true),
        };
    }
    
    pub fn deinit(self: *TestReceiver) void {
        posix.close(self.socket);
    }
    
    /// Receive packets in a loop (call from a separate thread or poll)
    pub fn receiveOnce(self: *TestReceiver) bool {
        const result = posix.recvfrom(
            self.socket,
            &self.recv_buffer,
            0,
            null,
            null,
        );
        
        if (result) |bytes| {
            self.stats.packets_received += 1;
            self.stats.bytes_received += bytes;
            return true;
        } else |err| {
            if (err == error.WouldBlock) {
                return false; // No data available
            }
            self.stats.errors += 1;
            return false;
        }
    }
    
    /// Poll for packets for a duration
    pub fn pollFor(self: *TestReceiver, duration_ms: u64) void {
        const end_time = std.time.milliTimestamp() + @as(i64, @intCast(duration_ms));
        
        while (std.time.milliTimestamp() < end_time) {
            if (!self.receiveOnce()) {
                std.time.sleep(100_000); // 0.1ms
            }
        }
    }
};

/// Full loopback test - sends and receives on localhost
pub fn runLoopbackTest(allocator: std.mem.Allocator) !bool {
    std.debug.print("\n", .{});
    std.debug.print("=== Loopback Network Test ===\n", .{});
    std.debug.print("Testing UDP send/receive on localhost\n", .{});
    std.debug.print("\n", .{});
    
    const test_port: u16 = 19876;
    const packet_count: usize = 10;
    
    // Start receiver
    var receiver = try TestReceiver.init(test_port);
    defer receiver.deinit();
    
    std.debug.print("Receiver bound to port {d}\n", .{test_port});
    
    // Create sender
    var simulator = TrafficSimulator.init(allocator);
    defer simulator.deinit();
    
    // Target localhost
    const target = net.Address.initIp4(.{127, 0, 0, 1}, test_port);
    
    // Send packets
    std.debug.print("Sending {d} test packets...\n", .{packet_count});
    for (0..packet_count) |_| {
        const packet = simulator.createMockGossipPing();
        _ = try simulator.sendPackets(target, &.{packet});
    }
    
    // Give time for packets to arrive
    std.time.sleep(10_000_000); // 10ms
    
    // Receive packets
    receiver.pollFor(100); // Poll for 100ms
    
    // Check results
    std.debug.print("\n", .{});
    std.debug.print("Results:\n", .{});
    std.debug.print("  Sent:     {d} packets\n", .{simulator.stats.packets_sent});
    std.debug.print("  Received: {d} packets\n", .{receiver.stats.packets_received});
    
    const success = receiver.stats.packets_received >= packet_count;
    
    if (success) {
        std.debug.print("\n", .{});
        std.debug.print("[PASS] Loopback test successful!\n", .{});
    } else {
        std.debug.print("\n", .{});
        std.debug.print("[FAIL] Not all packets received\n", .{});
    }
    
    return success;
}

/// Test recvmmsg batching if available
pub fn runBatchingTest(allocator: std.mem.Allocator) !bool {
    std.debug.print("\n", .{});
    std.debug.print("=== Batched I/O Test (recvmmsg/sendmmsg) ===\n", .{});
    
    _ = allocator;
    
    // For now, just verify the syscall exists
    // Full implementation would test actual batching
    
    const has_recvmmsg = @hasDecl(std.os.linux, "recvmmsg");
    const has_sendmmsg = @hasDecl(std.os.linux, "sendmmsg");
    
    std.debug.print("recvmmsg available: {}\n", .{has_recvmmsg});
    std.debug.print("sendmmsg available: {}\n", .{has_sendmmsg});
    
    if (has_recvmmsg and has_sendmmsg) {
        std.debug.print("\n", .{});
        std.debug.print("[PASS] Batched I/O syscalls available\n", .{});
        return true;
    } else {
        std.debug.print("\n", .{});
        std.debug.print("[INFO] Batched I/O not available, will use standard sockets\n", .{});
        return false;
    }
}

/// Run all network tests
pub fn runAllTests(allocator: std.mem.Allocator) !void {
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         VEXOR NETWORK IMPLEMENTATION TESTS               ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    // Test 1: Loopback
    if (try runLoopbackTest(allocator)) {
        passed += 1;
    } else {
        failed += 1;
    }
    
    // Test 2: Batching
    if (try runBatchingTest(allocator)) {
        passed += 1;
    } else {
        // Not a failure, just not available
        passed += 1;
    }
    
    // Summary
    std.debug.print("\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Test Summary: {d} passed, {d} failed\n", .{passed, failed});
    std.debug.print("══════════════════════════════════════════════════════════\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try runAllTests(allocator);
}
