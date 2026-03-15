//! Buffer Pool for Account Loading
//!
//! High-performance memory manager that replaces mmap for account loading.
//! Based on Sig's approach which achieved 80% memory reduction.
//!
//! Key features:
//!   - Fixed-size frames (512 bytes covers 95% of accounts)
//!   - Explicit memory control (no kernel page cache)
//!   - Atomic ref counting for thread safety
//!   - FIFO eviction for predictable behavior
//!   - Support for O_DIRECT I/O
//!
//! Why not mmap?
//!   - High memory usage from page cache readahead
//!   - No control over eviction
//!   - Hidden blocking in page faults
//!   - TLB shootdowns affecting all threads
//!   - Can't saturate modern NVMe (10+ GB/s)

const std = @import("std");
const Atomic = std.atomic.Value;
const posix = std.posix;

/// Frame metadata
pub const FrameMeta = struct {
    /// Reference count
    ref_count: Atomic(u32),
    
    /// Valid data flag
    valid: Atomic(bool),
    
    /// File ID this frame belongs to
    file_id: u32,
    
    /// Offset within file
    offset: u64,
    
    /// Actual data size (may be less than frame size)
    data_size: u32,
    
    /// Last access timestamp (for LRU if needed)
    last_access: Atomic(i64),
    
    pub fn init() FrameMeta {
        return .{
            .ref_count = Atomic(u32).init(0),
            .valid = Atomic(bool).init(false),
            .file_id = 0,
            .offset = 0,
            .data_size = 0,
            .last_access = Atomic(i64).init(0),
        };
    }
    
    pub fn acquire(self: *FrameMeta) void {
        _ = self.ref_count.fetchAdd(1, .acquire);
        self.last_access.store(std.time.milliTimestamp(), .release);
    }
    
    pub fn release(self: *FrameMeta) void {
        _ = self.ref_count.fetchSub(1, .release);
    }
    
    pub fn isInUse(self: *const FrameMeta) bool {
        return self.ref_count.load(.acquire) > 0;
    }
};

/// Buffer pool configuration
pub const BufferPoolConfig = struct {
    /// Number of frames
    num_frames: usize = 65536,
    
    /// Size of each frame (512 bytes covers 95% of accounts)
    frame_size: usize = 512,
    
    /// Use O_DIRECT for disk I/O
    use_direct_io: bool = true,
    
    /// Pre-fault pages on init
    prefault: bool = true,
    
    /// Enable huge pages if available
    huge_pages: bool = true,
};

/// Buffer pool
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    config: BufferPoolConfig,
    
    /// Frame data buffer (aligned for O_DIRECT)
    data: []align(4096) u8,
    
    /// Frame metadata
    meta: []FrameMeta,
    
    /// Free list (FIFO queue of frame indices)
    free_list: []u32,
    free_head: Atomic(u32),
    free_tail: Atomic(u32),
    
    /// Statistics
    stats: BufferPoolStats,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: BufferPoolConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        const total_size = config.num_frames * config.frame_size;
        
        // Allocate aligned data buffer
        self.data = try allocator.alignedAlloc(u8, 4096, total_size);
        errdefer allocator.free(self.data);
        
        // Pre-fault pages
        if (config.prefault) {
            @memset(self.data, 0);
        }
        
        // Allocate metadata
        self.meta = try allocator.alloc(FrameMeta, config.num_frames);
        errdefer allocator.free(self.meta);
        
        for (self.meta) |*m| {
            m.* = FrameMeta.init();
        }
        
        // Initialize free list
        self.free_list = try allocator.alloc(u32, config.num_frames);
        errdefer allocator.free(self.free_list);
        
        for (self.free_list, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }
        
        self.allocator = allocator;
        self.config = config;
        self.free_head = Atomic(u32).init(0);
        self.free_tail = Atomic(u32).init(@intCast(config.num_frames));
        self.stats = BufferPoolStats{};
        
        std.debug.print("[BufferPool] Initialized: {d} frames x {d} bytes = {d} MB\n", .{
            config.num_frames,
            config.frame_size,
            total_size / (1024 * 1024),
        });
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.free_list);
        self.allocator.free(self.meta);
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
    
    /// Allocate a frame
    pub fn allocFrame(self: *Self) ?u32 {
        const head = self.free_head.load(.acquire);
        const tail = self.free_tail.load(.acquire);
        
        if (head >= tail) {
            // Pool exhausted, try to evict
            _ = self.stats.alloc_failures.fetchAdd(1, .release);
            return self.evictFrame();
        }
        
        // Try to claim the head
        if (self.free_head.cmpxchgStrong(head, head + 1, .acq_rel, .acquire)) |_| {
            // Another thread got it, retry
            return self.allocFrame();
        }
        
        const frame_idx = self.free_list[head % self.config.num_frames];
        self.meta[frame_idx].acquire();
        _ = self.stats.allocs.fetchAdd(1, .release);
        
        return frame_idx;
    }
    
    /// Release a frame back to pool
    pub fn releaseFrame(self: *Self, frame_idx: u32) void {
        self.meta[frame_idx].release();
        
        if (!self.meta[frame_idx].isInUse()) {
            // Add back to free list
            const tail = self.free_tail.fetchAdd(1, .acq_rel);
            self.free_list[tail % self.config.num_frames] = frame_idx;
            self.meta[frame_idx].valid.store(false, .release);
            _ = self.stats.releases.fetchAdd(1, .release);
        }
    }
    
    /// Get frame data pointer
    pub fn getFrameData(self: *Self, frame_idx: u32) []u8 {
        const offset = @as(usize, frame_idx) * self.config.frame_size;
        return self.data[offset .. offset + self.config.frame_size];
    }
    
    /// Get frame metadata
    pub fn getFrameMeta(self: *Self, frame_idx: u32) *FrameMeta {
        return &self.meta[frame_idx];
    }
    
    /// Load data from file into a frame
    pub fn loadFromFile(self: *Self, file: std.fs.File, file_id: u32, offset: u64) !u32 {
        const frame_idx = self.allocFrame() orelse return error.PoolExhausted;
        
        const frame_data = self.getFrameData(frame_idx);
        const meta = self.getFrameMeta(frame_idx);
        
        try file.seekTo(offset);
        const bytes_read = try file.read(frame_data);
        
        meta.file_id = file_id;
        meta.offset = offset;
        meta.data_size = @intCast(bytes_read);
        meta.valid.store(true, .release);
        
        _ = self.stats.loads.fetchAdd(1, .release);
        
        return frame_idx;
    }
    
    /// Evict a frame (FIFO strategy)
    fn evictFrame(self: *Self) ?u32 {
        // Find oldest frame not in use
        var oldest_idx: ?u32 = null;
        var oldest_time: i64 = std.math.maxInt(i64);
        
        for (self.meta, 0..) |*m, i| {
            if (!m.isInUse() and m.valid.load(.acquire)) {
                const access_time = m.last_access.load(.acquire);
                if (access_time < oldest_time) {
                    oldest_time = access_time;
                    oldest_idx = @intCast(i);
                }
            }
        }
        
        if (oldest_idx) |idx| {
            self.meta[idx].valid.store(false, .release);
            self.meta[idx].acquire();
            _ = self.stats.evictions.fetchAdd(1, .release);
            return idx;
        }
        
        return null;
    }
    
    /// Print statistics
    pub fn printStats(self: *const Self) void {
        std.debug.print("\n[BufferPool Stats]\n", .{});
        std.debug.print("  Allocations:   {d}\n", .{self.stats.allocs.load(.acquire)});
        std.debug.print("  Releases:      {d}\n", .{self.stats.releases.load(.acquire)});
        std.debug.print("  Loads:         {d}\n", .{self.stats.loads.load(.acquire)});
        std.debug.print("  Evictions:     {d}\n", .{self.stats.evictions.load(.acquire)});
        std.debug.print("  Alloc Fails:   {d}\n", .{self.stats.alloc_failures.load(.acquire)});
    }
};

/// Buffer pool statistics
pub const BufferPoolStats = struct {
    allocs: Atomic(u64) = Atomic(u64).init(0),
    releases: Atomic(u64) = Atomic(u64).init(0),
    loads: Atomic(u64) = Atomic(u64).init(0),
    evictions: Atomic(u64) = Atomic(u64).init(0),
    alloc_failures: Atomic(u64) = Atomic(u64).init(0),
};

/// Account reference - points to data in buffer pool
pub const AccountRef = struct {
    /// Frame index in buffer pool
    frame_idx: u32,
    
    /// Offset within frame
    offset_in_frame: u16,
    
    /// Account data size
    data_size: u16,
    
    /// File ID for reload if evicted
    file_id: u32,
    
    /// Offset in file for reload
    file_offset: u64,
    
    pub fn getData(self: *const AccountRef, pool: *BufferPool) []const u8 {
        const frame_data = pool.getFrameData(self.frame_idx);
        return frame_data[self.offset_in_frame .. self.offset_in_frame + self.data_size];
    }
};

test "buffer_pool basic" {
    var pool = try BufferPool.init(std.testing.allocator, .{
        .num_frames = 16,
        .frame_size = 512,
        .prefault = false,
    });
    defer pool.deinit();
    
    // Allocate and release frames
    const frame1 = pool.allocFrame() orelse unreachable;
    const frame2 = pool.allocFrame() orelse unreachable;
    
    try std.testing.expect(frame1 != frame2);
    
    pool.releaseFrame(frame1);
    pool.releaseFrame(frame2);
}
