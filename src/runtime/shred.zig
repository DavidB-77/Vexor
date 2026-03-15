const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const fec_resolver = @import("fec_resolver.zig");
const bmtree = @import("bmtree.zig");
const af_xdp = @import("../network/af_xdp/socket.zig");

/// Re-export for consumers
pub const UmemFrameRef = af_xdp.UmemFrameRef;
pub const UmemFrameManager = af_xdp.UmemFrameManager;

pub const SHRED_PAYLOAD_SIZE: usize = 1228;
pub const SHRED_HEADER_SIZE: usize = 88;

pub const ShredType = enum(u8) {
    data = 0b1010_0101,
    code = 0b0101_1010,
    pub fn isData(self: ShredType) bool {
        return self == .data;
    }
};

/// Parsed variant byte with Merkle V2 metadata.
/// Unifies with fec_resolver.parseVariantByte for consistent interpretation.
pub const ShredVariant = struct {
    is_data: bool,
    is_merkle: bool,
    proof_size: u8,
    chained: bool,
    resigned: bool,

    pub fn fromByte(variant: u8) ShredVariant {
        const parsed = fec_resolver.parseVariantByte(variant);
        const high_nibble = variant & 0xF0;

        // Determine chained/resigned from high nibble
        const chained = switch (high_nibble) {
            0x60, 0x70, 0x90, 0xB0 => true, // chained code/data variants
            else => false,
        };
        const resigned = switch (high_nibble) {
            0x70, 0xB0 => true, // resigned variants
            else => false,
        };

        return .{
            .is_data = parsed.is_data,
            .is_merkle = parsed.is_merkle,
            .proof_size = parsed.proof_size,
            .chained = chained,
            .resigned = resigned,
        };
    }
};

pub const ShredCommonHeader = struct {
    signature: core.Signature,
    variant_byte: u8,
    variant: ShredVariant,
    shred_type: ShredType,
    slot: core.Slot,
    index: u32,
    version: u16,
    fec_set_index: u32,
    parent_offset: u16,

    pub fn fromBytes(data: []const u8) !ShredCommonHeader {
        if (data.len < 83) return error.ShredTooShort;
        var sig: core.Signature = .{ .data = [_]u8{0} ** 64 };
        @memcpy(&sig.data, data[0..64]);

        const variant_byte = data[64];
        const variant = ShredVariant.fromByte(variant_byte);

        return ShredCommonHeader{
            .signature = sig,
            .variant_byte = variant_byte,
            .variant = variant,
            .shred_type = if (variant.is_data) .data else .code,
            .slot = std.mem.readInt(u64, data[65..73], .little),
            .index = std.mem.readInt(u32, data[73..77], .little),
            .version = std.mem.readInt(u16, data[77..79], .little),
            .fec_set_index = std.mem.readInt(u32, data[79..83], .little),
            .parent_offset = if (variant.is_data) std.mem.readInt(u16, data[83..85], .little) else 0,
        };
    }
};

pub const Shred = struct {
    common: ShredCommonHeader,
    payload: []const u8,

    pub fn slot(self: *const Shred) core.Slot {
        return self.common.slot;
    }

    pub fn index(self: *const Shred) u32 {
        return self.common.index;
    }

    pub fn isData(self: *const Shred) bool {
        return self.common.shred_type == .data;
    }

    pub fn parentOffset(self: *const Shred) u16 {
        return self.common.parent_offset;
    }

    pub fn rawData(self: *const Shred) []const u8 {
        return self.payload;
    }

    pub fn dataSize(self: *const Shred) u16 {
        if (!self.isData()) return 0;
        if (self.payload.len < 88) return 0;
        return std.mem.readInt(u16, self.payload[86..88], .little);
    }

    pub fn numData(self: *const Shred) u16 {
        if (self.isData()) return 0;
        if (self.payload.len < 85) return 0;
        return std.mem.readInt(u16, self.payload[83..85], .little);
    }

    pub fn numCoding(self: *const Shred) u16 {
        if (self.isData()) return 0;
        if (self.payload.len < 87) return 0;
        return std.mem.readInt(u16, self.payload[85..87], .little);
    }

    pub fn codingPosition(self: *const Shred) u16 {
        if (self.isData()) return 0;
        if (self.payload.len < 89) return 0;
        return std.mem.readInt(u16, self.payload[87..89], .little);
    }

    pub fn fecSetIndex(self: *const Shred) u32 {
        return self.common.fec_set_index;
    }

    pub fn version(self: *const Shred) u16 {
        return self.common.version;
    }

    pub fn fromPayload(payload: []const u8) !Shred {
        const common = try ShredCommonHeader.fromBytes(payload);
        return Shred{
            .common = common,
            .payload = payload,
        };
    }

    pub fn isLastInSlot(self: *const Shred) bool {
        if (!self.isData()) return false;
        if (self.payload.len <= 85) return false;
        // Data Shred flags are at offset 85.
        // Solana's LAST_SHRED_IN_SLOT is 0b1100_0000 (0xC0).
        // It requires both the DATA_COMPLETE (0x40) and LAST_IN_SLOT (0x80) bits.
        return (self.payload[85] & 0xC0) == 0xC0;
    }

    /// Returns the proof_size from the Merkle V2 variant.
    pub fn proofSize(self: *const Shred) u8 {
        return self.common.variant.proof_size;
    }

    /// Returns whether this is a Merkle shred (as opposed to legacy).
    pub fn isMerkle(self: *const Shred) bool {
        return self.common.variant.is_merkle;
    }

    pub fn deinit(self: *const Shred, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Compute the Merkle root from the proof nodes embedded at the end of the shred.
    /// Returns null if the shred is not a Merkle shred or the payload is too short.
    ///
    /// Layout for Merkle shreds (from Sig/Agave):
    ///   [signature 64B][variant..header][entry data][merkle proof nodes][optional: chained hash][optional: retransmitter sig]
    /// Proof nodes are proof_size * 20 bytes, located at the end of the payload
    /// (before any chained hash / retransmitter sig).
    pub fn merkleRoot(self: *const Shred) ?[bmtree.MERKLE_NODE_SIZE]u8 {
        const v = self.common.variant;
        if (!v.is_merkle) return null;
        if (v.proof_size == 0) return null;

        const payload = self.payload;
        const proof_bytes: usize = @as(usize, v.proof_size) * bmtree.MERKLE_NODE_SIZE;

        // Calculate the end of the proof region
        // Chained Merkle shreds have an additional 32-byte chained hash after the proof
        // Resigned shreds have a 64-byte retransmitter signature after the chained hash
        const suffix_size: usize = (if (v.chained) @as(usize, 32) else @as(usize, 0)) +
            (if (v.resigned) @as(usize, 64) else @as(usize, 0));

        // The proof ends at (payload.len - suffix_size)
        // The proof starts at (payload.len - suffix_size - proof_bytes)
        if (payload.len < suffix_size + proof_bytes) return null;
        const proof_end = payload.len - suffix_size;
        const proof_start = proof_end - proof_bytes;

        // The leaf data is everything from the variant byte (offset 64) up to the proof start
        const header_size: usize = if (v.is_data) SHRED_HEADER_SIZE else 89; // data: 88, code: 89
        if (proof_start < header_size) return null;

        // Hash the erasure shard (everything from variant byte to proof start) as the leaf
        const erasure_shard = payload[64..proof_start];
        const leaf_hash = bmtree.MerkleTree.hashMerkleLeaf(erasure_shard);

        // The shred's index within the FEC set
        const fec_set_idx = self.common.fec_set_index;
        const shred_idx_in_fec: usize = if (self.common.index >= fec_set_idx)
            @as(usize, self.common.index - fec_set_idx)
        else
            0;

        // Walk the proof upward to reconstruct the root
        const proof_nodes = payload[proof_start..proof_end];
        return bmtree.MerkleTree.reconstructRoot(leaf_hash, proof_nodes, shred_idx_in_fec);
    }

    /// Verify that this shred was signed by the given leader.
    /// For Merkle shreds: computes the Merkle root and verifies the Ed25519
    /// signature (in the shred header) against it.
    /// For legacy shreds: verifies the signature against the payload directly.
    pub fn verifySignature(self: *const Shred, leader_pubkey: *const core.Pubkey) bool {
        if (!self.isMerkle()) {
            // Legacy shreds: signature covers payload bytes [64..]
            if (self.payload.len <= 64) return false;
            return crypto.verify(&self.common.signature, leader_pubkey, self.payload[64..]);
        }

        // Merkle shreds: signature covers the 20-byte Merkle root
        const root = self.merkleRoot() orelse {
            // Can't compute root — reject the shred
            std.log.warn("[Shred] Cannot compute Merkle root for slot {d} index {d}", .{ self.common.slot, self.common.index });
            return false;
        };

        return crypto.verify(&self.common.signature, leader_pubkey, &root);
    }
};

pub fn parseShred(data: []const u8) !Shred {
    const common = try ShredCommonHeader.fromBytes(data);
    return Shred{ .common = common, .payload = data };
}

pub const ShredAssembler = struct {
    allocator: std.mem.Allocator,
    slots: std.AutoHashMap(u64, *SlotAssembly),
    fec_resolver: fec_resolver.FecResolver,
    highest_completed_slot: std.atomic.Value(u64),
    mutex: std.Thread.Mutex,
    /// Optional frame manager for releasing zero-copy UMEM frames on slot cleanup.
    /// Set by TVU after initialization via setFrameManager().
    frame_manager: ?*UmemFrameManager = null,
    /// Last time sweepStaleSlots() was called (nanoseconds)
    last_sweep_ns: u64 = 0,

    // ═══════════════════════════════════════════════════════════════════════
    // SlotAssembly: Zero-Alloc Slab with Dual-Path Storage
    // ═══════════════════════════════════════════════════════════════════════

    pub const SlotAssembly = struct {
        allocator: std.mem.Allocator,
        slot: u64,

        // ── Zero-Copy Path: UMEM frame references (no allocation, no copy) ──
        frames: [2048]?UmemFrameRef =
            [_]?UmemFrameRef{null} ** 2048,

        // ── Copy Path: heap-allocated payloads (kernel socket, FEC recovery, FramePressure) ──
        copied: [2048]?[]u8 =
            [_]?[]u8{null} ** 2048,

        // ── O(1) dedup bitmap (replaces HashMap.contains()) ──
        received: std.StaticBitSet(2048) =
            std.StaticBitSet(2048).initEmpty(),

        received_count: u32 = 0,
        last_index: ?u32 = null,
        is_complete: bool = false,

        /// Timestamp of last insert (nanoseconds) — used by stale slot sweeper
        last_updated_ns: u64 = 0,

        /// Maximum data shreds per slot (Solana practical limit ~2048,
        /// Firedancer uses 32768 as absolute ceiling).
        pub const MAX_SHREDS_PER_SLOT: u32 = 2048;

        pub fn init(allocator: std.mem.Allocator, slot: u64) SlotAssembly {
            return .{
                .allocator = allocator,
                .slot = slot,
                .last_updated_ns = @intCast(std.time.nanoTimestamp()),
            };
        }

        /// Deinit: free all copied payloads. Does NOT release UMEM frames —
        /// caller must call deinitWithFrameManager() for that.
        pub fn deinit(self: *SlotAssembly) void {
            for (&self.copied) |*c| {
                if (c.*) |payload| {
                    self.allocator.free(payload);
                    c.* = null;
                }
            }
            self.allocator.destroy(self);
        }

        /// Deinit with UMEM frame release — releases all held frames back to
        /// the Fill Ring via the frame manager, then frees copied payloads.
        pub fn deinitWithFrameManager(self: *SlotAssembly, fm: *UmemFrameManager) void {
            for (&self.frames) |*f| {
                if (f.*) |ref| {
                    fm.release(ref.frame_addr);
                    f.* = null;
                }
            }
            self.deinit();
        }

        /// Check if a shred index has been received (O(1) bitmap lookup)
        pub fn contains(self: *const SlotAssembly, index: u32) bool {
            if (index >= MAX_SHREDS_PER_SLOT) return false;
            return self.received.isSet(index);
        }

        /// Get shred count (O(1) — no iteration needed)
        pub fn count(self: *const SlotAssembly) u32 {
            return self.received_count;
        }

        /// Get raw payload for a shred index (prefers UMEM frame, falls back to copy).
        /// Returns null if the shred hasn't been received.
        pub fn getPayload(self: *const SlotAssembly, index: u32) ?[]const u8 {
            if (index >= MAX_SHREDS_PER_SLOT) return null;
            if (!self.received.isSet(index)) return null;

            // Prefer zero-copy frame data
            if (self.frames[index]) |ref| {
                return ref.data[0..ref.len];
            }
            // Fallback to copied data
            if (self.copied[index]) |payload| {
                return payload;
            }
            return null;
        }

        /// Insert via copy path (fallback: kernel socket, FEC recovery, FramePressure)
        pub fn insert(self: *SlotAssembly, index: u32, payload: []const u8, is_last: bool) !bool {
            if (self.is_complete) return false;
            if (index >= MAX_SHREDS_PER_SLOT) return false;
            if (self.received.isSet(index)) return false;

            const copy = try self.allocator.alloc(u8, payload.len);
            @memcpy(copy, payload);
            self.copied[index] = copy;
            self.received.set(index);
            self.received_count += 1;
            self.last_updated_ns = @intCast(std.time.nanoTimestamp());

            return self.handleLastAndComplete(index, is_last);
        }

        /// Insert via zero-copy path (UMEM frame reference — no allocation, no copy)
        pub fn insertFrame(self: *SlotAssembly, index: u32, frame: UmemFrameRef, is_last: bool) bool {
            if (self.is_complete) return false;
            if (index >= MAX_SHREDS_PER_SLOT) return false;
            if (self.received.isSet(index)) return false;

            self.frames[index] = frame;
            self.received.set(index);
            self.received_count += 1;
            self.last_updated_ns = @intCast(std.time.nanoTimestamp());

            return self.handleLastAndComplete(index, is_last);
        }

        /// Insert via ownership transfer (zero-copy handoff from FEC recovery).
        /// Caller transfers ownership of `owned_payload` — it will be freed
        /// by SlotAssembly.deinit(). No memcpy, no allocation.
        ///
        /// Use this instead of insert() when you already have a heap-allocated
        /// buffer (e.g., from FEC reconstruction) to avoid redundant copying.
        pub fn insertOwned(self: *SlotAssembly, index: u32, owned_payload: []u8, is_last: bool) bool {
            if (self.is_complete) {
                self.allocator.free(owned_payload);
                return false;
            }
            if (index >= MAX_SHREDS_PER_SLOT) {
                self.allocator.free(owned_payload);
                return false;
            }
            if (self.received.isSet(index)) {
                self.allocator.free(owned_payload); // Duplicate — free the caller's buffer
                return false;
            }

            self.copied[index] = owned_payload; // Transfer ownership — no copy
            self.received.set(index);
            self.received_count += 1;
            self.last_updated_ns = @intCast(std.time.nanoTimestamp());

            return self.handleLastAndComplete(index, is_last);
        }

        /// Shared logic for last-index tracking and completeness check
        fn handleLastAndComplete(self: *SlotAssembly, index: u32, is_last: bool) bool {
            if (is_last) {
                // Defensive: If we already have shreds with indices HIGHER than this "last" index,
                // it's a spurious "last" bit.
                if (self.received_count > 0) {
                    var highest_seen: u32 = 0;
                    var idx: u32 = 0;
                    while (idx < MAX_SHREDS_PER_SLOT) : (idx += 1) {
                        if (self.received.isSet(idx) and idx > highest_seen) {
                            highest_seen = idx;
                        }
                    }
                    if (index < highest_seen) {
                        std.log.warn("[Assembler] Slot {d} ignoring LAST bit on index {d} because we already have index {d}", .{ self.slot, index, highest_seen });
                    } else {
                        if (self.last_index) |prev_last| {
                            if (prev_last != index) {
                                std.log.warn("[Assembler] Slot {d} LAST_INDEX changed from {d} to {d}!", .{ self.slot, prev_last, index });
                            }
                        }
                        self.last_index = index;
                    }
                } else {
                    self.last_index = index;
                }
            }

            // Check if complete: all shreds 0..last_index present
            if (self.last_index) |last| {
                if (self.received_count >= last + 1) {
                    // Fast check: the bitmap must have all bits 0..last set
                    var i: u32 = 0;
                    while (i <= last) : (i += 1) {
                        if (!self.received.isSet(i)) return false;
                    }
                    self.is_complete = true;
                    return true;
                }
            }
            return false;
        }
    };

    // ═══════════════════════════════════════════════════════════════════════
    // Initialization
    // ═══════════════════════════════════════════════════════════════════════

    pub fn init(allocator: std.mem.Allocator) !*ShredAssembler {
        return try initWithShredVersion(allocator, 0);
    }

    pub fn initWithShredVersion(allocator: std.mem.Allocator, version: u16) !*ShredAssembler {
        // Default: Data-Only mode (FEC recovery disabled for stability)
        return try initWithConfig(allocator, version, false, false);
    }

    /// Initialize with FEC recovery enabled (use only after RS bugs are fixed)
    pub fn initWithFecRecovery(allocator: std.mem.Allocator, version: u16) !*ShredAssembler {
        return try initWithConfig(allocator, version, true, false);
    }

    /// Initialize with FEC recovery AND SIMD acceleration enabled
    pub fn initWithFecAndSimd(allocator: std.mem.Allocator, version: u16) !*ShredAssembler {
        return try initWithConfig(allocator, version, true, true);
    }

    fn initWithConfig(allocator: std.mem.Allocator, version: u16, enable_recovery: bool, enable_simd: bool) !*ShredAssembler {
        const self = try allocator.create(ShredAssembler);
        const fec = if (!enable_recovery)
            fec_resolver.FecResolver.initDataOnly(allocator, 100, version)
        else if (enable_simd)
            fec_resolver.FecResolver.initWithSimd(allocator, 100, version)
        else
            fec_resolver.FecResolver.init(allocator, 100, version);

        self.* = .{
            .allocator = allocator,
            .slots = std.AutoHashMap(u64, *SlotAssembly).init(allocator),
            .fec_resolver = fec,
            .highest_completed_slot = std.atomic.Value(u64).init(0),
            .mutex = .{},
        };

        if (!enable_recovery) {
            std.log.info("[Assembler] Data-Only mode: FEC recovery DISABLED for stability", .{});
        } else if (enable_simd) {
            std.log.info("[Assembler] FEC recovery ENABLED with SIMD acceleration", .{});
        } else {
            std.log.info("[Assembler] FEC recovery ENABLED - Reed-Solomon erasure coding active", .{});
        }

        std.log.info("[Assembler] Zero-alloc slab: {d} shreds/slot capacity, 30s stale timeout", .{SlotAssembly.MAX_SHREDS_PER_SLOT});

        return self;
    }

    /// Set the UMEM frame manager (called by TVU after AcceleratedIO init).
    /// Required for proper UMEM frame release during slot cleanup and sweeping.
    pub fn setFrameManager(self: *ShredAssembler, fm: *UmemFrameManager) void {
        self.frame_manager = fm;
        std.log.info("[Assembler] UmemFrameManager attached — zero-copy frame release enabled", .{});
    }

    pub fn deinit(self: *ShredAssembler) void {
        // Scope the mutex to avoid use-after-free: unlock must happen BEFORE destroy.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.slots.valueIterator();
            while (it.next()) |assembly| {
                if (self.frame_manager) |fm| {
                    assembly.*.deinitWithFrameManager(fm);
                } else {
                    assembly.*.deinit();
                }
            }
            self.slots.deinit();
            self.fec_resolver.deinit();
        }
        self.allocator.destroy(self);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Stale Slot Sweeper (Frame Leak Prevention)
    // ═══════════════════════════════════════════════════════════════════════

    /// Stale slot timeout for LIVE Turbine slots (close to head): 30 seconds
    const LIVE_SLOT_TIMEOUT_NS: u64 = 30 * std.time.ns_per_s;

    /// Stale slot timeout for REPAIR slots (far behind head): 5 minutes
    /// Repair slots arrive slowly via request/response — give them time.
    const REPAIR_SLOT_TIMEOUT_NS: u64 = 5 * 60 * std.time.ns_per_s;

    /// A slot is considered "live" (near the head) if it's within this many
    /// slots of the highest completed slot. Beyond this → repair territory.
    const LIVE_SLOT_WINDOW: u64 = 1000;

    /// Sweep interval: check for stale slots every 5 seconds
    const SWEEP_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;

    /// Sweep stale slots: release all held UMEM frames and copied payloads
    /// for slots that haven't received any shreds within their timeout.
    ///
    /// Uses dual timeouts:
    ///   - Live slots (within 1000 of head): 30 seconds
    ///   - Repair slots (far behind head): 5 minutes
    ///
    /// Call this periodically from the TVU main loop.
    /// Returns the number of slots swept.
    pub fn sweepStaleSlots(self: *ShredAssembler) usize {
        const now_ns: u64 = @intCast(std.time.nanoTimestamp());

        // Throttle: only sweep every 5 seconds
        if (now_ns < self.last_sweep_ns + SWEEP_INTERVAL_NS) return 0;
        self.last_sweep_ns = now_ns;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Get the current head for live vs. repair classification
        const head_slot = self.highest_completed_slot.load(.seq_cst);

        // Collect stale slot keys (can't remove during iteration)
        var stale_keys = std.ArrayList(u64).init(self.allocator);
        defer stale_keys.deinit();

        var it = self.slots.iterator();
        while (it.next()) |entry| {
            const assembly = entry.value_ptr.*;
            if (assembly.is_complete) continue; // Don't sweep completed slots (replay may need them)

            const age_ns = if (now_ns > assembly.last_updated_ns) now_ns - assembly.last_updated_ns else 0;
            const slot_key = entry.key_ptr.*;

            // Classify: is this a live Turbine slot or a historical repair slot?
            // CRITICAL: When head_slot == 0 (nothing completed yet), ALL slots are
            // repair slots and need the full 5-minute timeout. The old logic treated
            // them as 'live' (30s timeout) which killed them before they could assemble.
            const is_live = if (head_slot == 0)
                false // Nothing completed yet — everything is repair territory
            else
                (slot_key >= head_slot and slot_key - head_slot <= LIVE_SLOT_WINDOW) or
                    (head_slot > slot_key and head_slot - slot_key <= LIVE_SLOT_WINDOW);

            const timeout = if (is_live) LIVE_SLOT_TIMEOUT_NS else REPAIR_SLOT_TIMEOUT_NS;

            if (age_ns > timeout) {
                stale_keys.append(slot_key) catch continue;
            }
        }

        // Remove stale slots and release their resources
        for (stale_keys.items) |slot_key| {
            if (self.slots.fetchRemove(slot_key)) |removed| {
                const assembly = removed.value;
                const frame_count = assembly.received_count;

                // Classify for logging
                const is_live = (head_slot > 0) and
                    ((slot_key >= head_slot and slot_key - head_slot <= LIVE_SLOT_WINDOW) or
                    (head_slot > slot_key and head_slot - slot_key <= LIVE_SLOT_WINDOW));

                if (self.frame_manager) |fm| {
                    assembly.deinitWithFrameManager(fm);
                } else {
                    assembly.deinit();
                }

                std.log.info("[Sweeper] Cleaned {s} slot {d} ({d} shreds, {s})", .{
                    if (is_live) "live" else "repair",
                    slot_key,
                    frame_count,
                    if (self.frame_manager != null) "frames released" else "copies freed",
                });
            }
            self.fec_resolver.removeSlot(slot_key);
        }

        if (stale_keys.items.len > 0) {
            std.log.info("[Sweeper] Swept {d} stale slots (active: {d}, head: {d})", .{
                stale_keys.items.len,
                self.slots.count(),
                head_slot,
            });
        }

        return stale_keys.items.len;
    }

    pub const InsertResult = enum {
        inserted,
        duplicate,
        completed_slot,
    };

    pub fn insert(self: *ShredAssembler, s: Shred) !InsertResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot_val = s.slot();
        const flags = if (s.payload.len > 85) s.payload[85] else 0;
        if (flags & 0xC0 != 0) {
            std.log.info("[Assembler] Shred slot={d} idx={d} flags=0x{x:0>2} (is_last={})", .{ slot_val, s.index(), flags, s.isLastInSlot() });
        }

        // 1. Process in FEC resolver regardless of type
        const fr_res = self.fec_resolver.addShred(
            slot_val,
            s.index(),
            s.fecSetIndex(),
            s.isData(),
            s.payload,
            s.version(),
            s.numData(),
            s.numCoding(),
            s.codingPosition(),
        ) catch .err;

        // FEC diagnostics: log recovery events (debug.print shows in journalctl)
        if (fr_res == .complete) {
            // Log every 10th FEC set completion to avoid spam
            const sets_done = self.fec_resolver.stats.sets_completed;
            if (sets_done % 10 == 1) {
                std.debug.print("[FEC-DIAG] Set COMPLETE: slot={d} fec={d} (total_sets={d} recovered={d} skipped={d})\n", .{
                    slot_val,
                    s.fecSetIndex(),
                    sets_done,
                    self.fec_resolver.stats.shreds_recovered,
                    self.fec_resolver.stats.recovery_skipped,
                });
            }
        }

        // 2. Only process data shreds for main assembly
        if (!s.isData()) {
            // Even for coding shreds, we might have just completed an FEC set
            if (fr_res != .complete) return .inserted;
        }

        var completed = false;
        const entry = try self.slots.getOrPut(slot_val);
        if (!entry.found_existing) {
            entry.value_ptr.* = try self.allocator.create(SlotAssembly);
            entry.value_ptr.*.* = SlotAssembly.init(self.allocator, slot_val);
        }
        const assembly = entry.value_ptr.*;

        if (assembly.contains(s.index())) {
            return .duplicate;
        }

        const is_last = s.isLastInSlot();
        if (is_last) {
            std.log.info("[Assembler] Received LAST shred for slot {d} at index {d}", .{ slot_val, s.index() });
        }

        completed = try assembly.insert(s.index(), s.payload, is_last);

        if (completed) {
            const assembly_completed = self.slots.get(slot_val).?;
            std.log.info("[Assembler] Slot {d} COMPLETED! Total shreds: {d}, Last index: {d}", .{ slot_val, assembly_completed.count(), assembly_completed.last_index.? });
            _ = self.highest_completed_slot.fetchMax(slot_val, .seq_cst);
            return .completed_slot;
        }

        // 3. If FEC completed a set, pull recovered data shreds into assembly
        if (fr_res == .complete) {
            const fsi = s.fecSetIndex();
            const key = fec_resolver.FecResolver.makeKey(slot_val, fsi);
            if (self.fec_resolver.active_sets.get(key)) |set| {
                const rec_entry = try self.slots.getOrPut(slot_val);
                if (!rec_entry.found_existing) {
                    rec_entry.value_ptr.* = try self.allocator.create(SlotAssembly);
                    rec_entry.value_ptr.*.* = SlotAssembly.init(self.allocator, slot_val);
                }
                const rec_assembly = rec_entry.value_ptr.*;

                // Insert recovered shreds
                var i: u16 = 0;
                while (i < set.data_shred_cnt) : (i += 1) {
                    if (set.data_received.isSet(i)) {
                        if (set.data_shreds[i]) |rec_shred| {
                            const global_idx = fsi + @as(u32, @intCast(i));
                            if (!rec_assembly.contains(global_idx)) {
                                if (Shred.fromPayload(rec_shred)) |temp_shred| {
                                    const is_rec_last = temp_shred.isLastInSlot();
                                    _ = rec_assembly.insert(global_idx, rec_shred, is_rec_last) catch continue;
                                    if (rec_assembly.is_complete) completed = true;
                                } else |_| continue;
                            }
                        }
                    }
                }
            }
        }

        if (completed) {
            const assembly_completed = self.slots.get(slot_val).?;
            std.log.info("[Assembler] Slot {d} COMPLETED! Total shreds: {d}, Last index: {d}", .{ slot_val, assembly_completed.count(), assembly_completed.last_index.? });
            _ = self.highest_completed_slot.fetchMax(slot_val, .seq_cst);
            return .completed_slot;
        }

        if (!s.isData()) return .inserted; // Coding shreds count as "inserted" for flow control
        return .inserted;
    }

    /// Batch insert: Sig-inspired (Syndica/sig shred_receiver.zig)
    /// Takes the lock ONCE and processes up to `shreds.len` shreds.
    /// Returns struct with counts of inserted, duplicates, and completed slots.
    /// This is dramatically faster than calling insert() per-shred because
    /// we avoid lock/unlock overhead per packet (critical at >100K shreds/sec).
    pub const BatchInsertResult = struct {
        inserted: usize = 0,
        duplicates: usize = 0,
        completed_slots: usize = 0,
    };

    pub fn insertBatch(self: *ShredAssembler, shreds: []const Shred) BatchInsertResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = BatchInsertResult{};

        for (shreds) |s| {
            const slot_val = s.slot();

            // 1. Process in FEC resolver regardless of type
            const fr_res = self.fec_resolver.addShred(
                slot_val,
                s.index(),
                s.fecSetIndex(),
                s.isData(),
                s.payload,
                s.version(),
                s.numData(),
                s.numCoding(),
                s.codingPosition(),
            ) catch .err;

            // Log FEC completion periodically
            if (fr_res == .complete) {
                const sets_done = self.fec_resolver.stats.sets_completed;
                if (sets_done % 10 == 1) {
                    std.debug.print("[FEC-DIAG] Set COMPLETE: slot={d} fec={d} (total_sets={d} recovered={d} skipped={d})\n", .{
                        slot_val,
                        s.fecSetIndex(),
                        sets_done,
                        self.fec_resolver.stats.shreds_recovered,
                        self.fec_resolver.stats.recovery_skipped,
                    });
                }
            }

            // 2. Only process data shreds for main assembly
            if (!s.isData()) {
                if (fr_res != .complete) {
                    result.inserted += 1;
                    continue;
                }
            }

            var completed = false;
            const entry = self.slots.getOrPut(slot_val) catch {
                continue;
            };
            if (!entry.found_existing) {
                entry.value_ptr.* = self.allocator.create(SlotAssembly) catch continue;
                entry.value_ptr.*.* = SlotAssembly.init(self.allocator, slot_val);
            }
            const assembly = entry.value_ptr.*;

            if (assembly.contains(s.index())) {
                result.duplicates += 1;
                continue;
            }

            const is_last = s.isLastInSlot();
            if (is_last) {
                std.log.info("[Assembler] Received LAST shred for slot {d} at index {d}", .{ slot_val, s.index() });
            }

            completed = assembly.insert(s.index(), s.payload, is_last) catch {
                continue;
            };

            // 3. If FEC completed a set, pull recovered data shreds into assembly
            if (fr_res == .complete) {
                const fsi = s.fecSetIndex();
                const key = fec_resolver.FecResolver.makeKey(slot_val, fsi);
                if (self.fec_resolver.active_sets.get(key)) |set| {
                    const rec_entry = self.slots.getOrPut(slot_val) catch continue;
                    if (!rec_entry.found_existing) {
                        rec_entry.value_ptr.* = self.allocator.create(SlotAssembly) catch continue;
                        rec_entry.value_ptr.*.* = SlotAssembly.init(self.allocator, slot_val);
                    }
                    const rec_assembly = rec_entry.value_ptr.*;

                    var i: u16 = 0;
                    while (i < set.data_shred_cnt) : (i += 1) {
                        if (set.data_received.isSet(i)) {
                            if (set.data_shreds[i]) |rec_shred| {
                                const global_idx = fsi + @as(u32, @intCast(i));
                                if (!rec_assembly.contains(global_idx)) {
                                    if (Shred.fromPayload(rec_shred)) |temp_shred| {
                                        const is_rec_last = temp_shred.isLastInSlot();
                                        _ = rec_assembly.insert(global_idx, rec_shred, is_rec_last) catch continue;
                                        if (rec_assembly.is_complete) completed = true;
                                    } else |_| continue;
                                }
                            }
                        }
                    }
                }
            }

            if (completed) {
                const assembly_completed = self.slots.get(slot_val).?;
                std.log.info("[Assembler] Slot {d} COMPLETED! Total shreds: {d}, Last index: {d}", .{ slot_val, assembly_completed.count(), assembly_completed.last_index.? });
                _ = self.highest_completed_slot.fetchMax(slot_val, .seq_cst);
                result.completed_slots += 1;
            } else {
                result.inserted += 1;
            }
        }

        return result;
    }

    pub fn getShred(self: *ShredAssembler, slot_val: u64, index: u32) !?Shred {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return null;
        const payload = assembly.getPayload(index) orelse return null;

        // Note: this makes a copy to be safe, as Shred handles its own lifetime in some paths
        const copy = try self.allocator.alloc(u8, payload.len);
        @memcpy(copy, payload);
        return try Shred.fromPayload(copy);
    }

    pub fn getHighestShredIndex(self: *ShredAssembler, slot_val: u64) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return null;
        var highest: u32 = 0;
        var idx: u32 = 0;
        while (idx < SlotAssembly.MAX_SHREDS_PER_SLOT) : (idx += 1) {
            if (assembly.received.isSet(idx) and idx > highest) highest = idx;
        }
        return highest;
    }

    pub fn getLastShred(self: *ShredAssembler, slot_val: u64) ?Shred {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return null;
        const idx = assembly.last_index orelse return null;
        const payload = assembly.getPayload(idx) orelse return null;

        const copy = self.allocator.alloc(u8, payload.len) catch return null;
        @memcpy(copy, payload);
        return Shred.fromPayload(copy) catch null;
    }

    pub fn getParentSlot(self: *ShredAssembler, slot_val: u64) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return null;
        // Find the first received shred to extract parent offset
        var idx: u32 = 0;
        while (idx < SlotAssembly.MAX_SHREDS_PER_SLOT) : (idx += 1) {
            if (assembly.getPayload(idx)) |payload| {
                const s = Shred.fromPayload(payload) catch return null;
                const offset = s.parentOffset();
                if (slot_val > offset) return slot_val - offset;
                return null;
            }
        }
        return null;
    }

    pub fn getCompletedSlot(self: *ShredAssembler) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.slots.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.is_complete) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    pub fn clearCompletedSlot(self: *ShredAssembler, slot_val: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.slots.fetchRemove(slot_val)) |entry| {
            if (self.frame_manager) |fm| {
                entry.value.deinitWithFrameManager(fm);
            } else {
                entry.value.deinit();
            }
        }
        self.fec_resolver.removeSlot(slot_val);
    }

    pub fn removeSlot(self: *ShredAssembler, slot_val: u64) void {
        self.clearCompletedSlot(slot_val);
    }

    pub fn assembleSlot(self: *ShredAssembler, slot_val: u64) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return null;
        if (!assembly.is_complete) return null;

        const last = assembly.last_index.?;

        // Pass 1: Count total bytes using the 16-bit size field at bytes 86-87.
        // Per Agave spec, this field already excludes Merkle proof/suffix.
        var total_size: usize = 0;
        var i: u32 = 0;
        while (i <= last) : (i += 1) {
            const shred_data = assembly.getPayload(i) orelse continue;
            if (shred_data.len < 88 or (shred_data[64] & 0x80 == 0)) continue;

            const size = std.mem.readInt(u16, shred_data[86..88], .little);
            if (size <= 88) continue;
            const clamped: u16 = @min(size, @as(u16, @intCast(shred_data.len)));
            if (clamped <= 88) continue;
            total_size += clamped - 88;
        }

        std.log.debug("[Assembler] Assembling slot {d} with {d} bytes from {d} shreds", .{ slot_val, total_size, last + 1 });

        const result = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;
        i = 0;
        while (i <= last) : (i += 1) {
            const shred_data = assembly.getPayload(i) orelse continue;
            if (shred_data.len < 88 or (shred_data[64] & 0x80 == 0)) continue;

            const size = std.mem.readInt(u16, shred_data[86..88], .little);
            if (size <= 88) continue;
            const clamped: u16 = @min(size, @as(u16, @intCast(shred_data.len)));
            if (clamped <= 88) continue;
            const data_len = clamped - 88;

            if (offset + data_len > total_size) {
                std.debug.print("[Assembler] Buffer overflow in slot {d}! offset={d} len={d} total={d}\n", .{ slot_val, offset, data_len, total_size });
                break;
            }
            @memcpy(result[offset .. offset + data_len], shred_data[88 .. 88 + data_len]);
            offset += data_len;
        }

        return result;
    }

    pub fn getHighestCompletedSlot(self: *ShredAssembler) ?u64 {
        const val = self.highest_completed_slot.load(.seq_cst);
        return if (val == 0) null else val;
    }

    pub fn getInProgressSlots(self: *ShredAssembler) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var slots = std.ArrayList(u64).init(self.allocator);
        var it = self.slots.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*.is_complete) {
                try slots.append(entry.key_ptr.*);
            }
        }
        return slots.toOwnedSlice();
    }

    pub fn getInProgressSlotCount(self: *ShredAssembler) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var it = self.slots.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*.is_complete) {
                count += 1;
            }
        }
        return count;
    }

    pub const SlotInfo = struct {
        knows_last_shred: bool,
        unique_count: usize,
        last_shred_index: u32,
    };

    pub fn getSlotInfo(self: *ShredAssembler, slot_val: u64) !SlotInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return SlotInfo{
            .knows_last_shred = false,
            .unique_count = 0,
            .last_shred_index = 0,
        };

        return SlotInfo{
            .knows_last_shred = assembly.last_index != null,
            .unique_count = assembly.count(),
            .last_shred_index = assembly.last_index orelse 0,
        };
    }

    pub fn getMissingIndices(self: *ShredAssembler, slot_val: u64) ![]u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return &.{};
        if (assembly.is_complete) return &.{};

        var missing = std.ArrayList(u32).init(self.allocator);
        if (assembly.last_index) |last| {
            var i: u32 = 0;
            while (i <= last) : (i += 1) {
                if (!assembly.contains(i)) {
                    try missing.append(i);
                }
            }
        }
        return missing.toOwnedSlice();
    }

    /// Get the highest shred index we've seen for a slot
    pub fn getHighestIndex(self: *ShredAssembler, slot_val: u64) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return 0;
        var highest: u32 = 0;
        var idx: u32 = 0;
        while (idx < SlotAssembly.MAX_SHREDS_PER_SLOT) : (idx += 1) {
            if (assembly.received.isSet(idx) and idx > highest) highest = idx;
        }
        return highest;
    }

    /// Check if we have a specific shred for a slot (lock-free from TVU thread)
    pub fn hasShred(self: *ShredAssembler, slot_val: u64, shred_idx: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const assembly = self.slots.get(slot_val) orelse return false;
        if (shred_idx >= SlotAssembly.MAX_SHREDS_PER_SLOT) return false;
        return assembly.received.isSet(shred_idx);
    }
};
