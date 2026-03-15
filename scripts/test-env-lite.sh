#!/bin/bash
# test-env-lite.sh - Ultra-lightweight test environment for Vexor
# Memory usage: < 5 MB total (all kernel-space)
#
# Usage:
#   ./scripts/test-env-lite.sh setup    # Create test environment
#   ./scripts/test-env-lite.sh teardown # Remove test environment
#   ./scripts/test-env-lite.sh status   # Check if running
#   ./scripts/test-env-lite.sh test     # Run quick connectivity test

set -e

ACTION="${1:-help}"
NAME="vxtest"
HOST_IP="10.99.0.1"
NS_IP="10.99.0.2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        echo "Run with: sudo $0 $ACTION"
        exit 1
    fi
}

do_setup() {
    check_root
    log_info "Creating lightweight test environment: $NAME"
    
    # Cleanup any existing environment first
    do_teardown_quiet
    
    # Create network namespace (kernel only, ~0 MB userspace)
    log_info "Creating network namespace..."
    ip netns add $NAME
    
    # Create veth pair (kernel only, ~0 MB userspace)
    log_info "Creating veth pair..."
    ip link add $NAME type veth peer name veth0
    
    # Move one end to namespace
    ip link set veth0 netns $NAME
    
    # Configure host side
    log_info "Configuring host interface ($NAME: $HOST_IP)..."
    ip addr add $HOST_IP/24 dev $NAME
    ip link set $NAME up
    
    # Configure namespace side
    log_info "Configuring namespace interface (veth0: $NS_IP)..."
    ip netns exec $NAME ip addr add $NS_IP/24 dev veth0
    ip netns exec $NAME ip link set veth0 up
    ip netns exec $NAME ip link set lo up
    
    # Disable offloads that can interfere with XDP testing
    log_info "Disabling NIC offloads for testing..."
    ethtool -K $NAME tx off rx off gso off gro off tso off 2>/dev/null || true
    ip netns exec $NAME ethtool -K veth0 tx off rx off gso off gro off tso off 2>/dev/null || true
    
    echo ""
    log_info "Test environment ready!"
    echo ""
    echo "  ┌─────────────────────────┐     ┌─────────────────────────┐"
    echo "  │    Root Namespace       │     │  Namespace: $NAME       │"
    echo "  │                         │     │                         │"
    echo "  │  $NAME ($HOST_IP)  ◄────────►  veth0 ($NS_IP)     │"
    echo "  │                         │     │                         │"
    echo "  │  [Vexor binds here]     │     │  [Traffic gen here]     │"
    echo "  └─────────────────────────┘     └─────────────────────────┘"
    echo ""
    echo "Commands:"
    echo "  # Test Vexor networking (from project root):"
    echo "  sudo ./zig-out/bin/vexor --interface $NAME --test-mode"
    echo ""
    echo "  # Generate test traffic:"
    echo "  sudo ip netns exec $NAME bash -c 'echo test | nc -u -w1 $HOST_IP 8001'"
    echo ""
    echo "  # Enter namespace shell:"
    echo "  sudo ip netns exec $NAME bash"
    echo ""
    echo "  # Cleanup:"
    echo "  sudo $0 teardown"
}

do_teardown() {
    check_root
    log_info "Tearing down test environment: $NAME"
    do_teardown_quiet
    log_info "Cleanup complete"
}

do_teardown_quiet() {
    ip netns del $NAME 2>/dev/null || true
    ip link del $NAME 2>/dev/null || true
}

do_status() {
    if ip netns list 2>/dev/null | grep -q "^$NAME"; then
        log_info "Test environment is ACTIVE"
        echo ""
        echo "Host interface:"
        ip addr show $NAME 2>/dev/null | grep -E "inet|state" || echo "  (not found)"
        echo ""
        echo "Namespace interface:"
        ip netns exec $NAME ip addr show veth0 2>/dev/null | grep -E "inet|state" || echo "  (not found)"
    else
        log_warn "Test environment is NOT running"
        echo "Run: sudo $0 setup"
    fi
}

do_test() {
    check_root
    
    if ! ip netns list 2>/dev/null | grep -q "^$NAME"; then
        log_error "Test environment not running. Run: sudo $0 setup"
        exit 1
    fi
    
    log_info "Running connectivity test..."
    
    # Test ping from namespace to host
    echo -n "  Ping from namespace to host: "
    if ip netns exec $NAME ping -c 1 -W 1 $HOST_IP >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Test ping from host to namespace
    echo -n "  Ping from host to namespace: "
    if ping -c 1 -W 1 $NS_IP >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    # Test UDP (start a listener, send a packet)
    echo -n "  UDP connectivity test: "
    
    # Start UDP listener in background (times out after 2 seconds)
    timeout 2 nc -u -l $HOST_IP 9999 > /tmp/vexor_udp_test 2>/dev/null &
    NC_PID=$!
    sleep 0.2
    
    # Send UDP packet from namespace
    ip netns exec $NAME bash -c "echo 'VEXOR_TEST' | nc -u -w1 $HOST_IP 9999" 2>/dev/null || true
    sleep 0.3
    
    # Check if received
    if grep -q "VEXOR_TEST" /tmp/vexor_udp_test 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}TIMEOUT${NC} (may still work)"
    fi
    
    kill $NC_PID 2>/dev/null || true
    rm -f /tmp/vexor_udp_test
    
    echo ""
    log_info "Connectivity tests complete"
}

do_help() {
    echo "Vexor Lightweight Test Environment"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup     Create the test environment (veth + namespace)"
    echo "  teardown  Remove the test environment"
    echo "  status    Check if test environment is running"
    echo "  test      Run connectivity tests"
    echo "  help      Show this help"
    echo ""
    echo "Resource usage: < 5 MB (all kernel-space, no heavy processes)"
}

case "$ACTION" in
    setup)    do_setup ;;
    teardown) do_teardown ;;
    status)   do_status ;;
    test)     do_test ;;
    help|-h|--help) do_help ;;
    *)
        log_error "Unknown command: $ACTION"
        do_help
        exit 1
        ;;
esac
