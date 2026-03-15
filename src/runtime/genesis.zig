//! Vexor Genesis Block Loading
//!
//! Handles loading and validating the genesis block, which contains
//! the initial state of the cluster including:
//! - Native programs (system, vote, stake, etc.)
//! - Initial accounts and balances
//! - Cluster configuration parameters
//! - Genesis hash (used for shred verification)

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Genesis configuration from genesis.bin
pub const GenesisConfig = struct {
    /// Creation time (unix timestamp in seconds)
    creation_time: i64,
    /// Initial accounts
    accounts: []const GenesisAccount,
    /// Native instruction processors (built-in programs)
    native_instruction_processors: []const NativeInstructionProcessor,
    /// Rewards pools
    rewards_pools: []const GenesisAccount,
    /// Target ticks per slot
    ticks_per_slot: u64,
    /// Duration of slot in milliseconds
    slot_duration_ms: u64,
    /// Slots per epoch
    slots_per_epoch: u64,
    /// Target lamports per signature
    lamports_per_signature: u64,
    /// Rent configuration
    rent: RentConfig,
    /// Fee rate governor
    fee_rate_governor: FeeRateGovernor,
    /// Inflation configuration
    inflation: InflationConfig,
    /// Epoch schedule
    epoch_schedule: EpochSchedule,
    /// Cluster type
    cluster_type: ClusterType,

    const Self = @This();

    /// Load genesis from a file
    pub fn load(allocator: Allocator, path: []const u8) !Self {
        var file = try fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const size = stat.size;

        // Read the entire file (genesis is typically small)
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);

        _ = try file.readAll(data);

        return try Self.deserialize(allocator, data);
    }

    /// Deserialize from bincode format
    pub fn deserialize(allocator: Allocator, data: []const u8) !Self {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        const creation_time = try reader.readInt(i64, .little);
        // Skip accounts for now (would need allocator for dynamic array)
        const accounts_len = try reader.readInt(u64, .little);
        try reader.skipBytes(accounts_len * (32 + 8 + 8 + 1 + 32), .{}); // Simplified skip

        const processors_len = try reader.readInt(u64, .little);
        try reader.skipBytes(processors_len * 64, .{}); // Simplified skip

        const rewards_len = try reader.readInt(u64, .little);
        try reader.skipBytes(rewards_len * (32 + 8 + 8 + 1 + 32), .{}); // Simplified skip

        const ticks_per_slot = try reader.readInt(u64, .little);
        const slot_duration_ms = try reader.readInt(u64, .little);
        const slots_per_epoch = try reader.readInt(u64, .little);
        const lamports_per_signature = try reader.readInt(u64, .little);

        // Rent config
        const rent = RentConfig{
            .lamports_per_byte_year = try reader.readInt(u64, .little),
            .exemption_threshold = @bitCast(try reader.readInt(u64, .little)),
            .burn_percent = try reader.readByte(),
        };

        // Fee rate governor
        const fee_rate_governor = FeeRateGovernor{
            .target_lamports_per_signature = try reader.readInt(u64, .little),
            .target_signatures_per_slot = try reader.readInt(u64, .little),
            .min_lamports_per_signature = try reader.readInt(u64, .little),
            .max_lamports_per_signature = try reader.readInt(u64, .little),
            .burn_percent = try reader.readByte(),
        };

        // Inflation config
        const inflation = InflationConfig{
            .initial = @bitCast(try reader.readInt(u64, .little)),
            .terminal = @bitCast(try reader.readInt(u64, .little)),
            .taper = @bitCast(try reader.readInt(u64, .little)),
            .foundation = @bitCast(try reader.readInt(u64, .little)),
            .foundation_term = @bitCast(try reader.readInt(u64, .little)),
        };

        // Epoch schedule
        const epoch_schedule = EpochSchedule{
            .slots_per_epoch = try reader.readInt(u64, .little),
            .leader_schedule_slot_offset = try reader.readInt(u64, .little),
            .warmup = try reader.readByte() != 0,
            .first_normal_epoch = try reader.readInt(u64, .little),
            .first_normal_slot = try reader.readInt(u64, .little),
        };

        // Cluster type
        const cluster_type_val = try reader.readInt(u32, .little);
        const cluster_type = std.meta.intToEnum(ClusterType, cluster_type_val) catch .Development;

        _ = allocator;

        return Self{
            .creation_time = creation_time,
            .accounts = &[_]GenesisAccount{},
            .native_instruction_processors = &[_]NativeInstructionProcessor{},
            .rewards_pools = &[_]GenesisAccount{},
            .ticks_per_slot = ticks_per_slot,
            .slot_duration_ms = slot_duration_ms,
            .slots_per_epoch = slots_per_epoch,
            .lamports_per_signature = lamports_per_signature,
            .rent = rent,
            .fee_rate_governor = fee_rate_governor,
            .inflation = inflation,
            .epoch_schedule = epoch_schedule,
            .cluster_type = cluster_type,
        };
    }

    /// Compute the genesis hash
    pub fn hash(self: *const Self) [32]u8 {
        _ = self;
        // Would serialize and hash the entire config
        // Using SHA256
        var result: [32]u8 = undefined;
        @memset(&result, 0);
        return result;
    }

    /// Validate genesis against expected values
    pub fn validate(self: *const Self, expected_hash: ?[32]u8) !void {
        // Validate basic parameters
        if (self.ticks_per_slot == 0) return error.InvalidTicksPerSlot;
        if (self.slots_per_epoch == 0) return error.InvalidSlotsPerEpoch;
        if (self.lamports_per_signature == 0) return error.InvalidLamportsPerSignature;

        // Validate hash if provided
        if (expected_hash) |expected| {
            const actual = self.hash();
            if (!std.mem.eql(u8, &actual, &expected)) {
                return error.GenesisHashMismatch;
            }
        }
    }
};

/// Account in genesis block
pub const GenesisAccount = struct {
    pubkey: [32]u8,
    lamports: u64,
    data_len: u64,
    executable: bool,
    owner: [32]u8,
    data: []const u8,
};

/// Native instruction processor (built-in program)
pub const NativeInstructionProcessor = struct {
    name: []const u8,
    pubkey: [32]u8,
};

/// Rent configuration
pub const RentConfig = struct {
    lamports_per_byte_year: u64,
    exemption_threshold: f64,
    burn_percent: u8,

    /// Calculate rent for an account
    pub fn calculateRent(self: RentConfig, data_len: usize, lamports: u64) u64 {
        const bytes: u64 = @intCast(data_len + 128); // Account overhead
        const rent_per_year = bytes * self.lamports_per_byte_year;

        // Check if rent exempt
        const min_exempt = @as(u64, @intFromFloat(@as(f64, @floatFromInt(rent_per_year)) * self.exemption_threshold));
        if (lamports >= min_exempt) {
            return 0; // Rent exempt
        }

        // Return annual rent (would divide by epochs in real implementation)
        return rent_per_year;
    }
};

/// Fee rate governor configuration
pub const FeeRateGovernor = struct {
    target_lamports_per_signature: u64,
    target_signatures_per_slot: u64,
    min_lamports_per_signature: u64,
    max_lamports_per_signature: u64,
    burn_percent: u8,
};

/// Inflation configuration
pub const InflationConfig = struct {
    initial: f64,
    terminal: f64,
    taper: f64,
    foundation: f64,
    foundation_term: f64,

    /// Calculate inflation rate for a given year
    pub fn calculateRate(self: InflationConfig, year: f64) f64 {
        const tapered = self.initial * std.math.pow(f64, 1.0 - self.taper, year);
        return @max(tapered, self.terminal);
    }
};

/// Epoch schedule configuration
pub const EpochSchedule = struct {
    slots_per_epoch: u64,
    leader_schedule_slot_offset: u64,
    warmup: bool,
    first_normal_epoch: u64,
    first_normal_slot: u64,

    /// Get epoch for a given slot
    pub fn getEpoch(self: EpochSchedule, slot: u64) u64 {
        if (slot < self.first_normal_slot) {
            // Warmup period - epochs grow in size
            var epoch: u64 = 0;
            var epoch_start: u64 = 0;
            var slots_in_epoch = MINIMUM_SLOTS_PER_EPOCH;

            while (epoch_start + slots_in_epoch <= slot) {
                epoch_start += slots_in_epoch;
                slots_in_epoch *= 2;
                epoch += 1;
            }
            return epoch;
        } else {
            // Normal period - fixed epoch size
            const normal_slot_index = slot - self.first_normal_slot;
            return self.first_normal_epoch + normal_slot_index / self.slots_per_epoch;
        }
    }

    /// Get first slot of an epoch
    pub fn getFirstSlotInEpoch(self: EpochSchedule, epoch: u64) u64 {
        if (epoch < self.first_normal_epoch) {
            // Warmup period
            return (std.math.shl(u64, 1, epoch + @as(u6, @intCast(std.math.log2(MINIMUM_SLOTS_PER_EPOCH)))) - MINIMUM_SLOTS_PER_EPOCH);
        } else {
            // Normal period
            return self.first_normal_slot + (epoch - self.first_normal_epoch) * self.slots_per_epoch;
        }
    }

    /// Get last slot of an epoch
    pub fn getLastSlotInEpoch(self: EpochSchedule, epoch: u64) u64 {
        return self.getFirstSlotInEpoch(epoch + 1) - 1;
    }

    /// Get slots in epoch
    pub fn getSlotsInEpoch(self: EpochSchedule, epoch: u64) u64 {
        if (epoch < self.first_normal_epoch) {
            return std.math.shl(u64, 1, epoch + @as(u6, @intCast(std.math.log2(MINIMUM_SLOTS_PER_EPOCH))));
        } else {
            return self.slots_per_epoch;
        }
    }
};

const MINIMUM_SLOTS_PER_EPOCH: u64 = 32;

/// Cluster type
pub const ClusterType = enum(u32) {
    Testnet = 0,
    MainnetBeta = 1,
    Devnet = 2,
    Development = 3,

    pub fn toString(self: ClusterType) []const u8 {
        return switch (self) {
            .Testnet => "testnet",
            .MainnetBeta => "mainnet-beta",
            .Devnet => "devnet",
            .Development => "development",
        };
    }

    pub fn entrypoints(self: ClusterType) []const []const u8 {
        return switch (self) {
            .Testnet => &[_][]const u8{
                "entrypoint.testnet.solana.com:8001",
                "entrypoint2.testnet.solana.com:8001",
                "entrypoint3.testnet.solana.com:8001",
            },
            .MainnetBeta => &[_][]const u8{
                "entrypoint.mainnet-beta.solana.com:8001",
                "entrypoint2.mainnet-beta.solana.com:8001",
                "entrypoint3.mainnet-beta.solana.com:8001",
                "entrypoint4.mainnet-beta.solana.com:8001",
                "entrypoint5.mainnet-beta.solana.com:8001",
            },
            .Devnet => &[_][]const u8{
                "entrypoint.devnet.solana.com:8001",
                "entrypoint2.devnet.solana.com:8001",
                "entrypoint3.devnet.solana.com:8001",
                "entrypoint4.devnet.solana.com:8001",
                "entrypoint5.devnet.solana.com:8001",
            },
            .Development => &[_][]const u8{
                "127.0.0.1:8001",
            },
        };
    }
};

/// Well-known genesis hashes
pub const known_hashes = struct {
    pub const mainnet_beta: [32]u8 = .{
        0x5e, 0xf1, 0x5d, 0x3b, 0x8c, 0x57, 0x08, 0x8b,
        0x58, 0x8f, 0x8a, 0x7e, 0xaa, 0x9c, 0x8c, 0x05,
        0x16, 0x92, 0x32, 0x90, 0x3a, 0x93, 0x5f, 0x66,
        0xa2, 0xfd, 0xf7, 0x33, 0x5d, 0x31, 0x3e, 0x82,
    };

    pub const testnet: [32]u8 = .{
        0x04, 0xe3, 0xb6, 0xcc, 0xf3, 0x6f, 0xd3, 0xef,
        0xd9, 0x6e, 0xd4, 0xaa, 0xaa, 0xe5, 0xee, 0x00,
        0x39, 0x88, 0x8a, 0xb9, 0xc8, 0xdc, 0x1d, 0x54,
        0xe5, 0xa6, 0xc0, 0x01, 0x94, 0x41, 0x3c, 0x54,
    };

    pub const devnet: [32]u8 = .{
        0xe3, 0xf6, 0x2b, 0x18, 0xc6, 0x5f, 0x0d, 0x09,
        0x7f, 0x0b, 0x58, 0x25, 0x47, 0x06, 0x09, 0x89,
        0x1b, 0x2c, 0x0b, 0x23, 0x48, 0x88, 0x3b, 0x5f,
        0x44, 0x0c, 0x12, 0x9e, 0xe4, 0x03, 0x7e, 0x1a,
    };

    pub fn forCluster(cluster: ClusterType) ?[32]u8 {
        return switch (cluster) {
            .MainnetBeta => mainnet_beta,
            .Testnet => testnet,
            .Devnet => devnet,
            .Development => null,
        };
    }
};

/// Native program IDs
pub const native_programs = struct {
    pub const system_program: [32]u8 = .{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }; // 11111111111111111111111111111111

    pub const vote_program: [32]u8 = .{
        0x07, 0x61, 0x48, 0x1d, 0x35, 0x7e, 0x6a, 0x6b,
        0xf2, 0x24, 0x08, 0x77, 0xe7, 0xa6, 0xee, 0x44,
        0x29, 0x5e, 0x69, 0x2e, 0x2a, 0x17, 0x47, 0xa5,
        0x87, 0xc8, 0xb6, 0x22, 0x8b, 0x9d, 0x00, 0x00,
    }; // Vote111111111111111111111111111111111111111

    pub const stake_program: [32]u8 = .{
        0x06, 0xa1, 0xd8, 0x17, 0x91, 0x37, 0x54, 0x2a,
        0x98, 0x3a, 0x98, 0x3a, 0xe3, 0xd4, 0x72, 0x8e,
        0x40, 0x64, 0x02, 0x77, 0x52, 0x9c, 0x50, 0xbb,
        0x51, 0x14, 0x2d, 0xfe, 0x5b, 0x83, 0x00, 0x00,
    }; // Stake11111111111111111111111111111111111111

    pub const config_program: [32]u8 = .{
        0x03, 0x06, 0x46, 0x6f, 0xe5, 0x21, 0x17, 0x32,
        0xff, 0xec, 0xad, 0xba, 0x72, 0xc3, 0x9b, 0xe7,
        0xbc, 0x8c, 0xe5, 0xbb, 0xc5, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }; // Config1111111111111111111111111111111111111

    pub const bpf_loader_program: [32]u8 = .{
        0x02, 0xa8, 0xf6, 0x91, 0x4e, 0x88, 0x6c, 0xde,
        0xaa, 0xfb, 0xb1, 0x10, 0x85, 0xac, 0x49, 0xac,
        0xdb, 0x3f, 0x2e, 0x07, 0x60, 0xac, 0x24, 0xf9,
        0x3c, 0x68, 0x22, 0x06, 0x00, 0x00, 0x00, 0x00,
    }; // BPFLoader2111111111111111111111111111111111

    pub const bpf_loader_upgradeable: [32]u8 = .{
        0x02, 0xc4, 0x91, 0x73, 0x19, 0x75, 0xdd, 0x6a,
        0x7b, 0xc6, 0x5a, 0xb2, 0xb1, 0x74, 0x36, 0x6b,
        0x23, 0x83, 0x21, 0x41, 0xed, 0x3a, 0x85, 0x6a,
        0xf8, 0xdb, 0x73, 0x37, 0x00, 0x00, 0x00, 0x00,
    }; // BPFLoaderUpgradeab1e11111111111111111111111
};

// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

test "epoch schedule calculations" {
    const schedule = EpochSchedule{
        .slots_per_epoch = 432000,
        .leader_schedule_slot_offset = 432000,
        .warmup = true,
        .first_normal_epoch = 14,
        .first_normal_slot = 524256,
    };

    // Test normal epoch
    const epoch = schedule.getEpoch(600000);
    try std.testing.expect(epoch >= schedule.first_normal_epoch);

    // Test slots in epoch
    const slots = schedule.getSlotsInEpoch(schedule.first_normal_epoch);
    try std.testing.expectEqual(schedule.slots_per_epoch, slots);
}

test "inflation rate" {
    const inflation = InflationConfig{
        .initial = 0.08,
        .terminal = 0.015,
        .taper = 0.15,
        .foundation = 0.05,
        .foundation_term = 7.0,
    };

    const year0_rate = inflation.calculateRate(0);
    const year10_rate = inflation.calculateRate(10);

    try std.testing.expect(year0_rate > year10_rate);
    try std.testing.expect(year10_rate >= inflation.terminal);
}

test "rent calculation" {
    const rent = RentConfig{
        .lamports_per_byte_year = 3480,
        .exemption_threshold = 2.0,
        .burn_percent = 50,
    };

    // Large balance should be rent exempt
    const exempt_rent = rent.calculateRent(1000, 10_000_000_000);
    try std.testing.expectEqual(@as(u64, 0), exempt_rent);

    // Small balance should owe rent
    const owed_rent = rent.calculateRent(1000, 100);
    try std.testing.expect(owed_rent > 0);
}

test "cluster type entrypoints" {
    const testnet_eps = ClusterType.Testnet.entrypoints();
    try std.testing.expect(testnet_eps.len > 0);

    const mainnet_eps = ClusterType.MainnetBeta.entrypoints();
    try std.testing.expect(mainnet_eps.len > 0);
}

