//! Lock-free data structures
//!
//! Implements high-performance concurrent data structures.
//!
//! - MPMC Bounded Queue (based on Dmitry Vyukov's design)

const std = @import("std");

/// Multi-Producer Multi-Consumer Bounded Queue
/// Safe for concurrent use by any number of producers and consumers.
/// T must be copyable (value type).
pub fn MPmcQueue(comptime T: type, comptime capacity: usize) type {
    // Capacity must be power of 2
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("MPmcQueue capacity must be a power of 2");
        }
    }

    return struct {
        const Self = @This();
        const mask = capacity - 1;

        const Slot = struct {
            turn: std.atomic.Value(usize),
            data: T,
        };

        // Cache-line padding to prevent false sharing
        _pad0: [56]u8 = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        _pad1: [56]u8 = undefined,
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        _pad2: [56]u8 = undefined,
        buffer: [capacity]Slot = undefined,

        pub fn init() Self {
            var self = Self{};
            for (&self.buffer, 0..) |*slot, i| {
                slot.turn = std.atomic.Value(usize).init(i);
            }
            return self;
        }

        /// Push item to queue. Returns error if full.
        pub fn push(self: *Self, item: T) !void {
            var head = self.head.load(.seq_cst);
            while (true) {
                const slot = &self.buffer[head & mask];
                const turn = slot.turn.load(.acquire);
                const diff = @as(isize, @intCast(turn)) - @as(isize, @intCast(head));

                if (diff == 0) {
                    // Slot is ready for writing
                    if (self.head.cmpxchgWeak(head, head + 1, .seq_cst, .seq_cst)) |new_head| {
                        head = new_head;
                        continue;
                    }

                    // We claimed the slot
                    slot.data = item;
                    slot.turn.store(head + 1, .release);
                    return;
                } else if (diff < 0) {
                    // Queue full
                    return error.QueueFull;
                } else {
                    // Contention, reload head
                    head = self.head.load(.seq_cst);
                }
            }
        }

        /// Pop item from queue. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            var tail = self.tail.load(.seq_cst);
            while (true) {
                const slot = &self.buffer[tail & mask];
                const turn = slot.turn.load(.acquire);
                const diff = @as(isize, @intCast(turn)) - @as(isize, @intCast(tail + 1));

                if (diff == 0) {
                    // Slot is ready for reading
                    if (self.tail.cmpxchgWeak(tail, tail + 1, .seq_cst, .seq_cst)) |new_tail| {
                        tail = new_tail;
                        continue;
                    }

                    // We claimed the slot
                    const item = slot.data;
                    slot.turn.store(tail + capacity, .release);
                    return item;
                } else if (diff < 0) {
                    // Queue empty
                    return null;
                } else {
                    // Contention, reload tail
                    tail = self.tail.load(.seq_cst);
                }
            }
        }

        /// Estimate count (not strictly accurate due to concurrency)
        pub fn count(self: *Self) usize {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.monotonic);
            if (h > t) return h - t;
            return 0;
        }
    };
}

test "MPmcQueue basic" {
    var queue = MPmcQueue(u32, 4).init();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try queue.push(4);
    try std.testing.expectError(error.QueueFull, queue.push(5));

    try std.testing.expectEqual(@as(u32, 1), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 2), queue.pop().?);

    try queue.push(5);
    try queue.push(6);

    try std.testing.expectEqual(@as(u32, 3), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 4), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 5), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 6), queue.pop().?);
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}
