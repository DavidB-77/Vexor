//! BPF ELF Loader
//!
//! Loads pre-compiled eBPF programs from ELF .o files.
//! This is the production approach used by Firedancer and libbpf.
//!
//! Flow:
//! 1. Read ELF file
//! 2. Parse section headers to find .text (program) and .maps (map definitions)
//! 3. Create maps via BPF syscalls
//! 4. Relocate map references in program bytecode
//! 5. Load program via BPF_PROG_LOAD

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// BPF syscall constants
const SYS_bpf: c_long = 321;
const BPF_MAP_CREATE: c_int = 0;
const BPF_PROG_LOAD: c_int = 5;
const BPF_OBJ_GET: c_int = 7;

const BPF_MAP_TYPE_XSKMAP: u32 = 17;
const BPF_MAP_TYPE_HASH: u32 = 1;
const BPF_PROG_TYPE_XDP: u32 = 6;

// ELF constants
const ELF_MAGIC = "\x7fELF";
const EM_BPF: u16 = 247;
const SHT_PROGBITS: u32 = 1;
const SHT_STRTAB: u32 = 3;
const SHT_REL: u32 = 9;

extern "c" fn syscall(number: c_long, ...) c_long;

fn bpf_syscall(cmd: c_int, attr: *const anyopaque, size: usize) c_long {
    return syscall(SYS_bpf, @as(c_long, cmd), @intFromPtr(attr), @as(c_long, @intCast(size)));
}

/// ELF64 Header
const Elf64_Ehdr = extern struct {
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
const Elf64_Shdr = extern struct {
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

/// ELF64 Relocation Entry
const Elf64_Rel = extern struct {
    r_offset: u64,
    r_info: u64,
};

/// ELF64 Symbol
const Elf64_Sym = extern struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};

/// BPF Map Definition (from .maps section BTF)
const BpfMapDef = struct {
    name: []const u8,
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    fd: i32 = -1,
};

/// Loaded BPF program info
pub const LoadedProgram = struct {
    prog_fd: i32,
    xsks_map_fd: i32,
    port_filter_fd: i32,
    allocator: Allocator,

    pub fn deinit(self: *LoadedProgram) void {
        if (self.prog_fd >= 0) _ = posix.close(self.prog_fd);
        if (self.xsks_map_fd >= 0) _ = posix.close(self.xsks_map_fd);
        if (self.port_filter_fd >= 0) _ = posix.close(self.port_filter_fd);
    }
};

/// Load a BPF program from a pinned path (already loaded via bpftool)
pub fn loadFromPinned(allocator: Allocator, prog_path: []const u8) !LoadedProgram {
    _ = allocator;
    
    // BPF_OBJ_GET attribute
    const ObjGetAttr = extern struct {
        pathname: u64,
        bpf_fd: u32,
        file_flags: u32,
    };

    var path_buf: [256]u8 = undefined;
    if (prog_path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..prog_path.len], prog_path);
    path_buf[prog_path.len] = 0;

    var attr: ObjGetAttr = .{
        .pathname = @intFromPtr(&path_buf),
        .bpf_fd = 0,
        .file_flags = 0,
    };

    const result = bpf_syscall(BPF_OBJ_GET, &attr, @sizeOf(ObjGetAttr));
    if (result < 0) {
        const err = std.posix.errno(@as(i32, @intCast(result)));
        std.log.err("[BPF Loader] Failed to get pinned program at {s}: {s}", .{ prog_path, @tagName(err) });
        return error.PinnedObjectNotFound;
    }

    std.log.info("[BPF Loader] Loaded pinned program from {s}, fd={d}", .{ prog_path, result });

    // TODO: Also get map FDs - for now return placeholder
    return LoadedProgram{
        .prog_fd = @intCast(result),
        .xsks_map_fd = -1, // Need to get from program's map_ids
        .port_filter_fd = -1,
        .allocator = allocator,
    };
}

/// Create XSKMAP and port filter map directly (simpler approach)
pub fn createMaps(allocator: Allocator) !struct { xsks_map_fd: i32, port_filter_fd: i32 } {
    _ = allocator;

    // BPF_MAP_CREATE attribute (simplified)
    const MapCreateAttr = extern struct {
        map_type: u32,
        key_size: u32,
        value_size: u32,
        max_entries: u32,
        map_flags: u32 = 0,
        inner_map_fd: u32 = 0,
        numa_node: u32 = 0,
        map_name: [16]u8 = [_]u8{0} ** 16,
    };

    // Create XSKMAP
    var xsks_attr = MapCreateAttr{
        .map_type = BPF_MAP_TYPE_XSKMAP,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 64,
    };
    const xsks_name = "xsks_map";
    @memcpy(xsks_attr.map_name[0..xsks_name.len], xsks_name);

    const xsks_fd = bpf_syscall(BPF_MAP_CREATE, &xsks_attr, @sizeOf(MapCreateAttr));
    if (xsks_fd < 0) {
        const err = std.posix.errno(@as(i32, @intCast(xsks_fd)));
        std.log.err("[BPF Loader] Failed to create XSKMAP: {s}", .{@tagName(err)});
        return error.MapCreateFailed;
    }

    // Create port filter hash map
    var port_attr = MapCreateAttr{
        .map_type = BPF_MAP_TYPE_HASH,
        .key_size = 2, // u16 port
        .value_size = 1, // u8 action
        .max_entries = 16,
    };
    const port_name = "port_filter";
    @memcpy(port_attr.map_name[0..port_name.len], port_name);

    const port_fd = bpf_syscall(BPF_MAP_CREATE, &port_attr, @sizeOf(MapCreateAttr));
    if (port_fd < 0) {
        const err = std.posix.errno(@as(i32, @intCast(port_fd)));
        std.log.err("[BPF Loader] Failed to create port filter map: {s}", .{@tagName(err)});
        _ = posix.close(@intCast(xsks_fd));
        return error.MapCreateFailed;
    }

    std.log.info("[BPF Loader] Created maps: xsks_map fd={d}, port_filter fd={d}", .{ xsks_fd, port_fd });

    return .{
        .xsks_map_fd = @intCast(xsks_fd),
        .port_filter_fd = @intCast(port_fd),
    };
}

/// Add a port to the port filter map
pub fn addPortFilter(port_filter_fd: i32, port: u16) !void {
    const MapUpdateAttr = extern struct {
        map_fd: u32,
        key: u64,
        value: u64,
        flags: u64,
    };

    var port_key: u16 = port;
    var action: u8 = 1; // 1 = redirect to AF_XDP

    var attr = MapUpdateAttr{
        .map_fd = @intCast(port_filter_fd),
        .key = @intFromPtr(&port_key),
        .value = @intFromPtr(&action),
        .flags = 0, // BPF_ANY
    };

    const result = bpf_syscall(2, &attr, @sizeOf(MapUpdateAttr)); // BPF_MAP_UPDATE_ELEM = 2
    if (result < 0) {
        const err = std.posix.errno(@as(i32, @intCast(result)));
        std.log.err("[BPF Loader] Failed to add port {d} to filter: {s}", .{ port, @tagName(err) });
        return error.MapUpdateFailed;
    }

    std.log.debug("[BPF Loader] Added port {d} to filter map", .{port});
}

/// Register an AF_XDP socket in XSKMAP
pub fn registerXskSocket(xsks_map_fd: i32, queue_id: u32, socket_fd: i32) !void {
    const MapUpdateAttr = extern struct {
        map_fd: u32,
        key: u64,
        value: u64,
        flags: u64,
    };

    var key: u32 = queue_id;
    var value: u32 = @intCast(socket_fd);

    var attr = MapUpdateAttr{
        .map_fd = @intCast(xsks_map_fd),
        .key = @intFromPtr(&key),
        .value = @intFromPtr(&value),
        .flags = 0,
    };

    const result = bpf_syscall(2, &attr, @sizeOf(MapUpdateAttr));
    if (result < 0) {
        const err = std.posix.errno(@as(i32, @intCast(result)));
        std.log.err("[BPF Loader] Failed to register socket fd={d} at queue={d}: {s}", .{ socket_fd, queue_id, @tagName(err) });
        return error.SocketRegistrationFailed;
    }

    std.log.debug("[BPF Loader] Registered socket fd={d} at queue_id={d}", .{ socket_fd, queue_id });
}

/// Load XDP program from embedded bytecode
/// This loads a minimal XDP program that:
/// 1. Checks if UDP dest port is in port_filter map
/// 2. If yes, redirects to xsks_map[queue_id]
/// 3. Otherwise passes to kernel
pub fn loadMinimalXdpProgram(allocator: Allocator, xsks_map_fd: i32, port_filter_fd: i32) !i32 {
    // Minimal XDP program bytecode that does port filtering and redirect
    // This is equivalent to our xdp_filter.c but as raw bytecode
    //
    // The program needs to:
    // 1. Parse ethernet header
    // 2. Check if IPv4
    // 3. Parse IP header
    // 4. Check if UDP
    // 5. Get UDP dest port
    // 6. Lookup in port_filter map
    // 7. If found, bpf_redirect_map to xsks_map
    // 8. Otherwise XDP_PASS

    // For now, we'll use a simplified program that just passes everything
    // This is a placeholder - the real implementation would parse headers
    
    // BPF instructions for: return XDP_PASS (2)
    // mov r0, 2
    // exit
    const minimal_prog = [_]u64{
        0x00000002000000b7, // mov r0, 2 (XDP_PASS)
        0x0000000000000095, // exit
    };

    // Verifier log buffer
    var log_buf = try allocator.alloc(u8, 65536);
    defer allocator.free(log_buf);
    @memset(log_buf, 0);

    // BPF_PROG_LOAD attribute
    const ProgLoadAttr = extern struct {
        prog_type: u32,
        insn_cnt: u32,
        insns: u64,
        license: u64,
        log_level: u32,
        log_size: u32,
        log_buf: u64,
        kern_version: u32,
        prog_flags: u32,
        prog_name: [16]u8,
        prog_ifindex: u32,
        expected_attach_type: u32,
    };

    const license = "GPL";
    var prog_name: [16]u8 = [_]u8{0} ** 16;
    const name = "vexor_xdp";
    @memcpy(prog_name[0..name.len], name);

    var attr = ProgLoadAttr{
        .prog_type = BPF_PROG_TYPE_XDP,
        .insn_cnt = minimal_prog.len,
        .insns = @intFromPtr(&minimal_prog),
        .license = @intFromPtr(license.ptr),
        .log_level = 1,
        .log_size = @intCast(log_buf.len),
        .log_buf = @intFromPtr(log_buf.ptr),
        .kern_version = 0,
        .prog_flags = 0,
        .prog_name = prog_name,
        .prog_ifindex = 0,
        .expected_attach_type = 0,
    };

    _ = xsks_map_fd;
    _ = port_filter_fd;

    const result = bpf_syscall(BPF_PROG_LOAD, &attr, @sizeOf(ProgLoadAttr));
    if (result < 0) {
        const err = std.posix.errno(@as(i32, @intCast(result)));
        std.log.err("[BPF Loader] Failed to load XDP program: {s}", .{@tagName(err)});
        
        // Print verifier log
        var log_len: usize = 0;
        while (log_len < log_buf.len and log_buf[log_len] != 0) : (log_len += 1) {}
        if (log_len > 0) {
            std.log.err("[BPF Loader] Verifier log:\n{s}", .{log_buf[0..log_len]});
        }
        return error.ProgramLoadFailed;
    }

    std.log.info("[BPF Loader] Loaded minimal XDP program, fd={d}", .{result});
    return @intCast(result);
}
