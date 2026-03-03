const std = @import("std");
const zgpu_build = @import("zgpu");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- quickjs-ng (vendored) ---
    const qjs_dep = b.dependency("zig-quickjs-ng", .{
        .target = target,
        .optimize = optimize,
    });
    const qjs_mod = qjs_dep.module("quickjs");
    const qjs_lib = qjs_dep.artifact("quickjs-ng");

    // --- Library module (for test aggregation) ---
    const lib_mod = b.addModule("threez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("quickjs", qjs_mod);

    // --- Executable ---
    // QuickJS Value is an extern struct; the default backend cannot
    // lower its return type yet (Zig compiler TODO), so use LLVM.
    const exe = b.addExecutable(.{
        .name = "threez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = false,
    });

    // --- Dependencies ---

    // zglfw — GLFW windowing library
    const zglfw_dep = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zglfw_mod = zglfw_dep.module("root");
    lib_mod.addImport("zglfw", zglfw_mod);
    exe.root_module.addImport("zglfw", zglfw_mod);
    exe.linkLibrary(zglfw_dep.artifact("glfw"));

    // zgpu — WebGPU via Dawn
    const zgpu_dep = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu_mod = zgpu_dep.module("root");
    lib_mod.addImport("zgpu", zgpu_mod);
    exe.root_module.addImport("zgpu", zgpu_mod);

    // quickjs — JavaScript engine (needed by main.zig for JS runtime)
    exe.root_module.addImport("quickjs", qjs_mod);
    exe.linkLibrary(qjs_lib);

    // --- Library artifact ---
    // QuickJS Value is an extern struct; use LLVM backend.
    const lib = b.addLibrary(.{
        .name = "threez",
        .root_module = lib_mod,
        .linkage = .static,
        .use_llvm = true,
        .use_lld = false,
    });
    lib.linkLibrary(qjs_lib);
    lib.linkLibrary(zglfw_dep.artifact("glfw"));

    // Dawn/WebGPU native linking:
    // zgpu's zdawn artifact compiles dawn.cpp + dawn_proc.c and links libdawn.
    // We cannot use linkLibrary(zdawn) directly because it creates a thin archive
    // that nests libdawn.a — Zig's linker can't handle nested archives.
    // Instead we add the C sources to our exe and link the prebuilt libdawn ourselves.
    exe.addIncludePath(zgpu_dep.path("libs/dawn/include"));
    exe.addIncludePath(zgpu_dep.path("src"));
    exe.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    exe.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    // Dawn prebuilt library search paths + link (per-platform)
    zgpu_build.addLibraryPathsTo(exe);
    zgpu_build.linkSystemDeps(b, exe);
    exe.linkSystemLibrary("dawn");
    exe.linkLibC();
    if (target.result.abi != .msvc)
        exe.linkLibCpp();

    // zignal
    if (b.lazyDependency("zignal", .{})) |zignal_dep| {
        const zignal_mod = zignal_dep.module("zignal");
        lib_mod.addImport("zignal", zignal_mod);
        exe.root_module.addImport("zignal", zignal_mod);
    }

    // zig-clap
    if (b.lazyDependency("clap", .{})) |clap_dep| {
        const clap_mod = clap_dep.module("clap");
        lib_mod.addImport("clap", clap_mod);
        exe.root_module.addImport("clap", clap_mod);
    }

    // --- Install ---
    b.installArtifact(lib);
    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the threez CLI");
    run_step.dependOn(&run_cmd.step);

    // --- Embed API check ---
    // Verifies the library can be imported by another Zig binary that embeds JS.
    const embed_check_mod = b.createModule(.{
        .root_source_file = b.path("examples/embed_api_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed_check_mod.addImport("threez", lib_mod);

    const embed_check_exe = b.addExecutable(.{
        .name = "threez-embed-check",
        .root_module = embed_check_mod,
        .use_llvm = true,
        .use_lld = false,
    });
    embed_check_exe.linkLibrary(qjs_lib);
    embed_check_exe.linkLibrary(zglfw_dep.artifact("glfw"));
    embed_check_exe.addIncludePath(zgpu_dep.path("libs/dawn/include"));
    embed_check_exe.addIncludePath(zgpu_dep.path("src"));
    embed_check_exe.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    embed_check_exe.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    zgpu_build.addLibraryPathsTo(embed_check_exe);
    zgpu_build.linkSystemDeps(b, embed_check_exe);
    embed_check_exe.linkSystemLibrary("dawn");
    embed_check_exe.linkLibC();
    if (target.result.abi != .msvc)
        embed_check_exe.linkLibCpp();

    const run_embed_check = b.addRunArtifact(embed_check_exe);
    const embed_check_step = b.step("embed-check", "Run @embedFile library API check");
    embed_check_step.dependOn(&run_embed_check.step);

    // --- Tests ---
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "quickjs", .module = qjs_mod },
                .{ .name = "zgpu", .module = zgpu_mod },
                .{ .name = "zglfw", .module = zglfw_mod },
            },
        }),
        // QuickJS Value is an extern struct; the default backend cannot
        // lower its return type yet (Zig compiler TODO), so use LLVM.
        .use_llvm = true,
        .use_lld = false,
    });
    lib_unit_tests.linkLibrary(qjs_lib);

    // Dawn/WebGPU native linking for tests (gpu_bridge.zig imports zgpu)
    lib_unit_tests.addIncludePath(zgpu_dep.path("libs/dawn/include"));
    lib_unit_tests.addIncludePath(zgpu_dep.path("src"));
    lib_unit_tests.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    lib_unit_tests.addCSourceFile(.{
        .file = zgpu_dep.path("src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    zgpu_build.addLibraryPathsTo(lib_unit_tests);
    zgpu_build.linkSystemDeps(b, lib_unit_tests);
    lib_unit_tests.linkSystemLibrary("dawn");
    lib_unit_tests.linkLibC();
    if (target.result.abi != .msvc)
        lib_unit_tests.linkLibCpp();
    lib_unit_tests.linkLibrary(zglfw_dep.artifact("glfw"));

    // Add lazy dependencies to the test module so tests can use them
    if (b.lazyDependency("zignal", .{})) |zignal_dep| {
        lib_unit_tests.root_module.addImport("zignal", zignal_dep.module("zignal"));
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // main.zig has no unit tests but must still compile during `zig build test`.
    // It imports quickjs, zglfw, zgpu, so we give the test module the same deps.
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "quickjs", .module = qjs_mod },
                .{ .name = "zgpu", .module = zgpu_mod },
                .{ .name = "zglfw", .module = zglfw_mod },
            },
        }),
        .use_llvm = true,
        .use_lld = false,
    });
    exe_unit_tests.linkLibrary(qjs_lib);

    // Add lazy dependencies to exe test module
    if (b.lazyDependency("clap", .{})) |clap_dep| {
        exe_unit_tests.root_module.addImport("clap", clap_dep.module("clap"));
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
