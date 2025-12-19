//! BPF Interpreter
//! Executes eBPF bytecode for Solana programs.
//!
//! The BPF virtual machine uses:
//! - 11 64-bit registers (r0-r10)
//! - r10 is the read-only frame pointer
//! - r1-r5 are arguments for function calls
//! - r0 is the return value
//! - Stack of 64KB per call frame

const std = @import("std");
const Allocator = std.mem.Allocator;

/// BPF instruction encoding (8 bytes)
pub const BpfInstruction = packed struct {
    opcode: u8,
    dst_src: u8, // dst:4 | src:4
    offset: i16,
    imm: i32,

    pub fn dst(self: BpfInstruction) u4 {
        return @truncate(self.dst_src & 0x0f);
    }

    pub fn src(self: BpfInstruction) u4 {
        return @truncate(self.dst_src >> 4);
    }
};

/// BPF instruction classes
const BPF_LD: u8 = 0x00;
const BPF_LDX: u8 = 0x01;
const BPF_ST: u8 = 0x02;
const BPF_STX: u8 = 0x03;
const BPF_ALU: u8 = 0x04;
const BPF_JMP: u8 = 0x05;
const BPF_JMP32: u8 = 0x06;
const BPF_ALU64: u8 = 0x07;

/// ALU operations
const BPF_ADD: u8 = 0x00;
const BPF_SUB: u8 = 0x10;
const BPF_MUL: u8 = 0x20;
const BPF_DIV: u8 = 0x30;
const BPF_OR: u8 = 0x40;
const BPF_AND: u8 = 0x50;
const BPF_LSH: u8 = 0x60;
const BPF_RSH: u8 = 0x70;
const BPF_NEG: u8 = 0x80;
const BPF_MOD: u8 = 0x90;
const BPF_XOR: u8 = 0xa0;
const BPF_MOV: u8 = 0xb0;
const BPF_ARSH: u8 = 0xc0;
const BPF_END: u8 = 0xd0;

/// Jump operations
const BPF_JA: u8 = 0x00;
const BPF_JEQ: u8 = 0x10;
const BPF_JGT: u8 = 0x20;
const BPF_JGE: u8 = 0x30;
const BPF_JSET: u8 = 0x40;
const BPF_JNE: u8 = 0x50;
const BPF_JSGT: u8 = 0x60;
const BPF_JSGE: u8 = 0x70;
const BPF_CALL: u8 = 0x80;
const BPF_EXIT: u8 = 0x90;
const BPF_JLT: u8 = 0xa0;
const BPF_JLE: u8 = 0xb0;
const BPF_JSLT: u8 = 0xc0;
const BPF_JSLE: u8 = 0xd0;

/// Source modifiers
const BPF_K: u8 = 0x00; // Immediate
const BPF_X: u8 = 0x08; // Register

/// Memory size modifiers
const BPF_W: u8 = 0x00; // Word (4 bytes)
const BPF_H: u8 = 0x08; // Half-word (2 bytes)
const BPF_B: u8 = 0x10; // Byte
const BPF_DW: u8 = 0x18; // Double-word (8 bytes)

/// Memory mode
const BPF_MEM: u8 = 0x60;

/// Stack size per frame
const STACK_SIZE: usize = 64 * 1024;

/// Maximum call depth
const MAX_CALL_DEPTH: usize = 64;

/// Maximum instructions per execution
const MAX_INSTRUCTIONS: u64 = 200_000;

/// VM execution errors
pub const VmError = error{
    InvalidInstruction,
    DivisionByZero,
    InvalidMemoryAccess,
    StackOverflow,
    CallDepthExceeded,
    InstructionLimitExceeded,
    InvalidSyscall,
    SyscallFailed,
    InvalidRegister,
    Halted,
};

/// Syscall function type
pub const SyscallFn = *const fn (*VmContext, u64, u64, u64, u64, u64) VmError!u64;

/// VM execution context
pub const VmContext = struct {
    /// Registers r0-r10
    registers: [11]u64,
    /// Program counter
    pc: usize,
    /// Stack memory
    stack: []u8,
    /// Heap memory (for program data)
    heap: []u8,
    /// Read-only data
    rodata: []const u8,
    /// Program bytecode
    bytecode: []const u8,
    /// Instruction count
    instruction_count: u64,
    /// Call stack for return addresses
    call_stack: std.ArrayList(usize),
    /// Frame pointer stack
    frame_stack: std.ArrayList(u64),
    /// Syscall handlers
    syscalls: std.AutoHashMap(u32, SyscallFn),
    /// Is running
    running: bool,
    /// Allocator
    allocator: Allocator,

    pub fn init(allocator: Allocator, bytecode: []const u8, rodata: []const u8, heap_size: usize) !VmContext {
        const stack = try allocator.alloc(u8, STACK_SIZE);
        errdefer allocator.free(stack);

        const heap = try allocator.alloc(u8, heap_size);
        errdefer allocator.free(heap);

        var ctx = VmContext{
            .registers = [_]u64{0} ** 11,
            .pc = 0,
            .stack = stack,
            .heap = heap,
            .rodata = rodata,
            .bytecode = bytecode,
            .instruction_count = 0,
            .call_stack = std.ArrayList(usize).init(allocator),
            .frame_stack = std.ArrayList(u64).init(allocator),
            .syscalls = std.AutoHashMap(u32, SyscallFn).init(allocator),
            .running = true,
            .allocator = allocator,
        };

        // Set r10 (frame pointer) to top of stack
        ctx.registers[10] = @intFromPtr(stack.ptr) + STACK_SIZE;

        return ctx;
    }

    pub fn deinit(self: *VmContext) void {
        self.allocator.free(self.stack);
        self.allocator.free(self.heap);
        self.call_stack.deinit();
        self.frame_stack.deinit();
        self.syscalls.deinit();
    }

    pub fn registerSyscall(self: *VmContext, id: u32, handler: SyscallFn) !void {
        try self.syscalls.put(id, handler);
    }
};

/// BPF Virtual Machine
pub const BpfVm = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) BpfVm {
        return .{ .allocator = allocator };
    }

    /// Execute bytecode and return result in r0
    pub fn execute(self: *BpfVm, ctx: *VmContext) VmError!u64 {
        _ = self;

        while (ctx.running) {
            // Check instruction limit
            if (ctx.instruction_count >= MAX_INSTRUCTIONS) {
                return VmError.InstructionLimitExceeded;
            }
            ctx.instruction_count += 1;

            // Fetch instruction
            const insn = fetchInstruction(ctx) orelse return VmError.InvalidInstruction;
            ctx.pc += 1;

            // Decode and execute
            try executeInstruction(ctx, insn);
        }

        return ctx.registers[0];
    }

    fn fetchInstruction(ctx: *VmContext) ?BpfInstruction {
        const offset = ctx.pc * 8;
        if (offset + 8 > ctx.bytecode.len) return null;

        const bytes = ctx.bytecode[offset..][0..8];
        return @bitCast(bytes.*);
    }

    fn executeInstruction(ctx: *VmContext, insn: BpfInstruction) VmError!void {
        const class = insn.opcode & 0x07;
        const dst = insn.dst();
        const src = insn.src();

        switch (class) {
            BPF_ALU64 => try executeAlu64(ctx, insn, dst, src),
            BPF_ALU => try executeAlu32(ctx, insn, dst, src),
            BPF_JMP => try executeJmp(ctx, insn, dst, src),
            BPF_JMP32 => try executeJmp32(ctx, insn, dst, src),
            BPF_LDX => try executeLdx(ctx, insn, dst, src),
            BPF_STX => try executeStx(ctx, insn, dst, src),
            BPF_ST => try executeSt(ctx, insn, dst),
            BPF_LD => try executeLd(ctx, insn, dst),
            else => return VmError.InvalidInstruction,
        }
    }

    fn executeAlu64(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const op = insn.opcode & 0xf0;
        const is_imm = (insn.opcode & 0x08) == 0;
        const src_val: u64 = if (is_imm) @as(u64, @bitCast(@as(i64, insn.imm))) else ctx.registers[src];

        switch (op) {
            BPF_ADD => ctx.registers[dst] +%= src_val,
            BPF_SUB => ctx.registers[dst] -%= src_val,
            BPF_MUL => ctx.registers[dst] *%= src_val,
            BPF_DIV => {
                if (src_val == 0) return VmError.DivisionByZero;
                ctx.registers[dst] /= src_val;
            },
            BPF_OR => ctx.registers[dst] |= src_val,
            BPF_AND => ctx.registers[dst] &= src_val,
            BPF_LSH => ctx.registers[dst] <<= @truncate(src_val),
            BPF_RSH => ctx.registers[dst] >>= @truncate(src_val),
            BPF_NEG => ctx.registers[dst] = @bitCast(-@as(i64, @bitCast(ctx.registers[dst]))),
            BPF_MOD => {
                if (src_val == 0) return VmError.DivisionByZero;
                ctx.registers[dst] %= src_val;
            },
            BPF_XOR => ctx.registers[dst] ^= src_val,
            BPF_MOV => ctx.registers[dst] = src_val,
            BPF_ARSH => {
                const signed: i64 = @bitCast(ctx.registers[dst]);
                ctx.registers[dst] = @bitCast(signed >> @truncate(src_val));
            },
            else => return VmError.InvalidInstruction,
        }
    }

    fn executeAlu32(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const op = insn.opcode & 0xf0;
        const is_imm = (insn.opcode & 0x08) == 0;
        const src_val: u32 = if (is_imm) @bitCast(insn.imm) else @truncate(ctx.registers[src]);
        var dst_val: u32 = @truncate(ctx.registers[dst]);

        switch (op) {
            BPF_ADD => dst_val +%= src_val,
            BPF_SUB => dst_val -%= src_val,
            BPF_MUL => dst_val *%= src_val,
            BPF_DIV => {
                if (src_val == 0) return VmError.DivisionByZero;
                dst_val /= src_val;
            },
            BPF_OR => dst_val |= src_val,
            BPF_AND => dst_val &= src_val,
            BPF_LSH => dst_val <<= @truncate(src_val),
            BPF_RSH => dst_val >>= @truncate(src_val),
            BPF_NEG => dst_val = @bitCast(-@as(i32, @bitCast(dst_val))),
            BPF_MOD => {
                if (src_val == 0) return VmError.DivisionByZero;
                dst_val %= src_val;
            },
            BPF_XOR => dst_val ^= src_val,
            BPF_MOV => dst_val = src_val,
            BPF_ARSH => {
                const signed: i32 = @bitCast(dst_val);
                dst_val = @bitCast(signed >> @truncate(src_val));
            },
            else => return VmError.InvalidInstruction,
        }

        // Zero-extend to 64 bits
        ctx.registers[dst] = dst_val;
    }

    fn executeJmp(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const op = insn.opcode & 0xf0;
        const is_imm = (insn.opcode & 0x08) == 0;
        const src_val: u64 = if (is_imm) @as(u64, @bitCast(@as(i64, insn.imm))) else ctx.registers[src];
        const dst_val = ctx.registers[dst];

        const should_jump = switch (op) {
            BPF_JA => true,
            BPF_JEQ => dst_val == src_val,
            BPF_JGT => dst_val > src_val,
            BPF_JGE => dst_val >= src_val,
            BPF_JSET => (dst_val & src_val) != 0,
            BPF_JNE => dst_val != src_val,
            BPF_JSGT => @as(i64, @bitCast(dst_val)) > @as(i64, @bitCast(src_val)),
            BPF_JSGE => @as(i64, @bitCast(dst_val)) >= @as(i64, @bitCast(src_val)),
            BPF_JLT => dst_val < src_val,
            BPF_JLE => dst_val <= src_val,
            BPF_JSLT => @as(i64, @bitCast(dst_val)) < @as(i64, @bitCast(src_val)),
            BPF_JSLE => @as(i64, @bitCast(dst_val)) <= @as(i64, @bitCast(src_val)),
            BPF_CALL => {
                try executeCall(ctx, insn);
                return;
            },
            BPF_EXIT => {
                if (ctx.call_stack.items.len > 0) {
                    // Return from function call
                    ctx.pc = ctx.call_stack.pop();
                    ctx.registers[10] = ctx.frame_stack.pop();
                } else {
                    // Exit program
                    ctx.running = false;
                }
                return;
            },
            else => return VmError.InvalidInstruction,
        };

        if (should_jump) {
            const offset: i64 = insn.offset;
            const new_pc = @as(i64, @intCast(ctx.pc)) + offset;
            if (new_pc < 0) return VmError.InvalidInstruction;
            ctx.pc = @intCast(new_pc);
        }
    }

    fn executeJmp32(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const op = insn.opcode & 0xf0;
        const is_imm = (insn.opcode & 0x08) == 0;
        const src_val: u32 = if (is_imm) @bitCast(insn.imm) else @truncate(ctx.registers[src]);
        const dst_val: u32 = @truncate(ctx.registers[dst]);

        const should_jump = switch (op) {
            BPF_JEQ => dst_val == src_val,
            BPF_JGT => dst_val > src_val,
            BPF_JGE => dst_val >= src_val,
            BPF_JSET => (dst_val & src_val) != 0,
            BPF_JNE => dst_val != src_val,
            BPF_JSGT => @as(i32, @bitCast(dst_val)) > @as(i32, @bitCast(src_val)),
            BPF_JSGE => @as(i32, @bitCast(dst_val)) >= @as(i32, @bitCast(src_val)),
            BPF_JLT => dst_val < src_val,
            BPF_JLE => dst_val <= src_val,
            BPF_JSLT => @as(i32, @bitCast(dst_val)) < @as(i32, @bitCast(src_val)),
            BPF_JSLE => @as(i32, @bitCast(dst_val)) <= @as(i32, @bitCast(src_val)),
            else => return VmError.InvalidInstruction,
        };

        if (should_jump) {
            const offset: i64 = insn.offset;
            const new_pc = @as(i64, @intCast(ctx.pc)) + offset;
            if (new_pc < 0) return VmError.InvalidInstruction;
            ctx.pc = @intCast(new_pc);
        }
    }

    fn executeCall(ctx: *VmContext, insn: BpfInstruction) VmError!void {
        const call_type = insn.src();

        if (call_type == 0) {
            // Syscall
            const syscall_id: u32 = @bitCast(insn.imm);
            const handler = ctx.syscalls.get(syscall_id) orelse return VmError.InvalidSyscall;

            ctx.registers[0] = try handler(
                ctx,
                ctx.registers[1],
                ctx.registers[2],
                ctx.registers[3],
                ctx.registers[4],
                ctx.registers[5],
            );
        } else if (call_type == 1) {
            // Local function call
            if (ctx.call_stack.items.len >= MAX_CALL_DEPTH) {
                return VmError.CallDepthExceeded;
            }

            try ctx.call_stack.append(ctx.pc);
            try ctx.frame_stack.append(ctx.registers[10]);

            // Adjust frame pointer for new frame
            ctx.registers[10] -= STACK_SIZE / MAX_CALL_DEPTH;

            // Jump to function
            const offset: i64 = insn.imm;
            const new_pc = @as(i64, @intCast(ctx.pc)) + offset;
            if (new_pc < 0) return VmError.InvalidInstruction;
            ctx.pc = @intCast(new_pc);
        } else {
            return VmError.InvalidInstruction;
        }
    }

    fn executeLdx(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const size = insn.opcode & 0x18;
        const addr = ctx.registers[src] +% @as(u64, @bitCast(@as(i64, insn.offset)));
        const ptr = @as([*]const u8, @ptrFromInt(addr));

        // Memory access validation would go here
        ctx.registers[dst] = switch (size) {
            BPF_B => ptr[0],
            BPF_H => std.mem.readInt(u16, ptr[0..2], .little),
            BPF_W => std.mem.readInt(u32, ptr[0..4], .little),
            BPF_DW => std.mem.readInt(u64, ptr[0..8], .little),
            else => return VmError.InvalidInstruction,
        };
    }

    fn executeStx(ctx: *VmContext, insn: BpfInstruction, dst: u4, src: u4) VmError!void {
        const size = insn.opcode & 0x18;
        const addr = ctx.registers[dst] +% @as(u64, @bitCast(@as(i64, insn.offset)));
        const ptr = @as([*]u8, @ptrFromInt(addr));
        const val = ctx.registers[src];

        switch (size) {
            BPF_B => ptr[0] = @truncate(val),
            BPF_H => std.mem.writeInt(u16, ptr[0..2], @truncate(val), .little),
            BPF_W => std.mem.writeInt(u32, ptr[0..4], @truncate(val), .little),
            BPF_DW => std.mem.writeInt(u64, ptr[0..8], val, .little),
            else => return VmError.InvalidInstruction,
        }
    }

    fn executeSt(ctx: *VmContext, insn: BpfInstruction, dst: u4) VmError!void {
        const size = insn.opcode & 0x18;
        const addr = ctx.registers[dst] +% @as(u64, @bitCast(@as(i64, insn.offset)));
        const ptr = @as([*]u8, @ptrFromInt(addr));
        const val: u64 = @bitCast(@as(i64, insn.imm));

        switch (size) {
            BPF_B => ptr[0] = @truncate(val),
            BPF_H => std.mem.writeInt(u16, ptr[0..2], @truncate(val), .little),
            BPF_W => std.mem.writeInt(u32, ptr[0..4], @truncate(val), .little),
            BPF_DW => std.mem.writeInt(u64, ptr[0..8], val, .little),
            else => return VmError.InvalidInstruction,
        }
    }

    fn executeLd(ctx: *VmContext, insn: BpfInstruction, dst: u4) VmError!void {
        const mode = insn.opcode & 0xe0;

        if (mode == 0x18) {
            // 64-bit immediate (lddw) - two instructions
            const low: u64 = @as(u64, @bitCast(@as(i64, insn.imm)));

            // Fetch next instruction for high 32 bits
            const next_offset = ctx.pc * 8;
            if (next_offset + 8 > ctx.bytecode.len) {
                return VmError.InvalidInstruction;
            }
            const next_bytes = ctx.bytecode[next_offset..][0..8];
            const next: BpfInstruction = @bitCast(next_bytes.*);

            const high: u64 = @as(u64, @bitCast(@as(i64, next.imm))) << 32;
            ctx.registers[dst] = low | high;
            ctx.pc += 1; // Skip the second instruction
        } else {
            return VmError.InvalidInstruction;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BpfVm: basic initialization" {
    const allocator = std.testing.allocator;
    const vm = BpfVm.init(allocator);
    _ = vm;
}

test "BpfVm: mov instruction" {
    const allocator = std.testing.allocator;

    // mov r0, 42
    // exit
    const bytecode = [_]u8{
        0xb7, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, // mov r0, 42
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // exit
    };

    var ctx = try VmContext.init(allocator, &bytecode, &[_]u8{}, 1024);
    defer ctx.deinit();

    var vm = BpfVm.init(allocator);
    const result = try vm.execute(&ctx);

    try std.testing.expectEqual(@as(u64, 42), result);
}

test "BpfVm: add instruction" {
    const allocator = std.testing.allocator;

    // mov r0, 10
    // add r0, 32
    // exit
    const bytecode = [_]u8{
        0xb7, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, // mov r0, 10
        0x07, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, // add r0, 32
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // exit
    };

    var ctx = try VmContext.init(allocator, &bytecode, &[_]u8{}, 1024);
    defer ctx.deinit();

    var vm = BpfVm.init(allocator);
    const result = try vm.execute(&ctx);

    try std.testing.expectEqual(@as(u64, 42), result);
}

