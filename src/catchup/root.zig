//! Fast Catch-Up System
//!
//! Modular high-performance catch-up for Solana validators.
//! Designed to work standalone with standard RPC/gossip sources,
//! and integrate seamlessly with Snapstream CDN when available.
//!
//! Components:
//!   - SnapshotProvider: Abstract interface for snapshot sources
//!   - ParallelDownloader: Multi-threaded chunked downloads
//!   - StreamingDecompressor: Decompress while downloading
//!   - BufferPool: Efficient memory management (replaces mmap)
//!   - ParallelIndexer: Lock-free parallel index generation
//!
//! Architecture:
//!   ┌─────────────────────────────────────────────────────┐
//!   │              FAST CATCH-UP PIPELINE                  │
//!   ├─────────────────────────────────────────────────────┤
//!   │  SnapshotProvider ──→ ParallelDownloader            │
//!   │        │                    │                        │
//!   │        ▼                    ▼                        │
//!   │  StreamingDecompressor ──→ BufferPool               │
//!   │                              │                        │
//!   │                    ParallelIndexer                   │
//!   └─────────────────────────────────────────────────────┘

const std = @import("std");
const storage = @import("../storage/root.zig");

// Re-export all components
pub const provider = @import("provider.zig");
pub const downloader = @import("downloader.zig");
pub const buffer_pool = @import("buffer_pool.zig");
pub const parallel_indexer = @import("parallel_indexer.zig");

// Main types
pub const SnapshotProvider = provider.SnapshotProvider;
pub const RpcSnapshotProvider = provider.RpcSnapshotProvider;
pub const ParallelDownloader = downloader.ParallelDownloader;
pub const BufferPool = buffer_pool.BufferPool;
pub const ParallelIndexer = parallel_indexer.ParallelIndexer;

/// Fast catch-up configuration
pub const CatchupConfig = struct {
    /// Number of download threads
    download_threads: u32 = 8,
    
    /// Chunk size for parallel downloads (bytes)
    chunk_size: usize = 16 * 1024 * 1024, // 16MB
    
    /// Buffer pool size (number of frames)
    buffer_pool_frames: usize = 65536,
    
    /// Frame size for buffer pool (bytes)
    /// 512 bytes covers 95% of accounts
    frame_size: usize = 512,
    
    /// Number of indexer threads
    indexer_threads: u32 = 8,
    
    /// Number of index bins (power of 2)
    index_bins: u32 = 8192,
    
    /// Enable streaming decompression
    streaming_decompress: bool = true,
    
    /// Use O_DIRECT for disk I/O (bypass page cache)
    use_direct_io: bool = true,
    
    /// Verify hash during loading
    verify_on_load: bool = true,
};

/// Fast catch-up manager
pub const FastCatchup = struct {
    config: CatchupConfig,
    allocator: std.mem.Allocator,
    provider: SnapshotProvider,
    downloader: ?*ParallelDownloader,
    buffer_pool: ?*BufferPool,
    indexer: ?*ParallelIndexer,
    
    // Statistics
    stats: CatchupStats,
    
    pub fn init(allocator: std.mem.Allocator, config: CatchupConfig, prov: SnapshotProvider) FastCatchup {
        return .{
            .config = config,
            .allocator = allocator,
            .provider = prov,
            .downloader = null,
            .buffer_pool = null,
            .indexer = null,
            .stats = CatchupStats{},
        };
    }
    
    /// Run fast catch-up to target slot
    pub fn catchupToSlot(
        self: *FastCatchup, 
        target_slot: u64,
        accounts_db: *storage.AccountsDb,
    ) !CatchupResult {
        const start_time = std.time.milliTimestamp();
        
        // Phase 1: Find best snapshot
        std.debug.print("[Catchup] Finding snapshot for slot {d}...\n", .{target_slot});
        const snapshot_info = try self.provider.findSnapshot(target_slot);
        
        std.debug.print("[Catchup] Found snapshot: slot={d}, size={d}MB\n", .{
            snapshot_info.slot,
            snapshot_info.size_bytes / (1024 * 1024),
        });
        
        // Determine paths
        const download_path = try std.fmt.allocPrint(
            self.allocator, 
            "/tmp/vexor-snapshot-{d}.tar.zst", 
            .{snapshot_info.slot}
        );
        defer self.allocator.free(download_path);
        
        const extract_path = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/vexor-extract-{d}",
            .{snapshot_info.slot}
        );
        defer self.allocator.free(extract_path);
        
        // Phase 2: Download (parallel chunked)
        std.debug.print("[Catchup] Downloading with {d} threads...\n", .{self.config.download_threads});
        self.stats.download_start = std.time.milliTimestamp();
        
        // Check if we have a source to download from
        if (snapshot_info.source_len > 0) {
            // Initialize parallel downloader
            self.downloader = try ParallelDownloader.init(
                self.allocator,
                self.provider,
                self.config.download_threads,
                self.config.chunk_size,
            );
            
            // Download to temp file
            try self.downloader.?.downloadToFile(&snapshot_info, download_path);
            
            self.downloader.?.deinit();
            self.downloader = null;
        }
        
        self.stats.download_end = std.time.milliTimestamp();
        self.stats.bytes_downloaded = snapshot_info.size_bytes;
        
        // Phase 3: Decompress (streaming)
        std.debug.print("[Catchup] Decompressing...\n", .{});
        self.stats.decompress_start = std.time.milliTimestamp();
        
        if (self.config.streaming_decompress) {
            const compression_type = storage.CompressionType.fromExtension(download_path);
            
            var decompressor = storage.StreamingDecompressor.init(
                self.allocator,
                compression_type,
                .{},
            );
            defer decompressor.deinit();
            
            try decompressor.start();
            
            // Create output directory
            try std.fs.cwd().makePath(extract_path);
            
            // Stream decompress to output
            const input_file = try std.fs.cwd().openFile(download_path, .{});
            defer input_file.close();
            
            const file_size = try input_file.getEndPos();
            const chunk_size: usize = 4 * 1024 * 1024; // 4MB chunks
            
            var offset: u64 = 0;
            var sequence: u64 = 0;
            
            while (offset < file_size) {
                const read_size = @min(chunk_size, file_size - offset);
                const buffer = try self.allocator.alloc(u8, read_size);
                
                const bytes_read = try input_file.read(buffer);
                
                try decompressor.addChunk(.{
                    .sequence = sequence,
                    .compressed_data = buffer[0..bytes_read],
                    .decompressed_data = null,
                    .is_final = offset + bytes_read >= file_size,
                    .original_size = null,
                });
                
                offset += bytes_read;
                sequence += 1;
            }
            
            decompressor.finishInput();
            
            // Write decompressed output
            const output_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/snapshot.tar",
                .{extract_path}
            );
            defer self.allocator.free(output_path);
            
            const output_file = try std.fs.cwd().createFile(output_path, .{});
            defer output_file.close();
            
            while (decompressor.getDecompressedChunk()) |chunk| {
                var mutable_chunk = chunk;
                defer mutable_chunk.deinit(self.allocator);
                
                if (mutable_chunk.decompressed_data) |data| {
                    try output_file.writeAll(data);
                }
            }
        }
        
        self.stats.decompress_end = std.time.milliTimestamp();
        
        // Phase 4: Load accounts with buffer pool + parallel indexing
        std.debug.print("[Catchup] Loading accounts with fast parallel loader...\n", .{});
        self.stats.load_start = std.time.milliTimestamp();
        
        // Use existing parallel snapshot loader (already optimized)
        var parallel_loader = storage.ParallelSnapshotLoader.init(self.allocator, .{
            .num_threads = self.config.indexer_threads,
            .verbose = true,
        });
        const load_result = try parallel_loader.loadSnapshotParallel(extract_path, accounts_db);
        
        self.stats.accounts_loaded = load_result.accounts_loaded;
        self.stats.load_end = std.time.milliTimestamp();
        
        // Phase 5: Build index in parallel
        std.debug.print("[Catchup] Building index with {d} threads...\n", .{self.config.indexer_threads});
        self.stats.index_start = std.time.milliTimestamp();
        
        // Initialize parallel indexer
        self.indexer = try ParallelIndexer.init(
            self.allocator,
            .{
                .num_threads = self.config.indexer_threads,
                .initial_bin_capacity = 1024,
            },
        );
        
        // Build index from loaded accounts
        try self.indexer.?.buildIndex(accounts_db);
        
        self.indexer.?.deinit();
        self.indexer = null;
        
        self.stats.index_end = std.time.milliTimestamp();
        
        const total_time = std.time.milliTimestamp() - start_time;
        
        return CatchupResult{
            .success = true,
            .final_slot = snapshot_info.slot,
            .accounts_loaded = self.stats.accounts_loaded,
            .total_time_ms = @intCast(total_time),
            .download_time_ms = @intCast(self.stats.download_end - self.stats.download_start),
            .decompress_time_ms = @intCast(self.stats.decompress_end - self.stats.decompress_start),
            .load_time_ms = @intCast(self.stats.load_end - self.stats.load_start),
            .index_time_ms = @intCast(self.stats.index_end - self.stats.index_start),
        };
    }
};

/// Catch-up statistics
pub const CatchupStats = struct {
    bytes_downloaded: u64 = 0,
    accounts_loaded: u64 = 0,
    download_start: i64 = 0,
    download_end: i64 = 0,
    decompress_start: i64 = 0,
    decompress_end: i64 = 0,
    load_start: i64 = 0,
    load_end: i64 = 0,
    index_start: i64 = 0,
    index_end: i64 = 0,
};

/// Catch-up result
pub const CatchupResult = struct {
    success: bool,
    final_slot: u64,
    accounts_loaded: u64,
    total_time_ms: u64,
    download_time_ms: u64,
    decompress_time_ms: u64,
    load_time_ms: u64,
    index_time_ms: u64,
    
    pub fn print(self: *const CatchupResult) void {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              FAST CATCH-UP RESULTS                        ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Final Slot:      {d}\n", .{self.final_slot});
        std.debug.print("║ Accounts Loaded: {d}\n", .{self.accounts_loaded});
        std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ TIMING BREAKDOWN:\n", .{});
        std.debug.print("║   Download:    {d}ms\n", .{self.download_time_ms});
        std.debug.print("║   Decompress:  {d}ms\n", .{self.decompress_time_ms});
        std.debug.print("║   Load:        {d}ms\n", .{self.load_time_ms});
        std.debug.print("║   Index:       {d}ms\n", .{self.index_time_ms});
        std.debug.print("║   ─────────────────────\n", .{});
        std.debug.print("║   TOTAL:       {d}ms\n", .{self.total_time_ms});
        std.debug.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }
};

test "catchup module" {
    // Basic compile test
    _ = provider;
    _ = downloader;
    _ = buffer_pool;
    _ = parallel_indexer;
}
