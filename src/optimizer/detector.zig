//! Vexor Hardware Detector
//!
//! Detects system hardware capabilities for optimization.

const std = @import("std");
const builtin = @import("builtin");

/// CPU information
pub const CpuInfo = struct {
    model: []const u8,
    vendor: Vendor,
    cores: u32,
    threads: u32,
    cache_l1: u32, // KB
    cache_l2: u32, // KB
    cache_l3: u32, // KB
    features: CpuFeatures,

    pub const Vendor = enum {
        intel,
        amd,
        arm,
        unknown,
    };

    pub const CpuFeatures = struct {
        avx2: bool = false,
        avx512: bool = false,
        sha_ni: bool = false,
        aes_ni: bool = false,
        neon: bool = false,
    };
};

/// Memory information
pub const MemoryInfo = struct {
    total: u64,
    available: u64,
    swap_total: u64,
    swap_free: u64,
    huge_pages_total: u64,
    huge_pages_free: u64,
};

/// GPU information
pub const GpuInfo = struct {
    name: []const u8,
    vendor: Vendor,
    vram_bytes: u64,
    compute_units: u32,
    driver_version: []const u8,

    pub const Vendor = enum {
        nvidia,
        amd,
        intel,
        unknown,
    };
};

/// Network interface information
pub const NetworkInfo = struct {
    name: []const u8,
    driver: []const u8,
    speed_mbps: u32,
    xdp_capable: bool,
    rx_queues: u32,
    tx_queues: u32,
};

/// Detect CPU information
pub fn detectCpu(allocator: std.mem.Allocator) !CpuInfo {
    var info = CpuInfo{
        .model = "Unknown",
        .vendor = .unknown,
        .cores = 1,
        .threads = 1,
        .cache_l1 = 0,
        .cache_l2 = 0,
        .cache_l3 = 0,
        .features = .{},
    };

    if (builtin.os.tag == .linux) {
        // Read from /proc/cpuinfo
        const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return info;
        defer file.close();

        var buf: [8192]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return info;
        const content = buf[0..bytes_read];

        // Parse model name
        if (std.mem.indexOf(u8, content, "model name")) |start| {
            if (std.mem.indexOfPos(u8, content, start, ":")) |colon| {
                if (std.mem.indexOfPos(u8, content, colon + 2, "\n")) |end| {
                    info.model = try allocator.dupe(u8, content[colon + 2 .. end]);
                }
            }
        }

        // Detect vendor
        if (std.mem.indexOf(u8, content, "GenuineIntel")) |_| {
            info.vendor = .intel;
        } else if (std.mem.indexOf(u8, content, "AuthenticAMD")) |_| {
            info.vendor = .amd;
        }

        // Count cores (count "processor" entries)
        var cores: u32 = 0;
        var iter = std.mem.splitSequence(u8, content, "processor");
        while (iter.next()) |_| {
            cores += 1;
        }
        if (cores > 0) cores -= 1; // Subtract 1 for the text before first "processor"
        info.threads = cores;
        info.cores = cores / 2; // Assume hyperthreading, adjust as needed
        if (info.cores == 0) info.cores = 1;

        // Detect features
        info.features.avx2 = std.mem.indexOf(u8, content, " avx2 ") != null;
        info.features.avx512 = std.mem.indexOf(u8, content, " avx512") != null;
        info.features.sha_ni = std.mem.indexOf(u8, content, " sha_ni ") != null;
        info.features.aes_ni = std.mem.indexOf(u8, content, " aes ") != null;
    } else {
        info.model = try allocator.dupe(u8, "Unknown (non-Linux)");
    }

    return info;
}

/// Detect memory information
pub fn detectMemory() !MemoryInfo {
    var info = MemoryInfo{
        .total = 0,
        .available = 0,
        .swap_total = 0,
        .swap_free = 0,
        .huge_pages_total = 0,
        .huge_pages_free = 0,
    };

    if (builtin.os.tag == .linux) {
        const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return info;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return info;
        const content = buf[0..bytes_read];

        // Parse memory values
        info.total = parseMemValue(content, "MemTotal:");
        info.available = parseMemValue(content, "MemAvailable:");
        info.swap_total = parseMemValue(content, "SwapTotal:");
        info.swap_free = parseMemValue(content, "SwapFree:");
        info.huge_pages_total = parseMemValue(content, "HugePages_Total:") * 2 * 1024 * 1024; // 2MB huge pages
        info.huge_pages_free = parseMemValue(content, "HugePages_Free:") * 2 * 1024 * 1024;
    }

    return info;
}

fn parseMemValue(content: []const u8, key: []const u8) u64 {
    if (std.mem.indexOf(u8, content, key)) |start| {
        const after_key = content[start + key.len ..];
        var i: usize = 0;
        // Skip whitespace
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == '\t')) : (i += 1) {}
        // Parse number
        var num: u64 = 0;
        while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
            num = num * 10 + @as(u64, after_key[i] - '0');
        }
        // Assume kB, convert to bytes
        return num * 1024;
    }
    return 0;
}

/// Detect GPU information
pub fn detectGpu(allocator: std.mem.Allocator) !?GpuInfo {
    _ = allocator;
    // TODO: Implement GPU detection via nvidia-smi or similar
    return null;
}

/// Detect network interfaces
pub fn detectNetwork(allocator: std.mem.Allocator) ![]NetworkInfo {
    _ = allocator;
    // TODO: Implement network detection via /sys/class/net
    return &.{};
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "detect cpu" {
    const info = try detectCpu(std.testing.allocator);
    defer std.testing.allocator.free(info.model);

    try std.testing.expect(info.cores >= 1);
    try std.testing.expect(info.threads >= 1);
}

test "detect memory" {
    const info = try detectMemory();
    if (builtin.os.tag == .linux) {
        try std.testing.expect(info.total > 0);
    }
}

