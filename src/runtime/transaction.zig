//! Vexor Transaction Module
//!
//! Handles transaction parsing, validation, and serialization.
//! Solana transaction format:
//! [num_signatures: u8]
//! [signatures: 64 * num_signatures]
//! [message: variable]
//!
//! Message format:
//! [header: 3 bytes]
//! [account_keys: 32 * num_keys]
//! [recent_blockhash: 32]
//! [instructions: variable]

const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");

/// Maximum accounts per transaction
pub const MAX_ACCOUNTS: usize = 64;

/// Maximum instructions per transaction
pub const MAX_INSTRUCTIONS: usize = 64;

/// Maximum transaction size
pub const MAX_TX_SIZE: usize = 1232;

/// Parsed transaction
pub const ParsedTransaction = struct {
    /// All signatures on this transaction
    signatures: []const core.Signature,

    /// The message being signed
    message: Message,

    /// Raw message bytes (for verification)
    message_bytes: []const u8,

    /// Was this transaction sanitized
    is_sanitized: bool,

    pub fn feePayer(self: *const ParsedTransaction) core.Pubkey {
        return self.message.account_keys[0];
    }

    /// Verify all signatures
    pub fn verifySignatures(self: *const ParsedTransaction) bool {
        const num_signers = self.message.header.num_required_signatures;
        if (self.signatures.len != num_signers) return false;

        for (self.signatures, 0..) |*sig, i| {
            const pubkey = &self.message.account_keys[i];
            if (!crypto.verify(sig, pubkey, self.message_bytes)) {
                return false;
            }
        }
        return true;
    }
};

/// Transaction message
pub const Message = struct {
    /// Message header
    header: MessageHeader,

    /// All account public keys
    account_keys: []const core.Pubkey,

    /// Recent blockhash
    recent_blockhash: core.Hash,

    /// Compiled instructions
    instructions: []const CompiledInstruction,

    /// Get accounts that are writable
    pub fn writableAccounts(self: *const Message) []const core.Pubkey {
        const writable_count = self.header.num_required_signatures - self.header.num_readonly_signed_accounts + self.header.num_readonly_unsigned_accounts;
        _ = writable_count;
        // TODO: Return slice of writable accounts
        return self.account_keys[0..1];
    }

    /// Check if an account is signer
    pub fn isSigner(self: *const Message, index: usize) bool {
        return index < self.header.num_required_signatures;
    }

    /// Check if an account is writable
    pub fn isWritable(self: *const Message, index: usize) bool {
        if (index >= self.account_keys.len) return false;

        // First check: is it a signer?
        if (index < self.header.num_required_signatures) {
            // Signed accounts: first (num_required - num_readonly_signed) are writable
            return index < (self.header.num_required_signatures - self.header.num_readonly_signed_accounts);
        }

        // Unsigned accounts
        const unsigned_start = self.header.num_required_signatures;
        const unsigned_index = index - unsigned_start;
        const num_unsigned = self.account_keys.len - unsigned_start;
        const num_writable_unsigned = num_unsigned - self.header.num_readonly_unsigned_accounts;

        return unsigned_index < num_writable_unsigned;
    }
};

/// Message header (3 bytes)
pub const MessageHeader = struct {
    /// Number of required signatures
    num_required_signatures: u8,

    /// Number of read-only signed accounts
    num_readonly_signed_accounts: u8,

    /// Number of read-only unsigned accounts
    num_readonly_unsigned_accounts: u8,
};

/// Compiled instruction
pub const CompiledInstruction = struct {
    /// Index into account_keys for the program
    program_id_index: u8,

    /// Indices into account_keys for the accounts
    account_indices: []const u8,

    /// Instruction data
    data: []const u8,
};

/// Transaction parser
pub const TransactionParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Parse a transaction from bytes
    pub fn parse(self: *Self, data: []const u8) !ParsedTransaction {
        if (data.len < 4) return error.TooShort;

        var offset: usize = 0;

        // Parse number of signatures
        const num_sigs = data[offset];
        offset += 1;

        if (num_sigs == 0 or num_sigs > 8) return error.InvalidSignatureCount;

        // Parse signatures
        const sig_end = offset + @as(usize, num_sigs) * 64;
        if (sig_end > data.len) return error.TooShort;

        var signatures = try self.allocator.alloc(core.Signature, num_sigs);
        errdefer self.allocator.free(signatures);

        for (0..num_sigs) |i| {
            const sig_start = offset + i * 64;
            @memcpy(&signatures[i].data, data[sig_start..][0..64]);
        }
        offset = sig_end;

        // Message starts here
        const message_start = offset;
        const message_bytes = data[message_start..];

        // Parse message
        const message = try self.parseMessage(message_bytes);

        return ParsedTransaction{
            .signatures = signatures,
            .message = message,
            .message_bytes = message_bytes,
            .is_sanitized = false,
        };
    }

    fn parseMessage(self: *Self, data: []const u8) !Message {
        if (data.len < 4) return error.TooShort;

        var offset: usize = 0;

        // Parse header
        const header = MessageHeader{
            .num_required_signatures = data[offset],
            .num_readonly_signed_accounts = data[offset + 1],
            .num_readonly_unsigned_accounts = data[offset + 2],
        };
        offset += 3;

        // Parse number of account keys (compact-u16)
        const num_accounts = try self.parseCompactU16(data[offset..], &offset);
        if (num_accounts > MAX_ACCOUNTS) return error.TooManyAccounts;

        // Parse account keys
        const keys_end = offset + @as(usize, num_accounts) * 32;
        if (keys_end > data.len) return error.TooShort;

        var account_keys = try self.allocator.alloc(core.Pubkey, num_accounts);
        errdefer self.allocator.free(account_keys);

        for (0..num_accounts) |i| {
            const key_start = offset + i * 32;
            @memcpy(&account_keys[i].data, data[key_start..][0..32]);
        }
        offset = keys_end;

        // Parse recent blockhash
        if (offset + 32 > data.len) return error.TooShort;
        var recent_blockhash: core.Hash = undefined;
        @memcpy(&recent_blockhash.data, data[offset..][0..32]);
        offset += 32;

        // Parse instructions
        const num_instructions = try self.parseCompactU16(data[offset..], &offset);
        if (num_instructions > MAX_INSTRUCTIONS) return error.TooManyInstructions;

        var instructions = try self.allocator.alloc(CompiledInstruction, num_instructions);
        errdefer self.allocator.free(instructions);

        for (0..num_instructions) |i| {
            instructions[i] = try self.parseInstruction(data, &offset);
        }

        return Message{
            .header = header,
            .account_keys = account_keys,
            .recent_blockhash = recent_blockhash,
            .instructions = instructions,
        };
    }

    fn parseInstruction(self: *Self, data: []const u8, offset: *usize) !CompiledInstruction {
        if (offset.* >= data.len) return error.TooShort;

        // Program ID index
        const program_id_index = data[offset.*];
        offset.* += 1;

        // Account indices
        const num_accounts = try self.parseCompactU16(data[offset.*..], offset);
        if (offset.* + num_accounts > data.len) return error.TooShort;

        const account_indices = try self.allocator.alloc(u8, num_accounts);
        errdefer self.allocator.free(account_indices);
        @memcpy(account_indices, data[offset.*..][0..num_accounts]);
        offset.* += num_accounts;

        // Data
        const data_len = try self.parseCompactU16(data[offset.*..], offset);
        if (offset.* + data_len > data.len) return error.TooShort;

        const ix_data = try self.allocator.alloc(u8, data_len);
        errdefer self.allocator.free(ix_data);
        @memcpy(ix_data, data[offset.*..][0..data_len]);
        offset.* += data_len;

        return CompiledInstruction{
            .program_id_index = program_id_index,
            .account_indices = account_indices,
            .data = ix_data,
        };
    }

    pub fn parseCompactU16(self: *Self, data: []const u8, offset: *usize) !u16 {
        _ = self;
        if (data.len == 0) return error.TooShort;

        var value: u16 = 0;
        var shift: u4 = 0;

        for (0..3) |i| {
            if (i >= data.len) return error.TooShort;

            const byte = data[i];
            value |= @as(u16, byte & 0x7F) << shift;

            if (byte & 0x80 == 0) {
                offset.* += i + 1;
                return value;
            }

            shift += 7;
        }

        return error.InvalidCompactU16;
    }
};

/// Sanitize a transaction for execution
pub fn sanitize(tx: *ParsedTransaction) !void {
    const msg = &tx.message;

    // Check header consistency
    if (msg.header.num_required_signatures == 0) {
        return error.NoSignatures;
    }

    if (msg.header.num_required_signatures > msg.account_keys.len) {
        return error.NotEnoughAccounts;
    }

    // Check instruction indices
    for (msg.instructions) |ix| {
        if (ix.program_id_index >= msg.account_keys.len) {
            return error.InvalidProgramIndex;
        }
        for (ix.account_indices) |idx| {
            if (idx >= msg.account_keys.len) {
                return error.InvalidAccountIndex;
            }
        }
    }

    // Check for duplicate accounts
    for (msg.account_keys, 0..) |key, i| {
        for (msg.account_keys[i + 1 ..]) |other| {
            if (std.mem.eql(u8, &key.data, &other.data)) {
                return error.DuplicateAccount;
            }
        }
    }

    tx.is_sanitized = true;
}

/// Well-known program IDs
pub const SystemProgram = core.Pubkey{ .data = [_]u8{0} ** 32 };
pub const VoteProgram = core.Pubkey{
    .data = [_]u8{ 0x07, 0x61, 0x48, 0x1d, 0x35, 0x74, 0x74, 0xbb, 0x7c, 0x4d, 0x76, 0x24, 0xeb, 0xd3, 0xbd, 0xb3, 0xd8, 0x35, 0x5e, 0x73, 0xd1, 0x10, 0x43, 0xfc, 0x0d, 0xa3, 0x53, 0x80, 0x00, 0x00, 0x00, 0x00 },
};
pub const StakeProgram = core.Pubkey{
    .data = [_]u8{ 0x06, 0xa1, 0xd8, 0x17, 0x91, 0x37, 0x54, 0x2a, 0x98, 0x34, 0x37, 0xbd, 0xfe, 0x2a, 0x7a, 0xb2, 0x55, 0x7f, 0x53, 0x5c, 0x8a, 0x78, 0x72, 0x2b, 0x68, 0xa4, 0x9d, 0xc0, 0x00, 0x00, 0x00, 0x00 },
};
pub const ComputeBudgetProgram = core.Pubkey{
    .data = [_]u8{ 0x03, 0x06, 0x46, 0x6f, 0xe5, 0x21, 0x17, 0x32, 0xff, 0xec, 0xad, 0xba, 0x72, 0xc3, 0x9b, 0xe7, 0xbc, 0x8c, 0xe5, 0xbb, 0xc5, 0xf7, 0x12, 0x6b, 0x2c, 0x43, 0x9b, 0x3a, 0x40, 0x00, 0x00, 0x00 },
};

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════
test "message header" {
    const header = MessageHeader{
        .num_required_signatures = 2,
        .num_readonly_signed_accounts = 1,
        .num_readonly_unsigned_accounts = 3,
    };
    try std.testing.expectEqual(@as(u8, 2), header.num_required_signatures);
}

test "compact u16 parsing" {
    var parser = TransactionParser.init(std.testing.allocator);

    // Single byte
    var offset: usize = 0;
    const val1 = try parser.parseCompactU16(&[_]u8{0x05}, &offset);
    try std.testing.expectEqual(@as(u16, 5), val1);

    // Two bytes
    offset = 0;
    const val2 = try parser.parseCompactU16(&[_]u8{ 0x80, 0x01 }, &offset);
    try std.testing.expectEqual(@as(u16, 128), val2);
}

