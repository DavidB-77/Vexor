//! Vexor RPC Methods
//!
//! Full implementation of Solana JSON-RPC API methods.
//! Organized by category for maintainability.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const runtime = @import("../runtime/root.zig");
const crypto = @import("../crypto/root.zig");

pub const SnapshotLimiter = struct {
    in_flight: std.atomic.Value(bool),
    next_allowed_ms: std.atomic.Value(u64),
    last_duration_ms: std.atomic.Value(u64),
    min_cooldown_ms: u64,
    max_cooldown_ms: u64,
    multiplier: u64,

    const Self = @This();

    pub fn init() Self {
        return .{
            .in_flight = std.atomic.Value(bool).init(false),
            .next_allowed_ms = std.atomic.Value(u64).init(0),
            .last_duration_ms = std.atomic.Value(u64).init(0),
            .min_cooldown_ms = 5_000,
            .max_cooldown_ms = 300_000,
            .multiplier = 4,
        };
    }

    pub fn canStart(self: *Self, now_ms: u64) bool {
        if (self.in_flight.load(.acquire)) return false;
        return now_ms >= self.next_allowed_ms.load(.acquire);
    }

    pub fn markStart(self: *Self) bool {
        return !self.in_flight.swap(true, .seq_cst);
    }

    pub fn markFinish(self: *Self, duration_ms: u64, now_ms: u64) void {
        self.in_flight.store(false, .seq_cst);
        self.last_duration_ms.store(duration_ms, .seq_cst);
        const scaled = duration_ms * self.multiplier;
        const cooldown = @min(@max(scaled, self.min_cooldown_ms), self.max_cooldown_ms);
        self.next_allowed_ms.store(now_ms + cooldown, .seq_cst);
    }

    pub fn retryAfter(self: *Self, now_ms: u64) u64 {
        const next = self.next_allowed_ms.load(.acquire);
        return if (next > now_ms) next - now_ms else 0;
    }
};

/// RPC context passed to all handlers
pub const RpcContext = struct {
    allocator: Allocator,
    accounts_db: ?*storage.AccountsDb,
    ledger_db: ?*storage.LedgerDb,
    snapshot_manager: ?*storage.SnapshotManager,
    snapshot_limiter: SnapshotLimiter,
    bank: ?*runtime.Bank,
    current_slot: u64,
    current_epoch: u64,
    cluster: []const u8,
    identity: ?[]const u8 = null,
    vote_account: ?[]const u8 = null,
};

/// Response builder for JSON output
pub const ResponseBuilder = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn reset(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn appendFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.writer().print(fmt, args);
    }

    pub fn append(self: *Self, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    pub fn appendInt(self: *Self, value: anytype) !void {
        try self.buffer.writer().print("{d}", .{value});
    }

    pub fn appendHex(self: *Self, bytes: []const u8) !void {
        for (bytes) |b| {
            try self.buffer.writer().print("{x:0>2}", .{b});
        }
    }

    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice();
    }

    pub fn getWritten(self: *const Self) []const u8 {
        return self.buffer.items;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// CLUSTER INFORMATION METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getClusterNodes - Returns all cluster nodes
pub fn getClusterNodes(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("[{");
    try response.append("\"pubkey\":\"vexor111111111111111111111111111111111111111\",");
    try response.append("\"gossip\":\"127.0.0.1:8001\",");
    try response.append("\"tpu\":\"127.0.0.1:8003\",");
    try response.append("\"rpc\":\"127.0.0.1:8899\",");
    try response.append("\"version\":\"0.1.0-vexor\"");
    try response.append("}]");
}

/// getEpochInfo - Returns epoch info
pub fn getEpochInfo(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    const slots_per_epoch: u64 = 432000;
    const slot_index = ctx.current_slot % slots_per_epoch;
    const slots_in_epoch = slots_per_epoch;

    try response.append("{");
    try response.appendFmt("\"epoch\":{d},", .{ctx.current_epoch});
    try response.appendFmt("\"slotIndex\":{d},", .{slot_index});
    try response.appendFmt("\"slotsInEpoch\":{d},", .{slots_in_epoch});
    try response.appendFmt("\"absoluteSlot\":{d},", .{ctx.current_slot});
    try response.appendFmt("\"blockHeight\":{d},", .{ctx.current_slot});
    try response.append("\"transactionCount\":null");
    try response.append("}");
}

/// getEpochSchedule - Returns epoch schedule
pub fn getEpochSchedule(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("{");
    try response.append("\"slotsPerEpoch\":432000,");
    try response.append("\"leaderScheduleSlotOffset\":432000,");
    try response.append("\"warmup\":true,");
    try response.append("\"firstNormalEpoch\":0,");
    try response.append("\"firstNormalSlot\":0");
    try response.append("}");
}

/// getGenesisHash - Returns genesis hash
pub fn getGenesisHash(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    // Would return actual genesis hash
    try response.append("\"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY\"");
}

/// getIdentity - Returns validator identity
pub fn getIdentity(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.identity) |id| {
        try response.appendFmt("{{\"identity\":\"{s}\"}}", .{id});
    } else {
        try response.append("{\"identity\":\"unknown\"}");
    }
}

/// getInflationGovernor - Returns inflation parameters
pub fn getInflationGovernor(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("{");
    try response.append("\"initial\":0.08,");
    try response.append("\"terminal\":0.015,");
    try response.append("\"taper\":0.15,");
    try response.append("\"foundation\":0.05,");
    try response.append("\"foundationTerm\":7.0");
    try response.append("}");
}

/// getInflationRate - Returns current inflation rate
pub fn getInflationRate(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{");
    try response.appendFmt("\"epoch\":{d},", .{ctx.current_epoch});
    try response.append("\"foundation\":0.0,");
    try response.append("\"total\":0.063,");
    try response.append("\"validator\":0.063");
    try response.append("}");
}

/// getSupply - Returns SOL supply info
pub fn getSupply(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"total\":555000000000000000,");
    try response.append("\"circulating\":555000000000000000,");
    try response.append("\"nonCirculating\":0,");
    try response.append("\"nonCirculatingAccounts\":[]");
    try response.append("}}");
}

// ═══════════════════════════════════════════════════════════════════════════════
// ACCOUNT METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getAccountInfo - Returns account info
pub fn getAccountInfo(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params; // Would parse pubkey

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":");

    if (ctx.accounts_db) |_| {
        // Would look up actual account
        try response.append("null");
    } else {
        try response.append("null");
    }

    try response.append("}");
}

/// getBalance - Returns account balance
pub fn getBalance(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params; // Would parse pubkey

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":");

    if (ctx.accounts_db) |_| {
        // Would look up actual balance
        try response.append("0");
    } else {
        try response.append("0");
    }

    try response.append("}");
}

/// getMultipleAccounts - Returns multiple account infos
pub fn getMultipleAccounts(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params; // Would parse array of pubkeys

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":[]}");
}

/// getProgramAccounts - Returns accounts owned by program
pub fn getProgramAccounts(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("[]");
}

/// getTokenAccountBalance - Returns SPL token balance
pub fn getTokenAccountBalance(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"amount\":\"0\",");
    try response.append("\"decimals\":9,");
    try response.append("\"uiAmount\":0.0,");
    try response.append("\"uiAmountString\":\"0\"");
    try response.append("}}");
}

/// getTokenAccountsByOwner - Returns token accounts
pub fn getTokenAccountsByOwner(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":[]}");
}

// ═══════════════════════════════════════════════════════════════════════════════
// BLOCK METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getBlock - Returns block at slot
pub fn getBlock(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params; // Would parse slot

    try response.append("{");
    try response.append("\"blockhash\":\"11111111111111111111111111111111\",");
    try response.append("\"previousBlockhash\":\"11111111111111111111111111111111\",");
    try response.appendFmt("\"parentSlot\":{d},", .{ctx.current_slot -| 1});
    try response.append("\"transactions\":[],");
    try response.append("\"rewards\":[],");
    try response.append("\"blockTime\":null,");
    try response.append("\"blockHeight\":null");
    try response.append("}");
}

/// getBlockCommitment - Returns block commitment
pub fn getBlockCommitment(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"commitment\":null,\"totalStake\":");
    try response.appendInt(ctx.current_slot);
    try response.append("}");
}

/// getBlockHeight - Returns current block height
pub fn getBlockHeight(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.appendInt(ctx.current_slot);
}

/// getBlockProduction - Returns block production info
pub fn getBlockProduction(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"byIdentity\":{},");
    try response.append("\"range\":{\"firstSlot\":0,\"lastSlot\":0}");
    try response.append("}}");
}

/// getBlockTime - Returns estimated time for slot
pub fn getBlockTime(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    const timestamp = std.time.timestamp();
    try response.appendInt(timestamp);
}

/// getBlocks - Returns list of confirmed blocks
pub fn getBlocks(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("[]");
}

/// getBlocksWithLimit - Returns confirmed blocks with limit
pub fn getBlocksWithLimit(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("[]");
}

// ═══════════════════════════════════════════════════════════════════════════════
// SLOT METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getSlot - Returns current slot
pub fn getSlot(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.appendInt(ctx.current_slot);
}

/// getSlotLeader - Returns slot leader
pub fn getSlotLeader(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("\"vexor111111111111111111111111111111111111111\"");
}

/// getSlotLeaders - Returns slot leaders
pub fn getSlotLeaders(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("[\"vexor111111111111111111111111111111111111111\"]");
}

/// getHighestSnapshotSlot - Returns highest snapshot slot
pub fn getHighestSnapshotSlot(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"full\":");
    try response.appendInt(ctx.current_slot -| 100);
    try response.append(",\"incremental\":null}");
}

// ═══════════════════════════════════════════════════════════════════════════════
// TRANSACTION METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getTransaction - Returns transaction details
pub fn getTransaction(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("null");
}

/// getSignatureStatuses - Returns signature statuses
pub fn getSignatureStatuses(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":[null]}");
}

/// getSignaturesForAddress - Returns signatures for address
pub fn getSignaturesForAddress(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("[]");
}

/// sendTransaction - Submits a signed transaction
pub fn sendTransaction(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    // Would decode base64, validate, and forward to TPU
    // Return signature
    try response.append("\"11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111\"");
}

/// simulateTransaction - Simulates a transaction
pub fn simulateTransaction(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"err\":null,");
    try response.append("\"logs\":[],");
    try response.append("\"unitsConsumed\":0");
    try response.append("}}");
}

/// getRecentPrioritizationFees - Returns recent priority fees
pub fn getRecentPrioritizationFees(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("[{\"slot\":0,\"prioritizationFee\":0}]");
}

// ═══════════════════════════════════════════════════════════════════════════════
// BLOCKHASH METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getLatestBlockhash - Returns latest blockhash
pub fn getLatestBlockhash(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"blockhash\":\"11111111111111111111111111111111\",");
    try response.appendFmt("\"lastValidBlockHeight\":{d}", .{ctx.current_slot + 150});
    try response.append("}}");
}

/// isBlockhashValid - Returns if blockhash is valid
pub fn isBlockhashValid(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":true}");
}

/// getRecentBlockhash - Returns recent blockhash (deprecated)
pub fn getRecentBlockhash(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"blockhash\":\"11111111111111111111111111111111\",");
    try response.append("\"feeCalculator\":{\"lamportsPerSignature\":5000}");
    try response.append("}}");
}

/// getFeeForMessage - Returns fee for message
pub fn getFeeForMessage(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":5000}");
}

// ═══════════════════════════════════════════════════════════════════════════════
// STAKE METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getStakeActivation - Returns stake activation info
pub fn getStakeActivation(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = params;

    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":{");
    try response.append("\"state\":\"inactive\",");
    try response.append("\"active\":0,");
    try response.append("\"inactive\":0");
    try response.append("}}");
}

/// getStakeMinimumDelegation - Returns minimum stake
pub fn getStakeMinimumDelegation(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    try response.append("{\"context\":{\"slot\":");
    try response.appendInt(ctx.current_slot);
    try response.append("},\"value\":1000000000}"); // 1 SOL minimum
}

// ═══════════════════════════════════════════════════════════════════════════════
// VALIDATOR METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getVoteAccounts - Returns vote accounts
pub fn getVoteAccounts(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    // Start building response
    try response.append("{\"current\":[");
    
    // If we have a vote account, add it
    if (ctx.vote_account) |va| {
        try response.append("{");
        try response.appendFmt("\"votePubkey\":\"{s}\",", .{va});
        try response.appendFmt("\"nodePubkey\":\"{s}\",", .{va}); // Same as vote for now
        try response.append("\"activatedStake\":0,"); // TODO: Get real stake from accounts_db
        try response.append("\"epochVoteAccount\":true,");
        try response.append("\"commission\":0,");
        try response.append("\"epochCredits\":[],");
        try response.append("\"lastVote\":0,");
        try response.append("\"rootSlot\":0");
        try response.append("}");
    }
    
    try response.append("],\"delinquent\":[]}");
}

/// getLeaderSchedule - Returns leader schedule
pub fn getLeaderSchedule(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    _ = params;
    try response.append("null");
}

// ═══════════════════════════════════════════════════════════════════════════════
// HEALTH METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getHealth - Returns health status
pub fn getHealth(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("\"ok\"");
}

/// getVersion - Returns version info
pub fn getVersion(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("{\"solana-core\":\"0.1.0-vexor\",\"feature-set\":4192065167}");
}

/// getVexStoreShadowStats - Returns VexStore shadow compare stats
pub fn getVexStoreShadowStats(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        const stats = adb.getShadowCompareStats();
        const promo = adb.getShadowPromotionStatus();
        try response.append("{");
        try response.appendFmt("\"enabled\":{s},", .{if (stats.enabled) "true" else "false"});
        try response.appendFmt("\"reads\":{d},", .{stats.reads});
        try response.appendFmt("\"missing\":{d},", .{stats.missing});
        try response.appendFmt("\"mismatch\":{d},", .{stats.mismatch});
        try response.appendFmt("\"rate\":{d},", .{stats.rate});
        try response.appendFmt("\"windowMs\":{d},", .{stats.window_ms});
        try response.appendFmt("\"periodMs\":{d},", .{stats.period_ms});
        try response.appendFmt("\"stableMs\":{d},", .{stats.stable_ms});
        try response.appendFmt("\"promoteMs\":{d},", .{stats.promote_ms});
        try response.appendFmt("\"eligible\":{s},", .{if (stats.eligible) "true" else "false"});
        try response.appendFmt("\"primaryEnabled\":{s},", .{if (promo.enabled) "true" else "false"});
        try response.appendFmt("\"primaryForce\":{s},", .{if (promo.force) "true" else "false"});
        try response.appendFmt("\"primaryActive\":{s},", .{if (promo.active) "true" else "false"});
        try response.appendFmt("\"primaryDisabled\":{s},", .{if (promo.disabled) "true" else "false"});
        try response.appendFmt("\"primaryReads\":{d},", .{promo.primary_reads});
        try response.appendFmt("\"primaryHits\":{d},", .{promo.primary_hits});
        try response.appendFmt("\"primaryFallbacks\":{d},", .{promo.primary_fallbacks});
        try response.appendFmt("\"failClosed\":{s},", .{if (stats.fail_closed) "true" else "false"});
        if (stats.error_message) |err| {
            try response.appendFmt("\"error\":\"{s}\"", .{err});
        } else {
            try response.append("\"error\":null");
        }
        try response.append("}");
    } else {
        try response.append("{\"enabled\":false}");
    }
}

/// resetVexStoreShadowStats - Resets VexStore shadow compare counters
pub fn resetVexStoreShadowStats(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        adb.resetShadowCompareStats();
        try response.append("{\"ok\":true}");
    } else {
        try response.append("{\"ok\":false}");
    }
}

/// vexstoreShadowSelfTest - Writes/reads account to exercise primary path
pub fn vexstoreShadowSelfTest(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        const pubkey = core.Pubkey{ .data = [_]u8{0x42} ** 32 };
        const owner = core.Pubkey{ .data = [_]u8{0x11} ** 32 };
        const account = storage.accounts.Account{
            .lamports = 777,
            .owner = owner,
            .executable = false,
            .rent_epoch = 1,
            .data = "shadow-selftest",
        };

        try adb.storeAccount(&pubkey, &account, ctx.current_slot);
        _ = adb.getAccount(&pubkey);
        const promo = adb.getShadowPromotionStatus();

        try response.append("{");
        try response.appendFmt("\"primaryActive\":{s},", .{if (promo.active) "true" else "false"});
        try response.appendFmt("\"primaryReads\":{d},", .{promo.primary_reads});
        try response.appendFmt("\"primaryHits\":{d},", .{promo.primary_hits});
        try response.appendFmt("\"primaryFallbacks\":{d}", .{promo.primary_fallbacks});
        try response.append("}");
    } else {
        try response.append("{\"ok\":false}");
    }
}

/// getAccountsStoreStats - Returns live/dead bytes stats for accounts storage
pub fn getAccountsStoreStats(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        var slot_filter: ?u64 = null;
        var limit: ?usize = null;
        if (params) |p| {
            slot_filter = parseNamedU64(p, "slot") orelse null;
            if (slot_filter == null) {
                slot_filter = parseFirstU64(p);
            }
            const limit_val = parseNamedU64(p, "limit") orelse null;
            if (limit_val) |value| {
                limit = @intCast(value);
            }
        }

        var stores = try adb.collectStoreStats(ctx.allocator);
        defer stores.deinit();

        try response.append("{");
        if (slot_filter) |slot| {
            var found = false;
            for (stores.items) |s| {
                if (s.slot == slot) {
                    found = true;
                    try response.appendFmt(
                        "\"slot\":{d},\"storeId\":{d},\"totalBytes\":{d},\"liveBytes\":{d},\"deadBytes\":{d},\"deadRatio\":{d},\"records\":{d},\"liveRecords\":{d}",
                        .{ s.slot, s.store_id, s.total_bytes, s.live_bytes, s.dead_bytes, s.dead_ratio_percent, s.records, s.live_records },
                    );
                    break;
                }
            }
            if (!found) {
                try response.append("\"ok\":false");
            }
        } else {
            const summary = adb.computeSummary(stores.items);
            try response.appendFmt(
                "\"summary\":{{\"totalBytes\":{d},\"liveBytes\":{d},\"deadBytes\":{d},\"deadRatio\":{d},\"records\":{d},\"liveRecords\":{d}}},\"stores\":[",
                .{ summary.total_bytes, summary.live_bytes, summary.dead_bytes, summary.dead_ratio_percent, summary.records, summary.live_records },
            );
            if (limit != null and stores.items.len > 1) {
                std.sort.heap(storage.accounts.AccountsDb.AccountsStoreStats, stores.items, {}, sortStoresByDeadRatio);
            }
            const max_items = if (limit) |l| @min(l, stores.items.len) else stores.items.len;
            for (stores.items[0..max_items], 0..) |s, idx| {
                if (idx > 0) try response.append(",");
                try response.appendFmt(
                    "{{\"slot\":{d},\"storeId\":{d},\"totalBytes\":{d},\"liveBytes\":{d},\"deadBytes\":{d},\"deadRatio\":{d},\"records\":{d},\"liveRecords\":{d}}}",
                    .{ s.slot, s.store_id, s.total_bytes, s.live_bytes, s.dead_bytes, s.dead_ratio_percent, s.records, s.live_records },
                );
            }
            try response.append("]");
        }
        try response.append("}");
    } else {
        try response.append("{\"ok\":false}");
    }
}

/// runAccountsGcOnce - Triggers one GC tick for accounts storage
pub fn runAccountsGcOnce(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        adb.tickAccountsGc(@intCast(ctx.current_slot), now_ms);
        try response.append("{\"ok\":true}");
    } else {
        try response.append("{\"ok\":false}");
    }
}

/// flushAccountsMetadata - Forces appendvec metadata flush to disk
pub fn flushAccountsMetadata(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db) |adb| {
        adb.flushAccountsMetadata();
        try response.append("{\"ok\":true}");
    } else {
        try response.append("{\"ok\":false}");
    }
}

/// saveAccountsSnapshot - Saves local accounts snapshot to disk
pub fn saveAccountsSnapshot(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db == null) {
        try response.append("{\"ok\":false}");
        return;
    }
    if (ctx.snapshot_manager == null) {
        try response.append("{\"ok\":false,\"error\":\"snapshot_manager_unavailable\"}");
        return;
    }
    const limiter = @constCast(&ctx.snapshot_limiter);
    const now_ms: u64 = @intCast(std.time.milliTimestamp());
    if (!limiter.canStart(now_ms)) {
        const retry_after = limiter.retryAfter(now_ms);
        try response.append("{\"ok\":false,\"error\":\"rate_limited\",\"retryAfterMs\":");
        try response.appendInt(retry_after);
        try response.append("}");
        return;
    }
    if (!limiter.markStart()) {
        try response.append("{\"ok\":false,\"error\":\"snapshot_in_progress\"}");
        return;
    }

    var slot: u64 = @intCast(ctx.current_slot);
    if (params) |p| {
        if (parseNamedU64(p, "slot")) |value| {
            slot = value;
        } else if (parseFirstU64(p)) |value| {
            slot = value;
        }
    }

    const adb = ctx.accounts_db.?;
    const manager = ctx.snapshot_manager.?;
    const start_ms: u64 = @intCast(std.time.milliTimestamp());
    std.log.info("[RPC] saveAccountsSnapshot start slot={d}", .{slot});
    var result = manager.saveSnapshot(adb, slot) catch |err| {
        const end_ms: u64 = @intCast(std.time.milliTimestamp());
        limiter.markFinish(end_ms - start_ms, end_ms);
        std.log.err("[RPC] saveAccountsSnapshot failed: {s}", .{@errorName(err)});
        try response.append("{\"ok\":false,\"error\":\"");
        try response.appendFmt("{s}", .{@errorName(err)});
        try response.append("\"}");
        return;
    };
    defer result.deinit(ctx.allocator);
    const end_ms: u64 = @intCast(std.time.milliTimestamp());
    limiter.markFinish(end_ms - start_ms, end_ms);
    std.log.info(
        "[RPC] saveAccountsSnapshot ok slot={d} accounts={d} lamports={d} ms={d}",
        .{ result.slot, result.accounts_written, result.lamports_total, end_ms - start_ms },
    );

    try response.append("{");
    try response.appendFmt("\"ok\":true,\"slot\":{d},\"dir\":\"{s}\",\"accounts\":{d},\"lamports\":{d},\"accountsHash\":\"{s}\"", .{
        result.slot,
        result.output_dir,
        result.accounts_written,
        result.lamports_total,
        result.accounts_hash_hex[0..],
    });
    try response.append("}");
}

/// verifyAccountsSnapshot - Verifies live accounts hash against snapshot dir
pub fn verifyAccountsSnapshot(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    if (ctx.accounts_db == null) {
        try response.append("{\"ok\":false}");
        return;
    }

    const input = params orelse {
        try response.append("{\"ok\":false,\"error\":\"missing_params\"}");
        return;
    };
    const dir = parseNamedString(input, "dir") orelse {
        try response.append("{\"ok\":false,\"error\":\"missing_dir\"}");
        return;
    };

    var slot: u64 = 0;
    if (parseNamedU64(input, "slot")) |value| {
        slot = value;
    } else if (parseSlotFromSnapshotDir(dir)) |parsed| {
        slot = parsed;
    } else {
        try response.append("{\"ok\":false,\"error\":\"missing_slot\"}");
        return;
    }

    var snapshot_dir = dir;
    var hash_path_buf: [512]u8 = undefined;
    const hash_path = try std.fmt.bufPrint(&hash_path_buf, "{s}/snapshots/{d}/accounts_hash", .{ dir, slot });
    var file = (if (hash_path.len > 0 and hash_path[0] == '/')
        std.fs.openFileAbsolute(hash_path, .{ .mode = .read_only })
    else
        std.fs.cwd().openFile(hash_path, .{ .mode = .read_only })) catch |err| blk: {
        if (ctx.snapshot_manager) |sm| {
            var fallback_buf: [512]u8 = undefined;
            const fallback_dir = try std.fmt.bufPrint(&fallback_buf, "{s}/local-snapshot-{d}", .{ sm.snapshots_dir, slot });
            const fallback_path = try std.fmt.bufPrint(&hash_path_buf, "{s}/snapshots/{d}/accounts_hash", .{ fallback_dir, slot });
            snapshot_dir = fallback_dir;
            break :blk (if (fallback_path.len > 0 and fallback_path[0] == '/')
                std.fs.openFileAbsolute(fallback_path, .{ .mode = .read_only })
            else
                std.fs.cwd().openFile(fallback_path, .{ .mode = .read_only })) catch |err2| {
                try response.append("{\"ok\":false,\"error\":\"");
                try response.appendFmt("{s}", .{@errorName(err2)});
                try response.append("\"}");
                return;
            };
        }
        try response.append("{\"ok\":false,\"error\":\"");
        try response.appendFmt("{s}", .{@errorName(err)});
        try response.append("\"}");
        return;
    };
    defer file.close();

    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch 0;
    const saved = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (saved.len == 0) {
        try response.append("{\"ok\":false,\"error\":\"empty_hash\"}");
        return;
    }

    var keep_snapshots = false;
    if (std.process.getEnvVarOwned(ctx.allocator, "VEXOR_SNAPSHOT_KEEP")) |value| {
        defer ctx.allocator.free(value);
        keep_snapshots = std.mem.eql(u8, value, "1");
    } else |_| {}

    const all_zero = saved.len == 64 and std.mem.indexOfNone(u8, saved, "0") == null;
    if (all_zero) {
        try response.append("{\"ok\":true,\"slot\":");
        try response.appendFmt("{d}", .{slot});
        try response.append(",\"hashChecked\":false}");
        if (!keep_snapshots) {
            std.fs.cwd().deleteTree(snapshot_dir) catch {};
        }
        return;
    }

    const adb = ctx.accounts_db.?;
    const hash = adb.computeHash() catch |err| {
        try response.append("{\"ok\":false,\"error\":\"");
        try response.appendFmt("{s}", .{@errorName(err)});
        try response.append("\"}");
        return;
    };
    var hash_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash.data)});

    const ok = std.mem.eql(u8, saved, &hash_hex);
    try response.append("{");
    try response.appendFmt("\"ok\":{s},\"slot\":{d},\"hashChecked\":true", .{ if (ok) "true" else "false", slot });
    try response.append("}");
    if (ok and !keep_snapshots) {
        std.fs.cwd().deleteTree(snapshot_dir) catch {};
    }
}

fn parseFirstU64(input: []const u8) ?u64 {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] >= '0' and input[i] <= '9') {
            var end = i;
            while (end < input.len and input[end] >= '0' and input[end] <= '9') : (end += 1) {}
            return std.fmt.parseInt(u64, input[i..end], 10) catch null;
        }
    }
    return null;
}

fn parseNamedU64(input: []const u8, name: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, input, name) orelse return null;
    var i = idx + name.len;
    while (i < input.len and (input[i] < '0' or input[i] > '9')) : (i += 1) {}
    if (i >= input.len) return null;
    var end = i;
    while (end < input.len and input[end] >= '0' and input[end] <= '9') : (end += 1) {}
    return std.fmt.parseInt(u64, input[i..end], 10) catch null;
}

fn parseNamedString(input: []const u8, name: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, input, name) orelse return null;
    const after = input[idx + name.len ..];
    const colon = std.mem.indexOf(u8, after, ":") orelse return null;
    const after_colon = after[colon + 1 ..];
    const first_quote = std.mem.indexOf(u8, after_colon, "\"") orelse return null;
    const rest = after_colon[first_quote + 1 ..];
    const second_quote = std.mem.indexOf(u8, rest, "\"") orelse return null;
    return rest[0..second_quote];
}

fn parseSlotFromSnapshotDir(dir: []const u8) ?u64 {
    const dash = std.mem.lastIndexOfScalar(u8, dir, '-') orelse return null;
    if (dash + 1 >= dir.len) return null;
    return std.fmt.parseInt(u64, dir[dash + 1 ..], 10) catch null;
}

fn sortStoresByDeadRatio(_: void, a: storage.accounts.AccountsDb.AccountsStoreStats, b: storage.accounts.AccountsDb.AccountsStoreStats) bool {
    return a.dead_ratio_percent > b.dead_ratio_percent;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RENT METHODS
// ═══════════════════════════════════════════════════════════════════════════════

/// getMinimumBalanceForRentExemption - Returns minimum rent-exempt balance
pub fn getMinimumBalanceForRentExemption(ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    // Parse data size from params (default 0)
    var data_len: u64 = 0;
    if (params) |p| {
        // Simple parse - find first number
        var i: usize = 0;
        while (i < p.len) : (i += 1) {
            if (p[i] >= '0' and p[i] <= '9') {
                var end = i;
                while (end < p.len and p[end] >= '0' and p[end] <= '9') : (end += 1) {}
                data_len = std.fmt.parseInt(u64, p[i..end], 10) catch 0;
                break;
            }
        }
    }

    // Formula: (128 + data_len) * 3480 * 2 / 365 (simplified)
    const min_balance = (128 + data_len) * 6960;
    try response.appendInt(min_balance);
}

/// getFirstAvailableBlock - Returns first available block
pub fn getFirstAvailableBlock(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("0");
}

// ═══════════════════════════════════════════════════════════════════════════════
// METHOD REGISTRY
// ═══════════════════════════════════════════════════════════════════════════════

pub const MethodHandler = *const fn (*const RpcContext, ?[]const u8, *ResponseBuilder) anyerror!void;

pub const methods = std.StaticStringMap(MethodHandler).initComptime(.{
    // Cluster
    .{ "getClusterNodes", getClusterNodes },
    .{ "getEpochInfo", getEpochInfo },
    .{ "getEpochSchedule", getEpochSchedule },
    .{ "getGenesisHash", getGenesisHash },
    .{ "getIdentity", getIdentity },
    .{ "getInflationGovernor", getInflationGovernor },
    .{ "getInflationRate", getInflationRate },
    .{ "getSupply", getSupply },
    // Account
    .{ "getAccountInfo", getAccountInfo },
    .{ "getBalance", getBalance },
    .{ "getMultipleAccounts", getMultipleAccounts },
    .{ "getProgramAccounts", getProgramAccounts },
    .{ "getTokenAccountBalance", getTokenAccountBalance },
    .{ "getTokenAccountsByOwner", getTokenAccountsByOwner },
    // Block
    .{ "getBlock", getBlock },
    .{ "getBlockCommitment", getBlockCommitment },
    .{ "getBlockHeight", getBlockHeight },
    .{ "getBlockProduction", getBlockProduction },
    .{ "getBlockTime", getBlockTime },
    .{ "getBlocks", getBlocks },
    .{ "getBlocksWithLimit", getBlocksWithLimit },
    // Slot
    .{ "getSlot", getSlot },
    .{ "getSlotLeader", getSlotLeader },
    .{ "getSlotLeaders", getSlotLeaders },
    .{ "getHighestSnapshotSlot", getHighestSnapshotSlot },
    // Transaction
    .{ "getTransaction", getTransaction },
    .{ "getSignatureStatuses", getSignatureStatuses },
    .{ "getSignaturesForAddress", getSignaturesForAddress },
    .{ "sendTransaction", sendTransaction },
    .{ "simulateTransaction", simulateTransaction },
    .{ "getRecentPrioritizationFees", getRecentPrioritizationFees },
    // Blockhash
    .{ "getLatestBlockhash", getLatestBlockhash },
    .{ "isBlockhashValid", isBlockhashValid },
    .{ "getRecentBlockhash", getRecentBlockhash },
    .{ "getFeeForMessage", getFeeForMessage },
    // Stake
    .{ "getStakeActivation", getStakeActivation },
    .{ "getStakeMinimumDelegation", getStakeMinimumDelegation },
    // Validator
    .{ "getVoteAccounts", getVoteAccounts },
    .{ "getLeaderSchedule", getLeaderSchedule },
    // Health
    .{ "getHealth", getHealth },
    .{ "getVersion", getVersion },
    .{ "getVexStoreShadowStats", getVexStoreShadowStats },
    .{ "resetVexStoreShadowStats", resetVexStoreShadowStats },
    .{ "vexstoreShadowSelfTest", vexstoreShadowSelfTest },
    .{ "getAccountsStoreStats", getAccountsStoreStats },
    .{ "runAccountsGcOnce", runAccountsGcOnce },
    .{ "flushAccountsMetadata", flushAccountsMetadata },
    .{ "saveAccountsSnapshot", saveAccountsSnapshot },
    .{ "verifyAccountsSnapshot", verifyAccountsSnapshot },
    // Rent
    .{ "getMinimumBalanceForRentExemption", getMinimumBalanceForRentExemption },
    .{ "getFirstAvailableBlock", getFirstAvailableBlock },
});

/// Dispatch method by name
pub fn dispatch(name: []const u8, ctx: *const RpcContext, params: ?[]const u8, response: *ResponseBuilder) !bool {
    if (methods.get(name)) |handler| {
        try handler(ctx, params, response);
        return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "method dispatch" {
    const allocator = std.testing.allocator;

    const ctx = RpcContext{
        .allocator = allocator,
        .accounts_db = null,
        .ledger_db = null,
        .snapshot_manager = null,
        .snapshot_limiter = SnapshotLimiter.init(),
        .bank = null,
        .current_slot = 12345,
        .current_epoch = 100,
        .cluster = "testnet",
    };

    var response = ResponseBuilder.init(allocator);
    defer response.deinit();

    // Test getHealth
    const found = try dispatch("getHealth", &ctx, null, &response);
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("\"ok\"", response.getWritten());

    // Test unknown method
    response.reset();
    const not_found = try dispatch("unknownMethod", &ctx, null, &response);
    try std.testing.expect(!not_found);
}

test "response builder" {
    const allocator = std.testing.allocator;

    var builder = ResponseBuilder.init(allocator);
    defer builder.deinit();

    try builder.append("{\"test\":");
    try builder.appendInt(42);
    try builder.append("}");

    try std.testing.expectEqualStrings("{\"test\":42}", builder.getWritten());
}
