#!/bin/bash
# Compile eBPF XDP program to BPF bytecode
# Requires: clang with BPF target support

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BPF_SOURCE="$PROJECT_ROOT/src/network/af_xdp/bpf/xdp_filter.c"
BPF_OUTPUT="$PROJECT_ROOT/zig-out/bpf/xdp_filter.o"

# Create output directory
mkdir -p "$(dirname "$BPF_OUTPUT")"

# Check for clang
if ! command -v clang &> /dev/null; then
    echo "Error: clang not found. Install with: sudo apt-get install clang"
    exit 1
fi

# Check for BPF headers
if [ ! -d "/usr/include/bpf" ] && [ ! -d "/usr/local/include/bpf" ]; then
    echo "Warning: BPF headers not found. Install with: sudo apt-get install libbpf-dev"
    echo "Attempting to compile anyway..."
fi

# Compile eBPF program
echo "Compiling eBPF XDP program..."
clang -O2 -target bpf -D__BPF__ \
    -I/usr/include \
    -I/usr/include/bpf \
    -I/usr/local/include \
    -I/usr/local/include/bpf \
    -c "$BPF_SOURCE" \
    -o "$BPF_OUTPUT"

if [ $? -eq 0 ]; then
    echo "✅ eBPF program compiled successfully: $BPF_OUTPUT"
    file "$BPF_OUTPUT"
else
    echo "❌ Failed to compile eBPF program"
    exit 1
fi

