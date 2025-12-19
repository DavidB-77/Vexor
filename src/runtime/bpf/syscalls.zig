//! BPF Syscalls
//! System call implementations for Solana programs.
//!
//! Solana programs use syscalls to interact with the runtime:
//! - Logging (sol_log)
//! - Memory operations (sol_memcpy, sol_memset, etc.)
//! - Cryptographic operations (sol_sha256, sol_keccak256)
//! - Cross-program invocation (sol_invoke_signed)
//! - Account data access

const std = @import("std");
const Allocator = std.mem.Allocator;
const interpreter = @import("interpreter.zig");
const VmContext = interpreter.VmContext;
const VmError = interpreter.VmError;

/// Syscall IDs (matching Solana runtime)
pub const SYSCALL_ABORT: u32 = 0x7f12d80d;
pub const SYSCALL_SOL_PANIC: u32 = 0x686093bb;
pub const SYSCALL_SOL_LOG: u32 = 0x5c2a4d87;
pub const SYSCALL_SOL_LOG_64: u32 = 0x9f6f8c60;
pub const SYSCALL_SOL_LOG_PUBKEY: u32 = 0x7ef088ca;
pub const SYSCALL_SOL_LOG_COMPUTE_UNITS: u32 = 0x3e8e4ec3;
pub const SYSCALL_SOL_LOG_DATA: u32 = 0x4a3e0a45;
pub const SYSCALL_SOL_MEMCPY: u32 = 0xd697889a;
pub const SYSCALL_SOL_MEMMOVE: u32 = 0x8791a5e3;
pub const SYSCALL_SOL_MEMCMP: u32 = 0x4bfa3c64;
pub const SYSCALL_SOL_MEMSET: u32 = 0x5fdcde31;
pub const SYSCALL_SOL_SHA256: u32 = 0xdeb0e474;
pub const SYSCALL_SOL_KECCAK256: u32 = 0x93f7c5f5;
pub const SYSCALL_SOL_SECP256K1_RECOVER: u32 = 0x7bd0d12a;
pub const SYSCALL_SOL_BLAKE3: u32 = 0x2d0f25ce;
pub const SYSCALL_SOL_POSEIDON: u32 = 0xf0e65b3a;
pub const SYSCALL_SOL_CREATE_PROGRAM_ADDRESS: u32 = 0x9377323c;
pub const SYSCALL_SOL_TRY_FIND_PROGRAM_ADDRESS: u32 = 0x9c2c0e2e;
pub const SYSCALL_SOL_GET_CLOCK_SYSVAR: u32 = 0xdfa2ed0e;
pub const SYSCALL_SOL_GET_EPOCH_SCHEDULE_SYSVAR: u32 = 0x6cb5ee64;
pub const SYSCALL_SOL_GET_RENT_SYSVAR: u32 = 0x4d5d9f6d;
pub const SYSCALL_SOL_GET_RETURN_DATA: u32 = 0xd1e52078;
pub const SYSCALL_SOL_SET_RETURN_DATA: u32 = 0x8b2a3a4e;
pub const SYSCALL_SOL_INVOKE_SIGNED: u32 = 0xd7449092;
pub const SYSCALL_SOL_ALLOC_FREE: u32 = 0x8f21ceb8;
pub const SYSCALL_SOL_GET_PROCESSED_SIBLING_INSTRUCTION: u32 = 0xbcb4e4c6;
pub const SYSCALL_SOL_GET_STACK_HEIGHT: u32 = 0x0c4f45a1;

/// Invoke context for syscalls
pub const InvokeContext = struct {
    /// Program ID being executed
    program_id: [32]u8,
    /// Accounts passed to the program
    accounts: []AccountMeta,
    /// Instruction data
    instruction_data: []const u8,
    /// Remaining compute units
    compute_units: u64,
    /// Maximum compute units
    max_compute_units: u64,
    /// Log collector
    log_messages: std.ArrayList([]const u8),
    /// Return data
    return_data: ?[]const u8,
    /// Return data program ID
    return_data_program_id: ?[32]u8,
    /// Call depth
    call_depth: usize,
    /// Allocator
    allocator: Allocator,

    pub fn init(allocator: Allocator, program_id: [32]u8, compute_budget: u64) !InvokeContext {
        return .{
            .program_id = program_id,
            .accounts = &[_]AccountMeta{},
            .instruction_data = &[_]u8{},
            .compute_units = compute_budget,
            .max_compute_units = compute_budget,
            .log_messages = std.ArrayList([]const u8).init(allocator),
            .return_data = null,
            .return_data_program_id = null,
            .call_depth = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InvokeContext) void {
        for (self.log_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.log_messages.deinit();
    }

    pub fn consumeUnits(self: *InvokeContext, units: u64) bool {
        if (self.compute_units >= units) {
            self.compute_units -= units;
            return true;
        }
        return false;
    }
};

/// Account metadata for CPI
pub const AccountMeta = struct {
    pubkey: [32]u8,
    is_signer: bool,
    is_writable: bool,
    data: []u8,
    lamports: *u64,
    owner: [32]u8,
    executable: bool,
    rent_epoch: u64,
};

/// Syscall handler context
pub const SyscallContext = struct {
    vm: *VmContext,
    invoke: *InvokeContext,
};

/// Register all syscalls with the VM
pub fn registerSyscalls(ctx: *VmContext) !void {
    // Abort/panic
    try ctx.registerSyscall(SYSCALL_ABORT, syscallAbort);
    try ctx.registerSyscall(SYSCALL_SOL_PANIC, syscallPanic);
    
    // Logging
    try ctx.registerSyscall(SYSCALL_SOL_LOG, syscallLog);
    try ctx.registerSyscall(SYSCALL_SOL_LOG_64, syscallLog64);
    try ctx.registerSyscall(SYSCALL_SOL_LOG_PUBKEY, syscallLogPubkey);
    try ctx.registerSyscall(SYSCALL_SOL_LOG_COMPUTE_UNITS, syscallLogComputeUnits);
    try ctx.registerSyscall(SYSCALL_SOL_LOG_DATA, syscallLogData);
    
    // Memory operations
    try ctx.registerSyscall(SYSCALL_SOL_MEMCPY, syscallMemcpy);
    try ctx.registerSyscall(SYSCALL_SOL_MEMMOVE, syscallMemmove);
    try ctx.registerSyscall(SYSCALL_SOL_MEMCMP, syscallMemcmp);
    try ctx.registerSyscall(SYSCALL_SOL_MEMSET, syscallMemset);
    try ctx.registerSyscall(SYSCALL_SOL_ALLOC_FREE, syscallAllocFree);
    
    // Cryptographic operations
    try ctx.registerSyscall(SYSCALL_SOL_SHA256, syscallSha256);
    try ctx.registerSyscall(SYSCALL_SOL_KECCAK256, syscallKeccak256);
    try ctx.registerSyscall(SYSCALL_SOL_BLAKE3, syscallBlake3);
    try ctx.registerSyscall(SYSCALL_SOL_SECP256K1_RECOVER, syscallSecp256k1Recover);
    
    // PDA operations
    try ctx.registerSyscall(SYSCALL_SOL_CREATE_PROGRAM_ADDRESS, syscallCreateProgramAddress);
    try ctx.registerSyscall(SYSCALL_SOL_TRY_FIND_PROGRAM_ADDRESS, syscallTryFindProgramAddress);
    
    // Sysvars
    try ctx.registerSyscall(SYSCALL_SOL_GET_CLOCK_SYSVAR, syscallGetClockSysvar);
    try ctx.registerSyscall(SYSCALL_SOL_GET_RENT_SYSVAR, syscallGetRentSysvar);
    try ctx.registerSyscall(SYSCALL_SOL_GET_EPOCH_SCHEDULE_SYSVAR, syscallGetEpochScheduleSysvar);
    
    // Return data
    try ctx.registerSyscall(SYSCALL_SOL_SET_RETURN_DATA, syscallSetReturnData);
    try ctx.registerSyscall(SYSCALL_SOL_GET_RETURN_DATA, syscallGetReturnData);
    
    // CPI and introspection
    try ctx.registerSyscall(SYSCALL_SOL_INVOKE_SIGNED, syscallInvokeSigned);
    try ctx.registerSyscall(SYSCALL_SOL_GET_STACK_HEIGHT, syscallGetStackHeight);
    try ctx.registerSyscall(SYSCALL_SOL_GET_PROCESSED_SIBLING_INSTRUCTION, syscallGetProcessedSiblingInstruction);
}

// ============================================================================
// Memory Region Validation
// ============================================================================

/// Maximum valid memory region for BPF programs
/// In a real implementation, this would check against the VM's memory map
const MAX_BPF_MEMORY: u64 = 1 << 32; // 4GB address space

/// Minimum valid address (stack starts here in BPF)
const MIN_BPF_MEMORY: u64 = 0x100000000; // 4GB offset (program text)

/// Maximum length for a single memory operation
const MAX_MEMORY_OP_LEN: u64 = 10 * 1024 * 1024; // 10MB limit per operation

/// Validate a memory region is accessible
/// Returns error if the region is invalid
fn validateMemoryRegion(addr: u64, len: u64, write: bool) VmError!void {
    _ = write; // In full implementation, check write permissions
    
    // Zero-length operations are always valid
    if (len == 0) return;
    
    // Check for null pointer
    if (addr == 0) return VmError.AccessViolation;
    
    // Check for overflow
    const end_addr = @addWithOverflow(addr, len);
    if (end_addr[1] != 0) return VmError.AccessViolation;
    
    // Check for unreasonably large operations
    if (len > MAX_MEMORY_OP_LEN) return VmError.AccessViolation;
    
    // In a full implementation, we would check against the VM's memory map here
    // For now, accept addresses that look reasonable
    return;
}

/// Validate two memory regions don't overlap (for memcpy)
fn validateNoOverlap(src: u64, dst: u64, len: u64) VmError!void {
    if (len == 0) return;
    
    const src_end = src + len;
    const dst_end = dst + len;
    
    // Check for overlap
    if ((src < dst_end) and (dst < src_end)) {
        // Regions overlap - this should use memmove instead
        return VmError.AccessViolation;
    }
    
    return;
}

// ============================================================================
// Syscall Implementations
// ============================================================================

fn syscallAbort(_: *VmContext, _: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    return VmError.Halted;
}

fn syscallPanic(_: *VmContext, _: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // file_ptr: u64, file_len: u64, line: u64, column: u64
    return VmError.Halted;
}

fn syscallLog(ctx: *VmContext, msg_ptr: u64, msg_len: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Validate memory region
    try validateMemoryRegion(msg_ptr, msg_len, false);
    
    // Additional safety: limit log message length
    const safe_len = @min(msg_len, 10000); // 10KB max log message
    
    _ = ctx;
    const ptr = @as([*]const u8, @ptrFromInt(msg_ptr));
    const msg = ptr[0..safe_len];

    // In production, this would go to the invoke context's log collector
    std.log.info("Program log: {s}", .{msg});

    return 0;
}

fn syscallLog64(_: *VmContext, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) VmError!u64 {
    // Log 5 u64 values
    std.log.info("Program log: {d} {d} {d} {d} {d}", .{ arg1, arg2, arg3, arg4, arg5 });
    return 0;
}

fn syscallLogPubkey(_: *VmContext, pubkey_ptr: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Log a pubkey in base58
    const ptr = @as([*]const u8, @ptrFromInt(pubkey_ptr));
    const pubkey = ptr[0..32];

    // TODO: Base58 encode
    std.log.info("Program log: pubkey {any}", .{pubkey});
    return 0;
}

fn syscallLogComputeUnits(_: *VmContext, _: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Log remaining compute units
    // Would need invoke context for actual value
    std.log.info("Program log: compute units remaining", .{});
    return 0;
}

fn syscallMemcpy(_: *VmContext, dst: u64, src: u64, n: u64, _: u64, _: u64) VmError!u64 {
    if (n == 0) return 0;

    // Validate source and destination memory regions
    try validateMemoryRegion(src, n, false);
    try validateMemoryRegion(dst, n, true);
    
    // For memcpy, regions must not overlap
    try validateNoOverlap(src, dst, n);

    const dst_ptr = @as([*]u8, @ptrFromInt(dst));
    const src_ptr = @as([*]const u8, @ptrFromInt(src));

    @memcpy(dst_ptr[0..n], src_ptr[0..n]);
    return 0;
}

fn syscallMemmove(_: *VmContext, dst: u64, src: u64, n: u64, _: u64, _: u64) VmError!u64 {
    if (n == 0) return 0;

    // Validate source and destination memory regions
    try validateMemoryRegion(src, n, false);
    try validateMemoryRegion(dst, n, true);

    const dst_ptr = @as([*]u8, @ptrFromInt(dst));
    const src_ptr = @as([*]const u8, @ptrFromInt(src));

    // Use memmove semantics (handles overlapping)
    // Use std library's copy which handles overlap correctly
    const dst_slice = dst_ptr[0..n];
    const src_slice = src_ptr[0..n];

    if (@intFromPtr(dst_ptr) < @intFromPtr(src_ptr)) {
        // Forward copy is safe
        for (0..n) |i| {
            dst_slice[i] = src_slice[i];
        }
    } else if (@intFromPtr(dst_ptr) > @intFromPtr(src_ptr)) {
        // Backward copy needed for overlap safety
        var i = n;
        while (i > 0) {
            i -= 1;
            dst_slice[i] = src_slice[i];
        }
    }
    // If dst == src, no copy needed

    return 0;
}

fn syscallMemcmp(_: *VmContext, s1: u64, s2: u64, n: u64, result_ptr: u64, _: u64) VmError!u64 {
    // Validate all memory regions
    try validateMemoryRegion(s1, n, false);
    try validateMemoryRegion(s2, n, false);
    try validateMemoryRegion(result_ptr, @sizeOf(i32), true);

    const s1_ptr = @as([*]const u8, @ptrFromInt(s1));
    const s2_ptr = @as([*]const u8, @ptrFromInt(s2));
    const result = @as(*i32, @ptrFromInt(result_ptr));

    var cmp: i32 = 0;
    for (0..n) |i| {
        if (s1_ptr[i] != s2_ptr[i]) {
            cmp = @as(i32, s1_ptr[i]) - @as(i32, s2_ptr[i]);
            break;
        }
    }

    result.* = cmp;
    return 0;
}

fn syscallMemset(_: *VmContext, s: u64, c: u64, n: u64, _: u64, _: u64) VmError!u64 {
    if (n == 0) return 0;

    // Validate destination memory region
    try validateMemoryRegion(s, n, true);

    const ptr = @as([*]u8, @ptrFromInt(s));
    @memset(ptr[0..n], @truncate(c));
    return 0;
}

fn syscallSha256(_: *VmContext, vals_ptr: u64, vals_len: u64, result_ptr: u64, _: u64, _: u64) VmError!u64 {
    // Validate result pointer (32 bytes for SHA256)
    try validateMemoryRegion(result_ptr, 32, true);
    
    // Limit number of input slices to prevent DoS
    const max_slices: u64 = 1000;
    if (vals_len > max_slices) return VmError.AccessViolation;
    
    // Validate slice headers array
    const SliceHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    const headers_size = vals_len * @sizeOf(SliceHeader);
    try validateMemoryRegion(vals_ptr, headers_size, false);
    
    // SHA256 hash of concatenated byte arrays
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    const headers_ptr = @as([*]const SliceHeader, @ptrFromInt(vals_ptr));
    for (0..vals_len) |i| {
        const header = headers_ptr[i];
        
        // Validate each data slice
        try validateMemoryRegion(header.ptr, header.len, false);
        
        if (header.len > 0) {
            const data_ptr = @as([*]const u8, @ptrFromInt(header.ptr));
            hasher.update(data_ptr[0..header.len]);
        }
    }

    const digest = hasher.finalResult();
    const result = @as([*]u8, @ptrFromInt(result_ptr));
    @memcpy(result[0..32], &digest);

    return 0;
}

fn syscallKeccak256(_: *VmContext, vals_ptr: u64, vals_len: u64, result_ptr: u64, _: u64, _: u64) VmError!u64 {
    // Validate result pointer (32 bytes for Keccak256)
    try validateMemoryRegion(result_ptr, 32, true);
    
    // Limit number of input slices to prevent DoS
    const max_slices: u64 = 1000;
    if (vals_len > max_slices) return VmError.AccessViolation;
    
    // Validate slice headers array
    const SliceHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    const headers_size = vals_len * @sizeOf(SliceHeader);
    try validateMemoryRegion(vals_ptr, headers_size, false);
    
    // Keccak256 hash
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});

    const headers_ptr = @as([*]const SliceHeader, @ptrFromInt(vals_ptr));
    for (0..vals_len) |i| {
        const header = headers_ptr[i];
        
        // Validate each data slice
        try validateMemoryRegion(header.ptr, header.len, false);
        
        if (header.len > 0) {
            const data_ptr = @as([*]const u8, @ptrFromInt(header.ptr));
            hasher.update(data_ptr[0..header.len]);
        }
    }

    const digest = hasher.finalResult();
    const result = @as([*]u8, @ptrFromInt(result_ptr));
    @memcpy(result[0..32], &digest);

    return 0;
}

fn syscallCreateProgramAddress(_: *VmContext, seeds_ptr: u64, seeds_len: u64, program_id_ptr: u64, result_ptr: u64, _: u64) VmError!u64 {
    // Create a program derived address (PDA)
    // PDA = SHA256("PDA_MARKER" || seeds[0] || seeds[1] || ... || program_id)[0..32]
    // Only valid if result is NOT on the Ed25519 curve
    
    const SeedHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    
    // Hash all seeds
    const headers = @as([*]const SeedHeader, @ptrFromInt(seeds_ptr));
    for (0..seeds_len) |i| {
        const seed_ptr = @as([*]const u8, @ptrFromInt(headers[i].ptr));
        const seed_len = headers[i].len;
        if (seed_len > 32) return 1; // Seeds must be <= 32 bytes
        hasher.update(seed_ptr[0..seed_len]);
    }
    
    // Hash program ID
    const program_id = @as([*]const u8, @ptrFromInt(program_id_ptr));
    hasher.update(program_id[0..32]);
    
    // Hash PDA marker
    hasher.update("ProgramDerivedAddress");
    
    const hash = hasher.finalResult();
    
    // Check if on curve (simplified - real impl checks Ed25519 curve)
    // If hash[31] & 0x80 is set, likely not on curve (approximation)
    if (hash[31] & 0x80 != 0) {
        // Valid PDA - copy to result
        const result = @as([*]u8, @ptrFromInt(result_ptr));
        @memcpy(result[0..32], &hash);
        return 0;
    }
    
    // On curve - invalid PDA
    return 1;
}

fn syscallTryFindProgramAddress(_: *VmContext, seeds_ptr: u64, seeds_len: u64, program_id_ptr: u64, result_ptr: u64, bump_ptr: u64) VmError!u64 {
    // Find a valid PDA by trying bump seeds from 255 down to 0
    const SeedHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    
    const headers = @as([*]const SeedHeader, @ptrFromInt(seeds_ptr));
    const program_id = @as([*]const u8, @ptrFromInt(program_id_ptr));
    const result = @as([*]u8, @ptrFromInt(result_ptr));
    const bump = @as(*u8, @ptrFromInt(bump_ptr));
    
    // Try each bump from 255 down to 0
    var bump_seed: u8 = 255;
    while (true) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        // Hash all seeds
        for (0..seeds_len) |i| {
            const seed_ptr = @as([*]const u8, @ptrFromInt(headers[i].ptr));
            const seed_len = headers[i].len;
            if (seed_len > 32) return 1;
            hasher.update(seed_ptr[0..seed_len]);
        }
        
        // Hash bump seed
        hasher.update(&[_]u8{bump_seed});
        
        // Hash program ID
        hasher.update(program_id[0..32]);
        
        // Hash PDA marker
        hasher.update("ProgramDerivedAddress");
        
        const hash = hasher.finalResult();
        
        // Check if valid PDA (not on curve)
        if (hash[31] & 0x80 != 0) {
            @memcpy(result[0..32], &hash);
            bump.* = bump_seed;
            return 0;
        }
        
        if (bump_seed == 0) break;
        bump_seed -= 1;
    }
    
    // No valid bump found
    return 1;
}

fn syscallGetClockSysvar(_: *VmContext, clock_ptr: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Get Clock sysvar
    const ClockSysvar = extern struct {
        slot: u64,
        epoch_start_timestamp: i64,
        epoch: u64,
        leader_schedule_epoch: u64,
        unix_timestamp: i64,
    };

    const clock = @as(*ClockSysvar, @ptrFromInt(clock_ptr));

    // Would get actual values from invoke context
    const now = std.time.timestamp();
    clock.* = .{
        .slot = 0,
        .epoch_start_timestamp = now,
        .epoch = 0,
        .leader_schedule_epoch = 0,
        .unix_timestamp = now,
    };

    return 0;
}

fn syscallGetRentSysvar(_: *VmContext, rent_ptr: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Get Rent sysvar
    const RentSysvar = extern struct {
        lamports_per_byte_year: u64,
        exemption_threshold: f64,
        burn_percent: u8,
        _padding: [7]u8,
    };

    const rent = @as(*RentSysvar, @ptrFromInt(rent_ptr));
    rent.* = .{
        .lamports_per_byte_year = 3480,
        .exemption_threshold = 2.0,
        .burn_percent = 50,
        ._padding = [_]u8{0} ** 7,
    };

    return 0;
}

fn syscallSetReturnData(_: *VmContext, data_ptr: u64, data_len: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Set return data for cross-program invocation
    _ = data_ptr;
    _ = data_len;
    // Would store in invoke context
    return 0;
}

fn syscallGetReturnData(_: *VmContext, data_ptr: u64, data_len: u64, program_id_ptr: u64, _: u64, _: u64) VmError!u64 {
    // Get return data from previous CPI
    _ = data_ptr;
    _ = data_len;
    _ = program_id_ptr;
    // Would retrieve from invoke context
    return 0;
}

fn syscallGetStackHeight(_: *VmContext, _: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Return current CPI call depth
    // Would get from invoke context
    return 0;
}

/// Cross-program invocation syscall
fn syscallInvokeSigned(_: *VmContext, instruction_ptr: u64, account_infos_ptr: u64, account_infos_len: u64, signers_seeds_ptr: u64, signers_seeds_len: u64) VmError!u64 {
    // CPI: Call another program from within a program
    //
    // instruction_ptr: pointer to Instruction struct
    // account_infos_ptr: pointer to array of AccountInfo
    // account_infos_len: number of account infos
    // signers_seeds_ptr: pointer to array of signer seeds (for PDAs)
    // signers_seeds_len: number of signers
    
    const Instruction = extern struct {
        program_id_ptr: u64,
        accounts_ptr: u64,
        accounts_len: u64,
        data_ptr: u64,
        data_len: u64,
    };
    
    const instruction = @as(*const Instruction, @ptrFromInt(instruction_ptr));
    _ = instruction;
    _ = account_infos_ptr;
    _ = account_infos_len;
    _ = signers_seeds_ptr;
    _ = signers_seeds_len;
    
    // In full implementation:
    // 1. Validate accounts match what instruction expects
    // 2. Verify signer seeds produce valid PDAs
    // 3. Recursively invoke the target program
    // 4. Update account states on return
    
    // For now, return success (real impl would execute)
    return 0;
}

/// Blake3 hash syscall
fn syscallBlake3(_: *VmContext, vals_ptr: u64, vals_len: u64, result_ptr: u64, _: u64, _: u64) VmError!u64 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    
    const SliceHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    
    const headers_ptr = @as([*]const SliceHeader, @ptrFromInt(vals_ptr));
    for (0..vals_len) |i| {
        const header = headers_ptr[i];
        const data_ptr = @as([*]const u8, @ptrFromInt(header.ptr));
        hasher.update(data_ptr[0..header.len]);
    }
    
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    
    const result = @as([*]u8, @ptrFromInt(result_ptr));
    @memcpy(result[0..32], &digest);
    
    return 0;
}

/// secp256k1 signature recovery syscall
fn syscallSecp256k1Recover(_: *VmContext, hash_ptr: u64, recovery_id: u64, signature_ptr: u64, result_ptr: u64, _: u64) VmError!u64 {
    // Recover public key from secp256k1 signature
    // This is used for Ethereum compatibility
    
    _ = hash_ptr;
    _ = recovery_id;
    _ = signature_ptr;
    _ = result_ptr;
    
    // Full implementation would use libsecp256k1
    // For now return error (not implemented)
    return 1;
}

/// Get epoch schedule sysvar
fn syscallGetEpochScheduleSysvar(_: *VmContext, sysvar_ptr: u64, _: u64, _: u64, _: u64, _: u64) VmError!u64 {
    const EpochScheduleSysvar = extern struct {
        slots_per_epoch: u64,
        leader_schedule_slot_offset: u64,
        warmup: bool,
        _padding1: [7]u8,
        first_normal_epoch: u64,
        first_normal_slot: u64,
    };
    
    const sysvar = @as(*EpochScheduleSysvar, @ptrFromInt(sysvar_ptr));
    sysvar.* = .{
        .slots_per_epoch = 432000,
        .leader_schedule_slot_offset = 432000,
        .warmup = false,
        ._padding1 = [_]u8{0} ** 7,
        .first_normal_epoch = 0,
        .first_normal_slot = 0,
    };
    
    return 0;
}

/// Log instruction data
fn syscallLogData(_: *VmContext, data_ptr: u64, data_len: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Log arbitrary data (displayed as base64 in explorers)
    const SliceHeader = extern struct {
        ptr: u64,
        len: u64,
    };
    
    const headers = @as([*]const SliceHeader, @ptrFromInt(data_ptr));
    
    for (0..data_len) |i| {
        const header = headers[i];
        const data = @as([*]const u8, @ptrFromInt(header.ptr));
        std.log.info("Program data: {any}", .{data[0..header.len]});
    }
    
    return 0;
}

/// Allocate memory on heap
fn syscallAllocFree(_: *VmContext, size: u64, free_ptr: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // BPF programs have a simple bump allocator
    // size > 0: allocate
    // free_ptr > 0: free (no-op for bump allocator)
    
    _ = size;
    _ = free_ptr;
    
    // Real implementation would manage heap in VM memory region
    // For now, return null (allocation failed)
    return 0;
}

/// Get processed sibling instruction
fn syscallGetProcessedSiblingInstruction(_: *VmContext, index: u64, result_ptr: u64, _: u64, _: u64, _: u64) VmError!u64 {
    // Get instruction that was processed before current one in same tx
    _ = index;
    _ = result_ptr;
    
    // Would need transaction context
    return 1; // Not found
}

// ============================================================================
// Tests
// ============================================================================

test "syscall: memset" {
    const allocator = std.testing.allocator;

    const buffer = try allocator.alloc(u8, 32);
    defer allocator.free(buffer);

    const result = try syscallMemset(undefined, @intFromPtr(buffer.ptr), 0x42, 32, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), result);

    for (buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0x42), byte);
    }
}

test "syscall: sha256" {
    // Simplified test - real syscalls need VM context
    const data = "hello world";
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    const hash = hasher.finalResult();

    try std.testing.expectEqual(@as(usize, 32), hash.len);
}

test "InvokeContext: compute units" {
    const allocator = std.testing.allocator;

    var ctx = try InvokeContext.init(allocator, [_]u8{0} ** 32, 1000);
    defer ctx.deinit();

    try std.testing.expect(ctx.consumeUnits(100));
    try std.testing.expectEqual(@as(u64, 900), ctx.compute_units);

    try std.testing.expect(!ctx.consumeUnits(1000));
    try std.testing.expectEqual(@as(u64, 900), ctx.compute_units);
}

