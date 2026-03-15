#!/bin/bash
# Vexor Safe Validator Launcher
# This script provides safe startup with crash protection to prevent kernel lockups
# from blocking SSH access. It includes:
# - Single-run mode (no auto-restart) for testing new binaries
# - Crash counter with automatic stop after N crashes
# - Quick rollback to known-good binary
# - Pre-flight health check before starting

set -euo pipefail

VEXOR_BIN="/home/sol/vexor/bin/vexor-validator"
VEXOR_BACKUP="/home/sol/vexor/bin/vexor-validator.known-good"
CRASH_COUNTER_FILE="/tmp/vexor-crash-count"
MAX_CRASHES=3
CRASH_WINDOW_SECONDS=300  # 5 minutes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[VEXOR]${NC} $1"; }
warn() { echo -e "${YELLOW}[VEXOR-WARN]${NC} $1"; }
error() { echo -e "${RED}[VEXOR-ERROR]${NC} $1"; }

# Pre-flight checks
preflight_check() {
    log "Running pre-flight checks..."
    
    # Check binary exists and is executable
    if [[ ! -x "$VEXOR_BIN" ]]; then
        error "Binary not found or not executable: $VEXOR_BIN"
        return 1
    fi
    
    # Check binary has correct capabilities
    if ! getcap "$VEXOR_BIN" 2>/dev/null | grep -q "cap_net"; then
        warn "Binary missing network capabilities. Run: sudo setcap cap_net_raw,cap_net_admin,cap_bpf+ep $VEXOR_BIN"
    fi
    
    # Check keypair files exist
    if [[ ! -f "/home/sol/.secrets/qubetest/validator-keypair.json" ]]; then
        error "Validator keypair not found"
        return 1
    fi
    
    # Check ledger directory
    if [[ ! -d "/home/sol/ledger" ]]; then
        warn "Creating ledger directory..."
        mkdir -p /home/sol/ledger
    fi
    
    log "Pre-flight checks passed"
    return 0
}

# Check crash history
check_crash_history() {
    if [[ -f "$CRASH_COUNTER_FILE" ]]; then
        local last_crash_time=$(cut -d: -f1 "$CRASH_COUNTER_FILE" 2>/dev/null || echo 0)
        local crash_count=$(cut -d: -f2 "$CRASH_COUNTER_FILE" 2>/dev/null || echo 0)
        local now=$(date +%s)
        
        # Reset counter if outside crash window
        if (( now - last_crash_time > CRASH_WINDOW_SECONDS )); then
            rm -f "$CRASH_COUNTER_FILE"
            return 0
        fi
        
        # Check if we've exceeded max crashes
        if (( crash_count >= MAX_CRASHES )); then
            error "Maximum crashes ($MAX_CRASHES) exceeded in ${CRASH_WINDOW_SECONDS}s window!"
            error "Binary appears unstable. NOT restarting."
            error ""
            error "To investigate: journalctl -u vexor-validator -n 200"
            error "To reset: rm $CRASH_COUNTER_FILE"
            error "To rollback: /home/sol/bin/vexor-safe-launch --rollback"
            return 1
        fi
    fi
    return 0
}

# Record a crash
record_crash() {
    local now=$(date +%s)
    local crash_count=1
    
    if [[ -f "$CRASH_COUNTER_FILE" ]]; then
        local last_crash_time=$(cut -d: -f1 "$CRASH_COUNTER_FILE" 2>/dev/null || echo 0)
        crash_count=$(cut -d: -f2 "$CRASH_COUNTER_FILE" 2>/dev/null || echo 0)
        
        # If within crash window, increment counter
        if (( now - last_crash_time <= CRASH_WINDOW_SECONDS )); then
            crash_count=$((crash_count + 1))
        else
            crash_count=1
        fi
    fi
    
    echo "${now}:${crash_count}" > "$CRASH_COUNTER_FILE"
    warn "Crash recorded: $crash_count of $MAX_CRASHES in window"
}

# Rollback to known-good binary
do_rollback() {
    if [[ ! -f "$VEXOR_BACKUP" ]]; then
        error "No known-good backup found at $VEXOR_BACKUP"
        return 1
    fi
    
    log "Rolling back to known-good binary..."
    cp "$VEXOR_BACKUP" "$VEXOR_BIN"
    chmod +x "$VEXOR_BIN"
    
    # Reapply capabilities
    sudo setcap cap_net_raw,cap_net_admin,cap_bpf+ep "$VEXOR_BIN"
    
    # Reset crash counter
    rm -f "$CRASH_COUNTER_FILE"
    
    log "Rollback complete!"
}

# Mark current binary as known-good
mark_good() {
    log "Marking current binary as known-good..."
    cp "$VEXOR_BIN" "$VEXOR_BACKUP"
    log "Backup saved to: $VEXOR_BACKUP"
}

# Run the validator
run_validator() {
    local mode="$1"
    
    log "Starting Vexor Validator..."
    log "Mode: $mode"
    log "Binary: $VEXOR_BIN"
    
    exec "$VEXOR_BIN" run \
        --bootstrap \
        --testnet \
        --identity /home/sol/.secrets/qubetest/validator-keypair.json \
        --vote-account /home/sol/.secrets/qubetest/vote-account-keypair.json \
        --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on \
        --known-validator 7XSY3MrYnK8vq693Rju17bbPkCN3Z7KvvfvJx4kdrsSY \
        --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN \
        --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv \
        --known-validator 6gPFU17pZ7rSHCs7Uqr2WC5LqZDEVQd9mDXVkHezcVkn \
        --known-validator J5e4xh1V7zGZnHq9rYfsowFJghoc9SEZWFfiCdbc8FF1 \
        --known-validator FT9QgTVo375TgDAQusTgpsfXqTosCJLfrBpoVdcbnhtS \
        --ledger /home/sol/ledger \
        --accounts /mnt/ramdisk/accounts \
        --snapshots /home/sol/restart_snapshots \
        --log /home/sol/vexor-validator.log \
        --public-ip YOUR_VALIDATOR_IP \
        --gossip-port 8001 \
        --tpu-port 8003 \
        --tvu-port 8004 \
        --rpc-port 8899 \
        --dynamic-port-range 8000-8010 \
        --expected-shred-version 27350 \
        --disable-io-uring \
        --enable-parallel-snapshot \
        --parallel-snapshot-threads 8 \
        --limit-ledger-size 50000000
}

# Main
case "${1:-run}" in
    run)
        # Normal run with crash protection
        if ! preflight_check; then
            exit 1
        fi
        if ! check_crash_history; then
            exit 2
        fi
        run_validator "protected"
        # If we get here, validator exited
        record_crash
        ;;
    test)
        # Single run for testing (no restart wrapper)
        log "TEST MODE: Single run, no auto-restart"
        if ! preflight_check; then
            exit 1
        fi
        run_validator "test"
        ;;
    rollback)
        do_rollback
        ;;
    mark-good)
        mark_good
        ;;
    reset)
        rm -f "$CRASH_COUNTER_FILE"
        log "Crash counter reset"
        ;;
    status)
        if [[ -f "$CRASH_COUNTER_FILE" ]]; then
            echo "Crash history: $(cat $CRASH_COUNTER_FILE)"
        else
            echo "No recent crashes"
        fi
        ;;
    *)
        echo "Usage: $0 {run|test|rollback|mark-good|reset|status}"
        echo ""
        echo "Commands:"
        echo "  run       - Start with crash protection (default)"
        echo "  test      - Single run for testing new binaries"
        echo "  rollback  - Restore known-good binary"
        echo "  mark-good - Mark current binary as known-good"
        echo "  reset     - Reset crash counter"
        echo "  status    - Show crash history"
        exit 1
        ;;
esac
