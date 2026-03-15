//! WebSocket Subscription Manager
//! Manages real-time subscriptions for Solana RPC.
//!
//! Supported subscriptions:
//! - accountSubscribe: Watch for account changes
//! - slotSubscribe: Watch for slot updates
//! - signatureSubscribe: Watch for transaction confirmations
//! - logsSubscribe: Watch for program logs
//! - programSubscribe: Watch for program account changes
//! - rootSubscribe: Watch for root updates
//! - blockSubscribe: Watch for new blocks
//! - voteSubscribe: Watch for vote updates

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

/// Subscription types
pub const SubscriptionType = enum {
    account,
    slot,
    signature,
    logs,
    program,
    root,
    block,
    vote,
};

/// Account subscription configuration
pub const AccountConfig = struct {
    pubkey: [32]u8,
    encoding: Encoding = .base64,
    commitment: Commitment = .finalized,
    data_slice: ?DataSlice = null,
};

/// Program subscription configuration
pub const ProgramConfig = struct {
    program_id: [32]u8,
    encoding: Encoding = .base64,
    commitment: Commitment = .finalized,
    filters: []const Filter = &.{},
};

/// Signature subscription configuration
pub const SignatureConfig = struct {
    signature: [64]u8,
    commitment: Commitment = .finalized,
    enable_received_notification: bool = false,
};

/// Logs subscription configuration
pub const LogsConfig = struct {
    filter: LogsFilter,
    commitment: Commitment = .finalized,
};

/// Log filter types
pub const LogsFilter = union(enum) {
    all: void,
    all_with_votes: void,
    mentions: [32]u8,
};

/// Data encoding
pub const Encoding = enum {
    base58,
    base64,
    base64_zstd,
    json_parsed,
};

/// Commitment level
pub const Commitment = enum {
    processed,
    confirmed,
    finalized,
};

/// Data slice for partial account data
pub const DataSlice = struct {
    offset: usize,
    length: usize,
};

/// Filter for program subscriptions
pub const Filter = union(enum) {
    memcmp: struct {
        offset: usize,
        bytes: []const u8,
    },
    data_size: usize,
};

/// Subscription handle
pub const SubscriptionId = u64;

/// Active subscription
pub const Subscription = struct {
    id: SubscriptionId,
    sub_type: SubscriptionType,
    config: SubscriptionConfig,
    connection_id: u64,
    created_at: i64,
    last_notification: i64,
    notification_count: u64,
};

/// Union of all subscription configs
pub const SubscriptionConfig = union(SubscriptionType) {
    account: AccountConfig,
    slot: void,
    signature: SignatureConfig,
    logs: LogsConfig,
    program: ProgramConfig,
    root: void,
    block: Commitment,
    vote: void,
};

/// Notification payload
pub const Notification = struct {
    subscription_id: SubscriptionId,
    payload: NotificationPayload,
};

/// Notification payload variants
pub const NotificationPayload = union(enum) {
    account: AccountNotification,
    slot: SlotNotification,
    signature: SignatureNotification,
    logs: LogsNotification,
    program: ProgramNotification,
    root: u64,
    block: BlockNotification,
    vote: VoteNotification,
};

pub const AccountNotification = struct {
    lamports: u64,
    data: []const u8,
    owner: [32]u8,
    executable: bool,
    rent_epoch: u64,
    slot: u64,
};

pub const SlotNotification = struct {
    parent: u64,
    root: u64,
    slot: u64,
};

pub const SignatureNotification = struct {
    slot: u64,
    err: ?[]const u8,
};

pub const LogsNotification = struct {
    signature: [64]u8,
    err: ?[]const u8,
    logs: []const []const u8,
};

pub const ProgramNotification = struct {
    pubkey: [32]u8,
    account: AccountNotification,
};

pub const BlockNotification = struct {
    slot: u64,
    block_time: ?i64,
    blockhash: [32]u8,
};

pub const VoteNotification = struct {
    vote_pubkey: [32]u8,
    slots: []const u64,
    hash: [32]u8,
    timestamp: ?i64,
};

/// Subscription manager
pub const SubscriptionManager = struct {
    /// Active subscriptions by ID
    subscriptions: std.AutoHashMap(SubscriptionId, Subscription),

    /// Account subscriptions by pubkey
    account_subs: std.AutoHashMap([32]u8, std.ArrayList(SubscriptionId)),

    /// Program subscriptions by program ID
    program_subs: std.AutoHashMap([32]u8, std.ArrayList(SubscriptionId)),

    /// Signature subscriptions by signature
    signature_subs: std.AutoHashMap([64]u8, SubscriptionId),

    /// Slot subscribers
    slot_subs: std.ArrayList(SubscriptionId),

    /// Root subscribers
    root_subs: std.ArrayList(SubscriptionId),

    /// Vote subscribers
    vote_subs: std.ArrayList(SubscriptionId),

    /// Block subscribers
    block_subs: std.ArrayList(SubscriptionId),

    /// Logs subscribers
    logs_subs: std.ArrayList(SubscriptionId),

    /// Next subscription ID
    next_id: std.atomic.Value(u64),

    /// Mutex
    mutex: Mutex,

    /// Allocator
    allocator: Allocator,

    /// Notification callback
    notify_fn: ?*const fn (*SubscriptionManager, u64, Notification) void,

    pub fn init(allocator: Allocator) SubscriptionManager {
        return .{
            .subscriptions = std.AutoHashMap(SubscriptionId, Subscription).init(allocator),
            .account_subs = std.AutoHashMap([32]u8, std.ArrayList(SubscriptionId)).init(allocator),
            .program_subs = std.AutoHashMap([32]u8, std.ArrayList(SubscriptionId)).init(allocator),
            .signature_subs = std.AutoHashMap([64]u8, SubscriptionId).init(allocator),
            .slot_subs = std.ArrayList(SubscriptionId).init(allocator),
            .root_subs = std.ArrayList(SubscriptionId).init(allocator),
            .vote_subs = std.ArrayList(SubscriptionId).init(allocator),
            .block_subs = std.ArrayList(SubscriptionId).init(allocator),
            .logs_subs = std.ArrayList(SubscriptionId).init(allocator),
            .next_id = std.atomic.Value(u64).init(1),
            .mutex = .{},
            .allocator = allocator,
            .notify_fn = null,
        };
    }

    pub fn deinit(self: *SubscriptionManager) void {
        // Clean up account subs lists
        var account_iter = self.account_subs.valueIterator();
        while (account_iter.next()) |list| {
            list.deinit();
        }
        self.account_subs.deinit();

        // Clean up program subs lists
        var program_iter = self.program_subs.valueIterator();
        while (program_iter.next()) |list| {
            list.deinit();
        }
        self.program_subs.deinit();

        self.subscriptions.deinit();
        self.signature_subs.deinit();
        self.slot_subs.deinit();
        self.root_subs.deinit();
        self.vote_subs.deinit();
        self.block_subs.deinit();
        self.logs_subs.deinit();
    }

    /// Subscribe to account changes
    pub fn subscribeAccount(self: *SubscriptionManager, connection_id: u64, config: AccountConfig) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .account,
            .config = .{ .account = config },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);

        // Add to account index
        const result = try self.account_subs.getOrPut(config.pubkey);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(SubscriptionId).init(self.allocator);
        }
        try result.value_ptr.append(id);

        return id;
    }

    /// Subscribe to slot updates
    pub fn subscribeSlot(self: *SubscriptionManager, connection_id: u64) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .slot,
            .config = .{ .slot = {} },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);
        try self.slot_subs.append(id);

        return id;
    }

    /// Subscribe to signature confirmation
    pub fn subscribeSignature(self: *SubscriptionManager, connection_id: u64, config: SignatureConfig) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .signature,
            .config = .{ .signature = config },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);
        try self.signature_subs.put(config.signature, id);

        return id;
    }

    /// Subscribe to program account changes
    pub fn subscribeProgram(self: *SubscriptionManager, connection_id: u64, config: ProgramConfig) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .program,
            .config = .{ .program = config },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);

        const result = try self.program_subs.getOrPut(config.program_id);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(SubscriptionId).init(self.allocator);
        }
        try result.value_ptr.append(id);

        return id;
    }

    /// Subscribe to root updates
    pub fn subscribeRoot(self: *SubscriptionManager, connection_id: u64) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .root,
            .config = .{ .root = {} },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);
        try self.root_subs.append(id);

        return id;
    }

    /// Subscribe to vote updates
    pub fn subscribeVote(self: *SubscriptionManager, connection_id: u64) !SubscriptionId {
        const id = self.next_id.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        const sub = Subscription{
            .id = id,
            .sub_type = .vote,
            .config = .{ .vote = {} },
            .connection_id = connection_id,
            .created_at = std.time.timestamp(),
            .last_notification = 0,
            .notification_count = 0,
        };

        try self.subscriptions.put(id, sub);
        try self.vote_subs.append(id);

        return id;
    }

    /// Unsubscribe
    pub fn unsubscribe(self: *SubscriptionManager, id: SubscriptionId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.fetchRemove(id)) |kv| {
            const sub = kv.value;

            // Remove from type-specific index
            switch (sub.sub_type) {
                .account => {
                    if (self.account_subs.getPtr(sub.config.account.pubkey)) |list| {
                        self.removeFromList(list, id);
                    }
                },
                .slot => self.removeFromList(&self.slot_subs, id),
                .signature => _ = self.signature_subs.remove(sub.config.signature.signature),
                .program => {
                    if (self.program_subs.getPtr(sub.config.program.program_id)) |list| {
                        self.removeFromList(list, id);
                    }
                },
                .root => self.removeFromList(&self.root_subs, id),
                .vote => self.removeFromList(&self.vote_subs, id),
                .block => self.removeFromList(&self.block_subs, id),
                .logs => self.removeFromList(&self.logs_subs, id),
            }

            return true;
        }

        return false;
    }

    fn removeFromList(self: *SubscriptionManager, list: *std.ArrayList(SubscriptionId), id: SubscriptionId) void {
        _ = self;
        for (list.items, 0..) |item, i| {
            if (item == id) {
                _ = list.swapRemove(i);
                break;
            }
        }
    }

    /// Notify account change
    pub fn notifyAccountChange(self: *SubscriptionManager, pubkey: *const [32]u8, notification: AccountNotification) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.account_subs.get(pubkey.*)) |subs| {
            for (subs.items) |sub_id| {
                if (self.subscriptions.getPtr(sub_id)) |sub| {
                    self.sendNotification(sub, .{ .account = notification });
                }
            }
        }
    }

    /// Notify slot update
    pub fn notifySlotUpdate(self: *SubscriptionManager, notification: SlotNotification) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slot_subs.items) |sub_id| {
            if (self.subscriptions.getPtr(sub_id)) |sub| {
                self.sendNotification(sub, .{ .slot = notification });
            }
        }
    }

    /// Notify signature confirmation
    pub fn notifySignature(self: *SubscriptionManager, signature: *const [64]u8, notification: SignatureNotification) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.signature_subs.get(signature.*)) |sub_id| {
            if (self.subscriptions.getPtr(sub_id)) |sub| {
                self.sendNotification(sub, .{ .signature = notification });
            }
            // Auto-unsubscribe after confirmation
            _ = self.signature_subs.remove(signature.*);
            _ = self.subscriptions.remove(sub_id);
        }
    }

    /// Notify root update
    pub fn notifyRootUpdate(self: *SubscriptionManager, root: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.root_subs.items) |sub_id| {
            if (self.subscriptions.getPtr(sub_id)) |sub| {
                self.sendNotification(sub, .{ .root = root });
            }
        }
    }

    /// Notify vote
    pub fn notifyVote(self: *SubscriptionManager, notification: VoteNotification) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.vote_subs.items) |sub_id| {
            if (self.subscriptions.getPtr(sub_id)) |sub| {
                self.sendNotification(sub, .{ .vote = notification });
            }
        }
    }

    fn sendNotification(self: *SubscriptionManager, sub: *Subscription, payload: NotificationPayload) void {
        sub.notification_count += 1;
        sub.last_notification = std.time.timestamp();

        if (self.notify_fn) |callback| {
            callback(self, sub.connection_id, .{
                .subscription_id = sub.id,
                .payload = payload,
            });
        }
    }

    /// Get subscription count
    pub fn getSubscriptionCount(self: *SubscriptionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.subscriptions.count();
    }

    /// Get subscriptions for a connection
    pub fn getConnectionSubscriptions(self: *SubscriptionManager, connection_id: u64) ![]SubscriptionId {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(SubscriptionId).init(self.allocator);
        errdefer result.deinit();

        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.connection_id == connection_id) {
                try result.append(entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice();
    }

    /// Remove all subscriptions for a connection
    pub fn removeConnectionSubscriptions(self: *SubscriptionManager, connection_id: u64) !usize {
        const subs = try self.getConnectionSubscriptions(connection_id);
        defer self.allocator.free(subs);

        var removed: usize = 0;
        for (subs) |sub_id| {
            if (self.unsubscribe(sub_id)) {
                removed += 1;
            }
        }

        return removed;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SubscriptionManager: subscribe account" {
    const allocator = std.testing.allocator;

    var manager = SubscriptionManager.init(allocator);
    defer manager.deinit();

    const pubkey = [_]u8{1} ** 32;
    const id = try manager.subscribeAccount(1, .{ .pubkey = pubkey });

    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(usize, 1), manager.getSubscriptionCount());
}

test "SubscriptionManager: subscribe slot" {
    const allocator = std.testing.allocator;

    var manager = SubscriptionManager.init(allocator);
    defer manager.deinit();

    const id = try manager.subscribeSlot(1);

    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(usize, 1), manager.getSubscriptionCount());
}

test "SubscriptionManager: unsubscribe" {
    const allocator = std.testing.allocator;

    var manager = SubscriptionManager.init(allocator);
    defer manager.deinit();

    const id = try manager.subscribeSlot(1);
    try std.testing.expectEqual(@as(usize, 1), manager.getSubscriptionCount());

    try std.testing.expect(manager.unsubscribe(id));
    try std.testing.expectEqual(@as(usize, 0), manager.getSubscriptionCount());
}

test "SubscriptionManager: multiple subscriptions" {
    const allocator = std.testing.allocator;

    var manager = SubscriptionManager.init(allocator);
    defer manager.deinit();

    _ = try manager.subscribeSlot(1);
    _ = try manager.subscribeSlot(1);
    _ = try manager.subscribeRoot(1);

    try std.testing.expectEqual(@as(usize, 3), manager.getSubscriptionCount());
}

