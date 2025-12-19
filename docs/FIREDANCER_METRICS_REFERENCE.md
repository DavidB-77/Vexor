# Firedancer Metrics System Reference

This document describes how Firedancer implements its metrics and monitoring system.
This serves as a reference for future Vexor improvements.

## Overview

Firedancer's metrics system is designed for:
1. **Zero-overhead writes** - Metrics are written to shared memory with atomic operations
2. **High-frequency updates** - Core loop metrics are batched and drained during housekeeping
3. **Prometheus compatibility** - Exposed via HTTP endpoint (default port 7999)
4. **Real-time monitoring** - Console-based `fdctl monitor` command

## Architecture

### Shared Memory Layout

```
[ in_link_N ulong ]           <- Number of input links
[ out_link_N ulong]           <- Number of output links
[ in_link_0_metrics ... ]     <- Per-link input metrics
[ out_link_0_metrics ... ]    <- Per-link output metrics
[ tile_metrics ]              <- Tile-specific metrics
```

All values are `ulong` (8 bytes). This layout minimizes cache line sharing.

### Key Constants

```c
#define FD_METRICS_ALIGN (128UL)  // Cache-line aligned

// TPS History
#define FD_GUI_TPS_HISTORY_WINDOW_DURATION_SECONDS (10L)
#define FD_GUI_TPS_HISTORY_SAMPLE_CNT (150UL)  // 150 samples = 25 minutes history

// Slots tracked
#define FD_GUI_SLOTS_CNT (864000UL)  // 2x epoch (432,000 slots)
```

### Metric Types

1. **GAUGE** - Current value (e.g., PID, connection count)
2. **COUNTER** - Monotonically increasing (e.g., packets received)
3. **HISTOGRAM** - Distribution buckets with sum/count

### Thread-Local Storage

```c
extern FD_TL ulong * fd_metrics_base_tl;     // Base of entire metrics region
extern FD_TL volatile ulong * fd_metrics_tl;  // Base of tile-specific metrics
```

Threads register once via `fd_metrics_register(metrics)`.

## Metric Access Macros

```c
// Set a gauge value
FD_MGAUGE_SET( group, measurement, value );
// Example: FD_MGAUGE_SET( QUIC, CONNECTIONS_CREATED_COUNT, conn_cnt );

// Get a gauge value
FD_MGAUGE_GET( group, measurement );

// Increment a counter
FD_MCNT_INC( group, measurement, value );

// Set a counter (for batched updates)
FD_MCNT_SET( group, measurement, value );

// Copy histogram buckets
FD_MHIST_COPY( group, measurement, hist );
```

All macros compile to a single memory write at a computed offset.

## TPS Calculation

Firedancer calculates TPS from completed slots within a time window:

```c
static void fd_gui_estimated_tps_snap( fd_gui_t * gui ) {
    ulong total_txn_cnt = 0UL;
    ulong vote_txn_cnt = 0UL;
    ulong nonvote_failed_txn_cnt = 0UL;

    // Iterate through recent completed slots
    for( ulong i=0UL; i<fd_ulong_min( gui->summary.slot_completed+1UL, FD_GUI_SLOTS_CNT ); i++ ) {
        ulong _slot = gui->summary.slot_completed - i;
        fd_gui_slot_t const * slot = fd_gui_get_slot_const( gui, _slot );

        // Skip if slot too old (outside 10-second window)
        if( slot->completed_time + FD_GUI_TPS_HISTORY_WINDOW_DURATION_SECONDS*1e9 < gui->next_sample ) break;

        // Skip slots that were skipped
        if( slot->skipped ) continue;

        total_txn_cnt += slot->total_txn_cnt;
        vote_txn_cnt += slot->vote_txn_cnt;
        nonvote_failed_txn_cnt += slot->nonvote_failed_txn_cnt;
    }

    // Store in circular buffer
    gui->summary.estimated_tps_history[ gui->summary.estimated_tps_history_idx ][ 0 ] = total_txn_cnt;
    gui->summary.estimated_tps_history[ gui->summary.estimated_tps_history_idx ][ 1 ] = vote_txn_cnt;
    gui->summary.estimated_tps_history[ gui->summary.estimated_tps_history_idx ][ 2 ] = nonvote_failed_txn_cnt;
    gui->summary.estimated_tps_history_idx = (gui->summary.estimated_tps_history_idx+1UL) % FD_GUI_TPS_HISTORY_SAMPLE_CNT;
}
```

TPS is then calculated as: `total_txn_cnt / FD_GUI_TPS_HISTORY_WINDOW_DURATION_SECONDS`

### TPS Categories

Firedancer tracks 4 TPS categories:
- **total** - All transactions
- **vote** - Vote transactions
- **nonvote_success** - Non-vote successful transactions
- **nonvote_failed** - Non-vote failed transactions

## Console Monitor (`fdctl monitor`)

The monitor takes periodic snapshots and calculates deltas:

```c
typedef struct {
    ulong pid;
    ulong heartbeat;
    ulong status;
    ulong in_backp;
    ulong backp_cnt;
    ulong nvcsw;           // Voluntary context switches
    ulong nivcsw;          // Involuntary context switches
    ulong regime_ticks[9]; // Time spent in different processing regimes
} tile_snap_t;
```

### Tile Regimes

Each tile tracks time spent in 9 regimes:
0-2: Housekeeping (caught up, processing, backpressure)
3-5: Prefrag processing
6-7: Postfrag processing

This allows calculating:
- `% hkeep` - Time in housekeeping
- `% wait` - Time waiting for work
- `% backp` - Time in backpressure
- `% finish` - Time processing

### Link Metrics

For each link between tiles:
- `tot TPS` - Total transactions per second
- `tot bps` - Total bits per second
- `uniq TPS/bps` - Unique (non-duplicate) rates
- `ha tr%` - High-availability throughput percentage
- `filt tr%` - Filtered throughput percentage
- `ovrnp cnt` - Overrun while polling count
- `ovrnr cnt` - Overrun while reading count
- `slow cnt` - Slow consumer count

## Network Tile Metrics (XDP)

From `metrics.xml`:

```xml
<tile name="net">
    <counter name="RxPktCnt" summary="Packet receive count." />
    <counter name="RxBytesTotal" summary="Total bytes received." />
    <counter name="TxSubmitCnt" summary="Packet transmit jobs submitted." />
    <counter name="TxCompleteCnt" summary="Transmit jobs completed by kernel." />

    <!-- XDP-specific -->
    <counter name="XskTxWakeupCnt" summary="XSK sendto syscalls dispatched." />
    <counter name="XskRxWakeupCnt" summary="XSK recvmsg syscalls dispatched." />
    <counter name="XdpRxDroppedOther" summary="Dropped for other reasons" />
    <counter name="XdpRxRingFull" summary="Dropped due to rx ring full" />
</tile>
```

## Prometheus HTTP Endpoint

Default: `http://localhost:7999/metrics`

Output format:
```
# HELP tile_pid The process ID of the tile.
# TYPE tile_pid gauge
tile_pid{kind="net",kind_id="0"} 1108973
tile_pid{kind="quic",kind_id="0"} 1108975
```

## GUI WebSocket API

The GUI sends JSON updates via WebSocket:

```json
{
    "type": "summary",
    "key": "estimated_tps",
    "value": {
        "total": 50000.0,
        "vote": 10000.0,
        "nonvote_success": 35000.0,
        "nonvote_failed": 5000.0
    }
}
```

## Performance Considerations

### For High-Frequency Metrics

1. **Batch updates locally** in the tile
2. **Drain to shared memory** during housekeeping (every few ms)
3. **Use atomic writes** to prevent torn reads

Example:
```c
// In core loop - accumulate locally
local_pkt_cnt++;

// In housekeeping - drain to shared memory
FD_MCNT_SET( NET, RX_PKT_CNT, local_pkt_cnt );
```

### For Low-Frequency Metrics

Direct atomic writes are acceptable:
```c
FD_MCNT_INC( QUIC, CONNECTIONS_CREATED_COUNT, 1 );
```

## Comparison: Firedancer vs Vexor

| Aspect | Firedancer | Vexor (Current) |
|--------|------------|-----------------|
| Storage | Shared memory (mmap) | Atomic struct fields |
| Access | Compile-time offset macros | Runtime atomic ops |
| TPS Calc | From completed slots | From snapshot deltas |
| Output | Prometheus + WebSocket | Console + Prometheus |
| History | 25min rolling (150 samples) | 1min rolling (60 samples) |

## Recommendations for Vexor

1. **Keep atomic fields** - Simpler than shared memory for single-process
2. **Increase history** - Consider 150+ samples for better averaging
3. **Add link metrics** - Track inter-module throughput
4. **Add regime tracking** - Measure where time is spent
5. **Consider batched updates** - For very hot paths
6. **Add histogram support** - For latency distributions

## Key Metrics for Performance Benchmarking

| Metric | Target (Firedancer-like) |
|--------|--------------------------|
| TPS | 1,000,000+ |
| Packets/sec | 30,000,000 (with XDP zero-copy) |
| Shreds/sec | 100,000+ |
| Latency p99 | < 1ms per slot |
| Vote latency | < 50ms |
| Backpressure % | < 1% |
| Context switches | < 100/sec |

## Files Reference (Firedancer)

- `src/disco/metrics/fd_metrics.h` - Core metrics macros
- `src/disco/metrics/fd_metrics_base.h` - Metric types and declarations
- `src/disco/metrics/metrics.xml` - All metric definitions
- `src/disco/gui/fd_gui.c` - TPS calculation and GUI state
- `src/disco/gui/fd_gui_printf.c` - JSON output formatting
- `src/app/shared/commands/monitor/monitor.c` - Console monitor

---

*Document created: December 16, 2024*
*Reference: Firedancer commit (local repo at /home/dbdev/external/firedancer)*

