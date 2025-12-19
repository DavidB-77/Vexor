//! Cluster Discovery via RPC
//!
//! This module provides RPC-based cluster node discovery as a workaround
//! for the gossip protocol incompatibility. It fetches cluster nodes from
//! a trusted RPC endpoint and provides their TVU addresses for shred reception.
//!
//! NOTE: This is a temporary solution. Full gossip implementation is required
//! for voting and block production.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const packet = @import("packet.zig");

/// Cluster node information from RPC
pub const ClusterNode = struct {
    pubkey: core.Pubkey,
    tvu_addr: ?packet.SocketAddr,
    gossip_addr: ?packet.SocketAddr,
    repair_addr: ?packet.SocketAddr,
    shred_version: u16,
    version: []const u8,
};

/// RPC-based cluster discovery
pub const ClusterDiscovery = struct {
    allocator: Allocator,
    nodes: std.ArrayList(ClusterNode),
    rpc_url: []const u8,
    shred_version: u16,
    last_refresh: i64,
    refresh_interval_ms: i64,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, rpc_url: []const u8) Self {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(ClusterNode).init(allocator),
            .rpc_url = rpc_url,
            .shred_version = 0,
            .last_refresh = 0,
            .refresh_interval_ms = 60000, // Refresh every 60 seconds
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.nodes.deinit();
    }
    
    /// Refresh cluster nodes from RPC
    pub fn refresh(self: *Self) !void {
        const now = std.time.milliTimestamp();
        if (now - self.last_refresh < self.refresh_interval_ms) return;
        
        std.log.info("[ClusterDiscovery] Refreshing cluster nodes from RPC...", .{});
        
        // In a real implementation, this would make an HTTP request to the RPC
        // endpoint and parse the JSON response. For now, we'll use hardcoded
        // testnet nodes as a proof of concept.
        
        // Clear existing nodes
        self.nodes.clearRetainingCapacity();
        
        // Add testnet entrypoints (these are real testnet nodes from getClusterNodes)
        try self.addTestnetNodes();
        
        self.last_refresh = now;
        std.log.info("[ClusterDiscovery] Found {d} cluster nodes", .{self.nodes.items.len});
    }
    
    /// Add known testnet nodes (hardcoded for now)
    fn addTestnetNodes(self: *Self) !void {
        // These are real testnet nodes from the getClusterNodes RPC response
        const testnet_nodes = [_]struct {
            ip: [4]u8,
            tvu_port: u16,
            gossip_port: u16,
        }{
            .{ .ip = .{ 192, 155, 103, 41 }, .tvu_port = 8002, .gossip_port = 8001 },
            .{ .ip = .{ 104, 250, 133, 50 }, .tvu_port = 8000, .gossip_port = 8001 },
            .{ .ip = .{ 186, 233, 184, 93 }, .tvu_port = 8001, .gossip_port = 8000 },
            .{ .ip = .{ 147, 28, 169, 89 }, .tvu_port = 8002, .gossip_port = 8001 },
        };
        
        for (testnet_nodes) |node| {
            try self.nodes.append(.{
                .pubkey = core.Pubkey{}, // Empty for now
                .tvu_addr = packet.SocketAddr.ipv4(node.ip, node.tvu_port),
                .gossip_addr = packet.SocketAddr.ipv4(node.ip, node.gossip_port),
                .repair_addr = null,
                .shred_version = 9604, // Testnet shred version
                .version = "3.1.4",
            });
        }
        
        self.shred_version = 9604;
    }
    
    /// Get TVU addresses of all known nodes
    pub fn getTvuAddresses(self: *Self) []packet.SocketAddr {
        var addrs = std.ArrayList(packet.SocketAddr).init(self.allocator);
        for (self.nodes.items) |node| {
            if (node.tvu_addr) |addr| {
                addrs.append(addr) catch continue;
            }
        }
        return addrs.toOwnedSlice() catch &[_]packet.SocketAddr{};
    }
    
    /// Get node count
    pub fn nodeCount(self: *const Self) usize {
        return self.nodes.items.len;
    }
    
    /// Get shred version
    pub fn getShredVersion(self: *const Self) u16 {
        return self.shred_version;
    }
};

