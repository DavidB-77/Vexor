//! Vexor Memory Allocator
//!
//! Custom allocator strategies optimized for validator workloads:
//! - Arena allocator for transaction processing (per-slot)
//! - Pool allocator for fixed-size objects (packets, shreds)
//! - Memory-mapped regions for large data structures

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// High-performance arena allocator for per-slot allocations
/// Memory is allocated in bulk and freed all at once at slot boundaries
pub const SlotArena = struct {
    backing: Allocator,
    arena: std.heap.ArenaAllocator,
    slot: u64,
    bytes_allocated: usize,
    allocation_count: usize,

    const Self = @This();

    pub fn init(backing: Allocator, slot: u64) Self {
        return .{
            .backing = backing,
            .arena = std.heap.ArenaAllocator.init(backing),
            .slot = slot,
            .bytes_allocated = 0,
            .allocation_count = 0,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return self.arena.allocator();
    }

    /// Reset for a new slot - O(1) operation
    pub fn reset(self: *Self, new_slot: u64) void {
        _ = self.arena.reset(.retain_capacity);
        self.slot = new_slot;
        self.bytes_allocated = 0;
        self.allocation_count = 0;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn stats(self: *const Self) ArenaStats {
        return .{
            .slot = self.slot,
            .bytes_allocated = self.bytes_allocated,
            .allocation_count = self.allocation_count,
        };
    }

    pub const ArenaStats = struct {
        slot: u64,
        bytes_allocated: usize,
        allocation_count: usize,
    };
};

/// Fixed-size pool allocator for high-frequency object types
/// Zero fragmentation, O(1) alloc/free
pub fn PoolAllocator(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            data: T,
            next: ?*Node,
        };

        backing: Allocator,
        free_list: ?*Node,
        blocks: std.ArrayList(*[BLOCK_SIZE]Node),
        allocated_count: usize,
        free_count: usize,

        const BLOCK_SIZE = 4096; // Objects per block

        pub fn init(backing: Allocator) Self {
            return .{
                .backing = backing,
                .free_list = null,
                .blocks = std.ArrayList(*[BLOCK_SIZE]Node).init(backing),
                .allocated_count = 0,
                .free_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.blocks.items) |block| {
                self.backing.destroy(block);
            }
            self.blocks.deinit();
        }

        pub fn alloc(self: *Self) !*T {
            if (self.free_list) |node| {
                self.free_list = node.next;
                self.free_count -= 1;
                self.allocated_count += 1;
                return &node.data;
            }

            // Allocate new block
            const block = try self.backing.create([BLOCK_SIZE]Node);
            try self.blocks.append(block);

            // Initialize free list with new nodes (skip first, return it)
            for (block[1..]) |*node| {
                node.next = self.free_list;
                self.free_list = node;
                self.free_count += 1;
            }

            self.allocated_count += 1;
            return &block[0].data;
        }

        pub fn free(self: *Self, ptr: *T) void {
            const node: *Node = @fieldParentPtr("data", ptr);
            node.next = self.free_list;
            self.free_list = node;
            self.allocated_count -= 1;
            self.free_count += 1;
        }

        pub fn stats(self: *const Self) PoolStats {
            return .{
                .allocated = self.allocated_count,
                .free = self.free_count,
                .blocks = self.blocks.items.len,
                .capacity = self.blocks.items.len * BLOCK_SIZE,
            };
        }

        pub const PoolStats = struct {
            allocated: usize,
            free: usize,
            blocks: usize,
            capacity: usize,
        };
    };
}

/// Memory-mapped allocator for large persistent structures
/// Uses mmap for zero-copy I/O
pub const MmapAllocator = struct {
    const Self = @This();

    mappings: std.ArrayList(Mapping),
    backing: Allocator,

    const Mapping = struct {
        ptr: [*]align(std.mem.page_size) u8,
        len: usize,
    };

    pub fn init(backing: Allocator) Self {
        return .{
            .mappings = std.ArrayList(Mapping).init(backing),
            .backing = backing,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.mappings.items) |mapping| {
            std.posix.munmap(mapping.ptr[0..mapping.len]);
        }
        self.mappings.deinit();
    }

    /// Allocate anonymous memory-mapped region
    pub fn allocAnon(self: *Self, size: usize) ![]align(std.mem.page_size) u8 {
        const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
        
        const ptr = try std.posix.mmap(
            null,
            aligned_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        try self.mappings.append(.{
            .ptr = @alignCast(ptr.ptr),
            .len = aligned_size,
        });

        return @alignCast(ptr);
    }

    /// Map a file into memory
    pub fn mapFile(self: *Self, path: []const u8, writable: bool) ![]align(std.mem.page_size) u8 {
        const file = try std.fs.cwd().openFile(path, .{
            .mode = if (writable) .read_write else .read_only,
        });
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        const prot = std.posix.PROT.READ | if (writable) std.posix.PROT.WRITE else 0;
        
        const ptr = try std.posix.mmap(
            null,
            size,
            prot,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        try self.mappings.append(.{
            .ptr = @alignCast(ptr.ptr),
            .len = size,
        });

        return @alignCast(ptr);
    }
};

/// Huge page allocator for performance-critical data
/// Uses 2MB or 1GB huge pages when available
pub const HugePageAllocator = struct {
    const Self = @This();

    pub const PageSize = enum {
        regular, // 4KB
        huge_2mb,
        huge_1gb,

        pub fn bytes(self: PageSize) usize {
            return switch (self) {
                .regular => 4096,
                .huge_2mb => 2 * 1024 * 1024,
                .huge_1gb => 1024 * 1024 * 1024,
            };
        }
    };

    /// Attempt to allocate huge pages, falling back to regular pages
    pub fn allocHuge(size: usize, prefer: PageSize) ![]align(std.mem.page_size) u8 {
        const page_size = prefer.bytes();
        const aligned_size = std.mem.alignForward(usize, size, page_size);

        // Try huge pages first via madvise
        const ptr = try std.posix.mmap(
            null,
            aligned_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        // Advise kernel to use huge pages (best effort)
        if (prefer != .regular) {
            std.posix.madvise(ptr, aligned_size, .HUGEPAGE) catch {
                // Huge pages not available, continue with regular pages
            };
        }

        return @alignCast(ptr);
    }

    pub fn free(ptr: []align(std.mem.page_size) u8) void {
        std.posix.munmap(ptr);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "slot arena basic" {
    var arena = SlotArena.init(std.testing.allocator, 100);
    defer arena.deinit();

    const alloc = arena.allocator();
    const ptr = try alloc.alloc(u8, 1024);
    try std.testing.expectEqual(@as(usize, 1024), ptr.len);

    arena.reset(101);
    try std.testing.expectEqual(@as(u64, 101), arena.slot);
}

test "pool allocator" {
    const TestStruct = struct {
        value: u64,
        data: [64]u8,
    };

    var pool = PoolAllocator(TestStruct).init(std.testing.allocator);
    defer pool.deinit();

    const obj1 = try pool.alloc();
    obj1.value = 42;

    const obj2 = try pool.alloc();
    obj2.value = 43;

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 2), stats.allocated);

    pool.free(obj1);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().allocated);
}

test "mmap allocator" {
    var mmap = MmapAllocator.init(std.testing.allocator);
    defer mmap.deinit();

    const mem = try mmap.allocAnon(1024 * 1024); // 1MB
    try std.testing.expectEqual(@as(usize, 1024 * 1024), mem.len);

    // Write and read
    mem[0] = 0xAB;
    mem[mem.len - 1] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), mem[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), mem[mem.len - 1]);
}

