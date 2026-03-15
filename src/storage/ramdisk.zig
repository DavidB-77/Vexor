//! Vexor RAM Disk Manager
//!
//! Tier-0 storage using tmpfs for ultra-low latency access.
//! Used for hot data like recent account state and pending transactions.

const std = @import("std");
const core = @import("../core/root.zig");

/// RAM disk manager for tier-0 storage
pub const RamdiskManager = struct {
    allocator: std.mem.Allocator,
    mount_path: []const u8,
    max_size: usize,
    used_size: std.atomic.Value(usize),
    /// Hot accounts cache
    hot_accounts: HotAccountsStore,
    /// Pending transactions
    pending_txs: PendingTransactionStore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !*Self {
        const manager = try allocator.create(Self);
        manager.* = .{
            .allocator = allocator,
            .mount_path = path,
            .max_size = max_size,
            .used_size = std.atomic.Value(usize).init(0),
            .hot_accounts = HotAccountsStore.init(allocator),
            .pending_txs = PendingTransactionStore.init(allocator),
        };

        // Verify mount point exists and is tmpfs
        try manager.verifyMount();

        return manager;
    }

    pub fn deinit(self: *Self) void {
        self.hot_accounts.deinit();
        self.pending_txs.deinit();
        self.allocator.destroy(self);
    }

    fn verifyMount(self: *Self) !void {
        // Check if path exists
        std.fs.accessAbsolute(self.mount_path, .{}) catch |err| {
            std.debug.print("Warning: RAM disk path {s} not accessible: {}\n", .{ self.mount_path, err });
            return err;
        };

        // TODO: Verify it's actually tmpfs via /proc/mounts
    }

    /// Get available space
    pub fn availableSpace(self: *Self) usize {
        return self.max_size - self.used_size.load(.seq_cst);
    }

    /// Check if we should evict data
    pub fn shouldEvict(self: *Self) bool {
        return self.used_size.load(.seq_cst) > (self.max_size * 90 / 100); // >90% full
    }

    /// Evict cold data to NVMe
    pub fn evictColdData(self: *Self) !usize {
        _ = self;
        // TODO: Move least recently accessed data to tier-1
        return 0;
    }
};

/// Hot accounts stored in RAM disk
pub const HotAccountsStore = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap(core.Pubkey, HotAccount),

    const Self = @This();

    pub const HotAccount = struct {
        lamports: u64,
        data: []u8,
        last_access: i64,
        access_count: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .accounts = std.AutoHashMap(core.Pubkey, HotAccount).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.accounts.valueIterator();
        while (iter.next()) |account| {
            self.allocator.free(account.data);
        }
        self.accounts.deinit();
    }

    pub fn get(self: *Self, pubkey: *const core.Pubkey) ?*HotAccount {
        if (self.accounts.getPtr(pubkey.*)) |account| {
            account.last_access = std.time.timestamp();
            account.access_count += 1;
            return account;
        }
        return null;
    }

    pub fn put(self: *Self, pubkey: *const core.Pubkey, lamports: u64, data: []const u8) !void {
        const data_copy = try self.allocator.dupe(u8, data);
        try self.accounts.put(pubkey.*, .{
            .lamports = lamports,
            .data = data_copy,
            .last_access = std.time.timestamp(),
            .access_count = 1,
        });
    }
};

/// Pending transactions in RAM disk
pub const PendingTransactionStore = struct {
    allocator: std.mem.Allocator,
    transactions: std.AutoHashMap(core.Signature, PendingTransaction),

    const Self = @This();

    pub const PendingTransaction = struct {
        data: []u8,
        received_at: i64,
        priority_fee: u64,
        forwarded: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .transactions = std.AutoHashMap(core.Signature, PendingTransaction).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.transactions.valueIterator();
        while (iter.next()) |tx| {
            self.allocator.free(tx.data);
        }
        self.transactions.deinit();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "hot accounts store" {
    var store = HotAccountsStore.init(std.testing.allocator);
    defer store.deinit();

    const pubkey = core.Pubkey{ .data = [_]u8{1} ** 32 };
    try store.put(&pubkey, 1000000, "test data");

    const account = store.get(&pubkey);
    try std.testing.expect(account != null);
    try std.testing.expectEqual(@as(u64, 1000000), account.?.lamports);
}

