//! Vexor System Tuner
//!
//! Applies system-level optimizations for validator performance.

const std = @import("std");
const builtin = @import("builtin");

/// Check if we can modify system settings
pub fn canModifySystem() !bool {
    if (builtin.os.tag != .linux) return false;

    // Check if running as root or have CAP_SYS_ADMIN
    const uid = std.os.linux.getuid();
    return uid == 0;
}

/// Optimize kernel parameters via sysctl
pub fn optimizeKernel() !void {
    if (builtin.os.tag != .linux) return;

    // These are the key parameters for validator performance
    const params = [_]struct { []const u8, []const u8 }{
        // Network tuning
        .{ "net.core.rmem_max", "134217728" }, // 128MB receive buffer
        .{ "net.core.wmem_max", "134217728" }, // 128MB send buffer
        .{ "net.core.rmem_default", "134217728" },
        .{ "net.core.wmem_default", "134217728" },
        .{ "net.core.netdev_max_backlog", "250000" },
        .{ "net.core.somaxconn", "65535" },
        .{ "net.ipv4.tcp_rmem", "4096 87380 134217728" },
        .{ "net.ipv4.tcp_wmem", "4096 87380 134217728" },
        .{ "net.ipv4.udp_rmem_min", "16384" },
        .{ "net.ipv4.udp_wmem_min", "16384" },

        // Memory tuning
        .{ "vm.swappiness", "1" }, // Minimize swap usage
        .{ "vm.dirty_ratio", "80" },
        .{ "vm.dirty_background_ratio", "5" },
        .{ "vm.max_map_count", "1000000" },

        // File descriptor limits
        .{ "fs.file-max", "500000" },
        .{ "fs.nr_open", "500000" },
    };

    for (params) |param| {
        const path = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "/proc/sys/{s}",
            .{std.mem.replaceOwned(u8, std.heap.page_allocator, param[0], ".", "/") catch continue},
        );
        defer std.heap.page_allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch continue;
        defer file.close();

        _ = file.write(param[1]) catch {};
    }
}

/// Set CPU governor to performance mode
pub fn optimizeCpuGovernor() !void {
    if (builtin.os.tag != .linux) return;

    // Find all CPU scaling governor files
    var dir = std.fs.openDirAbsolute("/sys/devices/system/cpu", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "cpu") and entry.name.len > 3) {
            const digit = entry.name[3];
            if (digit >= '0' and digit <= '9') {
                const governor_path = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "/sys/devices/system/cpu/{s}/cpufreq/scaling_governor",
                    .{entry.name},
                ) catch continue;
                defer std.heap.page_allocator.free(governor_path);

                const file = std.fs.openFileAbsolute(governor_path, .{ .mode = .write_only }) catch continue;
                defer file.close();

                _ = file.write("performance") catch {};
            }
        }
    }
}

/// Optimize network settings
pub fn optimizeNetwork() !void {
    if (builtin.os.tag != .linux) return;

    // Enable TCP BBR congestion control if available
    const bbr_path = "/proc/sys/net/ipv4/tcp_congestion_control";
    const file = std.fs.openFileAbsolute(bbr_path, .{ .mode = .write_only }) catch return;
    defer file.close();
    _ = file.write("bbr") catch {};

    // TODO: Configure IRQ affinity for network interfaces
}

/// Set IRQ affinity for a network interface
pub fn setIrqAffinity(interface: []const u8, cpu_mask: u64) !void {
    _ = interface;
    _ = cpu_mask;
    // TODO: Find IRQs for interface and set affinity via /proc/irq/N/smp_affinity
}

/// Optimization recommendation
pub const Recommendation = struct {
    description: []const u8,
    priority: Priority,
    category: Category,

    pub const Priority = enum {
        critical,
        high,
        medium,
        low,
    };

    pub const Category = enum {
        kernel,
        cpu,
        memory,
        network,
        storage,
    };
};

/// Get optimization recommendations based on current system state
pub fn getRecommendations(allocator: std.mem.Allocator) ![]Recommendation {
    var recommendations = std.ArrayList(Recommendation).init(allocator);

    // Check swap usage
    if (builtin.os.tag == .linux) {
        const swappiness = readSysctl("vm.swappiness") catch null;
        if (swappiness) |val| {
            if (val > 10) {
                try recommendations.append(.{
                    .description = try allocator.dupe(u8, "Reduce vm.swappiness to 1 for better performance"),
                    .priority = .high,
                    .category = .memory,
                });
            }
        }

        // Check CPU governor
        const governor = readCpuGovernor() catch null;
        if (governor) |gov| {
            if (!std.mem.eql(u8, gov, "performance")) {
                try recommendations.append(.{
                    .description = try allocator.dupe(u8, "Set CPU governor to 'performance' mode"),
                    .priority = .critical,
                    .category = .cpu,
                });
            }
        }

        // Check network buffer sizes
        const rmem_max = readSysctl("net.core.rmem_max") catch null;
        if (rmem_max) |val| {
            if (val < 134217728) {
                try recommendations.append(.{
                    .description = try allocator.dupe(u8, "Increase network buffer sizes for better throughput"),
                    .priority = .high,
                    .category = .network,
                });
            }
        }
    }

    return recommendations.toOwnedSlice();
}

fn readSysctl(param: []const u8) !u64 {
    var path_buf: [256]u8 = undefined;
    var i: usize = 0;
    for ("/proc/sys/") |c| {
        path_buf[i] = c;
        i += 1;
    }
    for (param) |c| {
        path_buf[i] = if (c == '.') '/' else c;
        i += 1;
    }

    const file = try std.fs.openFileAbsolute(path_buf[0..i], .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = try file.readAll(&buf);
    const trimmed = std.mem.trim(u8, buf[0..len], " \n\t");

    return std.fmt.parseInt(u64, trimmed, 10);
}

fn readCpuGovernor() ![]const u8 {
    const file = try std.fs.openFileAbsolute("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = try file.readAll(&buf);
    return std.mem.trim(u8, buf[0..len], " \n\t");
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "can modify system" {
    const can = try canModifySystem();
    // Just verify it doesn't crash
    _ = can;
}

test "get recommendations" {
    const recs = try getRecommendations(std.testing.allocator);
    defer {
        for (recs) |rec| {
            std.testing.allocator.free(rec.description);
        }
        std.testing.allocator.free(recs);
    }
    // Just verify it returns something
}

