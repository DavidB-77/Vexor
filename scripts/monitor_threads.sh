#!/bin/bash
# Thread Leak Monitor for Vexor Validator
# Usage: ./monitor_threads.sh [PID]
# If no PID provided, finds the vexor process automatically

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get PID
if [ -n "$1" ]; then
    PID=$1
else
    PID=$(pgrep -x vexor 2>/dev/null || pgrep -f "vexor" 2>/dev/null | head -1)
    if [ -z "$PID" ]; then
        echo -e "${RED}Error: vexor process not found${NC}"
        echo "Usage: $0 [PID]"
        exit 1
    fi
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Thread Leak Monitor - PID: $PID${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Initial counts
PREV_THREADS=0
START_TIME=$(date +%s)

while true; do
    if ! kill -0 $PID 2>/dev/null; then
        echo -e "${RED}Process $PID has terminated${NC}"
        exit 1
    fi

    # Get thread count from /proc/[pid]/status
    THREADS=$(grep "Threads:" /proc/$PID/status 2>/dev/null | awk '{print $2}')
    
    # Count thread types from /proc/[pid]/task
    TASK_DIR="/proc/$PID/task"
    IO_URING_WORKERS=0
    USERLAND=0
    OTHER=0
    
    if [ -d "$TASK_DIR" ]; then
        for tid in $(ls "$TASK_DIR" 2>/dev/null); do
            COMM=$(cat "$TASK_DIR/$tid/comm" 2>/dev/null || echo "unknown")
            case "$COMM" in
                iou-wrk-*|io_wq*)
                    ((IO_URING_WORKERS++))
                    ;;
                iou-sqp-*)
                    ((OTHER++))
                    ;;
                kworker/*)
                    ((OTHER++))
                    ;;
                *)
                    ((USERLAND++))
                    ;;
            esac
        done
    fi
    
    # Calculate delta
    DELTA=$((THREADS - PREV_THREADS))
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    
    # Color based on delta
    if [ $DELTA -gt 10 ]; then
        DELTA_COLOR=$RED
    elif [ $DELTA -gt 0 ]; then
        DELTA_COLOR=$YELLOW
    else
        DELTA_COLOR=$GREEN
    fi
    
    # Format output
    printf "\r[%s] Threads: %-6d (Δ: %s%+d${NC}) | Userland: %-4d | io_uring: %-4d | Other: %-4d | Elapsed: %ds   " \
        "$(date +%H:%M:%S)" "$THREADS" "$DELTA_COLOR" "$DELTA" "$USERLAND" "$IO_URING_WORKERS" "$OTHER" "$ELAPSED"
    
    # Alert thresholds
    if [ $THREADS -gt 10000 ]; then
        echo ""
        echo -e "${RED}🚨 CRITICAL: Thread count exceeds 10,000!${NC}"
    elif [ $THREADS -gt 1000 ]; then
        echo ""
        echo -e "${YELLOW}⚠️  WARNING: Thread count exceeds 1,000${NC}"
    fi
    
    if [ $IO_URING_WORKERS -gt 100 ]; then
        echo ""
        echo -e "${RED}🚨 io_uring worker explosion: $IO_URING_WORKERS workers!${NC}"
    fi
    
    PREV_THREADS=$THREADS
    sleep 2
done
