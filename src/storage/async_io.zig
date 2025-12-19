// Async I/O Support using io_uring
//
// Provides non-blocking file I/O for:
// - Parallel snapshot chunk writes
// - Async account loading
// - Buffered ledger writes
//
// Falls back to blocking I/O if io_uring is not available

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const os = std.os;
const linux = os.linux;

/// io_uring operation result
pub const IoResult = struct {
    bytes_transferred: i32,
    user_data: u64,
    success: bool,
    
    pub fn isSuccess(self: *const IoResult) bool {
        return self.success and self.bytes_transferred >= 0;
    }
};

/// Configuration for async I/O
pub const AsyncIoConfig = struct {
    /// Number of submission queue entries
    queue_depth: u32 = 256,
    /// Enable SQPOLL for kernel-side polling (requires CAP_SYS_ADMIN)
    enable_sqpoll: bool = false,
    /// SQPOLL idle timeout in milliseconds
    sqpoll_idle_ms: u32 = 1000,
    /// Enable registered file descriptors for faster ops
    register_fds: bool = true,
    /// Maximum registered files
    max_registered_files: u32 = 64,
};

/// Async I/O manager using io_uring
pub const AsyncIoManager = struct {
    allocator: Allocator,
    ring: ?*linux.IoUring,
    config: AsyncIoConfig,
    registered_fds: std.ArrayList(fs.File),
    pending_ops: u32,
    is_available: bool,
    
    const Self = @This();
    
    /// Initialize async I/O manager
    pub fn init(allocator: Allocator, config: AsyncIoConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .ring = null,
            .config = config,
            .registered_fds = std.ArrayList(fs.File).init(allocator),
            .pending_ops = 0,
            .is_available = false,
        };
        
        // Try to initialize io_uring
        self.ring = linux.IoUring.init(config.queue_depth, .{
            .SQPOLL = if (config.enable_sqpoll) 1 else 0,
            .SQ_AFF = 0,
        }) catch |err| {
            // io_uring not available, will fall back to blocking I/O
            std.log.warn("io_uring not available ({s}), using blocking I/O", .{@errorName(err)});
            return self;
        };
        
        self.is_available = true;
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        if (self.ring) |ring| {
            ring.deinit();
        }
        self.registered_fds.deinit();
        self.allocator.destroy(self);
    }
    
    /// Check if async I/O is available
    pub fn available(self: *const Self) bool {
        return self.is_available;
    }
    
    /// Register a file for faster operations
    pub fn registerFile(self: *Self, file: fs.File) !u32 {
        if (!self.is_available) return error.NotAvailable;
        
        const index: u32 = @intCast(self.registered_fds.items.len);
        try self.registered_fds.append(file);
        
        // TODO: Actually register with io_uring
        // linux.io_uring_register_files(...)
        
        return index;
    }
    
    /// Queue an async write operation
    pub fn queueWrite(
        self: *Self,
        file: fs.File,
        buffer: []const u8,
        offset: u64,
        user_data: u64,
    ) !void {
        if (!self.is_available) {
            // Fallback to blocking write
            _ = try file.pwrite(buffer, offset);
            return;
        }
        
        const ring = self.ring orelse return error.NotInitialized;
        
        // Get a submission queue entry
        const sqe = try ring.getSqe();
        
        // Prepare write operation
        sqe.prepWrite(file.handle, buffer, offset);
        sqe.user_data = user_data;
        
        self.pending_ops += 1;
    }
    
    /// Queue an async read operation
    pub fn queueRead(
        self: *Self,
        file: fs.File,
        buffer: []u8,
        offset: u64,
        user_data: u64,
    ) !void {
        if (!self.is_available) {
            // Fallback to blocking read
            _ = try file.pread(buffer, offset);
            return;
        }
        
        const ring = self.ring orelse return error.NotInitialized;
        
        const sqe = try ring.getSqe();
        sqe.prepRead(file.handle, buffer, offset);
        sqe.user_data = user_data;
        
        self.pending_ops += 1;
    }
    
    /// Submit all queued operations
    pub fn submit(self: *Self) !u32 {
        if (!self.is_available or self.ring == null) return 0;
        
        return try self.ring.?.submit();
    }
    
    /// Wait for completions
    pub fn waitCompletions(self: *Self, min_completions: u32) ![]IoResult {
        if (!self.is_available or self.ring == null) {
            return &[_]IoResult{};
        }
        
        var results = std.ArrayList(IoResult).init(self.allocator);
        
        var completed: u32 = 0;
        while (completed < min_completions and self.pending_ops > 0) {
            const cqe = try self.ring.?.getCqe();
            
            try results.append(.{
                .bytes_transferred = cqe.res,
                .user_data = cqe.user_data,
                .success = cqe.res >= 0,
            });
            
            self.ring.?.cqAdvance(1);
            self.pending_ops -= 1;
            completed += 1;
        }
        
        return results.toOwnedSlice();
    }
    
    /// Get number of pending operations
    pub fn pendingCount(self: *const Self) u32 {
        return self.pending_ops;
    }
};

/// High-level async file writer
pub const AsyncFileWriter = struct {
    io_manager: *AsyncIoManager,
    file: fs.File,
    file_index: ?u32,
    
    const Self = @This();
    
    pub fn init(io_manager: *AsyncIoManager, path: []const u8) !Self {
        const file = try fs.cwd().createFile(path, .{});
        
        var self = Self{
            .io_manager = io_manager,
            .file = file,
            .file_index = null,
        };
        
        // Register file if possible
        if (io_manager.available()) {
            self.file_index = io_manager.registerFile(file) catch null;
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.file.close();
    }
    
    /// Write data at offset (async if available)
    pub fn writeAt(self: *Self, data: []const u8, offset: u64, user_data: u64) !void {
        try self.io_manager.queueWrite(self.file, data, offset, user_data);
    }
    
    /// Pre-allocate file size
    pub fn preallocate(self: *Self, size: u64) !void {
        try self.file.setEndPos(size);
    }
};

/// Batch I/O operations for efficient bulk writes
pub const BatchIoQueue = struct {
    allocator: Allocator,
    io_manager: *AsyncIoManager,
    pending_writes: std.ArrayList(WriteOp),
    batch_size: u32,
    
    const WriteOp = struct {
        file: fs.File,
        data: []const u8,
        offset: u64,
        user_data: u64,
    };
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, io_manager: *AsyncIoManager, batch_size: u32) Self {
        return .{
            .allocator = allocator,
            .io_manager = io_manager,
            .pending_writes = std.ArrayList(WriteOp).init(allocator),
            .batch_size = batch_size,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pending_writes.deinit();
    }
    
    /// Add a write to the batch
    pub fn add(self: *Self, file: fs.File, data: []const u8, offset: u64, user_data: u64) !void {
        try self.pending_writes.append(.{
            .file = file,
            .data = data,
            .offset = offset,
            .user_data = user_data,
        });
        
        // Auto-flush if batch is full
        if (self.pending_writes.items.len >= self.batch_size) {
            try self.flush();
        }
    }
    
    /// Flush all pending writes
    pub fn flush(self: *Self) !void {
        for (self.pending_writes.items) |op| {
            try self.io_manager.queueWrite(op.file, op.data, op.offset, op.user_data);
        }
        
        _ = try self.io_manager.submit();
        self.pending_writes.clearRetainingCapacity();
    }
    
    /// Wait for all completions
    pub fn waitAll(self: *Self) ![]IoResult {
        const pending = self.io_manager.pendingCount();
        if (pending == 0) return &[_]IoResult{};
        
        return try self.io_manager.waitCompletions(pending);
    }
};

/// Check if io_uring is supported on this system
pub fn isIoUringSupported() bool {
    // Try to create a minimal ring
    const ring = linux.IoUring.init(1, .{}) catch {
        return false;
    };
    ring.deinit();
    return true;
}

/// Get recommended queue depth for this system
pub fn recommendedQueueDepth() u32 {
    // Get CPU count for sizing
    const cpu_count = std.Thread.getCpuCount() catch 4;
    
    // Recommended: 32-64 per CPU, capped at 4096
    return @min(@as(u32, @intCast(cpu_count)) * 64, 4096);
}

// Tests
test "async io manager initialization" {
    const allocator = std.testing.allocator;
    
    const manager = try AsyncIoManager.init(allocator, .{});
    defer manager.deinit();
    
    // May or may not be available depending on kernel
    _ = manager.available();
}

test "io_uring support check" {
    const supported = isIoUringSupported();
    // Just verify it doesn't crash
    _ = supported;
}

test "recommended queue depth" {
    const depth = recommendedQueueDepth();
    try std.testing.expect(depth >= 32);
    try std.testing.expect(depth <= 4096);
}

