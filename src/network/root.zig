//! Vexor Network Module
//!
//! High-performance networking layer supporting:
//! - AF_XDP kernel bypass for ultra-low latency packet processing
//! - QUIC/HTTP3 via zquic integration
//! - TPU (Transaction Processing Unit) for incoming transactions
//! - TVU (Transaction Validation Unit) for shred propagation
//! - Gossip protocol for cluster discovery and protocol state
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────┐
//! │                    NETWORK LAYER                        │
//! ├──────────────┬──────────────┬──────────────┬────────────┤
//! │   AF_XDP     │    QUIC      │   GOSSIP     │   RPC      │
//! │   (raw)      │   (zquic)    │   (UDP)      │  (HTTP)    │
//! ├──────────────┴──────────────┴──────────────┴────────────┤
//! │                  PACKET ROUTER                          │
//! └─────────────────────────────────────────────────────────┘

const std = @import("std");
const build_options = @import("build_options");

pub const packet = @import("packet.zig");
pub const socket = @import("socket.zig");
pub const quic_legacy = @import("quic.zig");
pub const quic = @import("quic/root.zig");
pub const gossip = @import("gossip.zig");
pub const crds = @import("crds.zig");
pub const cluster_info = @import("cluster_info.zig");
pub const tpu = @import("tpu.zig");
pub const tvu = @import("tvu.zig");
pub const rpc = @import("rpc.zig");
pub const rpc_methods = @import("rpc_methods.zig");
pub const rpc_server = @import("rpc_server.zig");
pub const repair = @import("repair.zig");
pub const tx_forwarder = @import("tx_forwarder.zig");
pub const masque = @import("masque/root.zig");
pub const solana_quic = @import("solana_quic.zig");
pub const accelerated_io = @import("accelerated_io.zig");
pub const io_uring = @import("io_uring.zig");
pub const tls13 = @import("tls13.zig");
pub const cluster_discovery = @import("cluster_discovery.zig");
pub const tpu_client = @import("tpu_client.zig");

// MASQUE types (QUIC proxying)
pub const MasqueClient = masque.MasqueClient;
pub const MasqueServer = masque.MasqueServer;
pub const MasqueClientConfig = masque.ClientConfig;
pub const MasqueServerConfig = masque.ServerConfig;
pub const MasqueUdpTunnel = masque.UdpTunnel;

// Full QUIC transport types (automatic size handling)
pub const QuicTransport = quic.Transport;
pub const QuicConnection = quic.Connection;
pub const QuicStream = quic.Stream;
pub const QuicMessage = quic.Message;
pub const QuicPriority = quic.Priority;
pub const QuicDeliveryMode = quic.DeliveryMode;
pub const QuicMasqueConnection = quic.MasqueConnection;

// Solana-specific QUIC types
pub const SolanaTpuQuic = solana_quic.SolanaTpuQuic;
pub const SolanaQuicConfig = solana_quic.SolanaQuicConfig;
pub const SolanaNetworkClient = solana_quic.SolanaNetworkClient;
pub const TransactionWireFormat = solana_quic.TransactionWireFormat;
pub const ShredWireFormat = solana_quic.ShredWireFormat;

// Accelerated I/O (AF_XDP kernel bypass)
pub const AcceleratedIO = accelerated_io.AcceleratedIO;
pub const AcceleratedIOConfig = accelerated_io.Config;
pub const AcceleratedIOBackend = accelerated_io.Backend;
pub const createTvuIO = accelerated_io.createTvuIO;
pub const createTpuUdpIO = accelerated_io.createTpuUdpIO;
pub const createGossipIO = accelerated_io.createGossipIO;

// Conditional AF_XDP support (kernel bypass networking)
pub const af_xdp = if (build_options.af_xdp_enabled)
    @import("af_xdp/root.zig")
else
    @import("af_xdp_stub.zig");

// AF_XDP types (conditionally exported)
pub const PacketProcessor = if (build_options.af_xdp_enabled)
    af_xdp.PacketProcessor
else
    void;
pub const PacketType = if (build_options.af_xdp_enabled)
    af_xdp.PacketType
else
    void;

// Re-export common types
pub const Packet = packet.Packet;
pub const PacketBatch = packet.PacketBatch;
pub const UdpSocket = socket.UdpSocket;
pub const SocketSet = socket.SocketSet;
pub const GossipService = gossip.GossipService;
pub const ContactInfo = gossip.ContactInfo;
pub const CrdsValue = crds.CrdsValue;
pub const CrdsData = crds.CrdsData;
pub const Protocol = crds.Protocol;
pub const ClusterInfo = cluster_info.ClusterInfo;
pub const ClusterConfig = cluster_info.ClusterConfig;
pub const LeaderSchedule = cluster_info.LeaderSchedule;
pub const RpcHttpServer = rpc_server.RpcHttpServer;
pub const RepairService = repair.RepairService;
pub const TxForwarder = tx_forwarder.TxForwarder;
pub const TpuClient = tpu_client.TpuClient;
pub const TpuForward = tpu_client.TpuForward;

/// Initialize the networking subsystem
pub fn init(allocator: std.mem.Allocator, config: anytype) !*NetworkManager {
    return NetworkManager.init(allocator, config);
}

/// Main network manager coordinating all network components
pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    gossip_service: ?*gossip.GossipService,
    tpu_service: ?*tpu.TpuService,
    tvu_service: ?*tvu.TvuService,
    rpc_server: ?*rpc.RpcServer,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: anytype) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .gossip_service = null,
            .tpu_service = null,
            .tvu_service = null,
            .rpc_server = null,
            .running = std.atomic.Value(bool).init(false),
        };

        // Initialize services based on config
        if (config.enable_rpc) {
            self.rpc_server = try rpc.RpcServer.init(allocator, config.rpc_port);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.gossip_service) |gs| gs.deinit();
        if (self.tpu_service) |tpu_svc| tpu_svc.deinit();
        if (self.tvu_service) |tvu_svc| tvu_svc.deinit();
        if (self.rpc_server) |rpc_srv| rpc_srv.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Self) !void {
        self.running.store(true, .seq_cst);

        // Start services in order
        if (self.gossip_service) |gs| try gs.start();
        if (self.tpu_service) |tpu_svc| try tpu_svc.start();
        if (self.tvu_service) |tvu_svc| try tvu_svc.start();
        if (self.rpc_server) |rpc_srv| try rpc_srv.start();
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .seq_cst);
    }
};

test {
    std.testing.refAllDecls(@This());
}

