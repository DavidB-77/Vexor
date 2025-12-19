//! AF_XDP Kernel Bypass Networking
//! High-performance networking using Linux XDP (eXpress Data Path).
//!
//! Performance comparison:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                    │ Standard UDP │ AF_XDP     │ DPDK       │
//! ├─────────────────────────────────────────────────────────────┤
//! │ Latency (μs)       │ 5-20         │ <1         │ <1         │
//! │ Throughput (PPS)   │ ~1M          │ ~10M       │ ~20M       │
//! │ CPU per packet     │ High         │ Low        │ Lowest     │
//! │ Kernel bypass      │ No           │ Partial    │ Full       │
//! │ Compatibility      │ Excellent    │ Good       │ Limited    │
//! │ Complexity         │ Low          │ Medium     │ High       │
//! └─────────────────────────────────────────────────────────────┘
//!
//! Requirements:
//! - Linux kernel 4.18+ (5.3+ recommended)
//! - CAP_NET_RAW or root privileges
//! - NIC driver with XDP support (most modern NICs)
//!
//! Usage:
//! ```zig
//! const af_xdp = @import("af_xdp/root.zig");
//!
//! var processor = try af_xdp.PacketProcessor.init(allocator, .{
//!     .xdp_config = .{
//!         .interface = "eth0",
//!         .queue_id = 0,
//!     },
//! });
//! defer processor.deinit();
//!
//! processor.registerHandler(.gossip, handleGossip);
//! processor.registerHandler(.turbine_shred, handleShred);
//!
//! try processor.start();
//! ```

const std = @import("std");
const builtin = @import("builtin");

pub const socket = @import("socket.zig");
pub const processor = @import("processor.zig");
pub const xdp_program = @import("xdp_program.zig");

// Socket types
pub const XdpSocket = socket.XdpSocket;
pub const XdpConfig = socket.XdpConfig;
pub const XdpStatistics = socket.XdpStatistics;
pub const Packet = socket.Packet;
pub const XdpDesc = socket.XdpDesc;
pub const UmemRing = socket.UmemRing;
pub const DescRing = socket.DescRing;

// eBPF XDP Program
pub const XdpProgram = xdp_program.XdpProgram;

// Processor types
pub const PacketProcessor = processor.PacketProcessor;
pub const ProcessorConfig = processor.ProcessorConfig;
pub const PacketStats = processor.PacketStats;
pub const ParsedPacket = processor.ParsedPacket;
pub const PacketType = processor.PacketType;
pub const PacketHandler = processor.PacketHandler;

// Protocol headers
pub const EthHeader = processor.EthHeader;
pub const Ipv4Header = processor.Ipv4Header;
pub const UdpHeader = processor.UdpHeader;

/// Check if AF_XDP is available on this system
pub fn isAvailable() bool {
    // Check if we're on Linux
    if (builtin.os.tag != .linux) {
        std.debug.print("debug: [AF_XDP] Not available: not Linux\n", .{});
        return false;
    }

    // Try to create an AF_XDP socket
    const fd = std.posix.socket(socket.AF_XDP, std.posix.SOCK.RAW, 0) catch |err| {
        std.debug.print("debug: [AF_XDP] Socket creation test failed - not available\n", .{});
        // Provide helpful error messages
        if (err == error.PermissionDenied) {
            std.debug.print("info: [AF_XDP] Permission denied. Fix with: sudo setcap cap_net_raw,cap_net_admin+ep /path/to/vexor\n", .{});
        } else if (err == error.AddressFamilyNotSupported) {
            std.debug.print("info: [AF_XDP] Kernel doesn't support AF_XDP. Need kernel 4.18+\n", .{});
        }
        return false;
    };
    std.posix.close(fd);

    std.debug.print("debug: [AF_XDP] Available and working\n", .{});
    return true;
}

/// Get XDP capabilities for an interface
pub fn getInterfaceCaps(interface: []const u8) InterfaceCaps {
    _ = interface;
    return .{
        .xdp_supported = isAvailable(),
        .zero_copy = false, // Would need to check driver
        .hw_offload = false,
        .max_queues = 1,
    };
}

/// Interface capabilities
pub const InterfaceCaps = struct {
    xdp_supported: bool,
    zero_copy: bool,
    hw_offload: bool,
    max_queues: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "imports compile" {
    _ = socket;
    _ = processor;
}

test "isAvailable: check" {
    // This will be false in non-Linux environments
    const available = isAvailable();
    _ = available;
}

test "getInterfaceCaps: basic" {
    const caps = getInterfaceCaps("eth0");
    _ = caps;
}

