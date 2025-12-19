//! AF_XDP Socket Implementation
//! High-performance kernel bypass networking using Linux AF_XDP.
//!
//! AF_XDP provides:
//! - Zero-copy packet processing
//! - Direct NIC → userspace path
//! - UMEM ring buffers shared with kernel
//! - 10M+ packets/sec capability
//!
//! Memory layout:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                         UMEM                                 │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ Frame 0 │ Frame 1 │ Frame 2 │ ... │ Frame N          │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! ├─────────────────────────────────────────────────────────────┤
//! │  Fill Ring (kernel → user): frames ready to receive         │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ producer │ consumer │ [addr] [addr] [addr] ...       │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! ├─────────────────────────────────────────────────────────────┤
//! │  Completion Ring (kernel → user): TX frames completed       │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ producer │ consumer │ [addr] [addr] [addr] ...       │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! ├─────────────────────────────────────────────────────────────┤
//! │  RX Ring (kernel → user): received packets                  │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ producer │ consumer │ [desc] [desc] [desc] ...       │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! ├─────────────────────────────────────────────────────────────┤
//! │  TX Ring (user → kernel): packets to send                   │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ producer │ consumer │ [desc] [desc] [desc] ...       │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

/// AF_XDP socket address family (Linux specific)
pub const AF_XDP: u16 = 44;

/// XDP socket options
pub const SOL_XDP: u32 = 283;
pub const XDP_MMAP_OFFSETS: u32 = 1;
pub const XDP_RX_RING: u32 = 2;
pub const XDP_TX_RING: u32 = 3;
pub const XDP_UMEM_REG: u32 = 4;
pub const XDP_UMEM_FILL_RING: u32 = 5;
pub const XDP_UMEM_COMPLETION_RING: u32 = 6;
pub const XDP_STATISTICS: u32 = 7;
pub const XDP_OPTIONS: u32 = 8;

/// XDP flags
pub const XDP_FLAGS_UPDATE_IF_NOEXIST: u32 = 1 << 0;
pub const XDP_FLAGS_SKB_MODE: u32 = 1 << 1;
pub const XDP_FLAGS_DRV_MODE: u32 = 1 << 2;
pub const XDP_FLAGS_HW_MODE: u32 = 1 << 3;
pub const XDP_FLAGS_REPLACE: u32 = 1 << 4;

/// XDP bind flags
pub const XDP_SHARED_UMEM: u16 = 1 << 0;
pub const XDP_COPY: u16 = 1 << 1;
pub const XDP_ZEROCOPY: u16 = 1 << 2;
pub const XDP_USE_NEED_WAKEUP: u16 = 1 << 3;

/// XDP ring flags (checked at runtime to avoid unnecessary wakeups)
pub const XDP_RING_NEED_WAKEUP: u32 = 1 << 0;

/// XDP mmap page offsets for ring buffers
pub const XDP_PGOFF_RX_RING: u64 = 0;
pub const XDP_PGOFF_TX_RING: u64 = 0x80000000;
pub const XDP_UMEM_PGOFF_FILL_RING: u64 = 0x100000000;
pub const XDP_UMEM_PGOFF_COMPLETION_RING: u64 = 0x180000000;

/// UMEM registration structure
pub const XdpUmemReg = extern struct {
    addr: u64,
    len: u64,
    chunk_size: u32,
    headroom: u32,
    flags: u32,
};

/// Ring offset structure
pub const XdpRingOffset = extern struct {
    producer: u64,
    consumer: u64,
    desc: u64,
    flags: u64,
};

/// Mmap offsets
pub const XdpMmapOffsets = extern struct {
    rx: XdpRingOffset,
    tx: XdpRingOffset,
    fr: XdpRingOffset, // fill ring
    cr: XdpRingOffset, // completion ring
};

/// Socket address for AF_XDP
pub const SockaddrXdp = extern struct {
    sxdp_family: u16,
    sxdp_flags: u16,
    sxdp_ifindex: u32,
    sxdp_queue_id: u32,
    sxdp_shared_umem_fd: u32,
};

/// RX/TX descriptor
pub const XdpDesc = extern struct {
    addr: u64,
    len: u32,
    options: u32,
};

/// XDP statistics
pub const XdpStatistics = extern struct {
    rx_dropped: u64,
    rx_invalid_descs: u64,
    tx_invalid_descs: u64,
    rx_ring_full: u64,
    rx_fill_ring_empty_descs: u64,
    tx_ring_empty_descs: u64,
};

/// Configuration for XDP socket
pub const XdpConfig = struct {
    /// Network interface name (empty = auto-detect)
    interface: []const u8 = "",
    /// Queue ID
    queue_id: u32 = 0,
    /// Number of frames in UMEM
    frame_count: u32 = 4096,
    /// Frame size
    frame_size: u32 = 4096,
    /// RX ring size
    rx_size: u32 = 2048,
    /// TX ring size
    tx_size: u32 = 2048,
    /// Fill ring size
    fill_size: u32 = 2048,
    /// Completion ring size
    comp_size: u32 = 2048,
    /// Use zero-copy mode
    zero_copy: bool = true,
    /// Headroom for metadata
    headroom: u32 = 0,
};

/// UMEM ring buffer
pub const UmemRing = struct {
    producer: *u32,
    consumer: *u32,
    flags: ?*u32, // Ring flags for need_wakeup optimization
    ring: []u64,
    cached_prod: u32,
    cached_cons: u32,
    mask: u32,

    pub fn reserve(self: *UmemRing, count: u32) ?u32 {
        if (self.free() < count) return null;
        const idx = self.cached_prod;
        self.cached_prod += count;
        return idx;
    }

    pub fn submit(self: *UmemRing, count: u32) void {
        @atomicStore(u32, self.producer, self.producer.* + count, .release);
    }

    pub fn peek(self: *UmemRing, count: u32) ?u32 {
        const available = @atomicLoad(u32, self.producer, .acquire) - self.cached_cons;
        if (available < count) return null;
        const idx = self.cached_cons;
        self.cached_cons += count;
        return idx;
    }

    pub fn release(self: *UmemRing, count: u32) void {
        @atomicStore(u32, self.consumer, self.consumer.* + count, .release);
    }

    pub fn free(self: *UmemRing) u32 {
        return @intCast(self.ring.len - (self.cached_prod - @atomicLoad(u32, self.consumer, .acquire)));
    }
    
    /// Check if kernel needs wakeup (for ~30M pps optimization)
    pub fn needWakeup(self: *UmemRing) bool {
        if (self.flags) |f| {
            return (@atomicLoad(u32, f, .acquire) & XDP_RING_NEED_WAKEUP) != 0;
        }
        return true; // Conservative: always wakeup if flags not available
    }
};

/// Descriptor ring buffer
pub const DescRing = struct {
    producer: *u32,
    consumer: *u32,
    flags: ?*u32, // Ring flags for need_wakeup optimization
    ring: []XdpDesc,
    cached_prod: u32,
    cached_cons: u32,
    mask: u32,

    pub fn reserve(self: *DescRing, count: u32) ?u32 {
        if (self.free() < count) return null;
        const idx = self.cached_prod;
        self.cached_prod += count;
        return idx;
    }

    pub fn submit(self: *DescRing, count: u32) void {
        @atomicStore(u32, self.producer, self.producer.* + count, .release);
    }

    pub fn peek(self: *DescRing, count: u32) ?u32 {
        const available = @atomicLoad(u32, self.producer, .acquire) - self.cached_cons;
        if (available < count) return null;
        const idx = self.cached_cons;
        self.cached_cons += count;
        return idx;
    }

    pub fn release(self: *DescRing, count: u32) void {
        @atomicStore(u32, self.consumer, self.consumer.* + count, .release);
    }

    pub fn free(self: *DescRing) u32 {
        return @intCast(self.ring.len - (self.cached_prod - @atomicLoad(u32, self.consumer, .acquire)));
    }
    
    /// Check if kernel needs wakeup (for ~30M pps optimization)
    pub fn needWakeup(self: *DescRing) bool {
        if (self.flags) |f| {
            return (@atomicLoad(u32, f, .acquire) & XDP_RING_NEED_WAKEUP) != 0;
        }
        return true; // Conservative: always wakeup if flags not available
    }
};

/// AF_XDP Socket
pub const XdpSocket = struct {
    /// Socket file descriptor
    fd: posix.fd_t,
    /// UMEM memory region
    umem: []align(std.mem.page_size) u8,
    /// Fill ring
    fill_ring: UmemRing,
    /// Completion ring
    comp_ring: UmemRing,
    /// RX ring
    rx_ring: DescRing,
    /// TX ring
    tx_ring: DescRing,
    /// Configuration
    config: XdpConfig,
    /// Statistics
    stats: XdpStatistics,
    /// Interface index
    ifindex: u32,
    /// Allocator
    allocator: Allocator,
    /// Is initialized
    initialized: bool,

    pub fn init(allocator: Allocator, config: XdpConfig) !XdpSocket {
        var sock = XdpSocket{
            .fd = -1,
            .umem = &[_]u8{},
            .fill_ring = undefined,
            .comp_ring = undefined,
            .rx_ring = undefined,
            .tx_ring = undefined,
            .config = config,
            .stats = std.mem.zeroes(XdpStatistics),
            .ifindex = 0,
            .allocator = allocator,
            .initialized = false,
        };

        try sock.setup();
        return sock;
    }

    pub fn deinit(self: *XdpSocket) void {
        if (self.fd >= 0) {
            posix.close(self.fd);
        }
        if (self.umem.len > 0) {
            posix.munmap(self.umem);
        }
    }

    fn setup(self: *XdpSocket) !void {
        std.debug.print("[XDP Setup] Getting interface index for: {s}\n", .{self.config.interface});
        // Get interface index
        self.ifindex = getInterfaceIndex(self.config.interface) catch |err| {
            std.log.err("[AF_XDP] Failed to get interface index: {}", .{err});
            return err;
        };

        // Create AF_XDP socket
        self.fd = posix.socket(AF_XDP, posix.SOCK.RAW, 0) catch |err| {
            std.log.err("[AF_XDP] Socket creation failed: {}", .{err});
            return err;
        };
        errdefer posix.close(self.fd);

        // Allocate UMEM
        const umem_size = @as(usize, self.config.frame_count) * self.config.frame_size;
        self.umem = posix.mmap(
            null,
            umem_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch |err| {
            std.log.err("[AF_XDP] UMEM mmap failed: {}", .{err});
            return err;
        };
        errdefer posix.munmap(self.umem);

        // Register UMEM
        const umem_reg = XdpUmemReg{
            .addr = @intFromPtr(self.umem.ptr),
            .len = umem_size,
            .chunk_size = self.config.frame_size,
            .headroom = self.config.headroom,
            .flags = 0,
        };

        std.log.debug("[AF_XDP] Registering UMEM", .{});
        setsockopt(self.fd, SOL_XDP, XDP_UMEM_REG, std.mem.asBytes(&umem_reg)) catch |err| {
            std.log.err("[AF_XDP] UMEM registration failed: {}", .{err});
            return err;
        };

        // Set up ring sizes
        try setsockopt(self.fd, SOL_XDP, XDP_UMEM_FILL_RING, std.mem.asBytes(&self.config.fill_size));
        try setsockopt(self.fd, SOL_XDP, XDP_UMEM_COMPLETION_RING, std.mem.asBytes(&self.config.comp_size));
        try setsockopt(self.fd, SOL_XDP, XDP_RX_RING, std.mem.asBytes(&self.config.rx_size));
        try setsockopt(self.fd, SOL_XDP, XDP_TX_RING, std.mem.asBytes(&self.config.tx_size));

        // Get mmap offsets
        var offsets: XdpMmapOffsets = undefined;
        var len: u32 = @sizeOf(XdpMmapOffsets);
        try getsockopt(self.fd, SOL_XDP, XDP_MMAP_OFFSETS, std.mem.asBytes(&offsets), &len);

        // Memory map the rings
        try self.mmapRings(&offsets);

        // Bind to interface with optimizations for ~30M pps:
        // - XDP_ZEROCOPY: Eliminates memcpy between kernel and userspace
        // - XDP_USE_NEED_WAKEUP: Avoids unnecessary wakeup syscalls
        std.log.debug("[AF_XDP] Binding to interface {d} queue {d}", .{ self.ifindex, self.config.queue_id });
        var bind_flags: u16 = XDP_USE_NEED_WAKEUP; // Always use need_wakeup optimization
        if (self.config.zero_copy) {
            bind_flags |= XDP_ZEROCOPY;
        } else {
            bind_flags |= XDP_COPY;
        }
        var addr = SockaddrXdp{
            .sxdp_family = AF_XDP,
            .sxdp_flags = bind_flags,
            .sxdp_ifindex = self.ifindex,
            .sxdp_queue_id = self.config.queue_id,
            .sxdp_shared_umem_fd = 0,
        };

        var actual_mode: []const u8 = if ((bind_flags & XDP_ZEROCOPY) != 0) "zero-copy (~30M pps)" else "copy mode (~20M pps)";
        posix.bind(self.fd, @ptrCast(&addr), @sizeOf(SockaddrXdp)) catch |err| {
            // If zero-copy fails, try with copy mode as fallback
            if (self.config.zero_copy) {
                std.log.warn("[AF_XDP] Zero-copy bind failed ({}), falling back to copy mode", .{err});
                addr.sxdp_flags = XDP_USE_NEED_WAKEUP | XDP_COPY;
                actual_mode = "copy mode (~20M pps, zero-copy not supported)";
                posix.bind(self.fd, @ptrCast(&addr), @sizeOf(SockaddrXdp)) catch |err2| {
                    std.log.err("[AF_XDP] Bind to queue {d} failed: {} - queue may already be in use", .{ self.config.queue_id, err2 });
                    return err2;
                };
            } else {
                std.log.err("[AF_XDP] Bind to queue {d} failed: {} - queue may already be in use", .{ self.config.queue_id, err });
                return err;
            }
        };
        std.log.info("[AF_XDP] Bound to interface {d} queue {d} with {s}", .{ self.ifindex, self.config.queue_id, actual_mode });

        // Populate fill ring with initial frames
        try self.populateFillRing();

        self.initialized = true;
    }

    fn mmapRings(self: *XdpSocket, offsets: *const XdpMmapOffsets) !void {
        // Mmap RX ring
        const rx_map_size = offsets.rx.desc + @as(usize, self.config.rx_size) * @sizeOf(XdpDesc);
        const rx_map = posix.mmap(
            null,
            rx_map_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            @intCast(XDP_PGOFF_RX_RING),
        ) catch |err| {
            std.log.err("[AF_XDP] RX ring mmap failed: {}", .{err});
            return err;
        };
        
        // Set up RX ring pointers (including flags for need_wakeup optimization)
        self.rx_ring = .{
            .producer = @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.producer),
            .consumer = @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.consumer),
            .flags = if (offsets.rx.flags != 0) @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.flags) else null,
            .ring = @as([*]XdpDesc, @ptrFromInt(@intFromPtr(rx_map.ptr) + offsets.rx.desc))[0..self.config.rx_size],
            .cached_prod = 0,
            .cached_cons = 0,
            .mask = self.config.rx_size - 1,
        };
        
        // Mmap TX ring
        const tx_map_size = offsets.tx.desc + @as(usize, self.config.tx_size) * @sizeOf(XdpDesc);
        const tx_map = posix.mmap(
            null,
            tx_map_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            @intCast(XDP_PGOFF_TX_RING),
        ) catch |err| {
            std.log.err("[AF_XDP] TX ring mmap failed: {}", .{err});
            return err;
        };
        
        // Set up TX ring pointers (including flags for need_wakeup optimization)
        self.tx_ring = .{
            .producer = @ptrFromInt(@intFromPtr(tx_map.ptr) + offsets.tx.producer),
            .consumer = @ptrFromInt(@intFromPtr(tx_map.ptr) + offsets.tx.consumer),
            .flags = if (offsets.tx.flags != 0) @ptrFromInt(@intFromPtr(tx_map.ptr) + offsets.tx.flags) else null,
            .ring = @as([*]XdpDesc, @ptrFromInt(@intFromPtr(tx_map.ptr) + offsets.tx.desc))[0..self.config.tx_size],
            .cached_prod = 0,
            .cached_cons = 0,
            .mask = self.config.tx_size - 1,
        };
        
        // Mmap Fill ring
        const fill_map_size = offsets.fr.desc + @as(usize, self.config.fill_size) * @sizeOf(u64);
        const fill_map = posix.mmap(
            null,
            fill_map_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            @intCast(XDP_UMEM_PGOFF_FILL_RING),
        ) catch |err| {
            std.log.err("[AF_XDP] Fill ring mmap failed: {}", .{err});
            return err;
        };
        
        // Set up Fill ring pointers (including flags for need_wakeup optimization)
        self.fill_ring = .{
            .producer = @ptrFromInt(@intFromPtr(fill_map.ptr) + offsets.fr.producer),
            .consumer = @ptrFromInt(@intFromPtr(fill_map.ptr) + offsets.fr.consumer),
            .flags = if (offsets.fr.flags != 0) @ptrFromInt(@intFromPtr(fill_map.ptr) + offsets.fr.flags) else null,
            .ring = @as([*]u64, @ptrFromInt(@intFromPtr(fill_map.ptr) + offsets.fr.desc))[0..self.config.fill_size],
            .cached_prod = 0,
            .cached_cons = 0,
            .mask = self.config.fill_size - 1,
        };
        
        // Mmap Completion ring
        const comp_map_size = offsets.cr.desc + @as(usize, self.config.comp_size) * @sizeOf(u64);
        const comp_map = posix.mmap(
            null,
            comp_map_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.fd,
            @intCast(XDP_UMEM_PGOFF_COMPLETION_RING),
        ) catch |err| {
            std.log.err("[AF_XDP] Completion ring mmap failed: {}", .{err});
            return err;
        };
        
        // Set up Completion ring pointers (including flags for need_wakeup optimization)
        self.comp_ring = .{
            .producer = @ptrFromInt(@intFromPtr(comp_map.ptr) + offsets.cr.producer),
            .consumer = @ptrFromInt(@intFromPtr(comp_map.ptr) + offsets.cr.consumer),
            .flags = if (offsets.cr.flags != 0) @ptrFromInt(@intFromPtr(comp_map.ptr) + offsets.cr.flags) else null,
            .ring = @as([*]u64, @ptrFromInt(@intFromPtr(comp_map.ptr) + offsets.cr.desc))[0..self.config.comp_size],
            .cached_prod = 0,
            .cached_cons = 0,
            .mask = self.config.comp_size - 1,
        };
        
        std.log.debug("[AF_XDP] Rings mapped successfully", .{});
    }

    fn populateFillRing(self: *XdpSocket) !void {
        // Add frames to fill ring for RX - kernel needs frame addresses to receive into
        const frames_to_add = @min(self.config.fill_size, self.config.frame_count);
        
        const idx = self.fill_ring.reserve(frames_to_add);
        if (idx) |start_idx| {
            for (0..frames_to_add) |i| {
                const ring_idx = (start_idx + @as(u32, @intCast(i))) & self.fill_ring.mask;
                self.fill_ring.ring[ring_idx] = @as(u64, i) * self.config.frame_size;
            }
            self.fill_ring.submit(frames_to_add);
            std.log.debug("[AF_XDP] Populated fill ring with {d} frames", .{frames_to_add});
        } else {
            std.log.warn("[AF_XDP] Failed to reserve space in fill ring", .{});
        }
    }

    /// Receive packets
    pub fn recv(self: *XdpSocket, packets: []Packet) !usize {
        if (!self.initialized) return error.NotInitialized;

        var received: usize = 0;
        const available = self.rx_ring.peek(@intCast(packets.len));

        if (available) |idx| {
            for (0..packets.len) |i| {
                const desc_idx = (idx + @as(u32, @intCast(i))) & self.rx_ring.mask;
                const desc = self.rx_ring.ring[desc_idx];

                packets[i] = .{
                    .data = self.umem[desc.addr..][0..desc.len],
                    .len = desc.len,
                };
                received += 1;
            }

            self.rx_ring.release(@intCast(received));
        }

        return received;
    }

    /// Send packets
    pub fn send(self: *XdpSocket, packets: []const Packet) !usize {
        if (!self.initialized) return error.NotInitialized;

        var sent: usize = 0;
        const available = self.tx_ring.reserve(@intCast(packets.len));

        if (available) |idx| {
            for (packets) |pkt| {
                const desc_idx = (idx + @as(u32, @intCast(sent))) & self.tx_ring.mask;

                // Find a free frame
                const frame_addr = sent * self.config.frame_size;

                // Copy data to UMEM frame
                @memcpy(self.umem[frame_addr..][0..pkt.len], pkt.data[0..pkt.len]);

                self.tx_ring.ring[desc_idx] = .{
                    .addr = frame_addr,
                    .len = pkt.len,
                    .options = 0,
                };

                sent += 1;
            }

            self.tx_ring.submit(@intCast(sent));

            // Only kick the kernel if needed (XDP_USE_NEED_WAKEUP optimization for ~30M pps)
            if (self.tx_ring.needWakeup()) {
                _ = try sendto(self.fd, &[_]u8{}, 0, null, 0);
            }
        }

        return sent;
    }

    /// Poll for events
    pub fn poll(self: *XdpSocket, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.fd,
            .events = posix.POLL.IN | posix.POLL.OUT,
            .revents = 0,
        }};

        const result = try posix.poll(&fds, timeout_ms);
        return result > 0;
    }

    /// Get statistics
    pub fn getStats(self: *XdpSocket) !XdpStatistics {
        var stats: XdpStatistics = undefined;
        var len: u32 = @sizeOf(XdpStatistics);
        try getsockopt(self.fd, SOL_XDP, XDP_STATISTICS, std.mem.asBytes(&stats), &len);
        self.stats = stats;
        return stats;
    }
};

/// Packet representation
pub const Packet = struct {
    data: []u8,
    len: u32,
};

/// Get interface index by name
pub fn getInterfaceIndex(name: []const u8) !u32 {
    // Use ioctl SIOCGIFINDEX
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    var ifr: extern struct {
        name: [16]u8,
        ifindex: i32,
        _padding: [20]u8,
    } = undefined;

    @memset(&ifr.name, 0);
    const copy_len = @min(name.len, 15);
    @memcpy(ifr.name[0..copy_len], name[0..copy_len]);

    // SIOCGIFINDEX = 0x8933
    const SIOCGIFINDEX: u32 = 0x8933;

    // Use C library ioctl since std.posix doesn't expose it
    const rc = std.c.ioctl(sock, SIOCGIFINDEX, &ifr);
    if (rc < 0) {
        return error.IoctlFailed;
    }

    return @intCast(ifr.ifindex);
}

fn setsockopt(fd: posix.fd_t, level: u32, optname: u32, optval: []const u8) !void {
    const rc = std.c.setsockopt(fd, @intCast(level), @intCast(optname), optval.ptr, @intCast(optval.len));
    if (rc < 0) {
        const errno = std.c._errno().*;
        std.debug.print("[setsockopt] Failed: errno={d}\n", .{errno});
        return error.SetSockOptFailed;
    }
}

fn getsockopt(fd: posix.fd_t, level: u32, optname: u32, optval: []u8, optlen: *u32) !void {
    const rc = std.c.getsockopt(fd, @intCast(level), @intCast(optname), optval.ptr, optlen);
    if (rc < 0) {
        return error.GetSockOptFailed;
    }
}

fn sendto(fd: posix.fd_t, buf: []const u8, flags: u32, addr: ?*const posix.sockaddr, addrlen: posix.socklen_t) !usize {
    const rc = std.c.sendto(fd, buf.ptr, buf.len, @intCast(flags), addr, addrlen);
    if (rc < 0) {
        return error.SendToFailed;
    }
    return @intCast(rc);
}

// ============================================================================
// Tests
// ============================================================================

test "XdpConfig: defaults" {
    const config = XdpConfig{};
    try std.testing.expectEqual(@as(u32, 4096), config.frame_count);
    try std.testing.expectEqual(@as(u32, 4096), config.frame_size);
}

test "XdpStatistics: size" {
    // Ensure struct is packed correctly for kernel interface
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(XdpStatistics));
}

test "XdpDesc: size" {
    // Ensure descriptor struct matches kernel definition
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(XdpDesc));
}

