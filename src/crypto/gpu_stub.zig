//! GPU Stub
//!
//! Placeholder when GPU acceleration is disabled.

const std = @import("std");
const core = @import("../core/root.zig");

pub const MIN_BATCH_FOR_GPU = std.math.maxInt(usize); // Never use GPU

pub const GpuDevice = struct {
    name: []const u8,
    vram_gb: u32,
    compute_capability: struct { major: u32, minor: u32 },
    multiprocessors: u32,
    cuda_cores: u32,
};

pub fn isAvailable() !bool {
    return false;
}

pub fn detect() !?GpuDevice {
    return null;
}

pub fn batchVerify(
    allocator: std.mem.Allocator,
    signatures: []const core.Signature,
    pubkeys: []const core.Pubkey,
    messages: []const []const u8,
) !BatchVerifyResult {
    _ = allocator;
    _ = signatures;
    _ = pubkeys;
    _ = messages;
    return error.GpuNotAvailable;
}

pub const BatchVerifyResult = struct {
    valid_count: usize,
    valid_bitmap: []u8,
    time_ns: u64,
    gpu_time_ns: u64,
};

pub const GpuContext = struct {
    pub fn init(device_id: i32) !GpuContext {
        _ = device_id;
        return error.GpuNotAvailable;
    }

    pub fn deinit(self: *GpuContext) void {
        _ = self;
    }
};

pub const GpuStats = struct {
    signatures_verified: u64 = 0,
    total_gpu_time_ns: u64 = 0,
};

test "gpu stub" {
    const available = try isAvailable();
    try std.testing.expect(!available);
}

