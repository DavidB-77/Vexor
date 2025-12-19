//! RAM Disk Stub
//!
//! Placeholder when RAM disk is disabled.

const std = @import("std");
const core = @import("../core/root.zig");

pub const RamdiskManager = struct {
    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !*RamdiskManager {
        _ = allocator;
        _ = path;
        _ = max_size;
        return error.RamdiskDisabled;
    }

    pub fn deinit(self: *RamdiskManager) void {
        _ = self;
    }

    pub fn availableSpace(self: *RamdiskManager) usize {
        _ = self;
        return 0;
    }

    pub fn shouldEvict(self: *RamdiskManager) bool {
        _ = self;
        return false;
    }
};

