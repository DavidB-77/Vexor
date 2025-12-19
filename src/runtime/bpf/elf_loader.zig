//! BPF ELF Loader
//! Parses ELF64 binaries containing eBPF bytecode for Solana programs.
//!
//! Solana programs are compiled to eBPF (extended Berkeley Packet Filter)
//! and stored as ELF64 files. This loader extracts the bytecode and
//! relocation information needed for execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// ELF64 Header
pub const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

/// ELF64 Section Header
pub const Elf64SectionHeader = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,
};

/// ELF64 Program Header
pub const Elf64ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

/// ELF64 Symbol
pub const Elf64Symbol = extern struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};

/// ELF64 Relocation with addend
pub const Elf64Rela = extern struct {
    r_offset: u64,
    r_info: u64,
    r_addend: i64,

    pub fn getSymbol(self: *const Elf64Rela) u32 {
        return @truncate(self.r_info >> 32);
    }

    pub fn getType(self: *const Elf64Rela) u32 {
        return @truncate(self.r_info & 0xffffffff);
    }
};

/// ELF magic bytes
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

/// ELF class (64-bit)
const ELFCLASS64: u8 = 2;

/// ELF data encoding (little endian)
const ELFDATA2LSB: u8 = 1;

/// ELF machine type for BPF
const EM_BPF: u16 = 247;

/// Section types
const SHT_NULL: u32 = 0;
const SHT_PROGBITS: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const SHT_STRTAB: u32 = 3;
const SHT_RELA: u32 = 4;
const SHT_NOBITS: u32 = 8;
const SHT_REL: u32 = 9;

/// Section flags
const SHF_WRITE: u64 = 0x1;
const SHF_ALLOC: u64 = 0x2;
const SHF_EXECINSTR: u64 = 0x4;

/// Program header types
const PT_LOAD: u32 = 1;

/// Loaded BPF program
pub const LoadedProgram = struct {
    /// Raw bytecode (BPF instructions)
    bytecode: []const u8,
    /// Read-only data section
    rodata: []const u8,
    /// Read-write data section
    data: []u8,
    /// BSS size (zero-initialized)
    bss_size: usize,
    /// Entry point offset
    entry_point: u64,
    /// Symbol table for syscall resolution
    symbols: std.StringHashMap(u64),
    /// Allocator used
    allocator: Allocator,

    pub fn deinit(self: *LoadedProgram) void {
        self.allocator.free(self.bytecode);
        if (self.rodata.len > 0) {
            self.allocator.free(self.rodata);
        }
        if (self.data.len > 0) {
            self.allocator.free(self.data);
        }
        self.symbols.deinit();
    }
};

/// ELF loading errors
pub const ElfError = error{
    InvalidMagic,
    InvalidClass,
    InvalidEncoding,
    InvalidMachine,
    InvalidVersion,
    NoTextSection,
    SectionOutOfBounds,
    InvalidSectionHeader,
    InvalidSymbol,
    RelocationFailed,
    OutOfMemory,
    InvalidElfData,
};

/// ELF Loader for BPF programs
pub const ElfLoader = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ElfLoader {
        return .{ .allocator = allocator };
    }

    /// Load a BPF program from ELF data
    pub fn load(self: *ElfLoader, elf_data: []const u8) ElfError!LoadedProgram {
        // Validate header
        if (elf_data.len < @sizeOf(Elf64Header)) {
            return ElfError.InvalidElfData;
        }

        const header: *const Elf64Header = @ptrCast(@alignCast(elf_data.ptr));

        // Check magic
        if (!std.mem.eql(u8, header.e_ident[0..4], &ELF_MAGIC)) {
            return ElfError.InvalidMagic;
        }

        // Check class (64-bit)
        if (header.e_ident[4] != ELFCLASS64) {
            return ElfError.InvalidClass;
        }

        // Check encoding (little endian)
        if (header.e_ident[5] != ELFDATA2LSB) {
            return ElfError.InvalidEncoding;
        }

        // Check machine type
        if (header.e_machine != EM_BPF) {
            return ElfError.InvalidMachine;
        }

        // Find sections
        var text_section: ?*const Elf64SectionHeader = null;
        var rodata_section: ?*const Elf64SectionHeader = null;
        var data_section: ?*const Elf64SectionHeader = null;
        var bss_section: ?*const Elf64SectionHeader = null;
        var symtab_section: ?*const Elf64SectionHeader = null;
        var strtab_section: ?*const Elf64SectionHeader = null;

        // Get section header string table
        const shstrtab_offset = self.getSectionOffset(elf_data, header, header.e_shstrndx) orelse
            return ElfError.InvalidSectionHeader;

        // Iterate sections
        var i: u16 = 0;
        while (i < header.e_shnum) : (i += 1) {
            const sh = self.getSectionHeader(elf_data, header, i) orelse continue;
            const name = self.getSectionName(elf_data, shstrtab_offset, sh.sh_name);

            if (std.mem.eql(u8, name, ".text")) {
                text_section = sh;
            } else if (std.mem.eql(u8, name, ".rodata")) {
                rodata_section = sh;
            } else if (std.mem.eql(u8, name, ".data")) {
                data_section = sh;
            } else if (std.mem.eql(u8, name, ".bss")) {
                bss_section = sh;
            } else if (sh.sh_type == SHT_SYMTAB) {
                symtab_section = sh;
            } else if (sh.sh_type == SHT_STRTAB and !std.mem.eql(u8, name, ".shstrtab")) {
                strtab_section = sh;
            }
        }

        // Text section is required
        const text = text_section orelse return ElfError.NoTextSection;

        // Copy bytecode
        const bytecode = self.allocator.alloc(u8, text.sh_size) catch
            return ElfError.OutOfMemory;
        errdefer self.allocator.free(bytecode);

        const text_start = text.sh_offset;
        const text_end = text_start + text.sh_size;
        if (text_end > elf_data.len) {
            return ElfError.SectionOutOfBounds;
        }
        @memcpy(bytecode, elf_data[text_start..text_end]);

        // Copy rodata
        var rodata: []const u8 = &[_]u8{};
        if (rodata_section) |ro| {
            const ro_data = self.allocator.alloc(u8, ro.sh_size) catch
                return ElfError.OutOfMemory;
            const ro_start = ro.sh_offset;
            const ro_end = ro_start + ro.sh_size;
            if (ro_end > elf_data.len) {
                return ElfError.SectionOutOfBounds;
            }
            @memcpy(ro_data, elf_data[ro_start..ro_end]);
            rodata = ro_data;
        }

        // Copy data
        var data: []u8 = &[_]u8{};
        if (data_section) |d| {
            const d_data = self.allocator.alloc(u8, d.sh_size) catch
                return ElfError.OutOfMemory;
            const d_start = d.sh_offset;
            const d_end = d_start + d.sh_size;
            if (d_end > elf_data.len) {
                return ElfError.SectionOutOfBounds;
            }
            @memcpy(d_data, elf_data[d_start..d_end]);
            data = d_data;
        }

        // BSS size
        const bss_size: usize = if (bss_section) |b| b.sh_size else 0;

        // Parse symbols
        var symbols = std.StringHashMap(u64).init(self.allocator);
        errdefer symbols.deinit();

        if (symtab_section != null and strtab_section != null) {
            const symtab = symtab_section.?;
            const strtab = strtab_section.?;

            const sym_count = symtab.sh_size / @sizeOf(Elf64Symbol);
            var sym_idx: usize = 0;
            while (sym_idx < sym_count) : (sym_idx += 1) {
                const sym_offset = symtab.sh_offset + sym_idx * @sizeOf(Elf64Symbol);
                if (sym_offset + @sizeOf(Elf64Symbol) > elf_data.len) break;

                const sym: *const Elf64Symbol = @ptrCast(@alignCast(elf_data.ptr + sym_offset));
                const sym_name = self.getStringFromTable(elf_data, strtab.sh_offset, sym.st_name);

                if (sym_name.len > 0 and sym.st_value != 0) {
                    const name_copy = self.allocator.dupe(u8, sym_name) catch continue;
                    symbols.put(name_copy, sym.st_value) catch {
                        self.allocator.free(name_copy);
                        continue;
                    };
                }
            }
        }

        return LoadedProgram{
            .bytecode = bytecode,
            .rodata = rodata,
            .data = data,
            .bss_size = bss_size,
            .entry_point = header.e_entry,
            .symbols = symbols,
            .allocator = self.allocator,
        };
    }

    fn getSectionHeader(self: *ElfLoader, elf_data: []const u8, header: *const Elf64Header, index: u16) ?*const Elf64SectionHeader {
        _ = self;
        const offset = header.e_shoff + @as(u64, index) * header.e_shentsize;
        if (offset + @sizeOf(Elf64SectionHeader) > elf_data.len) return null;
        return @ptrCast(@alignCast(elf_data.ptr + offset));
    }

    fn getSectionOffset(self: *ElfLoader, elf_data: []const u8, header: *const Elf64Header, index: u16) ?u64 {
        const sh = self.getSectionHeader(elf_data, header, index) orelse return null;
        return sh.sh_offset;
    }

    fn getSectionName(self: *ElfLoader, elf_data: []const u8, strtab_offset: u64, name_offset: u32) []const u8 {
        _ = self;
        return getStringFromTableStatic(elf_data, strtab_offset, name_offset);
    }

    fn getStringFromTable(self: *ElfLoader, elf_data: []const u8, strtab_offset: u64, name_offset: u32) []const u8 {
        _ = self;
        return getStringFromTableStatic(elf_data, strtab_offset, name_offset);
    }

    fn getStringFromTableStatic(elf_data: []const u8, strtab_offset: u64, name_offset: u32) []const u8 {
        const start = strtab_offset + name_offset;
        if (start >= elf_data.len) return "";

        var end = start;
        while (end < elf_data.len and elf_data[end] != 0) : (end += 1) {}

        return elf_data[start..end];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ElfLoader: basic initialization" {
    const allocator = std.testing.allocator;
    const loader = ElfLoader.init(allocator);
    _ = loader;
}

test "ElfLoader: reject invalid magic" {
    const allocator = std.testing.allocator;
    var loader = ElfLoader.init(allocator);

    const bad_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 60;
    const result = loader.load(&bad_data);
    try std.testing.expectError(ElfError.InvalidMagic, result);
}

test "ElfLoader: reject wrong class" {
    const allocator = std.testing.allocator;
    var loader = ElfLoader.init(allocator);

    // Valid magic but 32-bit class
    var bad_data = [_]u8{0} ** 64;
    bad_data[0] = 0x7f;
    bad_data[1] = 'E';
    bad_data[2] = 'L';
    bad_data[3] = 'F';
    bad_data[4] = 1; // ELFCLASS32

    const result = loader.load(&bad_data);
    try std.testing.expectError(ElfError.InvalidClass, result);
}

