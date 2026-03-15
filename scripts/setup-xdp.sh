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

# Check kernel version for known AF_XDP bugs
# Reference: Cloudflare blog - veth driver race condition fixed in kernel 6.2+
echo ""
echo "=== Checking kernel compatibility ==="
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
echo "Kernel version: $(uname -r)"

if [ "$KERNEL_MAJOR" -lt 5 ] || ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 15 ]); then
    echo "WARNING: Kernel < 5.15 may have AF_XDP bugs"
    echo "Recommended: Kernel 6.2+ for best AF_XDP stability"
fi

# Check driver type
DRIVER=$(ethtool -i "$INTERFACE" 2>/dev/null | grep "^driver:" | awk '{print $2}')
echo "NIC driver: $DRIVER"

# Known good drivers for AF_XDP zero-copy
case "$DRIVER" in
    i40e|ice|ixgbe|mlx5_core|igc|stmmac)
        echo "Driver $DRIVER supports AF_XDP zero-copy mode"
        ;;
    veth)
        echo "WARNING: veth driver had race conditions - ensure kernel 6.2+"
        ;;
    *)
        echo "Driver $DRIVER - AF_XDP support unknown, may fall back to copy mode"
        ;;
esac

# CRITICAL: Disable offloads that cause packet corruption with XDP
# Reference: Firedancer docs - "Linux has undocumented problems with ethtool offloads
# like GRO and UDP segmentation... cause packet corruption in XDP sockets"
echo ""
echo "=== Disabling problematic NIC offloads ==="
ethtool -K "$INTERFACE" gro off 2>/dev/null || echo "Warning: Could not disable GRO"
ethtool -K "$INTERFACE" lro off 2>/dev/null || echo "Warning: Could not disable LRO"
ethtool -K "$INTERFACE" tso off 2>/dev/null || echo "Warning: Could not disable TSO"
ethtool -K "$INTERFACE" gso off 2>/dev/null || echo "Warning: Could not disable GSO"
ethtool -K "$INTERFACE" rx-udp-gro-forwarding off 2>/dev/null || true
# Disable VLAN offloads for more deterministic matching
ethtool -K "$INTERFACE" rxvlan off txvlan off 2>/dev/null || true
echo "Offloads disabled"

# Show current offload status
echo ""
echo "Current offload status:"
ethtool -k "$INTERFACE" 2>/dev/null | grep -E "^(generic-receive-offload|large-receive-offload|tcp-segmentation-offload|generic-segmentation-offload):" || true

# Create directories
mkdir -p "$XDP_DIR"
mkdir -p "$PIN_DIR"

# Fix BPF filesystem permissions (required for non-root access)
echo "Fixing BPF filesystem permissions..."
chmod 755 /sys/fs/bpf/ 2>/dev/null || true

# Fix missing asm headers symlink (common issue on Ubuntu)
if [ ! -e /usr/include/asm ]; then
    echo "Creating /usr/include/asm symlink for BPF compilation..."
    ln -s /usr/include/x86_64-linux-gnu/asm /usr/include/asm
fi

# Check if source exists
if [ ! -f "$XDP_SRC" ]; then
    echo "Error: XDP source not found at $XDP_SRC"
    echo "Please deploy xdp_filter.c first"
    exit 1
fi

# Generate vmlinux.h if not present
VMLINUX_H="$XDP_DIR/vmlinux.h"
if [ ! -f "$VMLINUX_H" ]; then
    echo "Generating vmlinux.h from running kernel..."
    bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$VMLINUX_H" 2>/dev/null || {
        echo "Warning: Could not generate vmlinux.h, using minimal headers"
        # Create minimal vmlinux.h with just what we need
        cat > "$VMLINUX_H" << 'VMLINUX_EOF'
#ifndef __VMLINUX_H__
#define __VMLINUX_H__

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

struct xdp_md {
    __u32 data;
    __u32 data_end;
    __u32 data_meta;
    __u32 ingress_ifindex;
    __u32 rx_queue_index;
    __u32 egress_ifindex;
};

struct ethhdr {
    unsigned char h_dest[6];
    unsigned char h_source[6];
    __u16 h_proto;
} __attribute__((packed));

struct iphdr {
    __u8 ihl:4, version:4;
    __u8 tos;
    __u16 tot_len;
    __u16 id;
    __u16 frag_off;
    __u8 ttl;
    __u8 protocol;
    __u16 check;
    __u32 saddr;
    __u32 daddr;
} __attribute__((packed));

struct udphdr {
    __u16 source;
    __u16 dest;
    __u16 len;
    __u16 check;
} __attribute__((packed));

#define ETH_P_IP 0x0800
#define IPPROTO_UDP 17

enum xdp_action {
    XDP_ABORTED = 0,
    XDP_DROP,
    XDP_PASS,
    XDP_TX,
    XDP_REDIRECT,
};

#endif /* __VMLINUX_H__ */
VMLINUX_EOF
    }
fi

# Create simplified XDP source that uses vmlinux.h
XDP_SRC_SIMPLE="$XDP_DIR/xdp_simple.c"
cat > "$XDP_SRC_SIMPLE" << 'XDP_EOF'
// Minimal XDP program for VEXOR
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// Define constants not in vmlinux.h
#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif
#ifndef IPPROTO_UDP
#define IPPROTO_UDP 17
#endif
#ifndef XDP_PASS
#define XDP_PASS 2
#endif

struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64);
    __type(key, __u32);
    __type(value, __u32);
} xsks_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);
    __type(key, __u16);
    __type(value, __u8);
} port_filter SEC(".maps");

SEC("xdp")
int xdp_filter_prog(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;
    
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;
    
    if (ip->protocol != IPPROTO_UDP)
        return XDP_PASS;
    
    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end)
        return XDP_PASS;
    
    __u16 dport = bpf_ntohs(udp->dest);
    __u8 *action = bpf_map_lookup_elem(&port_filter, &dport);
    if (!action || *action == 0)
        return XDP_PASS;
    
    __u32 queue_id = ctx->rx_queue_index;
    return bpf_redirect_map(&xsks_map, queue_id, XDP_PASS);
}

char _license[] SEC("license") = "GPL";
XDP_EOF

# Compile
echo "Compiling XDP program..."
clang -O2 -g -target bpf -D__TARGET_ARCH_x86 \
    -I"$XDP_DIR" \
    -c "$XDP_SRC_SIMPLE" -o "$XDP_OBJ"
echo "Compiled: $XDP_OBJ"

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

# Set permissions so sol user can access the pinned maps
echo ""
echo "Setting permissions for sol user..."
chmod 755 /sys/fs/bpf/
chmod 755 "$PIN_DIR"
chmod 666 "$PIN_DIR/xsks_map" "$PIN_DIR/port_filter" "$PIN_DIR/prog"
chown sol:sol "$PIN_DIR/xsks_map" "$PIN_DIR/port_filter" "$PIN_DIR/prog" 2>/dev/null || true

# CRITICAL: Set up flow steering to protect management traffic
# Reference: Medium article - SSH breaks when XDP traffic saturates queues
# Reference: Cloudflare blog - AF_XDP kernel race conditions can corrupt packets
echo ""
echo "=== Setting up flow steering rules ==="

# Check if NIC supports ntuple filtering
if ethtool -k "$INTERFACE" 2>/dev/null | grep -q "ntuple-filters: on"; then
    echo "ntuple filters supported, adding flow steering rules..."
    
    # Delete any existing Vexor rules (rule IDs 100-120)
    for i in $(seq 100 120); do
        ethtool -U "$INTERFACE" delete $i 2>/dev/null || true
    done
    
    # Route management TCP traffic to queue 0 - NOT used by AF_XDP
    # These are all critical ports that should bypass XDP:
    
    # SSH - must always work for server access
    ethtool -U "$INTERFACE" flow-type tcp4 dst-port 22 action 0 loc 100 2>/dev/null && \
        echo "  TCP:22 (SSH) -> queue 0" || echo "  Warning: SSH rule failed"
    
    # RPC - Solana RPC for client queries  
    ethtool -U "$INTERFACE" flow-type tcp4 dst-port 8899 action 0 loc 101 2>/dev/null && \
        echo "  TCP:8899 (RPC) -> queue 0" || echo "  Warning: RPC rule failed"
    
    # WebSocket - RPC subscriptions
    ethtool -U "$INTERFACE" flow-type tcp4 dst-port 8900 action 0 loc 102 2>/dev/null && \
        echo "  TCP:8900 (WebSocket) -> queue 0" || echo "  Warning: WebSocket rule failed"
    
    # Dashboard stream
    ethtool -U "$INTERFACE" flow-type tcp4 dst-port 8910 action 0 loc 103 2>/dev/null && \
        echo "  TCP:8910 (Dashboard) -> queue 0" || echo "  Warning: Dashboard rule failed"
    
    # Metrics (Prometheus)
    ethtool -U "$INTERFACE" flow-type tcp4 dst-port 9090 action 0 loc 104 2>/dev/null && \
        echo "  TCP:9090 (Metrics) -> queue 0" || echo "  Warning: Metrics rule failed"
    
    echo ""
    echo "Current flow steering rules:"
    ethtool -u "$INTERFACE" 2>/dev/null | head -30 || true
else
    echo "Warning: ntuple filters not available on $INTERFACE"
    echo ""
    echo "CRITICAL: Without flow steering, the following ports may be affected:"
    echo "  - TCP:22 (SSH)"
    echo "  - TCP:8899 (RPC)"
    echo "  - TCP:8900 (WebSocket)"
    echo "  - TCP:8910 (Dashboard)"
    echo "  - TCP:9090 (Metrics)"
    echo ""
    echo "Options:"
    echo "  1. Use a separate NIC for management traffic (recommended)"
    echo "  2. Don't use AF_XDP on this NIC"
    echo "  3. Manually configure traffic separation"
fi

# Grant capabilities to vexor binary so it can use AF_XDP without root
VEXOR_BIN="/home/sol/vexor/bin/vexor-validator"
if [ -f "$VEXOR_BIN" ]; then
    echo "Granting network capabilities to vexor-validator..."
    setcap cap_net_raw,cap_net_admin,cap_bpf+ep "$VEXOR_BIN" 2>/dev/null || \
    setcap cap_net_raw,cap_net_admin+ep "$VEXOR_BIN" 2>/dev/null || \
    echo "Warning: Could not set capabilities (may need newer kernel)"
fi

echo ""
echo "=== XDP Setup Complete ==="
echo ""
echo "VEXOR can now use these pinned BPF objects:"
echo "  Program:     $PIN_DIR/prog"
echo "  XSKMAP:      $PIN_DIR/xsks_map"  
echo "  Port Filter: $PIN_DIR/port_filter"
echo ""
echo "=== IMPORTANT: XDP Attachment ==="
echo "The XDP program is NOT attached to the interface yet."
echo "Vexor will attach it when it starts (ephemeral, removed on exit)."
echo ""
echo "To manually attach (CAUTION - may affect SSH):"
echo "  bpftool net attach xdp pinned $PIN_DIR/prog dev $INTERFACE"
echo ""
echo "To detach (restore normal networking):"
echo "  ip link set dev $INTERFACE xdp off"
echo ""
echo "=== SSH Recovery ==="
echo "If you lose SSH access:"
echo "  1. Use IPMI/console to access the server"
echo "  2. Run: ip link set dev $INTERFACE xdp off"
echo "  3. Run: rm -rf /sys/fs/bpf/vexor/"
echo "  4. Verify: ip link show $INTERFACE (should show no xdp)"
echo ""
echo "=== Safe Testing Recommendation ==="
echo "Test with short runs first and monitor SSH in a separate terminal."
echo "Consider using a separate NIC for management traffic for production."
