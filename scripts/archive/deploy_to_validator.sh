#!/bin/bash
# Deploy Vexor to validator and set up eBPF testing
# Usage: ./scripts/deploy_to_validator.sh [validator_host]

set -e

# Load credentials if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.credentials" ]; then
    source "$SCRIPT_DIR/../.credentials"
fi

VALIDATOR_HOST="${1:-${VALIDATOR_HOST:-38.92.24.174}}"
VALIDATOR_USER="${VALIDATOR_USER:-davidb}"
VALIDATOR_PASSWORD="${VALIDATOR_PASSWORD:-<REMOVED>}"
REMOTE_DIR="/home/davidb/bin/vexor"
REMOTE_PATH="/home/davidb/bin/vexor/vexor"
REMOTE_BPF_PATH="/home/davidb/bin/vexor/bpf"

# Check for sshpass (needed for password auth)
if ! command -v sshpass &> /dev/null; then
    echo "⚠️  sshpass not found. Install with: sudo apt-get install sshpass"
    echo "   Or set up SSH keys for passwordless access"
    USE_SSHPASS=false
else
    USE_SSHPASS=true
    export SSHPASS="$VALIDATOR_PASSWORD"
fi

echo "🚀 Deploying Vexor to validator: $VALIDATOR_HOST"
echo ""

# 1. Build locally
echo "📦 Building Vexor locally..."
cd "$(dirname "$0")/.."

# Try to build with AF_XDP, fallback to regular build if clang not available
if command -v clang &> /dev/null; then
    echo "   Building with AF_XDP enabled..."
    zig build -Daf_xdp=true
    if [ -f "zig-out/bpf/xdp_filter.o" ]; then
        echo "✅ Build complete with BPF program"
        HAS_BPF=true
    else
        echo "⚠️  BPF program not compiled, will compile on validator"
        HAS_BPF=false
    fi
else
    echo "⚠️  clang not found - building without BPF (will compile on validator)"
    zig build
    HAS_BPF=false
fi
echo "✅ Binary built"

# 2. Create remote directories
echo "📁 Creating remote directories..."
if [ "$USE_SSHPASS" = true ]; then
    sshpass -e ssh -o StrictHostKeyChecking=no "$VALIDATOR_USER@$VALIDATOR_HOST" "mkdir -p $REMOTE_BPF_PATH || (echo '$VALIDATOR_PASSWORD' | sudo -S mkdir -p $REMOTE_BPF_PATH && sudo chown -R $VALIDATOR_USER:$VALIDATOR_USER $REMOTE_DIR)"
else
    ssh "$VALIDATOR_USER@$VALIDATOR_HOST" "mkdir -p $REMOTE_BPF_PATH"
fi

# 3. Copy binary
echo "📤 Copying binary..."
if [ "$USE_SSHPASS" = true ]; then
    sshpass -e ssh -o StrictHostKeyChecking=no "$VALIDATOR_USER@$VALIDATOR_HOST" "mkdir -p $REMOTE_DIR || (echo '$VALIDATOR_PASSWORD' | sudo -S mkdir -p $REMOTE_DIR && sudo chown -R $VALIDATOR_USER:$VALIDATOR_USER $REMOTE_DIR)"
    sshpass -e scp -o StrictHostKeyChecking=no zig-out/bin/vexor "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_PATH"
else
    ssh "$VALIDATOR_USER@$VALIDATOR_HOST" "mkdir -p $REMOTE_DIR"
    scp zig-out/bin/vexor "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_PATH"
fi

# 4. Copy BPF program (if compiled) or compile on validator
if [ "$HAS_BPF" = true ]; then
    echo "📤 Copying BPF program..."
    if [ "$USE_SSHPASS" = true ]; then
        sshpass -e scp -o StrictHostKeyChecking=no zig-out/bpf/xdp_filter.o "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_BPF_PATH/"
    else
        scp zig-out/bpf/xdp_filter.o "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_BPF_PATH/"
    fi
else
    echo "📤 Compiling BPF program on validator..."
    # Copy source and compile on validator
    if [ "$USE_SSHPASS" = true ]; then
        sshpass -e scp -o StrictHostKeyChecking=no src/network/af_xdp/bpf/xdp_filter.c "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_BPF_PATH/"
        sshpass -e ssh -o StrictHostKeyChecking=no "$VALIDATOR_USER@$VALIDATOR_HOST" "cd $REMOTE_BPF_PATH && clang -O2 -target bpf -c xdp_filter.c -o xdp_filter.o -I . 2>&1 || (echo 'Installing clang...' && echo '$VALIDATOR_PASSWORD' | sudo -S apt-get install -y clang && clang -O2 -target bpf -c xdp_filter.c -o xdp_filter.o -I .)"
    else
        scp src/network/af_xdp/bpf/xdp_filter.c "$VALIDATOR_USER@$VALIDATOR_HOST:$REMOTE_BPF_PATH/"
        ssh "$VALIDATOR_USER@$VALIDATOR_HOST" "cd $REMOTE_BPF_PATH && clang -O2 -target bpf -c xdp_filter.c -o xdp_filter.o -I ."
    fi
fi

# 5. Set capabilities on validator
echo "🔐 Setting capabilities on validator..."
if [ "$USE_SSHPASS" = true ]; then
    sshpass -e ssh -o StrictHostKeyChecking=no "$VALIDATOR_USER@$VALIDATOR_HOST" "echo '$VALIDATOR_PASSWORD' | sudo -S setcap cap_net_raw,cap_net_admin+ep $REMOTE_PATH 2>&1"
    echo "✅ Capabilities set"
else
    ssh "$VALIDATOR_USER@$VALIDATOR_HOST" "sudo setcap cap_net_raw,cap_net_admin+ep $REMOTE_PATH"
fi

# 6. Verify
echo "✅ Verifying deployment..."
if [ "$USE_SSHPASS" = true ]; then
    sshpass -e ssh -o StrictHostKeyChecking=no "$VALIDATOR_USER@$VALIDATOR_HOST" "ls -lh $REMOTE_PATH && ls -lh $REMOTE_BPF_PATH/xdp_filter.o 2>&1"
else
    ssh "$VALIDATOR_USER@$VALIDATOR_HOST" "ls -lh $REMOTE_PATH && ls -lh $REMOTE_BPF_PATH/xdp_filter.o"
fi

echo ""
echo "✅ Deployment complete!"
echo ""
echo "To test eBPF on validator:"
echo "  ssh $VALIDATOR_USER@$VALIDATOR_HOST"
echo "  $REMOTE_PATH run --no-voting --gossip-port 8101 --rpc-port 8999 --public-ip 38.92.24.174"
echo ""
echo "Look for: '✅ eBPF kernel-level filtering active (~20M pps)'"

