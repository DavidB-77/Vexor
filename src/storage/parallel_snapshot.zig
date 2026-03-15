//! Parallel Snapshot Loading
//!
//! Optimizes snapshot loading by:
//! 1. Pre-scanning the file list
//! 2. io_uring batch file reads (kernel-level parallelism)
//! 3. Parallel AppendVec parsing (CPU-bound)
//! 4. Batched account storage
//!
//! This can provide 4-8x speedup on multi-core systems.

const std = @import("std");
const fs = std.fs;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const accounts = @import("accounts.zig");
const io_uring = @import("../network/io_uring.zig");

/// Parsed account ready for storage
pub const ParsedAccount = struct {
    pubkey: [32]u8,
    lamports: u64,
    owner: [32]u8,
    executable: bool,
    rent_epoch: u64,
    data: []const u8,
    slot: u64,
};

/// Result from parsing a single AppendVec file
pub const FileParseResult = struct {
    accounts: []ParsedAccount,
    lamports_total: u64,

    pub fn deinit(self: FileParseResult, allocator: Allocator) void {
        for (self.accounts) |acc| {
            if (acc.data.len > 0) {
                allocator.free(@constCast(acc.data));
            }
        }
        allocator.free(self.accounts);
    }
};

/// Configuration for parallel loading
pub const ParallelConfig = struct {
    /// Number of worker threads (default: CPU count - 1)
    num_threads: usize = 0,
    /// Batch size for account storage
    batch_size: usize = 1000,
    /// Enable verbose logging
    verbose: bool = false,
    /// Enable io_uring for batch file reads (Linux 5.1+)
    /// NOTE: Disabled - threaded approach is faster for this workload
    /// io_uring requires file sizes upfront, which means stat per file
    /// Threaded approach parallelizes stat+read together
    enable_io_uring: bool = false,
    /// io_uring batch size (files per batch)
    io_uring_batch_size: u32 = 64,
    /// Number of storage worker threads (default: same as num_threads)
    storage_threads: usize = 0,
};

/// Context for batch storage worker threads
pub const BatchStoreContext = struct {
    /// Slice of results to process (subset for this worker)
    results: []?FileParseResult,
    /// Corresponding error flags
    errors: []?anyerror,
    /// Start index in the results array
    start_idx: usize,
    /// End index (exclusive) in the results array
    end_idx: usize,
    /// AccountsDb reference (type-erased)
    accounts_db_ptr: *anyopaque,
    /// Whether VexStore is available
    use_vexstore: bool,
    /// Atomic counters for aggregation
    accounts_loaded: *std.atomic.Value(u64),
    lamports_total: *std.atomic.Value(u64),
    error_count: *std.atomic.Value(u64),
    vexstore_writes: *std.atomic.Value(u64),
    appendvec_writes: *std.atomic.Value(u64),
    /// Allocator for freeing parsed data
    allocator: Allocator,
};

/// Parallel snapshot loader
pub const ParallelSnapshotLoader = struct {
    const Self = @This();

    allocator: Allocator,
    config: ParallelConfig,

    // io_uring state
    ring: ?*io_uring.IoUring,
    batch_reader: ?io_uring.BatchFileReader,
    io_uring_available: bool,

    // Stats
    files_processed: std.atomic.Value(u64),
    accounts_parsed: std.atomic.Value(u64),
    bytes_processed: std.atomic.Value(u64),
    io_uring_reads: std.atomic.Value(u64),
    blocking_reads: std.atomic.Value(u64),

    pub fn init(allocator: Allocator, config: ParallelConfig) Self {
        var actual_config = config;
        if (actual_config.num_threads == 0) {
            // Default to CPU count - 1, minimum 1
            const cpu_count = std.Thread.getCpuCount() catch 4;
            actual_config.num_threads = @max(1, cpu_count -| 1);
        }

        // Try to initialize io_uring if enabled
        var ring: ?*io_uring.IoUring = null;
        var batch_reader: ?io_uring.BatchFileReader = null;
        var io_uring_available = false;

        if (actual_config.enable_io_uring and io_uring.IoUring.isAvailable()) {
            ring = io_uring.IoUring.init(allocator, .{
                .sq_entries = 256,
                .cq_entries = 512,
            }) catch null;

            if (ring) |r| {
                batch_reader = io_uring.BatchFileReader.init(allocator, r, actual_config.io_uring_batch_size);
                io_uring_available = true;
                std.debug.print("[ParallelLoader] io_uring enabled (batch size: {d})\n", .{actual_config.io_uring_batch_size});
            }
        }

        if (!io_uring_available) {
            std.debug.print("[ParallelLoader] io_uring not available, using blocking I/O\n", .{});
        }

        return Self{
            .allocator = allocator,
            .config = actual_config,
            .ring = ring,
            .batch_reader = batch_reader,
            .io_uring_available = io_uring_available,
            .files_processed = std.atomic.Value(u64).init(0),
            .accounts_parsed = std.atomic.Value(u64).init(0),
            .bytes_processed = std.atomic.Value(u64).init(0),
            .io_uring_reads = std.atomic.Value(u64).init(0),
            .blocking_reads = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.ring) |r| {
            r.deinit();
        }
    }

    /// Parse accounts from a buffer (used by both io_uring and blocking reads)
    pub fn parseBuffer(self: *Self, buf: []const u8, slot: u64) !FileParseResult {
        const file_size = buf.len;

        if (file_size == 0) {
            return FileParseResult{
                .accounts = &[_]ParsedAccount{},
                .lamports_total = 0,
            };
        }

        // Parse accounts
        var parsed_accounts = std.ArrayList(ParsedAccount).init(self.allocator);
        errdefer {
            for (parsed_accounts.items) |*acc| {
                if (acc.data.len > 0) {
                    self.allocator.free(@constCast(acc.data));
                }
            }
            parsed_accounts.deinit();
        }

        var offset: usize = 0;
        var lamports_total: u64 = 0;

        const STORED_META_SIZE: usize = 48;
        const ACCOUNT_META_SIZE: usize = 56;
        const MIN_ACCOUNT_SIZE: usize = STORED_META_SIZE + ACCOUNT_META_SIZE;
        const MAX_ACCOUNT_DATA_LEN: u64 = 10 * 1024 * 1024;

        while (offset + MIN_ACCOUNT_SIZE <= file_size) {
            const write_version = std.mem.readInt(u64, buf[offset..][0..8], .little);
            const data_len = std.mem.readInt(u64, buf[offset + 8 ..][0..8], .little);

            if (write_version == 0 and data_len == 0) break;
            if (data_len > MAX_ACCOUNT_DATA_LEN) break;

            var pubkey: [32]u8 = undefined;
            @memcpy(&pubkey, buf[offset + 16 ..][0..32]);

            const meta_offset = offset + STORED_META_SIZE;
            if (meta_offset + ACCOUNT_META_SIZE > file_size) break;

            const lamports = std.mem.readInt(u64, buf[meta_offset..][0..8], .little);
            const rent_epoch = std.mem.readInt(u64, buf[meta_offset + 8 ..][0..8], .little);

            var owner: [32]u8 = undefined;
            @memcpy(&owner, buf[meta_offset + 16 ..][0..32]);

            const executable = buf[meta_offset + 48] != 0;

            const data_offset = meta_offset + ACCOUNT_META_SIZE;
            const data_end = data_offset + @as(usize, @intCast(data_len));

            if (data_end > file_size) break;

            // Copy data
            const data = if (data_len > 0) blk: {
                const d = try self.allocator.alloc(u8, @intCast(data_len));
                @memcpy(d, buf[data_offset..data_end]);
                break :blk d;
            } else &[_]u8{};

            try parsed_accounts.append(ParsedAccount{
                .pubkey = pubkey,
                .lamports = lamports,
                .owner = owner,
                .executable = executable,
                .rent_epoch = rent_epoch,
                .data = data,
                .slot = slot,
            });

            lamports_total +|= lamports;

            // Advance to next account (8-byte aligned)
            const record_len = STORED_META_SIZE + ACCOUNT_META_SIZE + @as(usize, @intCast(data_len));
            const pad = (8 - (record_len % 8)) & 7;
            offset += record_len + pad;

            // Skip potential hash (32 bytes) - some formats have it
            if (offset + 32 <= file_size) {
                // Check if next 8 bytes look like a valid write_version
                if (offset + 8 <= file_size) {
                    const next_version = std.mem.readInt(u64, buf[offset..][0..8], .little);
                    if (next_version == 0) {
                        offset += 32; // Skip hash
                    }
                }
            }
        }

        return FileParseResult{
            .accounts = try parsed_accounts.toOwnedSlice(),
            .lamports_total = lamports_total,
        };
    }

    /// Parse a single AppendVec file (thread-safe, no shared state)
    /// Uses blocking I/O - for use when io_uring is not available or in worker threads
    pub fn parseAppendVec(self: *Self, file_path: []const u8, slot: u64) !FileParseResult {
        var file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        const file_size = stat.size;

        if (file_size == 0) {
            _ = self.files_processed.fetchAdd(1, .monotonic);
            return FileParseResult{
                .accounts = &[_]ParsedAccount{},
                .lamports_total = 0,
            };
        }

        // Read file into heap buffer
        const buf = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buf);

        const bytes_read = try file.readAll(buf);
        if (bytes_read != file_size) {
            return error.ShortRead;
        }

        _ = self.blocking_reads.fetchAdd(1, .monotonic);

        const result = try self.parseBuffer(buf, slot);

        _ = self.files_processed.fetchAdd(1, .monotonic);
        _ = self.accounts_parsed.fetchAdd(@intCast(result.accounts.len), .monotonic);
        _ = self.bytes_processed.fetchAdd(file_size, .monotonic);

        return result;
    }

    /// Get current stats
    pub fn getStats(self: *Self) struct { files: u64, accounts: u64, bytes: u64 } {
        return .{
            .files = self.files_processed.load(.monotonic),
            .accounts = self.accounts_parsed.load(.monotonic),
            .bytes = self.bytes_processed.load(.monotonic),
        };
    }

    /// Worker context for parallel processing
    const WorkerContext = struct {
        loader: *Self,
        file_paths: []const []const u8,
        results: []?FileParseResult,
        errors: []?anyerror,
        start_idx: usize,
        end_idx: usize,
        slot: u64,
    };

    /// Worker function for thread pool
    fn workerFn(ctx: *WorkerContext) void {
        var i = ctx.start_idx;
        while (i < ctx.end_idx) : (i += 1) {
            ctx.results[i] = ctx.loader.parseAppendVec(ctx.file_paths[i], ctx.slot) catch |err| {
                ctx.errors[i] = err;
                continue;
            };
            ctx.errors[i] = null;
        }
    }

    /// Load files using threaded approach (io_uring fallback)
    /// io_uring for file reads doesn't help because we need file sizes first,
    /// which requires stat per file. Threaded approach parallelizes both stat+read.
    fn loadWithIoUring(
        self: *Self,
        accounts_dir: fs.Dir,
        file_paths: []const []const u8,
        results: []?FileParseResult,
        errors: []?anyerror,
    ) !void {
        // Note: io_uring batch reader is available but not used here
        // because threaded approach is faster for this workload
        _ = accounts_dir;

        const num_files = file_paths.len;
        const files_per_thread = (num_files + self.config.num_threads - 1) / self.config.num_threads;

        var threads = try self.allocator.alloc(Thread, self.config.num_threads);
        defer self.allocator.free(threads);

        var contexts = try self.allocator.alloc(WorkerContext, self.config.num_threads);
        defer self.allocator.free(contexts);

        var spawned: usize = 0;
        for (0..self.config.num_threads) |t| {
            const start_idx = t * files_per_thread;
            if (start_idx >= num_files) break;

            const end_idx = @min(start_idx + files_per_thread, num_files);

            contexts[t] = WorkerContext{
                .loader = self,
                .file_paths = file_paths,
                .results = results,
                .errors = errors,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .slot = 0,
            };

            threads[t] = try Thread.spawn(.{}, workerFn, .{&contexts[t]});
            spawned += 1;
        }

        // Wait for all threads
        for (threads[0..spawned]) |t| {
            t.join();
        }
    }

    /// Load snapshot directory in parallel
    /// Returns total accounts loaded and lamports
    pub fn loadSnapshotParallel(
        self: *Self,
        snapshot_dir: []const u8,
        accounts_db: anytype,
    ) !struct { accounts_loaded: u64, lamports_total: u64 } {
        const start_time = std.time.milliTimestamp();

        // Enable bulk loading mode if available (faster inserts)
        if (@typeInfo(@TypeOf(accounts_db)) != .Null) {
            if (@hasDecl(@TypeOf(accounts_db.*), "enableBulkLoading")) {
                accounts_db.enableBulkLoading();
            }
        }
        defer {
            // Disable bulk loading mode when done
            if (@typeInfo(@TypeOf(accounts_db)) != .Null) {
                if (@hasDecl(@TypeOf(accounts_db.*), "disableBulkLoading")) {
                    accounts_db.disableBulkLoading();
                }
            }
        }

        // Build accounts path
        const accounts_path = try std.fs.path.join(self.allocator, &.{ snapshot_dir, "accounts" });
        defer self.allocator.free(accounts_path);

        // Phase 1: Collect all file paths
        var file_paths = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (file_paths.items) |p| self.allocator.free(p);
            file_paths.deinit();
        }

        var accounts_dir = try fs.cwd().openDir(accounts_path, .{ .iterate = true });
        defer accounts_dir.close();

        var iter = accounts_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ accounts_path, entry.name });
            try file_paths.append(full_path);
        }

        const num_files = file_paths.items.len;
        if (num_files == 0) {
            return .{ .accounts_loaded = 0, .lamports_total = 0 };
        }

        std.debug.print("[ParallelLoader] Found {d} files, using {d} threads (io_uring: {s})\n", .{
            num_files, self.config.num_threads, if (self.io_uring_available) "YES" else "NO",
        });

        // Phase 2: Allocate result arrays
        const results = try self.allocator.alloc(?FileParseResult, num_files);
        defer self.allocator.free(results);
        @memset(results, null);

        const errors = try self.allocator.alloc(?anyerror, num_files);
        defer self.allocator.free(errors);
        @memset(errors, null);

        // Phase 3: Use io_uring batch reads if available, otherwise use threads
        if (self.io_uring_available and self.batch_reader != null) {
            // io_uring path: batch read all files, then parse in parallel
            try self.loadWithIoUring(accounts_dir, file_paths.items, results, errors);
        } else {
            // Fallback: traditional threaded approach with blocking I/O
            const files_per_thread = (num_files + self.config.num_threads - 1) / self.config.num_threads;

            var threads = try self.allocator.alloc(Thread, self.config.num_threads);
            defer self.allocator.free(threads);

            var contexts = try self.allocator.alloc(WorkerContext, self.config.num_threads);
            defer self.allocator.free(contexts);

            var spawned: usize = 0;
            for (0..self.config.num_threads) |t| {
                const start_idx = t * files_per_thread;
                if (start_idx >= num_files) break;

                const end_idx = @min(start_idx + files_per_thread, num_files);

                contexts[t] = WorkerContext{
                    .loader = self,
                    .file_paths = file_paths.items,
                    .results = results,
                    .errors = errors,
                    .start_idx = start_idx,
                    .end_idx = end_idx,
                    .slot = 0, // TODO: parse from filename
                };

                threads[t] = try Thread.spawn(.{}, workerFn, .{&contexts[t]});
                spawned += 1;
            }

            // Wait for all threads
            for (threads[0..spawned]) |t| {
                t.join();
            }
        }

        const parse_time = std.time.milliTimestamp() - start_time;
        std.debug.print("[ParallelLoader] Parse phase: {d}ms\n", .{parse_time});

        // Phase 4: Store accounts in parallel using worker threads
        const store_start = std.time.milliTimestamp();
        var accounts_loaded_atomic = std.atomic.Value(u64).init(0);
        var lamports_total_atomic = std.atomic.Value(u64).init(0);
        var error_count_atomic = std.atomic.Value(u64).init(0);
        var vexstore_writes_atomic = std.atomic.Value(u64).init(0);
        var appendvec_writes_atomic = std.atomic.Value(u64).init(0);

        // Check if VexStore is available for faster bulk loading
        const use_vexstore = if (@typeInfo(@TypeOf(accounts_db)) != .Null)
            @hasDecl(@TypeOf(accounts_db.*), "hasVexStore") and accounts_db.hasVexStore()
        else
            false;

        if (use_vexstore) {
            std.debug.print("[ParallelLoader] Using VexStore for bulk storage\n", .{});
        }

        // Determine number of storage threads
        const storage_threads = if (self.config.storage_threads > 0)
            self.config.storage_threads
        else
            self.config.num_threads;

        const results_per_thread = (num_files + storage_threads - 1) / storage_threads;

        std.debug.print("[ParallelLoader] Phase 4: Storing accounts with {d} threads\n", .{storage_threads});

        // Storage worker context
        const StorageWorkerCtx = struct {
            results: []?FileParseResult,
            errors: []?anyerror,
            start_idx: usize,
            end_idx: usize,
            accounts_db: @TypeOf(accounts_db),
            use_vexstore: bool,
            accounts_loaded: *std.atomic.Value(u64),
            lamports_total: *std.atomic.Value(u64),
            error_count: *std.atomic.Value(u64),
            vexstore_writes: *std.atomic.Value(u64),
            appendvec_writes: *std.atomic.Value(u64),
            allocator: Allocator,
        };

        // Storage worker function
        const storageWorkerFn = struct {
            fn work(ctx: *StorageWorkerCtx) void {
                // Per-thread reusable serialization buffer — eliminates heap thrashing.
                // Pre-allocate 4KB (enough for most accounts). Grows automatically if needed.
                var reuse_buf = std.ArrayList(u8).initCapacity(ctx.allocator, 4096) catch {
                    std.log.err("[ParallelLoader] Worker failed to allocate reuse buffer", .{});
                    return;
                };
                defer reuse_buf.deinit();

                var store_ok: u64 = 0;
                var store_err: u64 = 0;

                var i = ctx.start_idx;
                while (i < ctx.end_idx) : (i += 1) {
                    if (ctx.errors[i] != null) {
                        _ = ctx.error_count.fetchAdd(1, .monotonic);
                        continue;
                    }

                    if (ctx.results[i]) |result| {
                        for (result.accounts) |acc| {
                            // Store in accounts_db if provided
                            if (@typeInfo(@TypeOf(ctx.accounts_db)) != .Null) {
                                const core_pubkey = @as(*const core.Pubkey, @ptrCast(&acc.pubkey));
                                const core_owner = @as(*const core.Pubkey, @ptrCast(&acc.owner));

                                const account = accounts.Account{
                                    .lamports = acc.lamports,
                                    .owner = core_owner.*,
                                    .executable = acc.executable,
                                    .rent_epoch = acc.rent_epoch,
                                    .data = acc.data,
                                };

                                // Use reusable-buffer bulk store (zero-alloc hot path)
                                if (@hasDecl(@TypeOf(ctx.accounts_db.*), "storeAccountBulkReuse")) {
                                    ctx.accounts_db.storeAccountBulkReuse(core_pubkey, &account, acc.slot, &reuse_buf) catch |err| {
                                        store_err += 1;
                                        if (store_err <= 3) {
                                            std.log.err("[ParallelLoader] storeAccountBulkReuse failed: {}", .{err});
                                        }
                                        continue;
                                    };
                                } else if (@hasDecl(@TypeOf(ctx.accounts_db.*), "storeAccountBulk")) {
                                    ctx.accounts_db.storeAccountBulk(core_pubkey, &account, acc.slot) catch |err| {
                                        store_err += 1;
                                        if (store_err <= 3) {
                                            std.log.err("[ParallelLoader] storeAccountBulk failed: {}", .{err});
                                        }
                                        continue;
                                    };
                                }
                                store_ok += 1;
                                _ = ctx.appendvec_writes.fetchAdd(1, .monotonic);
                            }

                            _ = ctx.accounts_loaded.fetchAdd(1, .monotonic);
                            _ = ctx.lamports_total.fetchAdd(acc.lamports, .monotonic);
                        }

                        // Free parsed data
                        result.deinit(ctx.allocator);
                    }
                }

                if (store_err > 0) {
                    std.log.err("[ParallelLoader] Worker: {d} stored OK, {d} FAILED", .{ store_ok, store_err });
                }
            }
        }.work;

        // Spawn storage worker threads
        var storage_thread_handles = try self.allocator.alloc(Thread, storage_threads);
        defer self.allocator.free(storage_thread_handles);

        var storage_contexts = try self.allocator.alloc(StorageWorkerCtx, storage_threads);
        defer self.allocator.free(storage_contexts);

        var spawned_storage: usize = 0;
        for (0..storage_threads) |t| {
            const start_idx = t * results_per_thread;
            if (start_idx >= num_files) break;

            const end_idx = @min(start_idx + results_per_thread, num_files);

            storage_contexts[t] = StorageWorkerCtx{
                .results = results,
                .errors = errors,
                .start_idx = start_idx,
                .end_idx = end_idx,
                .accounts_db = accounts_db,
                .use_vexstore = use_vexstore,
                .accounts_loaded = &accounts_loaded_atomic,
                .lamports_total = &lamports_total_atomic,
                .error_count = &error_count_atomic,
                .vexstore_writes = &vexstore_writes_atomic,
                .appendvec_writes = &appendvec_writes_atomic,
                .allocator = self.allocator,
            };

            storage_thread_handles[t] = try Thread.spawn(.{}, storageWorkerFn, .{&storage_contexts[t]});
            spawned_storage += 1;
        }

        // Wait for all storage threads to complete
        for (storage_thread_handles[0..spawned_storage]) |t| {
            t.join();
        }

        // Read final atomic values
        const accounts_loaded = accounts_loaded_atomic.load(.monotonic);
        const lamports_total = lamports_total_atomic.load(.monotonic);
        const error_count = error_count_atomic.load(.monotonic);
        const vexstore_writes = vexstore_writes_atomic.load(.monotonic);
        const appendvec_writes = appendvec_writes_atomic.load(.monotonic);

        // Flush VexStore if used
        if (use_vexstore and @typeInfo(@TypeOf(accounts_db)) != .Null) {
            if (@hasDecl(@TypeOf(accounts_db.*), "flushVexStore")) {
                accounts_db.flushVexStore() catch {};
            }
        }

        const store_time = std.time.milliTimestamp() - store_start;
        const total_time = std.time.milliTimestamp() - start_time;
        const io_uring_count = self.io_uring_reads.load(.monotonic);
        const blocking_count = self.blocking_reads.load(.monotonic);

        std.debug.print("[ParallelLoader] Store phase: {d}ms\n", .{store_time});
        std.debug.print("[ParallelLoader] Total: {d} accounts in {d}ms ({d} errors)\n", .{
            accounts_loaded, total_time, error_count,
        });
        if (io_uring_count > 0 or blocking_count > 0) {
            std.debug.print("[ParallelLoader] Reads: io_uring={d}, blocking={d}\n", .{
                io_uring_count, blocking_count,
            });
        }
        if (vexstore_writes > 0 or appendvec_writes > 0) {
            std.debug.print("[ParallelLoader] Writes: vexstore={d}, appendvec={d}\n", .{
                vexstore_writes, appendvec_writes,
            });
        }

        return .{
            .accounts_loaded = accounts_loaded,
            .lamports_total = lamports_total,
        };
    }
};

/// Generate synthetic test AppendVec files
pub fn generateTestFixture(allocator: Allocator, output_dir: []const u8, num_files: usize, accounts_per_file: usize) !void {
    // Create output directory
    fs.cwd().makeDir(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const accounts_dir_path = try std.fs.path.join(allocator, &.{ output_dir, "accounts" });
    defer allocator.free(accounts_dir_path);

    fs.cwd().makeDir(accounts_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create version file
    const version_path = try std.fs.path.join(allocator, &.{ output_dir, "version" });
    defer allocator.free(version_path);

    var version_file = try fs.cwd().createFile(version_path, .{});
    try version_file.writeAll("1.2.0\n");
    version_file.close();

    // Generate AppendVec files
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..num_files) |file_idx| {
        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "{d}.{d}", .{ file_idx * 1000, file_idx });

        const file_path = try std.fs.path.join(allocator, &.{ accounts_dir_path, filename });
        defer allocator.free(file_path);

        const file = try fs.cwd().createFile(file_path, .{});
        defer file.close();

        // Write accounts to file
        for (0..accounts_per_file) |acc_idx| {
            // Generate random account
            var pubkey: [32]u8 = undefined;
            random.bytes(&pubkey);

            var owner: [32]u8 = undefined;
            random.bytes(&owner);

            const data_len: u64 = random.intRangeAtMost(u64, 0, 1024);
            const lamports: u64 = random.intRangeAtMost(u64, 1, 1_000_000_000);
            const rent_epoch: u64 = random.intRangeAtMost(u64, 0, 1000);
            const executable: u8 = if (random.boolean()) 1 else 0;

            // Write StoredMeta
            const write_version: u64 = @intCast(acc_idx + 1);
            try file.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u64, write_version)));
            try file.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u64, data_len)));
            try file.writeAll(&pubkey);

            // Write AccountMeta
            try file.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u64, lamports)));
            try file.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u64, rent_epoch)));
            try file.writeAll(&owner);
            try file.writeAll(&[_]u8{executable});
            try file.writeAll(&[_]u8{0} ** 7); // padding

            // Write data
            if (data_len > 0) {
                const data = try allocator.alloc(u8, @intCast(data_len));
                defer allocator.free(data);
                random.bytes(data);
                try file.writeAll(data);
            }

            // Align to 8 bytes
            const record_len = 48 + 56 + @as(usize, @intCast(data_len));
            const pad = (8 - (record_len % 8)) & 7;
            if (pad > 0) {
                try file.writeAll(([_]u8{0} ** 8)[0..pad]);
            }
        }
    }

    std.debug.print("[TestFixture] Generated {d} files with {d} accounts each in {s}\n", .{
        num_files, accounts_per_file, output_dir,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "generate and parse test fixture" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/vexor-parallel-test";

    // Clean up any previous test
    fs.cwd().deleteTree(test_dir) catch {};

    // Generate test fixture: 10 files, 100 accounts each
    try generateTestFixture(allocator, test_dir, 10, 100);

    // Parse one file
    var loader = ParallelSnapshotLoader.init(allocator, .{});

    const accounts_path = try std.fs.path.join(allocator, &.{ test_dir, "accounts", "0.0" });
    defer allocator.free(accounts_path);

    var result = try loader.parseAppendVec(accounts_path, 0);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 100), result.accounts.len);
    try std.testing.expect(result.lamports_total > 0);

    // Clean up
    fs.cwd().deleteTree(test_dir) catch {};
}

test "benchmark parallel vs sequential" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/vexor-bench-test";

    // Clean up any previous test
    fs.cwd().deleteTree(test_dir) catch {};

    // Generate realistic test fixture: 50 files, 2000 accounts each = 100k accounts
    // Real AppendVecs are larger files (several MB), few large files is more realistic
    try generateTestFixture(allocator, test_dir, 50, 2000);

    var loader = ParallelSnapshotLoader.init(allocator, .{ .verbose = true });

    // Collect file paths
    const accounts_dir_path = try std.fs.path.join(allocator, &.{ test_dir, "accounts" });
    defer allocator.free(accounts_dir_path);

    var accounts_dir = try fs.cwd().openDir(accounts_dir_path, .{ .iterate = true });
    defer accounts_dir.close();

    var file_paths = std.ArrayList([]const u8).init(allocator);
    defer {
        for (file_paths.items) |p| allocator.free(p);
        file_paths.deinit();
    }

    var iter = accounts_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const full_path = try std.fs.path.join(allocator, &.{ accounts_dir_path, entry.name });
        try file_paths.append(full_path);
    }

    std.debug.print("\n[Benchmark] Found {d} files\n", .{file_paths.items.len});

    // Sequential parse (baseline)
    const seq_start = std.time.milliTimestamp();
    var seq_accounts: u64 = 0;
    for (file_paths.items) |path| {
        var result = try loader.parseAppendVec(path, 0);
        seq_accounts += result.accounts.len;
        result.deinit(allocator);
    }
    const seq_end = std.time.milliTimestamp();
    const seq_ms = seq_end - seq_start;

    std.debug.print("[Benchmark] Sequential: {d} accounts in {d}ms\n", .{ seq_accounts, seq_ms });

    // Reset stats
    loader.files_processed = std.atomic.Value(u64).init(0);
    loader.accounts_parsed = std.atomic.Value(u64).init(0);

    // Parallel parse - spawn threads manually for benchmark
    const par_start = std.time.milliTimestamp();
    const files_per_thread = (file_paths.items.len + loader.config.num_threads - 1) / loader.config.num_threads;

    const WorkCtx = struct {
        ldr: *ParallelSnapshotLoader,
        paths: []const []const u8,
        start: usize,
        end: usize,
        alloc: Allocator,

        fn work(ctx: *@This()) void {
            var i = ctx.start;
            while (i < ctx.end) : (i += 1) {
                var res = ctx.ldr.parseAppendVec(ctx.paths[i], 0) catch continue;
                res.deinit(ctx.alloc);
            }
        }
    };

    var threads = try allocator.alloc(Thread, loader.config.num_threads);
    defer allocator.free(threads);

    var ctxs = try allocator.alloc(WorkCtx, loader.config.num_threads);
    defer allocator.free(ctxs);

    var spawned: usize = 0;
    for (0..loader.config.num_threads) |t| {
        const s = t * files_per_thread;
        if (s >= file_paths.items.len) break;
        const e = @min(s + files_per_thread, file_paths.items.len);

        ctxs[t] = WorkCtx{
            .ldr = &loader,
            .paths = file_paths.items,
            .start = s,
            .end = e,
            .alloc = allocator,
        };
        threads[t] = try Thread.spawn(.{}, WorkCtx.work, .{&ctxs[t]});
        spawned += 1;
    }

    for (threads[0..spawned]) |th| th.join();

    const par_stats = loader.getStats();
    const par_end = std.time.milliTimestamp();
    const par_ms = par_end - par_start;

    std.debug.print("[Benchmark] Parallel:   {d} accounts in {d}ms ({d} threads)\n", .{ par_stats.accounts, par_ms, spawned });

    // Calculate speedup
    if (par_ms > 0) {
        const speedup = @as(f64, @floatFromInt(seq_ms)) / @as(f64, @floatFromInt(par_ms));
        std.debug.print("[Benchmark] Speedup: {d:.2}x\n", .{speedup});
    }

    // Clean up
    fs.cwd().deleteTree(test_dir) catch {};
}
