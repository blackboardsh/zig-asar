const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dynamic library (for native wrappers and Bun FFI)
    const lib = b.addLibrary(.{
        .name = "asar",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Leave room for LC_CODE_SIGNATURE in unsigned Intel release artifacts.
    if (target.result.os.tag == .macos and target.result.cpu.arch == .x86_64) {
        lib.headerpad_size = 0x1000;
    }
    // Zig 0.16's MachO linker exports ___dso_handle/__mh_dylib_header by
    // default, which breaks downstream Apple ld links against this dylib
    // (adrp_lo12 fixups can't target the external ___dso_handle). Export
    // only the C API.
    lib.root_module.export_symbol_names = &.{
        "asar_open",
        "asar_close",
        "asar_read_file",
        "asar_free_buffer",
        "asar_pack",
    };
    b.installArtifact(lib);

    // Static archive of the same module. macOS release artifacts re-link
    // this with Apple's clang (see release.yml): zig 0.16's MachO linker
    // exports ___dso_handle/__mh_dylib_header from dylibs, which breaks
    // downstream Apple-ld links against libasar.dylib.
    const static_lib = b.addLibrary(.{
        .name = "asar-static",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(static_lib);

    // CLI binary (statically linked to avoid dynamic library issues)
    const exe = b.addExecutable(.{
        .name = "zig-asar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Don't link the dynamic library - CLI uses its own code
    b.installArtifact(exe);

    // Tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}
