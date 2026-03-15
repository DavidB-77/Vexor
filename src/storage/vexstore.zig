//! VexStore: WiscKey-style storage engine for VEXOR
//! Keys in LSM tree, values in append-only log
//!
//! Architecture:
//! - MemTable: In-memory sorted buffer for recent writes
//! - SSTable: On-disk sorted key->value_ptr tables
//! - Value Log: Append-only log for actual values
//! - WAL: Write-ahead log for crash recovery

const std = @import("std");
const async_io = @import("async_io.zig");

// ═══════════════════════════════════════════════════════════════════════════════
// COMMON TYPES
// ═══════════════════════════════════════════════════════════════════════════════

/// Pointer to value in the value log.
/// When segment mode is active, the offset encodes both segment_id and local offset:
///   offset = (segment_id << 32) | local_offset
/// Segment 0 = legacy single-file vlog (backward compatible)
pub const ValuePtr = struct {
    offset: u64,
    len: u32,

    /// Segment ID encoded in high 32 bits (0 = legacy single-file mode)
    pub fn segmentId(self: ValuePtr) u32 {
        return @intCast(self.offset >> 32);
    }

    /// Local offset within the segment (low 32 bits)
    pub fn localOffset(self: ValuePtr) u32 {
        return @truncate(self.offset);
    }

    /// Create a segmented ValuePtr
    pub fn segmented(segment_id: u32, local_offset: u32, length: u32) ValuePtr {
        return .{
            .offset = (@as(u64, segment_id) << 32) | @as(u64, local_offset),
            .len = length,
        };
    }

    /// Check if this pointer is in the legacy single-file mode
    pub fn isLegacy(self: ValuePtr) bool {
        return self.segmentId() == 0;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// MEMTABLE - In-memory sorted write buffer
// ═══════════════════════════════════════════════════════════════════════════════

/// MemTable entry storing key and value log pointer
pub const MemTableEntry = struct {
    key: [32]u8,
    value_ptr: ValuePtr,
    deleted: bool,
};

/// MemTable - sorted in-memory buffer for recent writes
/// Uses sorted array (simple, cache-friendly) - can upgrade to skiplist later
pub const MemTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(MemTableEntry),
    size_bytes: usize,
    max_size_bytes: usize,

    const Self = @This();

    /// Default MemTable size: 64MB
    pub const DEFAULT_MAX_SIZE: usize = 64 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, max_size_bytes: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(MemTableEntry).init(allocator),
            .size_bytes = 0,
            .max_size_bytes = max_size_bytes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    /// Insert or update a key in the MemTable
    pub fn put(self: *Self, key: [32]u8, value_ptr: ValuePtr) !void {
        const entry_size = 32 + @sizeOf(ValuePtr) + 1;

        // Binary search for existing key or insertion point
        const idx = self.findKeyIndex(key);

        if (idx < self.entries.items.len and std.mem.eql(u8, &self.entries.items[idx].key, &key)) {
            // Update existing entry
            self.entries.items[idx].value_ptr = value_ptr;
            self.entries.items[idx].deleted = false;
        } else {
            // Insert new entry at sorted position
            try self.entries.insert(idx, .{
                .key = key,
                .value_ptr = value_ptr,
                .deleted = false,
            });
            self.size_bytes += entry_size;
        }
    }

    /// Mark a key as deleted (tombstone)
    pub fn delete(self: *Self, key: [32]u8) !void {
        const idx = self.findKeyIndex(key);

        if (idx < self.entries.items.len and std.mem.eql(u8, &self.entries.items[idx].key, &key)) {
            // Mark existing entry as deleted
            self.entries.items[idx].deleted = true;
        } else {
            // Insert tombstone
            const entry_size = 32 + @sizeOf(ValuePtr) + 1;
            try self.entries.insert(idx, .{
                .key = key,
                .value_ptr = .{ .offset = 0, .len = 0 },
                .deleted = true,
            });
            self.size_bytes += entry_size;
        }
    }

    /// Get value pointer for a key (returns null if not found or deleted)
    pub fn get(self: *Self, key: [32]u8) ?ValuePtr {
        const idx = self.findKeyIndex(key);

        if (idx < self.entries.items.len and std.mem.eql(u8, &self.entries.items[idx].key, &key)) {
            const entry = self.entries.items[idx];
            if (entry.deleted) return null;
            return entry.value_ptr;
        }
        return null;
    }

    /// Check if key exists (even if deleted - for tombstone detection)
    pub fn contains(self: *Self, key: [32]u8) ?MemTableEntry {
        const idx = self.findKeyIndex(key);

        if (idx < self.entries.items.len and std.mem.eql(u8, &self.entries.items[idx].key, &key)) {
            return self.entries.items[idx];
        }
        return null;
    }

    /// Check if MemTable should be flushed
    pub fn shouldFlush(self: *Self) bool {
        return self.size_bytes >= self.max_size_bytes;
    }

    /// Get all entries in sorted order (for flushing to SSTable)
    pub fn getEntries(self: *Self) []const MemTableEntry {
        return self.entries.items;
    }

    /// Clear the MemTable after flush
    pub fn clear(self: *Self) void {
        self.entries.clearRetainingCapacity();
        self.size_bytes = 0;
    }

    /// Count of entries
    pub fn count(self: *Self) usize {
        return self.entries.items.len;
    }

    /// Binary search to find key index or insertion point
    fn findKeyIndex(self: *Self, key: [32]u8) usize {
        var left: usize = 0;
        var right: usize = self.entries.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = std.mem.order(u8, &self.entries.items[mid].key, &key);

            if (cmp == .lt) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// BLOOM FILTER - Probabilistic set membership test
// ═══════════════════════════════════════════════════════════════════════════════

/// Bloom filter for fast negative lookups
/// False positives are possible, false negatives are not
pub const BloomFilter = struct {
    bits: []u8,
    num_bits: usize,
    num_hashes: u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a bloom filter optimized for expected_items with target false positive rate
    /// Default: 1% false positive rate
    pub fn init(allocator: std.mem.Allocator, expected_items: usize) !Self {
        // Optimal bits = -n * ln(p) / (ln(2)^2) where p = 0.01 (1% FPR)
        // Simplified: ~10 bits per item for 1% FPR
        const bits_per_item: usize = 10;
        const num_bits = @max(64, expected_items * bits_per_item);
        const num_bytes = (num_bits + 7) / 8;

        // Optimal hash functions = (m/n) * ln(2) ≈ 7 for 10 bits/item
        const num_hashes: u8 = 7;

        const bits = try allocator.alloc(u8, num_bytes);
        @memset(bits, 0);

        return .{
            .bits = bits,
            .num_bits = num_bits,
            .num_hashes = num_hashes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bits);
    }

    /// Add a key to the bloom filter
    pub fn add(self: *Self, key: [32]u8) void {
        var i: u8 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const bit_pos = self.hash(key, i) % self.num_bits;
            const byte_pos = bit_pos / 8;
            const bit_offset: u3 = @intCast(bit_pos % 8);
            self.bits[byte_pos] |= @as(u8, 1) << bit_offset;
        }
    }

    /// Check if a key might be in the set
    /// Returns false = definitely not in set
    /// Returns true = probably in set (may be false positive)
    pub fn mayContain(self: *const Self, key: [32]u8) bool {
        var i: u8 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const bit_pos = self.hash(key, i) % self.num_bits;
            const byte_pos = bit_pos / 8;
            const bit_offset: u3 = @intCast(bit_pos % 8);
            if ((self.bits[byte_pos] & (@as(u8, 1) << bit_offset)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Hash function using FNV-1a with seed
    fn hash(self: *const Self, key: [32]u8, seed: u8) usize {
        _ = self;
        // FNV-1a hash
        var h: u64 = 14695981039346656037 +% @as(u64, seed) *% 31;
        for (key) |byte| {
            h ^= byte;
            h *%= 1099511628211;
        }
        return @intCast(h);
    }

    /// Serialize bloom filter to bytes
    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        // Format: [num_bits: u32][num_hashes: u8][bits...]
        const header_size = 4 + 1;
        const total = header_size + self.bits.len;
        const buf = try allocator.alloc(u8, total);

        std.mem.writeInt(u32, buf[0..4], @intCast(self.num_bits), .little);
        buf[4] = self.num_hashes;
        @memcpy(buf[5..], self.bits);

        return buf;
    }

    /// Deserialize bloom filter from bytes
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 5) return error.InvalidBloomFilter;

        const num_bits = std.mem.readInt(u32, data[0..4], .little);
        const num_hashes = data[4];
        const bits_data = data[5..];

        const bits = try allocator.alloc(u8, bits_data.len);
        @memcpy(bits, bits_data);

        return .{
            .bits = bits,
            .num_bits = num_bits,
            .num_hashes = num_hashes,
            .allocator = allocator,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// HOT CACHE - LRU cache for frequently accessed values
// ═══════════════════════════════════════════════════════════════════════════════

/// LRU Cache entry
pub const CacheEntry = struct {
    key: [32]u8,
    value: []u8,
    prev: ?*CacheEntry,
    next: ?*CacheEntry,
};

/// Simple LRU cache for hot account data
pub const HotCache = struct {
    allocator: std.mem.Allocator,
    lock: std.Thread.Mutex,
    map: std.AutoHashMap([32]u8, *CacheEntry),
    head: ?*CacheEntry, // Most recently used
    tail: ?*CacheEntry, // Least recently used
    size_bytes: usize,
    max_size_bytes: usize,
    hits: u64,
    misses: u64,

    const Self = @This();

    /// Default cache size: 128MB
    pub const DEFAULT_MAX_SIZE: usize = 128 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, max_size_bytes: usize) Self {
        return .{
            .allocator = allocator,
            .lock = .{},
            .map = std.AutoHashMap([32]u8, *CacheEntry).init(allocator),
            .head = null,
            .tail = null,
            .size_bytes = 0,
            .max_size_bytes = max_size_bytes,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        // Free all entries
        var current = self.head;
        while (current) |entry| {
            const next = entry.next;
            self.allocator.free(entry.value);
            self.allocator.destroy(entry);
            current = next;
        }
        self.map.deinit();
    }

    /// Get value from cache (moves to front if found)
    /// Returns a duplicate of the value, caller must free.
    pub fn get(self: *Self, allocator: std.mem.Allocator, key: [32]u8) !?[]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.get(key)) |entry| {
            self.hits += 1;
            self.moveToFront(entry);
            return try allocator.dupe(u8, entry.value);
        }
        self.misses += 1;
        return null;
    }

    /// Put value in cache (evicts LRU entries if needed)
    pub fn put(self: *Self, key: [32]u8, value: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Check if already exists
        if (self.map.get(key)) |entry| {
            // Update existing entry
            self.size_bytes -= entry.value.len;
            self.allocator.free(entry.value);
            entry.value = try self.allocator.dupe(u8, value);
            self.size_bytes += value.len;
            self.moveToFront(entry);
            return;
        }

        // Evict LRU entries if needed
        while (self.size_bytes + value.len > self.max_size_bytes and self.tail != null) {
            self.evictLRU();
        }

        // Create new entry
        const entry = try self.allocator.create(CacheEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = key,
            .value = try self.allocator.dupe(u8, value),
            .prev = null,
            .next = self.head,
        };

        // Link to front
        if (self.head) |head| {
            head.prev = entry;
        }
        self.head = entry;
        if (self.tail == null) {
            self.tail = entry;
        }

        try self.map.put(key, entry);
        self.size_bytes += value.len;
    }

    /// Remove entry from cache
    pub fn remove(self: *Self, key: [32]u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.fetchRemove(key)) |kv| {
            const entry = kv.value;
            self.unlinkEntry(entry);
            self.size_bytes -= entry.value.len;
            self.allocator.free(entry.value);
            self.allocator.destroy(entry);
        }
    }

    fn moveToFront(self: *Self, entry: *CacheEntry) void {
        if (self.head == entry) return; // Already at front

        self.unlinkEntry(entry);

        entry.prev = null;
        entry.next = self.head;
        if (self.head) |head| {
            head.prev = entry;
        }
        self.head = entry;
    }

    fn unlinkEntry(self: *Self, entry: *CacheEntry) void {
        if (entry.prev) |prev| {
            prev.next = entry.next;
        } else {
            self.head = entry.next;
        }
        if (entry.next) |next| {
            next.prev = entry.prev;
        } else {
            self.tail = entry.prev;
        }
    }

    fn evictLRU(self: *Self) void {
        if (self.tail) |entry| {
            _ = self.map.remove(entry.key);
            self.unlinkEntry(entry);
            self.size_bytes -= entry.value.len;
            self.allocator.free(entry.value);
            self.allocator.destroy(entry);
        }
    }

    /// Get cache stats
    pub fn getStats(self: *const Self) struct { hits: u64, misses: u64, size_bytes: usize, entry_count: usize } {
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .size_bytes = self.size_bytes,
            .entry_count = self.map.count(),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// SSTABLE - Sorted String Table (on-disk sorted key->value_ptr)
// ═══════════════════════════════════════════════════════════════════════════════

/// Metadata for a single SSTable file
pub const SSTableMeta = struct {
    /// Unique ID for this SSTable
    id: u64,
    /// Level in LSM tree (0 = newest, higher = older/merged)
    level: u8,
    /// Number of entries in this SSTable
    entry_count: u32,
    /// Minimum key (for range queries and compaction)
    min_key: [32]u8,
    /// Maximum key (for range queries and compaction)
    max_key: [32]u8,
    /// File size in bytes
    file_size: u64,
    /// Sequence number when this SSTable was created
    sequence: u64,
    /// Bloom filter for fast negative lookups (owned, must be freed)
    bloom: ?*BloomFilter,
    /// Allocator for bloom filter cleanup
    allocator: ?std.mem.Allocator,

    /// Check if a key might be in this SSTable using bloom filter first
    pub fn mayContain(self: *const SSTableMeta, key: [32]u8) bool {
        // Fast path: bloom filter says definitely not here
        if (self.bloom) |bf| {
            if (!bf.mayContain(key)) {
                return false;
            }
        }
        // Fall back to key range check
        const cmp_min = std.mem.order(u8, &key, &self.min_key);
        const cmp_max = std.mem.order(u8, &key, &self.max_key);
        return (cmp_min == .gt or cmp_min == .eq) and (cmp_max == .lt or cmp_max == .eq);
    }

    /// Get filename for this SSTable
    pub fn getFilename(self: *const SSTableMeta, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "L{d}-{d:0>8}.sst", .{ self.level, self.id });
    }

    /// Clean up bloom filter memory
    pub fn deinit(self: *SSTableMeta) void {
        if (self.bloom) |bf| {
            if (self.allocator) |alloc| {
                bf.deinit();
                alloc.destroy(bf);
            }
        }
        self.bloom = null;
    }
};

/// SSTable manager - tracks all SSTables across levels
pub const SSTableManager = struct {
    allocator: std.mem.Allocator,
    /// SSTables organized by level (index = level)
    levels: [MAX_LEVELS]std.ArrayList(SSTableMeta),
    /// Next SSTable ID
    next_id: u64,
    /// Next sequence number
    next_sequence: u64,

    const Self = @This();
    pub const MAX_LEVELS: usize = 7; // L0-L6

    /// L0 size threshold before compaction (number of SSTables)
    pub const L0_COMPACTION_TRIGGER: usize = 4;
    /// Size ratio between levels (L(n+1) = L(n) * LEVEL_SIZE_RATIO)
    pub const LEVEL_SIZE_RATIO: usize = 10;

    pub fn init(allocator: std.mem.Allocator) Self {
        var levels: [MAX_LEVELS]std.ArrayList(SSTableMeta) = undefined;
        for (&levels) |*level| {
            level.* = std.ArrayList(SSTableMeta).init(allocator);
        }
        return .{
            .allocator = allocator,
            .levels = levels,
            .next_id = 1,
            .next_sequence = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        for (&self.levels) |*level| {
            // Clean up bloom filters
            for (level.items) |*sst| {
                sst.deinit();
            }
            level.deinit();
        }
    }

    /// Add a new SSTable at the specified level with optional bloom filter
    pub fn addSSTable(self: *Self, level: u8, entry_count: u32, min_key: [32]u8, max_key: [32]u8, file_size: u64) !SSTableMeta {
        return self.addSSTableWithBloom(level, entry_count, min_key, max_key, file_size, null);
    }

    /// Add a new SSTable with a bloom filter
    pub fn addSSTableWithBloom(self: *Self, level: u8, entry_count: u32, min_key: [32]u8, max_key: [32]u8, file_size: u64, bloom: ?*BloomFilter) !SSTableMeta {
        const meta = SSTableMeta{
            .id = self.next_id,
            .level = level,
            .entry_count = entry_count,
            .min_key = min_key,
            .max_key = max_key,
            .file_size = file_size,
            .sequence = self.next_sequence,
            .bloom = bloom,
            .allocator = if (bloom != null) self.allocator else null,
        };
        self.next_id += 1;
        self.next_sequence += 1;

        try self.levels[level].append(meta);
        return meta;
    }

    /// Remove an SSTable from tracking (after compaction)
    pub fn removeSSTable(self: *Self, level: u8, id: u64) void {
        const level_list = &self.levels[level];
        for (level_list.items, 0..) |*sst, i| {
            if (sst.id == id) {
                sst.deinit(); // Clean up bloom filter
                _ = level_list.orderedRemove(i);
                return;
            }
        }
    }

    /// Get all SSTables at a level
    pub fn getLevel(self: *Self, level: u8) []const SSTableMeta {
        return self.levels[level].items;
    }

    /// Count of SSTables at a level
    pub fn levelCount(self: *Self, level: u8) usize {
        return self.levels[level].items.len;
    }

    /// Check if L0 needs compaction
    pub fn needsL0Compaction(self: *Self) bool {
        return self.levels[0].items.len >= L0_COMPACTION_TRIGGER;
    }

    /// Get total SSTable count across all levels
    pub fn totalCount(self: *Self) usize {
        var total: usize = 0;
        for (self.levels) |level| {
            total += level.items.len;
        }
        return total;
    }

    /// Find SSTables that may contain a key (for reads)
    /// Returns SSTables in order: L0 (newest first by sequence), then L1+
    pub fn findSSTables(self: *Self, key: [32]u8, result: *std.ArrayList(SSTableMeta)) !void {
        // L0: Check all (may overlap), sort by sequence descending
        var l0_matches = std.ArrayList(SSTableMeta).init(self.allocator);
        defer l0_matches.deinit();

        for (self.levels[0].items) |sst| {
            if (sst.mayContain(key)) {
                try l0_matches.append(sst);
            }
        }

        // Sort L0 by sequence descending (newest first)
        std.mem.sort(SSTableMeta, l0_matches.items, {}, struct {
            fn lessThan(_: void, a: SSTableMeta, b: SSTableMeta) bool {
                return a.sequence > b.sequence;
            }
        }.lessThan);

        try result.appendSlice(l0_matches.items);

        // L1+: Check each level (non-overlapping within level)
        for (1..MAX_LEVELS) |level| {
            for (self.levels[level].items) |sst| {
                if (sst.mayContain(key)) {
                    try result.append(sst);
                    break; // Only one SSTable per level can contain the key
                }
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// VALUE LOG SEGMENT - Individual segment of the value log
// ═══════════════════════════════════════════════════════════════════════════════

/// Extended ValuePtr that includes segment ID
pub const SegmentedValuePtr = struct {
    segment_id: u32,
    offset: u64,
    len: u32,

    /// Convert to legacy ValuePtr (for backward compat, assumes segment 0)
    pub fn toLegacy(self: SegmentedValuePtr) ValuePtr {
        return .{ .offset = self.offset, .len = self.len };
    }
};

/// Value log segment metadata
pub const VlogSegment = struct {
    id: u32,
    file: std.fs.File,
    size: u64,
    live_bytes: u64,
    dead_bytes: u64,

    /// Maximum segment size before rolling to new segment (256MB)
    pub const MAX_SIZE: u64 = 256 * 1024 * 1024;

    pub fn init(id: u32, file: std.fs.File, size: u64) VlogSegment {
        return .{
            .id = id,
            .file = file,
            .size = size,
            .live_bytes = size,
            .dead_bytes = 0,
        };
    }

    pub fn close(self: *VlogSegment) void {
        self.file.close();
    }

    /// Check if segment should be garbage collected (>50% dead)
    pub fn needsGC(self: *const VlogSegment) bool {
        if (self.live_bytes + self.dead_bytes == 0) return false;
        return self.dead_bytes * 2 > self.live_bytes + self.dead_bytes;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// VEXSTORE - Main storage engine
// ═══════════════════════════════════════════════════════════════════════════════

pub const VexStore = struct {
    allocator: std.mem.Allocator,
    lock: std.Thread.RwLock, // Protects all state except background thread signaling
    dir: std.fs.Dir,
    owns_dir: bool,
    vlog: std.fs.File, // Current active segment (legacy single-file mode)
    wal: std.fs.File,
    write_offset: u64,

    // Segmented value log
    vlog_segments: std.ArrayList(VlogSegment),
    active_segment_id: u32,
    next_segment_id: u32,

    // MemTable for recent writes (checked first on reads)
    memtable: MemTable,

    // Hot cache for frequently accessed values
    hot_cache: HotCache,

    // SSTable manager for multi-level LSM tree
    sstables: SSTableManager,

    // In-memory index (merged view of all SSTables for fast lookup)
    // TODO: Replace with per-SSTable lookups + bloom filters for large datasets
    index: std.AutoHashMap([32]u8, ValuePtr),

    current_sst: ?[]u8,
    deleted_count: u64,
    deleted_bytes: u64,
    live_bytes: u64,
    compaction_vlog: ?std.fs.File,
    compaction_index: ?std.AutoHashMap([32]u8, ValuePtr),
    compaction_keys: ?[][32]u8,
    compaction_pos: usize,
    compaction_offset: u64,

    // Stats
    memtable_hits: u64,
    index_hits: u64,
    l0_sstable_count: u64,
    bloom_filter_hits: u64,
    bloom_filter_misses: u64,
    cache_hits: u64,
    cache_misses: u64,
    segment_rolls: u64,

    // Background compaction
    compaction_thread: ?std.Thread,
    compaction_mutex: std.Thread.Mutex,
    compaction_cond: std.Thread.Condition,
    compaction_pending: bool,
    shutdown_requested: bool,

    // Async I/O manager (optional, for io_uring acceleration)
    async_io_manager: ?*async_io.AsyncIoManager,

    const Self = @This();
    const WalOp = enum(u8) { put = 1, delete = 2 };
    const crc32 = std.hash.crc.Crc32;

    pub fn init(allocator: std.mem.Allocator, path: []const u8, async_io_manager: ?*async_io.AsyncIoManager) !*Self {
        try std.fs.cwd().makePath(path);
        const dir = try std.fs.cwd().openDir(path, .{});
        return initWithDirInternal(allocator, dir, true, MemTable.DEFAULT_MAX_SIZE, async_io_manager);
    }

    pub fn initWithMemTableSize(allocator: std.mem.Allocator, path: []const u8, memtable_size: usize, async_io_manager: ?*async_io.AsyncIoManager) !*Self {
        try std.fs.cwd().makePath(path);
        const dir = try std.fs.cwd().openDir(path, .{});
        return initWithDirInternal(allocator, dir, true, memtable_size, async_io_manager);
    }

    pub fn initWithDir(allocator: std.mem.Allocator, dir: std.fs.Dir, async_io_manager: ?*async_io.AsyncIoManager) !*Self {
        return initWithDirInternal(allocator, dir, false, MemTable.DEFAULT_MAX_SIZE, async_io_manager);
    }

    fn initWithDirInternal(allocator: std.mem.Allocator, dir: std.fs.Dir, owns_dir: bool, memtable_size: usize, async_io_manager: ?*async_io.AsyncIoManager) !*Self {
        const store = try allocator.create(Self);
        errdefer allocator.destroy(store);

        const vlog = try dir.createFile("vlog.bin", .{ .read = true, .truncate = false });
        const wal = try dir.createFile("wal.log", .{ .read = true, .truncate = false });
        const end = try vlog.getEndPos();

        store.* = .{
            .allocator = allocator,
            .lock = .{},
            .dir = dir,
            .owns_dir = owns_dir,
            .vlog = vlog,
            .wal = wal,
            .write_offset = end,
            .vlog_segments = std.ArrayList(VlogSegment).init(allocator),
            .active_segment_id = 0,
            .next_segment_id = 1,
            .memtable = MemTable.init(allocator, memtable_size),
            .hot_cache = HotCache.init(allocator, HotCache.DEFAULT_MAX_SIZE),
            .sstables = SSTableManager.init(allocator),
            .index = std.AutoHashMap([32]u8, ValuePtr).init(allocator),
            .current_sst = null,
            .deleted_count = 0,
            .deleted_bytes = 0,
            .live_bytes = 0,
            .compaction_vlog = null,
            .compaction_index = null,
            .compaction_keys = null,
            .compaction_pos = 0,
            .compaction_offset = 0,
            .memtable_hits = 0,
            .index_hits = 0,
            .l0_sstable_count = 0,
            .bloom_filter_hits = 0,
            .bloom_filter_misses = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .segment_rolls = 0,
            .compaction_thread = null,
            .compaction_mutex = .{},
            .compaction_cond = .{},
            .compaction_pending = false,
            .shutdown_requested = false,
            .async_io_manager = async_io_manager,
        };

        try store.loadManifest();
        try store.replayWal();

        return store;
    }

    /// Start the background compaction thread
    pub fn startBackgroundCompaction(self: *Self) !void {
        if (self.compaction_thread != null) return; // Already running

        self.compaction_thread = try std.Thread.spawn(.{}, compactionWorker, .{self});
    }

    /// Stop the background compaction thread
    pub fn stopBackgroundCompaction(self: *Self) void {
        if (self.compaction_thread == null) return;

        // Signal shutdown
        {
            self.compaction_mutex.lock();
            defer self.compaction_mutex.unlock();
            self.shutdown_requested = true;
            self.compaction_cond.signal();
        }

        // Wait for thread to finish
        if (self.compaction_thread) |thread| {
            thread.join();
        }
        self.compaction_thread = null;
        self.shutdown_requested = false;
    }

    /// Signal that compaction may be needed
    fn signalCompaction(self: *Self) void {
        self.compaction_mutex.lock();
        defer self.compaction_mutex.unlock();
        self.compaction_pending = true;
        self.compaction_cond.signal();
    }

    /// Background compaction worker thread
    fn compactionWorker(self: *Self) void {
        while (true) {
            // Wait for work or shutdown
            {
                self.compaction_mutex.lock();
                defer self.compaction_mutex.unlock();

                while (!self.compaction_pending and !self.shutdown_requested) {
                    self.compaction_cond.wait(&self.compaction_mutex);
                }

                if (self.shutdown_requested) {
                    return;
                }

                self.compaction_pending = false;
            }

            // Perform compaction outside the lock
            self.performBackgroundCompaction();
        }
    }

    /// Perform the actual compaction work
    fn performBackgroundCompaction(self: *Self) void {
        // Check if L0 compaction is needed
        if (self.sstables.needsL0Compaction()) {
            self.compactL0ToL1() catch |err| {
                std.log.err("[VexStore] Background L0 compaction failed: {}", .{err});
            };
        }

        // Check segment-level GC first (compacts individual 256MB segments)
        if (self.findDirtiestSegment()) |_| {
            self.compactDirtiestSegment() catch |err| {
                std.log.err("[VexStore] Segment GC failed: {}", .{err});
            };
        }

        // Fall back to full value log compaction if needed
        if (self.needsValueLogCompaction()) {
            // Process up to 10000 entries per round to avoid blocking too long
            _ = self.compactValueLogIncremental(10000) catch |err| {
                std.log.err("[VexStore] Background value log compaction failed: {}", .{err});
            };
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SEGMENT MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// Roll to a new active segment when current exceeds 256MB.
    /// Called from put() when write_offset within active segment passes MAX_SIZE.
    fn rollActiveSegment(self: *Self) !void {
        const new_id = self.next_segment_id;
        self.next_segment_id += 1;

        // Create new segment file
        const seg_name = try std.fmt.allocPrint(self.allocator, "vlog-{d:0>6}.seg", .{new_id});
        defer self.allocator.free(seg_name);
        const seg_file = try self.dir.createFile(seg_name, .{ .read = true, .truncate = true });

        // Record the old active segment in the segments list
        const old_seg = VlogSegment.init(
            self.active_segment_id,
            self.vlog,
            self.write_offset,
        );
        try self.vlog_segments.append(old_seg);

        // Switch active to new segment
        self.vlog = seg_file;
        self.active_segment_id = new_id;
        self.write_offset = 0;
        self.segment_rolls += 1;

        std.log.info("[VexStore] Rolled to new segment {d} (total segments: {d})", .{
            new_id,
            self.vlog_segments.items.len + 1,
        });
    }

    /// Find the dirtiest segment that qualifies for GC (>50% dead bytes)
    fn findDirtiestSegment(self: *Self) ?usize {
        var worst_idx: ?usize = null;
        var worst_ratio: f64 = 0.0;

        for (self.vlog_segments.items, 0..) |seg, i| {
            if (seg.needsGC()) {
                const total = seg.live_bytes + seg.dead_bytes;
                const ratio = if (total > 0)
                    @as(f64, @floatFromInt(seg.dead_bytes)) / @as(f64, @floatFromInt(total))
                else
                    0.0;
                if (ratio > worst_ratio) {
                    worst_ratio = ratio;
                    worst_idx = i;
                }
            }
        }
        return worst_idx;
    }

    /// Compact a single dirty segment: read live values, write to active segment,
    /// update index pointers, delete old segment file.
    /// This does NOT block concurrent reads because:
    /// 1. We read from old segment under shared lock
    /// 2. We write to active segment (new file)
    /// 3. We swap index pointers under exclusive lock (brief)
    /// 4. We delete old segment file after all pointers are updated
    fn compactDirtiestSegment(self: *Self) !void {
        // Find the dirtiest segment under shared lock
        var target_seg_id: u32 = undefined;
        var target_idx: usize = undefined;
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            const idx = self.findDirtiestSegment() orelse return;
            target_idx = idx;
            target_seg_id = self.vlog_segments.items[idx].id;
        }

        // Phase 1: Find all index keys pointing to this segment (shared lock)
        var keys_in_segment = std.ArrayList([32]u8).init(self.allocator);
        defer keys_in_segment.deinit();
        var ptrs_in_segment = std.ArrayList(ValuePtr).init(self.allocator);
        defer ptrs_in_segment.deinit();

        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            var iter = self.index.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.segmentId() == target_seg_id) {
                    try keys_in_segment.append(entry.key_ptr.*);
                    try ptrs_in_segment.append(entry.value_ptr.*);
                }
            }
        }

        if (keys_in_segment.items.len == 0) {
            // Segment has no live entries — just delete it
            self.lock.lock();
            defer self.lock.unlock();
            self.removeSegmentById(target_seg_id);
            return;
        }

        // Phase 2: Read live values and write to active segment (no lock on read, exclusive on write)
        var new_ptrs = std.ArrayList(ValuePtr).init(self.allocator);
        defer new_ptrs.deinit();

        // Read values from the old segment (thread-safe pread)
        var read_values = std.ArrayList([]u8).init(self.allocator);
        defer {
            for (read_values.items) |v| self.allocator.free(v);
            read_values.deinit();
        }
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            for (ptrs_in_segment.items) |ptr| {
                const value = try self.readValueFromLog(ptr);
                try read_values.append(value);
            }
        }

        // Phase 3: Write to active segment and update index (exclusive lock)
        {
            self.lock.lock();
            defer self.lock.unlock();

            for (keys_in_segment.items, 0..) |key, i| {
                const value = read_values.items[i];

                // Write value to active segment
                _ = try self.vlog.pwrite(value, self.write_offset);
                const new_ptr = if (self.active_segment_id == 0)
                    ValuePtr{ .offset = self.write_offset, .len = @intCast(value.len) }
                else
                    ValuePtr.segmented(self.active_segment_id, @intCast(self.write_offset), @intCast(value.len));

                self.write_offset += value.len;
                try new_ptrs.append(new_ptr);

                // Update index to point to new location
                try self.index.put(key, new_ptr);
            }

            // Remove the old segment
            self.removeSegmentById(target_seg_id);

            std.log.info("[VexStore] Segment GC: compacted segment {d}, relocated {d} live values", .{
                target_seg_id,
                keys_in_segment.items.len,
            });
        }
    }

    /// Remove a segment by ID: close file handle, delete file, remove from list
    fn removeSegmentById(self: *Self, seg_id: u32) void {
        for (self.vlog_segments.items, 0..) |*seg, i| {
            if (seg.id == seg_id) {
                seg.close();
                // Delete segment file
                const seg_name = std.fmt.allocPrint(self.allocator, "vlog-{d:0>6}.seg", .{seg_id}) catch return;
                defer self.allocator.free(seg_name);
                self.dir.deleteFile(seg_name) catch {};
                _ = self.vlog_segments.orderedRemove(i);
                return;
            }
        }
    }

    /// Mark bytes as dead in the appropriate segment's tracking
    fn markSegmentDead(self: *Self, ptr: ValuePtr) void {
        const seg_id = ptr.segmentId();
        if (seg_id == 0) return; // Legacy mode — tracked via global deleted_bytes
        for (self.vlog_segments.items) |*seg| {
            if (seg.id == seg_id) {
                seg.dead_bytes += ptr.len;
                if (seg.live_bytes >= ptr.len) {
                    seg.live_bytes -= ptr.len;
                } else {
                    seg.live_bytes = 0;
                }
                return;
            }
        }
    }

    /// Check if value log compaction is needed (>50% dead bytes)
    fn needsValueLogCompaction(self: *Self) bool {
        const total = self.live_bytes + self.deleted_bytes;
        if (total == 0) return false;
        return self.deleted_bytes * 2 > total;
    }

    pub fn deinit(self: *Self) void {
        // Stop background compaction thread first
        self.stopBackgroundCompaction();

        self.vlog.close();
        self.wal.close();

        // Close all value log segments
        for (self.vlog_segments.items) |*seg| {
            seg.close();
        }
        self.vlog_segments.deinit();

        if (self.owns_dir) {
            self.dir.close();
        }
        self.memtable.deinit();
        self.hot_cache.deinit();
        self.sstables.deinit();
        self.index.deinit();
        if (self.current_sst) |name| {
            self.allocator.free(name);
        }
        if (self.compaction_vlog) |*file| {
            file.close();
        }
        if (self.compaction_index) |*map| {
            map.deinit();
        }
        if (self.compaction_keys) |keys| {
            self.allocator.free(keys);
        }
        self.allocator.destroy(self);
    }

    pub fn put(self: *Self, key: [32]u8, value: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Invalidate hot cache entry
        self.hot_cache.remove(key);

        // 1. Write to WAL for durability
        try self.appendWal(.put, key, value);

        // 2. Check if active segment needs rolling (256MB max per segment)
        if (self.active_segment_id > 0 and self.write_offset + value.len > VlogSegment.MAX_SIZE) {
            try self.rollActiveSegment();
        }

        // 3. Append value to value log (pwrite for thread safety)
        _ = try self.vlog.pwrite(value, self.write_offset);

        // Track if this overwrites an existing value
        const old_ptr = self.memtable.get(key) orelse self.index.get(key);
        if (old_ptr) |ptr| {
            self.deleted_bytes += ptr.len;
            self.live_bytes -= ptr.len;
            // Track dead bytes per segment for segment-level GC
            self.markSegmentDead(ptr);
        }

        // 4. Create ValuePtr (segment-aware if in segment mode)
        const ptr = if (self.active_segment_id == 0)
            ValuePtr{ .offset = self.write_offset, .len = @intCast(value.len) }
        else
            ValuePtr.segmented(self.active_segment_id, @intCast(self.write_offset), @intCast(value.len));

        // 5. Insert into MemTable (not directly into index)
        try self.memtable.put(key, ptr);

        self.write_offset += value.len;
        self.live_bytes += value.len;

        // 6. Auto-flush MemTable to SSTable if full
        if (self.memtable.shouldFlush()) {
            try self.flushMemTable();
        }
    }

    /// Fast bulk put - bypasses MemTable, writes directly to index
    /// Use this during snapshot loading for maximum performance
    /// Does NOT write to WAL (caller should ensure data is recoverable)
    pub fn putBulk(self: *Self, key: [32]u8, value: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Append value to value log (pwrite for thread safety)
        _ = try self.vlog.pwrite(value, self.write_offset);

        // Track if this overwrites an existing value
        if (self.index.get(key)) |old_ptr| {
            self.deleted_bytes += old_ptr.len;
            self.live_bytes -= old_ptr.len;
        }

        const ptr = ValuePtr{
            .offset = self.write_offset,
            .len = @intCast(value.len),
        };

        // Write directly to hash index (O(1) vs O(n) for MemTable)
        try self.index.put(key, ptr);

        self.write_offset += value.len;
        self.live_bytes += value.len;
    }

    /// Ensure index has capacity for expected number of entries (call before bulk loading)
    pub fn ensureIndexCapacity(self: *Self, count: u32) !void {
        try self.index.ensureTotalCapacity(count);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SNAPSHOT API - Deterministic iteration for snapshot generation
    // ═══════════════════════════════════════════════════════════════════════════════

    /// Snapshot iterator for deterministic key iteration
    /// Keys are sorted for reproducible snapshot generation
    pub const SnapshotIterator = struct {
        store: *Self,
        sorted_keys: [][32]u8,
        position: usize,

        /// Get next key-value pair, returns null when exhausted
        pub fn next(self: *SnapshotIterator) !?struct { key: [32]u8, value: []u8 } {
            if (self.position >= self.sorted_keys.len) {
                return null;
            }

            const key = self.sorted_keys[self.position];
            self.position += 1;

            // Get value from store
            const value = try self.store.get(key) orelse return null;
            return .{ .key = key, .value = value };
        }

        /// Get total number of keys
        pub fn count(self: *const SnapshotIterator) usize {
            return self.sorted_keys.len;
        }

        /// Get current progress
        pub fn progress(self: *const SnapshotIterator) struct { current: usize, total: usize } {
            return .{ .current = self.position, .total = self.sorted_keys.len };
        }

        /// Reset iterator to beginning
        pub fn reset(self: *SnapshotIterator) void {
            self.position = 0;
        }

        /// Clean up resources
        pub fn deinit(self: *SnapshotIterator) void {
            self.store.allocator.free(self.sorted_keys);
        }
    };

    /// Create a snapshot iterator for deterministic iteration over all keys
    /// The iterator provides keys in sorted order for reproducible snapshots
    pub fn createSnapshotIterator(self: *Self) !SnapshotIterator {
        self.lock.lock();
        defer self.lock.unlock();
        // Flush MemTable to ensure all data is in index
        try self.flushMemTable();

        // Collect all keys from index
        const count = self.index.count();
        const keys = try self.allocator.alloc([32]u8, count);
        errdefer self.allocator.free(keys);

        var iter = self.index.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }

        // Sort keys for deterministic iteration
        std.mem.sort([32]u8, keys, {}, struct {
            fn lessThan(_: void, a: [32]u8, b: [32]u8) bool {
                return std.mem.order(u8, &a, &b) == .lt;
            }
        }.lessThan);

        return .{
            .store = self,
            .sorted_keys = keys,
            .position = 0,
        };
    }

    /// Get total number of accounts in the store
    pub fn accountCount(self: *Self) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.index.count() + self.memtable.count();
    }

    /// Flush MemTable to a new L0 SSTable
    fn flushMemTable(self: *Self) !void {
        const entries = self.memtable.getEntries();
        if (entries.len == 0) return;

        // Find min/max keys (entries are sorted)
        const min_key = entries[0].key;
        const max_key = entries[entries.len - 1].key;

        // Create bloom filter for this SSTable
        const bloom = try self.allocator.create(BloomFilter);
        errdefer self.allocator.destroy(bloom);
        bloom.* = try BloomFilter.init(self.allocator, entries.len);

        // Also merge into in-memory index for fast lookups
        for (entries) |entry| {
            if (entry.deleted) {
                _ = self.index.remove(entry.key);
            } else {
                try self.index.put(entry.key, entry.value_ptr);
                // Add to bloom filter
                bloom.add(entry.key);
            }
        }

        // Write new L0 SSTable to disk
        const file_size = try self.writeL0SSTable(entries);

        // Register the SSTable with its bloom filter
        _ = try self.sstables.addSSTableWithBloom(0, @intCast(entries.len), min_key, max_key, file_size, bloom);
        self.l0_sstable_count = self.sstables.levelCount(0);

        // Clear MemTable
        self.memtable.clear();

        // Signal background compaction if L0 is getting full
        if (self.sstables.needsL0Compaction()) {
            if (self.compaction_thread != null) {
                // Background thread running - signal it
                self.signalCompaction();
            } else {
                // No background thread - do inline compaction
                try self.compactL0ToL1();
            }
        }
    }

    /// Write a new L0 SSTable file from MemTable entries
    fn writeL0SSTable(self: *Self, entries: []const MemTableEntry) !u64 {
        const sst_id = self.sstables.next_id;
        const filename = try std.fmt.allocPrint(self.allocator, "L0-{d:0>8}.sst", .{sst_id});
        defer self.allocator.free(filename);

        var file = try self.dir.createFile(filename, .{ .read = true, .truncate = true });
        defer file.close();

        // Async path using io_uring
        if (self.async_io_manager) |aio| {
            if (aio.available()) {
                const count: u32 = @intCast(entries.len);
                // Estimate size: header + entries * 48
                const total_size = 4 + entries.len * 48;
                const buffer = try self.allocator.alloc(u8, total_size);
                defer self.allocator.free(buffer);

                std.mem.writeInt(u32, buffer[0..4], count, .little);
                var offset: usize = 4;
                for (entries) |entry| {
                    if (entry.deleted) continue;

                    @memcpy(buffer[offset..][0..32], &entry.key);
                    std.mem.writeInt(u64, buffer[offset + 32 ..][0..8], entry.value_ptr.offset, .little);
                    std.mem.writeInt(u32, buffer[offset + 40 ..][0..4], entry.value_ptr.len, .little);
                    const checksum = computeSstChecksum(buffer[offset..][0..44]);
                    std.mem.writeInt(u32, buffer[offset + 44 ..][0..4], checksum, .little);
                    offset += 48;
                }

                // Submit single write for efficiency
                const id = try aio.queueWrite(file, buffer[0..offset], 0, 0);
                _ = try aio.submit();
                _ = try aio.waitFor(id);

                try file.sync();
                return try file.getEndPos();
            }
        }

        // Write header: entry count
        const count: u32 = @intCast(entries.len);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, count, .little);
        try file.writeAll(&header);

        // Write entries (sorted by key)
        for (entries) |entry| {
            if (entry.deleted) continue;

            var entry_buf: [32 + 8 + 4 + 4]u8 = undefined;
            @memcpy(entry_buf[0..32], &entry.key);
            std.mem.writeInt(u64, entry_buf[32..][0..8], entry.value_ptr.offset, .little);
            std.mem.writeInt(u32, entry_buf[40..][0..4], entry.value_ptr.len, .little);
            const checksum = computeSstChecksum(entry_buf[0..44]);
            std.mem.writeInt(u32, entry_buf[44..][0..4], checksum, .little);
            try file.writeAll(&entry_buf);
        }

        try file.sync();
        return try file.getEndPos();
    }

    /// Compact L0 SSTables into L1
    /// L0 files may overlap, L1 files are non-overlapping
    fn compactL0ToL1(self: *Self) !void {
        const l0_tables = self.sstables.getLevel(0);
        if (l0_tables.len == 0) return;

        // For simplicity, just flush the merged index to legacy SST for now
        // Full L0->L1 compaction would read all L0 files and merge-sort them
        try self.flushSst();

        // Clear L0 table tracking (they're now merged into index)
        while (self.sstables.levelCount(0) > 0) {
            const sst = self.sstables.levels[0].items[0];
            // Delete the L0 file
            const filename = try std.fmt.allocPrint(self.allocator, "L0-{d:0>8}.sst", .{sst.id});
            defer self.allocator.free(filename);
            self.dir.deleteFile(filename) catch {};
            self.sstables.removeSSTable(0, sst.id);
        }

        self.l0_sstable_count = 0;
    }

    pub fn get(self: *Self, key: [32]u8) !?[]u8 {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        // 0. Check hot cache first (fastest path)
        if (try self.hot_cache.get(self.allocator, key)) |cached| {
            return cached;
        }

        // 1. Check MemTable (most recent writes)
        if (self.memtable.contains(key)) |entry| {
            if (entry.deleted) {
                return null;
            }
            self.memtable_hits += 1;
            const value = try self.readValueFromLog(entry.value_ptr);
            // Add to hot cache for future reads
            self.hot_cache.put(key, value) catch {};
            return value;
        }

        // 2. Check bloom filters on L0 SSTables (fast negative lookup)
        var might_exist = false;
        for (self.sstables.levels[0].items) |sst| {
            if (sst.bloom) |bf| {
                if (bf.mayContain(key)) {
                    might_exist = true;
                    self.bloom_filter_hits += 1;
                    break;
                }
            } else {
                might_exist = true;
                break;
            }
        }

        if (!might_exist and self.sstables.levelCount(0) > 0) {
            self.bloom_filter_misses += 1;
        }

        // 3. Check in-memory index
        const ptr = self.index.get(key) orelse return null;
        self.index_hits += 1;
        const value = try self.readValueFromLog(ptr);
        // Add to hot cache for future reads
        self.hot_cache.put(key, value) catch {};
        return value;
    }

    /// Read value from value log given a pointer.
    /// Segment-aware: resolves the correct file based on segment_id in ValuePtr.
    /// Uses pread (atomic positioned read) for thread safety — no seek needed.
    /// Optionally uses io_uring for non-blocking reads when AsyncIoManager is available.
    fn readValueFromLog(self: *Self, ptr: ValuePtr) ![]u8 {
        const len: usize = @intCast(ptr.len);
        const buf = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(buf);

        // Resolve the correct file handle based on segment ID
        const seg_id = ptr.segmentId();
        const read_file: std.fs.File = if (seg_id == 0)
            self.vlog // Legacy single-file mode
        else blk: {
            // Segment mode: find the segment file
            for (self.vlog_segments.items) |seg| {
                if (seg.id == seg_id) break :blk seg.file;
            }
            return error.SegmentNotFound;
        };
        const read_offset: u64 = if (seg_id == 0) ptr.offset else @as(u64, ptr.localOffset());

        // Fast path: io_uring async read (non-blocking)
        if (self.async_io_manager) |aio| {
            if (aio.available()) {
                const id = try aio.queueRead(read_file, buf, read_offset, 0);
                _ = try aio.submit();
                const result = try aio.waitFor(id);
                if (!result.isSuccess() or result.bytes_transferred != @as(i32, @intCast(len))) {
                    return error.UnexpectedEof;
                }
                return buf;
            }
        }

        // Fallback: preadAll — atomic positioned read, thread-safe (no seek)
        const got = try read_file.preadAll(buf, read_offset);
        if (got != len) return error.UnexpectedEof;

        return buf;
    }

    pub fn delete(self: *Self, key: [32]u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        // Invalidate hot cache entry
        self.hot_cache.remove(key);

        self.appendWal(.delete, key, &[_]u8{}) catch {};

        // Check if key exists in MemTable or index
        const old_ptr = self.memtable.get(key) orelse self.index.get(key);
        if (old_ptr) |ptr| {
            self.deleted_count += 1;
            self.deleted_bytes += ptr.len;
            self.live_bytes -= ptr.len;
            // Track dead bytes per segment for segment-level GC
            self.markSegmentDead(ptr);
        }

        // Add tombstone to MemTable (will be merged to index on flush)
        self.memtable.delete(key) catch {};
    }

    pub fn flush(self: *Self) !void {
        self.lock.lock();
        defer self.lock.unlock();
        // Flush MemTable to index first
        try self.flushMemTable();
        // Then flush SSTable to disk
        try self.flushSst();
        // Clear WAL after successful flush
        try self.wal.setEndPos(0);
        try self.wal.sync();
        try self.vlog.sync();
    }

    /// Get MemTable stats
    pub fn memtableCount(self: *Self) usize {
        return self.memtable.count();
    }

    /// Get MemTable size in bytes
    pub fn memtableSizeBytes(self: *Self) usize {
        return self.memtable.size_bytes;
    }

    /// Get hit stats
    pub fn getHitStats(self: *Self) struct { memtable: u64, index: u64, bloom_hits: u64, bloom_misses: u64 } {
        return .{
            .memtable = self.memtable_hits,
            .index = self.index_hits,
            .bloom_hits = self.bloom_filter_hits,
            .bloom_misses = self.bloom_filter_misses,
        };
    }

    /// Get SSTable stats by level
    pub fn getSSTableStats(self: *Self) struct {
        l0_count: usize,
        l1_count: usize,
        total_count: usize,
        bloom_filters_active: usize,
    } {
        // Count SSTables with active bloom filters
        var bloom_count: usize = 0;
        for (self.sstables.levels) |level| {
            for (level.items) |sst| {
                if (sst.bloom != null) bloom_count += 1;
            }
        }
        return .{
            .l0_count = self.sstables.levelCount(0),
            .l1_count = self.sstables.levelCount(1),
            .total_count = self.sstables.totalCount(),
            .bloom_filters_active = bloom_count,
        };
    }

    /// Get value log segment stats
    pub fn getSegmentStats(self: *Self) struct {
        segment_count: usize,
        active_segment_id: u32,
        total_size: u64,
        segment_rolls: u64,
    } {
        var total_size: u64 = self.write_offset; // Legacy vlog size
        for (self.vlog_segments.items) |seg| {
            total_size += seg.size;
        }
        return .{
            .segment_count = self.vlog_segments.items.len + 1, // +1 for legacy vlog
            .active_segment_id = self.active_segment_id,
            .total_size = total_size,
            .segment_rolls = self.segment_rolls,
        };
    }

    pub fn compactValueLog(self: *Self) !void {
        // Flush MemTable first so all entries are in index
        try self.flushMemTable();
        _ = try self.compactValueLogIncremental(std.math.maxInt(usize));
    }

    pub fn compactValueLogIncremental(self: *Self, max_entries: usize) !bool {
        var needs_init = false;
        {
            self.lock.lockShared();
            if (self.compaction_keys == null) {
                needs_init = true;
            }
            self.lock.unlockShared();
        }

        if (needs_init) {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.compaction_keys == null) {
                try self.flushMemTable();
                try self.beginCompaction();
            }
            return false;
        }

        var finished_work = false;
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();

            // Re-check just in case
            if (self.compaction_keys == null) return false;

            const keys = self.compaction_keys.?;
            var processed: usize = 0;
            while (self.compaction_pos < keys.len and processed < max_entries) : (processed += 1) {
                const key = keys[self.compaction_pos];
                self.compaction_pos += 1;
                const ptr = self.index.get(key) orelse continue;
                const len: usize = @intCast(ptr.len);
                const buf = try self.allocator.alloc(u8, len);
                defer self.allocator.free(buf);

                // Use preadAll for thread-safe reads (no seek race)
                const got = try self.vlog.preadAll(buf, ptr.offset);
                if (got != len) return error.UnexpectedEof;

                const comp_vlog = self.compaction_vlog.?;
                // Use pwrite for thread-safe writes (compaction_offset is exclusive to this thread)
                _ = try comp_vlog.pwrite(buf, self.compaction_offset);
                const comp_index = &self.compaction_index.?;
                try comp_index.put(key, .{ .offset = self.compaction_offset, .len = ptr.len });
                self.compaction_offset += len;
            }

            if (self.compaction_pos < keys.len) {
                return false;
            }
            finished_work = true;
        }

        if (finished_work) {
            return try self.finishCompaction();
        }
        return false;
    }

    pub fn isCompacting(self: *Self) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.compaction_keys != null;
    }

    pub fn deletedCount(self: *Self) u64 {
        return self.deleted_count;
    }

    pub fn deadBytes(self: *Self) u64 {
        return self.deleted_bytes;
    }

    pub fn liveBytes(self: *Self) u64 {
        return self.live_bytes;
    }

    /// Get GC statistics
    pub fn getGCStats(self: *Self) struct {
        live_bytes: u64,
        dead_bytes: u64,
        deleted_count: u64,
        compaction_in_progress: bool,
        needs_gc: bool,
        gc_ratio: f64,
    } {
        const total = self.live_bytes + self.deleted_bytes;
        const ratio: f64 = if (total > 0) @as(f64, @floatFromInt(self.deleted_bytes)) / @as(f64, @floatFromInt(total)) else 0.0;
        return .{
            .live_bytes = self.live_bytes,
            .dead_bytes = self.deleted_bytes,
            .deleted_count = self.deleted_count,
            .compaction_in_progress = self.compaction_keys != null,
            .needs_gc = self.needsValueLogCompaction(),
            .gc_ratio = ratio,
        };
    }

    fn appendWal(self: *Self, op: WalOp, key: [32]u8, value: []const u8) !void {
        try self.wal.seekTo(try self.wal.getEndPos());
        var header: [1 + 32 + 4 + 4]u8 = undefined;
        header[0] = @intFromEnum(op);
        @memcpy(header[1..33], &key);
        std.mem.writeInt(u32, header[33..][0..4], @intCast(value.len), .little);
        const checksum = computeWalChecksum(header[0..37], value);
        std.mem.writeInt(u32, header[37..][0..4], checksum, .little);
        try self.wal.writeAll(&header);
        if (value.len > 0) {
            try self.wal.writeAll(value);
        }
    }

    fn beginCompaction(self: *Self) !void {
        // No lock here - caller (compactValueLogIncremental) must hold exclusive lock
        var iter = self.index.iterator();
        const count: usize = self.index.count();
        const keys = try self.allocator.alloc([32]u8, count);
        var i: usize = 0;
        while (iter.next()) |entry| {
            keys[i] = entry.key_ptr.*;
            i += 1;
        }

        const comp_vlog = try self.dir.createFile("vlog.compact", .{ .read = true, .truncate = true });
        const comp_index = std.AutoHashMap([32]u8, ValuePtr).init(self.allocator);

        self.compaction_keys = keys;
        self.compaction_pos = 0;
        self.compaction_offset = 0;
        self.compaction_vlog = comp_vlog;
        self.compaction_index = comp_index;
    }

    fn finishCompaction(self: *Self) !bool {
        self.lock.lock();
        defer self.lock.unlock();

        const comp_vlog = self.compaction_vlog.?;
        try comp_vlog.sync();
        comp_vlog.close();
        self.compaction_vlog = null;

        self.vlog.close();
        _ = self.dir.deleteFile("vlog.bin") catch {};
        try self.dir.rename("vlog.compact", "vlog.bin");
        self.vlog = try self.dir.openFile("vlog.bin", .{ .mode = .read_write });
        self.write_offset = self.compaction_offset;

        self.index.deinit();
        self.index = self.compaction_index.?;
        self.compaction_index = null;

        if (self.compaction_keys) |keys| {
            self.allocator.free(keys);
        }
        self.compaction_keys = null;
        self.compaction_pos = 0;
        self.compaction_offset = 0;
        self.deleted_count = 0;
        self.deleted_bytes = 0;
        self.live_bytes = self.write_offset;

        try self.flushSst();
        return true;
    }

    /// Replay WAL to recover uncommitted writes after crash
    /// During recovery, we write directly to index (not MemTable) because:
    /// 1. These were already committed to WAL before crash
    /// 2. We want to restore the exact pre-crash state
    /// 3. After replay, MemTable starts fresh for new writes
    fn replayWal(self: *Self) !void {
        const size = try self.wal.getEndPos();
        if (size == 0) return;
        try self.wal.seekTo(0);
        const buf = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(buf);
        const got = try self.wal.readAll(buf);
        if (got != size) return;

        var offset: usize = 0;
        var recovered: usize = 0;
        while (offset + 41 <= buf.len) {
            const op: WalOp = @enumFromInt(buf[offset]);
            offset += 1;
            var key: [32]u8 = undefined;
            @memcpy(&key, buf[offset..][0..32]);
            offset += 32;
            const len = std.mem.readInt(u32, buf[offset..][0..4], .little);
            offset += 4;
            const checksum = std.mem.readInt(u32, buf[offset..][0..4], .little);
            offset += 4;
            if (offset + len > buf.len) break;
            const expected = computeWalChecksum(buf[(offset - 41)..(offset - 4)], buf[offset..][0..len]);
            if (checksum != expected) return error.WalChecksumMismatch;
            if (op == .put) {
                const value = buf[offset..][0..len];
                try self.vlog.seekTo(self.write_offset);
                try self.vlog.writeAll(value);
                if (self.index.get(key)) |old_ptr| {
                    self.deleted_bytes += old_ptr.len;
                    self.live_bytes -= old_ptr.len;
                }
                // Write directly to index during recovery
                try self.index.put(key, .{ .offset = self.write_offset, .len = len });
                self.write_offset += len;
                self.live_bytes += len;
                recovered += 1;
            } else if (op == .delete) {
                if (self.index.fetchRemove(key)) |entry| {
                    self.deleted_count += 1;
                    self.deleted_bytes += entry.value.len;
                    self.live_bytes -= entry.value.len;
                }
                recovered += 1;
            }
            offset += len;
        }

        if (recovered > 0) {
            std.debug.print("[VexStore] Recovered {d} entries from WAL\n", .{recovered});
        }
    }

    fn flushSst(self: *Self) !void {
        const sst_name = try std.fmt.allocPrint(self.allocator, "sst-current.bin", .{});
        defer self.allocator.free(sst_name);

        var file = try self.dir.createFile(sst_name, .{ .read = true, .truncate = true });
        defer file.close();

        // Dump current index as a single SST snapshot.
        const count: u32 = @intCast(self.index.count());
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, count, .little);
        try file.writeAll(&header);

        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            var entry_buf: [32 + 8 + 4 + 4]u8 = undefined;
            @memcpy(entry_buf[0..32], entry.key_ptr.*[0..32]);
            std.mem.writeInt(u64, entry_buf[32..][0..8], entry.value_ptr.offset, .little);
            std.mem.writeInt(u32, entry_buf[40..][0..4], entry.value_ptr.len, .little);
            const checksum = computeSstChecksum(entry_buf[0..44]);
            std.mem.writeInt(u32, entry_buf[44..][0..4], checksum, .little);
            try file.writeAll(&entry_buf);
        }
        try file.sync();

        if (self.current_sst) |name| {
            _ = self.dir.deleteFile(name) catch {};
            self.allocator.free(name);
        }
        self.current_sst = try self.allocator.dupe(u8, sst_name);
        try self.writeManifest();
    }

    fn writeManifest(self: *Self) !void {
        // Write legacy manifest for backward compatibility
        var file = try self.dir.createFile("manifest", .{ .read = true, .truncate = true });
        defer file.close();
        if (self.current_sst) |name| {
            try file.writeAll(name);
        }
        try file.sync();

        // Write new SSTable manifest with all metadata
        try self.writeSSTableManifest();
    }

    /// Write SSTable manifest with full metadata for recovery
    fn writeSSTableManifest(self: *Self) !void {
        var file = try self.dir.createFile("sstable.manifest", .{ .read = true, .truncate = true });
        defer file.close();

        // Header: version(u8) + next_id(u64) + next_sequence(u64)
        var header: [17]u8 = undefined;
        header[0] = 1; // Version 1
        std.mem.writeInt(u64, header[1..9], self.sstables.next_id, .little);
        std.mem.writeInt(u64, header[9..17], self.sstables.next_sequence, .little);
        try file.writeAll(&header);

        // Write each level
        for (self.sstables.levels, 0..) |level, level_idx| {
            // Level header: level(u8) + count(u32)
            var level_header: [5]u8 = undefined;
            level_header[0] = @intCast(level_idx);
            std.mem.writeInt(u32, level_header[1..5], @intCast(level.items.len), .little);
            try file.writeAll(&level_header);

            // Write each SSTable in this level
            for (level.items) |sst| {
                // SSTable entry: id(u64) + entry_count(u32) + min_key(32) + max_key(32) + file_size(u64) + sequence(u64)
                var entry: [96]u8 = undefined;
                std.mem.writeInt(u64, entry[0..8], sst.id, .little);
                std.mem.writeInt(u32, entry[8..12], sst.entry_count, .little);
                @memcpy(entry[12..44], &sst.min_key);
                @memcpy(entry[44..76], &sst.max_key);
                std.mem.writeInt(u64, entry[76..84], sst.file_size, .little);
                std.mem.writeInt(u64, entry[84..92], sst.sequence, .little);
                // Bloom filter present flag
                const has_bloom: u32 = if (sst.bloom != null) 1 else 0;
                std.mem.writeInt(u32, entry[92..96], has_bloom, .little);
                try file.writeAll(&entry);
            }
        }

        try file.sync();
    }

    fn loadManifest(self: *Self) !void {
        // Try to load new SSTable manifest first
        self.loadSSTableManifest() catch {
            // Fall back to legacy manifest
            const file = self.dir.openFile("manifest", .{ .mode = .read_only }) catch return;
            defer file.close();
            const data = try file.readToEndAlloc(self.allocator, 4096);
            defer self.allocator.free(data);
            if (data.len == 0) return;
            self.current_sst = try self.allocator.dupe(u8, data);
            try self.loadSst(data);
        };
    }

    /// Load SSTable manifest and rebuild SSTable tracking
    fn loadSSTableManifest(self: *Self) !void {
        const file = self.dir.openFile("sstable.manifest", .{ .mode = .read_only }) catch return error.ManifestNotFound;
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(data);

        if (data.len < 17) return error.InvalidManifest;

        // Read header
        const version = data[0];
        if (version != 1) return error.UnsupportedManifestVersion;

        self.sstables.next_id = std.mem.readInt(u64, data[1..9], .little);
        self.sstables.next_sequence = std.mem.readInt(u64, data[9..17], .little);

        var offset: usize = 17;

        // Read each level
        while (offset + 5 <= data.len) {
            const level_idx = data[offset];
            offset += 1;
            const count = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            if (level_idx >= SSTableManager.MAX_LEVELS) return error.InvalidLevel;

            // Read each SSTable
            var i: u32 = 0;
            while (i < count and offset + 96 <= data.len) : (i += 1) {
                const id = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8;
                const entry_count = std.mem.readInt(u32, data[offset..][0..4], .little);
                offset += 4;
                var min_key: [32]u8 = undefined;
                @memcpy(&min_key, data[offset..][0..32]);
                offset += 32;
                var max_key: [32]u8 = undefined;
                @memcpy(&max_key, data[offset..][0..32]);
                offset += 32;
                const file_size = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8;
                const sequence = std.mem.readInt(u64, data[offset..][0..8], .little);
                offset += 8;
                const has_bloom = std.mem.readInt(u32, data[offset..][0..4], .little);
                offset += 4;

                // Verify SSTable file exists
                const filename = try std.fmt.allocPrint(self.allocator, "L{d}-{d:0>8}.sst", .{ level_idx, id });
                defer self.allocator.free(filename);

                const sst_file = self.dir.openFile(filename, .{ .mode = .read_only }) catch {
                    // SSTable file missing, skip
                    continue;
                };
                sst_file.close();

                // Rebuild bloom filter if it was present
                var bloom: ?*BloomFilter = null;
                if (has_bloom == 1) {
                    bloom = try self.rebuildBloomFilter(filename, entry_count);
                }

                // Add to manager (directly to avoid incrementing IDs)
                const meta = SSTableMeta{
                    .id = id,
                    .level = level_idx,
                    .entry_count = entry_count,
                    .min_key = min_key,
                    .max_key = max_key,
                    .file_size = file_size,
                    .sequence = sequence,
                    .bloom = bloom,
                    .allocator = if (bloom != null) self.allocator else null,
                };
                try self.sstables.levels[level_idx].append(meta);

                // Also load the SSTable data into the index
                try self.loadSstByFilename(filename);
            }
        }

        self.l0_sstable_count = self.sstables.levelCount(0);
    }

    /// Rebuild bloom filter by reading SSTable file
    fn rebuildBloomFilter(self: *Self, filename: []const u8, entry_count: u32) !*BloomFilter {
        const file = try self.dir.openFile(filename, .{ .mode = .read_only });
        defer file.close();

        const bloom = try self.allocator.create(BloomFilter);
        errdefer self.allocator.destroy(bloom);
        bloom.* = try BloomFilter.init(self.allocator, entry_count);

        // Skip header (4 bytes)
        try file.seekTo(4);

        // Read each key and add to bloom filter
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            var key: [32]u8 = undefined;
            const read = try file.read(&key);
            if (read != 32) break;
            bloom.add(key);
            // Skip value_ptr (12 bytes) + checksum (4 bytes)
            try file.seekBy(16);
        }

        return bloom;
    }

    /// Load SSTable by filename into index
    fn loadSstByFilename(self: *Self, filename: []const u8) !void {
        const file = self.dir.openFile(filename, .{ .mode = .read_only }) catch return;
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(data);
        if (data.len < 4) return;
        var offset: usize = 0;
        const count = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        var i: u32 = 0;
        while (i < count and offset + 48 <= data.len) : (i += 1) {
            var key: [32]u8 = undefined;
            @memcpy(&key, data[offset..][0..32]);
            offset += 32;
            const off = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;
            const len = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const checksum = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const expected = computeSstChecksum(data[(offset - 48)..(offset - 4)]);
            if (checksum != expected) return error.SstChecksumMismatch;
            try self.index.put(key, .{ .offset = off, .len = len });
            self.live_bytes += len;
        }
    }

    fn loadSst(self: *Self, name: []const u8) !void {
        const file = self.dir.openFile(name, .{ .mode = .read_only }) catch return;
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 16 * 1024 * 1024);
        defer self.allocator.free(data);
        if (data.len < 4) return;
        var offset: usize = 0;
        const count = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        var i: u32 = 0;
        while (i < count and offset + 48 <= data.len) : (i += 1) {
            var key: [32]u8 = undefined;
            @memcpy(&key, data[offset..][0..32]);
            offset += 32;
            const off = std.mem.readInt(u64, data[offset..][0..8], .little);
            offset += 8;
            const len = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const checksum = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const expected = computeSstChecksum(data[(offset - 48)..(offset - 4)]);
            if (checksum != expected) return error.SstChecksumMismatch;
            try self.index.put(key, .{ .offset = off, .len = len });
            self.live_bytes += len;
        }
    }

    fn computeWalChecksum(header: []const u8, value: []const u8) u32 {
        var crc = crc32.init();
        crc.update(header);
        crc.update(value);
        return crc.final();
    }

    fn computeSstChecksum(entry: []const u8) u32 {
        var crc = crc32.init();
        crc.update(entry);
        return crc.final();
    }
};

test "vexstore put/get/delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
    defer store.deinit();

    const key = [_]u8{1} ** 32;
    try store.put(key, "hello");

    const got = try store.get(key);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, "hello", got.?);

    store.delete(key);
    const missing = try store.get(key);
    try std.testing.expect(missing == null);
}

test "vexstore wal recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
        defer store.deinit();
        const key = [_]u8{9} ** 32;
        try store.put(key, "recover");
    }

    var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
    defer store.deinit();
    const key = [_]u8{9} ** 32;
    const got = try store.get(key);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, "recover", got.?);
}

test "vexstore compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
    defer store.deinit();

    const key1 = [_]u8{1} ** 32;
    const key2 = [_]u8{2} ** 32;
    try store.put(key1, "alpha");
    try store.put(key2, "beta");
    try store.put(key1, "alpha2");

    try store.compactValueLog();

    const got1 = try store.get(key1);
    try std.testing.expect(got1 != null);
    defer std.testing.allocator.free(got1.?);
    try std.testing.expectEqualSlices(u8, "alpha2", got1.?);

    const got2 = try store.get(key2);
    try std.testing.expect(got2 != null);
    defer std.testing.allocator.free(got2.?);
    try std.testing.expectEqualSlices(u8, "beta", got2.?);
}

test "vexstore incremental compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
    defer store.deinit();

    const key1 = [_]u8{3} ** 32;
    const key2 = [_]u8{4} ** 32;
    const key3 = [_]u8{5} ** 32;
    try store.put(key1, "one");
    try store.put(key2, "two");
    try store.put(key3, "three");

    var done = try store.compactValueLogIncremental(1);
    try std.testing.expect(done == false);
    done = try store.compactValueLogIncremental(1);
    try std.testing.expect(done == false);
    done = try store.compactValueLogIncremental(10);
    try std.testing.expect(done == true);

    const got = try store.get(key2);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, "two", got.?);
}

test "vexstore dead bytes tracking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDir(std.testing.allocator, tmp.dir, null);
    defer store.deinit();

    const key = [_]u8{7} ** 32;
    try store.put(key, "aaa");
    try std.testing.expectEqual(@as(u64, 0), store.deadBytes());

    try store.put(key, "bbbb");
    try std.testing.expectEqual(@as(u64, 3), store.deadBytes());

    store.delete(key);
    try std.testing.expectEqual(@as(u64, 3 + 4), store.deadBytes());
}

test "memtable sorted insert and lookup" {
    var mt = MemTable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    // Insert keys out of order
    const key3 = [_]u8{3} ** 32;
    const key1 = [_]u8{1} ** 32;
    const key2 = [_]u8{2} ** 32;

    try mt.put(key3, .{ .offset = 300, .len = 30 });
    try mt.put(key1, .{ .offset = 100, .len = 10 });
    try mt.put(key2, .{ .offset = 200, .len = 20 });

    // Verify count
    try std.testing.expectEqual(@as(usize, 3), mt.count());

    // Verify lookups
    const ptr1 = mt.get(key1);
    try std.testing.expect(ptr1 != null);
    try std.testing.expectEqual(@as(u64, 100), ptr1.?.offset);

    const ptr2 = mt.get(key2);
    try std.testing.expect(ptr2 != null);
    try std.testing.expectEqual(@as(u64, 200), ptr2.?.offset);

    // Verify sorted order
    const entries = mt.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(std.mem.order(u8, &entries[0].key, &entries[1].key) == .lt);
    try std.testing.expect(std.mem.order(u8, &entries[1].key, &entries[2].key) == .lt);
}

test "memtable update existing key" {
    var mt = MemTable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    const key = [_]u8{5} ** 32;

    try mt.put(key, .{ .offset = 100, .len = 10 });
    try std.testing.expectEqual(@as(usize, 1), mt.count());

    // Update same key
    try mt.put(key, .{ .offset = 200, .len = 20 });
    try std.testing.expectEqual(@as(usize, 1), mt.count()); // Still 1 entry

    const ptr = mt.get(key);
    try std.testing.expect(ptr != null);
    try std.testing.expectEqual(@as(u64, 200), ptr.?.offset); // Updated value
}

test "memtable delete (tombstone)" {
    var mt = MemTable.init(std.testing.allocator, 1024);
    defer mt.deinit();

    const key = [_]u8{6} ** 32;

    try mt.put(key, .{ .offset = 100, .len = 10 });
    try std.testing.expect(mt.get(key) != null);

    try mt.delete(key);
    try std.testing.expect(mt.get(key) == null); // Returns null for deleted

    // But entry still exists (as tombstone)
    const entry = mt.contains(key);
    try std.testing.expect(entry != null);
    try std.testing.expect(entry.?.deleted);
}

test "vexstore memtable flush" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Use small MemTable size to trigger auto-flush
    var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, 100, null);
    defer store.deinit();

    // Insert multiple keys - should trigger flush when MemTable fills
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var key: [32]u8 = undefined;
        @memset(&key, i);
        try store.put(key, "test-value-data");
    }

    // Verify all keys readable (some from MemTable, some from index)
    i = 0;
    while (i < 10) : (i += 1) {
        var key: [32]u8 = undefined;
        @memset(&key, i);
        const got = try store.get(key);
        try std.testing.expect(got != null);
        std.testing.allocator.free(got.?);
    }
}

test "bloom filter basic operations" {
    var bf = try BloomFilter.init(std.testing.allocator, 100);
    defer bf.deinit();

    // Add some keys
    const key1 = [_]u8{1} ** 32;
    const key2 = [_]u8{2} ** 32;
    const key3 = [_]u8{3} ** 32;
    const key_not_added = [_]u8{99} ** 32;

    bf.add(key1);
    bf.add(key2);
    bf.add(key3);

    // Added keys should be found
    try std.testing.expect(bf.mayContain(key1));
    try std.testing.expect(bf.mayContain(key2));
    try std.testing.expect(bf.mayContain(key3));

    // Non-added key should likely not be found (may have false positive)
    // This test is probabilistic but with good parameters should pass
    _ = bf.mayContain(key_not_added); // Just check it doesn't crash
}

test "bloom filter serialization" {
    var bf = try BloomFilter.init(std.testing.allocator, 50);
    defer bf.deinit();

    const key1 = [_]u8{10} ** 32;
    const key2 = [_]u8{20} ** 32;
    bf.add(key1);
    bf.add(key2);

    // Serialize
    const data = try bf.serialize(std.testing.allocator);
    defer std.testing.allocator.free(data);

    // Deserialize
    var bf2 = try BloomFilter.deserialize(std.testing.allocator, data);
    defer bf2.deinit();

    // Should have same results
    try std.testing.expect(bf2.mayContain(key1));
    try std.testing.expect(bf2.mayContain(key2));
}

test "background compaction thread" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, 100, null);
    defer store.deinit();

    // Start background compaction
    try store.startBackgroundCompaction();

    // Insert some data
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        var key: [32]u8 = undefined;
        @memset(&key, i);
        try store.put(key, "test-value");
    }

    // Verify data still accessible
    i = 0;
    while (i < 5) : (i += 1) {
        var key: [32]u8 = undefined;
        @memset(&key, i);
        const got = try store.get(key);
        try std.testing.expect(got != null);
        std.testing.allocator.free(got.?);
    }

    // Stop is called automatically by deinit
}

test "snapshot iterator deterministic order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, MemTable.DEFAULT_MAX_SIZE, null);
    defer store.deinit();

    // Insert keys in random order
    const key3 = [_]u8{3} ** 32;
    const key1 = [_]u8{1} ** 32;
    const key2 = [_]u8{2} ** 32;

    try store.put(key3, "value3");
    try store.put(key1, "value1");
    try store.put(key2, "value2");

    // Create snapshot iterator
    var iter = try store.createSnapshotIterator();
    defer iter.deinit();

    // Should get keys in sorted order
    try std.testing.expectEqual(@as(usize, 3), iter.count());

    // First key should be key1 (smallest)
    const result1 = try iter.next();
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualSlices(u8, &key1, &result1.?.key);
    std.testing.allocator.free(result1.?.value);

    // Second key should be key2
    const result2 = try iter.next();
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualSlices(u8, &key2, &result2.?.key);
    std.testing.allocator.free(result2.?.value);

    // Third key should be key3 (largest)
    const result3 = try iter.next();
    try std.testing.expect(result3 != null);
    try std.testing.expectEqualSlices(u8, &key3, &result3.?.key);
    std.testing.allocator.free(result3.?.value);

    // No more keys
    const result4 = try iter.next();
    try std.testing.expect(result4 == null);
}

test "manifest persistence and recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const key1 = [_]u8{1} ** 32;
    const key2 = [_]u8{2} ** 32;

    // Create store, add data, flush to trigger manifest write
    {
        var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, 100, null);
        defer store.deinit();

        try store.put(key1, "value1");
        try store.put(key2, "value2");

        // Flush to disk (writes manifest)
        try store.flush();
    }

    // Reopen store - should recover from manifest
    {
        var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, MemTable.DEFAULT_MAX_SIZE, null);
        defer store.deinit();

        // Data should still be accessible
        const got1 = try store.get(key1);
        try std.testing.expect(got1 != null);
        std.testing.allocator.free(got1.?);

        const got2 = try store.get(key2);
        try std.testing.expect(got2 != null);
        std.testing.allocator.free(got2.?);
    }
}

test "VexStore async flush" {
    if (!async_io.isIoUringSupported()) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const queue_depth = async_io.recommendedQueueDepth();
    const config = async_io.AsyncIoConfig{ .queue_depth = queue_depth };
    var async_mgr = try async_io.AsyncIoManager.init(std.testing.allocator, config);
    defer async_mgr.deinit();

    // Ensure async io is actually available, otherwise we aren't testing what we think
    try std.testing.expect(async_mgr.available());

    // Use small MemTable (100 bytes)
    var store = try VexStore.initWithDirInternal(std.testing.allocator, tmp.dir, false, 100, async_mgr);
    defer store.deinit();

    const key = [_]u8{0xAA} ** 32;
    try store.put(key, "async-value");

    try store.flush();

    const val = try store.get(key);
    try std.testing.expect(val != null);
    try std.testing.expectEqualSlices(u8, "async-value", val.?);
    std.testing.allocator.free(val.?);

    // Verify SSTable creation
    try std.testing.expectEqual(@as(usize, 1), store.sstables.levelCount(0));
}
