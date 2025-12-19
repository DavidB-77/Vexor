#!/bin/bash
# VEXOR XDP Setup Script
# Compiles and loads the XDP program, pins maps for VEXOR to use
#
# Usage: sudo ./setup-xdp.sh [interface]
# Default interface: enp1s0f0

set -e

INTERFACE="${1:-enp1s0f0}"
XDP_DIR="/home/sol/vexor/bpf"
XDP_SRC="$XDP_DIR/xdp_filter.c"
XDP_OBJ="$XDP_DIR/xdp_filter.o"
PIN_DIR="/sys/fs/bpf/vexor"

echo "=== VEXOR XDP Setup ==="
echo "Interface: $INTERFACE"
echo "XDP source: $XDP_SRC"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

# Create directories
mkdir -p "$XDP_DIR"
mkdir -p "$PIN_DIR"

# Check if source exists
if [ ! -f "$XDP_SRC" ]; then
    echo "Error: XDP source not found at $XDP_SRC"
    echo "Please deploy xdp_filter.c first"
    exit 1
fi

# Compile if needed or if source is newer
if [ ! -f "$XDP_OBJ" ] || [ "$XDP_SRC" -nt "$XDP_OBJ" ]; then
    echo "Compiling XDP program..."
    clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
        -c "$XDP_SRC" -o "$XDP_OBJ"
    echo "Compiled: $XDP_OBJ"
else
    echo "Using existing compiled program: $XDP_OBJ"
fi

# Detach any existing XDP program from interface
echo "Detaching any existing XDP program..."
ip link set dev "$INTERFACE" xdp off 2>/dev/null || true

# Remove old pinned objects
echo "Removing old pinned objects..."
rm -f "$PIN_DIR/prog" "$PIN_DIR/xsks_map" "$PIN_DIR/port_filter" 2>/dev/null || true

# Load and pin the program
echo "Loading XDP program..."
bpftool prog load "$XDP_OBJ" "$PIN_DIR/prog" \
    pinmaps "$PIN_DIR"

# Verify
echo ""
echo "=== Verification ==="
echo "Pinned objects:"
ls -la "$PIN_DIR/"

echo ""
echo "Loaded program:"
bpftool prog show pinned "$PIN_DIR/prog"

echo ""
echo "Maps:"
bpftool map show pinned "$PIN_DIR/xsks_map" 2>/dev/null || echo "xsks_map: not found"
bpftool map show pinned "$PIN_DIR/port_filter" 2>/dev/null || echo "port_filter: not found"

echo ""
echo "=== XDP Setup Complete ==="
echo "VEXOR can now use:"
echo "  Program:     $PIN_DIR/prog"
echo "  XSKMAP:      $PIN_DIR/xsks_map"  
echo "  Port Filter: $PIN_DIR/port_filter"
echo ""
echo "To attach manually: bpftool net attach xdp pinned $PIN_DIR/prog dev $INTERFACE"
