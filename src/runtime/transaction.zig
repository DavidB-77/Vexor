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
const bpf = @import("bpf/root.zig");

/// Maximum accounts per transaction (total, including ALT)
pub const MAX_ACCOUNTS: usize = 256;

/// Maximum instructions per transaction
pub const MAX_INSTRUCTIONS: usize = 256;

/// Maximum signatures per transaction
pub const MAX_SIGNATURES: usize = 256;

/// Maximum transaction size (Solana UDP packet payload limit)
pub const MAX_TX_SIZE: usize = 1232;

/// Maximum accounts in a single instruction
pub const MAX_INSTRUCTION_ACCOUNTS: usize = 255;

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

    pub fn deinit(self: ParsedTransaction, allocator: std.mem.Allocator) void {
        allocator.free(self.signatures);
        self.message.deinit(allocator);
    }

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

    /// Convert to bank-compatible transaction format
    pub fn toBankTransaction(self: ParsedTransaction, allocator: std.mem.Allocator) !@import("bank.zig").Transaction {
        const bank_mod = @import("bank.zig");

        // Default compute budget
        var compute_unit_limit: u32 = @intCast(bpf.ComputeBudget.DEFAULT_UNITS);
        var compute_unit_price: u64 = 0;

        // Parse instructions to find Compute Budget settings
        for (self.message.instructions) |*ix| {
            const program_id = self.message.account_keys[ix.program_id_index];
            if (std.mem.eql(u8, &program_id.data, &ComputeBudgetProgram.data)) {
                if (ix.data.len > 0) {
                    const discriminant = ix.data[0];
                    switch (discriminant) {
                        0 => { // RequestUnits (Legacy)
                            if (ix.data.len >= 9) {
                                compute_unit_limit = std.mem.readInt(u32, ix.data[1..5], .little);
                                // additional_fee is ignored in modern Solana in favor of SetComputeUnitPrice
                            }
                        },
                        1 => {}, // RequestHeapFrame (Ignored for now)
                        2 => { // SetComputeUnitLimit
                            if (ix.data.len >= 5) {
                                compute_unit_limit = std.mem.readInt(u32, ix.data[1..5], .little);
                            }
                        },
                        3 => { // SetComputeUnitPrice
                            if (ix.data.len >= 9) {
                                compute_unit_price = std.mem.readInt(u64, ix.data[1..9], .little);
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        // Populate account writability
        const account_writability = try allocator.alloc(bool, self.message.account_keys.len);
        for (self.message.account_keys, 0..) |_, i| {
            account_writability[i] = self.message.isWritable(i);
        }

        // We need to map Instructions (ParsedTransaction) to bank_mod.Instruction
        const instructions = try allocator.alloc(bank_mod.Instruction, self.message.instructions.len);
        for (self.message.instructions, 0..) |*ix, i| {
            instructions[i] = bank_mod.Instruction{
                .program_id_index = ix.program_id_index,
                .account_indices = ix.account_indices,
                .data = ix.data,
            };
        }

        return bank_mod.Transaction{
            .fee_payer = self.feePayer(),
            .signatures = self.signatures,
            .signature_count = @intCast(self.signatures.len),
            .signatures_verified = true, // We already verified them in TPU
            .message = self.message_bytes,
            .recent_blockhash = self.message.recent_blockhash,
            .compute_unit_limit = compute_unit_limit,
            .compute_unit_price = compute_unit_price,
            .account_keys = self.message.account_keys,
            .account_writability = account_writability,
            .instructions = instructions,
        };
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

    /// Address lookup tables (v0 only)
    address_lookups: []const AddressLookup,

    /// Whether this is a versioned transaction
    is_versioned: bool,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.account_keys);
        for (self.instructions) |ix| ix.deinit(allocator);
        allocator.free(self.instructions);
        if (self.address_lookups.len > 0) {
            for (self.address_lookups) |alt| alt.deinit(allocator);
            allocator.free(self.address_lookups);
        }
    }

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

    pub fn deinit(self: CompiledInstruction, allocator: std.mem.Allocator) void {
        allocator.free(self.account_indices);
        allocator.free(self.data);
    }
};

/// Address lookup table reference in versioned transactions
pub const AddressLookup = struct {
    account_key: core.Pubkey,
    writable_indexes: []const u8,
    readonly_indexes: []const u8,

    pub fn deinit(self: AddressLookup, allocator: std.mem.Allocator) void {
        allocator.free(self.writable_indexes);
        allocator.free(self.readonly_indexes);
    }
};

/// Transaction parser
pub const TransactionParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Parse a transaction from a slice (starts at offset 0)
    pub fn parseFromSlice(self: *Self, data: []const u8) !ParsedTransaction {
        var offset: usize = 0;
        return self.parse(data, &offset);
    }

    /// Parse a transaction from bytes and update the offset
    pub fn parse(self: *Self, data: []const u8, offset: *usize) !ParsedTransaction {
        if (offset.* + 4 > data.len) return error.TooShort;

        const num_sigs = try self.parseCompactU16(data[offset.*..], offset);

        if (num_sigs == 0 or num_sigs > MAX_SIGNATURES) {
            return error.InvalidSignatureCount;
        }

        // Parse signatures
        const sig_end = offset.* + @as(usize, num_sigs) * 64;
        if (sig_end > data.len) return error.TooShort;

        var signatures = try self.allocator.alloc(core.Signature, num_sigs);
        errdefer self.allocator.free(signatures);

        for (0..num_sigs) |i| {
            const sig_start = offset.* + i * 64;
            @memcpy(&signatures[i].data, data[sig_start..][0..64]);
        }
        offset.* = sig_end;

        // Message starts here
        const message_start = offset.*;

        // Parse message
        const message = self.parseMessage(data, offset) catch |err| {
            return err;
        };
        const message_end = offset.*;
        const message_bytes = data[message_start..message_end];

        // TX-DEBUG logging removed for performance

        return ParsedTransaction{
            .signatures = signatures,
            .message = message,
            .message_bytes = message_bytes,
            .is_sanitized = false,
        };
    }

    fn parseMessage(self: *Self, data: []const u8, offset: *usize) !Message {
        if (offset.* >= data.len) return error.TooShort;

        var is_versioned = false;
        if (data[offset.*] & 0x80 != 0) {
            is_versioned = true;
            const version = data[offset.*] & 0x7F;

            if (version != 0) return error.UnsupportedTransactionVersion;
            offset.* += 1;
        } else {

        }

        if (offset.* + 3 > data.len) return error.TooShort;

        // Parse header
        const header = MessageHeader{
            .num_required_signatures = data[offset.*],
            .num_readonly_signed_accounts = data[offset.* + 1],
            .num_readonly_unsigned_accounts = data[offset.* + 2],
        };

        offset.* += 3;

        // Parse number of account keys (compact-u16)
        const num_accounts = try self.parseCompactU16(data[offset.*..], offset);


        if (num_accounts > MAX_ACCOUNTS) {

            return error.TooManyAccounts;
        }



        // Parse account keys
        const keys_end = offset.* + @as(usize, num_accounts) * 32;
        if (keys_end > data.len) return error.TooShort;

        var account_keys = try self.allocator.alloc(core.Pubkey, num_accounts);
        errdefer self.allocator.free(account_keys);

        for (0..num_accounts) |i| {
            const key_start = offset.* + i * 32;
            @memcpy(&account_keys[i].data, data[key_start..][0..32]);
        }
        offset.* = keys_end;

        // Parse recent blockhash
        if (offset.* + 32 > data.len) return error.TooShort;
        var recent_blockhash: core.Hash = undefined;
        @memcpy(&recent_blockhash.data, data[offset.*..][0..32]);
        offset.* += 32;

        // Parse instructions
        const num_instructions = try self.parseCompactU16(data[offset.*..], offset);


        if (num_instructions > MAX_INSTRUCTIONS or num_instructions > MAX_TX_SIZE) {

            return error.TooManyInstructions;
        }

        var instructions = try self.allocator.alloc(CompiledInstruction, num_instructions);
        errdefer self.allocator.free(instructions);

        for (0..num_instructions) |i| {
            instructions[i] = try self.parseInstruction(data, offset);
        }

        // Parse address lookup tables if versioned
        var address_lookups: []AddressLookup = &[_]AddressLookup{};
        if (is_versioned) {
            const num_lookups = try self.parseCompactU16(data[offset.*..], offset);
            if (num_lookups > 0) {
                if (num_lookups > 127) return error.TooManyAddressLookups;
                address_lookups = try self.allocator.alloc(AddressLookup, num_lookups);
                // Initialize to avoid garbage during error deinit
                for (address_lookups) |*alt| alt.* = .{ .account_key = undefined, .writable_indexes = &.{}, .readonly_indexes = &.{} };
                errdefer {
                    for (address_lookups) |alt| alt.deinit(self.allocator);
                    self.allocator.free(address_lookups);
                }

                for (0..num_lookups) |i| {
                    if (offset.* + 32 > data.len) return error.TooShort;
                    var table_key: core.Pubkey = undefined;
                    @memcpy(&table_key.data, data[offset.*..][0..32]);
                    offset.* += 32;

                    const num_writable = try self.parseCompactU16(data[offset.*..], offset);
                    if (offset.* + num_writable > data.len) return error.TooShort;
                    const writable_indexes = try self.allocator.alloc(u8, num_writable);
                    @memcpy(writable_indexes, data[offset.*..][0..num_writable]);
                    offset.* += num_writable;

                    const num_readonly = try self.parseCompactU16(data[offset.*..], offset);
                    if (offset.* + num_readonly > data.len) return error.TooShort;
                    const readonly_indexes = try self.allocator.alloc(u8, num_readonly);
                    @memcpy(readonly_indexes, data[offset.*..][0..num_readonly]);
                    offset.* += num_readonly;

                    address_lookups[i] = AddressLookup{
                        .account_key = table_key,
                        .writable_indexes = writable_indexes,
                        .readonly_indexes = readonly_indexes,
                    };
                }
            }
        }

        return Message{
            .header = header,
            .account_keys = account_keys,
            .recent_blockhash = recent_blockhash,
            .instructions = instructions,
            .address_lookups = address_lookups,
            .is_versioned = is_versioned,
        };
    }

    fn parseInstruction(self: *Self, data: []const u8, offset: *usize) !CompiledInstruction {
        if (offset.* >= data.len) return error.TooShort;

        // Program ID index
        const program_id_index = data[offset.*];
        offset.* += 1;

        // Account indices
        const num_accounts = try self.parseCompactU16(data[offset.*..], offset);


        if (num_accounts > 255) return error.TooManyInstructionAccounts;
        if (offset.* + num_accounts > data.len) return error.TooShort;

        const account_indices = try self.allocator.alloc(u8, num_accounts);
        errdefer self.allocator.free(account_indices);
        @memcpy(account_indices, data[offset.*..][0..num_accounts]);
        offset.* += num_accounts;

        // Data
        const ix_data_offset = offset.*;
        const data_len = try self.parseCompactU16(data[offset.*..], offset);
        if (data_len > MAX_TX_SIZE) {
            std.log.err("[TX-DEBUG] Instruction data too long: {d} at offset {d}", .{ data_len, ix_data_offset });
            return error.InstructionDataTooLong;
        }


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

    pub fn parseCompactU16(self: *Self, slice: []const u8, offset: *usize) !u16 {
        _ = self;
        var fbs = std.io.fixedBufferStream(slice);
        const reader = fbs.reader();
        const value = try std.leb.readULEB128(u16, reader);
        offset.* += fbs.pos;
        return value;
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
// TRANSACTION MEASUREMENT (Gap 2 Fix: Offset Safety)
// ═══════════════════════════════════════════════════════════════════════════════

/// Measures the exact byte size of a transaction in the wire format WITHOUT
/// allocating memory. This allows the replay loop to always advance the offset
/// correctly, even when parsing fails mid-way.
///
/// Wire format:
///   [num_sigs: compact-u16][sigs: 64*num_sigs]
///   [version_prefix: 0-1 bytes]
///   [header: 3][accounts: 32*n][blockhash: 32]
///   [instructions...][address_lookups (if versioned)...]
pub fn measureTransaction(data: []const u8, start: usize) error{TooShort}!usize {
    var pos = start;

    // 1. Signatures
    const num_sigs = readCompactU16(data, &pos) catch return error.TooShort;
    const sigs_bytes = @as(usize, num_sigs) * 64;
    if (pos + sigs_bytes > data.len) return error.TooShort;
    pos += sigs_bytes;

    // 2. Message: check for versioned prefix
    if (pos >= data.len) return error.TooShort;
    var is_versioned = false;
    if (data[pos] & 0x80 != 0) {
        is_versioned = true;
        pos += 1; // skip version byte
    }

    // 3. Header (3 bytes)
    if (pos + 3 > data.len) return error.TooShort;
    pos += 3;

    // 4. Account keys
    const num_accounts = readCompactU16(data, &pos) catch return error.TooShort;
    const keys_bytes = @as(usize, num_accounts) * 32;
    if (pos + keys_bytes > data.len) return error.TooShort;
    pos += keys_bytes;

    // 5. Recent blockhash
    if (pos + 32 > data.len) return error.TooShort;
    pos += 32;

    // 6. Instructions
    const num_instructions = readCompactU16(data, &pos) catch return error.TooShort;
    for (0..num_instructions) |_| {
        // program_id_index
        if (pos >= data.len) return error.TooShort;
        pos += 1;

        // account indices
        const num_ix_accounts = readCompactU16(data, &pos) catch return error.TooShort;
        if (pos + num_ix_accounts > data.len) return error.TooShort;
        pos += num_ix_accounts;

        // instruction data
        const ix_data_len = readCompactU16(data, &pos) catch return error.TooShort;
        if (pos + ix_data_len > data.len) return error.TooShort;
        pos += ix_data_len;
    }

    // 7. Address lookup tables (versioned only)
    if (is_versioned) {
        const num_lookups = readCompactU16(data, &pos) catch return error.TooShort;
        for (0..num_lookups) |_| {
            // table key (32 bytes)
            if (pos + 32 > data.len) return error.TooShort;
            pos += 32;

            // writable indexes
            const num_writable = readCompactU16(data, &pos) catch return error.TooShort;
            if (pos + num_writable > data.len) return error.TooShort;
            pos += num_writable;

            // readonly indexes
            const num_readonly = readCompactU16(data, &pos) catch return error.TooShort;
            if (pos + num_readonly > data.len) return error.TooShort;
            pos += num_readonly;
        }
    }

    return pos - start;
}

/// Read a compact-u16 (LEB128) without allocating. Advances pos.
fn readCompactU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* >= data.len) return error.TooShort;
    var value: u16 = 0;
    var shift: u4 = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (pos.* + i >= data.len) return error.TooShort;
        const byte = data[pos.* + i];
        value |= @as(u16, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            pos.* += i + 1;
            return value;
        }
        shift += 7;
    }
    return error.TooShort; // malformed LEB128
}

// ═══════════════════════════════════════════════════════════════════════════════
// ADDRESS LOOKUP TABLE RESOLUTION (Step B: Resolve ALTs)
// ═══════════════════════════════════════════════════════════════════════════════

/// ALT resolution errors — all are non-fatal, just skip the transaction
pub const AltError = error{
    AltAccountNotFound,
    AltDataTooShort,
    AltIndexOutOfBounds,
    OutOfMemory,
};

/// Size of the Address Lookup Table account header.
/// Layout: [authority: 32][deactivation_slot: u64][padding + length fields: 16]
pub const ALT_HEADER_SIZE: usize = 56;

/// Resolves v0 Address Lookup Tables for a parsed transaction.
/// Reads ALT accounts from accounts_db, extracts pubkeys at the specified
/// indexes, and returns a NEW extended account_keys array that includes
/// both the static keys and the resolved ALT keys.
///
/// Order (matching Agave): static_keys ++ writable_alt_keys ++ readonly_alt_keys
///
/// Caller owns the returned slice and must free it.
/// The original tx.message.account_keys is NOT freed — caller manages lifecycle.
pub fn resolveTransactionALTs(
    allocator: std.mem.Allocator,
    tx: *const ParsedTransaction,
    accounts_db: anytype,
) AltError![]core.Pubkey {
    const lookups = tx.message.address_lookups;
    if (lookups.len == 0) {
        // No ALTs — return a copy of static keys
        const copy = allocator.alloc(core.Pubkey, tx.message.account_keys.len) catch
            return AltError.OutOfMemory;
        @memcpy(copy, tx.message.account_keys);
        return copy;
    }

    // Count total additional keys needed
    var extra_keys: usize = 0;
    for (lookups) |*alt| {
        extra_keys += alt.writable_indexes.len + alt.readonly_indexes.len;
    }

    const total_keys = tx.message.account_keys.len + extra_keys;
    const extended_keys = allocator.alloc(core.Pubkey, total_keys) catch
        return AltError.OutOfMemory;

    // Copy static keys
    @memcpy(extended_keys[0..tx.message.account_keys.len], tx.message.account_keys);

    // Resolve each ALT
    var write_pos = tx.message.account_keys.len;
    for (lookups) |*alt| {
        // Look up the ALT account in our accounts_db
        const alt_account = accounts_db.getAccount(&alt.account_key) orelse {
            allocator.free(extended_keys);
            return AltError.AltAccountNotFound;
        };

        // ALT data: [56-byte header][packed 32-byte pubkeys...]
        if (alt_account.data.len < ALT_HEADER_SIZE) {
            allocator.free(extended_keys);
            return AltError.AltDataTooShort;
        }

        const addresses_data = alt_account.data[ALT_HEADER_SIZE..];
        const num_addresses = addresses_data.len / 32;

        // Extract writable addresses first (Agave order)
        for (alt.writable_indexes) |idx| {
            if (idx >= num_addresses) {
                allocator.free(extended_keys);
                return AltError.AltIndexOutOfBounds;
            }
            const addr_start = @as(usize, idx) * 32;
            @memcpy(&extended_keys[write_pos].data, addresses_data[addr_start..][0..32]);
            write_pos += 1;
        }

        // Then readonly addresses
        for (alt.readonly_indexes) |idx| {
            if (idx >= num_addresses) {
                allocator.free(extended_keys);
                return AltError.AltIndexOutOfBounds;
            }
            const addr_start = @as(usize, idx) * 32;
            @memcpy(&extended_keys[write_pos].data, addresses_data[addr_start..][0..32]);
            write_pos += 1;
        }
    }

    return extended_keys;
}


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
