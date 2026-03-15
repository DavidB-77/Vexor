/* eBPF XDP Program for Packet Filtering
 * Filters packets by UDP destination port and redirects to AF_XDP sockets
 * Reference: Firedancer src/waltz/xdp/fd_xdp_prog.c
 */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <linux/in.h>  // For IPPROTO_UDP
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* XSKMAP: Maps queue_id -> AF_XDP socket file descriptor
 * Used to redirect packets to the correct AF_XDP socket
 */
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64);  // Support up to 64 queues
    __type(key, __u32);       // Queue ID
    __type(value, __u32);     // AF_XDP socket FD
} xsks_map SEC(".maps");

/* Port Filter Map: Maps UDP destination port -> action (1 = redirect, 0 = pass)
 * Used to determine which ports should be redirected to AF_XDP
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);  // Support up to 16 ports (gossip, TVU, TPU, etc.)
    __type(key, __u16);       // UDP destination port (host byte order)
    __type(value, __u8);      // Action: 1 = redirect to AF_XDP, 0 = pass to kernel
} port_filter SEC(".maps");

/* XDP Program Entry Point
 * Called for every packet received on the interface
 * Returns: XDP_PASS (let kernel handle) or XDP_REDIRECT (send to AF_XDP socket)
 */
SEC("xdp")
int xdp_filter_prog(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    struct ethhdr *eth = data;
    
    /* Bounds check: Ensure we have at least an Ethernet header */
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    
    /* Only process IPv4 packets */
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;
    
    /* Parse IPv4 header */
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;
    
    /* Only process UDP packets */
    if (ip->protocol != IPPROTO_UDP)
        return XDP_PASS;
    
    /* Parse UDP header */
    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end)
        return XDP_PASS;
    
    /* Get UDP destination port (network byte order -> host byte order) */
    __u16 dport = bpf_ntohs(udp->dest);
    
    /* Check if this port should be redirected to AF_XDP */
    __u8 *action = bpf_map_lookup_elem(&port_filter, &dport);
    if (!action || *action == 0) {
        /* Port not in filter map or action is 0 -> pass to kernel */
        return XDP_PASS;
    }
    
    /* Port matches filter -> redirect to AF_XDP socket */
    /* Get the queue ID for this packet (RSS queue) */
    __u32 queue_id = ctx->rx_queue_index;
    
    /* Redirect packet to AF_XDP socket for this queue */
    /* Returns XDP_REDIRECT if successful, XDP_PASS if socket not found */
    return bpf_redirect_map(&xsks_map, queue_id, XDP_PASS);
}

char _license[] SEC("license") = "GPL";

