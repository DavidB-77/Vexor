const std = @import("std");
const consensus = @import("root.zig");
const core = @import("../core/root.zig");

const ForkChoice = consensus.ForkChoice;
const Vote = consensus.Vote;
const Pubkey = core.Pubkey;
const Hash = core.Hash;

test "Simulation: Fork Divergence and Heavy Fork Selection" {
    const allocator = std.testing.allocator;

    // 1. Setup ForkChoice
    var fc = ForkChoice.init(allocator);
    defer fc.deinit();

    // Define Validator Weights
    const valA_pk = Pubkey.fromBytes([_]u8{1} ** 32);
    const valB_pk = Pubkey.fromBytes([_]u8{2} ** 32);

    try fc.registerVoter(valA_pk, 6000); // 60% stake
    try fc.registerVoter(valB_pk, 4000); // 40% stake
    fc.setTotalStake(10000);

    // 2. Setup Common History (Slots 0-10)
    // Root is 0
    try fc.addFork(0, null, Hash.ZERO); // Explicitly add root

    // We add blocks linearly up to 10
    var last_hash = Hash.ZERO;
    for (1..11) |i| {
        const slot = @as(u64, i);
        var hash_data = [_]u8{0} ** 32;
        std.mem.writeInt(u64, hash_data[0..8], slot, .little);
        const hash = Hash{ .data = hash_data };

        try fc.addFork(slot, slot - 1, hash);
        last_hash = hash;
    }

    // 3. Create Divergence after Slot 10
    // Fork A: 10 -> 11
    // Fork B: 10 -> 12 (skipping 11)

    // Fork A branch
    const hash11A = Hash{ .data = [_]u8{0xAA} ** 32 };
    try fc.addFork(11, 10, hash11A);

    // Fork B branch
    const hash12B = Hash{ .data = [_]u8{0xBB} ** 32 };
    try fc.addFork(12, 10, hash12B);

    // 4. Voting

    // Validator A (60%) votes for Slot 11 (Fork A)
    const voteA = Vote{
        .slot = 11,
        .hash = hash11A,
        .timestamp = 0,
        .signature = core.Signature{ .data = [_]u8{0} ** 64 },
    };
    try fc.onVoteWithVoter(&voteA, valA_pk);

    // Validator B (40%) votes for Slot 12 (Fork B)
    const voteB = Vote{
        .slot = 12,
        .hash = hash12B,
        .timestamp = 0,
        .signature = core.Signature{ .data = [_]u8{0} ** 64 },
    };
    try fc.onVoteWithVoter(&voteB, valB_pk);

    // 5. Verification
    // Best slot should be 11 because 6000 > 4000
    try std.testing.expectEqual(@as(?u64, 11), fc.bestSlot());

    // 6. Flip the scales
    // Validator A switches to Fork B (Slot 12)
    // In Vexor implementation, stakes are added cumulatively
    // So if A votes for 12, it ADDS 6000 to 12.
    // Fork A (11) has 6000 stake.
    // Fork B (12) has 4000 + 6000 = 10000 stake.

    // Recreate vote A for slot 12
    const voteA_switch = Vote{
        .slot = 12,
        .hash = hash12B,
        .timestamp = 0,
        .signature = core.Signature{ .data = [_]u8{0} ** 64 },
    };
    try fc.onVoteWithVoter(&voteA_switch, valA_pk);

    // Now best slot should be 12
    try std.testing.expectEqual(@as(?u64, 12), fc.bestSlot());
}
