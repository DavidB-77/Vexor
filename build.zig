//! Vexor Validator Client - Build Configuration
//! A high-performance, lightweight Solana validator client
//!
//! Build targets:
//!   zig build              - Build debug
//!   zig build -Doptimize=ReleaseFast - Build optimized
//!   zig build run          - Run the validator
//!   zig build test         - Run all tests
//!   zig build bench        - Run benchmarks
//!
//! Feature flags:
//!   -Dgpu=true             - Enable GPU acceleration (placeholder)
//!   -Daf_xdp=true          - Enable AF_XDP kernel bypass networking
//!   -Dramdisk=true         - Enable RAM disk tier-0 storage
//!   -Dalpenglow=true       - Enable Alpenglow consensus (experimental)
//!   -Dauto_optimize=true   - Enable auto-optimizer at startup
//!   -Dmasque=true          - Enable MASQUE protocol for QUIC proxying

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ══════════════════════════════════════════════════════════════════════
    // TARGET & OPTIMIZATION
    // ══════════════════════════════════════════════════════════════════════
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ══════════════════════════════════════════════════════════════════════
    // FEATURE FLAGS
    // ══════════════════════════════════════════════════════════════════════
    const gpu_enabled = b.option(bool, "gpu", "Enable GPU acceleration for signature verification") orelse false;
    const af_xdp_enabled = b.option(bool, "af_xdp", "Enable AF_XDP kernel bypass networking") orelse false;
    const ramdisk_enabled = b.option(bool, "ramdisk", "Enable RAM disk tier-0 storage") orelse true;
    const alpenglow_enabled = b.option(bool, "alpenglow", "Enable Alpenglow consensus (experimental)") orelse false;
    const auto_optimize_enabled = b.option(bool, "auto_optimize", "Enable auto-optimizer at startup") orelse true;
    const masque_enabled = b.option(bool, "masque", "Enable MASQUE protocol for QUIC proxying") orelse false;

    // ══════════════════════════════════════════════════════════════════════
    // BUILD OPTIONS (passed to source)
    // ══════════════════════════════════════════════════════════════════════
    const options = b.addOptions();
    options.addOption(bool, "gpu_enabled", gpu_enabled);
    options.addOption(bool, "af_xdp_enabled", af_xdp_enabled);
    options.addOption(bool, "ramdisk_enabled", ramdisk_enabled);
    options.addOption(bool, "alpenglow_enabled", alpenglow_enabled);
    options.addOption(bool, "auto_optimize_enabled", auto_optimize_enabled);
    options.addOption(bool, "masque_enabled", masque_enabled);

    // Version info
    options.addOption([]const u8, "version", "0.1.0-alpha");
    options.addOption([]const u8, "build_mode", @tagName(optimize));

    // ══════════════════════════════════════════════════════════════════════
    // MAIN EXECUTABLE
    // ══════════════════════════════════════════════════════════════════════
    const exe = b.addExecutable(.{
        .name = "vexor",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add build options module
    exe.root_module.addOptions("build_options", options);

    // Link system libraries based on features
    if (af_xdp_enabled) {
        // AF_XDP uses direct bpf() syscalls (Firedancer-style)
        // No external libraries needed - we use syscalls directly
        if (target.result.os.tag == .linux) {
            // No additional libraries needed - using direct syscalls
        }
    }

    if (gpu_enabled) {
        // GPU support - placeholder for CUDA/OpenCL linkage
        // Will be implemented when GPU module is built
        // exe.linkSystemLibrary("cuda");
    }

    // Link standard C library for system calls
    exe.linkLibC();

    // ══════════════════════════════════════════════════════════════════════
    // COMPILE eBPF XDP PROGRAM (if AF_XDP enabled)
    // ══════════════════════════════════════════════════════════════════════
    if (af_xdp_enabled and target.result.os.tag == .linux) {
        const bpf_obj_path = b.path("zig-out/bpf/xdp_filter.o");
        const bpf_c_file = b.path("src/network/af_xdp/bpf/xdp_filter.c");
        
        // Create output directory
        const bpf_dir_step = b.addSystemCommand(&.{"mkdir", "-p", "zig-out/bpf"});
        
        // Compile eBPF program using clang
        const bpf_compile_step = b.addSystemCommand(&.{
            "clang",
            "-O2",
            "-target", "bpf",
            "-c",
            bpf_c_file.getPath(b),
            "-o",
            bpf_obj_path.getPath(b),
            "-I", b.path("src/network/af_xdp/bpf").getPath(b),
        });
        bpf_compile_step.step.dependOn(&bpf_dir_step.step);
        exe.step.dependOn(&bpf_compile_step.step);
    }

    b.installArtifact(exe);

    // ══════════════════════════════════════════════════════════════════════
    // RUN COMMAND
    // ══════════════════════════════════════════════════════════════════════
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Vexor validator");
    run_step.dependOn(&run_cmd.step);

    // ══════════════════════════════════════════════════════════════════════
    // UNIT TESTS
    // ══════════════════════════════════════════════════════════════════════
    const test_step = b.step("test", "Run all unit tests");

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addOptions("build_options", options);
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // ══════════════════════════════════════════════════════════════════════
    // BENCHMARKS
    // ══════════════════════════════════════════════════════════════════════
    const bench_exe = b.addExecutable(.{
        .name = "vexor-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
    });
    bench_exe.root_module.addOptions("build_options", options);
    bench_exe.linkLibC();

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // ══════════════════════════════════════════════════════════════════════
    // AUTO-OPTIMIZER TOOL
    // ══════════════════════════════════════════════════════════════════════
    const optimizer_exe = b.addExecutable(.{
        .name = "vexor-optimize",
        .root_source_file = b.path("src/optimizer/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    optimizer_exe.root_module.addOptions("build_options", options);
    optimizer_exe.linkLibC();

    b.installArtifact(optimizer_exe);

    const optimize_cmd = b.addRunArtifact(optimizer_exe);
    const optimize_step = b.step("optimize", "Run system auto-optimizer");
    optimize_step.dependOn(&optimize_cmd.step);

    // ══════════════════════════════════════════════════════════════════════
    // CLIENT SWITCHER TOOL
    // ══════════════════════════════════════════════════════════════════════
    const switcher_exe = b.addExecutable(.{
        .name = "vexor-switch",
        .root_source_file = b.path("src/tools/client_switcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    switcher_exe.linkLibC();

    b.installArtifact(switcher_exe);

    const switch_cmd = b.addRunArtifact(switcher_exe);
    if (b.args) |args| {
        switch_cmd.addArgs(args);
    }
    const switch_step = b.step("switch", "Run client switcher tool");
    switch_step.dependOn(&switch_cmd.step);

    // ══════════════════════════════════════════════════════════════════════
    // INSTALLER TOOL
    // ══════════════════════════════════════════════════════════════════════
    const installer_exe = b.addExecutable(.{
        .name = "vexor-install",
        .root_source_file = b.path("src/tools/installer.zig"),
        .target = target,
        .optimize = optimize,
    });
    installer_exe.linkLibC();

    b.installArtifact(installer_exe);

    const install_cmd = b.addRunArtifact(installer_exe);
    if (b.args) |args| {
        install_cmd.addArgs(args);
    }
    const install_step = b.step("install-validator", "Run interactive installer");
    install_step.dependOn(&install_cmd.step);

    // ══════════════════════════════════════════════════════════════════════
    // DOCUMENTATION
    // ══════════════════════════════════════════════════════════════════════
    const docs = b.addStaticLibrary(.{
        .name = "vexor",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // ══════════════════════════════════════════════════════════════════════
    // CLEAN
    // ══════════════════════════════════════════════════════════════════════
    // Note: For cleaning, use: rm -rf zig-out .zig-cache
    // Or run: zig build --clean
}

