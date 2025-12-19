// Parallel Multi-Source Snapshot Download
//
// Speeds up snapshot download by:
// 1. Downloading from multiple peers simultaneously
// 2. Using HTTP Range requests for chunked parallel downloads
// 3. Automatic peer speed benchmarking and selection
// 4. Resume support on failure

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;
const fs = std.fs;
const net = std.net;
const http = std.http;

/// Represents a discovered snapshot source
pub const SnapshotPeer = struct {
    /// IP:port of the peer
    address: []const u8,
    /// Snapshot slot
    slot: u64,
    /// Snapshot hash
    hash: [32]u8,
    /// File size in bytes
    file_size: u64,
    /// URL path to snapshot
    url_path: []const u8,
    
    /// Benchmarking metrics
    latency_ms: u32 = 0,
    bandwidth_mbps: u32 = 0,
    success_rate: f32 = 1.0,
    last_benchmarked: i64 = 0,
    
    /// Calculate a score for peer selection (higher = better)
    pub fn score(self: *const SnapshotPeer) u32 {
        // Prioritize: low latency, high bandwidth, high success rate
        const latency_score: u32 = if (self.latency_ms > 0) 1000 / @min(self.latency_ms, 1000) else 0;
        const bw_score = self.bandwidth_mbps;
        const success_score: u32 = @intFromFloat(self.success_rate * 100);
        return latency_score + bw_score * 10 + success_score;
    }
};

/// Status of a download chunk
pub const ChunkStatus = enum {
    pending,
    downloading,
    completed,
    failed,
    verifying,
};

/// A chunk of the file to download
pub const Chunk = struct {
    id: u32,
    start_byte: u64,
    end_byte: u64,
    status: Atomic(ChunkStatus),
    assigned_peer: ?*SnapshotPeer,
    retry_count: u8,
    data: ?[]u8,
    
    pub fn init(id: u32, start: u64, end: u64) Chunk {
        return .{
            .id = id,
            .start_byte = start,
            .end_byte = end,
            .status = Atomic(ChunkStatus).init(.pending),
            .assigned_peer = null,
            .retry_count = 0,
            .data = null,
        };
    }
    
    pub fn size(self: *const Chunk) u64 {
        return self.end_byte - self.start_byte + 1;
    }
};

/// Download progress tracking
pub const DownloadProgress = struct {
    total_bytes: u64,
    downloaded_bytes: Atomic(u64),
    chunks_completed: Atomic(u32),
    chunks_total: u32,
    start_time: i64,
    active_downloads: Atomic(u32),
    
    pub fn init(total_bytes: u64, chunks_total: u32) DownloadProgress {
        return .{
            .total_bytes = total_bytes,
            .downloaded_bytes = Atomic(u64).init(0),
            .chunks_completed = Atomic(u32).init(0),
            .chunks_total = chunks_total,
            .start_time = std.time.milliTimestamp(),
            .active_downloads = Atomic(u32).init(0),
        };
    }
    
    pub fn percentComplete(self: *const DownloadProgress) f32 {
        const downloaded = self.downloaded_bytes.load(.monotonic);
        if (self.total_bytes == 0) return 0;
        return @as(f32, @floatFromInt(downloaded)) / @as(f32, @floatFromInt(self.total_bytes)) * 100.0;
    }
    
    pub fn speedMBps(self: *const DownloadProgress) f32 {
        const downloaded = self.downloaded_bytes.load(.monotonic);
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        if (elapsed_ms <= 0) return 0;
        return @as(f32, @floatFromInt(downloaded)) / 1_048_576.0 / (@as(f32, @floatFromInt(elapsed_ms)) / 1000.0);
    }
    
    pub fn etaSeconds(self: *const DownloadProgress) u64 {
        const speed = self.speedMBps();
        if (speed <= 0) return 0;
        const remaining = self.total_bytes - self.downloaded_bytes.load(.monotonic);
        return @intFromFloat(@as(f32, @floatFromInt(remaining)) / 1_048_576.0 / speed);
    }
};

/// Resume state for interrupted downloads
pub const ResumeState = struct {
    snapshot_slot: u64,
    snapshot_hash: [32]u8,
    total_size: u64,
    chunk_size: u64,
    completed_chunks: std.ArrayList(u32),
    output_path: []const u8,
    
    const MAGIC: [8]u8 = .{ 'V', 'X', 'R', 'S', 'N', 'A', 'P', '1' };
    
    pub fn init(allocator: Allocator, slot: u64, hash: [32]u8, total: u64, chunk_size: u64, path: []const u8) ResumeState {
        return .{
            .snapshot_slot = slot,
            .snapshot_hash = hash,
            .total_size = total,
            .chunk_size = chunk_size,
            .completed_chunks = std.ArrayList(u32).init(allocator),
            .output_path = path,
        };
    }
    
    pub fn deinit(self: *ResumeState) void {
        self.completed_chunks.deinit();
    }
    
    /// Save resume state to disk
    pub fn save(self: *const ResumeState, path: []const u8) !void {
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();
        
        const writer = file.writer();
        try writer.writeAll(&MAGIC);
        try writer.writeInt(u64, self.snapshot_slot, .little);
        try writer.writeAll(&self.snapshot_hash);
        try writer.writeInt(u64, self.total_size, .little);
        try writer.writeInt(u64, self.chunk_size, .little);
        try writer.writeInt(u32, @intCast(self.completed_chunks.items.len), .little);
        
        for (self.completed_chunks.items) |chunk_id| {
            try writer.writeInt(u32, chunk_id, .little);
        }
    }
    
    /// Load resume state from disk
    pub fn load(allocator: Allocator, path: []const u8) !?ResumeState {
        const file = fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        
        const reader = file.reader();
        
        var magic: [8]u8 = undefined;
        _ = reader.readAll(&magic) catch return null;
        if (!std.mem.eql(u8, &magic, &MAGIC)) return null;
        
        const slot = reader.readInt(u64, .little) catch return null;
        var hash: [32]u8 = undefined;
        _ = reader.readAll(&hash) catch return null;
        const total = reader.readInt(u64, .little) catch return null;
        const chunk_size = reader.readInt(u64, .little) catch return null;
        const count = reader.readInt(u32, .little) catch return null;
        
        var state = ResumeState.init(allocator, slot, hash, total, chunk_size, "");
        
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const chunk_id = reader.readInt(u32, .little) catch break;
            try state.completed_chunks.append(chunk_id);
        }
        
        return state;
    }
};

/// Parallel multi-source snapshot downloader
pub const ParallelDownloader = struct {
    allocator: Allocator,
    
    /// Available peers to download from
    peers: std.ArrayList(SnapshotPeer),
    
    /// Chunks to download
    chunks: std.ArrayList(Chunk),
    
    /// Download progress
    progress: DownloadProgress,
    
    /// Output file
    output_file: ?fs.File,
    output_path: []const u8,
    
    /// Configuration
    config: Config,
    
    /// Synchronization
    mutex: Mutex,
    shutdown: Atomic(bool),
    
    pub const Config = struct {
        /// Size of each chunk in bytes (default 64MB)
        chunk_size: u64 = 64 * 1024 * 1024,
        /// Maximum parallel downloads
        max_parallel: u32 = 8,
        /// Maximum retries per chunk
        max_retries: u8 = 3,
        /// Connection timeout in ms
        timeout_ms: u32 = 30_000,
        /// Enable resume support
        enable_resume: bool = true,
        /// Progress callback interval (ms)
        progress_interval_ms: u32 = 1000,
    };
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .peers = std.ArrayList(SnapshotPeer).init(allocator),
            .chunks = std.ArrayList(Chunk).init(allocator),
            .progress = DownloadProgress.init(0, 0),
            .output_file = null,
            .output_path = "",
            .config = config,
            .mutex = .{},
            .shutdown = Atomic(bool).init(false),
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.output_file) |f| f.close();
        self.chunks.deinit();
        self.peers.deinit();
    }
    
    /// Add a peer to the download pool
    pub fn addPeer(self: *Self, peer: SnapshotPeer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.peers.append(peer);
    }
    
    /// Benchmark all peers to determine speed
    pub fn benchmarkPeers(self: *Self) !void {
        for (self.peers.items) |*peer| {
            try self.benchmarkPeer(peer);
        }
        
        // Sort by score (best first)
        std.mem.sort(SnapshotPeer, self.peers.items, {}, struct {
            fn lessThan(_: void, a: SnapshotPeer, b: SnapshotPeer) bool {
                return a.score() > b.score();
            }
        }.lessThan);
    }
    
    fn benchmarkPeer(self: *Self, peer: *SnapshotPeer) !void {
        _ = self;
        const start = std.time.milliTimestamp();
        
        // TODO: Implement actual HTTP HEAD request to measure latency
        // For now, simulate with placeholder values
        const elapsed = std.time.milliTimestamp() - start;
        
        peer.latency_ms = @intCast(@max(1, elapsed));
        peer.bandwidth_mbps = 100; // Placeholder
        peer.last_benchmarked = std.time.milliTimestamp();
    }
    
    /// Prepare chunks for download
    pub fn prepareChunks(self: *Self, total_size: u64) !void {
        // Calculate number of chunks needed
        const chunk_count: u32 = @intCast((total_size + self.config.chunk_size - 1) / self.config.chunk_size);
        
        // Pre-allocate chunk array
        try self.chunks.ensureTotalCapacity(chunk_count);
        
        var offset: u64 = 0;
        var id: u32 = 0;
        
        while (offset < total_size) {
            const end = @min(offset + self.config.chunk_size - 1, total_size - 1);
            try self.chunks.append(Chunk.init(id, offset, end));
            offset = end + 1;
            id += 1;
        }
        
        self.progress = DownloadProgress.init(total_size, chunk_count);
    }
    
    /// Check for existing resume state
    pub fn checkResume(self: *Self, slot: u64) !?ResumeState {
        if (!self.config.enable_resume) return null;
        
        const resume_path = try std.fmt.allocPrint(self.allocator, "/tmp/vexor-download-{d}.resume", .{slot});
        defer self.allocator.free(resume_path);
        
        return try ResumeState.load(self.allocator, resume_path);
    }
    
    /// Get next available chunk for download
    fn getNextChunk(self: *Self) ?*Chunk {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.chunks.items) |*chunk| {
            if (chunk.status.load(.monotonic) == .pending) {
                chunk.status.store(.downloading, .monotonic);
                return chunk;
            }
        }
        return null;
    }
    
    /// Get the best available peer
    fn getBestPeer(self: *Self) ?*SnapshotPeer {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.peers.items.len == 0) return null;
        
        // Return highest scored peer
        // TODO: Implement round-robin or load balancing
        return &self.peers.items[0];
    }
    
    /// Download worker thread
    fn downloadWorker(self: *Self, worker_id: u32) void {
        _ = worker_id;
        
        while (!self.shutdown.load(.monotonic)) {
            const chunk = self.getNextChunk() orelse {
                // No more chunks, exit
                break;
            };
            
            const peer = self.getBestPeer() orelse {
                // No peers available
                chunk.status.store(.failed, .monotonic);
                continue;
            };
            
            chunk.assigned_peer = peer;
            _ = self.progress.active_downloads.fetchAdd(1, .monotonic);
            
            // Download the chunk
            const success = self.downloadChunk(chunk, peer);
            
            _ = self.progress.active_downloads.fetchSub(1, .monotonic);
            
            if (success) {
                chunk.status.store(.completed, .monotonic);
                _ = self.progress.chunks_completed.fetchAdd(1, .monotonic);
                _ = self.progress.downloaded_bytes.fetchAdd(chunk.size(), .monotonic);
            } else {
                chunk.retry_count += 1;
                if (chunk.retry_count >= self.config.max_retries) {
                    chunk.status.store(.failed, .monotonic);
                } else {
                    chunk.status.store(.pending, .monotonic);
                }
            }
        }
    }
    
    fn downloadChunk(self: *Self, chunk: *Chunk, peer: *SnapshotPeer) bool {
        _ = self;
        _ = chunk;
        _ = peer;
        
        // TODO: Implement actual HTTP Range request download
        // This is a placeholder for the actual implementation
        //
        // Steps:
        // 1. Open HTTP connection to peer
        // 2. Send GET with Range: bytes=start-end header
        // 3. Read response into chunk.data
        // 4. Write to output file at correct offset
        // 5. Verify checksum if available
        
        return true;
    }
    
    /// Start parallel download
    pub fn download(self: *Self, output_path: []const u8, progress_callback: ?*const fn (*const DownloadProgress) void) !void {
        self.output_path = output_path;
        
        // Create output file
        self.output_file = try fs.cwd().createFile(output_path, .{});
        
        // Pre-allocate file
        if (self.progress.total_bytes > 0) {
            try self.output_file.?.setEndPos(self.progress.total_bytes);
        }
        
        // Spawn worker threads
        var threads: [16]?Thread = [_]?Thread{null} ** 16;
        const num_workers = @min(self.config.max_parallel, 16);
        
        for (0..num_workers) |i| {
            threads[i] = try Thread.spawn(.{}, downloadWorker, .{ self, @as(u32, @intCast(i)) });
        }
        
        // Progress reporting loop
        while (self.progress.chunks_completed.load(.monotonic) < self.progress.chunks_total) {
            if (progress_callback) |cb| {
                cb(&self.progress);
            }
            std.time.sleep(self.config.progress_interval_ms * std.time.ns_per_ms);
        }
        
        // Wait for all workers
        for (threads) |t| {
            if (t) |thread| thread.join();
        }
        
        // Final progress report
        if (progress_callback) |cb| {
            cb(&self.progress);
        }
    }
    
    /// Cancel download
    pub fn cancel(self: *Self) void {
        self.shutdown.store(true, .monotonic);
    }
};

/// High-level function to download snapshot from multiple peers
pub fn downloadSnapshotParallel(
    allocator: Allocator,
    peers: []const SnapshotPeer,
    output_path: []const u8,
    progress_callback: ?*const fn (*const DownloadProgress) void,
) !void {
    var downloader = ParallelDownloader.init(allocator, .{});
    defer downloader.deinit();
    
    // Add all peers
    for (peers) |peer| {
        try downloader.addPeer(peer);
    }
    
    // Get file size from first peer
    if (peers.len == 0) return error.NoPeers;
    const total_size = peers[0].file_size;
    
    // Benchmark and prepare
    try downloader.benchmarkPeers();
    try downloader.prepareChunks(total_size);
    
    // Download
    try downloader.download(output_path, progress_callback);
}

// Tests
test "chunk initialization" {
    const chunk = Chunk.init(0, 0, 1023);
    try std.testing.expectEqual(@as(u64, 1024), chunk.size());
    try std.testing.expectEqual(ChunkStatus.pending, chunk.status.load(.monotonic));
}

test "peer scoring" {
    var peer = SnapshotPeer{
        .address = "127.0.0.1:8001",
        .slot = 1000,
        .hash = [_]u8{0} ** 32,
        .file_size = 1000000,
        .url_path = "/snapshot.tar.zst",
        .latency_ms = 50,
        .bandwidth_mbps = 100,
        .success_rate = 0.95,
    };
    
    const score = peer.score();
    try std.testing.expect(score > 0);
}

test "resume state save/load" {
    const allocator = std.testing.allocator;
    
    var state = ResumeState.init(allocator, 12345, [_]u8{1} ** 32, 1000000, 65536, "/tmp/test.tar.zst");
    defer state.deinit();
    
    try state.completed_chunks.append(0);
    try state.completed_chunks.append(5);
    try state.completed_chunks.append(10);
    
    try state.save("/tmp/test-resume.vxr");
    
    const loaded = try ResumeState.load(allocator, "/tmp/test-resume.vxr");
    if (loaded) |l| {
        var loaded_mut = l;
        defer loaded_mut.deinit();
        try std.testing.expectEqual(@as(u64, 12345), loaded_mut.snapshot_slot);
        try std.testing.expectEqual(@as(usize, 3), loaded_mut.completed_chunks.items.len);
    }
}

