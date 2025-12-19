#!/bin/bash
# Quick script to set up and test eBPF XDP functionality
# NOTE: Run this on the VALIDATOR, not locally!
# For local testing, use: ./scripts/deploy_to_validator.sh

set -e

echo "🔧 Setting up eBPF test environment on VALIDATOR..."
echo "   (This script should be run on the validator server)"
echo ""

# 1. Install clang if needed
if ! command -v clang &> /dev/null; then
    echo "📦 Installing clang..."
    sudo apt-get update
    sudo apt-get install -y clang
fi

# 2. Build with AF_XDP enabled
echo "🔨 Building Vexor with AF_XDP enabled..."
cd "$(dirname "$0")/.."
zig build -Daf_xdp=true

# 3. Verify BPF program compiled
if [ ! -f "zig-out/bpf/xdp_filter.o" ]; then
    echo "❌ ERROR: BPF program not compiled!"
    echo "   Expected: zig-out/bpf/xdp_filter.o"
    exit 1
fi
echo "✅ BPF program compiled: zig-out/bpf/xdp_filter.o"

# 4. Set capabilities
echo "🔐 Setting capabilities on binary..."
sudo setcap cap_net_raw,cap_net_admin+ep zig-out/bin/vexor
getcap zig-out/bin/vexor
echo "✅ Capabilities set"

# 5. Test run
echo ""
echo "🚀 Running Vexor to test eBPF initialization..."
echo "   Look for: '✅ eBPF kernel-level filtering active (~20M pps)'"
echo "   Or fallback: 'Using userspace port filtering (~10M pps)'"
echo ""
timeout 10 ./zig-out/bin/vexor run --no-voting --gossip-port 8101 --rpc-port 8999 --public-ip 127.0.0.1 2>&1 | grep -E "AF_XDP|eBPF|userspace|filtering|XDP|kernel|Performance|✅|~.*pps|Initialized" || echo "No eBPF messages found (may need full validator config)"

echo ""
echo "✅ Test complete!"

