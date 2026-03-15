#!/bin/bash
# swap-validator.sh — Graceful Agave ↔ Vexor swap with health check
#
# Run ON the validator (as sol user with sudo):
#   ./swap-validator.sh vexor     # Stop Agave → sleep → start Vexor
#   ./swap-validator.sh agave     # Stop Vexor → sleep → start Agave
#   ./swap-validator.sh status    # Show what's running
#
# Run FROM dev machine (via SSH):
#   ssh vexor-validator "./swap-validator.sh vexor"
#   ssh vexor-validator "./swap-validator.sh agave"
#
# Environment overrides:
#   SWAP_DELAY=20 ./swap-validator.sh vexor   (default: 15 seconds)
#   HEALTH_TIMEOUT=90 ./swap-validator.sh vexor (default: 60 seconds)
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────
SWAP_DELAY="${SWAP_DELAY:-15}"           # seconds between stop and start
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"   # seconds to wait for health
SUDO_PASS="${SUDO_PASS:?Set SUDO_PASS environment variable}"

AGAVE_SERVICE="solana-validator"
VEXOR_SERVICE="vexor-validator"

AGAVE_LOG="/home/sol/solana-validator.log"
VEXOR_LOG="/home/sol/vexor-validator.log"

RPC_URL="http://localhost:8899"

# ─── Colors ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step()  { echo -e "${CYAN}[→]${NC} ${BOLD}$*${NC}"; }

do_sudo() {
    echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
}

is_running() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

get_log_for() {
    case "$1" in
        agave) echo "$AGAVE_LOG" ;;
        vexor) echo "$VEXOR_LOG" ;;
    esac
}

get_service_for() {
    case "$1" in
        agave) echo "$AGAVE_SERVICE" ;;
        vexor) echo "$VEXOR_SERVICE" ;;
    esac
}

get_other() {
    case "$1" in
        agave) echo "vexor" ;;
        vexor) echo "agave" ;;
    esac
}

# ─── Health Check ───────────────────────────────────────────────────
# Waits for: (1) systemd service active, (2) log file updating, (3) RPC responding
health_check() {
    local client="$1"
    local service
    service=$(get_service_for "$client")
    local log_file
    log_file=$(get_log_for "$client")
    local waited=0

    log_step "Waiting for $client to become healthy (timeout: ${HEALTH_TIMEOUT}s)..."

    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        # Check 1: systemd service is active
        if is_running "$service"; then
            # Check 2: log file is being written (within last 15 seconds)
            if [ -f "$log_file" ]; then
                local log_age
                log_age=$(stat --format='%Y' "$log_file" 2>/dev/null || echo 0)
                local now
                now=$(date +%s)
                local age_secs=$(( now - log_age ))

                if [ "$age_secs" -lt 15 ]; then
                    # Check 3: RPC is responding (optional — may take longer)
                    local rpc_ok=false
                    if curl -s --max-time 3 "$RPC_URL" \
                        -X POST -H 'Content-Type: application/json' \
                        -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' \
                        2>/dev/null | grep -q "result"; then
                        rpc_ok=true
                    fi

                    if $rpc_ok; then
                        log_info "$client is healthy! Service active, log fresh (${age_secs}s ago), RPC responding."
                    else
                        log_info "$client is alive! Service active, log fresh (${age_secs}s ago). RPC not yet responding (normal during catchup)."
                    fi
                    return 0
                fi
            fi
        fi

        sleep 5
        waited=$((waited + 5))
        printf "\r  Waited %d/%ds..." "$waited" "$HEALTH_TIMEOUT"
    done
    echo ""

    log_error "$client failed health check after ${HEALTH_TIMEOUT}s"
    return 1
}

# ─── Graceful Stop ──────────────────────────────────────────────────
graceful_stop() {
    local client="$1"
    local service
    service=$(get_service_for "$client")

    if ! is_running "$service"; then
        log_info "$client ($service) is already stopped."
        return 0
    fi

    log_step "Stopping $client ($service)..."
    do_sudo systemctl stop "$service" || true

    # Wait for process to fully exit (up to 30s)
    local waited=0
    while is_running "$service" && [ "$waited" -lt 30 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    if is_running "$service"; then
        log_warn "$client did not stop cleanly after 30s, force-killing..."
        do_sudo systemctl kill -s KILL "$service" 2>/dev/null || true
        sleep 2
    fi

    log_info "$client stopped."
}

# ─── Swap ───────────────────────────────────────────────────────────
do_swap() {
    local target="$1"
    local current
    current=$(get_other "$target")
    local target_service
    target_service=$(get_service_for "$target")

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Swapping: ${RED}$current${NC} ${BOLD}→ ${GREEN}$target${NC}"
    echo -e "${BOLD}  Delay: ${SWAP_DELAY}s  |  Health timeout: ${HEALTH_TIMEOUT}s${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""

    # Step 1: Stop the current client
    graceful_stop "$current"

    # Step 2: Sleep to let network state settle
    log_step "Sleeping ${SWAP_DELAY}s to let network state settle..."
    local i=0
    while [ "$i" -lt "$SWAP_DELAY" ]; do
        sleep 1
        i=$((i + 1))
        printf "\r  %d/%ds..." "$i" "$SWAP_DELAY"
    done
    echo ""
    log_info "Sleep complete."

    # Step 3: Start the target client
    log_step "Starting $target ($target_service)..."
    do_sudo systemctl start "$target_service"
    sleep 2

    # Step 4: Health check
    if health_check "$target"; then
        echo ""
        echo -e "${BOLD}═══════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}✓ Successfully swapped to $target!${NC}"
        echo -e "${BOLD}═══════════════════════════════════════════${NC}"
        echo ""
        echo "Monitor:"
        local log_file
        log_file=$(get_log_for "$target")
        echo "  tail -f $log_file"
        echo "  curl -s $RPC_URL -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}'"
        return 0
    else
        log_error "$target failed to start properly!"
        echo ""

        # Auto-rollback
        log_warn "Auto-rolling back to $current..."
        do_sudo systemctl stop "$target_service" 2>/dev/null || true
        sleep 5
        do_sudo systemctl start "$(get_service_for "$current")"

        if health_check "$current"; then
            log_info "Rollback to $current successful."
        else
            log_error "Rollback ALSO failed! Manual intervention needed."
            echo "  ssh vexor-validator"
            echo "  sudo systemctl status $AGAVE_SERVICE --no-pager"
            echo "  sudo journalctl -u $AGAVE_SERVICE -n 50"
        fi
        return 1
    fi
}

# ─── Status ─────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo -e "${BOLD}═══ Validator Status ═══${NC}"
    echo ""

    # Service status
    if is_running "$AGAVE_SERVICE"; then
        echo -e "  Agave:  ${GREEN}RUNNING${NC}"
    else
        echo -e "  Agave:  ${RED}STOPPED${NC}"
    fi

    if is_running "$VEXOR_SERVICE"; then
        echo -e "  Vexor:  ${GREEN}RUNNING${NC}"
    else
        echo -e "  Vexor:  ${RED}STOPPED${NC}"
    fi

    # Process info
    echo ""
    echo -e "${BOLD}═══ Processes ═══${NC}"
    ps aux | grep -E "agave-validator|vexor-validator|vexor run" | grep -v grep \
        | awk '{printf "  PID:%-8s CPU:%-6s MEM:%-6s CMD:%s\n", $2, $3"%", $4"%", $11}' \
        || echo "  (none)"

    # RPC check
    echo ""
    echo -e "${BOLD}═══ RPC ═══${NC}"
    local rpc_result
    rpc_result=$(curl -s --max-time 3 "$RPC_URL" \
        -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getVersion"}' 2>/dev/null || echo "unavailable")
    echo "  $rpc_result"

    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") <vexor|agave|status>"
    echo ""
    echo "  vexor  — Stop Agave → sleep → start Vexor (with auto-rollback)"
    echo "  agave  — Stop Vexor → sleep → start Agave (with auto-rollback)"
    echo "  status — Show what's running"
    echo ""
    echo "Environment:"
    echo "  SWAP_DELAY=20    Sleep seconds between stop/start (default: 15)"
    echo "  HEALTH_TIMEOUT=90 Health check timeout (default: 60)"
    exit 1
fi

case "$1" in
    vexor)
        do_swap vexor
        ;;
    agave)
        do_swap agave
        ;;
    status)
        show_status
        ;;
    *)
        log_error "Unknown target: $1"
        echo "Valid options: vexor, agave, status"
        exit 1
        ;;
esac
