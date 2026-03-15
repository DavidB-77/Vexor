//! Vexor Snapshot Manager
//!
//! Handles downloading, validating, and loading snapshots from the cluster.
//! Snapshots are the primary mechanism for bootstrapping a new validator.
//!
//! Snapshot Types:
//! - Full snapshot: Complete state at a specific slot
//! - Incremental snapshot: Changes since the last full snapshot
//!
//! File Format:
//! snapshot-<slot>-<hash>.tar.zst (full)
//! incremental-snapshot-<base_slot>-<slot>-<hash>.tar.zst (incremental)

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const fs = std.fs;
const zstd = std.compress.zstd;
const core = @import("../core/root.zig");

/// Snapshot metadata
pub const SnapshotInfo = struct {
    slot: u64,
    hash: [32]u8,
    base_slot: ?u64, // For incremental snapshots
    lamports: u64,
    capitalization: u64,
    accounts_count: u64,
    size_bytes: u64,
    is_incremental: bool,
    download_url: ?[]const u8,
    /// Original filename (for local snapshots)
    filename: ?[]const u8 = null,
    /// Hash string (Base58) for path reconstruction
    hash_str: [64]u8 = undefined,
    hash_str_len: u8 = 0,

    /// Parse snapshot filename to extract metadata
    pub fn fromFilename(filename: []const u8) ?SnapshotInfo {
        // Full: snapshot-<slot>-<hash>.tar.zst
        // Incr: incremental-snapshot-<base>-<slot>-<hash>.tar.zst

        if (std.mem.startsWith(u8, filename, "incremental-snapshot-")) {
            return parseIncrementalFilename(filename);
        } else if (std.mem.startsWith(u8, filename, "snapshot-")) {
            return parseFullFilename(filename);
        }
        return null;
    }

    fn parseFullFilename(filename: []const u8) ?SnapshotInfo {
        // snapshot-<slot>-<hash>.tar.zst
        const prefix_len = "snapshot-".len;
        const suffix = ".tar.zst";

        if (!std.mem.endsWith(u8, filename, suffix)) return null;

        const body = filename[prefix_len .. filename.len - suffix.len];
        var parts = std.mem.splitScalar(u8, body, '-');

        const slot_str = parts.next() orelse return null;
        const hash_str = parts.next() orelse return null;

        const slot = std.fmt.parseInt(u64, slot_str, 10) catch return null;
        const hash = parseHash(hash_str) orelse return null;

        // Store hash string for path reconstruction
        var hash_str_buf: [64]u8 = undefined;
        const hash_len: u8 = @intCast(@min(hash_str.len, 64));
        @memcpy(hash_str_buf[0..hash_len], hash_str[0..hash_len]);

        return SnapshotInfo{
            .slot = slot,
            .hash = hash,
            .base_slot = null,
            .lamports = 0,
            .capitalization = 0,
            .accounts_count = 0,
            .size_bytes = 0,
            .is_incremental = false,
            .download_url = null,
            .filename = null,
            .hash_str = hash_str_buf,
            .hash_str_len = hash_len,
        };
    }

    fn parseIncrementalFilename(filename: []const u8) ?SnapshotInfo {
        // incremental-snapshot-<base>-<slot>-<hash>.tar.zst
        const prefix_len = "incremental-snapshot-".len;
        const suffix = ".tar.zst";

        if (!std.mem.endsWith(u8, filename, suffix)) return null;

        const body = filename[prefix_len .. filename.len - suffix.len];
        var parts = std.mem.splitScalar(u8, body, '-');

        const base_slot_str = parts.next() orelse return null;
        const slot_str = parts.next() orelse return null;
        const hash_str = parts.next() orelse return null;

        const base_slot = std.fmt.parseInt(u64, base_slot_str, 10) catch return null;
        const slot = std.fmt.parseInt(u64, slot_str, 10) catch return null;
        const hash = parseHash(hash_str) orelse return null;

        // Store hash string for path reconstruction
        var hash_str_buf: [64]u8 = undefined;
        const hash_len: u8 = @intCast(@min(hash_str.len, 64));
        @memcpy(hash_str_buf[0..hash_len], hash_str[0..hash_len]);

        return SnapshotInfo{
            .slot = slot,
            .hash = hash,
            .base_slot = base_slot,
            .lamports = 0,
            .capitalization = 0,
            .accounts_count = 0,
            .size_bytes = 0,
            .is_incremental = true,
            .download_url = null,
            .filename = null,
            .hash_str = hash_str_buf,
            .hash_str_len = hash_len,
        };
    }

    fn parseHash(hash_str: []const u8) ?[32]u8 {
        // Base58 decode - simplified (would need full base58 decoder)
        if (hash_str.len < 32 or hash_str.len > 44) return null;
        var result: [32]u8 = undefined;
        @memset(&result, 0);
        // Copy what we can for now (proper base58 decode needed)
        const copy_len = @min(hash_str.len, 32);
        @memcpy(result[0..copy_len], hash_str[0..copy_len]);
        return result;
    }
};

/// Snapshot save result
pub const SaveResult = struct {
    slot: u64,
    output_dir: []const u8,
    accounts_written: u64,
    lamports_total: u64,
    accounts_hash_hex: [64]u8,

    pub fn deinit(self: *SaveResult, allocator: Allocator) void {
        allocator.free(self.output_dir);
    }
};

/// Snapshot download progress
pub const DownloadProgress = struct {
    total_bytes: u64,
    downloaded_bytes: u64,
    elapsed_ns: u64,

    pub fn percentComplete(self: DownloadProgress) f64 {
        if (self.total_bytes == 0) return 0;
        return @as(f64, @floatFromInt(self.downloaded_bytes)) / @as(f64, @floatFromInt(self.total_bytes)) * 100.0;
    }

    pub fn bytesPerSecond(self: DownloadProgress) f64 {
        if (self.elapsed_ns == 0) return 0;
        const elapsed_sec = @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.downloaded_bytes)) / elapsed_sec;
    }

    pub fn etaSeconds(self: DownloadProgress) f64 {
        const bps = self.bytesPerSecond();
        if (bps == 0) return 0;
        const remaining = self.total_bytes - self.downloaded_bytes;
        return @as(f64, @floatFromInt(remaining)) / bps;
    }
};

/// Known validators for testnet (serve snapshots)
pub const TESTNET_KNOWN_VALIDATORS = [_][]const u8{
    "5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on", // Solana Foundation
    "dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs", // Solana Foundation
    "Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN", // Solana Foundation
    "eoKpUABi59aT4rR9HGS3LcMecfut9x7zJyodWWP43YQ", // Solana Foundation
    "9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv", // Solana Foundation
};

/// Known validators for devnet (serve snapshots)
pub const DEVNET_KNOWN_VALIDATORS = [_][]const u8{
    "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",
    "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY",
};

/// Known validators for mainnet (serve snapshots)
pub const MAINNET_KNOWN_VALIDATORS = [_][]const u8{
    "7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2", // Solana Foundation
    "GdnSyH3YtwcxFvQrVVJMm1JhTS4QVX7MFsX56uJLUfiZ", // Solana Foundation
    "DE1bawNcRJB9rVm3buyMVfr8mBEoyyu73NBovf2oXJsJ", // Solana Foundation
    "CakcnaRDHka2gXyfbEd2d3xsvkJkqsLw2akB3zsN1D2S", // Solana Foundation
};

/// Snapshot manager state
pub const SnapshotManager = struct {
    allocator: Allocator,
    snapshots_dir: []const u8,
    rpc_endpoints: std.ArrayList([]const u8),
    known_validators: std.ArrayList([]const u8),
    current_download: ?DownloadProgress,

    const Self = @This();

    pub fn init(allocator: Allocator, snapshots_dir: []const u8) Self {
        return Self{
            .allocator = allocator,
            .snapshots_dir = snapshots_dir,
            .rpc_endpoints = std.ArrayList([]const u8).init(allocator),
            .known_validators = std.ArrayList([]const u8).init(allocator),
            .current_download = null,
        };
    }

    pub fn cleanupTempSnapshots(self: *Self) void {
        var keep = false;
        if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_KEEP")) |value| {
            defer self.allocator.free(value);
            keep = std.mem.eql(u8, value, "1");
        } else |_| {}
        if (keep) return;

        const dir = if (self.snapshots_dir.len > 0 and self.snapshots_dir[0] == '/')
            std.fs.openDirAbsolute(self.snapshots_dir, .{ .iterate = true })
        else
            std.fs.cwd().openDir(self.snapshots_dir, .{ .iterate = true });

        const opened = dir catch return;
        var d = opened;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, "local-snapshot-") or
                std.mem.startsWith(u8, entry.name, "extracted-"))
            {
                d.deleteTree(entry.name) catch {};
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.rpc_endpoints.deinit();
        self.known_validators.deinit();
    }

    /// Add an RPC endpoint to try for downloads
    pub fn addRpcEndpoint(self: *Self, endpoint: []const u8) !void {
        try self.rpc_endpoints.append(endpoint);
    }

    /// Add a known validator pubkey for snapshot download priority
    pub fn addKnownValidator(self: *Self, pubkey: []const u8) !void {
        try self.known_validators.append(pubkey);
    }

    /// Add default known validators for a cluster
    pub fn addDefaultKnownValidators(self: *Self, cluster: anytype) !void {
        const validators = switch (cluster) {
            .mainnet_beta => &MAINNET_KNOWN_VALIDATORS,
            .testnet => &TESTNET_KNOWN_VALIDATORS,
            .devnet => &DEVNET_KNOWN_VALIDATORS,
            else => return, // No defaults for devnet/localnet
        };

        for (validators) |v| {
            try self.known_validators.append(v);
        }
    }

    /// Find the best available snapshot from RPC endpoints
    pub fn findBestSnapshot(self: *Self) !?SnapshotInfo {
        std.debug.print("[Snapshot] findBestSnapshot called, {d} endpoints\n", .{self.rpc_endpoints.items.len});

        if (try self.envSnapshotOverride()) |info| {
            return info;
        }

        for (self.rpc_endpoints.items) |endpoint| {
            std.debug.print("[Snapshot] Querying: {s}\n", .{endpoint});

            if (try self.querySnapshotFromRpc(endpoint)) |info| {
                std.debug.print("[Snapshot] Got info for slot {d}\n", .{info.slot});
                return info;
            }
        }
        std.debug.print("[Snapshot] No snapshot found from any endpoint\n", .{});
        return null;
    }

    fn envSnapshotOverride(self: *Self) !?SnapshotInfo {
        const url = std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_URL") catch return null;
        defer self.allocator.free(url);

        var slot: u64 = 0;
        if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_SLOT")) |value| {
            defer self.allocator.free(value);
            slot = std.fmt.parseInt(u64, value, 10) catch 0;
        } else |_| {}

        if (slot == 0) {
            if (std.mem.lastIndexOf(u8, url, "/")) |idx| {
                const name = url[idx + 1 ..];
                if (SnapshotInfo.fromFilename(name)) |parsed| {
                    slot = parsed.slot;
                }
            }
        }

        if (slot == 0) {
            std.log.warn("[Snapshot] VEXOR_SNAPSHOT_URL set but slot missing; set VEXOR_SNAPSHOT_SLOT", .{});
            return null;
        }

        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);

        var size_bytes: u64 = 0;
        var max_bytes: u64 = 0;
        if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_MAX_BYTES")) |value| {
            defer self.allocator.free(value);
            max_bytes = std.fmt.parseInt(u64, value, 10) catch 0;
        } else |_| {}

        if (std.Uri.parse(url_copy)) |uri| {
            var client = http.Client{ .allocator = self.allocator };
            defer client.deinit();
            const server_header_buf = try self.allocator.alloc(u8, 4096);
            defer self.allocator.free(server_header_buf);
            if (client.open(.HEAD, uri, .{ .server_header_buffer = server_header_buf })) |req| {
                var request = req;
                defer request.deinit();
                request.send() catch {};
                request.finish() catch {};
                request.wait() catch {};
                size_bytes = request.response.content_length orelse 0;
            } else |_| {}
        } else |_| {}

        if (max_bytes > 0 and size_bytes > max_bytes) {
            std.log.warn("[Snapshot] Env snapshot too large ({d} bytes) > max {d}", .{ size_bytes, max_bytes });
            self.allocator.free(url_copy);
            return null;
        }

        std.log.info("[Snapshot] Using env snapshot url (slot {d})", .{slot});
        return SnapshotInfo{
            .slot = slot,
            .hash = std.mem.zeroes([32]u8),
            .base_slot = null,
            .lamports = 0,
            .capitalization = 0,
            .accounts_count = 0,
            .size_bytes = size_bytes,
            .is_incremental = false,
            .download_url = url_copy,
            .filename = null,
            .hash_str = undefined,
            .hash_str_len = 0,
        };
    }

    /// Query an RPC endpoint for available snapshots
    /// Uses getHighestSnapshotSlot RPC method then finds snapshot from known providers
    fn querySnapshotFromRpc(self: *Self, endpoint: []const u8) !?SnapshotInfo {
        std.debug.print("[Snapshot] querySnapshotFromRpc: {s}\n", .{endpoint});

        // Parse the endpoint to extract cluster info
        const uri = std.Uri.parse(endpoint) catch {
            std.debug.print("[Snapshot] Failed to parse URI\n", .{});
            return null;
        };

        // Determine cluster from endpoint
        const is_testnet = std.mem.indexOf(u8, endpoint, "testnet") != null;
        const is_devnet = std.mem.indexOf(u8, endpoint, "devnet") != null;
        const is_mainnet = std.mem.indexOf(u8, endpoint, "mainnet") != null;

        // Get highest snapshot slot via RPC
        std.debug.print("[Snapshot] Opening HTTP client to {s}\n", .{endpoint});

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const request_body =
            \\{"jsonrpc":"2.0","id":1,"method":"getHighestSnapshotSlot"}
        ;

        const server_header_buf = try self.allocator.alloc(u8, 16 * 1024);
        defer self.allocator.free(server_header_buf);

        std.debug.print("[Snapshot] Connecting...\n", .{});

        var request = client.open(.POST, uri, .{
            .server_header_buffer = server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch |err| {
            std.debug.print("[Snapshot] Connect failed: {}\n", .{err});
            return null;
        };
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = request_body.len };

        std.debug.print("[Snapshot] Sending request...\n", .{});

        request.send() catch |err| {
            std.debug.print("[Snapshot] Send failed: {}\n", .{err});
            return null;
        };

        request.writer().writeAll(request_body) catch return null;
        request.finish() catch return null;

        std.debug.print("[Snapshot] Waiting for response...\n", .{});

        request.wait() catch |err| {
            std.debug.print("[Snapshot] Wait failed: {}\n", .{err});
            return null;
        };

        if (request.response.status != .ok) {
            std.debug.print("[Snapshot] RPC returned status {}\n", .{request.response.status});
            return null;
        }

        std.debug.print("[Snapshot] Got 200 OK, reading response...\n", .{});

        var response_buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(response_buf);

        const response_len = request.reader().readAll(response_buf) catch return null;
        const response = response_buf[0..response_len];

        std.debug.print("[Snapshot] Response: {s}\n", .{response});

        const slot = self.parseSnapshotSlot(response) orelse {
            std.log.warn("[Snapshot] Failed to parse snapshot slot from response", .{});
            return null;
        };

        std.log.info("[Snapshot] Highest snapshot slot: {d}", .{slot});

        // Try to find snapshot from known snapshot archive providers
        // These are community-provided snapshot archives
        const snapshot_providers = if (is_testnet)
            &[_][]const u8{
                "https://api.testnet.solana.com",
                "https://testnet.solana.com",
            }
        else if (is_devnet)
            &[_][]const u8{
                "https://api.devnet.solana.com",
            }
        else if (is_mainnet)
            &[_][]const u8{
                "https://api.mainnet-beta.solana.com",
            }
        else
            &[_][]const u8{endpoint};

        // Try to discover snapshot from cluster nodes via getClusterNodes
        if (try self.discoverSnapshotFromCluster(&client, endpoint, slot)) |info| {
            return info;
        }

        // Fallback: construct a placeholder that will use local catchup via shred repair
        _ = snapshot_providers;
        std.log.info("[Snapshot] No snapshot found from cluster nodes - will use FAST CATCHUP mode", .{});
        std.log.info("[Snapshot] Fast catchup: validator will request shreds from gossip peers", .{});
        std.log.info("[Snapshot] This may take longer than snapshot download but doesn't require snapshot server", .{});

        return SnapshotInfo{
            .slot = slot,
            .hash = std.mem.zeroes([32]u8),
            .base_slot = null,
            .lamports = 0,
            .capitalization = 0,
            .accounts_count = 0,
            .size_bytes = 0,
            .is_incremental = false,
            .download_url = null, // No direct download, will use shred repair catchup
            .filename = null,
            .hash_str = undefined,
            .hash_str_len = 0,
        };
    }

    /// Discover snapshot from cluster nodes using getClusterNodes RPC
    fn discoverSnapshotFromCluster(self: *Self, client: *http.Client, endpoint: []const u8, target_slot: u64) !?SnapshotInfo {
        std.debug.print("[Snapshot] Discovering from cluster nodes...\n", .{});

        const uri = std.Uri.parse(endpoint) catch return null;

        const request_body =
            \\{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}
        ;

        const server_header_buf = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(server_header_buf);

        var request = client.open(.POST, uri, .{
            .server_header_buffer = server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return null;
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = request_body.len };
        request.send() catch return null;
        request.writer().writeAll(request_body) catch return null;
        request.finish() catch return null;
        request.wait() catch return null;

        if (request.response.status != .ok) {
            std.debug.print("[Snapshot] getClusterNodes failed: {}\n", .{request.response.status});
            return null;
        }

        // Read cluster nodes response
        var response_buf = try self.allocator.alloc(u8, 256 * 1024);
        defer self.allocator.free(response_buf);

        const response_len = request.reader().readAll(response_buf) catch return null;
        const response = response_buf[0..response_len];

        // Parse RPC addresses from cluster nodes
        // Look for "rpc": "ip:port" patterns
        var nodes_found: usize = 0;
        var nodes_tried: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOf(u8, response[pos..], "\"rpc\":\"")) |idx| {
            nodes_found += 1;
            const start = pos + idx + 7; // Skip past "rpc":"
            const end = std.mem.indexOf(u8, response[start..], "\"") orelse break;
            const rpc_addr = response[start .. start + end];

            if (rpc_addr.len > 0 and !std.mem.eql(u8, rpc_addr, "null")) {
                nodes_tried += 1;
                // Try to get snapshot from this node (limit to 5 tries)
                if (nodes_tried > 5) {
                    std.debug.print("[Snapshot] Tried 5 nodes, stopping search\n", .{});
                    break;
                }

                const node_url = try std.fmt.allocPrint(self.allocator, "http://{s}", .{rpc_addr});
                defer self.allocator.free(node_url);

                std.debug.print("[Snapshot] Trying node: {s}\n", .{rpc_addr});

                if (try self.tryNodeSnapshot(client, node_url, target_slot)) |info| {
                    std.log.info("[Snapshot] Found snapshot from cluster node: {s}", .{rpc_addr});
                    return info;
                }
            }

            pos = start + end;
        }
        std.debug.print("[Snapshot] Found {d} nodes, tried {d}\n", .{ nodes_found, nodes_tried });

        return null;
    }

    /// Try to get snapshot info from a specific node
    /// Solana validators serve snapshots at /snapshot.tar.bz2 on their RPC port
    fn tryNodeSnapshot(self: *Self, client: *http.Client, node_url: []const u8, target_slot: u64) !?SnapshotInfo {
        // Standard Solana snapshot endpoint is /snapshot.tar.bz2 (not .tar.zst)
        // Validators that have --enable-rpc-exit or serve full RPC serve snapshots
        const download_url = try std.fmt.allocPrint(self.allocator, "{s}/snapshot.tar.bz2", .{node_url});
        errdefer self.allocator.free(download_url);

        // Verify snapshot exists with a HEAD request
        const uri = std.Uri.parse(download_url) catch {
            self.allocator.free(download_url);
            return null;
        };

        const server_header_buf = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(server_header_buf);

        var request = client.open(.HEAD, uri, .{
            .server_header_buffer = server_header_buf,
        }) catch {
            self.allocator.free(download_url);
            return null;
        };
        defer request.deinit();

        request.send() catch {
            self.allocator.free(download_url);
            return null;
        };
        request.finish() catch {
            self.allocator.free(download_url);
            return null;
        };
        request.wait() catch {
            self.allocator.free(download_url);
            return null;
        };

        if (request.response.status != .ok) {
            self.allocator.free(download_url);
            return null;
        }

        // Get content length for progress tracking
        const size_bytes = request.response.content_length orelse 0;

        // Optional size cap to avoid huge downloads (bytes)
        var max_bytes: u64 = 0;
        if (std.process.getEnvVarOwned(self.allocator, "VEXOR_SNAPSHOT_MAX_BYTES")) |value| {
            defer self.allocator.free(value);
            max_bytes = std.fmt.parseInt(u64, value, 10) catch 0;
        } else |_| {}
        if (max_bytes > 0 and size_bytes > max_bytes) {
            std.log.warn("[Snapshot] Skipping {s} ({d} bytes) > max {d}", .{ download_url, size_bytes, max_bytes });
            self.allocator.free(download_url);
            return null;
        }

        std.log.info("[Snapshot] Found snapshot at {s} ({d} bytes)", .{ download_url, size_bytes });

        return SnapshotInfo{
            .slot = target_slot,
            .hash = std.mem.zeroes([32]u8),
            .base_slot = null,
            .lamports = 0,
            .capitalization = 0,
            .accounts_count = 0,
            .size_bytes = size_bytes,
            .is_incremental = false,
            .download_url = download_url,
            .filename = null,
            .hash_str = undefined,
            .hash_str_len = 0,
        };
    }

    /// Parse snapshot slot from RPC response
    fn parseSnapshotSlot(self: *Self, response: []const u8) ?u64 {
        _ = self;
        // Look for "full": in the response
        const full_key = "\"full\":";
        const idx = std.mem.indexOf(u8, response, full_key) orelse return null;
        const start = idx + full_key.len;

        var end = start;
        while (end < response.len and (response[end] >= '0' and response[end] <= '9')) : (end += 1) {}

        if (end == start) return null;

        return std.fmt.parseInt(u64, response[start..end], 10) catch null;
    }

    /// Download a snapshot
    pub fn download(self: *Self, info: *const SnapshotInfo, progress_callback: ?*const fn (DownloadProgress) void) !void {
        const url = info.download_url orelse return error.NoDownloadUrl;

        // Create output file
        const filename = try self.generateFilename(info);
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ self.snapshots_dir, filename });
        defer self.allocator.free(path);

        // Open output file
        var file = try fs.cwd().createFile(path, .{});
        defer file.close();

        // Download with progress tracking
        try self.httpDownload(url, &file, progress_callback);
    }

    fn generateFilename(self: *Self, info: *const SnapshotInfo) ![]u8 {
        if (info.is_incremental) {
            return try std.fmt.allocPrint(self.allocator, "incremental-snapshot-{d}-{d}-{s}.tar.zst", .{
                info.base_slot.?,
                info.slot,
                "hash", // Would be actual base58 hash
            });
        } else {
            return try std.fmt.allocPrint(self.allocator, "snapshot-{d}-{s}.tar.zst", .{
                info.slot,
                "hash", // Would be actual base58 hash
            });
        }
    }

    fn httpDownload(self: *Self, url: []const u8, file: *fs.File, progress_callback: ?*const fn (DownloadProgress) void) !void {
        // Parse URL
        const uri = try std.Uri.parse(url);

        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Allocate server header buffer
        const server_header_buf = try self.allocator.alloc(u8, 16 * 1024);
        defer self.allocator.free(server_header_buf);

        var request = try client.open(.GET, uri, .{
            .server_header_buffer = server_header_buf,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        if (request.response.status != .ok) {
            std.log.err("[Snapshot] Download failed with status: {}", .{request.response.status});
            return error.DownloadFailed;
        }

        // Get content length if available
        const content_length = request.response.content_length orelse 0;

        // Initialize progress
        const start_time = std.time.nanoTimestamp();
        self.current_download = DownloadProgress{
            .total_bytes = content_length,
            .downloaded_bytes = 0,
            .elapsed_ns = 0,
        };

        // Read in chunks
        const chunk_size: usize = 256 * 1024; // 256KB chunks
        var buf = try self.allocator.alloc(u8, chunk_size);
        defer self.allocator.free(buf);

        var total_downloaded: u64 = 0;
        var last_progress_update: u64 = 0;

        while (true) {
            const bytes_read = request.reader().read(buf) catch |err| {
                std.log.err("[Snapshot] Read error: {}", .{err});
                return err;
            };

            if (bytes_read == 0) break;

            // Write to file
            try file.writeAll(buf[0..bytes_read]);

            total_downloaded += bytes_read;

            // Update progress every 1MB
            if (total_downloaded - last_progress_update >= 1_000_000) {
                last_progress_update = total_downloaded;
                const now = std.time.nanoTimestamp();

                self.current_download = DownloadProgress{
                    .total_bytes = content_length,
                    .downloaded_bytes = total_downloaded,
                    .elapsed_ns = @intCast(now - start_time),
                };

                if (progress_callback) |cb| {
                    cb(self.current_download.?);
                }
            }
        }

        std.log.info("[Snapshot] Downloaded {d} bytes", .{total_downloaded});
        self.current_download = null;
    }

    /// Extract a downloaded snapshot
    pub fn extract(self: *Self, snapshot_path: []const u8, output_dir: []const u8) !void {
        _ = self;

        // Create output directory
        try fs.cwd().makePath(output_dir);

        // Use system tar command for extraction (more reliable than manual parsing)
        // tar -I zstd -xf <snapshot.tar.zst> -C <output_dir>
        var child = std.process.Child.init(
            &.{ "tar", "-I", "zstd", "-xf", snapshot_path, "-C", output_dir },
            std.heap.page_allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| {
            std.log.err("[Snapshot] Failed to spawn tar process: {}", .{err});
            return error.ExtractionFailed;
        };
        const term = child.wait() catch |err| {
            std.log.err("[Snapshot] Failed waiting for tar process: {}", .{err});
            return error.ExtractionFailed;
        };
        if (term.Exited != 0) {
            std.log.err("[Snapshot] tar extraction failed with exit code {}", .{term.Exited});
            return error.ExtractionFailed;
        }

        std.log.info("[Snapshot] Extracted snapshot to {s}", .{output_dir});

        // Fix permissions - snapshot archives often have restrictive perms
        // chmod -R u+r <output_dir>
        const chmod_result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "chmod", "-R", "u+r", output_dir },
        }) catch |err| {
            std.log.warn("[Snapshot] Failed to fix permissions: {}", .{err});
            return; // Don't fail, just warn
        };

        if (chmod_result.term.Exited != 0) {
            std.log.warn("[Snapshot] chmod failed: {s}", .{chmod_result.stderr});
        }

        std.log.info("[Snapshot] Successfully prepared snapshot in {s}", .{output_dir});
    }

    fn extractTar(self: *Self, reader: anytype, output_dir: []const u8) !void {
        _ = self;
        _ = output_dir;

        // TAR header is 512 bytes
        var header_buf: [512]u8 = undefined;

        while (true) {
            // Read header
            const bytes_read = try reader.readAll(&header_buf);
            if (bytes_read < 512) break;

            // Check for empty header (end of archive)
            var all_zero = true;
            for (header_buf) |b| {
                if (b != 0) {
                    all_zero = false;
                    break;
                }
            }
            if (all_zero) break;

            // Parse TAR header
            const tar_header = parseTarHeader(&header_buf) orelse break;
            _ = tar_header;

            // Would extract file based on header type
            // - Regular file: read content to file
            // - Directory: create directory
            // - Symlink: create symlink
        }
    }

    /// Load snapshot into accounts database
    pub fn loadSnapshot(self: *Self, snapshot_dir: []const u8, accounts_db: anytype) !LoadResult {
        std.debug.print("[DEBUG] loadSnapshot: entering function, dir={s}\n", .{snapshot_dir});

        // Snapshot directory structure:
        // snapshot_dir/
        //   accounts/
        //     <slot>.0  (appendvec files)
        //     <slot>.1
        //     ...
        //   snapshots/
        //     <slot>/
        //       status_cache
        //       <slot>  (bank metadata)
        //   version

        // Read version file
        const version_path = try std.fs.path.join(self.allocator, &.{ snapshot_dir, "version" });
        defer self.allocator.free(version_path);
        std.debug.print("[DEBUG] loadSnapshot: reading version from {s}\n", .{version_path});

        var version_file = fs.cwd().openFile(version_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("[DEBUG] loadSnapshot: version file not found!\n", .{});
                return error.InvalidSnapshot;
            },
            else => return err,
        };
        defer version_file.close();

        var version_buf: [32]u8 = undefined;
        const version_len = try version_file.readAll(&version_buf);
        const version = std.mem.trim(u8, version_buf[0..version_len], " \n\r\t");
        std.debug.print("[DEBUG] loadSnapshot: version={s}\n", .{version});

        // Validate version
        if (!std.mem.eql(u8, version, "1.2.0") and
            !std.mem.eql(u8, version, "1.2.1") and
            !std.mem.eql(u8, version, "1.3.0") and
            !std.mem.eql(u8, version, "1.3.1"))
        {
            std.debug.print("[DEBUG] loadSnapshot: unsupported version!\n", .{});
            return error.UnsupportedSnapshotVersion;
        }

        // Load accounts from append vecs
        const accounts_path = try std.fs.path.join(self.allocator, &.{ snapshot_dir, "accounts" });
        defer self.allocator.free(accounts_path);
        std.debug.print("[DEBUG] loadSnapshot: accounts_path={s}\n", .{accounts_path});

        var accounts_loaded: u64 = 0;
        var lamports_total: u64 = 0;

        var accounts_dir = fs.cwd().openDir(accounts_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("[DEBUG] loadSnapshot: accounts dir not found!\n", .{});
                return error.InvalidSnapshot;
            },
            else => return err,
        };
        defer accounts_dir.close();
        std.debug.print("[DEBUG] loadSnapshot: accounts dir opened, starting iteration\n", .{});

        // Enable bulk loading mode for faster snapshot ingestion
        if (@typeInfo(@TypeOf(accounts_db)) != .Null) {
            if (@hasDecl(@TypeOf(accounts_db.*), "enableBulkLoading")) {
                accounts_db.enableBulkLoading();
            }
            if (@hasDecl(@TypeOf(accounts_db.*), "prepareVexStoreBulkLoad")) {
                accounts_db.prepareVexStoreBulkLoad(1_000_000) catch {};
            }
        }

        var iter = accounts_dir.iterate();
        var files_processed: u64 = 0;
        var max_slot_seen: u64 = 0;
        var last_log_time = std.time.milliTimestamp();

        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // First file - log it
            if (files_processed == 0) {
                std.debug.print("[DEBUG] loadSnapshot: first file={s}\n", .{entry.name});
            }

            const slot = parseSlotFromFilename(entry.name) orelse 0;
            if (slot > max_slot_seen) max_slot_seen = slot;

            // Load append vec file
            const result = self.loadAppendVec(accounts_dir, entry.name, slot, accounts_db) catch |err| {
                std.debug.print("[DEBUG] loadSnapshot: failed to load {s}: {}\n", .{ entry.name, err });
                continue;
            };

            accounts_loaded = accounts_loaded +| result.accounts_count;
            lamports_total = lamports_total +| result.lamports_total;
            files_processed += 1;

            // Log progress every 5 seconds or every 1000 files
            const now = std.time.milliTimestamp();
            if (now - last_log_time > 5000 or files_processed % 1000 == 0) {
                std.debug.print("[DEBUG] loadSnapshot: Progress: {d} files, {d} accounts, {d} lamports\n", .{
                    files_processed, accounts_loaded, lamports_total,
                });
                last_log_time = now;
            }
        }

        // Disable bulk loading mode and flush VexStore
        if (@typeInfo(@TypeOf(accounts_db)) != .Null) {
            if (@hasDecl(@TypeOf(accounts_db.*), "disableBulkLoading")) {
                accounts_db.disableBulkLoading();
            }
            if (@hasDecl(@TypeOf(accounts_db.*), "flushVexStore")) {
                accounts_db.flushVexStore() catch {};
            }
        }

        std.log.info("[Snapshot] Complete: {d} files, {d} accounts, {d} lamports", .{
            files_processed, accounts_loaded, lamports_total,
        });

        // NOTE: Disabled here due to a crash in AutoHashMap iteration under load.
        // We can re-enable once storage map concurrency is hardened.

        return LoadResult{
            .slot = max_slot_seen,
            .accounts_loaded = accounts_loaded,
            .lamports_total = lamports_total,
        };
    }

    /// Save a local snapshot from AccountsDb (Solana-format appendvecs).
    pub fn saveSnapshot(self: *Self, accounts_db: anytype, slot: u64) !SaveResult {
        std.log.info("[Snapshot] saveSnapshot start slot={d}", .{slot});
        const output_dir = try std.fmt.allocPrint(self.allocator, "{s}/local-snapshot-{d}", .{ self.snapshots_dir, slot });
        try fs.cwd().makePath(output_dir);

        var accounts_dir_buf: [512]u8 = undefined;
        const accounts_dir = try std.fmt.bufPrint(&accounts_dir_buf, "{s}/accounts", .{output_dir});
        try fs.cwd().makePath(accounts_dir);

        var slot_str_buf: [64]u8 = undefined;
        const slot_str = try std.fmt.bufPrint(&slot_str_buf, "{d}", .{slot});
        var snapshots_dir_buf: [512]u8 = undefined;
        const snapshots_dir = try std.fmt.bufPrint(&snapshots_dir_buf, "{s}/snapshots/{s}", .{ output_dir, slot_str });
        try fs.cwd().makePath(snapshots_dir);

        // Version file for loader compatibility
        var version_path_buf: [512]u8 = undefined;
        const version_path = try std.fmt.bufPrint(&version_path_buf, "{s}/version", .{output_dir});
        {
            const version_file = try fs.cwd().createFile(version_path, .{ .truncate = true });
            defer version_file.close();
            try version_file.writeAll("1.3.1\n");
        }

        // NOTE: Disabled here due to crash in AutoHashMap iteration under load.
        // Re-enable once storage map concurrency is hardened.

        const accounts_hash = try accounts_db.computeHash();

        var accounts_hash_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&accounts_hash_hex, "{s}", .{std.fmt.fmtSliceHexLower(&accounts_hash.data)});

        var hash_path_buf: [512]u8 = undefined;
        const hash_path = try std.fmt.bufPrint(&hash_path_buf, "{s}/accounts_hash", .{snapshots_dir});
        {
            const hash_file = try fs.cwd().createFile(hash_path, .{ .truncate = true });
            defer hash_file.close();
            try hash_file.writeAll(&accounts_hash_hex);
            try hash_file.writeAll("\n");
        }

        var appendvec_path_buf: [512]u8 = undefined;
        const appendvec_path = try std.fmt.bufPrint(&appendvec_path_buf, "{s}/{d}.0", .{ accounts_dir, slot });
        const av_file = try fs.cwd().createFile(appendvec_path, .{ .truncate = true });
        defer av_file.close();

        const stats = try accounts_db.writeSnapshotAppendVec(av_file.writer());

        std.log.info(
            "[Snapshot] saveSnapshot complete slot={d} accounts={d} lamports={d}",
            .{ slot, stats.accounts_written, stats.lamports_total },
        );
        return SaveResult{
            .slot = slot,
            .output_dir = output_dir,
            .accounts_written = stats.accounts_written,
            .lamports_total = stats.lamports_total,
            .accounts_hash_hex = accounts_hash_hex,
        };
    }

    fn writeSnapshotFromAccountsDir(
        accounts_dir_path: []const u8,
        writer: anytype,
    ) !struct { accounts_written: u64, lamports_total: u64 } {
        const header_size: usize = 32;
        const header_magic: [8]u8 = [_]u8{ 'V', 'E', 'X', 'A', 'V', '1', 0, 0 };
        const record_header_len: usize = 32 + 8 + 32 + 1 + 8 + 4;
        const STORED_META_SIZE: usize = 48;
        const ACCOUNT_META_SIZE: usize = 56;
        const write_version: u64 = 1;
        const pad_bytes = [_]u8{0} ** 8;

        var accounts_written: u64 = 0;
        var lamports_total: u64 = 0;

        var nested_buf: [512]u8 = undefined;
        const nested_path = std.fmt.bufPrint(&nested_buf, "{s}/accounts", .{accounts_dir_path}) catch null;
        const selected_path = if (nested_path) |p| blk: {
            if (p.len > 0 and p[0] == '/') {
                if (std.fs.openDirAbsolute(p, .{ .iterate = true })) |nested_dir| {
                    var d = nested_dir;
                    d.close();
                    break :blk p;
                } else |_| {}
            } else {
                if (std.fs.cwd().openDir(p, .{ .iterate = true })) |nested_dir| {
                    var d = nested_dir;
                    d.close();
                    break :blk p;
                } else |_| {}
            }
            break :blk accounts_dir_path;
        } else accounts_dir_path;

        var dir = if (selected_path.len > 0 and selected_path[0] == '/')
            try std.fs.openDirAbsolute(selected_path, .{ .iterate = true })
        else
            try std.fs.cwd().openDir(selected_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".av")) continue;

            var file = try dir.openFile(entry.name, .{});
            defer file.close();

            const stat = try file.stat();
            if (stat.size < header_size) continue;

            var header: [header_size]u8 = undefined;
            _ = try file.preadAll(&header, 0);
            if (!std.mem.eql(u8, header[0..8], &header_magic)) continue;

            const current_len = std.mem.readInt(u64, header[12..][0..8], .little);
            const file_size: usize = @intCast(stat.size);
            const limit: usize = @min(@as(usize, @intCast(current_len)), file_size);
            if (limit <= header_size) continue;

            var offset: usize = header_size;
            while (offset + record_header_len <= limit) {
                var header_buf: [record_header_len]u8 = undefined;
                _ = try file.preadAll(&header_buf, offset);
                var cursor: usize = 0;
                const pubkey = header_buf[cursor..][0..32];
                cursor += 32;
                const lamports = std.mem.readInt(u64, header_buf[cursor..][0..8], .little);
                cursor += 8;
                const owner = header_buf[cursor..][0..32];
                cursor += 32;
                const executable = header_buf[cursor] != 0;
                cursor += 1;
                const rent_epoch = std.mem.readInt(u64, header_buf[cursor..][0..8], .little);
                cursor += 8;
                const data_len = std.mem.readInt(u32, header_buf[cursor..][0..4], .little);
                cursor += 4;

                const total_len = record_header_len + @as(usize, data_len);
                if (offset + total_len > limit) break;

                var buf8: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf8, write_version, .little);
                try writer.writeAll(&buf8);
                std.mem.writeInt(u64, &buf8, data_len, .little);
                try writer.writeAll(&buf8);
                try writer.writeAll(pubkey);

                std.mem.writeInt(u64, &buf8, lamports, .little);
                try writer.writeAll(&buf8);
                std.mem.writeInt(u64, &buf8, rent_epoch, .little);
                try writer.writeAll(&buf8);
                try writer.writeAll(owner);
                try writer.writeByte(@intFromBool(executable));
                try writer.writeAll(pad_bytes[0..7]);

                // Account hash (32 bytes) - required between AccountMeta and data
                // in Agave's AppendVec format. Use zeros for locally-generated snapshots.
                const zero_hash = [_]u8{0} ** 32;
                try writer.writeAll(&zero_hash);

                var remaining: usize = @intCast(data_len);
                var data_offset: u64 = @intCast(offset + record_header_len);
                var chunk: [8192]u8 = undefined;
                while (remaining > 0) {
                    const take = @min(remaining, chunk.len);
                    _ = try file.preadAll(chunk[0..take], data_offset);
                    try writer.writeAll(chunk[0..take]);
                    data_offset += take;
                    remaining -= take;
                }

                const HASH_SIZE: usize = 32;
                const record_len = STORED_META_SIZE + ACCOUNT_META_SIZE + HASH_SIZE + @as(usize, data_len);
                const pad = (8 - (record_len % 8)) & 7;
                if (pad != 0) {
                    try writer.writeAll(pad_bytes[0..pad]);
                }

                accounts_written += 1;
                lamports_total = std.math.add(u64, lamports_total, lamports) catch lamports_total;
                offset += total_len;
            }
        }

        return .{
            .accounts_written = accounts_written,
            .lamports_total = lamports_total,
        };
    }

    /// Load accounts from an AppendVec file (Solana snapshot format)
    ///
    /// AppendVec format per account:
    ///   StoredMeta:   write_version(u64) + data_len(u64) + pubkey(32)
    ///   AccountMeta:  lamports(u64) + rent_epoch(u64) + owner(32) + executable(bool) + padding
    ///   Data:         variable length (data_len bytes)
    ///   Hash:         32 bytes (optional, may not be present)
    ///
    /// OPTIMIZATION: Uses mmap for files > 1MB to avoid large heap allocations
    fn loadAppendVec(self: *Self, dir: fs.Dir, filename: []const u8, slot: u64, accounts_db: anytype) !AppendVecLoadResult {
        // Open append vec file
        var file = try dir.openFile(filename, .{});
        defer file.close();

        // Get file size
        const stat = try file.stat();
        const file_size = stat.size;

        if (file_size == 0) {
            return AppendVecLoadResult{
                .accounts_count = 0,
                .lamports_total = 0,
            };
        }

        // Use mmap for large files (> 1MB) to avoid heap pressure
        const USE_MMAP_THRESHOLD: usize = 1024 * 1024;
        const use_mmap = file_size > USE_MMAP_THRESHOLD;

        var buf: []const u8 = undefined;
        const mmap_ptr: ?[]align(std.mem.page_size) u8 = null;
        var alloc_ptr: ?[]u8 = null;

        // SIGBUS FIX: Don't use mmap - it can cause SIGBUS if file is truncated/sparse
        // Instead, always read into memory. This is slightly slower but much safer.
        // The kernel can handle sparse files via read() but mmap will SIGBUS.
        _ = use_mmap; // Suppress unused warning

        alloc_ptr = self.allocator.alloc(u8, file_size) catch |err| {
            std.log.warn("[Snapshot] Failed to allocate {d} bytes for {s}: {}", .{ file_size, filename, err });
            return AppendVecLoadResult{ .accounts_count = 0, .lamports_total = 0 };
        };

        const bytes_read = file.readAll(alloc_ptr.?) catch |err| {
            std.log.warn("[Snapshot] Failed to read {s}: {}", .{ filename, err });
            self.allocator.free(alloc_ptr.?);
            return AppendVecLoadResult{ .accounts_count = 0, .lamports_total = 0 };
        };

        if (bytes_read != file_size) {
            std.log.warn("[Snapshot] Short read on {s}: expected {d}, got {d}", .{ filename, file_size, bytes_read });
            self.allocator.free(alloc_ptr.?);
            return AppendVecLoadResult{ .accounts_count = 0, .lamports_total = 0 };
        }
        buf = alloc_ptr.?;

        // Ensure cleanup on exit
        defer {
            if (mmap_ptr) |m| {
                std.posix.munmap(m);
            }
            if (alloc_ptr) |a| {
                self.allocator.free(a);
            }
        }

        // Parse accounts from AppendVec
        var offset: usize = 0;
        var accounts_count: u64 = 0;
        var lamports_total: u64 = 0;

        // Agave AppendVec on-disk record layout (verified against Sig's accounts_file.zig):
        // StoredMeta size: 8 (write_version) + 8 (data_len) + 32 (pubkey) = 48 bytes
        // AccountMeta size: 8 (lamports) + 8 (rent_epoch) + 32 (owner) + 1 (executable) + 7 (padding) = 56 bytes
        // Hash: 32 bytes (account hash, stored between AccountMeta and data)
        // Minimum account entry: 48 + 56 + 32 = 136 bytes (with 0 data)
        const STORED_META_SIZE: usize = 48;
        const ACCOUNT_META_SIZE: usize = 56;
        const HASH_SIZE: usize = 32;
        const MIN_ACCOUNT_SIZE: usize = STORED_META_SIZE + ACCOUNT_META_SIZE + HASH_SIZE;

        // Maximum reasonable data_len to prevent malicious input
        const MAX_ACCOUNT_DATA_LEN: u64 = 10 * 1024 * 1024; // 10MB max per account

        while (offset + MIN_ACCOUNT_SIZE <= file_size) {
            // Parse StoredMeta
            const write_version = std.mem.readInt(u64, buf[offset..][0..8], .little);
            const data_len = std.mem.readInt(u64, buf[offset + 8 ..][0..8], .little);

            // Sanity checks
            if (write_version == 0 and data_len == 0) {
                // Empty/end marker
                break;
            }

            // Validate data_len to prevent malicious input
            if (data_len > MAX_ACCOUNT_DATA_LEN) {
                std.log.warn("[Snapshot] DIAG: file={s} offset=0x{x} accounts_ok={d} write_ver={d} data_len={d}", .{
                    filename, offset, accounts_count, write_version, data_len,
                });
                // Hexdump first 16 bytes at failing offset for debugging
                if (offset + 16 <= file_size) {
                    std.log.warn("[Snapshot] DIAG: bytes @0x{x}: {x:0>2}", .{ offset, buf[offset..][0..16].* });
                }
                break;
            }

            // Pubkey at offset 16 - explicitly initialize
            var pubkey: [32]u8 = std.mem.zeroes([32]u8);
            @memcpy(&pubkey, buf[offset + 16 ..][0..32]);

            // Parse AccountMeta (starts at offset + STORED_META_SIZE)
            const meta_offset = offset + STORED_META_SIZE;
            if (meta_offset + ACCOUNT_META_SIZE + HASH_SIZE > file_size) break;

            const lamports = std.mem.readInt(u64, buf[meta_offset..][0..8], .little);
            const rent_epoch = std.mem.readInt(u64, buf[meta_offset + 8 ..][0..8], .little);

            // Owner - explicitly initialize
            var owner: [32]u8 = std.mem.zeroes([32]u8);
            @memcpy(&owner, buf[meta_offset + 16 ..][0..32]);

            const executable = buf[meta_offset + 48] != 0;

            // Hash (32 bytes) sits between AccountMeta and data in Agave's format
            // const hash = buf[meta_offset + ACCOUNT_META_SIZE ..][0..HASH_SIZE];
            // Data starts after AccountMeta + Hash
            const data_offset = meta_offset + ACCOUNT_META_SIZE + HASH_SIZE;
            const data_end = data_offset + @as(usize, @intCast(data_len));

            if (data_end > file_size) {
                // Corrupted or truncated file
                break;
            }

            // Extract account data
            const data = buf[data_offset..data_end];

            // Store account in database if provided
            if (@typeInfo(@TypeOf(accounts_db)) != .Null) {
                // Create account structure
                const core_pubkey = @as(*const @import("../core/root.zig").Pubkey, @ptrCast(&pubkey));
                const core_owner = @as(*const @import("../core/root.zig").Pubkey, @ptrCast(&owner));

                const account = @import("accounts.zig").Account{
                    .lamports = lamports,
                    .owner = core_owner.*,
                    .executable = executable,
                    .rent_epoch = rent_epoch,
                    .data = data,
                };

                // Use the fastest available bulk path for snapshot loading:
                // 1. storeAccountBulkVexStore: bypasses AppendVec entirely, O(1) hash insert
                // 2. storeAccountBulk: skips cache/MemTable, still uses AppendVec
                // 3. storeAccount: full path (last resort)
                const store_err: ?anyerror = blk: {
                    if (@hasDecl(@TypeOf(accounts_db.*), "storeAccountBulkVexStore")) {
                        if (accounts_db.hasVexStore()) {
                            accounts_db.storeAccountBulkVexStore(core_pubkey, &account) catch |err| {
                                break :blk err;
                            };
                            break :blk null;
                        }
                    }
                    if (@hasDecl(@TypeOf(accounts_db.*), "storeAccountBulk")) {
                        accounts_db.storeAccountBulk(core_pubkey, &account, slot) catch |err| {
                            break :blk err;
                        };
                        break :blk null;
                    }
                    if (@hasDecl(@TypeOf(accounts_db.*), "storeAccount")) {
                        accounts_db.storeAccount(core_pubkey, &account, slot) catch |err| {
                            break :blk err;
                        };
                        break :blk null;
                    }
                    break :blk null;
                };

                if (store_err) |err| {
                    if (accounts_count < 5) {
                        std.log.warn("[Snapshot] storeAccount error: {}", .{err});
                    }
                }
            }

            // Update stats with overflow check
            accounts_count += 1;
            lamports_total = std.math.add(u64, lamports_total, lamports) catch blk: {
                std.log.warn("[Snapshot] Lamports overflow, capping at max", .{});
                break :blk std.math.maxInt(u64);
            };

            // Advance past the entire record (StoredMeta + AccountMeta + Hash + data)
            offset = data_end;

            // Ensure 8-byte alignment for next entry
            offset = (offset + 7) & ~@as(usize, 7);
        }

        return AppendVecLoadResult{
            .accounts_count = accounts_count,
            .lamports_total = lamports_total,
        };
    }

    fn parseSlotFromFilename(filename: []const u8) ?u64 {
        const dot = std.mem.indexOfScalar(u8, filename, '.') orelse return null;
        return std.fmt.parseInt(u64, filename[0..dot], 10) catch null;
    }

    /// Verify snapshot hash
    pub fn verifyHash(self: *Self, snapshot_path: []const u8, expected_hash: [32]u8) !bool {
        _ = self;
        _ = snapshot_path;
        _ = expected_hash;
        // Would compute hash of snapshot and compare
        return true;
    }

    /// Clean up old snapshots
    pub fn cleanupOldSnapshots(self: *Self, keep_count: usize) !void {
        var dir = try fs.cwd().openDir(self.snapshots_dir, .{ .iterate = true });
        defer dir.close();

        var snapshots = std.ArrayList(SnapshotFile).init(self.allocator);
        defer snapshots.deinit();

        // Collect all snapshots
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (SnapshotInfo.fromFilename(entry.name)) |info| {
                const stat = try dir.statFile(entry.name);
                try snapshots.append(.{
                    .name = try self.allocator.dupe(u8, entry.name),
                    .slot = info.slot,
                    .mtime = stat.mtime,
                });
            }
        }

        // Sort by slot (descending)
        std.mem.sort(SnapshotFile, snapshots.items, {}, struct {
            fn lessThan(_: void, a: SnapshotFile, b: SnapshotFile) bool {
                return a.slot > b.slot;
            }
        }.lessThan);

        // Delete old ones
        var i: usize = keep_count;
        while (i < snapshots.items.len) : (i += 1) {
            dir.deleteFile(snapshots.items[i].name) catch {};
            self.allocator.free(snapshots.items[i].name);
        }

        // Free kept names
        for (snapshots.items[0..@min(keep_count, snapshots.items.len)]) |s| {
            self.allocator.free(s.name);
        }
    }
};

const SnapshotFile = struct {
    name: []const u8,
    slot: u64,
    mtime: i128,
};

const AppendVecLoadResult = struct {
    accounts_count: u64,
    lamports_total: u64,
};

pub const LoadResult = struct {
    slot: u64,
    accounts_loaded: u64,
    lamports_total: u64,
};

/// TAR header structure
const TarHeader = struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: u64,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
};

fn parseTarHeader(buf: *const [512]u8) ?TarHeader {
    // Check magic
    const magic = buf[257..263];
    if (!std.mem.eql(u8, magic, "ustar\x00") and
        !std.mem.eql(u8, magic, "ustar "))
    {
        return null;
    }

    // Parse size (octal)
    const size_str = buf[124..136];
    const size = parseOctal(size_str);

    return TarHeader{
        .name = buf[0..100].*,
        .mode = buf[100..108].*,
        .uid = buf[108..116].*,
        .gid = buf[116..124].*,
        .size = size,
        .mtime = buf[136..148].*,
        .checksum = buf[148..156].*,
        .typeflag = buf[156],
        .linkname = buf[157..257].*,
        .magic = buf[257..263].*,
        .version = buf[263..265].*,
        .uname = buf[265..297].*,
        .gname = buf[297..329].*,
        .devmajor = buf[329..337].*,
        .devminor = buf[337..345].*,
        .prefix = buf[345..500].*,
    };
}

fn parseOctal(str: []const u8) u64 {
    var result: u64 = 0;
    for (str) |c| {
        if (c >= '0' and c <= '7') {
            result = result * 8 + (c - '0');
        }
    }
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "parse snapshot filename" {
    const full = SnapshotInfo.fromFilename("snapshot-123456789-2ZWhY8YEcyG425fp68G43HTUL7HERCvooekkqJvZYoLt.tar.zst");
    try std.testing.expect(full != null);
    try std.testing.expectEqual(@as(u64, 123456789), full.?.slot);
    try std.testing.expect(!full.?.is_incremental);

    const incr = SnapshotInfo.fromFilename("incremental-snapshot-100000000-123456789-2ZWhY8YEcyG425fp68G43HTUL7HERCvooekkqJvZYoLt.tar.zst");
    try std.testing.expect(incr != null);
    try std.testing.expectEqual(@as(u64, 123456789), incr.?.slot);
    try std.testing.expectEqual(@as(u64, 100000000), incr.?.base_slot.?);
    try std.testing.expect(incr.?.is_incremental);
}

test "snapshot save/load roundtrip" {
    const accounts = @import("accounts.zig");
    const core_types = @import("../core/root.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base_path);

    const accounts_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "accounts" });
    defer std.testing.allocator.free(accounts_path);
    try std.fs.cwd().makePath(accounts_path);

    const accounts_path2 = try std.fs.path.join(std.testing.allocator, &.{ base_path, "accounts2" });
    defer std.testing.allocator.free(accounts_path2);
    try std.fs.cwd().makePath(accounts_path2);

    const snapshots_path = try std.fs.path.join(std.testing.allocator, &.{ base_path, "snapshots" });
    defer std.testing.allocator.free(snapshots_path);
    try std.fs.cwd().makePath(snapshots_path);

    var adb = try accounts.AccountsDb.init(std.testing.allocator, accounts_path, null);
    defer adb.deinit();

    const owner = core_types.Pubkey{ .data = [_]u8{9} ** 32 };
    const pubkey1 = core_types.Pubkey{ .data = [_]u8{1} ** 32 };
    const pubkey2 = core_types.Pubkey{ .data = [_]u8{2} ** 32 };

    const account1 = accounts.Account{
        .lamports = 111,
        .owner = owner,
        .executable = false,
        .rent_epoch = 1,
        .data = "one",
    };
    const account2 = accounts.Account{
        .lamports = 222,
        .owner = owner,
        .executable = true,
        .rent_epoch = 2,
        .data = "two-two",
    };

    try adb.storeAccount(&pubkey1, &account1, 5);
    try adb.storeAccount(&pubkey2, &account2, 5);

    var sm = SnapshotManager.init(std.testing.allocator, snapshots_path);
    defer sm.deinit();

    var save = try sm.saveSnapshot(adb, 5);
    defer save.deinit(std.testing.allocator);

    var adb2 = try accounts.AccountsDb.init(std.testing.allocator, accounts_path2, null);
    defer adb2.deinit();

    const load = try sm.loadSnapshot(save.output_dir, adb2);
    try std.testing.expectEqual(save.accounts_written, load.accounts_loaded);

    const hash2 = try adb2.computeHash();
    var hash2_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash2_hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash2.data)});
    try std.testing.expectEqualSlices(u8, &save.accounts_hash_hex, &hash2_hex);
}

test "download progress" {
    const progress = DownloadProgress{
        .total_bytes = 1000000,
        .downloaded_bytes = 500000,
        .elapsed_ns = 1_000_000_000, // 1 second
    };

    try std.testing.expectEqual(@as(f64, 50.0), progress.percentComplete());
    try std.testing.expectEqual(@as(f64, 500000.0), progress.bytesPerSecond());
    try std.testing.expectEqual(@as(f64, 1.0), progress.etaSeconds());
}

test "parse octal" {
    try std.testing.expectEqual(@as(u64, 0), parseOctal("0"));
    try std.testing.expectEqual(@as(u64, 7), parseOctal("7"));
    try std.testing.expectEqual(@as(u64, 8), parseOctal("10"));
    try std.testing.expectEqual(@as(u64, 64), parseOctal("100"));
}
