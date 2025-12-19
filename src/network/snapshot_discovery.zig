//! Vexor Gossip Snapshot Discovery
//!
//! Discovers available snapshots from cluster peers via gossip protocol.
//! This is used during validator bootstrap to find the best snapshot to download.
//!
//! Flow:
//! 1. Connect to entrypoint(s) and join gossip network
//! 2. Collect SnapshotHashes messages from peers
//! 3. Select best snapshot based on stake weight and slot height
//! 4. Download snapshot from serving peer

const std = @import("std");
const Allocator = std.mem.Allocator;
const crds = @import("crds.zig");
const gossip = @import("gossip.zig");
const socket = @import("socket.zig");
const packet = @import("packet.zig");

/// Discovered snapshot information
pub const DiscoveredSnapshot = struct {
    /// Peer that advertised this snapshot
    from_pubkey: [32]u8,
    /// Peer's RPC address for download
    rpc_addr: ?packet.SocketAddr,
    /// Full snapshot slot and hash
    full_slot: u64,
    full_hash: [32]u8,
    /// Incremental snapshot (if available)
    incremental_slot: ?u64,
    incremental_hash: ?[32]u8,
    /// When this was advertised
    wallclock: u64,
    /// Trust score (based on stake weight)
    trust_score: u32,

    /// Get download URL for full snapshot
    pub fn fullSnapshotUrl(self: *const DiscoveredSnapshot, allocator: Allocator) ![]u8 {
        if (self.rpc_addr) |addr| {
            const ip = addr.ip();
            const port = addr.port();
            return std.fmt.allocPrint(
                allocator,
                "http://{d}.{d}.{d}.{d}:{d}/snapshot-{d}-{s}.tar.zst",
                .{
                    ip[0], ip[1], ip[2], ip[3],
                    port,
                    self.full_slot,
                    std.fmt.fmtSliceHexLower(&self.full_hash),
                },
            );
        }
        return error.NoRpcAddress;
    }

    /// Get download URL for incremental snapshot
    pub fn incrementalSnapshotUrl(self: *const DiscoveredSnapshot, allocator: Allocator) ![]u8 {
        if (self.incremental_slot == null) return error.NoIncrementalSnapshot;
        if (self.rpc_addr) |addr| {
            const ip = addr.ip();
            const port = addr.port();
            return std.fmt.allocPrint(
                allocator,
                "http://{d}.{d}.{d}.{d}:{d}/incremental-snapshot-{d}-{d}-{s}.tar.zst",
                .{
                    ip[0], ip[1], ip[2], ip[3],
                    port,
                    self.full_slot,
                    self.incremental_slot.?,
                    std.fmt.fmtSliceHexLower(&(self.incremental_hash orelse return error.NoIncrementalSnapshot)),
                },
            );
        }
        return error.NoRpcAddress;
    }
};

/// Snapshot discovery service
pub const SnapshotDiscovery = struct {
    allocator: Allocator,
    /// Discovered snapshots by peer
    snapshots: std.AutoHashMap([32]u8, DiscoveredSnapshot),
    /// Contact info for peers (to get RPC address)
    contacts: std.AutoHashMap([32]u8, gossip.ContactInfo),
    /// Minimum slot to consider (filter old snapshots)
    min_slot: u64,
    /// Maximum age in milliseconds
    max_age_ms: u64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .snapshots = std.AutoHashMap([32]u8, DiscoveredSnapshot).init(allocator),
            .contacts = std.AutoHashMap([32]u8, gossip.ContactInfo).init(allocator),
            .min_slot = 0,
            .max_age_ms = 10 * 60 * 1000, // 10 minutes default
        };
    }

    pub fn deinit(self: *Self) void {
        self.snapshots.deinit();
        self.contacts.deinit();
    }

    /// Set minimum slot filter
    pub fn setMinSlot(self: *Self, slot: u64) void {
        self.min_slot = slot;
    }

    /// Process a CRDS value (call from gossip receiver)
    pub fn processGossipValue(self: *Self, value: *const crds.CrdsValue) !void {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());

        switch (value.data) {
            .SnapshotHashes => |sh| {
                // Check age
                if (now_ms > sh.wallclock and now_ms - sh.wallclock > self.max_age_ms) {
                    return; // Too old
                }

                // Check slot
                if (sh.full.slot < self.min_slot) {
                    return; // Too old slot
                }

                // Look up RPC address from contacts
                const rpc_addr = if (self.contacts.get(sh.from)) |ci|
                    ci.rpc_addr
                else
                    null;

                // Store/update snapshot info
                const entry = try self.snapshots.getOrPut(sh.from);
                
                // Determine incremental info
                var inc_slot: ?u64 = null;
                var inc_hash: ?[32]u8 = null;
                if (sh.incremental.len > 0) {
                    // Find the incremental for this full snapshot
                    for (sh.incremental) |inc| {
                        if (inc.slot > sh.full.slot) {
                            inc_slot = inc.slot;
                            inc_hash = inc.hash;
                            break;
                        }
                    }
                }

                entry.value_ptr.* = .{
                    .from_pubkey = sh.from,
                    .rpc_addr = rpc_addr,
                    .full_slot = sh.full.slot,
                    .full_hash = sh.full.hash,
                    .incremental_slot = inc_slot,
                    .incremental_hash = inc_hash,
                    .wallclock = sh.wallclock,
                    .trust_score = 1, // TODO: Calculate from stake weight
                };
            },
            .LegacySnapshotHashes => |sh| {
                if (sh.hashes.len == 0) return;
                
                // Check age
                if (now_ms > sh.wallclock and now_ms - sh.wallclock > self.max_age_ms) {
                    return;
                }

                // Use latest hash as full snapshot
                const latest = sh.hashes[sh.hashes.len - 1];
                if (latest.slot < self.min_slot) return;

                const rpc_addr = if (self.contacts.get(sh.from)) |ci|
                    ci.rpc_addr
                else
                    null;

                const entry = try self.snapshots.getOrPut(sh.from);
                entry.value_ptr.* = .{
                    .from_pubkey = sh.from,
                    .rpc_addr = rpc_addr,
                    .full_slot = latest.slot,
                    .full_hash = latest.hash,
                    .incremental_slot = null,
                    .incremental_hash = null,
                    .wallclock = sh.wallclock,
                    .trust_score = 1,
                };
            },
            .ContactInfo => |ci| {
                // Store contact info for RPC address lookup
                try self.contacts.put(ci.pubkey, gossip.ContactInfo{
                    .pubkey = @as(*const @import("../core/root.zig").Pubkey, @ptrCast(&ci.pubkey)).*,
                    .gossip_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.gossip.port()),
                    .tpu_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.tpu.port()),
                    .tpu_fwd_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.tpu_forwards.port()),
                    .tvu_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.tvu.port()),
                    .tvu_fwd_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.tvu_forwards.port()),
                    .repair_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.repair.port()),
                    .rpc_addr = packet.SocketAddr.ipv4(ci.rpc.ip(), ci.rpc.port()),
                    .serve_repair_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, ci.serve_repair.port()),
                    .wallclock = ci.wallclock,
                    .shred_version = ci.shred_version,
                    .version = .{ .major = 0, .minor = 0, .patch = 0, .commit = null },
                });
            },
            .LegacyContactInfo => |ci| {
                try self.contacts.put(ci.pubkey, gossip.ContactInfo{
                    .pubkey = @as(*const @import("../core/root.zig").Pubkey, @ptrCast(&ci.pubkey)).*,
                    .gossip_addr = packet.SocketAddr.ipv4(ci.gossip.ip(), ci.gossip.port()),
                    .tpu_addr = packet.SocketAddr.ipv4(ci.tpu.ip(), ci.tpu.port()),
                    .tpu_fwd_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, 0),
                    .tvu_addr = packet.SocketAddr.ipv4(ci.tvu.ip(), ci.tvu.port()),
                    .tvu_fwd_addr = packet.SocketAddr.ipv4(.{ 0, 0, 0, 0 }, 0),
                    .repair_addr = packet.SocketAddr.ipv4(ci.repair.ip(), ci.repair.port()),
                    .rpc_addr = packet.SocketAddr.ipv4(ci.rpc.ip(), ci.rpc.port()),
                    .serve_repair_addr = packet.SocketAddr.ipv4(ci.serve_repair.ip(), ci.serve_repair.port()),
                    .wallclock = ci.wallclock,
                    .shred_version = ci.shred_version,
                    .version = .{ .major = 0, .minor = 0, .patch = 0, .commit = null },
                });
            },
            else => {},
        }
    }

    /// Get the best snapshot to download
    /// Selection criteria:
    /// 1. Highest trust score
    /// 2. Highest slot
    /// 3. Has incremental (preferred)
    pub fn getBestSnapshot(self: *Self) ?DiscoveredSnapshot {
        var best: ?DiscoveredSnapshot = null;
        var best_score: u64 = 0;

        var iter = self.snapshots.valueIterator();
        while (iter.next()) |snapshot| {
            // Check if we have RPC address
            if (snapshot.rpc_addr == null) continue;

            // Score: trust_score * slot + incremental bonus
            const has_inc: u64 = if (snapshot.incremental_slot != null) 1000000 else 0;
            const score = @as(u64, snapshot.trust_score) * snapshot.full_slot + has_inc;

            if (score > best_score) {
                best_score = score;
                best = snapshot.*;
            }
        }

        return best;
    }

    /// Get all discovered snapshots sorted by slot (descending)
    pub fn getAllSnapshots(self: *Self, allocator: Allocator) ![]DiscoveredSnapshot {
        var list = std.ArrayList(DiscoveredSnapshot).init(allocator);
        errdefer list.deinit();

        var iter = self.snapshots.valueIterator();
        while (iter.next()) |s| {
            if (s.rpc_addr != null) {
                try list.append(s.*);
            }
        }

        // Sort by slot descending
        std.mem.sort(DiscoveredSnapshot, list.items, {}, struct {
            fn lessThan(_: void, a: DiscoveredSnapshot, b: DiscoveredSnapshot) bool {
                return a.full_slot > b.full_slot;
            }
        }.lessThan);

        return try list.toOwnedSlice();
    }

    /// Get count of discovered snapshots
    pub fn count(self: *Self) usize {
        return self.snapshots.count();
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

test "snapshot discovery init/deinit" {
    var sd = SnapshotDiscovery.init(std.testing.allocator);
    defer sd.deinit();

    try std.testing.expectEqual(@as(usize, 0), sd.count());
}

test "snapshot discovery min slot filter" {
    var sd = SnapshotDiscovery.init(std.testing.allocator);
    defer sd.deinit();

    sd.setMinSlot(1000);
    try std.testing.expectEqual(@as(u64, 1000), sd.min_slot);
}

