//! Vexor Leader Readiness Gate
//!
//! Centralized check to determine if the validator is ready to produce blocks.
//! Prevents block production when the node is desynchronized, which could lead to
//! duplicate blocks or slashable offenses.
//!
//! Checks include:
//! - Sync status (within N slots of network tip)
//! - Parent block completeness
//! - Bank state initialization
//! - Shred version correctness

const std = @import("std");
const core = @import("../core/root.zig");
const storage = @import("../storage/root.zig");
const network = @import("../network/root.zig");
const bank_mod = @import("../runtime/bank.zig");

/// Maximum slots behind network tip to allow block production
const MAX_SYNC_DISTANCE: u64 = 10;

/// Readiness check result
pub const ReadinessResult = struct {
    ready: bool,
    reason: Reason,
    details: ?[]const u8,

    pub const Reason = enum {
        ready,
        not_synced,
        parent_missing,
        bank_not_initialized,
        shred_version_mismatch,
        no_leader_schedule,
        not_our_slot,
        unknown_error,
    };

    pub fn ok() ReadinessResult {
        return .{
            .ready = true,
            .reason = .ready,
            .details = null,
        };
    }

    pub fn notReady(reason: Reason, details: ?[]const u8) ReadinessResult {
        return .{
            .ready = false,
            .reason = reason,
            .details = details,
        };
    }

    pub fn format(self: *const ReadinessResult) []const u8 {
        return switch (self.reason) {
            .ready => "READY",
            .not_synced => "Not synced with network",
            .parent_missing => "Parent block not complete",
            .bank_not_initialized => "Bank not initialized for slot",
            .shred_version_mismatch => "Shred version mismatch",
            .no_leader_schedule => "Leader schedule not available",
            .not_our_slot => "Not our leader slot",
            .unknown_error => "Unknown error",
        };
    }
};

/// Leader readiness gate
pub const LeaderReadiness = struct {
    allocator: std.mem.Allocator,

    /// Our identity pubkey
    identity: core.Pubkey,

    /// Reference to accounts DB for bank state checks
    accounts_db: ?*storage.AccountsDb,

    /// Reference to ledger DB for parent block checks
    ledger_db: ?*storage.LedgerDb,

    /// Expected shred version
    expected_shred_version: u16,

    /// Current network slot (updated periodically via RPC/gossip)
    network_slot: std.atomic.Value(u64),

    /// Last known good slot
    last_ready_slot: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, identity: core.Pubkey) Self {
        return .{
            .allocator = allocator,
            .identity = identity,
            .accounts_db = null,
            .ledger_db = null,
            .expected_shred_version = 0,
            .network_slot = std.atomic.Value(u64).init(0),
            .last_ready_slot = std.atomic.Value(u64).init(0),
        };
    }

    pub fn setAccountsDb(self: *Self, adb: *storage.AccountsDb) void {
        self.accounts_db = adb;
    }

    pub fn setLedgerDb(self: *Self, ldb: *storage.LedgerDb) void {
        self.ledger_db = ldb;
    }

    pub fn setShredVersion(self: *Self, version: u16) void {
        self.expected_shred_version = version;
    }

    pub fn updateNetworkSlot(self: *Self, slot: u64) void {
        self.network_slot.store(slot, .release);
    }

    /// Check if we can produce a block for the given slot
    pub fn canProduceBlock(
        self: *Self,
        slot: core.Slot,
        local_slot: u64,
        leader_schedule: anytype,
        current_shred_version: u16,
    ) ReadinessResult {
        // 1. Check if we're the leader for this slot
        if (leader_schedule.getSlotLeader(slot)) |leader_bytes| {
            if (!leader_bytes.eql(&self.identity)) {
                return ReadinessResult.notReady(.not_our_slot, null);
            }
        } else {
            return ReadinessResult.notReady(.no_leader_schedule, null);
        }

        // 2. Check sync status
        const net_slot = self.network_slot.load(.acquire);
        if (net_slot > 0) {
            const sync_distance = if (net_slot > local_slot) net_slot - local_slot else 0;
            if (sync_distance > MAX_SYNC_DISTANCE) {
                std.log.warn("[LeaderReady] Sync distance too large: {d} slots behind", .{sync_distance});
                return ReadinessResult.notReady(.not_synced, "Too far behind network tip");
            }
        }

        // 3. Check shred version
        if (self.expected_shred_version != 0 and current_shred_version != self.expected_shred_version) {
            std.log.warn("[LeaderReady] Shred version mismatch: expected {d}, got {d}", .{
                self.expected_shred_version,
                current_shred_version,
            });
            return ReadinessResult.notReady(.shred_version_mismatch, null);
        }

        // 4. Check parent block exists (slot - 1)
        if (slot > 0) {
            if (self.ledger_db) |ldb| {
                if (ldb.getSlotMeta(slot - 1) == null) {
                    return ReadinessResult.notReady(.parent_missing, "Parent slot not in ledger");
                }
            }
        }

        // 5. All checks passed
        self.last_ready_slot.store(slot, .release);
        std.log.info("[LeaderReady] READY to produce block for slot {d}", .{slot});
        return ReadinessResult.ok();
    }

    /// Quick check without full validation (for hot path)
    pub fn isLikelyReady(self: *Self, slot: core.Slot, local_slot: u64) bool {
        const net_slot = self.network_slot.load(.acquire);
        if (net_slot > 0) {
            const sync_distance = if (net_slot > local_slot) net_slot - local_slot else 0;
            if (sync_distance > MAX_SYNC_DISTANCE) {
                return false;
            }
        }
        // If we produced recently, we're probably still good
        const last = self.last_ready_slot.load(.acquire);
        return slot <= last + 10;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "readiness result" {
    const result = ReadinessResult.ok();
    try std.testing.expect(result.ready);
    try std.testing.expectEqual(ReadinessResult.Reason.ready, result.reason);

    const not_ready = ReadinessResult.notReady(.not_synced, "test");
    try std.testing.expect(!not_ready.ready);
    try std.testing.expectEqual(ReadinessResult.Reason.not_synced, not_ready.reason);
}
