#!/bin/bash
# run-network-tests.sh - Run Vexor network tests
#
# Usage:
#   ./scripts/run-network-tests.sh          # Run all tests (user mode)
#   sudo ./scripts/run-network-tests.sh     # Run all tests including AF_XDP
#   ./scripts/run-network-tests.sh quick    # Just capability detection
#   ./scripts/run-network-tests.sh traffic  # Just traffic simulation
#   ./scripts/run-network-tests.sh tiers    # Just tier testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_section() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"; }

check_memory() {
    local mem_info=$(free -m | awk 'NR==2{printf "Used: %sMB / Total: %sMB (%.1f%%)", $3, $2, $3*100/$2}')
    echo -e "${YELLOW}Memory:${NC} $mem_info"
}

MODE="${1:-all}"

log_section "VEXOR NETWORK TEST RUNNER"
check_memory
echo ""

if [[ $EUID -eq 0 ]]; then
    log_info "Running as root - AF_XDP tests will be available"
else
    log_info "Running as user - AF_XDP tests will be skipped"
    log_info "Run with sudo for full test coverage"
fi

case "$MODE" in
    quick|capability|caps)
        log_section "CAPABILITY DETECTION"
        zig run src/testing/network_capability_test.zig
        ;;
    
    traffic|sim)
        log_section "TRAFFIC SIMULATION"
        zig run src/testing/traffic_simulator.zig
        ;;
    
    tiers|tier)
        log_section "TIER TESTING"
        zig run src/testing/tier_test_harness.zig
        ;;
    
    all|full)
        log_section "COMPREHENSIVE TEST SUITE"
        zig run src/testing/root.zig
        ;;
    
    *)
        echo "Usage: $0 [quick|traffic|tiers|all]"
        echo ""
        echo "  quick   - Just capability detection (fastest)"
        echo "  traffic - Traffic simulation tests"
        echo "  tiers   - Test each networking tier"
        echo "  all     - Run complete test suite (default)"
        exit 1
        ;;
esac

echo ""
log_section "TEST COMPLETE"
check_memory
echo ""
