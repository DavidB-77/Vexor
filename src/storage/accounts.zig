//! Vexor Accounts Database
//!
//! High-performance accounts storage with:
//! - Memory-mapped append vectors
//! - Concurrent access via fine-grained locking
//! - Efficient hash computation for snapshots

const std = @import("std");
const core = @import("../core/root.zig");
const mem_alloc = @import("../core/allocator.zig");
const build_options = @import("build_options");
const vexstore = @import("vexstore.zig");
const async_io = @import("async_io.zig");

/// Account data structure
pub const Account = struct {
    lamports: u64,
    owner: core.Pubkey,
    executable: bool,
    rent_epoch: core.Epoch,
    data: []const u8,

    pub fn dataLen(self: *const Account) usize {
        return self.data.len;
    }

    pub fn isExecutable(self: *const Account) bool {
        return self.executable;
    }

    pub fn isNative(self: *const Account) bool {
        // Native programs have specific owner
        return self.executable and self.owner.data[0] == 0;
    }
};

/// Zero-copy account view from storage
pub const AccountView = struct {
    lamports: u64,
    owner: core.Pubkey,
    executable: bool,
    rent_epoch: core.Epoch,
    data: []const u8,
};

fn accountViewFromOwned(account: *const Account) AccountView {
    return .{
        .lamports = account.lamports,
        .owner = account.owner,
        .executable = account.executable,
        .rent_epoch = account.rent_epoch,
        .data = account.data,
    };
}

fn serializeAccount(allocator: std.mem.Allocator, account: *const Account) ![]u8 {
    const header_len: usize = 8 + 32 + 1 + 8 + 4;
    const total = header_len + account.data.len;
    var buf = try allocator.alloc(u8, total);
    var offset: usize = 0;

    std.mem.writeInt(u64, buf[offset..][0..8], account.lamports, .little);
    offset += 8;
    @memcpy(buf[offset..][0..32], &account.owner.data);
    offset += 32;
    buf[offset] = if (account.executable) 1 else 0;
    offset += 1;
    std.mem.writeInt(u64, buf[offset..][0..8], account.rent_epoch, .little);
    offset += 8;
    std.mem.writeInt(u32, buf[offset..][0..4], @intCast(account.data.len), .little);
    offset += 4;
    @memcpy(buf[offset..][0..account.data.len], account.data);

    return buf;
}

fn serializeAccountView(allocator: std.mem.Allocator, account: *const AccountView) ![]u8 {
    const header_len: usize = 8 + 32 + 1 + 8 + 4;
    const total = header_len + account.data.len;
    var buf = try allocator.alloc(u8, total);
    var offset: usize = 0;

    std.mem.writeInt(u64, buf[offset..][0..8], account.lamports, .little);
    offset += 8;
    @memcpy(buf[offset..][0..32], &account.owner.data);
    offset += 32;
    buf[offset] = if (account.executable) 1 else 0;
    offset += 1;
    std.mem.writeInt(u64, buf[offset..][0..8], account.rent_epoch, .little);
    offset += 8;
    std.mem.writeInt(u32, buf[offset..][0..4], @intCast(account.data.len), .little);
    offset += 4;
    @memcpy(buf[offset..][0..account.data.len], account.data);

    return buf;
}

/// Bulk load buffer for snapshot loading
/// Uses heap allocation instead of mmap to avoid thousands of 64MB mmap regions
pub const BulkLoadBuffer = struct {
    allocator: std.mem.Allocator,
    lock: std.Thread.RwLock,
    /// Account data stored as pubkey -> (lamports, owner, executable, rent_epoch, data)
    accounts: std.AutoHashMap(core.Pubkey, StoredAccount),
    /// Total accounts stored
    count: u64,

    const StoredAccount = struct {
        lamports: u64,
        owner: core.Pubkey,
        executable: bool,
        rent_epoch: u64,
        data: []u8, // Heap allocated copy
    };

    pub fn init(allocator: std.mem.Allocator) !*BulkLoadBuffer {
        const self = try allocator.create(BulkLoadBuffer);
        self.* = .{
            .allocator = allocator,
            .lock = .{},
            .accounts = std.AutoHashMap(core.Pubkey, StoredAccount).init(allocator),
            .count = 0,
        };
        return self;
    }

    pub fn deinit(self: *BulkLoadBuffer) void {
        // Free all stored account data
        var iter = self.accounts.valueIterator();
        while (iter.next()) |stored| {
            if (stored.data.len > 0) {
                self.allocator.free(stored.data);
            }
        }
        self.accounts.deinit();
        self.allocator.destroy(self);
    }

    pub fn store(self: *BulkLoadBuffer, pubkey: *const core.Pubkey, account: *const Account) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Copy account data to heap
        const data_copy = if (account.data.len > 0)
            try self.allocator.dupe(u8, account.data)
        else
            &[_]u8{};

        // Remove old data if exists
        if (self.accounts.get(pubkey.*)) |old| {
            if (old.data.len > 0) {
                self.allocator.free(old.data);
            }
        }

        try self.accounts.put(pubkey.*, .{
            .lamports = account.lamports,
            .owner = account.owner,
            .executable = account.executable,
            .rent_epoch = account.rent_epoch,
            .data = data_copy,
        });
        self.count += 1;
    }

    pub fn get(self: *BulkLoadBuffer, pubkey: *const core.Pubkey) ?AccountView {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.accounts.get(pubkey.*)) |stored| {
            return AccountView{
                .lamports = stored.lamports,
                .owner = stored.owner,
                .executable = stored.executable,
                .rent_epoch = stored.rent_epoch,
                .data = stored.data,
            };
        }
        return null;
    }
};

/// Main accounts database
pub const AccountsDb = struct {
    allocator: std.mem.Allocator,
    metadata_lock: std.Thread.Mutex, // Protects slot, stats, and metadata
    accounts_path: []const u8,
    /// Account index: pubkey -> location
    index: AccountIndex,
    /// Storage for account data
    storage: AccountStorage,
    /// Optional VexStore shadow backend
    vexstore_shadow: ?*vexstore.VexStore,
    shadow_compare_enabled: bool,
    shadow_compare_reads: u64,
    shadow_compare_missing: u64,
    shadow_compare_mismatch: u64,
    shadow_compare_rate: u64,
    shadow_compare_counter: u64,
    shadow_compare_mismatch_threshold: u64,
    shadow_compare_missing_threshold: u64,
    shadow_compare_stats_path: ?[]u8,
    shadow_compare_time_enabled: bool,
    shadow_compare_window_ms: u64,
    shadow_compare_period_ms: u64,
    shadow_compare_next_window_ms: u64,
    shadow_compare_window_end_ms: u64,
    shadow_compare_fail_closed: bool,
    shadow_compare_error: ?[]u8,
    shadow_compare_last_mismatch_ms: u64,
    shadow_compare_last_missing_ms: u64,
    shadow_compare_promote_ms: u64,
    shadow_compare_stats_rotate: u32,
    shadow_compare_stats_seq: u64,
    shadow_primary_enabled: bool,
    shadow_primary_force: bool,
    shadow_primary_disabled: bool,
    shadow_primary_mismatch_max: u64,
    shadow_primary_cache: ShadowAccountCache,
    shadow_primary_reads: u64,
    shadow_primary_hits: u64,
    shadow_primary_fallbacks: u64,
    shadow_compact_enabled: bool,
    shadow_compact_deleted_threshold: u64,
    shadow_compact_dead_bytes_threshold: u64,
    shadow_compact_ratio_percent: u32,
    shadow_compact_batch: usize,
    accounts_shrink_enabled: bool,
    accounts_shrink_ratio_percent: u32,
    accounts_shrink_min_bytes: u64,
    accounts_shrink_hysteresis_percent: u32,
    accounts_shrink_last_slot: core.Slot,
    accounts_stats_enabled: bool,
    accounts_stats_interval_ms: u64,
    accounts_stats_last_ms: u64,
    accounts_purge_enabled: bool,
    accounts_purge_age_slots: u64,
    accounts_clean_enabled: bool,
    accounts_clean_age_slots: u64,
    accounts_clean_last_slot: core.Slot,
    accounts_stats_top_n: usize,
    accounts_completed_max_slot: core.Slot,
    accounts_safe_lag_slots: u64,
    accounts_gc_slots: std.ArrayList(core.Slot),
    accounts_gc_cursor: usize,
    accounts_gc_batch: usize,
    accounts_gc_scan_interval_ms: u64,
    accounts_gc_last_scan_ms: u64,
    accounts_store_capacity_bytes: u64,
    /// Cache of recently accessed accounts
    cache: AccountCache,
    /// Current slot being processed
    slot: std.atomic.Value(u64),
    /// Bulk loading mode - skips AppendVec storage, stores only in index
    /// Used during snapshot loading to avoid creating thousands of mmap'd files
    bulk_loading_mode: bool,
    /// Bulk loading buffer - heap allocated storage for accounts during bulk load
    bulk_buffer: ?*BulkLoadBuffer,
    /// L1 RAM cache — accounts promoted from Bank.pending_writes during freeze().
    /// Protected by RwLock: getAccount() takes shared, promoteToUnflushedCache() takes exclusive.
    unflushed_cache: std.AutoHashMap(core.Pubkey, Account),
    unflushed_cache_lock: std.Thread.Mutex,
    /// Dedicated arena for L1 cache allocations — backed by page_allocator,
    /// completely isolated from the potentially corrupted AccountsDb allocator.
    cache_arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8, async_io_manager: ?*async_io.AsyncIoManager) !*Self {
        const db = try allocator.create(Self);
        var shadow: ?*vexstore.VexStore = null;
        var shadow_compare_enabled = false;
        var shadow_compact_enabled = false;
        var shadow_compact_deleted_threshold: u64 = 1000;
        var shadow_compact_dead_bytes_threshold: u64 = 1 * 1024 * 1024;
        var shadow_compact_ratio_percent: u32 = 150;
        var shadow_compact_batch: usize = 128;
        var shadow_compare_mismatch_threshold: u64 = std.math.maxInt(u64);
        var shadow_compare_missing_threshold: u64 = std.math.maxInt(u64);
        var shadow_compare_stats_path: ?[]u8 = null;
        var shadow_compare_rate: u64 = 1;
        var shadow_compare_time_enabled = false;
        var shadow_compare_window_ms: u64 = 5000;
        var shadow_compare_period_ms: u64 = 60000;
        var shadow_compare_fail_closed = false;
        var shadow_compare_promote_ms: u64 = 300_000;
        var shadow_compare_stats_rotate: u32 = 0;
        var shadow_primary_enabled = false;
        var shadow_primary_force = false;
        var shadow_primary_mismatch_max: u64 = std.math.maxInt(u64);
        var accounts_shrink_enabled = false;
        var accounts_shrink_ratio_percent: u32 = 50;
        var accounts_shrink_min_bytes: u64 = 8 * 1024 * 1024;
        var accounts_shrink_hysteresis_percent: u32 = 5;
        var accounts_stats_enabled = false;
        var accounts_stats_interval_ms: u64 = 10_000;
        var accounts_purge_enabled = false;
        var accounts_purge_age_slots: u64 = 1024;
        var accounts_clean_enabled = false;
        var accounts_clean_age_slots: u64 = 64;
        var accounts_stats_top_n: usize = 3;
        var accounts_index_bin_capacity: usize = 0;
        var accounts_safe_lag_slots: u64 = 32;
        var accounts_gc_batch: usize = 2;
        var accounts_gc_scan_interval_ms: u64 = 30_000;
        var accounts_store_capacity_bytes: u64 = 64 * 1024 * 1024;
        if (build_options.vexstore_shadow_enabled) {
            const shadow_path = try std.fmt.allocPrint(allocator, "{s}/vexstore", .{path});
            defer allocator.free(shadow_path);
            shadow = try vexstore.VexStore.init(allocator, shadow_path, async_io_manager);
            const compare = std.process.getEnvVarOwned(allocator, "VEXSTORE_SHADOW_COMPARE") catch null;
            if (compare) |value| {
                defer allocator.free(value);
                shadow_compare_enabled = std.mem.eql(u8, value, "1");
            }
            const compact = std.process.getEnvVarOwned(allocator, "VEXSTORE_COMPACT_ENABLE") catch null;
            if (compact) |value| {
                defer allocator.free(value);
                shadow_compact_enabled = std.mem.eql(u8, value, "1");
            }
            shadow_compact_deleted_threshold = parseEnvU64(
                allocator,
                "VEXSTORE_COMPACT_DELETED",
                shadow_compact_deleted_threshold,
            ) catch shadow_compact_deleted_threshold;
            shadow_compact_dead_bytes_threshold = parseEnvU64(
                allocator,
                "VEXSTORE_COMPACT_DEAD_BYTES",
                shadow_compact_dead_bytes_threshold,
            ) catch shadow_compact_dead_bytes_threshold;
            shadow_compact_ratio_percent = @intCast(parseEnvU64(
                allocator,
                "VEXSTORE_COMPACT_RATIO",
                shadow_compact_ratio_percent,
            ) catch shadow_compact_ratio_percent);
            shadow_compact_batch = @intCast(parseEnvU64(
                allocator,
                "VEXSTORE_COMPACT_BATCH",
                shadow_compact_batch,
            ) catch shadow_compact_batch);
            shadow_compare_mismatch_threshold = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_MISMATCH_MAX",
                shadow_compare_mismatch_threshold,
            ) catch shadow_compare_mismatch_threshold;
            shadow_compare_missing_threshold = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_MISSING_MAX",
                shadow_compare_missing_threshold,
            ) catch shadow_compare_missing_threshold;
            const stats_path = std.process.getEnvVarOwned(allocator, "VEXSTORE_SHADOW_STATS_PATH") catch null;
            if (stats_path) |value| {
                shadow_compare_stats_path = value;
            }
            shadow_compare_stats_rotate = @intCast(parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_STATS_ROTATE",
                shadow_compare_stats_rotate,
            ) catch shadow_compare_stats_rotate);
            shadow_compare_rate = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_COMPARE_RATE",
                shadow_compare_rate,
            ) catch shadow_compare_rate;
            if (shadow_compare_rate == 0) shadow_compare_rate = 1;
            shadow_compare_window_ms = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_COMPARE_WINDOW_MS",
                shadow_compare_window_ms,
            ) catch shadow_compare_window_ms;
            shadow_compare_period_ms = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_COMPARE_PERIOD_MS",
                shadow_compare_period_ms,
            ) catch shadow_compare_period_ms;
            shadow_compare_time_enabled = shadow_compare_window_ms > 0 and shadow_compare_period_ms > 0;
            {
                const fail_closed = std.process.getEnvVarOwned(allocator, "VEXSTORE_SHADOW_FAIL_CLOSED") catch null;
                if (fail_closed) |value| {
                    defer allocator.free(value);
                    shadow_compare_fail_closed = std.mem.eql(u8, value, "1");
                }
            }
            shadow_compare_promote_ms = parseEnvU64(
                allocator,
                "VEXSTORE_SHADOW_PROMOTE_MS",
                shadow_compare_promote_ms,
            ) catch shadow_compare_promote_ms;
            {
                const primary_enabled = std.process.getEnvVarOwned(allocator, "VEXSTORE_PRIMARY_ENABLE") catch null;
                if (primary_enabled) |value| {
                    defer allocator.free(value);
                    shadow_primary_enabled = std.mem.eql(u8, value, "1");
                }
            }
            {
                const primary_force = std.process.getEnvVarOwned(allocator, "VEXSTORE_PRIMARY_FORCE") catch null;
                if (primary_force) |value| {
                    defer allocator.free(value);
                    shadow_primary_force = std.mem.eql(u8, value, "1");
                }
            }
            shadow_primary_mismatch_max = parseEnvU64(
                allocator,
                "VEXSTORE_PRIMARY_MISMATCH_MAX",
                shadow_primary_mismatch_max,
            ) catch shadow_primary_mismatch_max;
        }
        {
            const shrink_enabled = std.process.getEnvVarOwned(allocator, "VEXOR_ACCOUNTS_SHRINK_ENABLE") catch null;
            if (shrink_enabled) |value| {
                defer allocator.free(value);
                accounts_shrink_enabled = std.mem.eql(u8, value, "1");
            }
            accounts_shrink_ratio_percent = @intCast(parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_SHRINK_RATIO",
                accounts_shrink_ratio_percent,
            ) catch accounts_shrink_ratio_percent);
            accounts_shrink_min_bytes = parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_SHRINK_MIN_BYTES",
                accounts_shrink_min_bytes,
            ) catch accounts_shrink_min_bytes;
            accounts_shrink_hysteresis_percent = @intCast(parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_SHRINK_HYSTERESIS",
                accounts_shrink_hysteresis_percent,
            ) catch accounts_shrink_hysteresis_percent);
        }
        {
            const stats_enabled = std.process.getEnvVarOwned(allocator, "VEXOR_ACCOUNTS_STATS_ENABLE") catch null;
            if (stats_enabled) |value| {
                defer allocator.free(value);
                accounts_stats_enabled = std.mem.eql(u8, value, "1");
            }
            accounts_stats_interval_ms = parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_STATS_INTERVAL_MS",
                accounts_stats_interval_ms,
            ) catch accounts_stats_interval_ms;
            accounts_stats_top_n = @intCast(parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_STATS_TOP_N",
                accounts_stats_top_n,
            ) catch accounts_stats_top_n);
        }
        {
            const purge_enabled = std.process.getEnvVarOwned(allocator, "VEXOR_ACCOUNTS_PURGE_ENABLE") catch null;
            if (purge_enabled) |value| {
                defer allocator.free(value);
                accounts_purge_enabled = std.mem.eql(u8, value, "1");
            }
            accounts_purge_age_slots = parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_PURGE_AGE_SLOTS",
                accounts_purge_age_slots,
            ) catch accounts_purge_age_slots;
        }
        {
            const clean_enabled = std.process.getEnvVarOwned(allocator, "VEXOR_ACCOUNTS_CLEAN_ENABLE") catch null;
            if (clean_enabled) |value| {
                defer allocator.free(value);
                accounts_clean_enabled = std.mem.eql(u8, value, "1");
            }
            accounts_clean_age_slots = parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_CLEAN_AGE_SLOTS",
                accounts_clean_age_slots,
            ) catch accounts_clean_age_slots;
        }
        accounts_index_bin_capacity = @intCast(parseEnvU64(
            allocator,
            "VEXOR_ACCOUNTS_INDEX_BIN_CAPACITY",
            accounts_index_bin_capacity,
        ) catch accounts_index_bin_capacity);
        accounts_safe_lag_slots = parseEnvU64(
            allocator,
            "VEXOR_ACCOUNTS_SAFE_LAG_SLOTS",
            accounts_safe_lag_slots,
        ) catch accounts_safe_lag_slots;
        accounts_gc_batch = @intCast(parseEnvU64(
            allocator,
            "VEXOR_ACCOUNTS_GC_BATCH",
            accounts_gc_batch,
        ) catch accounts_gc_batch);
        accounts_gc_scan_interval_ms = parseEnvU64(
            allocator,
            "VEXOR_ACCOUNTS_GC_SCAN_INTERVAL_MS",
            accounts_gc_scan_interval_ms,
        ) catch accounts_gc_scan_interval_ms;
        {
            const mb = parseEnvU64(
                allocator,
                "VEXOR_ACCOUNTS_STORE_CAPACITY_MB",
                accounts_store_capacity_bytes / (1024 * 1024),
            ) catch accounts_store_capacity_bytes / (1024 * 1024);
            accounts_store_capacity_bytes = @max(@as(u64, 1), mb) * 1024 * 1024;
        }
        const accounts_path_copy = try allocator.dupe(u8, path);
        db.* = .{
            .allocator = allocator,
            .metadata_lock = .{},
            .accounts_path = accounts_path_copy,
            .index = AccountIndex.initWithCapacity(allocator, accounts_index_bin_capacity),
            .storage = try AccountStorage.init(allocator, path, accounts_store_capacity_bytes),
            .cache = AccountCache.init(allocator),
            .slot = std.atomic.Value(u64).init(0),
            .vexstore_shadow = shadow,
            .shadow_compare_enabled = shadow_compare_enabled,
            .shadow_compare_reads = 0,
            .shadow_compare_missing = 0,
            .shadow_compare_mismatch = 0,
            .shadow_compare_rate = shadow_compare_rate,
            .shadow_compare_counter = 0,
            .shadow_compare_mismatch_threshold = shadow_compare_mismatch_threshold,
            .shadow_compare_missing_threshold = shadow_compare_missing_threshold,
            .shadow_compare_stats_path = shadow_compare_stats_path,
            .shadow_compare_time_enabled = shadow_compare_time_enabled,
            .shadow_compare_window_ms = shadow_compare_window_ms,
            .shadow_compare_period_ms = shadow_compare_period_ms,
            .shadow_compare_next_window_ms = 0,
            .shadow_compare_window_end_ms = 0,
            .shadow_compare_fail_closed = shadow_compare_fail_closed,
            .shadow_compare_error = null,
            .shadow_compare_last_mismatch_ms = 0,
            .shadow_compare_last_missing_ms = 0,
            .shadow_compare_promote_ms = shadow_compare_promote_ms,
            .shadow_compare_stats_rotate = shadow_compare_stats_rotate,
            .shadow_compare_stats_seq = 0,
            .shadow_primary_enabled = shadow_primary_enabled,
            .shadow_primary_force = shadow_primary_force,
            .shadow_primary_disabled = false,
            .shadow_primary_mismatch_max = shadow_primary_mismatch_max,
            .shadow_primary_cache = ShadowAccountCache.init(allocator),
            .shadow_primary_reads = 0,
            .shadow_primary_hits = 0,
            .shadow_primary_fallbacks = 0,
            .shadow_compact_enabled = shadow_compact_enabled,
            .shadow_compact_deleted_threshold = shadow_compact_deleted_threshold,
            .shadow_compact_dead_bytes_threshold = shadow_compact_dead_bytes_threshold,
            .shadow_compact_ratio_percent = shadow_compact_ratio_percent,
            .shadow_compact_batch = shadow_compact_batch,
            .accounts_shrink_enabled = accounts_shrink_enabled,
            .accounts_shrink_ratio_percent = accounts_shrink_ratio_percent,
            .accounts_shrink_min_bytes = accounts_shrink_min_bytes,
            .accounts_shrink_hysteresis_percent = accounts_shrink_hysteresis_percent,
            .accounts_shrink_last_slot = 0,
            .accounts_stats_enabled = accounts_stats_enabled,
            .accounts_stats_interval_ms = accounts_stats_interval_ms,
            .accounts_stats_last_ms = 0,
            .accounts_purge_enabled = accounts_purge_enabled,
            .accounts_purge_age_slots = accounts_purge_age_slots,
            .accounts_clean_enabled = accounts_clean_enabled,
            .accounts_clean_age_slots = accounts_clean_age_slots,
            .accounts_clean_last_slot = 0,
            .accounts_stats_top_n = accounts_stats_top_n,
            .accounts_completed_max_slot = 0,
            .accounts_safe_lag_slots = accounts_safe_lag_slots,
            .accounts_gc_slots = std.ArrayList(core.Slot).init(allocator),
            .accounts_gc_cursor = 0,
            .accounts_gc_batch = accounts_gc_batch,
            .accounts_gc_scan_interval_ms = accounts_gc_scan_interval_ms,
            .accounts_gc_last_scan_ms = 0,
            .accounts_store_capacity_bytes = accounts_store_capacity_bytes,
            .bulk_loading_mode = false,
            .bulk_buffer = null,
            .cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .unflushed_cache = undefined, // initialized below
            .unflushed_cache_lock = .{},
        };
        // Initialize unflushed_cache with the dedicated arena allocator (uncorrupted)
        db.unflushed_cache = std.AutoHashMap(core.Pubkey, Account).init(db.cache_arena.allocator());

        if (build_options.vexstore_shadow_enabled) {
            const enabled = std.process.getEnvVarOwned(allocator, "VEXSTORE_SHADOW_SELFTEST") catch null;
            if (enabled) |value| {
                defer allocator.free(value);
                if (std.mem.eql(u8, value, "1")) {
                    try db.shadowSelfTest();
                }
            }
        }
        return db;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.accounts_path);
        if (self.shadow_compare_stats_path) |path| {
            self.allocator.free(path);
        }
        if (self.shadow_compare_error) |msg| {
            self.allocator.free(msg);
        }
        self.shadow_primary_cache.deinit();
        if (self.vexstore_shadow) |vs| {
            vs.deinit();
        }
        self.cache.deinit();
        self.accounts_gc_slots.deinit();
        self.storage.deinit();
        self.index.deinit();
        self.allocator.destroy(self);
    }

    /// Get an account by pubkey
    pub fn getAccount(self: *Self, pubkey: *const core.Pubkey) ?AccountView {
        // L1: Check unflushed RAM cache first (accounts from recent freeze() calls)
        {
            self.unflushed_cache_lock.lock();
            defer self.unflushed_cache_lock.unlock();
            if (self.unflushed_cache.get(pubkey.*)) |account| {
                return accountViewFromOwned(&account);
            }
        }

        if (self.isShadowPrimaryActive()) {
            self.metadata_lock.lock();
            self.shadow_primary_reads += 1;
            self.metadata_lock.unlock();

            if (self.getAccountFromShadow(pubkey)) |account| {
                self.metadata_lock.lock();
                self.shadow_primary_hits += 1;
                self.metadata_lock.unlock();
                return account;
            }

            self.metadata_lock.lock();
            self.shadow_primary_fallbacks += 1;
            self.metadata_lock.unlock();
        }
        // Check bulk buffer first if in bulk loading mode
        if (self.bulk_buffer) |buf| {
            if (buf.get(pubkey)) |account| {
                return account;
            }
        }

        // Check cache first
        if (self.cache.get(pubkey)) |cached| {
            if (self.shadow_compare_enabled) {
                self.shadowCompare(pubkey, cached) catch {};
            }
            return cached;
        }

        // Look up in index
        if (self.index.get(pubkey)) |location| {
            const account = self.storage.readAccount(location) orelse return null;
            if (self.shadow_compare_enabled) {
                self.shadowCompare(pubkey, account) catch {};
            }
            _ = self.cache.insert(pubkey, account) catch {};
            return account;
        }

        return null;
    }

    /// Promote pending_writes from a frozen Bank into the shared L1 RAM cache.
    /// Deep-copies account data so the cache owns the memory independently of the Bank.
    /// Thread-safe: acquires exclusive write lock on unflushed_cache.
    pub fn promoteToUnflushedCache(self: *Self, pending_writes: []const AccountWrite) !void {
        self.unflushed_cache_lock.lock();
        defer self.unflushed_cache_lock.unlock();

        const arena_alloc = self.cache_arena.allocator();

        for (pending_writes) |*write| {
            // Deep copy account data using the dedicated cache arena (uncorrupted)
            const owned_data = if (write.account.data.len > 0) blk: {
                const copy = try arena_alloc.alloc(u8, write.account.data.len);
                @memcpy(copy, write.account.data);
                break :blk copy;
            } else &[_]u8{};

            // Note: ArenaAllocator doesn't support individual frees, so we skip
            // freeing old data. The arena will be bulk-freed when slots are rooted.

            // Explicit error propagation — no silent swallowing
            try self.unflushed_cache.put(write.pubkey, .{
                .lamports = write.account.lamports,
                .owner = write.account.owner,
                .executable = write.account.executable,
                .rent_epoch = write.account.rent_epoch,
                .data = owned_data,
            });
        }
    }

    /// Store an account
    pub fn storeAccount(self: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot) !void {
        // Write to storage
        const location = try self.storage.writeAccount(pubkey, account, slot);

        // Update index
        try self.index.insert(pubkey, location);

        // Update cache
        if (self.storage.readAccount(location)) |stored| {
            try self.cache.insert(pubkey, stored);
        }

        if (self.vexstore_shadow) |vs| {
            // Write to VexStore if enabled (either shadow or primary)
            const encoded = try serializeAccount(self.allocator, account);
            defer self.allocator.free(encoded);
            try vs.put(pubkey.data, encoded);
        }
    }

    pub const AccountWrite = struct {
        pubkey: core.Pubkey,
        account: Account,
    };

    /// Store multiple accounts atomically (at index level)
    pub fn storeAccounts(self: *Self, accounts: []const AccountWrite, slot: core.Slot) !void {
        var batch_entries = try std.ArrayList(AccountIndex.BatchEntry).initCapacity(self.allocator, accounts.len);
        defer batch_entries.deinit();

        for (accounts) |*write| {
            // Write to storage
            const location = try self.storage.writeAccount(&write.pubkey, &write.account, slot);

            // Add to batch
            try batch_entries.append(.{
                .pubkey = write.pubkey,
                .location = location,
            });

            // Update cache
            if (self.storage.readAccount(location)) |stored| {
                try self.cache.insert(&write.pubkey, stored);
            }

            if (self.vexstore_shadow) |vs| {
                const encoded = try serializeAccount(self.allocator, &write.account);
                defer self.allocator.free(encoded);
                try vs.put(write.pubkey.data, encoded);
            }
        }

        // Atomic index update
        try self.index.upsertBatch(batch_entries.items);
    }

    /// Fast bulk store for snapshot loading - skips cache and shadow
    /// This is optimized for initial loading when we don't need caching
    /// Pre-serializes account data outside the lock for better throughput
    pub fn storeAccountBulk(self: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot) !void {
        // Serialize outside the lock (this is the expensive part)
        const data = try self.storage.serializeAccountToBytes(pubkey, account);
        defer self.allocator.free(data);

        // Write with minimal lock time
        const location = try self.storage.writeAccountBytes(data, slot);

        // Update index only - skip cache and shadow during bulk load
        try self.index.insert(pubkey, location);

        // VexStore bulk store path
        if (self.vexstore_shadow) |vs| {
            // If primary enabled, we MUST write to VexStore even during bulk load
            // serializeAccountToBytes format might need adaptation if VexStore expects different format
            // For now assuming we can serialize separately or reuse

            // Note: serializeAccountToBytes returns AppendVec format. VexStore usually takes bincode/custom.
            // We should use serializeAccount for VexStore safety.
            const encoded = try serializeAccount(self.allocator, account);
            defer self.allocator.free(encoded);
            try vs.put(pubkey.data, encoded);
        }
    }

    /// Bulk store with a REUSABLE buffer — zero-allocation hot path.
    /// The caller provides a persistent ArrayList(u8) that is cleared and reused
    /// for each account, eliminating heap thrashing during snapshot loading.
    pub fn storeAccountBulkReuse(self: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot, reuse_buf: *std.ArrayList(u8)) !void {
        // Serialize into the reusable buffer (no allocation unless it grows)
        reuse_buf.clearRetainingCapacity();
        try reuse_buf.appendSlice(&pubkey.data);
        try reuse_buf.writer().writeInt(u64, account.lamports, .little);
        try reuse_buf.appendSlice(&account.owner.data);
        try reuse_buf.append(@intFromBool(account.executable));
        try reuse_buf.writer().writeInt(u64, account.rent_epoch, .little);
        try reuse_buf.writer().writeInt(u32, @intCast(account.data.len), .little);
        try reuse_buf.appendSlice(account.data);

        // Write with retry — under 31-thread contention, AppendVecFull can
        // slip through even after writeAccountBytes' internal rotation.
        // A brief yield lets the storage layer create a new store.
        var location: AccountLocation = undefined;
        var retries: u32 = 0;
        while (retries < 3) : (retries += 1) {
            location = self.storage.writeAccountBytes(reuse_buf.items, slot) catch |err| {
                if (retries < 2) {
                    std.Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            break;
        }

        // Update index only - skip cache and shadow during bulk load
        try self.index.insert(pubkey, location);
    }

    /// Enable bulk loading mode - uses faster code paths for initial snapshot loading
    pub fn enableBulkLoading(self: *Self) void {
        self.bulk_loading_mode = true;
        self.storage.bulk_mode = true;
        // Pre-size the index for faster inserts
        // Typical testnet snapshot has ~600k accounts
        self.index.ensureCapacity(1_000_000) catch {};
    }

    /// Disable bulk loading mode and switch to normal operation
    pub fn disableBulkLoading(self: *Self) void {
        self.bulk_loading_mode = false;
        self.storage.bulk_mode = false;
    }

    /// Fast bulk store directly to VexStore - fastest path for snapshot loading
    /// Bypasses AppendVec entirely, writes key-value pairs directly to VexStore
    /// Uses putBulk which skips MemTable for O(1) inserts
    pub fn storeAccountBulkVexStore(self: *Self, pubkey: *const core.Pubkey, account: *const Account) !void {
        const vs = self.vexstore_shadow orelse return error.VexStoreNotAvailable;

        // Serialize account to bytes
        const encoded = try serializeAccount(self.allocator, account);
        defer self.allocator.free(encoded);

        // Write directly to VexStore using bulk path (skips MemTable, O(1) hash insert)
        try vs.putBulk(pubkey.data, encoded);

        // Note: No index update needed - VexStore maintains its own index
    }

    /// Pre-size VexStore index for bulk loading
    pub fn prepareVexStoreBulkLoad(self: *Self, expected_count: u32) !void {
        if (self.vexstore_shadow) |vs| {
            try vs.ensureIndexCapacity(expected_count);
        }
    }

    /// Check if VexStore is available for bulk loading
    pub fn hasVexStore(self: *Self) bool {
        return self.vexstore_shadow != null;
    }

    /// Flush VexStore after bulk loading
    pub fn flushVexStore(self: *Self) !void {
        if (self.vexstore_shadow) |vs| {
            try vs.flush();
        }
    }

    fn shadowSelfTest(self: *Self) !void {
        const vs = self.vexstore_shadow orelse return error.MissingShadowStore;
        const pubkey = core.Pubkey{ .data = [_]u8{0x5a} ** 32 };
        const owner = core.Pubkey{ .data = [_]u8{0xa5} ** 32 };
        const account = Account{
            .lamports = 123,
            .owner = owner,
            .executable = false,
            .rent_epoch = 9,
            .data = "vexstore-shadow-selftest",
        };
        try self.storeAccount(&pubkey, &account, 1);

        const got = try vs.get(pubkey.data) orelse return error.ShadowMissingValue;
        defer self.allocator.free(got);
        const expected = try serializeAccount(self.allocator, &account);
        defer self.allocator.free(expected);
        if (!std.mem.eql(u8, expected, got)) {
            return error.ShadowMismatch;
        }

        try vs.flush();
        const manifest = vs.dir.openFile("manifest", .{ .mode = .read_only }) catch return error.ShadowManifestMissing;
        defer manifest.close();
        const manifest_data = try manifest.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(manifest_data);
        if (manifest_data.len == 0) return error.ShadowManifestEmpty;

        std.debug.print("[ShadowTest] VexStore shadow write verified\n", .{});
    }

    pub fn tickShadowCompaction(self: *Self) !void {
        if (!self.shadow_compact_enabled) return;
        const vs = self.vexstore_shadow orelse return;

        if (vs.isCompacting()) {
            const done = try vs.compactValueLogIncremental(self.shadow_compact_batch);
            if (done) {
                std.log.info("[VexStore] compaction completed", .{});
            }
            return;
        }

        if (!self.shouldCompactShadow(vs)) return;
        std.log.info("[VexStore] compaction started", .{});
        const done = try vs.compactValueLogIncremental(self.shadow_compact_batch);
        if (done) {
            std.log.info("[VexStore] compaction completed", .{});
        }
    }

    fn shadowCompare(self: *Self, pubkey: *const core.Pubkey, account: AccountView) !void {
        const vs = self.vexstore_shadow orelse return;
        if (self.shadow_compare_time_enabled and !self.shadowCompareWindowActive()) {
            return;
        }
        if (self.shadow_compare_fail_closed and self.shadow_compare_error != null) {
            return error.ShadowCompareFailed;
        }

        self.metadata_lock.lock();
        self.shadow_compare_counter += 1;
        const skip = self.shadow_compare_rate > 1 and (self.shadow_compare_counter % self.shadow_compare_rate) != 0;
        if (!skip) self.shadow_compare_reads += 1;
        self.metadata_lock.unlock();

        if (skip) return;

        const got = try vs.get(pubkey.data) orelse {
            self.metadata_lock.lock();
            defer self.metadata_lock.unlock();
            self.shadow_compare_missing += 1;
            self.shadow_compare_last_missing_ms = @intCast(std.time.milliTimestamp());
            std.log.warn("[ShadowCompare] missing shadow entry", .{});
            self.recordShadowCompareError("missing shadow entry");
            return;
        };
        defer self.allocator.free(got);
        const expected = try serializeAccountView(self.allocator, &account);
        defer self.allocator.free(expected);
        if (!std.mem.eql(u8, expected, got)) {
            self.metadata_lock.lock();
            defer self.metadata_lock.unlock();
            self.shadow_compare_mismatch += 1;
            self.shadow_compare_last_mismatch_ms = @intCast(std.time.milliTimestamp());
            std.log.warn("[ShadowCompare] mismatch detected", .{});
            self.recordShadowCompareError("mismatch detected");
        }
        self.metadata_lock.lock();
        defer self.metadata_lock.unlock();
        self.checkShadowThresholds();
    }

    fn shouldCompactShadow(self: *Self, vs: *vexstore.VexStore) bool {
        if (vs.deletedCount() < self.shadow_compact_deleted_threshold) {
            if (vs.deadBytes() < self.shadow_compact_dead_bytes_threshold) return false;
        }
        const live_bytes = vs.liveBytes();
        const vlog_size = vs.vlog.getEndPos() catch return false;
        if (live_bytes == 0) return vlog_size > 0;
        const lhs: u128 = @as(u128, vlog_size) * 100;
        const rhs: u128 = @as(u128, live_bytes) * self.shadow_compact_ratio_percent;
        return lhs >= rhs;
    }

    fn parseEnvU64(allocator: std.mem.Allocator, name: []const u8, default_value: u64) !u64 {
        const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
        defer allocator.free(raw);
        return std.fmt.parseInt(u64, raw, 10);
    }

    pub fn logShadowCompareStats(self: *Self) void {
        if (!self.shadow_compare_enabled) return;
        std.log.info(
            "[ShadowCompare] reads={d} missing={d} mismatch={d} rate={d} window={d}/{d}ms promote={d}ms",
            .{
                self.shadow_compare_reads,
                self.shadow_compare_missing,
                self.shadow_compare_mismatch,
                self.shadow_compare_rate,
                self.shadow_compare_window_ms,
                self.shadow_compare_period_ms,
                self.shadow_compare_promote_ms,
            },
        );
        if (self.shadow_compare_stats_path) |path| {
            self.writeShadowStats(path) catch {};
        }
        self.checkShadowThresholds();
    }

    pub fn resetShadowCompareStats(self: *Self) void {
        self.shadow_compare_reads = 0;
        self.shadow_compare_missing = 0;
        self.shadow_compare_mismatch = 0;
        self.shadow_compare_counter = 0;
        self.shadow_compare_last_missing_ms = 0;
        self.shadow_compare_last_mismatch_ms = 0;
        if (self.shadow_compare_error) |msg| {
            self.allocator.free(msg);
        }
        self.shadow_compare_error = null;
        self.shadow_primary_disabled = false;
        self.shadow_primary_reads = 0;
        self.shadow_primary_hits = 0;
        self.shadow_primary_fallbacks = 0;
    }

    fn isShadowPrimaryActive(self: *Self) bool {
        self.metadata_lock.lock();
        defer self.metadata_lock.unlock();
        // If explicitly enabled via ENV, always active
        if (self.shadow_primary_enabled) return true;

        // Legacy shadow logic
        if (self.shadow_primary_disabled) return false;
        if (self.shadow_primary_force) return true;
        const stats = self.getShadowCompareStatsUnlocked();
        return stats.eligible;
    }

    fn getAccountFromShadow(self: *Self, pubkey: *const core.Pubkey) ?AccountView {
        if (self.shadow_primary_cache.get(pubkey)) |cached| {
            return accountViewFromOwned(cached);
        }
        const vs = self.vexstore_shadow orelse return null;
        const raw = (vs.get(pubkey.data) catch return null) orelse return null;
        defer self.allocator.free(raw);
        const account = deserializeAccount(self.allocator, raw) catch return null;
        self.shadow_primary_cache.insert(pubkey, account) catch {
            self.shadow_primary_cache.freeAccount(account);
            return null;
        };
        return accountViewFromOwned(account);
    }

    fn checkShadowThresholds(self: *Self) void {
        if (self.shadow_compare_mismatch > self.shadow_compare_mismatch_threshold) {
            std.log.warn("[ShadowCompare] mismatch threshold exceeded", .{});
            self.recordShadowCompareError("mismatch threshold exceeded");
        }
        if (self.shadow_compare_missing > self.shadow_compare_missing_threshold) {
            std.log.warn("[ShadowCompare] missing threshold exceeded", .{});
            self.recordShadowCompareError("missing threshold exceeded");
        }
        self.checkPrimaryFailover();
    }

    fn checkPrimaryFailover(self: *Self) void {
        if (!self.shadow_primary_enabled) return;
        if (self.shadow_primary_disabled) return;
        if (self.shadow_compare_mismatch > self.shadow_primary_mismatch_max) {
            self.shadow_primary_disabled = true;
            std.log.warn("[VexStore] primary disabled due to mismatch threshold", .{});
        }
    }

    fn shadowCompareWindowActive(self: *Self) bool {
        const now: u64 = @intCast(std.time.milliTimestamp());
        if (self.shadow_compare_next_window_ms == 0) {
            self.shadow_compare_next_window_ms = now;
        }
        if (now >= self.shadow_compare_window_end_ms and now >= self.shadow_compare_next_window_ms) {
            self.shadow_compare_window_end_ms = now + self.shadow_compare_window_ms;
            self.shadow_compare_next_window_ms = now + self.shadow_compare_period_ms;
        }
        return now < self.shadow_compare_window_end_ms;
    }

    fn recordShadowCompareError(self: *Self, message: []const u8) void {
        if (self.shadow_compare_error != null) return;
        const msg = self.allocator.dupe(u8, message) catch return;
        self.shadow_compare_error = msg;
    }

    pub const ShadowCompareStats = struct {
        enabled: bool,
        reads: u64,
        missing: u64,
        mismatch: u64,
        rate: u64,
        window_ms: u64,
        period_ms: u64,
        fail_closed: bool,
        error_message: ?[]const u8,
        stable_ms: u64,
        promote_ms: u64,
        eligible: bool,
    };

    pub fn getShadowCompareStats(self: *Self) ShadowCompareStats {
        self.metadata_lock.lock();
        defer self.metadata_lock.unlock();
        return self.getShadowCompareStatsUnlocked();
    }

    fn getShadowCompareStatsUnlocked(self: *Self) ShadowCompareStats {
        const now: u64 = @intCast(std.time.milliTimestamp());
        const last_bad = @max(self.shadow_compare_last_mismatch_ms, self.shadow_compare_last_missing_ms);
        const stable_ms: u64 = if (last_bad == 0) now else now - last_bad;
        const eligible = self.shadow_compare_enabled and stable_ms >= self.shadow_compare_promote_ms;
        return .{
            .enabled = self.shadow_compare_enabled,
            .reads = self.shadow_compare_reads,
            .missing = self.shadow_compare_missing,
            .mismatch = self.shadow_compare_mismatch,
            .rate = self.shadow_compare_rate,
            .window_ms = self.shadow_compare_window_ms,
            .period_ms = self.shadow_compare_period_ms,
            .fail_closed = self.shadow_compare_fail_closed,
            .error_message = self.shadow_compare_error,
            .stable_ms = stable_ms,
            .promote_ms = self.shadow_compare_promote_ms,
            .eligible = eligible,
        };
    }

    pub const ShadowPromotionStatus = struct {
        eligible: bool,
        active: bool,
        enabled: bool,
        force: bool,
        disabled: bool,
        stable_ms: u64,
        promote_ms: u64,
        primary_reads: u64,
        primary_hits: u64,
        primary_fallbacks: u64,
    };

    pub fn getShadowPromotionStatus(self: *Self) ShadowPromotionStatus {
        const stats = self.getShadowCompareStats();
        return .{
            .eligible = stats.eligible,
            .active = self.isShadowPrimaryActive(),
            .enabled = self.shadow_primary_enabled,
            .force = self.shadow_primary_force,
            .disabled = self.shadow_primary_disabled,
            .stable_ms = stats.stable_ms,
            .promote_ms = stats.promote_ms,
            .primary_reads = self.shadow_primary_reads,
            .primary_hits = self.shadow_primary_hits,
            .primary_fallbacks = self.shadow_primary_fallbacks,
        };
    }

    fn writeShadowStats(self: *Self, path: []const u8) !void {
        const stats = self.getShadowCompareStats();
        const json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"reads\":{d},\"missing\":{d},\"mismatch\":{d},\"rate\":{d},\"windowMs\":{d},\"periodMs\":{d},\"stableMs\":{d},\"promoteMs\":{d},\"eligible\":{s}}}\n",
            .{
                stats.reads,
                stats.missing,
                stats.mismatch,
                stats.rate,
                stats.window_ms,
                stats.period_ms,
                stats.stable_ms,
                stats.promote_ms,
                if (stats.eligible) "true" else "false",
            },
        );
        defer self.allocator.free(json);
        try writeStatsFile(path, json);
        if (self.shadow_compare_stats_rotate > 0) {
            const slot = self.shadow_compare_stats_seq % self.shadow_compare_stats_rotate;
            const rotated = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, slot });
            defer self.allocator.free(rotated);
            try writeStatsFile(rotated, json);
            self.shadow_compare_stats_seq += 1;
        }
    }

    fn writeStatsFile(path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        defer file.close();
        try file.writeAll(data);
        try file.sync();
    }

    /// Get multiple accounts (batch)
    pub fn getAccounts(self: *Self, pubkeys: []const core.Pubkey, results: []?AccountView) usize {
        var found: usize = 0;
        for (pubkeys, 0..) |*pubkey, i| {
            if (self.getAccount(pubkey)) |account| {
                results[i] = account;
                found += 1;
            } else {
                results[i] = null;
            }
        }
        return found;
    }

    /// Clean zero-lamport accounts for a slot
    pub fn cleanZeroLamports(self: *Self, slot: core.Slot) void {
        self.storage.lock.lockShared();
        defer self.storage.lock.unlockShared();
        self.index.removeIf(slot, &self.storage);
    }

    /// Purge a slot's storage and index entries
    pub fn purgeSlot(self: *Self, slot: core.Slot) void {
        self.index.removeSlot(slot);
        self.storage.purgeSlot(slot);
    }

    pub fn tickAccountsPurge(self: *Self, current_slot: core.Slot) void {
        if (!self.accounts_purge_enabled) return;
        if (self.accounts_purge_age_slots == 0) return;
        const safe_slot = self.safeSlot(current_slot);
        if (safe_slot <= self.accounts_purge_age_slots) return;
        const threshold = safe_slot - self.accounts_purge_age_slots;
        var to_purge = std.ArrayList(core.Slot).init(self.allocator);
        defer to_purge.deinit();
        self.storage.lock.lock();
        var iter = self.storage.slot_to_store.iterator();
        while (iter.next()) |entry| {
            const slot = entry.key_ptr.*;
            if (slot <= threshold) {
                to_purge.append(slot) catch {};
            }
        }
        self.storage.lock.unlock();
        for (to_purge.items) |slot| {
            self.purgeSlot(slot);
        }
    }

    pub fn tickAccountsClean(self: *Self, current_slot: core.Slot) void {
        if (!self.accounts_clean_enabled) return;
        if (self.accounts_clean_age_slots == 0) return;
        const safe_slot = self.safeSlot(current_slot);
        if (safe_slot <= self.accounts_clean_age_slots) return;
        const target = safe_slot - self.accounts_clean_age_slots;
        if (target == 0 or target == self.accounts_clean_last_slot) return;
        self.cleanZeroLamports(target);
        self.accounts_clean_last_slot = target;
    }

    pub fn tickAccountsGc(self: *Self, current_slot: core.Slot, now_ms: u64) void {
        self.refreshGcSlots(now_ms) catch {};
        if (self.accounts_gc_slots.items.len == 0) return;
        const safe_slot = self.safeSlot(current_slot);
        const batch = @min(self.accounts_gc_batch, self.accounts_gc_slots.items.len);
        var i: usize = 0;
        while (i < batch) : (i += 1) {
            if (self.accounts_gc_cursor >= self.accounts_gc_slots.items.len) {
                self.accounts_gc_cursor = 0;
            }
            const slot = self.accounts_gc_slots.items[self.accounts_gc_cursor];
            self.accounts_gc_cursor += 1;
            if (slot > safe_slot) continue;
            if (self.accounts_clean_enabled and slot > 0 and slot != self.accounts_clean_last_slot) {
                if (safe_slot > self.accounts_clean_age_slots and slot <= safe_slot - self.accounts_clean_age_slots) {
                    self.cleanZeroLamports(slot);
                    self.accounts_clean_last_slot = slot;
                }
            }
            if (self.accounts_shrink_enabled and slot > 0 and slot != self.accounts_shrink_last_slot) {
                const did = self.shrinkSlot(
                    slot,
                    self.accounts_shrink_ratio_percent,
                    self.accounts_shrink_min_bytes,
                    self.accounts_shrink_hysteresis_percent,
                ) catch false;
                if (did) {
                    std.log.info("[AccountsDb] shrink completed slot={d}", .{slot});
                    self.accounts_shrink_last_slot = slot;
                }
            }
            if (self.accounts_purge_enabled and slot > 0) {
                if (safe_slot > self.accounts_purge_age_slots and slot <= safe_slot - self.accounts_purge_age_slots) {
                    self.purgeSlot(slot);
                }
            }
        }
    }

    pub fn flushAccountsMetadata(self: *Self) void {
        self.storage.flushMetadata();
    }

    fn refreshGcSlots(self: *Self, now_ms: u64) !void {
        if (self.accounts_gc_scan_interval_ms == 0) return;
        if (self.accounts_gc_last_scan_ms != 0 and now_ms - self.accounts_gc_last_scan_ms < self.accounts_gc_scan_interval_ms) {
            return;
        }
        self.accounts_gc_last_scan_ms = now_ms;
        self.accounts_gc_slots.clearRetainingCapacity();
        self.storage.lock.lock();
        var iter = self.storage.slot_to_store.iterator();
        while (iter.next()) |entry| {
            try self.accounts_gc_slots.append(entry.key_ptr.*);
        }
        self.storage.lock.unlock();
        std.sort.heap(core.Slot, self.accounts_gc_slots.items, {}, sortSlotAsc);
        self.accounts_gc_cursor = 0;
    }

    pub fn onSlotCompleted(self: *Self, slot: core.Slot) void {
        if (slot > self.accounts_completed_max_slot) {
            self.accounts_completed_max_slot = slot;
        }
    }

    fn safeSlot(self: *Self, current_slot: core.Slot) core.Slot {
        const max_completed = self.accounts_completed_max_slot;
        const lag = self.accounts_safe_lag_slots;
        const capped = if (max_completed > lag) max_completed - lag else 0;
        return if (capped < current_slot) capped else current_slot;
    }

    fn sortSlotAsc(_: void, a: core.Slot, b: core.Slot) bool {
        return a < b;
    }

    pub const AccountsStoreStats = struct {
        slot: core.Slot,
        store_id: u32,
        total_bytes: u64,
        live_bytes: u64,
        dead_bytes: u64,
        dead_ratio_percent: u32,
        records: u64,
        live_records: u64,
    };

    pub const AccountsStatsSummary = struct {
        total_bytes: u64,
        live_bytes: u64,
        dead_bytes: u64,
        dead_ratio_percent: u32,
        records: u64,
        live_records: u64,
    };

    pub fn collectStoreStats(self: *Self, allocator: std.mem.Allocator) !std.ArrayList(AccountsStoreStats) {
        const SlotStore = struct { slot: core.Slot, store_id: u32 };
        var pairs = std.ArrayList(SlotStore).init(allocator);
        defer pairs.deinit();

        self.storage.lock.lock();
        var iter = self.storage.slot_to_store.iterator();
        while (iter.next()) |entry| {
            try pairs.append(.{
                .slot = entry.key_ptr.*,
                .store_id = entry.value_ptr.*,
            });
        }
        self.storage.lock.unlock();

        var stats = std.ArrayList(AccountsStoreStats).init(allocator);
        for (pairs.items) |pair| {
            const store_stats = try self.computeStoreStats(pair.slot, pair.store_id);
            try stats.append(store_stats);
        }
        return stats;
    }

    pub fn computeSummary(self: *Self, stores: []const AccountsStoreStats) AccountsStatsSummary {
        _ = self;
        var total_bytes: u64 = 0;
        var live_bytes: u64 = 0;
        var dead_bytes: u64 = 0;
        var records: u64 = 0;
        var live_records: u64 = 0;
        for (stores) |s| {
            total_bytes += s.total_bytes;
            live_bytes += s.live_bytes;
            dead_bytes += s.dead_bytes;
            records += s.records;
            live_records += s.live_records;
        }
        const ratio = if (total_bytes == 0) 0 else @as(u32, @intCast(@as(u128, dead_bytes) * 100 / @as(u128, total_bytes)));
        return .{
            .total_bytes = total_bytes,
            .live_bytes = live_bytes,
            .dead_bytes = dead_bytes,
            .dead_ratio_percent = ratio,
            .records = records,
            .live_records = live_records,
        };
    }

    fn computeStoreStats(self: *Self, slot: core.Slot, store_id: u32) !AccountsStoreStats {
        self.storage.lock.lock();
        const av = self.storage.stores.get(store_id) orelse {
            self.storage.lock.unlock();
            return error.StoreNotFound;
        };
        var total_bytes: u64 = 0;
        var live_bytes: u64 = 0;
        var records: u64 = 0;
        var live_records: u64 = 0;
        var offset: u64 = av.firstRecordOffset();

        while (av.readRecord(offset)) |record| {
            total_bytes += record.total_len;
            records += 1;
            if (self.index.get(&record.pubkey)) |location| {
                if (location.store_id == store_id and location.offset == offset) {
                    live_bytes += record.total_len;
                    live_records += 1;
                }
            }
            offset += record.total_len;
        }
        self.storage.lock.unlock();

        const dead_bytes = total_bytes - live_bytes;
        const dead_ratio = if (total_bytes == 0) 0 else @as(u32, @intCast(@as(u128, dead_bytes) * 100 / @as(u128, total_bytes)));
        return .{
            .slot = slot,
            .store_id = store_id,
            .total_bytes = total_bytes,
            .live_bytes = live_bytes,
            .dead_bytes = dead_bytes,
            .dead_ratio_percent = dead_ratio,
            .records = records,
            .live_records = live_records,
        };
    }

    pub fn tickAccountsStats(self: *Self, now_ms: u64) void {
        if (!self.accounts_stats_enabled) return;
        if (self.accounts_stats_interval_ms == 0) return;
        if (self.accounts_stats_last_ms != 0 and now_ms - self.accounts_stats_last_ms < self.accounts_stats_interval_ms) {
            return;
        }
        self.accounts_stats_last_ms = now_ms;
        self.logAccountsStats() catch {};
    }

    fn logAccountsStats(self: *Self) !void {
        var stores = try self.collectStoreStats(self.allocator);
        defer stores.deinit();
        const summary = self.computeSummary(stores.items);
        std.log.info(
            "[AccountsDb] total={d} live={d} dead={d} deadRatio={d}% records={d} liveRecords={d}",
            .{
                summary.total_bytes,
                summary.live_bytes,
                summary.dead_bytes,
                summary.dead_ratio_percent,
                summary.records,
                summary.live_records,
            },
        );
        if (stores.items.len == 0) return;
        std.sort.heap(AccountsStoreStats, stores.items, {}, sortByDeadRatio);
        const top = @min(self.accounts_stats_top_n, stores.items.len);
        var i: usize = 0;
        while (i < top) : (i += 1) {
            const s = stores.items[i];
            std.log.info(
                "[AccountsDb] slot={d} store={d} deadRatio={d}% dead={d} live={d}",
                .{ s.slot, s.store_id, s.dead_ratio_percent, s.dead_bytes, s.live_bytes },
            );
        }
    }

    fn sortByDeadRatio(_: void, a: AccountsStoreStats, b: AccountsStoreStats) bool {
        return a.dead_ratio_percent > b.dead_ratio_percent;
    }

    pub fn tickAccountsShrink(self: *Self, slot: core.Slot) void {
        if (!self.accounts_shrink_enabled) return;
        const safe_slot = self.safeSlot(slot);
        if (safe_slot == 0 or safe_slot == self.accounts_shrink_last_slot) return;
        const did = self.shrinkSlot(
            safe_slot,
            self.accounts_shrink_ratio_percent,
            self.accounts_shrink_min_bytes,
            self.accounts_shrink_hysteresis_percent,
        ) catch false;
        if (did) {
            std.log.info("[AccountsDb] shrink completed slot={d}", .{safe_slot});
        }
        self.accounts_shrink_last_slot = safe_slot;
    }

    /// Shrink an appendvec for a slot if dead ratio exceeds threshold
    pub fn shrinkSlot(
        self: *Self,
        slot: core.Slot,
        dead_ratio_percent: u32,
        min_dead_bytes: u64,
        hysteresis_percent: u32,
    ) !bool {
        self.storage.lock.lock();
        defer self.storage.lock.unlock(); // CRITICAL: defer guarantees unlock on ALL exit paths
        const store_id = self.storage.slot_to_store.get(slot) orelse {
            return false;
        };
        const av = self.storage.stores.get(store_id) orelse {
            return false;
        };

        var live_bytes: u64 = 0;
        var total_bytes: u64 = 0;
        var offset: u64 = av.firstRecordOffset();

        while (av.readRecord(offset)) |record| {
            total_bytes += record.total_len;
            const location = self.index.get(&record.pubkey);
            if (location != null and location.?.store_id == store_id and location.?.offset == offset) {
                live_bytes += record.total_len;
            }
            offset += record.total_len;
        }

        if (total_bytes == 0) return false;
        const dead_bytes = total_bytes - live_bytes;
        const dead_ratio = @as(u128, dead_bytes) * 100 / @as(u128, total_bytes);
        const trigger_ratio = @as(u128, dead_ratio_percent) + @as(u128, hysteresis_percent);
        if (dead_ratio < trigger_ratio) return false;
        if (dead_bytes < min_dead_bytes) return false;

        const min_capacity: u64 = @intCast(std.mem.page_size);
        const target_capacity = std.mem.alignForward(u64, @max(live_bytes, min_capacity), std.mem.page_size);
        const new_store = try self.storage.createStoreForSlotUnlocked(slot, target_capacity);

        offset = av.firstRecordOffset();
        while (av.readRecord(offset)) |record| {
            const location = self.index.get(&record.pubkey);
            if (location != null and location.?.store_id == store_id and location.?.offset == offset) {
                var buf = std.ArrayList(u8).init(self.allocator);
                defer buf.deinit();
                try buf.appendSlice(&record.pubkey.data);
                try buf.writer().writeInt(u64, record.account.lamports, .little);
                try buf.appendSlice(&record.account.owner.data);
                try buf.append(@intFromBool(record.account.executable));
                try buf.writer().writeInt(u64, record.account.rent_epoch, .little);
                try buf.writer().writeInt(u32, @intCast(record.account.data.len), .little);
                try buf.appendSlice(record.account.data);

                const new_offset = try new_store.av.append(buf.items);
                const new_location = AccountLocation{
                    .store_id = new_store.store_id,
                    .offset = new_offset,
                    .slot = slot,
                };
                try self.index.insert(&record.pubkey, new_location);
            }
            offset += record.total_len;
        }

        _ = self.storage.slot_to_store.put(slot, new_store.store_id) catch {};
        if (self.storage.stores.fetchRemove(store_id)) |old_store| {
            const old_av = old_store.value;
            std.fs.cwd().deleteFile(old_av.file_path) catch {};
            old_av.deinit();
        }

        return true;
    }

    /// Compute accounts hash for snapshot
    pub fn computeHash(self: *Self) !core.Hash {
        var leaves = std.ArrayList(core.Hash).init(self.allocator);
        defer leaves.deinit();

        // Lock storage shared to ensure no appendvecs are deleted/shrunk while hashing
        self.storage.lock.lockShared();
        defer self.storage.lock.unlockShared();

        for (self.index.bins) |*bin| {
            bin.lock.lockShared();
            // We must collect both pubkey and account data while holding the bin lock
            // to ensure a consistent point-in-time view of this bin.
            var it = bin.entries.iterator();
            while (it.next()) |entry| {
                const pubkey = entry.key_ptr.*;
                const location = entry.value_ptr.*;
                if (self.storage.readAccountUnlocked(location)) |account| {
                    try leaves.append(hashAccount(&pubkey, account));
                }
            }
            bin.lock.unlockShared();
        }

        if (leaves.items.len == 0) {
            return core.Hash.ZERO;
        }

        // Sort leaves for deterministic Merkle root
        std.sort.heap(core.Hash, leaves.items, {}, hashLessThan);

        return merkleize(self.allocator, leaves.items);
    }

    /// Compute Accounts Delta Hash — ONLY hashes accounts modified in this slot.
    /// This is O(k) where k is the number of accounts touched, instead of O(n) over
    /// the entire database. Matches the Agave/Firedancer accounts_delta_hash approach.
    pub fn computeDeltaHash(self: *Self, alloc: std.mem.Allocator, delta_accounts: []const AccountWrite) !core.Hash {
        _ = self; // AccountsDb state not needed — hash is purely from the delta set
        if (delta_accounts.len == 0) {
            // No accounts modified in this slot (tick-only slot)
            return core.Hash.ZERO;
        }

        var leaves = try std.ArrayList(core.Hash).initCapacity(alloc, delta_accounts.len);
        defer leaves.deinit();

        for (delta_accounts) |*write| {
            // Hash each mutated account using the same hashAccount logic
            const view = accountViewFromOwned(&write.account);
            leaves.appendAssumeCapacity(hashAccount(&write.pubkey, view));
        }

        // Sort leaves for deterministic Merkle root (same as full hash)
        std.sort.heap(core.Hash, leaves.items, {}, hashLessThan);

        return merkleize(alloc, leaves.items);
    }

    /// Write accounts to a snapshot AppendVec file (Solana format).
    pub fn writeSnapshotAppendVec(self: *Self, writer: anytype) !struct { accounts_written: u64, lamports_total: u64 } {
        const STORED_META_SIZE: usize = 48;
        const ACCOUNT_META_SIZE: usize = 56;
        var accounts_written: u64 = 0;
        var lamports_total: u64 = 0;
        const write_version: u64 = 1;
        const pad_bytes = [_]u8{0} ** 8;

        // Lock storage shared to ensure no appendvecs are deleted/shrunk while writing
        self.storage.lock.lockShared();
        defer self.storage.lock.unlockShared();

        for (self.index.bins) |*bin| {
            bin.lock.lockShared();
            var it = bin.entries.iterator();
            while (it.next()) |entry| {
                const pubkey = entry.key_ptr.*;
                const location = entry.value_ptr.*;
                if (self.storage.readAccountUnlocked(location)) |account| {
                    var buf8: [8]u8 = undefined;

                    std.mem.writeInt(u64, &buf8, write_version, .little);
                    try writer.writeAll(&buf8);
                    std.mem.writeInt(u64, &buf8, @intCast(account.data.len), .little);
                    try writer.writeAll(&buf8);
                    try writer.writeAll(&pubkey.data);

                    std.mem.writeInt(u64, &buf8, account.lamports, .little);
                    try writer.writeAll(&buf8);
                    std.mem.writeInt(u64, &buf8, account.rent_epoch, .little);
                    try writer.writeAll(&buf8);
                    try writer.writeAll(&account.owner.data);
                    try writer.writeByte(@intFromBool(account.executable));
                    try writer.writeAll(pad_bytes[0..7]);

                    // Account hash (32 bytes) - required between AccountMeta and data
                    // in Agave's AppendVec format. Use zeros for locally-generated snapshots.
                    const zero_hash = [_]u8{0} ** 32;
                    try writer.writeAll(&zero_hash);

                    try writer.writeAll(account.data);

                    const HASH_SIZE: usize = 32;
                    const record_len = STORED_META_SIZE + ACCOUNT_META_SIZE + HASH_SIZE + @as(usize, @intCast(account.data.len));
                    const pad = (8 - (record_len % 8)) & 7;
                    if (pad != 0) {
                        try writer.writeAll(pad_bytes[0..pad]);
                    }

                    accounts_written += 1;
                    lamports_total = std.math.add(u64, lamports_total, account.lamports) catch lamports_total;
                }
            }
            bin.lock.unlockShared();
        }

        return .{
            .accounts_written = accounts_written,
            .lamports_total = lamports_total,
        };
    }

    /// Write accounts by scanning storage AppendVecs directly.
    /// NOTE: This bypasses the index and can include older versions.
    pub fn writeSnapshotAppendVecRaw(self: *Self, writer: anytype) !struct { accounts_written: u64, lamports_total: u64 } {
        const STORED_META_SIZE: usize = 48;
        const ACCOUNT_META_SIZE: usize = 56;
        var accounts_written: u64 = 0;
        var lamports_total: u64 = 0;
        const write_version: u64 = 1;
        const pad_bytes = [_]u8{0} ** 8;

        self.storage.lock.lock();
        defer self.storage.lock.unlock();
        var iter = self.storage.stores.valueIterator();
        while (iter.next()) |av| {
            var offset: u64 = av.*.firstRecordOffset();
            while (av.*.readRecord(offset)) |record| {
                var buf8: [8]u8 = undefined;

                std.mem.writeInt(u64, &buf8, write_version, .little);
                try writer.writeAll(&buf8);
                std.mem.writeInt(u64, &buf8, @intCast(record.account.data.len), .little);
                try writer.writeAll(&buf8);
                try writer.writeAll(&record.pubkey.data);

                std.mem.writeInt(u64, &buf8, record.account.lamports, .little);
                try writer.writeAll(&buf8);
                std.mem.writeInt(u64, &buf8, record.account.rent_epoch, .little);
                try writer.writeAll(&buf8);
                try writer.writeAll(&record.account.owner.data);
                try writer.writeByte(@intFromBool(record.account.executable));
                try writer.writeAll(pad_bytes[0..7]);

                // Account hash (32 bytes) - required between AccountMeta and data
                const zero_hash = [_]u8{0} ** 32;
                try writer.writeAll(&zero_hash);

                try writer.writeAll(record.account.data);

                const HASH_SIZE: usize = 32;
                const record_len = STORED_META_SIZE + ACCOUNT_META_SIZE + HASH_SIZE + @as(usize, @intCast(record.account.data.len));
                const pad = (8 - (record_len % 8)) & 7;
                if (pad != 0) {
                    try writer.writeAll(pad_bytes[0..pad]);
                }

                accounts_written += 1;
                lamports_total = std.math.add(u64, lamports_total, record.account.lamports) catch lamports_total;
                offset += record.total_len;
            }
        }

        return .{
            .accounts_written = accounts_written,
            .lamports_total = lamports_total,
        };
    }
};

fn pubkeyLessThan(_: void, a: core.Pubkey, b: core.Pubkey) bool {
    return std.mem.order(u8, &a.data, &b.data) == .lt;
}

fn hashLessThan(_: void, a: core.Hash, b: core.Hash) bool {
    return std.mem.order(u8, &a.data, &b.data) == .lt;
}

fn hashAccount(pubkey: *const core.Pubkey, account: AccountView) core.Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Pubkey
    hasher.update(&pubkey.data);

    // Lamports (u64 LE)
    var lamports_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, lamports_buf[0..8], account.lamports, .little);
    hasher.update(&lamports_buf);

    // Owner pubkey
    hasher.update(&account.owner.data);

    // Executable flag
    hasher.update(&[_]u8{@intFromBool(account.executable)});

    // Rent epoch (u64 LE)
    var rent_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, rent_buf[0..8], account.rent_epoch, .little);
    hasher.update(&rent_buf);

    // Data length (u32 LE)
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..4], @intCast(account.data.len), .little);
    hasher.update(&len_buf);

    // Data hash
    var data_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(account.data, &data_hash, .{});
    hasher.update(&data_hash);

    return core.Hash{ .data = hasher.finalResult() };
}

fn merkleize(allocator: std.mem.Allocator, leaves: []const core.Hash) !core.Hash {
    var level = std.ArrayList(core.Hash).init(allocator);
    defer level.deinit();
    try level.appendSlice(leaves);

    while (level.items.len > 1) {
        var next = std.ArrayList(core.Hash).init(allocator);
        defer next.deinit();
        const pairs = (level.items.len + 1) / 2;
        try next.ensureTotalCapacity(pairs);

        var i: usize = 0;
        while (i < level.items.len) : (i += 2) {
            const left = level.items[i];
            const right = if (i + 1 < level.items.len) level.items[i + 1] else left;

            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&left.data);
            hasher.update(&right.data);
            next.appendAssumeCapacity(core.Hash{ .data = hasher.finalResult() });
        }

        level.clearRetainingCapacity();
        try level.appendSlice(next.items);
    }

    return level.items[0];
}

test "accountsdb vexstore shadow writes" {
    if (!build_options.vexstore_shadow_enabled) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var db = try AccountsDb.init(std.testing.allocator, path);
    defer db.deinit();

    const pubkey = core.Pubkey{ .data = [_]u8{1} ** 32 };
    const owner = core.Pubkey{ .data = [_]u8{2} ** 32 };
    const account = Account{
        .lamports = 42,
        .owner = owner,
        .executable = false,
        .rent_epoch = 7,
        .data = "shadow",
    };

    try db.storeAccount(&pubkey, &account, 1);

    const shadow = db.vexstore_shadow orelse return error.MissingShadowStore;
    const got = try shadow.get(pubkey.data);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);

    const expected = try serializeAccount(std.testing.allocator, &account);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, got.?);
}

/// Account index mapping pubkeys to storage locations
pub const AccountIndex = struct {
    allocator: std.mem.Allocator,
    bins: []Bin,

    const Self = @This();

    const num_bins: usize = 8192;

    pub const BatchEntry = struct {
        pubkey: core.Pubkey,
        location: AccountLocation,
    };

    pub fn upsertBatch(self: *Self, entries: []const BatchEntry) !void {
        for (entries) |*entry| {
            const bin = self.binFor(&entry.pubkey);
            bin.lock.lock();
            defer bin.lock.unlock();
            try bin.entries.put(entry.pubkey, entry.location);
        }
    }

    const Bin = struct {
        lock: std.Thread.RwLock,
        entries: std.AutoHashMap(core.Pubkey, AccountLocation),
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return initWithCapacity(allocator, 0);
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, per_bin_capacity: usize) Self {
        const bins = allocator.alloc(Bin, num_bins) catch unreachable;
        for (bins) |*bin| {
            bin.* = .{
                .lock = .{},
                .entries = std.AutoHashMap(core.Pubkey, AccountLocation).init(allocator),
            };
            if (per_bin_capacity > 0) {
                const cap: u32 = @intCast(@min(per_bin_capacity, std.math.maxInt(u32)));
                bin.entries.ensureTotalCapacity(cap) catch {};
            }
        }
        return .{
            .allocator = allocator,
            .bins = bins,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.bins) |*bin| {
            bin.entries.deinit();
        }
        self.allocator.free(self.bins);
    }

    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?AccountLocation {
        const bin = self.binFor(pubkey);
        bin.lock.lockShared();
        defer bin.lock.unlockShared();
        return bin.entries.get(pubkey.*);
    }

    pub fn insert(self: *Self, pubkey: *const core.Pubkey, location: AccountLocation) !void {
        const bin = self.binFor(pubkey);
        bin.lock.lock();
        defer bin.lock.unlock();
        try bin.entries.put(pubkey.*, location);
    }

    /// Pre-allocate capacity across all bins for bulk loading
    pub fn ensureCapacity(self: *Self, total_capacity: usize) !void {
        const per_bin = (total_capacity + num_bins - 1) / num_bins;
        const cap: u32 = @intCast(@min(per_bin, std.math.maxInt(u32)));
        for (self.bins) |*bin| {
            bin.lock.lock();
            defer bin.lock.unlock();
            try bin.entries.ensureTotalCapacity(cap);
        }
    }

    pub fn removeSlot(self: *Self, slot: core.Slot) void {
        for (self.bins) |*bin| {
            bin.lock.lock();
            var iter = bin.entries.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.slot == slot) {
                    _ = bin.entries.remove(entry.key_ptr.*);
                }
            }
            bin.lock.unlock();
        }
    }

    pub fn removeIf(self: *Self, slot: core.Slot, storage: *AccountStorage) void {
        for (self.bins) |*bin| {
            bin.lock.lock();
            var iter = bin.entries.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.slot != slot) continue;
                if (storage.readAccountUnlocked(entry.value_ptr.*)) |account| {
                    if (account.lamports == 0) {
                        _ = bin.entries.remove(entry.key_ptr.*);
                    }
                }
            }
            bin.lock.unlock();
        }
    }

    fn binFor(self: *Self, pubkey: *const core.Pubkey) *Bin {
        const hi: u16 = (@as(u16, pubkey.data[0]) << 8) | pubkey.data[1];
        const idx = @as(usize, hi >> 3) & (num_bins - 1);
        return &self.bins[idx];
    }
};

/// Location of an account in storage
pub const AccountLocation = struct {
    /// Storage file ID
    store_id: u32,
    /// Offset within file
    offset: u64,
    /// Slot this version is from
    slot: core.Slot,
};

/// Account storage using append vectors
pub const AccountStorage = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    lock: std.Thread.RwLock,
    /// Active append vectors by slot
    stores: std.AutoHashMap(u32, *AppendVec),
    slot_to_store: std.AutoHashMap(core.Slot, u32),
    next_store_id: u32,
    default_capacity: u64,
    /// During snapshot loading, we use a shared store to avoid creating thousands of allocations
    current_bulk_store_id: ?u32 = null,
    bulk_store_bytes_used: u64 = 0,
    /// When true, bypass slot_to_store lookups to avoid routing to full stores
    bulk_mode: bool = false,

    const DEFAULT_APPEND_VEC_CAPACITY: u64 = 64 * 1024 * 1024; // 64MB

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8, default_capacity: u64) !Self {
        const base_path_copy = try allocator.dupe(u8, path);
        return .{
            .allocator = allocator,
            .base_path = base_path_copy,
            .lock = .{},
            .stores = std.AutoHashMap(u32, *AppendVec).init(allocator),
            .slot_to_store = std.AutoHashMap(core.Slot, u32).init(allocator),
            .next_store_id = 0,
            .default_capacity = if (default_capacity > 0) default_capacity else DEFAULT_APPEND_VEC_CAPACITY,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        var iter = self.stores.valueIterator();
        while (iter.next()) |av| {
            av.*.deinit();
        }
        self.stores.deinit();
        self.slot_to_store.deinit();
        self.allocator.free(self.base_path);
    }

    pub fn flushMetadata(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        var iter = self.stores.valueIterator();
        while (iter.next()) |av| {
            av.*.flushMeta() catch {};
        }
    }

    pub fn readAccount(self: *Self, location: AccountLocation) ?AccountView {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.readAccountUnlocked(location);
    }

    pub fn readAccountUnlocked(self: *Self, location: AccountLocation) ?AccountView {
        if (self.stores.get(location.store_id)) |av| {
            return av.getAccount(location.offset);
        }
        return null;
    }

    /// Serialize an account to bytes (for bulk loading with minimal lock time)
    pub fn serializeAccountToBytes(self: *Self, pubkey: *const core.Pubkey, account: *const Account) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice(&pubkey.data);
        try buf.writer().writeInt(u64, account.lamports, .little);
        try buf.appendSlice(&account.owner.data);
        try buf.append(@intFromBool(account.executable));
        try buf.writer().writeInt(u64, account.rent_epoch, .little);
        try buf.writer().writeInt(u32, @intCast(account.data.len), .little);
        try buf.appendSlice(account.data);

        return buf.toOwnedSlice();
    }

    /// Write pre-serialized account data (faster, minimizes lock time)
    pub fn writeAccountBytes(self: *Self, data: []const u8, slot: core.Slot) !AccountLocation {
        self.lock.lock();
        defer self.lock.unlock();
        var store_id = try self.getOrCreateStore(slot);
        var av = self.stores.get(store_id) orelse return error.StoreNotFound;

        const offset = av.append(data) catch |err| switch (err) {
            error.AppendVecFull => {
                // Current store full — force rotation to a new one
                self.current_bulk_store_id = null;
                self.bulk_store_bytes_used = 0;
                store_id = try self.getOrCreateStore(slot);
                av = self.stores.get(store_id) orelse return error.StoreNotFound;
                return .{
                    .store_id = store_id,
                    .offset = try av.append(data),
                    .slot = slot,
                };
            },
            else => return err,
        };

        // Track bytes written for bulk store rotation
        self.trackBulkWrite(@intCast(data.len));

        return AccountLocation{
            .store_id = store_id,
            .offset = offset,
            .slot = slot,
        };
    }

    pub fn writeAccount(self: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot) !AccountLocation {
        self.lock.lock();
        defer self.lock.unlock();
        var store_id = try self.getOrCreateStore(slot);
        // FIX: Avoid forced unwrap - return error if store not found (shouldn't happen but safer)
        var av = self.stores.get(store_id) orelse return error.StoreNotFound;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice(&pubkey.data);
        try buf.writer().writeInt(u64, account.lamports, .little);
        try buf.appendSlice(&account.owner.data);
        try buf.append(@intFromBool(account.executable));
        try buf.writer().writeInt(u64, account.rent_epoch, .little);
        try buf.writer().writeInt(u32, @intCast(account.data.len), .little);
        try buf.appendSlice(account.data);

        const offset = av.append(buf.items) catch |err| switch (err) {
            error.AppendVecFull => {
                // Current store full — force rotation to a new one
                self.current_bulk_store_id = null;
                self.bulk_store_bytes_used = 0;
                store_id = try self.getOrCreateStore(slot);
                av = self.stores.get(store_id) orelse return error.StoreNotFound;
                return .{
                    .store_id = store_id,
                    .offset = try av.append(buf.items),
                    .slot = slot,
                };
            },
            else => return err,
        };

        // Track bytes written for bulk store rotation
        self.trackBulkWrite(@intCast(buf.items.len));

        return AccountLocation{
            .store_id = store_id,
            .offset = offset,
            .slot = slot,
        };
    }

    fn getOrCreateStore(self: *Self, slot: core.Slot) !u32 {
        const capacity = if (self.default_capacity > 0) self.default_capacity else DEFAULT_APPEND_VEC_CAPACITY;

        // In bulk mode, bypass slot_to_store entirely.
        // All threads share the current bulk store and rotate when full.
        // This avoids the race where slot_to_store maps to an already-full store.
        if (self.bulk_mode) {
            // Check if current bulk store has room (leave 10% headroom)
            const headroom: u64 = capacity / 10;
            if (self.current_bulk_store_id) |bulk_id| {
                if (self.bulk_store_bytes_used + headroom < capacity) {
                    return bulk_id;
                }
            }

            // Need a new bulk store
            const store_id = self.next_store_id;
            self.next_store_id += 1;
            const new_av = try AppendVec.init(self.allocator, self.base_path, store_id, slot, capacity);
            try self.stores.put(store_id, new_av);

            self.current_bulk_store_id = store_id;
            self.bulk_store_bytes_used = 0;

            return store_id;
        }

        // Normal mode: per-slot store mapping
        if (self.slot_to_store.get(slot)) |store_id| {
            return store_id;
        }

        // Check if current bulk store has room (leave 10% headroom)
        const headroom: u64 = capacity / 10;
        if (self.current_bulk_store_id) |bulk_id| {
            if (self.bulk_store_bytes_used + headroom < capacity) {
                try self.slot_to_store.put(slot, bulk_id);
                return bulk_id;
            }
        }

        // Need a new store
        const store_id = self.next_store_id;
        self.next_store_id += 1;
        const new_av = try AppendVec.init(self.allocator, self.base_path, store_id, slot, capacity);
        try self.stores.put(store_id, new_av);
        try self.slot_to_store.put(slot, store_id);

        self.current_bulk_store_id = store_id;
        self.bulk_store_bytes_used = 0;

        return store_id;
    }

    /// Call this after writing to update bulk store usage tracking
    fn trackBulkWrite(self: *Self, bytes_written: u64) void {
        self.bulk_store_bytes_used += bytes_written;
    }

    pub fn createStoreForSlot(self: *Self, slot: core.Slot, capacity: u64) !struct { store_id: u32, av: *AppendVec } {
        self.lock.lock();
        defer self.lock.unlock();
        return self.createStoreForSlotUnlocked(slot, capacity);
    }

    fn createStoreForSlotUnlocked(self: *Self, slot: core.Slot, capacity: u64) !struct { store_id: u32, av: *AppendVec } {
        const store_id = self.next_store_id;
        self.next_store_id += 1;
        const av = try AppendVec.init(self.allocator, self.base_path, store_id, slot, capacity);
        try self.stores.put(store_id, av);
        return .{ .store_id = store_id, .av = av };
    }

    pub fn purgeSlot(self: *Self, slot: core.Slot) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.slot_to_store.fetchRemove(slot)) |entry| {
            const store_id = entry.value;
            if (self.stores.fetchRemove(store_id)) |store| {
                const av = store.value;
                std.fs.cwd().deleteFile(av.file_path) catch {};
                av.deinit();
            }
        }
    }
};

/// Append-only vector for account storage
/// NOTE: Following Sig's design, we use heap allocation instead of mmap to avoid SIGBUS
/// issues when loading thousands of files during snapshot loading.
pub const AppendVec = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    file: ?std.fs.File,
    data: []u8, // Heap-allocated buffer (not mmap)
    current_len: std.atomic.Value(u64),
    capacity: u64,
    last_meta_len: u64,
    dirty: bool, // Track if we need to flush to disk

    const Self = @This();
    const header_size: usize = 32;
    const header_magic: [8]u8 = [_]u8{ 'V', 'E', 'X', 'A', 'V', '1', 0, 0 };
    const record_header_len: usize = 32 + 8 + 32 + 1 + 8 + 4;
    const meta_flush_interval: u64 = 1 * 1024 * 1024; // 1MB

    const Record = struct {
        pubkey: core.Pubkey,
        account: AccountView,
        total_len: u64,
    };

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8, store_id: u32, slot: core.Slot, capacity: u64) !*Self {
        const av = try allocator.create(Self);
        errdefer allocator.destroy(av);

        const accounts_dir = try std.fmt.allocPrint(allocator, "{s}/accounts", .{base_path});
        defer allocator.free(accounts_dir);
        try std.fs.cwd().makePath(accounts_dir);

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{d}.{d}.av", .{ accounts_dir, slot, store_id });
        errdefer allocator.free(file_path);

        // Heap-allocate the data buffer instead of mmap
        // This avoids SIGBUS issues and follows Sig's approach
        const data = try allocator.alloc(u8, @intCast(capacity));
        errdefer allocator.free(data);

        av.* = .{
            .allocator = allocator,
            .file_path = file_path,
            .file = null,
            .data = data,
            .current_len = std.atomic.Value(u64).init(header_size),
            .capacity = capacity,
            .last_meta_len = header_size,
            .dirty = false,
        };

        // Initialize header in memory
        @memcpy(av.data[0..8], &header_magic);
        std.mem.writeInt(u32, av.data[8..12], 1, .little); // version
        std.mem.writeInt(u64, av.data[12..20], header_size, .little); // length
        @memset(av.data[20..header_size], 0); // padding

        return av;
    }

    pub fn deinit(self: *Self) void {
        // Flush to disk before cleanup
        self.flushToDisk() catch |err| {
            std.log.warn("[AppendVec] Failed to flush on deinit: {}", .{err});
        };

        if (self.file) |f| f.close();
        self.allocator.free(self.data);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }

    pub fn getAccount(self: *Self, offset: u64) ?AccountView {
        if (self.readRecord(offset)) |record| {
            return record.account;
        }
        return null;
    }

    pub fn append(self: *Self, data: []const u8) !u64 {
        const offset = self.current_len.fetchAdd(data.len, .seq_cst);
        if (offset + data.len > self.capacity) {
            // Rollback the atomic add
            _ = self.current_len.fetchSub(data.len, .seq_cst);
            return error.AppendVecFull;
        }

        // Write to heap buffer (no SIGBUS risk)
        @memcpy(self.data[offset..][0..data.len], data);
        self.dirty = true;

        const new_len = offset + data.len;
        self.updateHeaderLen(new_len);

        // Periodically flush to disk
        if (new_len - self.last_meta_len >= meta_flush_interval) {
            self.flushToDisk() catch {};
            self.last_meta_len = new_len;
        }
        return offset;
    }

    /// Flush the in-memory buffer to disk
    pub fn flushToDisk(self: *Self) !void {
        if (!self.dirty) return;

        // Open/create file if not already open
        if (self.file == null) {
            self.file = try std.fs.cwd().createFile(self.file_path, .{ .read = true, .truncate = true });
        }

        const current_len = self.current_len.load(.acquire);
        const file = self.file.?;

        // Write only the used portion
        try file.seekTo(0);
        try file.writeAll(self.data[0..current_len]);
        try file.sync();

        self.dirty = false;
    }

    pub fn readRecord(self: *Self, offset: u64) ?Record {
        const current_len = self.current_len.load(.acquire);
        if (offset < header_size) return null;
        if (offset + record_header_len > current_len) return null;
        var cursor = offset;
        var pubkey = core.Pubkey{ .data = undefined };
        @memcpy(&pubkey.data, self.data[cursor..][0..32]);
        cursor += 32;
        const lamports = std.mem.readInt(u64, self.data[cursor..][0..8], .little);
        cursor += 8;
        var owner = core.Pubkey{ .data = undefined };
        @memcpy(&owner.data, self.data[cursor..][0..32]);
        cursor += 32;
        const executable = self.data[cursor] != 0;
        cursor += 1;
        const rent_epoch = std.mem.readInt(u64, self.data[cursor..][0..8], .little);
        cursor += 8;
        const data_len = std.mem.readInt(u32, self.data[cursor..][0..4], .little);
        cursor += 4;
        const total_len = record_header_len + @as(usize, data_len);
        if (cursor + data_len > current_len) return null;
        const data = self.data[cursor..][0..data_len];
        return .{
            .pubkey = pubkey,
            .account = .{
                .lamports = lamports,
                .owner = owner,
                .executable = executable,
                .rent_epoch = rent_epoch,
                .data = data,
            },
            .total_len = @intCast(total_len),
        };
    }

    pub fn firstRecordOffset(_: *Self) u64 {
        return @intCast(header_size);
    }

    fn writeHeader(_: *Self, file: std.fs.File, len: u64) !void {
        var header: [header_size]u8 = .{0} ** header_size;
        @memcpy(header[0..8], &header_magic);
        std.mem.writeInt(u32, header[8..][0..4], 1, .little);
        std.mem.writeInt(u64, header[12..][0..8], len, .little);
        try file.pwriteAll(&header, 0);
        try file.sync();
    }

    fn readHeaderLen(_: *Self, file: std.fs.File) !u64 {
        var header: [header_size]u8 = undefined;
        _ = try file.preadAll(&header, 0);
        if (!std.mem.eql(u8, header[0..8], &header_magic)) {
            return error.InvalidHeader;
        }
        return std.mem.readInt(u64, header[12..][0..8], .little);
    }

    fn updateHeaderLen(self: *Self, len: u64) void {
        if (self.data.len < header_size) return;
        std.mem.writeInt(u64, self.data[12..][0..8], len, .little);
    }

    pub fn flushMeta(self: *Self) !void {
        const len = self.current_len.load(.acquire);
        try self.persistMeta(len);
    }

    fn metaPath(self: *Self) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.len", .{self.file_path});
    }

    fn persistMeta(self: *Self, len: u64) !void {
        const meta_path = try self.metaPath();
        defer self.allocator.free(meta_path);
        const file = try std.fs.cwd().createFile(meta_path, .{ .truncate = true });
        defer file.close();
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, len, .little);
        try file.writeAll(&buf);
        self.last_meta_len = len;
    }

    fn readMeta(self: *Self) ?u64 {
        const meta_path = self.metaPath() catch return null;
        defer self.allocator.free(meta_path);
        var file = std.fs.cwd().openFile(meta_path, .{ .mode = .read_only }) catch return null;
        defer file.close();
        var buf: [8]u8 = undefined;
        const n = file.readAll(&buf) catch return null;
        if (n != buf.len) return null;
        return std.mem.readInt(u64, &buf, .little);
    }
};

/// LRU cache for recently accessed accounts
///
/// OPTIMIZATION: Uses access counter instead of timestamp to avoid syscall overhead.
/// Eviction happens when cache exceeds max_size, removing ~25% of oldest entries.
pub const AccountCache = struct {
    allocator: std.mem.Allocator,
    lock: std.Thread.Mutex,
    entries: std.AutoHashMap(core.Pubkey, CacheEntry),
    max_size: usize,
    /// Global access counter (monotonically increasing)
    access_counter: u64,
    /// Cache statistics
    hits: u64,
    misses: u64,

    const Self = @This();

    const CacheEntry = struct {
        account: AccountView,
        /// Access order (higher = more recent)
        access_order: u64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .lock = .{},
            .entries = std.AutoHashMap(core.Pubkey, CacheEntry).init(allocator),
            .max_size = 100_000, // Default cache size
            .access_counter = 0,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    /// Get an account from cache
    /// NOTE: Returns a copy of the pointer - caller must not hold reference across slot boundaries
    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?AccountView {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.getPtr(pubkey.*)) |e| {
            self.access_counter += 1;
            e.access_order = self.access_counter;
            self.hits += 1;
            return e.account;
        }
        self.misses += 1;
        return null;
    }

    /// Insert an account into cache, evicting old entries if needed
    pub fn insert(self: *Self, pubkey: *const core.Pubkey, account: AccountView) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Check if eviction is needed
        if (self.entries.count() >= self.max_size) {
            self.evictOldest();
        }

        self.access_counter += 1;
        try self.entries.put(pubkey.*, .{
            .account = account,
            .access_order = self.access_counter,
        });
    }

    /// Evict approximately 25% of oldest entries
    fn evictOldest(self: *Self) void {
        const target_count = self.max_size * 3 / 4;
        const current_count = self.entries.count();

        if (current_count <= target_count) return;

        const to_remove = current_count - target_count;

        // Find threshold access_order (entries below this will be removed)
        // Simple approach: collect all access_orders, sort, find threshold
        var min_order: u64 = std.math.maxInt(u64);
        var max_order: u64 = 0;

        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            if (entry.access_order < min_order) min_order = entry.access_order;
            if (entry.access_order > max_order) max_order = entry.access_order;
        }

        // Estimate threshold (simple linear interpolation)
        const range = max_order - min_order;
        if (range == 0) return;

        const threshold_fraction = @as(f64, @floatFromInt(to_remove)) / @as(f64, @floatFromInt(current_count));
        const threshold_offset = @as(u64, @intFromFloat(threshold_fraction * @as(f64, @floatFromInt(range))));
        const threshold = min_order + threshold_offset;

        // Collect keys to remove (avoid modifying during iteration)
        var keys_to_remove: [256]core.Pubkey = undefined;
        var remove_count: usize = 0;

        var key_iter = self.entries.iterator();
        while (key_iter.next()) |kv| {
            if (kv.value_ptr.access_order <= threshold and remove_count < 256) {
                keys_to_remove[remove_count] = kv.key_ptr.*;
                remove_count += 1;
            }
        }

        // Remove collected keys
        for (keys_to_remove[0..remove_count]) |key| {
            _ = self.entries.remove(key);
        }
    }

    /// Get cache hit rate
    pub fn hitRate(self: *const Self) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    /// Clear the cache
    pub fn clear(self: *Self) void {
        self.entries.clearRetainingCapacity();
        self.access_counter = 0;
        self.hits = 0;
        self.misses = 0;
    }
};

/// Shadow cache for VexStore primary reads (owns account memory)
pub const ShadowAccountCache = struct {
    allocator: std.mem.Allocator,
    lock: std.Thread.Mutex,
    entries: std.AutoHashMap(core.Pubkey, ShadowCacheEntry),
    max_size: usize,
    access_counter: u64,

    const Self = @This();

    const ShadowCacheEntry = struct {
        account: *Account,
        access_order: u64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .lock = .{},
            .entries = std.AutoHashMap(core.Pubkey, ShadowCacheEntry).init(allocator),
            .max_size = 10_000,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            self.freeAccount(entry.account);
        }
        self.entries.deinit();
    }

    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?*const Account {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.getPtr(pubkey.*)) |entry| {
            self.access_counter += 1;
            entry.access_order = self.access_counter;
            return entry.account;
        }
        return null;
    }

    pub fn insert(self: *Self, pubkey: *const core.Pubkey, account: *Account) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.count() >= self.max_size) {
            self.evictOldest();
        }
        self.access_counter += 1;
        try self.entries.put(pubkey.*, .{
            .account = account,
            .access_order = self.access_counter,
        });
    }

    pub fn freeAccount(self: *Self, account: *Account) void {
        self.allocator.free(account.data);
        self.allocator.destroy(account);
    }

    fn evictOldest(self: *Self) void {
        var oldest_key: ?core.Pubkey = null;
        var oldest_access: u64 = std.math.maxInt(u64);
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.access_order < oldest_access) {
                oldest_access = entry.value_ptr.access_order;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |entry| {
                self.freeAccount(entry.value.account);
            }
        }
    }
};

fn deserializeAccount(allocator: std.mem.Allocator, data: []const u8) !*Account {
    const header_len: usize = 8 + 32 + 1 + 8 + 4;
    if (data.len < header_len) return error.MalformedAccount;
    var offset: usize = 0;
    const lamports = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    var owner = core.Pubkey{ .data = undefined };
    @memcpy(&owner.data, data[offset..][0..32]);
    offset += 32;
    const executable = data[offset] != 0;
    offset += 1;
    const rent_epoch = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    const data_len = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    if (offset + data_len > data.len) return error.MalformedAccount;

    const buf = try allocator.alloc(u8, data_len);
    @memcpy(buf, data[offset..][0..data_len]);

    const account = try allocator.create(Account);
    account.* = .{
        .lamports = lamports,
        .owner = owner,
        .executable = executable,
        .rent_epoch = rent_epoch,
        .data = buf,
    };
    return account;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "accounts db init" {
    var db = try AccountsDb.init(std.testing.allocator, "/tmp/test_accounts", null);
    defer db.deinit();

    const pubkey = core.Pubkey{ .data = [_]u8{1} ** 32 };
    try std.testing.expect(db.getAccount(&pubkey) == null);
}

test "account index" {
    var index = AccountIndex.init(std.testing.allocator);
    defer index.deinit();

    const pubkey = core.Pubkey{ .data = [_]u8{1} ** 32 };
    const location = AccountLocation{
        .store_id = 1,
        .offset = 100,
        .slot = 50,
    };

    try index.insert(&pubkey, location);
    const found = index.get(&pubkey);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 1), found.?.store_id);
}

test "account storage appendvec read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var storage = try AccountStorage.init(std.testing.allocator, path, 64 * 1024 * 1024);
    defer storage.deinit();

    const pubkey = core.Pubkey{ .data = [_]u8{3} ** 32 };
    const owner = core.Pubkey{ .data = [_]u8{4} ** 32 };
    const account = Account{
        .lamports = 999,
        .owner = owner,
        .executable = true,
        .rent_epoch = 42,
        .data = "appendvec",
    };

    const location = try storage.writeAccount(&pubkey, &account, 7);
    const got = storage.readAccount(location) orelse return error.MissingAccount;

    try std.testing.expectEqual(account.lamports, got.lamports);
    try std.testing.expectEqualSlices(u8, &account.owner.data, &got.owner.data);
    try std.testing.expectEqual(account.executable, got.executable);
    try std.testing.expectEqual(account.rent_epoch, got.rent_epoch);
    try std.testing.expectEqualSlices(u8, account.data, got.data);
}
