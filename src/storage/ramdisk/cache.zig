//! RamDisk Hot Cache
//! Ultra-low latency cache for frequently accessed accounts and data.
//!
//! Performance characteristics:
//! - RAM access: <1μs
//! - NVMe access: 50-100μs
//! - Cache hit provides 50-100x speedup
//!
//! Memory layout:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                    RAM Cache (32-64GB)                       │
//! ├─────────────────────────────────────────────────────────────┤
//! │  ┌─────────────────────────────────────────────────────┐    │
//! │  │              Hot Account Index                       │    │
//! │  │  [Pubkey -> Entry] HashMap                          │    │
//! │  └─────────────────────────────────────────────────────┘    │
//! │  ┌─────────────────────────────────────────────────────┐    │
//! │  │              Account Data Arena                      │    │
//! │  │  [Slab allocator for variable-size data]            │    │
//! │  └─────────────────────────────────────────────────────┘    │
//! │  ┌─────────────────────────────────────────────────────┐    │
//! │  │              Slot State Cache                        │    │
//! │  │  [Recent slot states for fast replay]               │    │
//! │  └─────────────────────────────────────────────────────┘    │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

/// Cache entry for an account
pub const CacheEntry = struct {
    /// Account pubkey
    pubkey: [32]u8,
    /// Account lamports
    lamports: u64,
    /// Account data (owned by arena)
    data: []u8,
    /// Account owner
    owner: [32]u8,
    /// Is executable
    executable: bool,
    /// Rent epoch
    rent_epoch: u64,
    /// Slot when written
    write_slot: u64,
    /// Access count for LRU
    access_count: u64,
    /// Last access timestamp (nanoseconds)
    last_access: i128,
    /// Is dirty (needs writeback)
    dirty: bool,
    /// Hash of data for integrity check
    data_hash: [32]u8,
};

/// Cache statistics
pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    writebacks: u64 = 0,
    total_bytes_cached: usize = 0,
    entry_count: usize = 0,

    pub fn hitRate(self: *const CacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// LRU eviction policy
pub const EvictionPolicy = enum {
    lru, // Least Recently Used
    lfu, // Least Frequently Used
    adaptive, // Adaptive based on access patterns
};

/// Configuration for the cache
pub const CacheConfig = struct {
    /// Maximum memory to use (bytes)
    max_memory: usize = 32 * 1024 * 1024 * 1024, // 32GB default
    /// Maximum entries
    max_entries: usize = 10_000_000, // 10M accounts
    /// Eviction policy
    eviction_policy: EvictionPolicy = .adaptive,
    /// Writeback threshold (dirty ratio)
    writeback_threshold: f32 = 0.8,
    /// Enable integrity checking
    integrity_check: bool = true,
    /// RAM disk path (if using tmpfs)
    ramdisk_path: ?[]const u8 = null,
};

/// RAM disk hot cache
pub const HotCache = struct {
    /// Entry index by pubkey
    entries: std.AutoHashMap([32]u8, *CacheEntry),
    /// Memory arena for account data
    arena: std.heap.ArenaAllocator,
    /// Free list of cache entries
    entry_pool: std.ArrayList(*CacheEntry),
    /// Configuration
    config: CacheConfig,
    /// Statistics
    stats: CacheStats,
    /// Lock for thread safety
    mutex: Mutex,
    /// Total bytes used
    bytes_used: usize,
    /// Backing allocator
    allocator: Allocator,
    /// Is using memory-mapped file
    using_mmap: bool,
    /// Memory-mapped region (if using mmap)
    mmap_region: ?[]align(std.mem.page_size) u8,

    pub fn init(allocator: Allocator, config: CacheConfig) !HotCache {
        var cache = HotCache{
            .entries = std.AutoHashMap([32]u8, *CacheEntry).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entry_pool = std.ArrayList(*CacheEntry).init(allocator),
            .config = config,
            .stats = .{},
            .mutex = .{},
            .bytes_used = 0,
            .allocator = allocator,
            .using_mmap = false,
            .mmap_region = null,
        };

        // Try to use memory-mapped file for larger cache
        if (config.ramdisk_path) |path| {
            cache.mmap_region = try cache.setupMmap(path, config.max_memory);
            cache.using_mmap = cache.mmap_region != null;
        }

        return cache;
    }

    pub fn deinit(self: *HotCache) void {
        // Clean up mmap if used
        if (self.mmap_region) |region| {
            std.posix.munmap(region);
        }

        self.entries.deinit();
        self.arena.deinit();
        self.entry_pool.deinit();
    }

    fn setupMmap(self: *HotCache, path: []const u8, size: usize) !?[]align(std.mem.page_size) u8 {
        _ = self;

        // Create or open the backing file
        const file = std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = false,
        }) catch |err| {
            std.log.warn("Failed to create ramdisk backing file: {}", .{err});
            return null;
        };
        defer file.close();

        // Resize to desired size
        file.setEndPos(size) catch |err| {
            std.log.warn("Failed to resize ramdisk file: {}", .{err});
            return null;
        };

        // Memory map the file
        const region = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        ) catch |err| {
            std.log.warn("Failed to mmap ramdisk file: {}", .{err});
            return null;
        };

        std.log.info("RamDisk cache using mmap at {s} ({d} MB)", .{
            path,
            size / (1024 * 1024),
        });

        return region;
    }

    /// Get an account from cache
    pub fn get(self: *HotCache, pubkey: *const [32]u8) ?*CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(pubkey.*)) |entry| {
            // Update access stats
            entry.access_count += 1;
            entry.last_access = std.time.nanoTimestamp();
            self.stats.hits += 1;
            return entry;
        }

        self.stats.misses += 1;
        return null;
    }

    /// Put an account into cache
    pub fn put(
        self: *HotCache,
        pubkey: *const [32]u8,
        lamports: u64,
        data: []const u8,
        owner: *const [32]u8,
        executable: bool,
        rent_epoch: u64,
        write_slot: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we need to evict
        const entry_size = @sizeOf(CacheEntry) + data.len;
        while (self.bytes_used + entry_size > self.config.max_memory or
            self.entries.count() >= self.config.max_entries)
        {
            if (!self.evictOne()) break;
        }

        // Get or create entry
        var entry: *CacheEntry = undefined;
        if (self.entries.get(pubkey.*)) |existing| {
            // Update existing
            entry = existing;
            self.bytes_used -= entry.data.len;
        } else {
            // Create new entry
            entry = try self.arena.allocator().create(CacheEntry);
            try self.entries.put(pubkey.*, entry);
            self.stats.entry_count += 1;
        }

        // Allocate data
        const data_copy = try self.arena.allocator().alloc(u8, data.len);
        @memcpy(data_copy, data);

        // Calculate hash for integrity
        var hash: [32]u8 = undefined;
        if (self.config.integrity_check) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(data);
            hash = hasher.finalResult();
        }

        // Fill entry
        entry.* = .{
            .pubkey = pubkey.*,
            .lamports = lamports,
            .data = data_copy,
            .owner = owner.*,
            .executable = executable,
            .rent_epoch = rent_epoch,
            .write_slot = write_slot,
            .access_count = 1,
            .last_access = std.time.nanoTimestamp(),
            .dirty = true,
            .data_hash = hash,
        };

        self.bytes_used += data.len;
        self.stats.total_bytes_cached = self.bytes_used;
    }

    /// Remove an account from cache
    pub fn remove(self: *HotCache, pubkey: *const [32]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(pubkey.*)) |kv| {
            self.bytes_used -= kv.value.data.len;
            self.stats.entry_count -= 1;
            // Entry and data will be freed when arena is reset
            return true;
        }
        return false;
    }

    /// Mark entry as clean (written back)
    pub fn markClean(self: *HotCache, pubkey: *const [32]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(pubkey.*)) |entry| {
            entry.dirty = false;
            self.stats.writebacks += 1;
        }
    }

    /// Get all dirty entries for writeback
    pub fn getDirtyEntries(self: *HotCache, allocator: Allocator) ![]const *CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var dirty = std.ArrayList(*CacheEntry).init(allocator);
        errdefer dirty.deinit();

        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            if (entry.*.dirty) {
                try dirty.append(entry.*);
            }
        }

        return dirty.toOwnedSlice();
    }

    /// Verify data integrity
    pub fn verifyIntegrity(self: *HotCache, pubkey: *const [32]u8) bool {
        if (!self.config.integrity_check) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(pubkey.*)) |entry| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(entry.data);
            const computed = hasher.finalResult();
            return std.mem.eql(u8, &computed, &entry.data_hash);
        }

        return false;
    }

    /// Evict one entry based on policy
    fn evictOne(self: *HotCache) bool {
        var victim: ?*CacheEntry = null;
        var victim_key: ?[32]u8 = null;
        var min_score: f64 = std.math.floatMax(f64);

        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            const entry = kv.value_ptr.*;
            const score = self.calculateEvictionScore(entry);

            if (score < min_score) {
                min_score = score;
                victim = entry;
                victim_key = kv.key_ptr.*;
            }
        }

        if (victim) |v| {
            if (victim_key) |key| {
                // If dirty, should writeback first (caller responsibility)
                if (v.dirty) {
                    // In production, trigger async writeback
                }

                self.bytes_used -= v.data.len;
                _ = self.entries.remove(key);
                self.stats.evictions += 1;
                self.stats.entry_count -= 1;
                return true;
            }
        }

        return false;
    }

    fn calculateEvictionScore(self: *HotCache, entry: *const CacheEntry) f64 {
        const now = std.time.nanoTimestamp();
        const age_ns: f64 = @floatFromInt(now - entry.last_access);
        const age_seconds = age_ns / 1_000_000_000.0;

        return switch (self.config.eviction_policy) {
            .lru => -age_seconds, // Lower = older = evict first
            .lfu => @floatFromInt(entry.access_count), // Lower = less used
            .adaptive => {
                // Combine recency and frequency
                const recency_weight: f64 = 0.7;
                const frequency_weight: f64 = 0.3;

                const recency_score = -age_seconds;
                const freq_score: f64 = @floatFromInt(entry.access_count);

                return recency_weight * recency_score + frequency_weight * freq_score;
            },
        };
    }

    /// Get cache statistics
    pub fn getStats(self: *HotCache) CacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *HotCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.stats.hits = 0;
        self.stats.misses = 0;
        self.stats.evictions = 0;
        self.stats.writebacks = 0;
    }

    /// Prefetch accounts into cache
    pub fn prefetch(
        self: *HotCache,
        pubkeys: []const [32]u8,
        fetch_fn: *const fn (*const [32]u8) ?AccountData,
    ) !usize {
        var fetched: usize = 0;

        for (pubkeys) |pubkey| {
            // Skip if already cached
            if (self.entries.contains(pubkey)) continue;

            // Fetch from backing store
            if (fetch_fn(&pubkey)) |account| {
                try self.put(
                    &pubkey,
                    account.lamports,
                    account.data,
                    &account.owner,
                    account.executable,
                    account.rent_epoch,
                    account.slot,
                );
                fetched += 1;
            }
        }

        return fetched;
    }

    /// Account data for prefetch callback
    pub const AccountData = struct {
        lamports: u64,
        data: []const u8,
        owner: [32]u8,
        executable: bool,
        rent_epoch: u64,
        slot: u64,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "HotCache: basic put and get" {
    const allocator = std.testing.allocator;

    var cache = try HotCache.init(allocator, .{
        .max_memory = 1024 * 1024, // 1MB
        .max_entries = 100,
    });
    defer cache.deinit();

    const pubkey = [_]u8{1} ** 32;
    const owner = [_]u8{2} ** 32;
    const data = "test data";

    try cache.put(&pubkey, 1000, data, &owner, false, 0, 1);

    const entry = cache.get(&pubkey);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 1000), entry.?.lamports);
    try std.testing.expectEqualSlices(u8, data, entry.?.data);
}

test "HotCache: cache miss" {
    const allocator = std.testing.allocator;

    var cache = try HotCache.init(allocator, .{});
    defer cache.deinit();

    const pubkey = [_]u8{1} ** 32;
    const entry = cache.get(&pubkey);

    try std.testing.expect(entry == null);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);
}

test "HotCache: eviction" {
    const allocator = std.testing.allocator;

    // Very small cache to force eviction
    var cache = try HotCache.init(allocator, .{
        .max_memory = 256,
        .max_entries = 2,
    });
    defer cache.deinit();

    const owner = [_]u8{0} ** 32;

    // Add entries until eviction
    for (0..5) |i| {
        var pubkey = [_]u8{0} ** 32;
        pubkey[0] = @intCast(i);
        try cache.put(&pubkey, 100, "data", &owner, false, 0, 1);
    }

    // Should have evicted some
    try std.testing.expect(cache.stats.evictions > 0);
}

test "HotCache: statistics" {
    const allocator = std.testing.allocator;

    var cache = try HotCache.init(allocator, .{});
    defer cache.deinit();

    const pubkey = [_]u8{1} ** 32;
    const owner = [_]u8{2} ** 32;

    // Miss
    _ = cache.get(&pubkey);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // Put
    try cache.put(&pubkey, 100, "data", &owner, false, 0, 1);

    // Hit
    _ = cache.get(&pubkey);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);

    const hit_rate = cache.stats.hitRate();
    try std.testing.expect(hit_rate > 0.0 and hit_rate < 1.0);
}

