//! Vexor Accounts Index
//!
//! High-performance index for account lookups.
//! Maps pubkeys to account locations in storage.
//!
//! Features:
//! - O(1) lookup by pubkey
//! - Efficient iteration by program owner
//! - Version tracking for forks
//! - Memory-mapped backing

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const RwLock = Thread.RwLock;

/// Account pubkey (32 bytes)
pub const Pubkey = [32]u8;

/// Account location in storage
pub const AccountLocation = struct {
    /// Slot this version was stored at
    slot: u64,
    /// Offset in AppendVec
    offset: u64,
    /// AppendVec ID
    store_id: u32,
    /// Account data length
    data_len: u32,
    /// Lamports at this slot
    lamports: u64,
    /// Write version (for ordering)
    write_version: u64,
};

/// Account index entry
pub const IndexEntry = struct {
    /// Account pubkey
    pubkey: Pubkey,
    /// Current location
    location: AccountLocation,
    /// Previous location (for versioning)
    previous: ?*IndexEntry,
    /// Account owner
    owner: Pubkey,
    /// Is this account executable
    executable: bool,
    /// Rent epoch
    rent_epoch: u64,
};

/// Root slot tracking
pub const RootEntry = struct {
    slot: u64,
    bank_hash: [32]u8,
    accounts_hash: [32]u8,
};

/// Accounts index
pub const AccountsIndex = struct {
    allocator: Allocator,

    /// Primary index: pubkey -> entry
    index: std.AutoHashMap(Pubkey, *IndexEntry),
    index_lock: RwLock,

    /// Secondary index: owner -> pubkeys
    program_index: std.AutoHashMap(Pubkey, std.ArrayList(Pubkey)),
    program_lock: RwLock,

    /// Root slots
    roots: std.ArrayList(RootEntry),
    roots_lock: Mutex,

    /// Latest slot in index
    latest_slot: u64,

    /// Statistics
    stats: IndexStats,

    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const idx = try allocator.create(Self);

        idx.* = Self{
            .allocator = allocator,
            .index = std.AutoHashMap(Pubkey, *IndexEntry).init(allocator),
            .index_lock = .{},
            .program_index = std.AutoHashMap(Pubkey, std.ArrayList(Pubkey)).init(allocator),
            .program_lock = .{},
            .roots = std.ArrayList(RootEntry).init(allocator),
            .roots_lock = .{},
            .latest_slot = 0,
            .stats = .{},
        };

        return idx;
    }

    pub fn deinit(self: *Self) void {
        // Free all entries
        var iter = self.index.valueIterator();
        while (iter.next()) |entry| {
            self.freeEntry(entry.*);
        }
        self.index.deinit();

        // Free program index
        var prog_iter = self.program_index.valueIterator();
        while (prog_iter.next()) |list| {
            list.deinit();
        }
        self.program_index.deinit();

        self.roots.deinit();
        self.allocator.destroy(self);
    }

    fn freeEntry(self: *Self, entry: *IndexEntry) void {
        // Free chain
        var current: ?*IndexEntry = entry.previous;
        while (current) |e| {
            const next = e.previous;
            self.allocator.destroy(e);
            current = next;
        }
        self.allocator.destroy(entry);
    }

    /// Insert or update account
    /// 
    /// SAFETY: Allocation happens outside of locks to reduce contention.
    /// Lock ordering: index_lock -> program_lock (never reversed)
    pub fn upsert(
        self: *Self,
        pubkey: Pubkey,
        location: AccountLocation,
        owner: Pubkey,
        executable: bool,
        rent_epoch: u64,
    ) !void {
        // Pre-allocate entry OUTSIDE of lock to reduce lock contention
        const new_entry = try self.allocator.create(IndexEntry);
        errdefer self.allocator.destroy(new_entry);
        
        new_entry.* = IndexEntry{
            .pubkey = pubkey,
            .location = location,
            .previous = null,
            .owner = owner,
            .executable = executable,
            .rent_epoch = rent_epoch,
        };
        
        var is_new_insert = false;
        
        // Acquire index lock
        self.index_lock.lock();
        defer self.index_lock.unlock();

        if (self.index.getPtr(pubkey)) |existing_ptr| {
            const existing = existing_ptr.*;
            // Link to previous version
            new_entry.previous = existing;
            existing_ptr.* = new_entry;
            _ = @atomicRmw(u64, &self.stats.updates, .Add, 1, .monotonic);
        } else {
            try self.index.put(pubkey, new_entry);
            _ = @atomicRmw(u64, &self.stats.inserts, .Add, 1, .monotonic);
            is_new_insert = true;
        }

        if (location.slot > self.latest_slot) {
            self.latest_slot = location.slot;
        }
        
        // Update program index AFTER releasing index_lock to prevent deadlock
        // NOTE: We still hold index_lock here, but program_lock acquisition
        // is done with consistent ordering (index first, program second)
        if (is_new_insert) {
            self.addToProgramIndexLocked(owner, pubkey) catch {};
        }
    }

    /// Add to program index (called with index_lock held)
    /// Lock ordering: Always acquire program_lock AFTER index_lock
    fn addToProgramIndexLocked(self: *Self, owner: Pubkey, pubkey: Pubkey) !void {
        self.program_lock.lock();
        defer self.program_lock.unlock();

        if (self.program_index.getPtr(owner)) |list| {
            try list.append(pubkey);
        } else {
            var list = std.ArrayList(Pubkey).init(self.allocator);
            try list.append(pubkey);
            try self.program_index.put(owner, list);
        }
    }

    /// Look up account
    pub fn get(self: *Self, pubkey: Pubkey) ?*const IndexEntry {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();

        if (self.index.get(pubkey)) |entry| {
            _ = @atomicRmw(u64, &self.stats.lookups, .Add, 1, .monotonic);
            return entry;
        }
        _ = @atomicRmw(u64, &self.stats.misses, .Add, 1, .monotonic);
        return null;
    }

    /// Look up account at specific slot
    pub fn getAtSlot(self: *Self, pubkey: Pubkey, slot: u64) ?*const IndexEntry {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();

        var entry: ?*const IndexEntry = self.index.get(pubkey);

        // Walk back to find version at slot
        while (entry) |e| {
            if (e.location.slot <= slot) {
                return e;
            }
            entry = e.previous;
        }

        return null;
    }

    /// Get accounts by program owner
    pub fn getByProgram(self: *Self, owner: Pubkey) ?[]const Pubkey {
        self.program_lock.lockShared();
        defer self.program_lock.unlockShared();

        if (self.program_index.get(owner)) |list| {
            return list.items;
        }
        return null;
    }

    /// Check if account exists
    pub fn contains(self: *Self, pubkey: Pubkey) bool {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        return self.index.contains(pubkey);
    }

    /// Remove account
    pub fn remove(self: *Self, pubkey: Pubkey) bool {
        self.index_lock.lock();
        defer self.index_lock.unlock();

        if (self.index.fetchRemove(pubkey)) |removed| {
            self.freeEntry(removed.value);
            _ = @atomicRmw(u64, &self.stats.removes, .Add, 1, .monotonic);
            return true;
        }
        return false;
    }

    /// Add root slot
    pub fn addRoot(self: *Self, slot: u64, bank_hash: [32]u8, accounts_hash: [32]u8) !void {
        self.roots_lock.lock();
        defer self.roots_lock.unlock();

        try self.roots.append(RootEntry{
            .slot = slot,
            .bank_hash = bank_hash,
            .accounts_hash = accounts_hash,
        });

        _ = @atomicRmw(u64, &self.stats.roots_added, .Add, 1, .monotonic);
    }

    /// Get latest root
    pub fn latestRoot(self: *Self) ?u64 {
        self.roots_lock.lock();
        defer self.roots_lock.unlock();

        if (self.roots.items.len == 0) return null;
        return self.roots.items[self.roots.items.len - 1].slot;
    }

    /// Clean old versions (keep only rooted slots)
    pub fn clean(self: *Self, min_slot: u64) !usize {
        self.index_lock.lock();
        defer self.index_lock.unlock();

        var cleaned: usize = 0;

        var iter = self.index.valueIterator();
        while (iter.next()) |entry_ptr| {
            var entry = entry_ptr.*;
            var prev_ptr: ?*?*IndexEntry = null;

            while (entry.previous) |prev| {
                if (prev.location.slot < min_slot) {
                    // Unlink and free
                    if (prev_ptr) |pp| {
                        pp.* = prev.previous;
                    } else {
                        entry.previous = prev.previous;
                    }
                    self.allocator.destroy(prev);
                    cleaned += 1;
                } else {
                    prev_ptr = &entry.previous;
                }
            }
        }

        _ = @atomicRmw(u64, &self.stats.cleaned, .Add, cleaned, .monotonic);
        return cleaned;
    }

    /// Get account count
    pub fn count(self: *Self) usize {
        self.index_lock.lockShared();
        defer self.index_lock.unlockShared();
        return self.index.count();
    }

    /// Get statistics
    pub fn getStats(self: *const Self) IndexStats {
        return self.stats;
    }

    /// Iterate all accounts (for serialization)
    pub fn iterate(self: *Self) AccountIterator {
        return AccountIterator{
            .index = self,
            .inner = self.index.iterator(),
        };
    }
};

/// Account iterator
pub const AccountIterator = struct {
    index: *AccountsIndex,
    inner: std.AutoHashMap(Pubkey, *IndexEntry).Iterator,

    const Self = @This();

    pub fn next(self: *Self) ?*const IndexEntry {
        if (self.inner.next()) |kv| {
            return kv.value_ptr.*;
        }
        return null;
    }
};

/// Index statistics
pub const IndexStats = struct {
    inserts: u64 = 0,
    updates: u64 = 0,
    removes: u64 = 0,
    lookups: u64 = 0,
    misses: u64 = 0,
    roots_added: u64 = 0,
    cleaned: u64 = 0,

    pub fn hitRate(self: *const IndexStats) f64 {
        const total = self.lookups + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.lookups)) / @as(f64, @floatFromInt(total));
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "accounts index init" {
    const allocator = std.testing.allocator;

    const index = try AccountsIndex.init(allocator);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.count());
}

test "accounts index insert and lookup" {
    const allocator = std.testing.allocator;

    const index = try AccountsIndex.init(allocator);
    defer index.deinit();

    var pubkey: Pubkey = undefined;
    @memset(&pubkey, 0x11);

    var owner: Pubkey = undefined;
    @memset(&owner, 0x22);

    const location = AccountLocation{
        .slot = 100,
        .offset = 0,
        .store_id = 1,
        .data_len = 100,
        .lamports = 1_000_000,
        .write_version = 1,
    };

    try index.upsert(pubkey, location, owner, false, 0);

    try std.testing.expectEqual(@as(usize, 1), index.count());

    const entry = index.get(pubkey);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u64, 100), entry.?.location.slot);
}

test "accounts index versioning" {
    const allocator = std.testing.allocator;

    const index = try AccountsIndex.init(allocator);
    defer index.deinit();

    var pubkey: Pubkey = undefined;
    @memset(&pubkey, 0x11);

    var owner: Pubkey = undefined;
    @memset(&owner, 0x22);

    // Insert version at slot 100
    try index.upsert(pubkey, .{
        .slot = 100,
        .offset = 0,
        .store_id = 1,
        .data_len = 100,
        .lamports = 1_000_000,
        .write_version = 1,
    }, owner, false, 0);

    // Update at slot 200
    try index.upsert(pubkey, .{
        .slot = 200,
        .offset = 100,
        .store_id = 1,
        .data_len = 100,
        .lamports = 2_000_000,
        .write_version = 2,
    }, owner, false, 0);

    // Current should be slot 200
    const current = index.get(pubkey);
    try std.testing.expectEqual(@as(u64, 200), current.?.location.slot);

    // Get at slot 150 should return slot 100 version
    const at_150 = index.getAtSlot(pubkey, 150);
    try std.testing.expectEqual(@as(u64, 100), at_150.?.location.slot);
}

