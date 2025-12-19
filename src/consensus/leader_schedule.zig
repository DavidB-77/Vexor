//! Vexor Leader Schedule
//!
//! Calculates and caches the leader schedule for each epoch.
//! The schedule is deterministically derived from stake weights.
//!
//! Schedule determination:
//! 1. Get stake weights at epoch boundary
//! 2. Shuffle validators using epoch-seeded RNG
//! 3. Assign slots proportionally to stake

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

/// Pubkey type
pub const Pubkey = [32]u8;

/// Epoch type
pub const Epoch = u64;

/// Slot type
pub const Slot = u64;

/// Stake weight entry
pub const StakeWeight = struct {
    pubkey: Pubkey,
    stake: u64,
};

/// Leader schedule for an epoch
pub const EpochSchedule = struct {
    epoch: Epoch,
    first_slot: Slot,
    last_slot: Slot,
    slot_leaders: []Pubkey,

    pub fn deinit(self: *EpochSchedule, allocator: Allocator) void {
        allocator.free(self.slot_leaders);
    }

    /// Get leader for a slot
    pub fn getLeader(self: *const EpochSchedule, slot: Slot) ?Pubkey {
        if (slot < self.first_slot or slot > self.last_slot) return null;
        const idx = slot - self.first_slot;
        if (idx >= self.slot_leaders.len) return null;
        return self.slot_leaders[idx];
    }

    /// Check if pubkey is leader for slot
    pub fn isLeader(self: *const EpochSchedule, slot: Slot, pubkey: Pubkey) bool {
        if (self.getLeader(slot)) |leader| {
            return std.mem.eql(u8, &leader, &pubkey);
        }
        return false;
    }

    /// Get slots where pubkey is leader
    pub fn getLeaderSlots(self: *const EpochSchedule, pubkey: Pubkey, allocator: Allocator) ![]Slot {
        var slots = std.ArrayList(Slot).init(allocator);

        for (self.slot_leaders, 0..) |leader, idx| {
            if (std.mem.eql(u8, &leader, &pubkey)) {
                try slots.append(self.first_slot + idx);
            }
        }

        return slots.toOwnedSlice();
    }
};

/// Leader schedule generator
pub const LeaderScheduleGenerator = struct {
    allocator: Allocator,
    slots_per_epoch: u64,
    leader_schedule_slot_offset: u64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .slots_per_epoch = 432000, // ~2 days at 400ms/slot
            .leader_schedule_slot_offset = 432000,
        };
    }

    /// Generate leader schedule for an epoch
    pub fn generate(self: *Self, epoch: Epoch, stakes: []const StakeWeight) !EpochSchedule {
        const first_slot = epoch * self.slots_per_epoch;
        const last_slot = first_slot + self.slots_per_epoch - 1;

        // Calculate total stake
        var total_stake: u64 = 0;
        for (stakes) |sw| {
            total_stake += sw.stake;
        }

        if (total_stake == 0) {
            return error.NoStake;
        }

        // Allocate slot leaders
        const slot_leaders = try self.allocator.alloc(Pubkey, self.slots_per_epoch);
        errdefer self.allocator.free(slot_leaders);

        // Seed RNG with epoch
        var seed: [32]u8 = undefined;
        std.mem.writeInt(u64, seed[0..8], epoch, .little);
        @memset(seed[8..], 0);
        var rng = std.rand.DefaultPrng.init(@bitCast(seed[0..8].*));

        // Assign leaders proportionally to stake
        var current_slot: usize = 0;
        var remaining_slots = self.slots_per_epoch;

        // Shuffle stake weights
        const shuffled = try self.allocator.alloc(StakeWeight, stakes.len);
        defer self.allocator.free(shuffled);
        @memcpy(shuffled, stakes);

        rng.random().shuffle(StakeWeight, shuffled);

        // Assign slots
        for (shuffled) |sw| {
            if (remaining_slots == 0) break;

            // Calculate slots for this validator (proportional to stake)
            const validator_slots = @min(
                (sw.stake * self.slots_per_epoch) / total_stake + 1,
                remaining_slots,
            );

            // Assign consecutive slots
            for (0..validator_slots) |_| {
                if (current_slot >= slot_leaders.len) break;
                slot_leaders[current_slot] = sw.pubkey;
                current_slot += 1;
                remaining_slots -= 1;
            }
        }

        // Fill any remaining slots with random validators
        while (current_slot < slot_leaders.len) {
            const idx = rng.random().uintLessThan(usize, stakes.len);
            slot_leaders[current_slot] = stakes[idx].pubkey;
            current_slot += 1;
        }

        return EpochSchedule{
            .epoch = epoch,
            .first_slot = first_slot,
            .last_slot = last_slot,
            .slot_leaders = slot_leaders,
        };
    }

    /// Get epoch for slot
    pub fn getEpoch(self: *const Self, slot: Slot) Epoch {
        return slot / self.slots_per_epoch;
    }

    /// Get first slot of epoch
    pub fn getFirstSlotInEpoch(self: *const Self, epoch: Epoch) Slot {
        return epoch * self.slots_per_epoch;
    }

    /// Get last slot of epoch
    pub fn getLastSlotInEpoch(self: *const Self, epoch: Epoch) Slot {
        return self.getFirstSlotInEpoch(epoch + 1) - 1;
    }
};

/// Leader schedule cache
pub const LeaderScheduleCache = struct {
    allocator: Allocator,
    schedules: std.AutoHashMap(Epoch, EpochSchedule),
    mutex: Mutex,
    generator: LeaderScheduleGenerator,
    
    /// Our identity (for checking if we're leader)
    identity: ?Pubkey = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .schedules = std.AutoHashMap(Epoch, EpochSchedule).init(allocator),
            .mutex = .{},
            .generator = LeaderScheduleGenerator.init(allocator),
            .identity = null,
        };
    }
    
    /// Set our identity for leader checks
    pub fn setIdentity(self: *Self, identity: Pubkey) void {
        self.identity = identity;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.schedules.valueIterator();
        while (iter.next()) |schedule| {
            var s = schedule.*;
            s.deinit(self.allocator);
        }
        self.schedules.deinit();
    }

    /// Get leader for slot
    pub fn getSlotLeader(self: *Self, slot: Slot) ?Pubkey {
        self.mutex.lock();
        defer self.mutex.unlock();

        const epoch = self.generator.getEpoch(slot);
        if (self.schedules.get(epoch)) |schedule| {
            return schedule.getLeader(slot);
        }
        return null;
    }

    /// Add schedule for epoch
    pub fn addSchedule(self: *Self, schedule: EpochSchedule) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove old schedule if exists
        if (self.schedules.fetchRemove(schedule.epoch)) |removed| {
            var s = removed.value;
            s.deinit(self.allocator);
        }

        try self.schedules.put(schedule.epoch, schedule);
    }

    /// Generate and cache schedule
    pub fn ensureSchedule(self: *Self, epoch: Epoch, stakes: []const StakeWeight) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schedules.contains(epoch)) return;

        const schedule = try self.generator.generate(epoch, stakes);
        try self.schedules.put(epoch, schedule);
    }

    /// Check if we're leader for slot
    pub fn isLeader(self: *Self, slot: Slot, pubkey: Pubkey) bool {
        if (self.getSlotLeader(slot)) |leader| {
            return std.mem.eql(u8, &leader, &pubkey);
        }
        return false;
    }

    /// Get next leader slot for pubkey
    pub fn nextLeaderSlot(self: *Self, pubkey: Pubkey, start_slot: Slot) ?Slot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const epoch = self.generator.getEpoch(start_slot);

        if (self.schedules.get(epoch)) |schedule| {
            for (schedule.slot_leaders, 0..) |leader, idx| {
                const slot = schedule.first_slot + idx;
                if (slot >= start_slot and std.mem.eql(u8, &leader, &pubkey)) {
                    return slot;
                }
            }
        }

        return null;
    }
    
    /// Check if we're leader for the given slot
    pub fn amILeader(self: *Self, slot: Slot) bool {
        if (self.identity) |id| {
            return self.isLeader(slot, id);
        }
        return false;
    }
    
    /// Fetch leader schedule from RPC endpoint
    pub fn fetchFromRpc(self: *Self, rpc_url: []const u8, slot: ?Slot) !void {
        const http = std.http;
        
        // Build JSON-RPC request
        var request_body = std.ArrayList(u8).init(self.allocator);
        defer request_body.deinit();
        
        const w = request_body.writer();
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLeaderSchedule\"");
        if (slot) |s| {
            try w.print(",\"params\":[{d}]", .{s});
        }
        try w.writeAll("}");
        
        // Make HTTP request
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const uri = try std.Uri.parse(rpc_url);
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = undefined,
        });
        defer req.deinit();
        
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        try req.send();
        try req.writer().writeAll(request_body.items);
        try req.finish();
        try req.wait();
        
        // Read response (limited)
        var response_buf: [1024 * 1024]u8 = undefined; // 1MB max
        const response_len = try req.reader().readAll(&response_buf);
        const response = response_buf[0..response_len];
        
        // Parse leader schedule from response
        try self.parseLeaderScheduleResponse(response, slot orelse 0);
    }
    
    /// Parse leader schedule JSON response
    fn parseLeaderScheduleResponse(self: *Self, response: []const u8, base_slot: Slot) !void {
        // Find "result" in response
        const result_start = std.mem.indexOf(u8, response, "\"result\"") orelse return error.InvalidResponse;
        const content = response[result_start..];
        
        // Parse each validator's slot assignments
        // Format: {"validatorPubkey": [slot1, slot2, ...], ...}
        const epoch = self.generator.getEpoch(base_slot);
        const first_slot = self.generator.getFirstSlotInEpoch(epoch);
        const slots_per_epoch = self.generator.slots_per_epoch;
        
        // Allocate slot leaders array
        var slot_leaders = try self.allocator.alloc(Pubkey, slots_per_epoch);
        errdefer self.allocator.free(slot_leaders);
        @memset(slot_leaders, [_]u8{0} ** 32);
        
        // Simple parsing: find pubkey:slots pairs
        var pos: usize = 0;
        while (pos < content.len) {
            // Find next pubkey (44 char base58)
            const quote_start = std.mem.indexOfPos(u8, content, pos, "\"") orelse break;
            const quote_end = std.mem.indexOfPos(u8, content, quote_start + 1, "\"") orelse break;
            const key = content[quote_start + 1 .. quote_end];
            
            // Skip if not a pubkey (44 chars)
            if (key.len < 32 or key.len > 44) {
                pos = quote_end + 1;
                continue;
            }
            
            // Find slot array
            const array_start = std.mem.indexOfPos(u8, content, quote_end, "[") orelse break;
            const array_end = std.mem.indexOfPos(u8, content, array_start, "]") orelse break;
            const slots_str = content[array_start + 1 .. array_end];
            
            // Parse pubkey (base58 decode simplified)
            var pubkey: Pubkey = undefined;
            @memset(&pubkey, 0);
            const copy_len = @min(key.len, 32);
            @memcpy(pubkey[0..copy_len], key[0..copy_len]);
            
            // Parse slots
            var slot_iter = std.mem.splitScalar(u8, slots_str, ',');
            while (slot_iter.next()) |slot_str| {
                const trimmed = std.mem.trim(u8, slot_str, " \t\n");
                if (trimmed.len == 0) continue;
                
                const slot_num = std.fmt.parseInt(u64, trimmed, 10) catch continue;
                if (slot_num >= first_slot and slot_num < first_slot + slots_per_epoch) {
                    const idx = slot_num - first_slot;
                    slot_leaders[idx] = pubkey;
                }
            }
            
            pos = array_end + 1;
        }
        
        // Add to cache
        const schedule = EpochSchedule{
            .epoch = epoch,
            .first_slot = first_slot,
            .last_slot = first_slot + slots_per_epoch - 1,
            .slot_leaders = slot_leaders,
        };
        
        try self.addSchedule(schedule);
        std.log.info("[LeaderSchedule] Loaded schedule for epoch {d}", .{epoch});
    }
    
    /// Import leader schedule directly (from gossip or snapshot)
    pub fn importSchedule(self: *Self, epoch: Epoch, leaders: []const Pubkey) !void {
        const slot_leaders = try self.allocator.alloc(Pubkey, leaders.len);
        @memcpy(slot_leaders, leaders);
        
        const schedule = EpochSchedule{
            .epoch = epoch,
            .first_slot = self.generator.getFirstSlotInEpoch(epoch),
            .last_slot = self.generator.getLastSlotInEpoch(epoch),
            .slot_leaders = slot_leaders,
        };
        
        try self.addSchedule(schedule);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "leader schedule generator" {
    const allocator = std.testing.allocator;

    var generator = LeaderScheduleGenerator.init(allocator);
    generator.slots_per_epoch = 100; // Small for testing

    var pubkey1: Pubkey = undefined;
    @memset(&pubkey1, 0x11);

    var pubkey2: Pubkey = undefined;
    @memset(&pubkey2, 0x22);

    const stakes = [_]StakeWeight{
        .{ .pubkey = pubkey1, .stake = 1000 },
        .{ .pubkey = pubkey2, .stake = 1000 },
    };

    var schedule = try generator.generate(0, &stakes);
    defer schedule.deinit(allocator);

    try std.testing.expectEqual(@as(Epoch, 0), schedule.epoch);
    try std.testing.expectEqual(@as(Slot, 0), schedule.first_slot);
    try std.testing.expectEqual(@as(Slot, 99), schedule.last_slot);

    // Every slot should have a leader
    for (schedule.slot_leaders) |leader| {
        try std.testing.expect(std.mem.eql(u8, &leader, &pubkey1) or std.mem.eql(u8, &leader, &pubkey2));
    }
}

test "leader schedule cache" {
    const allocator = std.testing.allocator;

    var cache = LeaderScheduleCache.init(allocator);
    defer cache.deinit();

    cache.generator.slots_per_epoch = 100;

    var pubkey1: Pubkey = undefined;
    @memset(&pubkey1, 0x11);

    const stakes = [_]StakeWeight{
        .{ .pubkey = pubkey1, .stake = 1000 },
    };

    try cache.ensureSchedule(0, &stakes);

    // Should be able to get leader
    const leader = cache.getSlotLeader(50);
    try std.testing.expect(leader != null);
}

test "epoch calculation" {
    const allocator = std.testing.allocator;

    const generator = LeaderScheduleGenerator.init(allocator);

    try std.testing.expectEqual(@as(Epoch, 0), generator.getEpoch(0));
    try std.testing.expectEqual(@as(Epoch, 0), generator.getEpoch(431999));
    try std.testing.expectEqual(@as(Epoch, 1), generator.getEpoch(432000));
    try std.testing.expectEqual(@as(Epoch, 1), generator.getEpoch(500000));
}
