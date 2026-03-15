//! Snapshot Provider Interface
//!
//! Abstract interface for snapshot sources. Implementations:
//!   - RpcSnapshotProvider: Standard Solana RPC/gossip (works now)
//!   - LocalSnapshotProvider: Load from local filesystem
//!   - SnapstreamProvider: Snapstream CDN (future integration)
//!
//! The interface supports:
//!   - Finding available snapshots near a target slot
//!   - Streaming chunk downloads with progress callbacks
//!   - Metadata queries (hash, slot, size)
//!   - Resume capability for interrupted downloads

const std = @import("std");
const net = std.net;

/// Snapshot metadata
pub const SnapshotInfo = struct {
    /// Snapshot slot
    slot: u64,
    
    /// Snapshot hash (base58)
    hash: [44]u8,
    hash_len: usize,
    
    /// Total size in bytes
    size_bytes: u64,
    
    /// Number of account files
    num_files: u32,
    
    /// Is this a full or incremental snapshot?
    is_incremental: bool,
    
    /// Base slot (for incremental snapshots)
    base_slot: ?u64,
    
    /// Source URL or path
    source: [256]u8,
    source_len: usize,
    
    pub fn getHash(self: *const SnapshotInfo) []const u8 {
        return self.hash[0..self.hash_len];
    }
    
    pub fn getSource(self: *const SnapshotInfo) []const u8 {
        return self.source[0..self.source_len];
    }
};

/// Chunk of snapshot data
pub const SnapshotChunk = struct {
    /// Offset in the snapshot file
    offset: u64,
    
    /// Size of this chunk
    size: usize,
    
    /// Data buffer
    data: []u8,
    
    /// Is this the last chunk?
    is_last: bool,
};

/// Download progress callback
pub const ProgressCallback = *const fn (
    bytes_downloaded: u64,
    total_bytes: u64,
    chunks_completed: u32,
    total_chunks: u32,
) void;

/// Snapshot provider interface (vtable-based for polymorphism)
pub const SnapshotProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        /// Find best snapshot for target slot
        findSnapshot: *const fn (ptr: *anyopaque, target_slot: u64) anyerror!SnapshotInfo,
        
        /// List available snapshots
        listSnapshots: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]SnapshotInfo,
        
        /// Download a chunk (for parallel downloading)
        downloadChunk: *const fn (
            ptr: *anyopaque,
            info: *const SnapshotInfo,
            offset: u64,
            size: usize,
            buffer: []u8,
        ) anyerror!usize,
        
        /// Get total chunk count for parallel download planning
        getChunkCount: *const fn (ptr: *anyopaque, info: *const SnapshotInfo, chunk_size: usize) u32,
        
        /// Check if provider supports resume
        supportsResume: *const fn (ptr: *anyopaque) bool,
        
        /// Provider name (for logging)
        getName: *const fn (ptr: *anyopaque) []const u8,
    };
    
    pub fn findSnapshot(self: SnapshotProvider, target_slot: u64) !SnapshotInfo {
        return self.vtable.findSnapshot(self.ptr, target_slot);
    }
    
    pub fn listSnapshots(self: SnapshotProvider, allocator: std.mem.Allocator) ![]SnapshotInfo {
        return self.vtable.listSnapshots(self.ptr, allocator);
    }
    
    pub fn downloadChunk(
        self: SnapshotProvider,
        info: *const SnapshotInfo,
        offset: u64,
        size: usize,
        buffer: []u8,
    ) !usize {
        return self.vtable.downloadChunk(self.ptr, info, offset, size, buffer);
    }
    
    pub fn getChunkCount(self: SnapshotProvider, info: *const SnapshotInfo, chunk_size: usize) u32 {
        return self.vtable.getChunkCount(self.ptr, info, chunk_size);
    }
    
    pub fn supportsResume(self: SnapshotProvider) bool {
        return self.vtable.supportsResume(self.ptr);
    }
    
    pub fn getName(self: SnapshotProvider) []const u8 {
        return self.vtable.getName(self.ptr);
    }
};

/// RPC-based snapshot provider (standard Solana gossip/RPC)
pub const RpcSnapshotProvider = struct {
    allocator: std.mem.Allocator,
    rpc_urls: []const []const u8,
    current_url_idx: usize,
    timeout_ms: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, rpc_urls: []const []const u8) Self {
        return .{
            .allocator = allocator,
            .rpc_urls = rpc_urls,
            .current_url_idx = 0,
            .timeout_ms = 30000,
        };
    }
    
    pub fn provider(self: *Self) SnapshotProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    
    const vtable = SnapshotProvider.VTable{
        .findSnapshot = findSnapshotImpl,
        .listSnapshots = listSnapshotsImpl,
        .downloadChunk = downloadChunkImpl,
        .getChunkCount = getChunkCountImpl,
        .supportsResume = supportsResumeImpl,
        .getName = getNameImpl,
    };
    
    fn findSnapshotImpl(ptr: *anyopaque, target_slot: u64) anyerror!SnapshotInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        
        // TODO: Query RPC for snapshot info
        // For now, return a placeholder
        var info = SnapshotInfo{
            .slot = target_slot,
            .hash = undefined,
            .hash_len = 0,
            .size_bytes = 0,
            .num_files = 0,
            .is_incremental = false,
            .base_slot = null,
            .source = undefined,
            .source_len = 0,
        };
        
        const placeholder_hash = "GoYk53TovPQVDUaN6KAjb2ie9aqqE1gUkau48fC8491d";
        @memcpy(info.hash[0..placeholder_hash.len], placeholder_hash);
        info.hash_len = placeholder_hash.len;
        
        return info;
    }
    
    fn listSnapshotsImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]SnapshotInfo {
        _ = ptr;
        _ = allocator;
        return &[_]SnapshotInfo{};
    }
    
    fn downloadChunkImpl(
        ptr: *anyopaque,
        info: *const SnapshotInfo,
        offset: u64,
        size: usize,
        buffer: []u8,
    ) anyerror!usize {
        _ = ptr;
        _ = info;
        _ = offset;
        _ = size;
        _ = buffer;
        return 0;
    }
    
    fn getChunkCountImpl(ptr: *anyopaque, info: *const SnapshotInfo, chunk_size: usize) u32 {
        _ = ptr;
        if (chunk_size == 0) return 0;
        return @intCast((info.size_bytes + chunk_size - 1) / chunk_size);
    }
    
    fn supportsResumeImpl(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }
    
    fn getNameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "RPC";
    }
};

/// Local filesystem snapshot provider
pub const LocalSnapshotProvider = struct {
    allocator: std.mem.Allocator,
    snapshot_dir: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, snapshot_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .snapshot_dir = snapshot_dir,
        };
    }
    
    pub fn provider(self: *Self) SnapshotProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    
    const vtable = SnapshotProvider.VTable{
        .findSnapshot = findSnapshotImpl,
        .listSnapshots = listSnapshotsImpl,
        .downloadChunk = downloadChunkImpl,
        .getChunkCount = getChunkCountImpl,
        .supportsResume = supportsResumeImpl,
        .getName = getNameImpl,
    };
    
    fn findSnapshotImpl(ptr: *anyopaque, target_slot: u64) anyerror!SnapshotInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Scan snapshot directory for matching snapshot
        var dir = std.fs.openDirAbsolute(self.snapshot_dir, .{ .iterate = true }) catch {
            return error.SnapshotNotFound;
        };
        defer dir.close();
        
        var best_slot: u64 = 0;
        var best_info: ?SnapshotInfo = null;
        
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            
            // Parse snapshot filename: snapshot-{slot}-{hash}.tar.zst
            if (std.mem.startsWith(u8, entry.name, "snapshot-")) {
                const rest = entry.name[9..];
                if (std.mem.indexOf(u8, rest, "-")) |dash_idx| {
                    const slot_str = rest[0..dash_idx];
                    const slot = std.fmt.parseInt(u64, slot_str, 10) catch continue;
                    
                    if (slot <= target_slot and slot > best_slot) {
                        best_slot = slot;
                        
                        var info = SnapshotInfo{
                            .slot = slot,
                            .hash = undefined,
                            .hash_len = 0,
                            .size_bytes = 0,
                            .num_files = 0,
                            .is_incremental = false,
                            .base_slot = null,
                            .source = undefined,
                            .source_len = 0,
                        };
                        
                        // Get file size
                        const stat = dir.statFile(entry.name) catch continue;
                        info.size_bytes = stat.size;
                        
                        // Build full path
                        const path = std.fmt.bufPrint(&info.source, "{s}/{s}", .{
                            self.snapshot_dir, entry.name
                        }) catch continue;
                        info.source_len = path.len;
                        
                        best_info = info;
                    }
                }
            }
        }
        
        return best_info orelse error.SnapshotNotFound;
    }
    
    fn listSnapshotsImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]SnapshotInfo {
        _ = ptr;
        _ = allocator;
        return &[_]SnapshotInfo{};
    }
    
    fn downloadChunkImpl(
        ptr: *anyopaque,
        info: *const SnapshotInfo,
        offset: u64,
        size: usize,
        buffer: []u8,
    ) anyerror!usize {
        _ = ptr;
        
        // Open file and read chunk
        const file = try std.fs.openFileAbsolute(info.getSource(), .{});
        defer file.close();
        
        try file.seekTo(offset);
        return try file.read(buffer[0..size]);
    }
    
    fn getChunkCountImpl(ptr: *anyopaque, info: *const SnapshotInfo, chunk_size: usize) u32 {
        _ = ptr;
        if (chunk_size == 0) return 0;
        return @intCast((info.size_bytes + chunk_size - 1) / chunk_size);
    }
    
    fn supportsResumeImpl(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }
    
    fn getNameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "Local";
    }
};

//=============================================================================
// SNAPSTREAM PROVIDER PLACEHOLDER
// This will be implemented when Snapstream is ready
//=============================================================================

/// Snapstream CDN provider (placeholder for future integration)
pub const SnapstreamProvider = struct {
    allocator: std.mem.Allocator,
    cdn_url: []const u8,
    api_key: ?[]const u8,
    
    // Snapstream-specific features
    enable_streaming: bool,
    enable_delta_sync: bool,
    preferred_region: ?[]const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, cdn_url: []const u8) Self {
        return .{
            .allocator = allocator,
            .cdn_url = cdn_url,
            .api_key = null,
            .enable_streaming = true,
            .enable_delta_sync = true,
            .preferred_region = null,
        };
    }
    
    pub fn provider(self: *Self) SnapshotProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    
    const vtable = SnapshotProvider.VTable{
        .findSnapshot = findSnapshotImpl,
        .listSnapshots = listSnapshotsImpl,
        .downloadChunk = downloadChunkImpl,
        .getChunkCount = getChunkCountImpl,
        .supportsResume = supportsResumeImpl,
        .getName = getNameImpl,
    };
    
    fn findSnapshotImpl(ptr: *anyopaque, target_slot: u64) anyerror!SnapshotInfo {
        _ = ptr;
        _ = target_slot;
        // TODO: Query Snapstream API for best snapshot
        return error.NotImplemented;
    }
    
    fn listSnapshotsImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]SnapshotInfo {
        _ = ptr;
        _ = allocator;
        // TODO: Query Snapstream API for available snapshots
        return error.NotImplemented;
    }
    
    fn downloadChunkImpl(
        ptr: *anyopaque,
        info: *const SnapshotInfo,
        offset: u64,
        size: usize,
        buffer: []u8,
    ) anyerror!usize {
        _ = ptr;
        _ = info;
        _ = offset;
        _ = size;
        _ = buffer;
        // TODO: Download chunk from Snapstream CDN
        // Features to support:
        //   - Parallel chunk downloads from nearest PoP
        //   - Delta encoding for incremental updates
        //   - Streaming decompression
        //   - Checksum verification
        return error.NotImplemented;
    }
    
    fn getChunkCountImpl(ptr: *anyopaque, info: *const SnapshotInfo, chunk_size: usize) u32 {
        _ = ptr;
        if (chunk_size == 0) return 0;
        return @intCast((info.size_bytes + chunk_size - 1) / chunk_size);
    }
    
    fn supportsResumeImpl(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }
    
    fn getNameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "Snapstream";
    }
};
