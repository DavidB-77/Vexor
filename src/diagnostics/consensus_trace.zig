const std = @import("std");
const core = @import("../core/root.zig");

pub const Milestone = enum {
    received,
    verified,
    replayed,
    voted,
    rooted,

    pub fn label(self: Milestone) []const u8 {
        return switch (self) {
            .received => "RCVD",
            .verified => "VRFY",
            .replayed => "RPLY",
            .voted => "VOTE",
            .rooted => "ROOT",
        };
    }
};

pub const SlotTrace = struct {
    slot: core.Slot,
    milestones: [5]?i64,

    pub fn init(slot: core.Slot) SlotTrace {
        return .{
            .slot = slot,
            .milestones = .{ null, null, null, null, null },
        };
    }

    pub fn mark(self: *SlotTrace, milestone: Milestone) void {
        const idx = @intFromEnum(milestone);
        if (self.milestones[idx] == null) {
            self.milestones[idx] = std.time.milliTimestamp();
        }
    }
};

pub const ConsensusTracker = struct {
    mutex: std.Thread.Mutex = .{},
    traces: [20]SlotTrace = undefined,
    idx: usize = 0,

    pub fn init() ConsensusTracker {
        var tracker = ConsensusTracker{
            .mutex = .{},
            .idx = 0,
        };
        for (tracker.traces[0..20]) |*t| {
            t.* = SlotTrace.init(0);
        }
        return tracker;
    }

    pub fn report(self: *ConsensusTracker, slot: core.Slot, milestone: Milestone) void {
        if (slot == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find existing or reuse old
        for (self.traces[0..20]) |*t| {
            if (t.slot == slot) {
                t.mark(milestone);
                return;
            }
        }

        // Reuse idx (ring buffer)
        const t = &self.traces[self.idx];
        t.* = SlotTrace.init(slot);
        t.mark(milestone);
        self.idx = (self.idx + 1) % 20;
    }

    pub fn printTraceBoard(self: *ConsensusTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.print("\n\x1b[1;35m┌────────────────── CONSENSUS TRACE (Recent Slots) ───────────────────┐\x1b[0m\n", .{});
        std.debug.print("\x1b[1;35m│\x1b[0m Slot        │ RCVD │ VRFY │ RPLY │ VOTE │ ROOT │ Status             \x1b[1;35m│\x1b[0m\n", .{});
        std.debug.print("\x1b[1;35m├─────────────┼──────┼──────┼──────┼──────┼──────┼────────────────────┤\x1b[0m\n", .{});

        // Collect and sort traces for display (most recent first)
        var sorted: [20]*SlotTrace = undefined;
        for (self.traces[0..20], 0..) |*t, i| sorted[i] = t;

        std.mem.sort(*SlotTrace, &sorted, {}, struct {
            fn lessThan(_: void, a: *SlotTrace, b: *SlotTrace) bool {
                return a.slot > b.slot;
            }
        }.lessThan);

        var count: usize = 0;
        for (sorted) |t| {
            if (t.slot == 0) continue;
            if (count >= 10) break; // Only show last 10
            count += 1;

            std.debug.print("\x1b[1;35m│\x1b[0m {d:<11} │", .{t.slot});

            inline for (@typeInfo(Milestone).Enum.fields) |f| {
                const mark_time = t.milestones[f.value];
                if (mark_time != null) {
                    std.debug.print("  ✅  │", .{});
                } else {
                    std.debug.print("  ..  │", .{});
                }
            }

            // Status summary
            const status = if (t.milestones[4] != null) "\x1b[32mFINALIZED\x1b[0m" else if (t.milestones[3] != null) "\x1b[33mVOTED\x1b[0m" else if (t.milestones[2] != null) "\x1b[36mREPLAYED\x1b[0m" else "PROCESSING";

            std.debug.print(" {s:<18} \x1b[1;35m│\x1b[0m\n", .{status});
        }
        std.debug.print("\x1b[1;35m└─────────────────────────────────────────────────────────────────────┘\x1b[0m\n", .{});
    }
};
