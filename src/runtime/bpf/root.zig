//! BPF Virtual Machine
//! Executes Solana programs compiled to eBPF bytecode.
//!
//! Architecture:
//! ┌─────────────────────────────────────────────────────────────┐
//! │                    BPF Runtime                               │
//! ├─────────────────────────────────────────────────────────────┤
//! │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
//! │  │ ELF Loader  │  │ Interpreter │  │ Syscalls            │  │
//! │  │             │  │             │  │                     │  │
//! │  │ - Parse ELF │  │ - Execute   │  │ - sol_log           │  │
//! │  │ - Extract   │  │   bytecode  │  │ - sol_memcpy        │  │
//! │  │   bytecode  │  │ - Registers │  │ - sol_sha256        │  │
//! │  │ - Relocate  │  │ - Stack     │  │ - sol_invoke_signed │  │
//! │  └─────────────┘  └─────────────┘  └─────────────────────┘  │
//! ├─────────────────────────────────────────────────────────────┤
//! │                    Program Cache                             │
//! │  ┌──────────────────────────────────────────────────────┐   │
//! │  │ Cached Programs: LoadedProgram instances              │   │
//! │  │ - Bytecode ready for execution                        │   │
//! │  │ - Verified and validated                              │   │
//! │  └──────────────────────────────────────────────────────┘   │
//! └─────────────────────────────────────────────────────────────┘

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const elf_loader = @import("elf_loader.zig");
pub const interpreter = @import("interpreter.zig");
pub const syscalls = @import("syscalls.zig");

pub const ElfLoader = elf_loader.ElfLoader;
pub const LoadedProgram = elf_loader.LoadedProgram;
pub const BpfVm = interpreter.BpfVm;
pub const VmContext = interpreter.VmContext;
pub const VmError = interpreter.VmError;
pub const InvokeContext = syscalls.InvokeContext;
pub const AccountMeta = syscalls.AccountMeta;

/// Program cache for loaded BPF programs
pub const ProgramCache = struct {
    programs: std.AutoHashMap([32]u8, *LoadedProgram),
    allocator: Allocator,
    loader: ElfLoader,

    pub fn init(allocator: Allocator) ProgramCache {
        return .{
            .programs = std.AutoHashMap([32]u8, *LoadedProgram).init(allocator),
            .allocator = allocator,
            .loader = ElfLoader.init(allocator),
        };
    }

    pub fn deinit(self: *ProgramCache) void {
        var iter = self.programs.valueIterator();
        while (iter.next()) |prog_ptr| {
            prog_ptr.*.deinit();
            self.allocator.destroy(prog_ptr.*);
        }
        self.programs.deinit();
    }

    /// Load a program from ELF data
    pub fn loadProgram(self: *ProgramCache, program_id: [32]u8, elf_data: []const u8) !*LoadedProgram {
        // Check cache
        if (self.programs.get(program_id)) |existing| {
            return existing;
        }

        // Load and cache
        const prog = try self.allocator.create(LoadedProgram);
        errdefer self.allocator.destroy(prog);

        prog.* = try self.loader.load(elf_data);
        errdefer prog.deinit();

        try self.programs.put(program_id, prog);
        return prog;
    }

    /// Get a cached program
    pub fn getProgram(self: *ProgramCache, program_id: [32]u8) ?*LoadedProgram {
        return self.programs.get(program_id);
    }

    /// Remove a program from cache
    pub fn removeProgram(self: *ProgramCache, program_id: [32]u8) void {
        if (self.programs.fetchRemove(program_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }
};

/// Execute a program
pub fn executeProgram(
    allocator: Allocator,
    program: *const LoadedProgram,
    invoke_ctx: *InvokeContext,
    accounts: []AccountMeta,
    instruction_data: []const u8,
) !u64 {
    // Set up accounts and instruction data
    invoke_ctx.accounts = accounts;
    invoke_ctx.instruction_data = instruction_data;

    // Create VM context
    var vm_ctx = try VmContext.init(
        allocator,
        program.bytecode,
        program.rodata,
        64 * 1024, // 64KB heap
    );
    defer vm_ctx.deinit();

    // Register syscalls
    try syscalls.registerSyscalls(&vm_ctx);

    // Set up arguments in registers
    // r1 = accounts pointer
    // r2 = accounts length
    // r3 = instruction data pointer
    // r4 = instruction data length
    // r5 = program id pointer
    vm_ctx.registers[1] = @intFromPtr(accounts.ptr);
    vm_ctx.registers[2] = accounts.len;
    vm_ctx.registers[3] = @intFromPtr(instruction_data.ptr);
    vm_ctx.registers[4] = instruction_data.len;
    vm_ctx.registers[5] = @intFromPtr(&invoke_ctx.program_id);

    // Execute
    var vm = BpfVm.init(allocator);
    const result = try vm.execute(&vm_ctx);

    return result;
}

/// Compute budget limits
pub const ComputeBudget = struct {
    /// Default compute units per transaction
    pub const DEFAULT_UNITS: u64 = 200_000;

    /// Maximum compute units per transaction
    pub const MAX_UNITS: u64 = 1_400_000;

    /// Compute units per byte of program data
    pub const UNITS_PER_BYTE: u64 = 100;

    /// Base cost for cross-program invocation
    pub const CPI_BASE_COST: u64 = 1000;

    /// Cost per signer for CPI
    pub const CPI_SIGNER_COST: u64 = 500;

    /// Cost per byte of data for CPI
    pub const CPI_DATA_COST: u64 = 1;

    /// Cost for sha256 hash
    pub const SHA256_BASE_COST: u64 = 85;

    /// Cost per byte for sha256
    pub const SHA256_BYTE_COST: u64 = 1;

    /// Cost for keccak256 hash
    pub const KECCAK256_BASE_COST: u64 = 36;

    /// Cost per byte for keccak256
    pub const KECCAK256_BYTE_COST: u64 = 1;

    /// Cost for secp256k1 recover
    pub const SECP256K1_RECOVER_COST: u64 = 25_000;

    /// Cost for ed25519 verify
    pub const ED25519_VERIFY_COST: u64 = 3_750;
};

// ============================================================================
// Tests
// ============================================================================

test "ProgramCache: basic operations" {
    const allocator = std.testing.allocator;

    var cache = ProgramCache.init(allocator);
    defer cache.deinit();

    // Try to get non-existent program
    const result = cache.getProgram([_]u8{1} ** 32);
    try std.testing.expect(result == null);
}

test "ComputeBudget: constants" {
    try std.testing.expect(ComputeBudget.MAX_UNITS > ComputeBudget.DEFAULT_UNITS);
    try std.testing.expectEqual(@as(u64, 200_000), ComputeBudget.DEFAULT_UNITS);
}

test "imports compile" {
    _ = elf_loader;
    _ = interpreter;
    _ = syscalls;
}

