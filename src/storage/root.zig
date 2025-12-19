//! Vexor Storage Module
//!
//! Tiered storage architecture for optimal performance:
//! - Tier 0: RAM disk (tmpfs) - Hot data, < 1μs access
//! - Tier 1: NVMe SSD - Warm data, < 100μs access
//! - Tier 2: Archive - Cold data, milliseconds access
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────┐
//! │                    STORAGE LAYER                        │
//! ├──────────────┬──────────────┬───────────────────────────┤
//! │  ACCOUNTS DB │   BLOCKSTORE │      SNAPSHOTS            │
//! │  ──────────  │   ────────── │      ─────────            │
//! │  Hot cache   │   Shreds     │      Full/Incremental     │
//! │  AppendVec   │   Slots      │      Compression          │
//! │  Index       │   Repair     │      Streaming            │
//! └──────────────┴──────────────┴───────────────────────────┘

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const accounts = @import("accounts.zig");
pub const ledger = @import("ledger.zig");
pub const blockstore = @import("blockstore.zig");
pub const snapshot = @import("snapshot.zig");
pub const accounts_index = @import("accounts_index.zig");
pub const parallel_download = @import("parallel_download.zig");
pub const async_io = @import("async_io.zig");
pub const streaming_decompress = @import("streaming_decompress.zig");

// Conditional RAM disk support (tiered hot cache)
pub const ramdisk = if (build_options.ramdisk_enabled)
    @import("ramdisk/root.zig")
else
    @import("ramdisk_stub.zig");

// RamDisk types (conditionally exported)
pub const HotCache = if (build_options.ramdisk_enabled)
    ramdisk.HotCache
else
    void;
pub const TieredStorage = if (build_options.ramdisk_enabled)
    ramdisk.TieredStorage
else
    void;

// Re-exports
pub const AccountsDb = accounts.AccountsDb;
pub const Blockstore = blockstore.Blockstore;
pub const LedgerDb = ledger.LedgerDb;
pub const SlotMeta = ledger.SlotMeta;
pub const SnapshotManager = snapshot.SnapshotManager;
pub const SnapshotInfo = snapshot.SnapshotInfo;
pub const AccountsIndex = accounts_index.AccountsIndex;

// Fast catch-up: Parallel multi-source snapshot download
pub const ParallelDownloader = parallel_download.ParallelDownloader;
pub const SnapshotPeer = parallel_download.SnapshotPeer;
pub const DownloadProgress = parallel_download.DownloadProgress;

// Async I/O: io_uring-based non-blocking file operations
pub const AsyncIoManager = async_io.AsyncIoManager;
pub const AsyncFileWriter = async_io.AsyncFileWriter;
pub const BatchIoQueue = async_io.BatchIoQueue;

// Streaming decompression for pipelined snapshot loading
pub const StreamingDecompressor = streaming_decompress.StreamingDecompressor;
pub const CompressionType = streaming_decompress.CompressionType;
pub const DecompressProgress = streaming_decompress.DecompressProgress;

/// Storage tier enumeration
pub const StorageTier = enum {
    /// RAM disk - fastest, volatile
    tier0_ramdisk,
    /// NVMe SSD - fast, persistent
    tier1_nvme,
    /// Archive storage - cold data
    tier2_archive,

    pub fn basePath(self: StorageTier, config: anytype) []const u8 {
        return switch (self) {
            .tier0_ramdisk => config.ramdisk_path orelse "/mnt/ramdisk",
            .tier1_nvme => config.ledger_path,
            .tier2_archive => "/archive", // TODO: Make configurable
        };
    }
};

/// Storage manager coordinating all storage components
pub const StorageManager = struct {
    allocator: std.mem.Allocator,
    accounts_db: ?*AccountsDb = null,
    ledger_db: ?*LedgerDb = null,
    blockstore_instance: ?*Blockstore = null,
    snapshot_manager: ?*SnapshotManager = null,
    ramdisk_manager: ?*ramdisk.RamdiskManager = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: anytype) !*Self {
        const manager = try allocator.create(Self);

        manager.* = .{
            .allocator = allocator,
            .accounts_db = try AccountsDb.init(allocator, config.accounts_path),
            .ledger_db = try LedgerDb.init(allocator, config.ledger_path),
            .blockstore_instance = try Blockstore.init(allocator, config.ledger_path),
            .snapshot_manager = null,
            .ramdisk_manager = null,
        };

        // Initialize RAM disk if enabled
        if (build_options.ramdisk_enabled and config.enable_ramdisk) {
            if (config.ramdisk_path) |path| {
                const rm = try allocator.create(ramdisk.RamdiskManager);
                rm.* = try ramdisk.RamdiskManager.init(
                    allocator,
                    .{
                        .mount_path = path,
                        .tiered_config = .{
                            .ram_config = .{
                                .max_memory = config.ramdisk_size_gb * 1024 * 1024 * 1024,
                            },
                        },
                    },
                );
                manager.ramdisk_manager = rm;
            }
        }

        return manager;
    }

    pub fn deinit(self: *Self) void {
        if (self.ramdisk_manager) |rm| rm.deinit();
        if (self.snapshot_manager) |sm| sm.deinit();
        if (self.blockstore_instance) |bs| bs.deinit();
        if (self.ledger_db) |ldb| ldb.deinit();
        if (self.accounts_db) |adb| adb.deinit();
        self.allocator.destroy(self);
    }

    /// Get optimal storage tier for data type
    pub fn tierForDataType(data_type: DataType) StorageTier {
        return switch (data_type) {
            .hot_accounts => .tier0_ramdisk,
            .recent_slots => .tier0_ramdisk,
            .accounts_index => .tier1_nvme,
            .shreds => .tier1_nvme,
            .old_slots => .tier2_archive,
        };
    }

    pub const DataType = enum {
        hot_accounts,
        recent_slots,
        accounts_index,
        shreds,
        old_slots,
    };
};

test {
    std.testing.refAllDecls(@This());
}

