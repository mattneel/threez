const std = @import("std");
const zgpu_build = @import("zgpu");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    const use_lld = target.result.os.tag == .windows;
    const strip_for_windows: ?bool = if (target.result.os.tag == .windows) true else null;

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
        .strip = strip_for_windows,
    });
    lib_mod.addImport("quickjs", qjs_mod);

    // --- Main artifact: executable on desktop, shared library on Android ---
    // QuickJS Value is an extern struct; the default backend cannot
    // lower its return type yet (Zig compiler TODO), so use LLVM.
    const exe = if (is_android) b.addLibrary(.{
        .name = "threez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
        .use_llvm = true,
        .use_lld = use_lld,
    }) else b.addExecutable(.{
        .name = "threez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_for_windows,
        }),
        .use_llvm = true,
        .use_lld = use_lld,
    });

    // Android NDK sysroot — Zig doesn't ship bionic headers, so we provide them.
    // Also add NDK library search path for system libs (libandroid, liblog, etc.).
    if (is_android) {
        const libc_conf = if (target.result.cpu.arch.isAARCH64())
            b.path("deps/android-sysroot/aarch64-libc.conf")
        else
            b.path("deps/android-sysroot/x86_64-libc.conf");
        exe.setLibCFile(libc_conf);

        const ndk_root = std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch
            @as([]const u8, "/home/autark/android/android-ndk-r27c");
        const arch_dir = if (target.result.cpu.arch.isAARCH64())
            "aarch64-linux-android"
        else
            "x86_64-linux-android";
        exe.addLibraryPath(.{ .cwd_relative = b.fmt(
            "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/{s}/26",
            .{ ndk_root, arch_dir },
        ) });

        // Vendor native_app_glue: compile C source and add include path
        exe.addIncludePath(b.path("deps/android-ndk"));
        exe.addCSourceFile(.{
            .file = b.path("deps/android-ndk/android_native_app_glue.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
    }

    // --- Dependencies ---

    // zglfw — GLFW windowing library (not available on Android)
    const zglfw_dep = if (!is_android) b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    if (zglfw_dep) |dep| {
        const zglfw_mod = dep.module("root");
        lib_mod.addImport("zglfw", zglfw_mod);
        exe.root_module.addImport("zglfw", zglfw_mod);
        exe.linkLibrary(dep.artifact("glfw"));
    }

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

    // --- Library artifact (static, for embedding — desktop only) ---
    const lib = if (!is_android) blk: {
        // QuickJS Value is an extern struct; use LLVM backend.
        const l = b.addLibrary(.{
            .name = "threez",
            .root_module = lib_mod,
            .linkage = .static,
            .use_llvm = true,
            .use_lld = use_lld,
        });
        l.linkLibrary(qjs_lib);
        l.linkLibrary(zglfw_dep.?.artifact("glfw"));
        break :blk l;
    } else null;

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

    // zig-clap (desktop only — CLI argument parsing)
    if (!is_android) {
        if (b.lazyDependency("clap", .{})) |clap_dep| {
            const clap_mod = clap_dep.module("clap");
            lib_mod.addImport("clap", clap_mod);
            exe.root_module.addImport("clap", clap_mod);
        }
    }

    // --- Install ---
    if (lib) |l| b.installArtifact(l);
    b.installArtifact(exe);

    // --- APK packaging (Android only) ---
    if (is_android) {
        const android_sdk_root = std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME") catch
            @as([]const u8, "/home/autark/android/sdk");
        const build_tools = b.fmt("{s}/build-tools/33.0.2", .{android_sdk_root});
        const platform_jar = b.fmt("{s}/platforms/android-33/android.jar", .{android_sdk_root});
        const abi_dir = if (target.result.cpu.arch.isAARCH64()) "arm64-v8a" else "x86_64";

        // Step 1: aapt2 link — compile manifest into base APK
        const aapt2_link = b.addSystemCommand(&.{
            b.fmt("{s}/aapt2", .{build_tools}),
            "link",
            "-o",
        });
        const base_apk = aapt2_link.addOutputFileArg("base.apk");
        aapt2_link.addArgs(&.{ "-I", platform_jar });
        aapt2_link.addArgs(&.{ "--manifest" });
        aapt2_link.addFileArg(b.path("AndroidManifest.xml"));
        aapt2_link.addArgs(&.{ "--min-sdk-version", "26", "--target-sdk-version", "33" });

        // Optional assets directory to bundle into the APK
        const assets_dir = b.option([]const u8, "assets", "Directory of assets to bundle in APK");

        // Step 2: assemble APK (inject .so, assets, zipalign, sign)
        const assemble = b.addSystemCommand(&.{"/bin/sh", "-c"});
        const so_path = exe.getEmittedBin();
        const apk_script = b.fmt(
            \\set -e
            \\WORK=$(mktemp -d)
            \\cp "$1" "$WORK/base.apk"
            \\mkdir -p "$WORK/lib/{s}"
            \\cp "$2" "$WORK/lib/{s}/libthreez.so"
            \\cd "$WORK" && zip -0 base.apk "lib/{s}/libthreez.so"
            \\if [ -n "$5" -a -d "$5" ]; then mkdir -p "$WORK/assets" && cp -r "$5"/. "$WORK/assets/" && cd "$WORK" && find assets -type f -exec zip -0 base.apk {{}} \; ; fi
            \\"{s}/zipalign" -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
            \\"{s}/apksigner" sign --ks "$3" --ks-pass pass:android --key-pass pass:android --out "$4" "$WORK/aligned.apk"
            \\rm -rf "$WORK"
        , .{ abi_dir, abi_dir, abi_dir, build_tools, build_tools });

        assemble.addArg(apk_script);
        assemble.addArg("--");
        assemble.addFileArg(base_apk);
        assemble.addFileArg(so_path);
        assemble.addFileArg(b.path("debug.keystore"));
        const signed_apk = assemble.addOutputFileArg("threez.apk");
        assemble.addArg(assets_dir orelse "");
        assemble.step.dependOn(&aapt2_link.step);

        const install_apk = b.addInstallFile(signed_apk, "threez.apk");

        const apk_step = b.step("apk", "Build signed Android APK");
        apk_step.dependOn(&install_apk.step);

        const adb_install = b.addSystemCommand(&.{ "adb", "install", "-r" });
        adb_install.addFileArg(signed_apk);
        adb_install.step.dependOn(&assemble.step);

        const adb_step = b.step("adb-install", "Install APK on connected device");
        adb_step.dependOn(&adb_install.step);
    }

    // --- Run step (desktop only) ---
    if (!is_android) {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the threez CLI");
        run_step.dependOn(&run_cmd.step);
    }

    // --- Embed API check (desktop only) ---
    if (!is_android) {
        const embed_check_mod = b.createModule(.{
            .root_source_file = b.path("examples/embed_api_check.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_for_windows,
        });
        embed_check_mod.addImport("threez", lib_mod);

        const embed_check_exe = b.addExecutable(.{
            .name = "threez-embed-check",
            .root_module = embed_check_mod,
            .use_llvm = true,
            .use_lld = use_lld,
        });
        embed_check_exe.linkLibrary(qjs_lib);
        embed_check_exe.linkLibrary(zglfw_dep.?.artifact("glfw"));
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
    }

    // --- Tests (desktop only — can't run Android tests on host) ---
    if (!is_android) {
        const zglfw_mod = zglfw_dep.?.module("root");
        const lib_unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip_for_windows,
                .imports = &.{
                    .{ .name = "quickjs", .module = qjs_mod },
                    .{ .name = "zgpu", .module = zgpu_mod },
                    .{ .name = "zglfw", .module = zglfw_mod },
                },
            }),
            .use_llvm = true,
            .use_lld = use_lld,
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
        lib_unit_tests.linkLibrary(zglfw_dep.?.artifact("glfw"));

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
                .strip = strip_for_windows,
                .imports = &.{
                    .{ .name = "quickjs", .module = qjs_mod },
                    .{ .name = "zgpu", .module = zgpu_mod },
                    .{ .name = "zglfw", .module = zglfw_mod },
                },
            }),
            .use_llvm = true,
            .use_lld = use_lld,
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
}
