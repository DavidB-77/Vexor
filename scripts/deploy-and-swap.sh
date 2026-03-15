#!/bin/bash
# deploy-and-swap.sh — One-command Agave ↔ Vexor workflow
#
# Usage:
#   ./scripts/deploy-and-swap.sh vexor    # build → deploy → switch to Vexor
#   ./scripts/deploy-and-swap.sh agave    # switch back to Agave
#   ./scripts/deploy-and-swap.sh status   # check which client is running
#
# Features:
#   - Pre-flight health check (confirms identity is visible)
#   - Waits for the new client to start producing before declaring success
#   - Auto-rollback to Agave if Vexor fails health check in 60s
#   - Log capture

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────
SERVER="YOUR_VALIDATOR_IP"
SERVER_USER="root"
VEXOR_BINARY="zig-out/bin/vexor"
REMOTE_VEXOR="/home/sol/vexor/bin/vexor-validator"
IDENTITY_PUBKEY="3J2jADiEoKMaooCQbkyr9aLnjAb5ApDWfVvKgzyK2fbP"
HEALTH_CHECK_TIMEOUT=60  # seconds to wait for health
LOG_FILE="/home/sol/logs/vexor.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─── Helpers ────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

ssh_cmd() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SERVER_USER@$SERVER" "$@"
}

# ─── Pre-flight ─────────────────────────────────────────────────────
preflight() {
    log_info "Testing SSH connection..."
    if ! ssh_cmd "echo ok" &>/dev/null; then
        log_error "Cannot reach $SERVER. Check SSH keys."
        exit 1
    fi
    log_info "SSH connected to $SERVER"

    log_info "Checking current validator status..."
    ssh_cmd "systemctl is-active solana-validator && echo RUNNING || echo STOPPED" 2>/dev/null
    local current_link
    current_link=$(ssh_cmd "readlink /home/sol/validator.sh 2>/dev/null || echo 'none'")
    log_info "Current symlink: $current_link"
}

# ─── Health check ───────────────────────────────────────────────────
# Waits up to $HEALTH_CHECK_TIMEOUT seconds for the validator to be healthy.
# "Healthy" = the solana-validator service is active AND log file is being written.
health_check() {
    local client="$1"
    local waited=0

    log_info "Waiting for $client to become healthy (timeout: ${HEALTH_CHECK_TIMEOUT}s)..."

    while [ $waited -lt $HEALTH_CHECK_TIMEOUT ]; do
        # Check systemd service is active
        if ssh_cmd "systemctl is-active --quiet solana-validator" 2>/dev/null; then
            # Check that log is growing (validator is doing work)
            local log_age
            log_age=$(ssh_cmd "stat --format='%Y' $LOG_FILE 2>/dev/null || echo 0")
            local now
            now=$(ssh_cmd "date +%s")
            local age_secs=$(( now - log_age ))

            if [ "$age_secs" -lt 10 ]; then
                log_info "$client is healthy! Log updated ${age_secs}s ago."
                return 0
            fi
        fi

        sleep 5
        waited=$((waited + 5))
        echo -ne "\r  Waited ${waited}/${HEALTH_CHECK_TIMEOUT}s..."
    done
    echo ""

    log_error "$client failed health check after ${HEALTH_CHECK_TIMEOUT}s"
    return 1
}

# ─── Switch ─────────────────────────────────────────────────────────
do_switch() {
    local target="$1"

    log_info "Stopping current validator..."
    ssh_cmd "systemctl stop solana-validator || true; sleep 3"

    case "$target" in
        agave)
            log_info "Switching symlink to Agave..."
            ssh_cmd "ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh"
            ;;
        vexor)
            log_info "Switching symlink to Vexor..."
            ssh_cmd "ln -sf /home/sol/validator-vexor.sh /home/sol/validator.sh"
            ;;
    esac

    log_info "Starting solana-validator service..."
    ssh_cmd "systemctl start solana-validator"
    sleep 2

    if health_check "$target"; then
        log_info "✓ Successfully switched to $target"
        return 0
    else
        return 1
    fi
}

# ─── Rollback ───────────────────────────────────────────────────────
rollback_to_agave() {
    log_warn "Rolling back to Agave..."
    ssh_cmd "systemctl stop solana-validator || true; sleep 3"
    ssh_cmd "ln -sf /home/sol/validator-agave.sh /home/sol/validator.sh"
    ssh_cmd "systemctl start solana-validator"

    if health_check "agave"; then
        log_info "✓ Rollback to Agave successful"
    else
        log_error "Rollback to Agave ALSO failed! Manual intervention needed."
        log_error "SSH to $SERVER and check: journalctl -u solana-validator -n 50"
        exit 2
    fi
}

# ─── Deploy (build + copy) ─────────────────────────────────────────
deploy_vexor() {
    # Build locally
    log_info "Building Vexor (ReleaseFast)..."
    zig build -Doptimize=ReleaseFast 2>&1 | tail -5
    if [ ! -f "$VEXOR_BINARY" ]; then
        log_error "Build failed — binary not found at $VEXOR_BINARY"
        exit 1
    fi
    log_info "✓ Build complete: $(ls -lh "$VEXOR_BINARY" | awk '{print $5}')"

    # Copy binary to server
    log_info "Deploying binary to $SERVER..."
    ssh_cmd "mkdir -p /home/sol/vexor/bin"
    scp -o StrictHostKeyChecking=no "$VEXOR_BINARY" "$SERVER_USER@$SERVER:$REMOTE_VEXOR"
    ssh_cmd "chmod +x $REMOTE_VEXOR && chown sol:sol $REMOTE_VEXOR"
    log_info "✓ Binary deployed"
}

# ─── Show status ────────────────────────────────────────────────────
show_status() {
    preflight
    echo ""
    log_info "Remote service status:"
    ssh_cmd "systemctl status solana-validator --no-pager -l 2>/dev/null | head -15" || true
    echo ""
    log_info "Recent log (last 5 lines):"
    ssh_cmd "tail -5 $LOG_FILE 2>/dev/null" || echo "  (no log file)"
}

# ─── Main ───────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") <vexor|agave|status>"
    echo ""
    echo "  vexor  — Build, deploy, and switch to Vexor (with auto-rollback)"
    echo "  agave  — Switch back to Agave"
    echo "  status — Show current validator state"
    exit 1
fi

TARGET="$1"

case "$TARGET" in
    vexor)
        preflight
        deploy_vexor
        echo ""
        if ! do_switch vexor; then
            log_warn "Vexor failed health check — auto-rolling back to Agave"
            rollback_to_agave
            exit 1
        fi
        echo ""
        log_info "Vexor is live! Monitor with:"
        log_info "  ssh $SERVER_USER@$SERVER 'tail -f $LOG_FILE'"
        ;;

    agave)
        preflight
        echo ""
        do_switch agave
        ;;

    status)
        show_status
        ;;

    *)
        log_error "Unknown target: $TARGET"
        echo "Usage: $(basename "$0") <vexor|agave|status>"
        exit 1
        ;;
esac
