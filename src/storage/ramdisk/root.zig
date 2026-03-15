//! RamDisk Storage Module
//! Ultra-low latency storage tier using RAM-based caching.
//!
//! This module provides:
//! - Hot cache for frequently accessed accounts
//! - Tiered storage management (RAM → NVMe → Archive)
//! - Automatic data promotion and eviction
//! - Background writeback for durability
//!
//! Performance targets:
//! ┌────────────────────────────────────────────────────────────┐
//! │  Operation          │  RAM Cache  │  NVMe      │  Archive  │
//! ├────────────────────────────────────────────────────────────┤
//! │  Read latency       │  <1μs       │  50-100μs  │  10ms     │
//! │  Write latency      │  <1μs       │  N/A*      │  N/A*     │
//! │  Throughput (IOPS)  │  10M+       │  500K      │  10K      │
//! └────────────────────────────────────────────────────────────┘
//!  * Writes are async, latency is to RAM only
//!
//! Memory layout for tmpfs mount:
//! ```
//! /mnt/ramdisk/
//! ├── hot/              # Hot account data
//! │   ├── accounts.mmap # Memory-mapped account store
//! │   └── index.mmap    # Account index
//! ├── slots/            # Recent slot data
//! │   ├── 12345/        # Slot-specific data
//! │   └── 12346/
//! └── temp/             # Temporary working data
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const cache = @import("cache.zig");
pub const tiered = @import("tiered.zig");

pub const HotCache = cache.HotCache;
pub const CacheConfig = cache.CacheConfig;
pub const CacheEntry = cache.CacheEntry;
pub const CacheStats = cache.CacheStats;
pub const EvictionPolicy = cache.EvictionPolicy;

pub const TieredStorage = tiered.TieredStorage;
pub const TieredConfig = tiered.TieredConfig;
pub const TieredStats = tiered.TieredStats;
pub const AccountData = tiered.AccountData;
pub const AccountLocation = tiered.AccountLocation;
pub const Tier = tiered.Tier;

/// RamDisk manager for the entire validator
pub const RamdiskManager = struct {
    /// Tiered storage backend
    storage: TieredStorage,

    /// Ramdisk mount path
    mount_path: []const u8,

    /// Is using real tmpfs
    using_tmpfs: bool,

    /// Allocator
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: RamdiskConfig) !RamdiskManager {
        // Check if ramdisk path exists and is tmpfs
        const using_tmpfs = isTmpfs(config.mount_path);
        if (!using_tmpfs) {
            std.log.warn("RamDisk path {s} is not tmpfs, performance will be degraded", .{config.mount_path});
        }

        // Set up tiered storage
        var tiered_config = config.tiered_config;
        tiered_config.ram_config.ramdisk_path = config.mount_path;

        return .{
            .storage = try TieredStorage.init(allocator, tiered_config),
            .mount_path = config.mount_path,
            .using_tmpfs = using_tmpfs,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RamdiskManager) void {
        self.storage.deinit();
    }

    /// Get account from any tier
    pub fn getAccount(self: *RamdiskManager, pubkey: *const [32]u8) !?AccountData {
        return self.storage.readAccount(pubkey);
    }

    /// Put account (writes to RAM, async flush to NVMe)
    pub fn putAccount(
        self: *RamdiskManager,
        pubkey: *const [32]u8,
        lamports: u64,
        data: []const u8,
        owner: *const [32]u8,
        executable: bool,
        rent_epoch: u64,
        slot: u64,
    ) !void {
        return self.storage.writeAccount(pubkey, lamports, data, owner, executable, rent_epoch, slot);
    }

    /// Force flush to durable storage
    pub fn flush(self: *RamdiskManager) !usize {
        return self.storage.flush();
    }

    /// Get combined statistics
    pub fn getStats(self: *RamdiskManager) RamdiskStats {
        const tiered_stats = self.storage.getStats();

        return .{
            .ram_cache_hits = tiered_stats.ram_hits,
            .ram_cache_misses = tiered_stats.ram_misses,
            .ram_cache_entries = tiered_stats.ram_entries,
            .ram_cache_bytes = tiered_stats.ram_bytes,
            .nvme_reads = tiered_stats.nvme_reads,
            .nvme_writes = tiered_stats.nvme_writes,
            .pending_writes = tiered_stats.pending_writebacks,
            .using_tmpfs = self.using_tmpfs,
        };
    }

    /// Check if path is tmpfs mounted
    fn isTmpfs(path: []const u8) bool {
        // On Linux, check /proc/mounts
        const mounts_file = std.fs.openFileAbsolute("/proc/mounts", .{}) catch return false;
        defer mounts_file.close();

        var buf: [4096]u8 = undefined;
        while (true) {
            const line = mounts_file.reader().readUntilDelimiter(&buf, '\n') catch break;

            // Parse mount line: device mountpoint fstype options
            var iter = std.mem.splitScalar(u8, line, ' ');
            _ = iter.next(); // device
            const mountpoint = iter.next() orelse continue;
            const fstype = iter.next() orelse continue;

            if (std.mem.eql(u8, mountpoint, path) and std.mem.eql(u8, fstype, "tmpfs")) {
                return true;
            }
        }

        return false;
    }
};

/// RamDisk configuration
pub const RamdiskConfig = struct {
    /// Path to ramdisk mount (should be tmpfs)
    mount_path: []const u8 = "/mnt/ramdisk",

    /// Tiered storage configuration
    tiered_config: TieredConfig = .{},
};

/// Combined statistics
pub const RamdiskStats = struct {
    ram_cache_hits: u64,
    ram_cache_misses: u64,
    ram_cache_entries: usize,
    ram_cache_bytes: usize,
    nvme_reads: u64,
    nvme_writes: u64,
    pending_writes: usize,
    using_tmpfs: bool,

    pub fn hitRate(self: *const RamdiskStats) f64 {
        const total = self.ram_cache_hits + self.ram_cache_misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.ram_cache_hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Setup helper to create tmpfs mount
pub fn setupTmpfsMount(path: []const u8, size_gb: usize) !void {
    // This would typically be done by a setup script, but we can attempt it
    const size_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}G", .{size_gb}) catch return;
    defer std.heap.page_allocator.free(size_str);

    // Try to create mount point
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Note: Actual mounting requires root privileges
    std.log.info("RamDisk setup: please mount tmpfs at {s} with:", .{path});
    std.log.info("  sudo mount -t tmpfs -o size={s} tmpfs {s}", .{ size_str, path });
}

// ============================================================================
// Tests
// ============================================================================

test "RamdiskManager: basic init" {
    const allocator = std.testing.allocator;

    var manager = try RamdiskManager.init(allocator, .{
        .mount_path = "/tmp/vexor-test-ramdisk",
        .tiered_config = .{
            .async_writeback = false,
        },
    });
    defer manager.deinit();

    const stats = manager.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.ram_cache_hits);
}

test "RamdiskManager: put and get" {
    const allocator = std.testing.allocator;

    var manager = try RamdiskManager.init(allocator, .{
        .mount_path = "/tmp/vexor-test-ramdisk",
        .tiered_config = .{
            .async_writeback = false,
        },
    });
    defer manager.deinit();

    const pubkey = [_]u8{42} ** 32;
    const owner = [_]u8{1} ** 32;
    const data = "account data here";

    try manager.putAccount(&pubkey, 5000, data, &owner, false, 123, 1000);

    const account = try manager.getAccount(&pubkey);
    try std.testing.expect(account != null);
    try std.testing.expectEqual(@as(u64, 5000), account.?.lamports);
}

test "imports compile" {
    _ = cache;
    _ = tiered;
}

