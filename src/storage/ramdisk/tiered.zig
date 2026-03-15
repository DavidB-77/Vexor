//! Tiered Storage Manager
//! Manages data flow between storage tiers for optimal performance.
//!
//! Tiers:
//! ┌─────────────────────────────────────────────────────────────┐
//! │  Tier 0: RAM (tmpfs/mmap)  │  <1μs  │  32-64GB  │  Hot     │
//! ├─────────────────────────────────────────────────────────────┤
//! │  Tier 1: NVMe SSD          │  50μs  │  1-4TB    │  Warm    │
//! ├─────────────────────────────────────────────────────────────┤
//! │  Tier 2: HDD/Archive       │  10ms  │  10TB+    │  Cold    │
//! └─────────────────────────────────────────────────────────────┘
//!
//! Data flows:
//! - Read: T0 → T1 → T2 (promote on access)
//! - Write: T0 (async flush to T1)
//! - Eviction: T0 → T1 → T2

const std = @import("std");
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const HotCache = cache.HotCache;
const CacheConfig = cache.CacheConfig;

/// Storage tier identifiers
pub const Tier = enum(u8) {
    ram = 0,
    nvme = 1,
    archive = 2,
};

/// Tiered storage configuration
pub const TieredConfig = struct {
    /// RAM cache configuration
    ram_config: CacheConfig = .{},

    /// NVMe storage path
    nvme_path: []const u8 = "/mnt/ledger",

    /// Archive storage path (optional)
    archive_path: ?[]const u8 = null,

    /// Enable background writeback
    async_writeback: bool = true,

    /// Writeback interval (ms)
    writeback_interval_ms: u64 = 100,

    /// Enable read-ahead prefetching
    prefetch_enabled: bool = true,

    /// Number of accounts to prefetch
    prefetch_count: usize = 1000,

    /// Enable compression for tier 1+
    compression_enabled: bool = true,

    /// Slots to keep in RAM
    hot_slots: usize = 100,
};

/// Account location info
pub const AccountLocation = struct {
    tier: Tier,
    offset: u64,
    size: u32,
    compressed: bool,
    slot: u64,
};

/// Tiered storage manager
pub const TieredStorage = struct {
    /// Tier 0: RAM cache
    hot_cache: HotCache,

    /// Configuration
    config: TieredConfig,

    /// Location index (where is each account)
    location_index: std.AutoHashMap([32]u8, AccountLocation),

    /// Background writeback thread
    writeback_thread: ?std.Thread,

    /// Shutdown signal
    shutdown: std.atomic.Value(bool),

    /// Pending writebacks
    pending_writebacks: std.ArrayList([32]u8),

    /// Allocator
    allocator: Allocator,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, config: TieredConfig) !TieredStorage {
        const storage = TieredStorage{
            .hot_cache = try HotCache.init(allocator, config.ram_config),
            .config = config,
            .location_index = std.AutoHashMap([32]u8, AccountLocation).init(allocator),
            .writeback_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .pending_writebacks = std.ArrayList([32]u8).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };

        // Note: Background writeback thread is NOT started here.
        // It must be started separately after the storage is allocated on the heap.
        // Call startWritebackThread() after obtaining a stable pointer.
        // For test/mock mode, async_writeback should be disabled.

        return storage;
    }

    pub fn deinit(self: *TieredStorage) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wait for writeback thread
        if (self.writeback_thread) |thread| {
            thread.join();
        }

        self.hot_cache.deinit();
        self.location_index.deinit();
        self.pending_writebacks.deinit();
    }

    /// Read an account (checks all tiers)
    pub fn readAccount(self: *TieredStorage, pubkey: *const [32]u8) !?AccountData {
        // Try RAM cache first (Tier 0)
        if (self.hot_cache.get(pubkey)) |entry| {
            return AccountData{
                .lamports = entry.lamports,
                .data = entry.data,
                .owner = entry.owner,
                .executable = entry.executable,
                .rent_epoch = entry.rent_epoch,
            };
        }

        // Try NVMe (Tier 1)
        if (try self.readFromNvme(pubkey)) |account| {
            // Promote to RAM cache
            try self.hot_cache.put(
                pubkey,
                account.lamports,
                account.data,
                &account.owner,
                account.executable,
                account.rent_epoch,
                0, // slot unknown
            );
            return account;
        }

        // Try archive (Tier 2) if configured
        if (self.config.archive_path != null) {
            if (try self.readFromArchive(pubkey)) |account| {
                // Promote to RAM
                try self.hot_cache.put(
                    pubkey,
                    account.lamports,
                    account.data,
                    &account.owner,
                    account.executable,
                    account.rent_epoch,
                    0,
                );
                return account;
            }
        }

        return null;
    }

    /// Write an account (always to RAM, async flush to NVMe)
    pub fn writeAccount(
        self: *TieredStorage,
        pubkey: *const [32]u8,
        lamports: u64,
        data: []const u8,
        owner: *const [32]u8,
        executable: bool,
        rent_epoch: u64,
        slot: u64,
    ) !void {
        // Write to RAM cache
        try self.hot_cache.put(
            pubkey,
            lamports,
            data,
            owner,
            executable,
            rent_epoch,
            slot,
        );

        // Update location
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.location_index.put(pubkey.*, .{
            .tier = .ram,
            .offset = 0,
            .size = @intCast(data.len),
            .compressed = false,
            .slot = slot,
        });

        // Queue for async writeback
        if (self.config.async_writeback) {
            try self.pending_writebacks.append(pubkey.*);
        }
    }

    /// Force flush all dirty entries to NVMe
    pub fn flush(self: *TieredStorage) !usize {
        const dirty = try self.hot_cache.getDirtyEntries(self.allocator);
        defer self.allocator.free(dirty);

        var flushed: usize = 0;
        for (dirty) |entry| {
            if (try self.writeToNvme(entry)) {
                self.hot_cache.markClean(&entry.pubkey);
                flushed += 1;
            }
        }

        return flushed;
    }

    /// Get statistics across all tiers
    pub fn getStats(self: *TieredStorage) TieredStats {
        const cache_stats = self.hot_cache.getStats();

        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .ram_hits = cache_stats.hits,
            .ram_misses = cache_stats.misses,
            .ram_entries = cache_stats.entry_count,
            .ram_bytes = cache_stats.total_bytes_cached,
            .nvme_reads = 0, // TODO: track
            .nvme_writes = cache_stats.writebacks,
            .pending_writebacks = self.pending_writebacks.items.len,
        };
    }

    // ========================================================================
    // Internal methods
    // ========================================================================

    fn readFromNvme(self: *TieredStorage, pubkey: *const [32]u8) !?AccountData {
        self.mutex.lock();
        const location = self.location_index.get(pubkey.*);
        self.mutex.unlock();

        if (location == null or location.?.tier != .nvme) {
            return null;
        }

        const loc = location.?;

        // Build path for account file
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/accounts/{x}", .{
            self.config.nvme_path,
            pubkey.*,
        }) catch return null;

        // Read file
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var data = try self.allocator.alloc(u8, loc.size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read < @sizeOf(AccountHeader)) {
            self.allocator.free(data);
            return null;
        }

        // Parse header
        const header: *const AccountHeader = @ptrCast(@alignCast(data.ptr));

        // Decompress if needed
        if (loc.compressed) {
            // TODO: implement decompression
        }

        return AccountData{
            .lamports = header.lamports,
            .data = data[@sizeOf(AccountHeader)..],
            .owner = header.owner,
            .executable = header.executable != 0,
            .rent_epoch = header.rent_epoch,
        };
    }

    fn readFromArchive(self: *TieredStorage, pubkey: *const [32]u8) !?AccountData {
        _ = self;
        _ = pubkey;
        // TODO: implement archive tier
        return null;
    }

    fn writeToNvme(self: *TieredStorage, entry: *const cache.CacheEntry) !bool {
        // Build path
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/accounts/{x}", .{
            self.config.nvme_path,
            entry.pubkey,
        }) catch return false;

        // Ensure directory exists
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/accounts", .{
            self.config.nvme_path,
        }) catch return false;
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return false,
        };

        // Write to file
        const file = std.fs.createFileAbsolute(path, .{}) catch return false;
        defer file.close();

        // Write header
        const header = AccountHeader{
            .lamports = entry.lamports,
            .owner = entry.owner,
            .executable = if (entry.executable) 1 else 0,
            .rent_epoch = entry.rent_epoch,
            .data_len = @intCast(entry.data.len),
        };

        _ = file.write(std.mem.asBytes(&header)) catch return false;
        _ = file.write(entry.data) catch return false;

        // Update location index
        self.mutex.lock();
        defer self.mutex.unlock();

        self.location_index.put(entry.pubkey, .{
            .tier = .nvme,
            .offset = 0,
            .size = @intCast(@sizeOf(AccountHeader) + entry.data.len),
            .compressed = false,
            .slot = entry.write_slot,
        }) catch return false;

        return true;
    }

    fn writebackLoop(self: *TieredStorage) void {
        while (!self.shutdown.load(.acquire)) {
            // Sleep for 100ms between checks
            std.time.sleep(100_000_000); // 100ms in ns

            // Process pending writebacks safely
            self.mutex.lock();
            defer self.mutex.unlock();

            // Only process if there are pending items
            if (self.pending_writebacks.items.len == 0) continue;

            // Copy the items to process (don't use toOwnedSlice which can fail)
            var items_to_process: [64][32]u8 = undefined;
            const count = @min(self.pending_writebacks.items.len, 64);

            for (0..count) |i| {
                @memcpy(&items_to_process[i], &self.pending_writebacks.items[i]);
            }

            // Remove processed items
            self.pending_writebacks.shrinkAndFree(self.pending_writebacks.items.len - count);

            // Process items (unlock during processing)
            self.mutex.unlock();
            for (0..count) |i| {
                if (self.hot_cache.get(&items_to_process[i])) |entry| {
                    if (entry.dirty) {
                        if (self.writeToNvme(entry) catch false) {
                            self.hot_cache.markClean(&items_to_process[i]);
                        }
                    }
                }
            }
            self.mutex.lock(); // Re-lock for the defer
        }
    }
};

/// Account header for NVMe storage
const AccountHeader = extern struct {
    lamports: u64,
    owner: [32]u8,
    executable: u8,
    rent_epoch: u64,
    data_len: u32,
    _padding: [3]u8 = [_]u8{0} ** 3,
};

/// Account data returned from reads
pub const AccountData = struct {
    lamports: u64,
    data: []const u8,
    owner: [32]u8,
    executable: bool,
    rent_epoch: u64,
};

/// Statistics across all tiers
pub const TieredStats = struct {
    ram_hits: u64,
    ram_misses: u64,
    ram_entries: usize,
    ram_bytes: usize,
    nvme_reads: u64,
    nvme_writes: u64,
    pending_writebacks: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "TieredStorage: basic init" {
    const allocator = std.testing.allocator;

    var storage = try TieredStorage.init(allocator, .{
        .async_writeback = false, // Disable for testing
    });
    defer storage.deinit();

    const stats = storage.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.ram_hits);
}

test "TieredStorage: write and read from RAM" {
    const allocator = std.testing.allocator;

    var storage = try TieredStorage.init(allocator, .{
        .async_writeback = false,
    });
    defer storage.deinit();

    const pubkey = [_]u8{1} ** 32;
    const owner = [_]u8{2} ** 32;
    const data = "test account data";

    try storage.writeAccount(&pubkey, 1000, data, &owner, false, 0, 100);

    const account = try storage.readAccount(&pubkey);
    try std.testing.expect(account != null);
    try std.testing.expectEqual(@as(u64, 1000), account.?.lamports);
}

test "TieredStorage: cache miss" {
    const allocator = std.testing.allocator;

    var storage = try TieredStorage.init(allocator, .{
        .async_writeback = false,
    });
    defer storage.deinit();

    const pubkey = [_]u8{99} ** 32;
    const account = try storage.readAccount(&pubkey);

    try std.testing.expect(account == null);
}

