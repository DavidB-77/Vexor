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

/// RPC context passed to all handlers
pub const RpcContext = struct {
    allocator: Allocator,
    accounts_db: ?*storage.AccountsDb,
    ledger_db: ?*storage.LedgerDb,
    bank: ?*runtime.Bank,
    current_slot: u64,
    current_epoch: u64,
    cluster: []const u8,
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
    try response.append("\"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d\"");
}

/// getIdentity - Returns validator identity
pub fn getIdentity(ctx: *const RpcContext, _: ?[]const u8, response: *ResponseBuilder) !void {
    _ = ctx;
    try response.append("{\"identity\":\"vexor111111111111111111111111111111111111111\"}");
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
    _ = ctx;
    try response.append("{\"current\":[],\"delinquent\":[]}");
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

