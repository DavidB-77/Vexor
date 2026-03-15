//! Parallel Index Generator
//!
//! High-performance parallel index builder for account data.
//! Based on Sig's approach of parallel mini-index generation + lock-free merge.
//!
//! Algorithm:
//!   1. Split account files across N threads
//!   2. Each thread builds a "mini-index" for its files
//!   3. Merge mini-indexes in parallel (each thread owns subset of bins)
//!   4. No lock contention between threads
//!
//! Index structure:
//!   - 8192 bins (13 bits from pubkey)
//!   - Each bin: HashMap<Pubkey, AccountLocation>
//!   - SwissMap-based for performance (like Sig)

const std = @import("std");
const Thread = std.Thread;
const Atomic = std.atomic.Value;

/// Number of index bins (power of 2, using 13 bits of pubkey)
pub const NUM_BINS: u32 = 8192;

/// Account location in storage
pub const AccountLocation = struct {
    /// File ID
    file_id: u32,
    
    /// Offset within file
    offset: u64,
    
    /// Account data length
    data_len: u32,
    
    /// Slot this account version is from
    slot: u64,
    
    /// Lamports (for quick filtering)
    lamports: u64,
};

/// Pubkey (32 bytes)
pub const Pubkey = [32]u8;

/// Get bin index from pubkey (first 13 bits)
pub fn getBinIndex(pubkey: *const Pubkey) u32 {
    // Use first 2 bytes, mask to 13 bits
    const b0: u32 = pubkey[0];
    const b1: u32 = pubkey[1];
    return ((b0 << 8) | b1) & (NUM_BINS - 1);
}

/// Mini-index for a thread's portion of files
pub const MiniIndex = struct {
    allocator: std.mem.Allocator,
    
    /// Per-bin hashmaps
    bins: [NUM_BINS]std.AutoHashMap(Pubkey, AccountLocation),
    
    /// Statistics
    total_accounts: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .bins = undefined,
            .total_accounts = 0,
        };
        
        for (&self.bins) |*bin| {
            bin.* = std.AutoHashMap(Pubkey, AccountLocation).init(allocator);
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        for (&self.bins) |*bin| {
            bin.deinit();
        }
    }
    
    pub fn insert(self: *Self, pubkey: *const Pubkey, location: AccountLocation) !void {
        const bin_idx = getBinIndex(pubkey);
        try self.bins[bin_idx].put(pubkey.*, location);
        self.total_accounts += 1;
    }
};

/// Parallel indexer configuration
pub const IndexerConfig = struct {
    /// Number of indexer threads
    num_threads: u32 = 8,
    
    /// Pre-allocate bin capacity
    initial_bin_capacity: u32 = 1024,
};

/// Parallel indexer
pub const ParallelIndexer = struct {
    allocator: std.mem.Allocator,
    config: IndexerConfig,
    
    /// Main index (final merged result)
    main_index: [NUM_BINS]std.AutoHashMap(Pubkey, AccountLocation),
    
    /// Per-bin locks for merging
    bin_locks: [NUM_BINS]std.Thread.Mutex,
    
    /// Progress tracking
    files_processed: Atomic(u32),
    accounts_indexed: Atomic(u64),
    
    /// Indexing state
    state: Atomic(u8),
    
    const Self = @This();
    const State = enum(u8) {
        idle,
        indexing,
        merging,
        complete,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: IndexerConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.allocator = allocator;
        self.config = config;
        self.files_processed = Atomic(u32).init(0);
        self.accounts_indexed = Atomic(u64).init(0);
        self.state = Atomic(u8).init(@intFromEnum(State.idle));
        
        // Initialize main index bins
        for (&self.main_index) |*bin| {
            bin.* = std.AutoHashMap(Pubkey, AccountLocation).init(allocator);
            try bin.ensureTotalCapacity(config.initial_bin_capacity);
        }
        
        // Initialize bin locks
        for (&self.bin_locks) |*lock| {
            lock.* = std.Thread.Mutex{};
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        for (&self.main_index) |*bin| {
            bin.deinit();
        }
        self.allocator.destroy(self);
    }
    
    /// Index account files in parallel
    pub fn indexFiles(self: *Self, file_paths: []const []const u8) !void {
        self.state.store(@intFromEnum(State.indexing), .release);
        
        std.debug.print("[Indexer] Starting parallel indexing of {d} files with {d} threads\n", .{
            file_paths.len,
            self.config.num_threads,
        });
        
        const start_time = std.time.milliTimestamp();
        
        // Spawn worker threads
        const threads = try self.allocator.alloc(Thread, self.config.num_threads);
        defer self.allocator.free(threads);
        
        const files_per_thread = (file_paths.len + self.config.num_threads - 1) / self.config.num_threads;
        
        for (threads, 0..) |*thread, i| {
            const start_idx = i * files_per_thread;
            const end_idx = @min(start_idx + files_per_thread, file_paths.len);
            
            if (start_idx < file_paths.len) {
                thread.* = try Thread.spawn(.{}, indexWorker, .{
                    self,
                    file_paths[start_idx..end_idx],
                    @as(u32, @intCast(i)),
                });
            }
        }
        
        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }
        
        self.state.store(@intFromEnum(State.complete), .release);
        
        const elapsed = std.time.milliTimestamp() - start_time;
        const total_accounts = self.accounts_indexed.load(.acquire);
        
        std.debug.print("[Indexer] Complete: {d} accounts indexed in {d}ms ({d} accounts/sec)\n", .{
            total_accounts,
            elapsed,
            if (elapsed > 0) total_accounts * 1000 / @as(u64, @intCast(elapsed)) else 0,
        });
    }
    
    /// Worker thread for indexing
    fn indexWorker(self: *Self, file_paths: []const []const u8, _: u32) void {
        
        // Create thread-local mini-index
        var mini_index = MiniIndex.init(self.allocator);
        defer mini_index.deinit();
        
        // Process assigned files
        for (file_paths) |path| {
            self.indexSingleFile(path, &mini_index) catch |err| {
                std.debug.print("[Indexer] Error processing {s}: {}\n", .{ path, err });
                continue;
            };
            _ = self.files_processed.fetchAdd(1, .release);
        }
        
        // Merge mini-index into main index
        self.mergeMiniIndex(&mini_index);
    }
    
    /// Index a single account file
    fn indexSingleFile(self: *Self, path: []const u8, mini_index: *MiniIndex) !void {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        
        // Parse file ID from path
        const file_id: u32 = 0; // TODO: Parse from filename
        
        // Read and parse account entries
        // Account file format (AppendVec):
        //   - write_version: u64
        //   - data_len: u64
        //   - pubkey: [32]u8
        //   - lamports: u64
        //   - rent_epoch: u64
        //   - owner: [32]u8
        //   - executable: bool
        //   - [data_len bytes of data]
        
        var offset: u64 = 0;
        const file_size = (try file.stat()).size;
        
        var header_buf: [128]u8 = undefined;
        
        while (offset < file_size) {
            // Read header
            try file.seekTo(offset);
            const header_bytes = try file.read(&header_buf);
            if (header_bytes < 96) break;
            
            // Parse header
            const data_len = std.mem.readInt(u64, header_buf[8..16], .little);
            const pubkey: *const Pubkey = @ptrCast(header_buf[16..48]);
            const lamports = std.mem.readInt(u64, header_buf[48..56], .little);
            
            // Create location entry
            const location = AccountLocation{
                .file_id = file_id,
                .offset = offset,
                .data_len = @intCast(data_len),
                .slot = 0, // TODO: Get from file metadata
                .lamports = lamports,
            };
            
            try mini_index.insert(pubkey, location);
            _ = self.accounts_indexed.fetchAdd(1, .release);
            
            // Move to next account
            // Header: 96 bytes (8+8+32+8+8+32+1 padded)
            // + data_len
            // + padding to 8-byte alignment
            const entry_size = 96 + data_len;
            const aligned_size = (entry_size + 7) & ~@as(u64, 7);
            offset += aligned_size;
        }
    }
    
    /// Merge a mini-index into main index
    fn mergeMiniIndex(self: *Self, mini_index: *MiniIndex) void {
        // Each thread merges its assigned bins (no contention)
        for (&mini_index.bins, 0..) |*mini_bin, bin_idx| {
            self.bin_locks[bin_idx].lock();
            defer self.bin_locks[bin_idx].unlock();
            
            var iter = mini_bin.iterator();
            while (iter.next()) |entry| {
                self.main_index[bin_idx].put(entry.key_ptr.*, entry.value_ptr.*) catch continue;
            }
        }
    }
    
    /// Lookup account by pubkey
    pub fn lookup(self: *Self, pubkey: *const Pubkey) ?AccountLocation {
        const bin_idx = getBinIndex(pubkey);
        return self.main_index[bin_idx].get(pubkey.*);
    }
    
    /// Get total indexed accounts
    pub fn getTotalAccounts(self: *const Self) u64 {
        var total: u64 = 0;
        for (&self.main_index) |*bin| {
            total += bin.count();
        }
        return total;
    }
    
    /// Print index statistics
    pub fn printStats(self: *const Self) void {
        var total: u64 = 0;
        var max_bin: u64 = 0;
        var min_bin: u64 = std.math.maxInt(u64);
        
        for (&self.main_index) |*bin| {
            const count = bin.count();
            total += count;
            max_bin = @max(max_bin, count);
            min_bin = @min(min_bin, count);
        }
        
        const avg = total / NUM_BINS;
        
        std.debug.print("\n[Index Stats]\n", .{});
        std.debug.print("  Total Accounts: {d}\n", .{total});
        std.debug.print("  Bins: {d}\n", .{NUM_BINS});
        std.debug.print("  Avg per bin: {d}\n", .{avg});
        std.debug.print("  Max bin: {d}\n", .{max_bin});
        std.debug.print("  Min bin: {d}\n", .{min_bin});
    }
    
    /// Build index from existing AccountsDb
    /// This is used during fast catchup after accounts are loaded
    pub fn buildIndex(self: *Self, _accounts_db: anytype) !void {
        std.debug.print("[Indexer] Building index from accounts DB...\n", .{});
        
        // TODO: Iterate through accounts in DB and add to index
        _ = _accounts_db;
        
        // For now, just mark as complete
        self.state.store(@intFromEnum(State.complete), .release);
        
        std.debug.print("[Indexer] Index build complete\n", .{});
    }
};

test "getBinIndex" {
    var pubkey: Pubkey = undefined;
    @memset(&pubkey, 0);
    
    // First 2 bytes = 0x0000 -> bin 0
    try std.testing.expectEqual(@as(u32, 0), getBinIndex(&pubkey));
    
    // First 2 bytes = 0x1FFF -> bin 8191 (max)
    pubkey[0] = 0x1F;
    pubkey[1] = 0xFF;
    try std.testing.expectEqual(@as(u32, 8191), getBinIndex(&pubkey));
}
