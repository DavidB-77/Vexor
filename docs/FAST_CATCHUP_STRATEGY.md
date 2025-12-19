# Vexor Fast Catch-up Strategy

**Status:** Partial Implementation  
**Priority:** HIGH  
**Created:** December 14, 2024

---

## Overview

Fast catch-up is critical for validators because:
1. **Faster bootstrap** = less downtime when starting/restarting
2. **Faster recovery** = quicker return to voting after issues
3. **Competitive advantage** = operators prefer faster clients

---

## Current Implementation Status

| Component | Status | File |
|-----------|--------|------|
| **Snapshot Discovery (Gossip)** | ✅ Complete | `snapshot_discovery.zig` |
| **Snapshot Discovery (RPC)** | ✅ Complete | `snapshot.zig` |
| **Single-Stream Download** | ✅ Complete | `snapshot.zig` - `httpDownload()` |
| **Progress Tracking** | ✅ Complete | `DownloadProgress` struct |
| **mmap Account Loading** | ✅ Complete | `loadAppendVec()` |
| **Shred Repair Protocol** | ✅ Complete | `repair.zig` |
| **Parallel Download** | ✅ Complete | `parallel_download.zig` - `ParallelDownloader` |
| **Multi-Source Download** | ✅ Complete | `parallel_download.zig` - `SnapshotPeer` scoring |
| **Resume on Failure** | ✅ Complete | `parallel_download.zig` - `ResumeState` |
| **Async I/O (io_uring)** | ✅ Complete | `async_io.zig` - `AsyncIoManager` |
| **Streaming Decompression** | ✅ Complete | `streaming_decompress.zig` - `StreamingDecompressor` |
| **Repair Integration** | ⚠️ Partial | Protocol ready, not wired |

---

## Proposed "Turbo Catch-up" Architecture

### Phase 1: Parallel Multi-Source Snapshot Download

```
┌─────────────────────────────────────────────────────────────────┐
│                    SNAPSHOT DOWNLOAD                             │
│                                                                  │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐     │
│  │ Peer A   │   │ Peer B   │   │ Peer C   │   │ Peer D   │     │
│  │ (fast)   │   │ (medium) │   │ (fast)   │   │ (slow)   │     │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘     │
│       │              │              │              │            │
│       ▼              ▼              ▼              ▼            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              CHUNK COORDINATOR                           │   │
│  │  • HTTP Range requests for parallel chunks              │   │
│  │  • Dynamic peer selection (fastest get more chunks)     │   │
│  │  • Automatic retry on failure                           │   │
│  │  • Resume tracking (persisted to disk)                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              CHUNK MERGER                                │   │
│  │  • io_uring async I/O                                   │   │
│  │  • Zero-copy where possible                             │   │
│  │  • Integrity verification (hash check)                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 2: Streaming Decompression + Loading

```
Traditional: Download → Decompress → Load
Vexor:       Download ──┬─→ Decompress ──┬─→ Load
                        │                │
                        └── (pipelined) ─┘
```

**Benefits:**
- Start loading accounts while still downloading
- Reduces total time by ~30-40%

### Phase 3: Shred Repair (Gap Fill)

After snapshot load, there's a gap:
```
Snapshot Slot: 374,576,751
Current Slot:  374,600,000
Gap:           23,249 slots to catch up
```

**Shred Repair Strategy:**
1. **Priority: Most Recent First** - Enables voting sooner
2. **Parallel Requests** - Request from multiple peers
3. **AF_XDP** - Low-latency repair responses
4. **Adaptive** - Request more from faster peers

---

## Comparison with Competitors

| Feature | Agave | Firedancer | Vexor (Proposed) |
|---------|-------|------------|------------------|
| **Download** | Single stream | Parallel chunks | Parallel + multi-source |
| **Decompression** | Sequential | Sequential | Streaming (pipelined) |
| **Account Loading** | Heap allocation | Custom | mmap (zero-copy) |
| **I/O Backend** | Blocking | AF_XDP | io_uring + AF_XDP |
| **Shred Repair** | Sequential | Parallel | Priority-weighted parallel |
| **Peer Selection** | Random | Stake-weighted | Latency + bandwidth |

**Expected Speedup: 3-5x over Agave**

---

## Implementation Plan

### Step 1: Parallel Chunk Download (Priority)

```zig
// src/storage/parallel_download.zig
pub const ChunkDownloader = struct {
    allocator: Allocator,
    peers: []DiscoveredSnapshot,
    chunk_size: usize,  // e.g., 64MB chunks
    chunks: []ChunkStatus,
    output_file: fs.File,
    
    pub fn downloadParallel(self: *Self, num_threads: usize) !void {
        // Spawn download threads
        var threads: [16]?Thread = [_]?Thread{null} ** 16;
        
        for (0..num_threads) |i| {
            threads[i] = try Thread.spawn(.{}, downloadWorker, .{self, i});
        }
        
        // Wait for all
        for (threads) |t| {
            if (t) |thread| thread.join();
        }
    }
    
    fn downloadWorker(self: *Self, worker_id: usize) void {
        while (self.getNextChunk()) |chunk| {
            // Try fastest peer first
            const peer = self.selectFastestPeer();
            
            // HTTP Range request
            const range = try std.fmt.allocPrint(
                self.allocator,
                "bytes={d}-{d}",
                .{chunk.start, chunk.end}
            );
            
            // Download chunk
            // ... implementation
        }
    }
};
```

### Step 2: Peer Benchmarking

```zig
pub const PeerBenchmark = struct {
    peer: DiscoveredSnapshot,
    latency_ms: u32,      // RTT to peer
    bandwidth_mbps: u32,   // Measured download speed
    success_rate: f32,     // % of successful requests
    last_updated: i64,
    
    pub fn benchmark(peer: *DiscoveredSnapshot) !PeerBenchmark {
        // Download small test chunk and measure
    }
};
```

### Step 3: Resume Support

```zig
// Persist download state to disk
pub const ResumeState = struct {
    snapshot_slot: u64,
    snapshot_hash: [32]u8,
    total_size: u64,
    completed_chunks: []ChunkRange,
    
    pub fn save(self: *Self, path: []const u8) !void;
    pub fn load(allocator: Allocator, path: []const u8) !?ResumeState;
};
```

### Step 4: io_uring Integration

```zig
// Use io_uring for async file I/O
pub fn writeChunkAsync(ring: *IoUring, file: fs.File, chunk: []const u8, offset: u64) !void {
    const sqe = try ring.getSqe();
    sqe.prepWrite(file.handle, chunk, offset);
    // Submit and continue - don't block
}
```

---

## Installer Integration

The installer should audit fast catch-up prerequisites:

| Check | Issue ID | Auto-Fix |
|-------|----------|----------|
| Network bandwidth | CATCH001 | Info only |
| io_uring support | CATCH002 | Already in installer |
| Disk I/O speed | CATCH003 | Info only |
| Peer connectivity | CATCH004 | Firewall rules |

---

## Metrics to Track

During catch-up, Vexor should report:
- Download speed (MB/s)
- Peer count and health
- Chunks completed / total
- ETA to completion
- Shred repair progress (slots remaining)

---

## References

- Firedancer snapshot loading: https://github.com/firedancer-io/firedancer
- Agave snapshot-utils: https://github.com/anza-xyz/agave/tree/master/runtime/src/snapshot_utils
- HTTP Range requests: https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests


