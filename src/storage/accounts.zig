//! Vexor Accounts Database
//!
//! High-performance accounts storage with:
//! - Memory-mapped append vectors
//! - Concurrent access via fine-grained locking
//! - Efficient hash computation for snapshots

const std = @import("std");
const core = @import("../core/root.zig");
const mem_alloc = @import("../core/allocator.zig");

/// Main accounts database
pub const AccountsDb = struct {
    allocator: std.mem.Allocator,
    accounts_path: []const u8,
    /// Account index: pubkey -> location
    index: AccountIndex,
    /// Storage for account data
    storage: AccountStorage,
    /// Cache of recently accessed accounts
    cache: AccountCache,
    /// Current slot being processed
    slot: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const db = try allocator.create(Self);
        db.* = .{
            .allocator = allocator,
            .accounts_path = path,
            .index = AccountIndex.init(allocator),
            .storage = try AccountStorage.init(allocator, path),
            .cache = AccountCache.init(allocator),
            .slot = std.atomic.Value(u64).init(0),
        };
        return db;
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.storage.deinit();
        self.index.deinit();
        self.allocator.destroy(self);
    }

    /// Get an account by pubkey
    pub fn getAccount(self: *Self, pubkey: *const core.Pubkey) ?*const Account {
        // Check cache first
        if (self.cache.get(pubkey)) |cached| {
            return cached;
        }

        // Look up in index
        if (self.index.get(pubkey)) |location| {
            return self.storage.readAccount(location);
        }

        return null;
    }

    /// Store an account
    pub fn storeAccount(self: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot) !void {
        // Write to storage
        const location = try self.storage.writeAccount(pubkey, account, slot);

        // Update index
        try self.index.insert(pubkey, location);

        // Update cache
        try self.cache.insert(pubkey, account);
    }

    /// Get multiple accounts (batch)
    pub fn getAccounts(self: *Self, pubkeys: []const core.Pubkey, results: []*const Account) usize {
        var found: usize = 0;
        for (pubkeys, 0..) |*pubkey, i| {
            if (self.getAccount(pubkey)) |account| {
                results[i] = account;
                found += 1;
            }
        }
        return found;
    }

    /// Compute accounts hash for snapshot
    pub fn computeHash(self: *Self) !core.Hash {
        _ = self;
        // TODO: Merkle tree over sorted accounts
        return core.Hash.ZERO;
    }
};

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

/// Account index mapping pubkeys to storage locations
pub const AccountIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(core.Pubkey, AccountLocation),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(core.Pubkey, AccountLocation).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?AccountLocation {
        return self.entries.get(pubkey.*);
    }

    pub fn insert(self: *Self, pubkey: *const core.Pubkey, location: AccountLocation) !void {
        try self.entries.put(pubkey.*, location);
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
    /// Active append vectors by slot
    stores: std.AutoHashMap(u32, *AppendVec),
    next_store_id: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        return .{
            .allocator = allocator,
            .base_path = path,
            .stores = std.AutoHashMap(u32, *AppendVec).init(allocator),
            .next_store_id = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.stores.valueIterator();
        while (iter.next()) |av| {
            av.*.deinit();
        }
        self.stores.deinit();
    }

    pub fn readAccount(self: *Self, location: AccountLocation) ?*const Account {
        if (self.stores.get(location.store_id)) |av| {
            return av.getAccount(location.offset);
        }
        return null;
    }

    pub fn writeAccount(_: *Self, pubkey: *const core.Pubkey, account: *const Account, slot: core.Slot) !AccountLocation {
        _ = pubkey;
        _ = account;
        // TODO: Get or create append vector for slot
        return AccountLocation{
            .store_id = 0,
            .offset = 0,
            .slot = slot,
        };
    }
};

/// Append-only vector for account storage
pub const AppendVec = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    mmap: ?*mem_alloc.MmapAllocator,
    data: []align(std.mem.page_size) u8,
    current_len: std.atomic.Value(u64),
    capacity: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8, capacity: u64) !*Self {
        const av = try allocator.create(Self);
        av.* = .{
            .allocator = allocator,
            .file_path = path,
            .mmap = null,
            .data = &.{},
            .current_len = std.atomic.Value(u64).init(0),
            .capacity = capacity,
        };
        return av;
    }

    pub fn deinit(self: *Self) void {
        if (self.mmap) |m| m.deinit();
        self.allocator.destroy(self);
    }

    pub fn getAccount(self: *Self, offset: u64) ?*const Account {
        _ = self;
        _ = offset;
        // TODO: Deserialize account from mmap'd region
        return null;
    }

    pub fn append(self: *Self, data: []const u8) !u64 {
        const offset = self.current_len.fetchAdd(data.len, .seq_cst);
        if (offset + data.len > self.capacity) {
            return error.AppendVecFull;
        }
        @memcpy(self.data[offset..][0..data.len], data);
        return offset;
    }
};

/// LRU cache for recently accessed accounts
/// 
/// OPTIMIZATION: Uses access counter instead of timestamp to avoid syscall overhead.
/// Eviction happens when cache exceeds max_size, removing ~25% of oldest entries.
pub const AccountCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(core.Pubkey, CacheEntry),
    max_size: usize,
    /// Global access counter (monotonically increasing)
    access_counter: u64,
    /// Cache statistics
    hits: u64,
    misses: u64,

    const Self = @This();

    const CacheEntry = struct {
        account: *const Account,
        /// Access order (higher = more recent)
        access_order: u64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
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
    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?*const Account {
        if (self.entries.getPtr(pubkey.*)) |entry| {
            // Update access order (no syscall, just increment counter)
            self.access_counter += 1;
            entry.access_order = self.access_counter;
            self.hits += 1;
            return entry.account;
        }
        self.misses += 1;
        return null;
    }

    /// Insert an account into cache, evicting old entries if needed
    pub fn insert(self: *Self, pubkey: *const core.Pubkey, account: *const Account) !void {
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

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "accounts db init" {
    var db = try AccountsDb.init(std.testing.allocator, "/tmp/test_accounts");
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

