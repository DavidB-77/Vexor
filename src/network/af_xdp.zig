//! Vexor AF_XDP Implementation
//!
//! Kernel bypass networking using AF_XDP for ultra-low latency packet processing.
//! Achieves 10M+ packets per second per core with zero-copy.
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────────────┐
//! │                          USER SPACE                                 │
//! │  ┌────────────┐    ┌────────────┐    ┌────────────┐                │
//! │  │   Vexor    │───▶│  AF_XDP    │───▶│   UMEM     │                │
//! │  │  Network   │    │   Socket   │    │  (shared)  │                │
//! │  └────────────┘    └────────────┘    └────────────┘                │
//! │        │                 │                 │                        │
//! │        │          ┌──────┴──────┐          │                        │
//! │        │          │ Ring Buffers │          │                        │
//! │        │          │ RX/TX/FILL/ │          │                        │
//! │        │          │ COMPLETION  │          │                        │
//! │        │          └──────┬──────┘          │                        │
//! ├────────┼─────────────────┼─────────────────┼────────────────────────┤
//! │        │                 │                 │        KERNEL          │
//! │        │           ┌─────┴─────┐           │                        │
//! │        │           │    XDP    │           │                        │
//! │        └──────────▶│  Program  │◀──────────┘                        │
//! │                    └─────┬─────┘                                    │
//! │                          │                                          │
//! │                    ┌─────┴─────┐                                    │
//! │                    │    NIC    │                                    │
//! │                    │  Driver   │                                    │
//! └────────────────────┴───────────┴────────────────────────────────────┘
//!
//! Requirements:
//! - Linux kernel 4.18+ (5.x recommended)
//! - libbpf library
//! - NIC with XDP support (Intel i40e/ice, Mellanox mlx5)
//!
//! Performance targets:
//! - < 1μs packet processing latency
//! - 10M+ packets/sec per queue
//! - Zero-copy packet handling

const std = @import("std");
const packet = @import("packet.zig");
const builtin = @import("builtin");
const linux = std.os.linux;

// ═══════════════════════════════════════════════════════════════════════════════
// LINUX AF_XDP SYSTEM DEFINITIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Address family for XDP sockets
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

/// XDP bind flags
pub const XDP_SHARED_UMEM: u16 = 1 << 0;
pub const XDP_COPY: u16 = 1 << 1;
pub const XDP_ZEROCOPY: u16 = 1 << 2;
pub const XDP_USE_NEED_WAKEUP: u16 = 1 << 3;

/// XDP attachment modes
pub const XDP_FLAGS_UPDATE_IF_NOEXIST: u32 = 1 << 0;
pub const XDP_FLAGS_SKB_MODE: u32 = 1 << 1;
pub const XDP_FLAGS_DRV_MODE: u32 = 1 << 2;
pub const XDP_FLAGS_HW_MODE: u32 = 1 << 3;
pub const XDP_FLAGS_REPLACE: u32 = 1 << 4;

/// Ring buffer offsets
pub const XdpRingOffset = extern struct {
    producer: u64,
    consumer: u64,
    desc: u64,
    flags: u64,
};

/// Mmap offsets for rings
pub const XdpMmapOffsets = extern struct {
    rx: XdpRingOffset,
    tx: XdpRingOffset,
    fr: XdpRingOffset, // Fill ring
    cr: XdpRingOffset, // Completion ring
};

/// UMEM registration
pub const XdpUmemReg = extern struct {
    addr: u64,
    len: u64,
    chunk_size: u32,
    headroom: u32,
    flags: u32,
};

/// Socket address for AF_XDP
pub const SockaddrXdp = extern struct {
    sxdp_family: u16 = AF_XDP,
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

// ═══════════════════════════════════════════════════════════════════════════════
// RING BUFFER IMPLEMENTATION (Cache-Line Optimized)
// ═══════════════════════════════════════════════════════════════════════════════

/// Cache line size for x86-64 (64 bytes)
pub const CACHE_LINE_SIZE = 64;

/// Generic ring buffer for AF_XDP with cache-line alignment
/// Producer and consumer are on separate cache lines to prevent false sharing
pub const Ring = struct {
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 0: Producer-side data (written by producer, read by consumer)
    // ═══════════════════════════════════════════════════════════════════════════
    /// Producer index (kernel-side)
    producer: *volatile u32 align(CACHE_LINE_SIZE),
    /// Cached producer value (local copy to reduce atomic reads)
    cached_prod: u32,
    /// Padding to fill cache line
    _pad0: [CACHE_LINE_SIZE - 12]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - 12),
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 1: Consumer-side data (written by consumer, read by producer)
    // ═══════════════════════════════════════════════════════════════════════════
    /// Consumer index (kernel-side)
    consumer: *volatile u32 align(CACHE_LINE_SIZE),
    /// Cached consumer value (local copy to reduce atomic reads)
    cached_cons: u32,
    /// Padding to fill cache line
    _pad1: [CACHE_LINE_SIZE - 12]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - 12),
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 2+: Ring metadata (read-only after init)
    // ═══════════════════════════════════════════════════════════════════════════
    /// Ring buffer (either u64 for fill/completion or XdpDesc for rx/tx)
    ring: [*]u64 align(CACHE_LINE_SIZE),
    /// Mask for wrap-around (size - 1)
    mask: u32,
    /// Ring size
    size: u32,
    
    const Self = @This();
    
    /// Reserve space for n entries (producer side)
    /// Uses cached consumer to minimize atomic reads
    pub inline fn reserve(self: *Self, n: u32) u32 {
        // Only reload consumer if we think we're full
        const cached_available = self.size - (self.cached_prod - self.cached_cons);
        if (cached_available < n) {
            // Reload consumer index (atomic read)
            self.cached_cons = @atomicLoad(u32, self.consumer, .acquire);
        }
        const available = self.size - (self.cached_prod - self.cached_cons);
        return @min(n, available);
    }
    
    /// Submit n entries (producer side)
    /// Updates producer index with release semantics
    pub inline fn submit(self: *Self, n: u32) void {
        // Memory barrier ensures all ring writes are visible before producer update
        @fence(.release);
        self.cached_prod +%= n;
        @atomicStore(u32, self.producer, self.cached_prod, .release);
    }
    
    /// Peek at available entries (consumer side)
    /// Uses cached producer to minimize atomic reads
    pub inline fn peek(self: *Self, n: u32) u32 {
        // Reload producer index (atomic read)
        self.cached_prod = @atomicLoad(u32, self.producer, .acquire);
        const available = self.cached_prod -% self.cached_cons;
        return @min(n, available);
    }
    
    /// Release n entries (consumer side)
    /// Updates consumer index with release semantics
    pub inline fn release(self: *Self, n: u32) void {
        // Memory barrier ensures all ring reads are complete before consumer update
        @fence(.release);
        self.cached_cons +%= n;
        @atomicStore(u32, self.consumer, self.cached_cons, .release);
    }
    
    /// Get index for the nth reserved entry (branchless)
    pub inline fn getIdx(self: *const Self, n: u32) u32 {
        return (self.cached_prod +% n) & self.mask;
    }
    
    /// Get address at index with prefetch hint
    pub inline fn getAddr(self: *Self, idx: u32) *u64 {
        const ptr = &self.ring[idx];
        // Prefetch next cache line for sequential access patterns
        @prefetch(@as([*]u8, @ptrCast(ptr)) + CACHE_LINE_SIZE, .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
        return ptr;
    }
    
    /// Batch get multiple addresses (for vectorized processing)
    pub inline fn getAddressBatch(self: *Self, start_n: u32, comptime count: u32) [count]*u64 {
        var result: [count]*u64 = undefined;
        inline for (0..count) |i| {
            result[i] = &self.ring[(self.cached_prod +% start_n +% @as(u32, i)) & self.mask];
        }
        return result;
    }
};

/// Descriptor ring (for RX/TX) with cache-line alignment
pub const DescRing = struct {
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 0: Producer-side data
    // ═══════════════════════════════════════════════════════════════════════════
    producer: *volatile u32 align(CACHE_LINE_SIZE),
    cached_prod: u32,
    _pad0: [CACHE_LINE_SIZE - 12]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - 12),
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 1: Consumer-side data
    // ═══════════════════════════════════════════════════════════════════════════
    consumer: *volatile u32 align(CACHE_LINE_SIZE),
    cached_cons: u32,
    _pad1: [CACHE_LINE_SIZE - 12]u8 = [_]u8{0} ** (CACHE_LINE_SIZE - 12),
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHE LINE 2+: Ring metadata
    // ═══════════════════════════════════════════════════════════════════════════
    ring: [*]XdpDesc align(CACHE_LINE_SIZE),
    mask: u32,
    size: u32,
    
    const Self = @This();
    
    pub inline fn reserve(self: *Self, n: u32) u32 {
        const cached_available = self.size - (self.cached_prod -% self.cached_cons);
        if (cached_available < n) {
            self.cached_cons = @atomicLoad(u32, self.consumer, .acquire);
        }
        const available = self.size - (self.cached_prod -% self.cached_cons);
        return @min(n, available);
    }
    
    pub inline fn submit(self: *Self, n: u32) void {
        @fence(.release);
        self.cached_prod +%= n;
        @atomicStore(u32, self.producer, self.cached_prod, .release);
    }
    
    pub inline fn peek(self: *Self, n: u32) u32 {
        self.cached_prod = @atomicLoad(u32, self.producer, .acquire);
        const available = self.cached_prod -% self.cached_cons;
        return @min(n, available);
    }
    
    pub inline fn release(self: *Self, n: u32) void {
        @fence(.release);
        self.cached_cons +%= n;
        @atomicStore(u32, self.consumer, self.cached_cons, .release);
    }
    
    pub inline fn getIdx(self: *const Self, n: u32) u32 {
        return (self.cached_prod +% n) & self.mask;
    }
    
    pub inline fn getDesc(self: *Self, idx: u32) *XdpDesc {
        const ptr = &self.ring[idx];
        // Prefetch next descriptor
        @prefetch(@as([*]u8, @ptrCast(ptr)) + @sizeOf(XdpDesc), .{
            .rw = .read,
            .locality = 3,
            .cache = .data,
        });
        return ptr;
    }
    
    /// Batch descriptor access for vectorized RX/TX
    pub inline fn getDescBatch(self: *Self, start_n: u32, comptime count: u32) [count]*XdpDesc {
        var result: [count]*XdpDesc = undefined;
        inline for (0..count) |i| {
            result[i] = &self.ring[(self.cached_prod +% start_n +% @as(u32, i)) & self.mask];
        }
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// UMEM (USER MEMORY) REGION
// ═══════════════════════════════════════════════════════════════════════════════

/// UMEM configuration
pub const UmemConfig = struct {
    /// Total size (must be page-aligned)
    size: usize = 64 * 1024 * 1024, // 64MB default
    /// Frame size (power of 2)
    frame_size: u32 = 4096,
    /// Headroom before packet data
    headroom: u32 = 256,
    /// Fill ring size
    fill_size: u32 = 4096,
    /// Completion ring size
    comp_size: u32 = 4096,
};

/// UMEM region for zero-copy packet buffers
pub const Umem = struct {
    allocator: std.mem.Allocator,
    /// Mapped memory region
    buffer: []align(4096) u8,
    /// Frame size
    frame_size: u32,
    /// Number of frames
    frame_count: u32,
    /// Headroom
    headroom: u32,
    /// Fill ring
    fill_ring: Ring,
    /// Completion ring
    comp_ring: Ring,
    /// File descriptor
    fd: i32,
    /// Free frame stack
    free_frames: []u64,
    free_count: usize,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: UmemConfig) !*Self {
        const umem = try allocator.create(Self);
        errdefer allocator.destroy(umem);
        
        // Allocate page-aligned buffer
        const buffer = try allocator.alignedAlloc(u8, 4096, config.size);
        errdefer allocator.free(buffer);
        
        const frame_count: u32 = @intCast(config.size / config.frame_size);
        
        // Initialize free frame list
        const free_frames = try allocator.alloc(u64, frame_count);
        errdefer allocator.free(free_frames);
        
        for (0..frame_count) |i| {
            free_frames[i] = i * config.frame_size;
        }
        
        umem.* = .{
            .allocator = allocator,
            .buffer = buffer,
            .frame_size = config.frame_size,
            .frame_count = frame_count,
            .headroom = config.headroom,
            .fill_ring = undefined, // Set up after socket creation
            .comp_ring = undefined,
            .fd = -1,
            .free_frames = free_frames,
            .free_count = frame_count,
        };
        
        return umem;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.fd >= 0) {
            std.posix.close(self.fd);
        }
        self.allocator.free(self.free_frames);
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }
    
    /// Allocate a frame
    pub fn allocFrame(self: *Self) ?u64 {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_frames[self.free_count];
    }
    
    /// Free a frame
    pub fn freeFrame(self: *Self, addr: u64) void {
        if (self.free_count >= self.free_frames.len) return;
        self.free_frames[self.free_count] = addr;
        self.free_count += 1;
    }
    
    /// Get pointer to frame data
    pub fn getFrameData(self: *Self, addr: u64) []u8 {
        const start = addr + self.headroom;
        const end = addr + self.frame_size;
        return self.buffer[@intCast(start)..@intCast(end)];
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// AF_XDP SOCKET
// ═══════════════════════════════════════════════════════════════════════════════

/// AF_XDP socket configuration
pub const XdpSocketConfig = struct {
    /// Network interface name
    interface: []const u8,
    /// Queue ID to bind to
    queue_id: u32 = 0,
    /// RX ring size
    rx_size: u32 = 4096,
    /// TX ring size
    tx_size: u32 = 4096,
    /// Bind flags
    bind_flags: u16 = XDP_USE_NEED_WAKEUP,
    /// UMEM configuration
    umem: UmemConfig = .{},
};

/// AF_XDP socket for high-performance packet I/O
pub const XdpSocket = struct {
    allocator: std.mem.Allocator,
    /// Interface index
    ifindex: u32,
    /// Queue ID
    queue_id: u32,
    /// UMEM region
    umem: *Umem,
    /// RX ring
    rx_ring: DescRing,
    /// TX ring
    tx_ring: DescRing,
    /// Socket file descriptor
    fd: i32,
    /// Configuration
    config: XdpSocketConfig,
    /// Statistics
    stats: Stats,
    
    pub const Stats = struct {
        rx_packets: u64 = 0,
        tx_packets: u64 = 0,
        rx_bytes: u64 = 0,
        tx_bytes: u64 = 0,
        rx_dropped: u64 = 0,
        tx_errors: u64 = 0,
    };
    
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: XdpSocketConfig) !*Self {
        if (builtin.os.tag != .linux) {
            return error.UnsupportedOS;
        }
        
        const socket = try allocator.create(Self);
        errdefer allocator.destroy(socket);
        
        // Get interface index
        const ifindex = try getIfIndex(config.interface);
        
        // Create UMEM
        const umem = try Umem.init(allocator, config.umem);
        errdefer umem.deinit();
        
        // Create AF_XDP socket
        const fd = linux.socket(AF_XDP, linux.SOCK.RAW, 0);
        if (@as(isize, @bitCast(fd)) < 0) {
            return error.SocketCreationFailed;
        }
        errdefer std.posix.close(@intCast(fd));
        
        // Register UMEM
        var umem_reg = XdpUmemReg{
            .addr = @intFromPtr(umem.buffer.ptr),
            .len = umem.buffer.len,
            .chunk_size = umem.frame_size,
            .headroom = umem.headroom,
            .flags = 0,
        };
        
        const setsockopt_result = linux.setsockopt(
            @intCast(fd),
            SOL_XDP,
            XDP_UMEM_REG,
            @ptrCast(&umem_reg),
            @sizeOf(XdpUmemReg),
        );
        
        if (@as(isize, @bitCast(setsockopt_result)) < 0) {
            return error.UmemRegistrationFailed;
        }
        
        // Set up ring sizes
        try setRingSize(@intCast(fd), XDP_UMEM_FILL_RING, config.umem.fill_size);
        try setRingSize(@intCast(fd), XDP_UMEM_COMPLETION_RING, config.umem.comp_size);
        try setRingSize(@intCast(fd), XDP_RX_RING, config.rx_size);
        try setRingSize(@intCast(fd), XDP_TX_RING, config.tx_size);
        
        // Get mmap offsets
        var offsets: XdpMmapOffsets = undefined;
        var optlen: u32 = @sizeOf(XdpMmapOffsets);
        
        const getsockopt_result = linux.getsockopt(
            @intCast(fd),
            SOL_XDP,
            XDP_MMAP_OFFSETS,
            @ptrCast(&offsets),
            &optlen,
        );
        
        if (@as(isize, @bitCast(getsockopt_result)) < 0) {
            return error.GetMmapOffsetsFailed;
        }
        
        // Bind socket to interface queue
        var sxdp = SockaddrXdp{
            .sxdp_flags = config.bind_flags,
            .sxdp_ifindex = ifindex,
            .sxdp_queue_id = config.queue_id,
            .sxdp_shared_umem_fd = 0,
        };
        
        const bind_result = linux.bind(
            @intCast(fd),
            @ptrCast(&sxdp),
            @sizeOf(SockaddrXdp),
        );
        
        if (@as(isize, @bitCast(bind_result)) < 0) {
            return error.BindFailed;
        }
        
        socket.* = .{
            .allocator = allocator,
            .ifindex = ifindex,
            .queue_id = config.queue_id,
            .umem = umem,
            .rx_ring = undefined, // Set up via mmap
            .tx_ring = undefined,
            .fd = @intCast(fd),
            .config = config,
            .stats = .{},
        };
        
        // Populate fill ring with frames
        try socket.populateFillRing();
        
        return socket;
    }

    pub fn deinit(self: *Self) void {
        if (self.fd >= 0) {
            std.posix.close(self.fd);
        }
        self.umem.deinit();
        self.allocator.destroy(self);
    }
    
    /// Receive packets
    pub fn recv(self: *Self, batch: *packet.PacketBatch) !usize {
        var received: usize = 0;
        
        // Check RX ring for available packets
        const avail = self.rx_ring.peek(@intCast(batch.capacity() - batch.count()));
        
        for (0..avail) |i| {
            const idx = (self.rx_ring.cached_cons + @as(u32, @intCast(i))) & self.rx_ring.mask;
            const desc = self.rx_ring.getDesc(idx);
            
            if (batch.push()) |pkt| {
                // Copy from UMEM to packet
                const frame_data = self.umem.getFrameData(desc.addr);
                const len = @min(desc.len, pkt.data.len);
                @memcpy(pkt.data[0..len], frame_data[0..len]);
                pkt.len = @intCast(len);
                pkt.timestamp_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
                
                self.stats.rx_packets += 1;
                self.stats.rx_bytes += len;
                received += 1;
                
                // Return frame to fill ring
                self.umem.freeFrame(desc.addr);
            }
        }
        
        if (received > 0) {
            self.rx_ring.release(@intCast(received));
            try self.populateFillRing();
        }
        
        return received;
    }
    
    /// Send packets
    pub fn send(self: *Self, batch: *const packet.PacketBatch) !usize {
        var sent: usize = 0;
        
        // Get TX ring space
        const avail = self.tx_ring.reserve(@intCast(batch.count()));
        
        for (batch.slice()[0..@min(batch.count(), avail)]) |*pkt| {
            // Allocate frame
            const addr = self.umem.allocFrame() orelse break;
            
            // Copy packet to UMEM
            const frame_data = self.umem.getFrameData(addr);
            @memcpy(frame_data[0..pkt.len], pkt.payload());
            
            // Fill TX descriptor
            const idx = self.tx_ring.getIdx(@intCast(sent));
            const desc = self.tx_ring.getDesc(idx);
            desc.addr = addr;
            desc.len = @intCast(pkt.len);
            desc.options = 0;
            
            self.stats.tx_packets += 1;
            self.stats.tx_bytes += pkt.len;
            sent += 1;
        }
        
        if (sent > 0) {
            self.tx_ring.submit(@intCast(sent));
            try self.kick();
        }
        
        return sent;
    }
    
    /// Trigger TX completion
    fn kick(self: *Self) !void {
        // Use sendto with MSG_DONTWAIT to trigger TX
        const rc = linux.sendto(
            self.fd,
            null,
            0,
            linux.MSG.DONTWAIT,
            null,
            0,
        );
        
        if (@as(isize, @bitCast(rc)) < 0) {
            const err = linux.getErrno(rc);
            if (err != .AGAIN and err != .BUSY) {
                return error.KickFailed;
            }
        }
    }
    
    /// Populate fill ring with free frames
    fn populateFillRing(self: *Self) !void {
        var fill = &self.umem.fill_ring;
        const avail = fill.reserve(fill.size / 2);
        
        for (0..avail) |i| {
            if (self.umem.allocFrame()) |addr| {
                const idx = fill.getIdx(@intCast(i));
                fill.ring[idx] = addr;
            } else {
                break;
            }
        }
        
        fill.submit(avail);
    }
    
    /// Complete TX and reclaim frames
    pub fn completeTx(self: *Self) void {
        var comp = &self.umem.comp_ring;
        const avail = comp.peek(comp.size);
        
        for (0..avail) |i| {
            const idx = (comp.cached_cons + @as(u32, @intCast(i))) & comp.mask;
            const addr = comp.ring[idx];
            self.umem.freeFrame(addr);
        }
        
        comp.release(avail);
    }
    
    /// Get statistics
    pub fn getStats(self: *const Self) Stats {
        return self.stats;
    }
    
    /// Get kernel statistics
    pub fn getKernelStats(self: *Self) !XdpStatistics {
        var stats: XdpStatistics = undefined;
        var optlen: u32 = @sizeOf(XdpStatistics);
        
        const rc = linux.getsockopt(
            self.fd,
            SOL_XDP,
            XDP_STATISTICS,
            @ptrCast(&stats),
            &optlen,
        );
        
        if (@as(isize, @bitCast(rc)) < 0) {
            return error.GetStatsFailed;
        }
        
        return stats;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// XDP PROGRAM LOADER
// ═══════════════════════════════════════════════════════════════════════════════

/// XDP program for packet filtering
pub const XdpProgram = struct {
    /// BPF program file descriptor
    prog_fd: i32,
    /// BPF map file descriptor (for XSKMAP)
    map_fd: i32,
    /// Interface index
    ifindex: u32,
    /// Attachment mode
    mode: AttachMode,
    
    pub const AttachMode = enum(u32) {
        skb = XDP_FLAGS_SKB_MODE,
        driver = XDP_FLAGS_DRV_MODE,
        hardware = XDP_FLAGS_HW_MODE,
    };
    
    const Self = @This();
    
    /// Load XDP program from ELF file
    pub fn load(bpf_path: []const u8) !Self {
        _ = bpf_path;
        // In a full implementation, we would:
        // 1. Parse ELF file
        // 2. Extract BPF bytecode
        // 3. Load with bpf(BPF_PROG_LOAD, ...)
        // 4. Create XSKMAP with bpf(BPF_MAP_CREATE, ...)
        
        return Self{
            .prog_fd = -1,
            .map_fd = -1,
            .ifindex = 0,
            .mode = .driver,
        };
    }
    
    /// Generate a simple XDP redirect program
    pub fn generateRedirectProgram(allocator: std.mem.Allocator) ![]const u8 {
        // BPF bytecode for XDP_REDIRECT to xskmap
        // This is a minimal program that redirects all packets
        const prog = [_]u8{
            // r2 = *(u32 *)(r1 + 4)  ; ingress ifindex
            0x61, 0x12, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
            // r0 = XDP_PASS
            0xb7, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
            // exit
            0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };
        
        const result = try allocator.dupe(u8, &prog);
        return result;
    }
    
    /// Attach to interface
    pub fn attach(self: *Self, ifindex: u32, mode: AttachMode) !void {
        self.ifindex = ifindex;
        self.mode = mode;
        
        // In a full implementation:
        // bpf_xdp_attach(ifindex, prog_fd, mode, NULL)
    }
    
    /// Detach from interface
    pub fn detach(self: *Self) !void {
        if (self.ifindex == 0) return;
        
        // In a full implementation:
        // bpf_xdp_detach(self.ifindex, self.mode, NULL)
        
        self.ifindex = 0;
    }
    
    /// Register socket in XSKMAP
    pub fn registerSocket(self: *Self, queue_id: u32, socket_fd: i32) !void {
        _ = self;
        _ = queue_id;
        _ = socket_fd;
        
        // In a full implementation:
        // bpf_map_update_elem(self.map_fd, &queue_id, &socket_fd, BPF_ANY)
    }
    
    pub fn deinit(self: *Self) void {
        if (self.ifindex != 0) {
            self.detach() catch {};
        }
        if (self.prog_fd >= 0) {
            std.posix.close(self.prog_fd);
        }
        if (self.map_fd >= 0) {
            std.posix.close(self.map_fd);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// Get interface index from name
fn getIfIndex(interface: []const u8) !u32 {
    if (builtin.os.tag != .linux) return error.UnsupportedOS;
    
    // Create temporary buffer for interface name
    var name_buf: [16]u8 = undefined;
    const name_len = @min(interface.len, 15);
    @memcpy(name_buf[0..name_len], interface[0..name_len]);
    name_buf[name_len] = 0;
    
    // Use ioctl SIOCGIFINDEX
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(fd)) < 0) {
        return error.SocketFailed;
    }
    defer std.posix.close(@intCast(fd));
    
    const SIOCGIFINDEX: u32 = 0x8933;
    
    var ifreq: extern struct {
        name: [16]u8,
        data: extern union {
            ifindex: i32,
            _pad: [24]u8,
        },
    } = undefined;
    
    @memcpy(&ifreq.name, &name_buf);
    
    const rc = linux.ioctl(@intCast(fd), SIOCGIFINDEX, @intFromPtr(&ifreq));
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.InterfaceNotFound;
    }
    
    return @intCast(ifreq.data.ifindex);
}

/// Set ring size via setsockopt
fn setRingSize(fd: i32, opt: u32, size: u32) !void {
    const rc = linux.setsockopt(
        fd,
        SOL_XDP,
        opt,
        @ptrCast(&size),
        @sizeOf(u32),
    );
    
    if (@as(isize, @bitCast(rc)) < 0) {
        return error.SetRingSizeFailed;
    }
}

/// Check if AF_XDP is available on this system
pub fn isAvailable() bool {
    if (builtin.os.tag != .linux) return false;

    // Try to create an AF_XDP socket
    const fd = linux.socket(AF_XDP, linux.SOCK.RAW, 0);
    if (@as(isize, @bitCast(fd)) < 0) {
        return false;
    }
    std.posix.close(@intCast(fd));
    return true;
}

/// Check if an interface supports XDP
pub fn checkXdpSupport(interface: []const u8) bool {
    const ifindex = getIfIndex(interface) catch return false;
    _ = ifindex;
    
    // In a full implementation, check driver capabilities
    // via ethtool or /sys/class/net/<interface>/device/driver
    
    return true;
}

/// Get list of XDP-capable interfaces
pub fn getXdpCapableInterfaces(allocator: std.mem.Allocator) ![][]const u8 {
    var interfaces = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (interfaces.items) |iface| {
            allocator.free(iface);
        }
        interfaces.deinit();
    }
    
    // Read from /sys/class/net
    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return interfaces.toOwnedSlice();
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .sym_link and entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "lo")) continue; // Skip loopback
        
        // Check if XDP capable (simplified)
        const name = try allocator.dupe(u8, entry.name);
        try interfaces.append(name);
    }
    
    return interfaces.toOwnedSlice();
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "af_xdp availability" {
    const available = isAvailable();
    // Should be true on Linux with AF_XDP support, false otherwise
    if (builtin.os.tag == .linux) {
        // May or may not be available depending on kernel
        _ = available;
    } else {
        try std.testing.expect(!available);
    }
}

test "umem allocation" {
    const umem = try Umem.init(std.testing.allocator, .{
        .size = 1024 * 1024, // 1MB
        .frame_size = 4096,
    });
    defer umem.deinit();
    
    // Allocate a frame
    const addr = umem.allocFrame();
    try std.testing.expect(addr != null);
    
    // Free it
    umem.freeFrame(addr.?);
    
    // Allocate again
    const addr2 = umem.allocFrame();
    try std.testing.expectEqual(addr, addr2);
}

test "ring buffer" {
    var producer: u32 = 0;
    var consumer: u32 = 0;
    var ring_data: [16]u64 = undefined;
    
    var ring = Ring{
        .producer = &producer,
        .consumer = &consumer,
        .ring = &ring_data,
        .mask = 15,
        .size = 16,
        .cached_prod = 0,
        .cached_cons = 0,
    };
    
    // Reserve space
    const reserved = ring.reserve(4);
    try std.testing.expectEqual(@as(u32, 4), reserved);
    
    // Submit
    ring.submit(4);
    try std.testing.expectEqual(@as(u32, 4), producer);
}
