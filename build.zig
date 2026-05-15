const std = @import("std");

const DawnBuild = struct {
    step: *std.Build.Step,
    include_dir: []const u8,
    gen_include_dir: []const u8,
    out_dir: []const u8,
};

const WindowsSdkInfo = struct {
    path: []const u8,
    version: []const u8,
};

const WindowsHostToolchain = struct {
    clang: []const u8,
    clangxx: []const u8,
    llvm_ar: []const u8,
    zig_lib_dir: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    const use_lld = target.result.os.tag == .windows;
    const strip_for_windows: ?bool = if (target.result.os.tag == .windows) true else null;
    const android_ndk_root = if (is_android)
        std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch
            @as([]const u8, "/home/autark/android/android-ndk-r27c")
    else
        "";

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
        qjs_lib.setLibCFile(libc_conf);
        exe.setLibCFile(libc_conf);

        const arch_dir = if (target.result.cpu.arch.isAARCH64())
            "aarch64-linux-android"
        else
            "x86_64-linux-android";
        const ndk_sysroot_lib = b.fmt(
            "{s}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/{s}",
            .{ android_ndk_root, arch_dir },
        );
        exe.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/26", .{ndk_sysroot_lib}) });
        // Also add the base sysroot lib dir for the NDK C++ runtime.
        exe.addLibraryPath(.{ .cwd_relative = ndk_sysroot_lib });
        exe.linkSystemLibrary("c++_static");

        // Vendor native_app_glue: compile C source and add include path
        exe.addIncludePath(b.path("deps/android-ndk"));
        exe.addCSourceFile(.{
            .file = b.path("deps/android-ndk/android_native_app_glue.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });

        // Force ANativeActivity_onCreate into .dynsym so the Android runtime
        // can dlsym() it when launching the NativeActivity.
        exe.forceUndefinedSymbol("ANativeActivity_onCreate");
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

    // zgpu — Windowing (GLFW) and WebGPU type definitions only.
// Active WebGPU implementation uses source-built Dawn from build.zig.
    const zgpu_dep = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu_mod = zgpu_dep.module("root");
    lib_mod.addImport("zgpu", zgpu_mod);
    exe.root_module.addImport("zgpu", zgpu_mod);
    const dawn_mri_tool = addDawnMriTool(b);
    const dawn_prep_tool = addDawnPrepTool(b);
    const dawn = addNativeDawnBuild(b, target, dawn_mri_tool, dawn_prep_tool, android_ndk_root);

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
        addDawnHeaders(l, dawn);
        break :blk l;
    } else null;

    // Dawn/WebGPU native linking: all native targets use the source-built Dawn C API.
    if (is_android) {
        exe.addCSourceFile(.{
            .file = b.path("src/android_wgpu_shim.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
    }
    linkDawnConsumer(b, exe, target, dawn);

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
        const build_tools = b.fmt("{s}/build-tools/35.0.0", .{android_sdk_root});
        const platform_jar = b.fmt("{s}/platforms/android-35/android.jar", .{android_sdk_root});
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
        linkDawnConsumer(b, embed_check_exe, target, dawn);

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

        linkDawnConsumer(b, lib_unit_tests, target, dawn);
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
        linkDawnConsumer(b, exe_unit_tests, target, dawn);

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}

fn addDawnMriTool(b: *std.Build) *std.Build.Step.Compile {
    const wf = b.addWriteFiles();
    const src = wf.add("dawn-mri-tool.zig",
        \\const std = @import("std");
        \\
        \\fn collectArchives(
        \\    allocator: std.mem.Allocator,
        \\    build_dir: []const u8,
        \\    libs: *std.array_list.Managed([]const u8),
        \\) !void {
        \\    var dir = try std.fs.cwd().openDir(build_dir, .{ .iterate = true });
        \\    defer dir.close();
        \\    var walker = try dir.walk(allocator);
        \\    defer walker.deinit();
        \\    while (try walker.next()) |entry| {
        \\        if (entry.kind != .file) continue;
        \\        if (!std.mem.endsWith(u8, entry.path, ".a")) continue;
        \\        if (std.mem.endsWith(u8, entry.path, "libdawn_proc.a")) continue;
        \\        const full_path = try std.fs.path.join(allocator, &.{ build_dir, entry.path });
        \\        try libs.append(full_path);
        \\    }
        \\}
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    var args = try std.process.argsWithAllocator(allocator);
        \\    defer args.deinit();
        \\    _ = args.next();
        \\    const build_dir = args.next() orelse return error.InvalidArgs;
        \\    const out_lib = args.next() orelse return error.InvalidArgs;
        \\    const out_script = args.next() orelse return error.InvalidArgs;
        \\    if (args.next() != null) return error.InvalidArgs;
        \\
        \\    const cwd_real = try std.fs.cwd().realpathAlloc(allocator, ".");
        \\    defer allocator.free(cwd_real);
        \\    const build_dir_abs = try std.fs.path.resolve(allocator, &.{ cwd_real, build_dir });
        \\    defer allocator.free(build_dir_abs);
        \\    const out_lib_abs = try std.fs.path.resolve(allocator, &.{ cwd_real, out_lib });
        \\    defer allocator.free(out_lib_abs);
        \\
        \\    var libs = std.array_list.Managed([]const u8).init(allocator);
        \\    defer {
        \\        for (libs.items) |lib| allocator.free(lib);
        \\        libs.deinit();
        \\    }
        \\    try collectArchives(allocator, build_dir_abs, &libs);
        \\
        \\    var script = std.array_list.Managed(u8).init(allocator);
        \\    defer script.deinit();
        \\    try script.writer().print("create {s}\n", .{out_lib_abs});
        \\    for (libs.items) |lib| {
        \\        try script.writer().print("addlib {s}\n", .{lib});
        \\    }
        \\    try script.writer().writeAll("save\nend\n");
        \\
        \\    const script_dir = std.fs.path.dirname(out_script) orelse ".";
        \\    const lib_dir = std.fs.path.dirname(out_lib) orelse ".";
        \\    try std.fs.cwd().makePath(script_dir);
        \\    try std.fs.cwd().makePath(lib_dir);
        \\    var file = try std.fs.cwd().createFile(out_script, .{ .truncate = true });
        \\    defer file.close();
        \\    try file.writeAll(script.items);
        \\}
    );

    return b.addExecutable(.{
        .name = "dawn-mri-tool",
        .root_module = b.createModule(.{
            .root_source_file = src,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

fn addDawnPrepTool(b: *std.Build) *std.Build.Step.Compile {
    const wf = b.addWriteFiles();
    const src = wf.add("dawn-prep-tool.zig",
        \\const std = @import("std");
        \\
        \\fn pathExists(path: []const u8) bool {
        \\    std.fs.cwd().access(path, .{}) catch return false;
        \\    return true;
        \\}
        \\
        \\fn runChecked(allocator: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) !void {
        \\    const result = try std.process.Child.run(.{
        \\        .allocator = allocator,
        \\        .argv = argv,
        \\        .cwd = cwd,
        \\        .max_output_bytes = 1024 * 1024,
        \\    });
        \\    defer allocator.free(result.stdout);
        \\    defer allocator.free(result.stderr);
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code == 0) return,
        \\        else => {},
        \\    }
        \\
        \\    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
        \\    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        \\    return error.CommandFailed;
        \\}
        \\
        \\fn captureStdout(allocator: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
        \\    const result = try std.process.Child.run(.{
        \\        .allocator = allocator,
        \\        .argv = argv,
        \\        .cwd = cwd,
        \\        .max_output_bytes = 64 * 1024,
        \\    });
        \\    defer allocator.free(result.stderr);
        \\
        \\    switch (result.term) {
        \\        .Exited => |code| if (code == 0) return result.stdout,
        \\        else => {},
        \\    }
        \\
        \\    allocator.free(result.stdout);
        \\    return error.CommandFailed;
        \\}
        \\
        \\fn findPython(allocator: std.mem.Allocator) ![]const u8 {
        \\    const candidates = [_][]const u8{ "python3", "python" };
        \\    for (candidates) |candidate| {
        \\        const result = std.process.Child.run(.{
        \\            .allocator = allocator,
        \\            .argv = &.{ candidate, "--version" },
        \\            .max_output_bytes = 256,
        \\        }) catch continue;
        \\        defer allocator.free(result.stdout);
        \\        defer allocator.free(result.stderr);
        \\
        \\        switch (result.term) {
        \\            .Exited => |code| if (code == 0) return candidate,
        \\            else => {},
        \\        }
        \\    }
        \\    return error.PythonNotFound;
        \\}
        \\
        \\fn patchFile(
        \\    allocator: std.mem.Allocator,
        \\    path: []const u8,
        \\    needle: []const u8,
        \\    replacement: []const u8,
        \\) !void {
        \\    const cwd = std.fs.cwd();
        \\    const original = try cwd.readFileAlloc(allocator, path, 1024 * 1024);
        \\    defer allocator.free(original);
        \\
        \\    if (std.mem.indexOf(u8, original, replacement) != null) return;
        \\    if (std.mem.indexOf(u8, original, needle) == null) return error.ExpectedTextNotFound;
        \\
        \\    const patched = try std.mem.replaceOwned(u8, allocator, original, needle, replacement);
        \\    defer allocator.free(patched);
        \\
        \\    var file = try cwd.createFile(path, .{ .truncate = true });
        \\    defer file.close();
        \\    try file.writeAll(patched);
        \\}
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    const args = try std.process.argsAlloc(allocator);
        \\    defer std.process.argsFree(allocator, args);
        \\    if (args.len != 7) return error.InvalidArgs;
        \\
        \\    const cache_root = args[1];
        \\    const src_dir = args[2];
        \\    const stamp_dir = args[3];
        \\    const dawn_commit = args[4];
        \\    const prep_stamp = args[5];
        \\    const zig_lib_dir = args[6];
        \\    const cwd = std.fs.cwd();
        \\
        \\    try cwd.makePath(cache_root);
        \\    try cwd.makePath(stamp_dir);
        \\
        \\    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{src_dir});
        \\    defer allocator.free(git_dir);
        \\    if (!pathExists(git_dir)) {
        \\        cwd.deleteTree(src_dir) catch {};
        \\        try runChecked(allocator, null, &.{
        \\            "git",
        \\            "clone",
        \\            "--shallow-since=2023-06-28",
        \\            "https://dawn.googlesource.com/dawn",
        \\            src_dir,
        \\        });
        \\    }
        \\
        \\    const current_commit = captureStdout(allocator, null, &.{
        \\        "git",
        \\        "-C",
        \\        src_dir,
        \\        "rev-parse",
        \\        "--short=12",
        \\        "HEAD",
        \\    }) catch "";
        \\    defer if (current_commit.len != 0) allocator.free(current_commit);
        \\    if (!std.mem.eql(u8, std.mem.trim(u8, current_commit, "\r\n"), dawn_commit)) {
        \\        try runChecked(allocator, null, &.{
        \\            "git",
        \\            "-C",
        \\            src_dir,
        \\            "fetch",
        \\            "--shallow-since=2023-06-28",
        \\            "origin",
        \\        });
        \\        try runChecked(allocator, null, &.{
        \\            "git",
        \\            "-C",
        \\            src_dir,
        \\            "checkout",
        \\            "--force",
        \\            dawn_commit,
        \\        });
        \\    }
        \\
        \\    const d3d_error_h = try std.fmt.allocPrint(allocator, "{s}/src/dawn/native/d3d/D3DError.h", .{src_dir});
        \\    defer allocator.free(d3d_error_h);
        \\    try patchFile(
        \\        allocator,
        \\        d3d_error_h,
        \\        "#include <winerror.h>",
        \\        "#include <wtypesbase.h>\n#include <winerror.h>",
        \\    );
        \\
        \\    const backend_d3d12_cpp = try std.fmt.allocPrint(allocator, "{s}/src/dawn/native/d3d12/BackendD3D12.cpp", .{src_dir});
        \\    defer allocator.free(backend_d3d12_cpp);
        \\    try patchFile(
        \\        allocator,
        \\        backend_d3d12_cpp,
        \\        "    if (instance->IsBeginCaptureOnStartupEnabled()) {\n        ComPtr<IDXGraphicsAnalysis> graphicsAnalysis;\n        if (GetFunctions()->dxgiGetDebugInterface1 != nullptr &&\n            SUCCEEDED(GetFunctions()->dxgiGetDebugInterface1(0, IID_PPV_ARGS(&graphicsAnalysis)))) {\n            graphicsAnalysis->BeginCapture();\n        }\n    }\n",
        \\        "    if (instance->IsBeginCaptureOnStartupEnabled()) {\n#if !defined(__MINGW32__)\n        ComPtr<IDXGraphicsAnalysis> graphicsAnalysis;\n        if (GetFunctions()->dxgiGetDebugInterface1 != nullptr &&\n            SUCCEEDED(GetFunctions()->dxgiGetDebugInterface1(0, IID_PPV_ARGS(&graphicsAnalysis)))) {\n            graphicsAnalysis->BeginCapture();\n        }\n#endif\n    }\n",
        \\    );
        \\
        \\    const shared_buffer_memory_d3d12_cpp = try std.fmt.allocPrint(allocator, "{s}/src/dawn/native/d3d12/SharedBufferMemoryD3D12.cpp", .{src_dir});
        \\    defer allocator.free(shared_buffer_memory_d3d12_cpp);
        \\    try patchFile(
        \\        allocator,
        \\        shared_buffer_memory_d3d12_cpp,
        \\        "    ComPtr<ID3D12Device> resourceDevice;\n    d3d12Resource->GetDevice(__uuidof(resourceDevice), &resourceDevice);\n",
        \\        "    ComPtr<ID3D12Device> resourceDevice;\n    d3d12Resource->GetDevice(IID_PPV_ARGS(resourceDevice.GetAddressOf()));\n",
        \\    );
        \\
        \\    const shared_fence_d3d12_cpp = try std.fmt.allocPrint(allocator, "{s}/src/dawn/native/d3d12/SharedFenceD3D12.cpp", .{src_dir});
        \\    defer allocator.free(shared_fence_d3d12_cpp);
        \\    try patchFile(
        \\        allocator,
        \\        shared_fence_d3d12_cpp,
        \\        "    const auto& queueFence = ToBackend(device->GetQueue())->GetSharedFence();\n    if (queueFence &&\n        ::CompareObjectHandles(queueFence->GetSystemHandle().Get(), descriptor->handle)) {\n        return queueFence;\n    }\n",
        \\        "    const auto& queueFence = ToBackend(device->GetQueue())->GetSharedFence();\n#if defined(__MINGW32__)\n    if (queueFence && queueFence->GetSystemHandle().Get() == descriptor->handle) {\n        return queueFence;\n    }\n#else\n    if (queueFence &&\n        ::CompareObjectHandles(queueFence->GetSystemHandle().Get(), descriptor->handle)) {\n        return queueFence;\n    }\n#endif\n",
        \\    );
        \\
        \\    if (zig_lib_dir.len != 0) {
        \\        const compat_dir = try std.fmt.allocPrint(allocator, "{s}/build_overrides/windows-gnu", .{src_dir});
        \\        defer allocator.free(compat_dir);
        \\        try cwd.makePath(compat_dir);
        \\        const corecrt_h = try std.fmt.allocPrint(allocator, "{s}/corecrt.h", .{compat_dir});
        \\        defer allocator.free(corecrt_h);
        \\        const mingw_corecrt = try std.fmt.allocPrint(allocator, "{s}/libc/include/any-windows-any/corecrt.h", .{zig_lib_dir});
        \\        defer allocator.free(mingw_corecrt);
        \\        var corecrt_file = try cwd.createFile(corecrt_h, .{ .truncate = true });
        \\        defer corecrt_file.close();
        \\        const corecrt_prefix = try std.fmt.allocPrint(allocator, "#pragma once\n#include \"{s}\"\n", .{mingw_corecrt});
        \\        defer allocator.free(corecrt_prefix);
        \\        try corecrt_file.writeAll(corecrt_prefix);
        \\        try corecrt_file.writeAll(
        \\            "#ifndef _UCRT_DISABLED_WARNINGS\n#define _UCRT_DISABLED_WARNINGS\n#endif\n"
        \\            ++ "#ifndef _UCRT_DISABLE_CLANG_WARNINGS\n"
        \\            ++ "#ifdef __clang__\n"
        \\            ++ "#define _UCRT_DISABLE_CLANG_WARNINGS _Pragma(\"clang diagnostic push\") _Pragma(\"clang diagnostic ignored \\\"-Wdeprecated-declarations\\\"\") _Pragma(\"clang diagnostic ignored \\\"-Wignored-attributes\\\"\") _Pragma(\"clang diagnostic ignored \\\"-Wignored-pragma-optimize\\\"\") _Pragma(\"clang diagnostic ignored \\\"-Wunknown-pragmas\\\"\")\n"
        \\            ++ "#else\n#define _UCRT_DISABLE_CLANG_WARNINGS\n#endif\n#endif\n"
        \\            ++ "#ifndef _UCRT_RESTORE_CLANG_WARNINGS\n#ifdef __clang__\n#define _UCRT_RESTORE_CLANG_WARNINGS _Pragma(\"clang diagnostic pop\")\n#else\n#define _UCRT_RESTORE_CLANG_WARNINGS\n#endif\n#endif\n"
        \\            ++ "#ifndef _CRT_BEGIN_C_HEADER\n#ifdef __cplusplus\n#define _CRT_BEGIN_C_HEADER extern \"C\" {\n#define _CRT_END_C_HEADER }\n#else\n#define _CRT_BEGIN_C_HEADER\n#define _CRT_END_C_HEADER\n#endif\n#endif\n"
        \\            ++ "#ifndef _ACRTIMP\n#define _ACRTIMP\n#endif\n"
        \\            ++ "#ifndef _VCRTIMP\n#define _VCRTIMP\n#endif\n"
        \\            ++ "#ifndef _CRTIMP\n#define _CRTIMP\n#endif\n"
        \\            ++ "#ifndef _CRT_INSECURE_DEPRECATE\n#define _CRT_INSECURE_DEPRECATE(_Replacement)\n#endif\n"
        \\            ++ "#ifndef _CRT_INSECURE_DEPRECATE_MEMORY\n#define _CRT_INSECURE_DEPRECATE_MEMORY(_Replacement)\n#endif\n"
        \\            ++ "#ifndef _CRT_DEPRECATE_TEXT\n#define _CRT_DEPRECATE_TEXT(_Text)\n#endif\n"
        \\            ++ "#ifndef _CRT_MANAGED_FP_DEPRECATE\n#define _CRT_MANAGED_FP_DEPRECATE\n#endif\n"
        \\            ++ "#ifndef _NODISCARD\n#define _NODISCARD [[nodiscard]]\n#endif\n"
        \\            ++ "#ifndef _CONST_RETURN\n#define _CONST_RETURN\n#endif\n"
        \\            ++ "#ifndef _Check_return_\n#define _Check_return_\n#endif\n"
        \\            ++ "#ifndef _Check_return_opt_\n#define _Check_return_opt_\n#endif\n"
        \\            ++ "#ifndef _Check_return_wat_\n#define _Check_return_wat_\n#endif\n"
        \\            ++ "#ifndef _Success_\n#define _Success_(_Expr)\n#endif\n"
        \\            ++ "#ifndef _In_\n#define _In_\n#endif\n"
        \\            ++ "#ifndef _In_opt_\n#define _In_opt_\n#endif\n"
        \\            ++ "#ifndef _In_z_\n#define _In_z_\n#endif\n"
        \\            ++ "#ifndef _In_opt_z_\n#define _In_opt_z_\n#endif\n"
        \\            ++ "#ifndef _In_reads_\n#define _In_reads_(_Size)\n#endif\n"
        \\            ++ "#ifndef _In_reads_opt_\n#define _In_reads_opt_(_Size)\n#endif\n"
        \\            ++ "#ifndef _In_reads_bytes_\n#define _In_reads_bytes_(_Size)\n#endif\n"
        \\            ++ "#ifndef _In_reads_bytes_opt_\n#define _In_reads_bytes_opt_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_\n#define _Out_\n#endif\n"
        \\            ++ "#ifndef _Out_opt_\n#define _Out_opt_\n#endif\n"
        \\            ++ "#ifndef _Out_writes_\n#define _Out_writes_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_opt_\n#define _Out_writes_opt_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_bytes_\n#define _Out_writes_bytes_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_bytes_opt_\n#define _Out_writes_bytes_opt_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_bytes_all_\n#define _Out_writes_bytes_all_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_bytes_all_opt_\n#define _Out_writes_bytes_all_opt_(_Size)\n#endif\n"
        \\            ++ "#ifndef _Out_writes_bytes_to_opt_\n#define _Out_writes_bytes_to_opt_(_A,_B)\n#endif\n"
        \\            ++ "#ifndef _Ret_maybenull_\n#define _Ret_maybenull_\n#endif\n"
        \\            ++ "#ifndef _Ret_notnull_\n#define _Ret_notnull_\n#endif\n"
        \\            ++ "#ifndef _Ret_range_\n#define _Ret_range_(_A,_B)\n#endif\n"
        \\            ++ "#ifndef _Post_equal_to_\n#define _Post_equal_to_(_Value)\n#endif\n"
        \\            ++ "#ifndef _When_\n#define _When_(_Cond,_Ann)\n#endif\n"
        \\            ++ "#ifndef _At_buffer_\n#define _At_buffer_(_Buf,_Iter,_Size,_Ann)\n#endif\n"
        \\            ++ "#ifndef _Post_satisfies_\n#define _Post_satisfies_(_Expr)\n#endif\n"
        \\            ++ "#ifndef _String_length_\n#define _String_length_(_Str)\n#endif\n"
        \\            ++ "#ifndef _Iter_\n#define _Iter_\n#endif\n",
        \\        );
        \\        const float_h = try std.fmt.allocPrint(allocator, "{s}/float.h", .{compat_dir});
        \\        defer allocator.free(float_h);
        \\        const mingw_float = try std.fmt.allocPrint(allocator, "{s}/libc/include/any-windows-any/float.h", .{zig_lib_dir});
        \\        defer allocator.free(mingw_float);
        \\        var float_file = try cwd.createFile(float_h, .{ .truncate = true });
        \\        defer float_file.close();
        \\        const float_prefix = try std.fmt.allocPrint(allocator, "#pragma once\n#include \"corecrt.h\"\n#include \"{s}\"\n", .{mingw_float});
        \\        defer allocator.free(float_prefix);
        \\        try float_file.writeAll(float_prefix);
        \\        const vcruntime_string_h = try std.fmt.allocPrint(allocator, "{s}/vcruntime_string.h", .{compat_dir});
        \\        defer allocator.free(vcruntime_string_h);
        \\        var compat_file = try cwd.createFile(vcruntime_string_h, .{ .truncate = true });
        \\        defer compat_file.close();
        \\        try compat_file.writeAll("#pragma once\n#include <string.h>\n#include <wchar.h>\n");
        \\    }
        \\
        \\    if (!pathExists(prep_stamp)) {
        \\        const python = try findPython(allocator);
        \\        try runChecked(allocator, src_dir, &.{ python, "tools/fetch_dawn_dependencies.py", "--shallow" });
        \\        if (std.fs.path.dirname(prep_stamp)) |prep_dir| {
        \\            try cwd.makePath(prep_dir);
        \\        }
        \\        var stamp = try cwd.createFile(prep_stamp, .{ .truncate = true });
        \\        defer stamp.close();
        \\        try stamp.writeAll(dawn_commit);
        \\    }
        \\}
    );
    return b.addExecutable(.{
        .name = "dawn-prep-tool",
        .root_module = b.createModule(.{
            .root_source_file = src,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

fn addNativeDawnBuild(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    dawn_mri_tool: *std.Build.Step.Compile,
    dawn_prep_tool: *std.Build.Step.Compile,
    android_ndk_root: []const u8,
) DawnBuild {
    const dawn_commit = "03e999815027";
    const use_host_toolchain = shouldUseHostDawnToolchain(b, target);
    const dawn_build_flavor = if (target.result.os.tag == .linux and target.result.abi == .android)
        "android-ndk"
    else if (use_host_toolchain)
        "hostcc"
    else
        "zigcc";
    const cache_root = ".zig-cache/dawn";
    const project_root = std.fs.cwd().realpathAlloc(b.allocator, ".") catch @panic("failed to resolve project root");
    const target_key = dawnTargetKey(b, target);
    const src_dir = b.fmt("{s}/src-{s}", .{ cache_root, dawn_commit });
    const include_dir = b.fmt("{s}/include", .{src_dir});
    const stamp_dir = b.fmt("{s}/stamps", .{cache_root});
    const build_dir = b.fmt("{s}/build-{s}-{s}-{s}", .{ cache_root, dawn_commit, dawn_build_flavor, target_key });
    const out_dir = b.fmt("{s}/out/{s}-{s}", .{ cache_root, dawn_build_flavor, target_key });
    const out_lib = b.fmt("{s}/libdawn.a", .{out_dir});
    const out_lib_abs = b.fmt("{s}/{s}", .{ project_root, out_lib });
    const gen_include_dir = b.fmt("{s}/gen/include", .{build_dir});
    const prep_stamp = b.fmt("{s}/fetched-{s}", .{ stamp_dir, dawn_commit });
    const windows_host_toolchain = if (target.result.os.tag == .windows and use_host_toolchain)
        detectWindowsHostToolchain(b) orelse @panic("missing Windows host Dawn toolchain: install VS Build Tools LLVM")
    else
        null;
    const prepare = b.addRunArtifact(dawn_prep_tool);
    prepare.addArgs(&.{ cache_root, src_dir, stamp_dir, dawn_commit, prep_stamp, if (windows_host_toolchain) |toolchain| windowsPathForCMake(b, toolchain.zig_lib_dir) else "" });
    prepare.has_side_effects = true;

    const jobs = std.Thread.getCpuCount() catch 8;
    var cmake_args = std.array_list.Managed([]const u8).init(b.allocator);
    const windows_sdk = if (target.result.os.tag == .windows and b.graph.host.result.os.tag == .windows)
        detectWindowsSdkInfo(b)
    else
        null;
    const cmake_build_type = if (target.result.os.tag == .windows)
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
    else
        "-DCMAKE_BUILD_TYPE=Release";
    cmake_args.appendSlice(&.{
        "cmake",
        "-S",
        src_dir,
        "-B",
        build_dir,
        cmake_build_type,
        "-DCMAKE_CXX_FLAGS=-Wno-switch-default -Wno-unsafe-buffer-usage",
        "-DDAWN_SUPPORTS_GLFW_FOR_WINDOWING=OFF",
        "-DDAWN_USE_GLFW=OFF",
        "-DDAWN_BUILD_SAMPLES=OFF",
        "-DDAWN_BUILD_TESTS=OFF",
        "-DTINT_BUILD_TESTS=OFF",
        "-DTINT_BUILD_CMD_TOOLS=OFF",
        "-DTINT_BUILD_GLSL_WRITER=OFF",
        "-DTINT_BUILD_HLSL_WRITER=OFF",
        "-DTINT_BUILD_MSL_WRITER=OFF",
        "-DTINT_BUILD_BENCHMARKS=OFF",
        "-DDAWN_BUILD_BENCHMARKS=OFF",
        "-DDAWN_ENABLE_NULL=OFF",
        "-DDAWN_ENABLE_DESKTOP_GL=OFF",
        "-DDAWN_ENABLE_OPENGLES=OFF",
        "-G",
        "Ninja",
    }) catch @panic("OOM");

    if (target.result.os.tag == .linux and target.result.abi == .android) {
        cmake_args.appendSlice(&.{
            b.fmt("-DCMAKE_TOOLCHAIN_FILE={s}/build/cmake/android.toolchain.cmake", .{android_ndk_root}),
            b.fmt("-DANDROID_ABI={s}", .{if (target.result.cpu.arch.isAARCH64()) "arm64-v8a" else "x86_64"}),
            "-DANDROID_PLATFORM=android-26",
        }) catch @panic("OOM");
    } else if (windows_host_toolchain) |toolchain| {
        cmake_args.appendSlice(&.{
            b.fmt("-DCMAKE_C_COMPILER={s}", .{windowsPathForCMake(b, toolchain.clang)}),
            b.fmt("-DCMAKE_CXX_COMPILER={s}", .{windowsPathForCMake(b, toolchain.clangxx)}),
            b.fmt("-DCMAKE_AR={s}", .{windowsPathForCMake(b, toolchain.llvm_ar)}),
            "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
            b.fmt("-DCMAKE_C_COMPILER_TARGET={s}", .{windowsClangTarget(target)}),
            b.fmt("-DCMAKE_CXX_COMPILER_TARGET={s}", .{windowsClangTarget(target)}),
        }) catch @panic("OOM");
    } else if (use_host_toolchain) {
        cmake_args.appendSlice(&.{
            "-DCMAKE_C_COMPILER=cc",
            "-DCMAKE_CXX_COMPILER=c++",
        }) catch @panic("OOM");
    } else {
        cmake_args.appendSlice(&.{
            b.fmt("-DCMAKE_C_COMPILER={s}", .{b.graph.zig_exe}),
            b.fmt("-DCMAKE_CXX_COMPILER={s}", .{b.graph.zig_exe}),
            "-DCMAKE_C_COMPILER_ARG1=cc",
            "-DCMAKE_CXX_COMPILER_ARG1=c++",
            b.fmt("-DCMAKE_C_COMPILER_TARGET={s}", .{target_key}),
            b.fmt("-DCMAKE_CXX_COMPILER_TARGET={s}", .{target_key}),
        }) catch @panic("OOM");
    }

    if (target.result.os.tag == .linux and target.result.abi == .android) {
        cmake_args.appendSlice(&.{
            "-DDAWN_ENABLE_VULKAN=ON",
            "-DDAWN_ENABLE_D3D11=OFF",
            "-DDAWN_ENABLE_D3D12=OFF",
            "-DDAWN_ENABLE_METAL=OFF",
            "-DDAWN_USE_X11=OFF",
            "-DDAWN_USE_WAYLAND=OFF",
        }) catch @panic("OOM");
    } else switch (target.result.os.tag) {
        .linux => blk: {
            requireLinuxDawnDeps();
            cmake_args.appendSlice(&.{
                "-DDAWN_ENABLE_VULKAN=ON",
                "-DDAWN_ENABLE_D3D11=OFF",
                "-DDAWN_ENABLE_D3D12=OFF",
                "-DDAWN_ENABLE_METAL=OFF",
                "-DDAWN_USE_X11=ON",
                "-DDAWN_USE_WAYLAND=OFF",
                "-DCMAKE_INCLUDE_PATH=/usr/include",
                b.fmt("-DCMAKE_LIBRARY_PATH={s};/lib/{s}", .{
                    linuxSystemLibDir(target),
                    linuxSystemLibTriplet(target),
                }),
            }) catch @panic("OOM");
            break :blk;
        },
        .windows => cmake_args.appendSlice(&.{
            "-DCMAKE_SYSTEM_NAME=Windows",
            b.fmt("-DCMAKE_SYSTEM_VERSION={s}", .{if (windows_sdk) |sdk| sdk.version else "10"}),
            b.fmt("-DCMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION={s}", .{if (windows_sdk) |sdk| sdk.version else "10"}),
            b.fmt("-DCMAKE_SYSTEM_PROCESSOR={s}", .{if (target.result.cpu.arch.isX86()) "x86_64" else "aarch64"}),
            "-DWIN32=TRUE",
            "-DUNIX=FALSE",
            "-DAPPLE=FALSE",
            "-DDAWN_ENABLE_VULKAN=OFF",
            "-DDAWN_ENABLE_D3D11=OFF",
            "-DDAWN_ENABLE_D3D12=ON",
            "-DTINT_BUILD_HLSL_WRITER=ON",
            "-DDAWN_ENABLE_METAL=OFF",
            "-DDAWN_FORCE_SYSTEM_COMPONENT_LOAD=ON",
            "-DDAWN_USE_WINDOWS_UI=OFF",
            "-DDAWN_USE_X11=OFF",
            "-DDAWN_USE_WAYLAND=OFF",
        }) catch @panic("OOM"),
        .macos => cmake_args.appendSlice(&.{
            "-DDAWN_ENABLE_VULKAN=OFF",
            "-DDAWN_ENABLE_D3D11=OFF",
            "-DDAWN_ENABLE_D3D12=OFF",
            "-DDAWN_ENABLE_METAL=ON",
            "-DDAWN_USE_X11=OFF",
            "-DDAWN_USE_WAYLAND=OFF",
        }) catch @panic("OOM"),
        else => @panic("unsupported Dawn target"),
    }

    if (windows_sdk) |sdk| {
        const sdk_root = windowsPathForCMake(b, sdk.path);
        const compat_include_flags = if (windows_host_toolchain != null)
            b.fmt("-isystem \"{s}\"", .{windowsPathForCMake(b, b.fmt("{s}/{s}/build_overrides/windows-gnu", .{ project_root, src_dir }))})
        else
            "";
        const after_include_flags = b.fmt("-isystem \"{s}/Include/{s}/ucrt\" -isystem \"{s}/Include/{s}/shared\" -isystem \"{s}/Include/{s}/um\"", .{
            sdk_root, sdk.version,
            sdk_root, sdk.version,
            sdk_root, sdk.version,
        });
        const lib_arch = if (target.result.cpu.arch.isX86()) "x64" else "arm64";
        const library_dirs = b.fmt("{s}/Lib/{s}/ucrt/{s};{s}/Lib/{s}/um/{s}", .{
            sdk_root, sdk.version, lib_arch,
            sdk_root, sdk.version, lib_arch,
        });
        const c_flags = if (windows_host_toolchain) |toolchain|
            b.fmt("{s} {s} {s}", .{ windowsZigCFlags(b, target, toolchain), compat_include_flags, after_include_flags })
        else
            after_include_flags;
        const cxx_flags = if (windows_host_toolchain) |toolchain|
            b.fmt("-Wno-switch-default -Wno-unsafe-buffer-usage {s} {s} {s}", .{ windowsZigCxxFlags(b, target, toolchain), compat_include_flags, after_include_flags })
        else
            b.fmt("-Wno-switch-default -Wno-unsafe-buffer-usage {s}", .{after_include_flags});
        cmake_args.appendSlice(&.{
            b.fmt("-DCMAKE_C_FLAGS={s}", .{c_flags}),
            b.fmt("-DCMAKE_CXX_FLAGS={s}", .{cxx_flags}),
            b.fmt("-DCMAKE_LIBRARY_PATH={s}", .{library_dirs}),
        }) catch @panic("OOM");
    }

    const configure = b.addSystemCommand(cmake_args.items);
    if (windows_sdk) |sdk| {
        configure.setEnvironmentVariable("WINDOWSSDKDIR", sdk.path);
        configure.setEnvironmentVariable("WINDOWSSDKVERSION", sdk.version);
    }
    configure.has_side_effects = true;
    configure.step.dependOn(&prepare.step);

    const build_dawn = b.addSystemCommand(&.{
        "cmake",
        "--build",
        build_dir,
        "--parallel",
        b.fmt("{d}", .{jobs}),
        "--target",
        "dawn_native",
        "dawn_proc",
        "dawn_platform",
        "dawn_wire",
        "webgpu_dawn",
    });
    if (windows_sdk) |sdk| {
        build_dawn.setEnvironmentVariable("WINDOWSSDKDIR", sdk.path);
        build_dawn.setEnvironmentVariable("WINDOWSSDKVERSION", sdk.version);
    }
    build_dawn.has_side_effects = true;
    build_dawn.step.dependOn(&configure.step);

    const mri = b.addRunArtifact(dawn_mri_tool);
    mri.addArgs(&.{ build_dir, out_lib });
    const mri_script = mri.addOutputFileArg("merge.mri");
    mri.step.dependOn(&build_dawn.step);

    const ar_cmd = if (target.result.os.tag == .linux and target.result.abi == .android)
        b.fmt("{s}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar", .{android_ndk_root})
    else if (windows_host_toolchain) |toolchain|
        toolchain.llvm_ar
    else
        "llvm-ar";

    const merge = b.addSystemCommand(&.{ ar_cmd, "-M" });
    merge.setStdIn(.{ .lazy_path = mri_script });
    merge.has_side_effects = true;
    merge.step.dependOn(&mri.step);

    const index = b.addSystemCommand(&.{ ar_cmd, "s", out_lib_abs });
    index.has_side_effects = true;
    index.step.dependOn(&merge.step);

    return .{
        .step = &index.step,
        .include_dir = include_dir,
        .gen_include_dir = gen_include_dir,
        .out_dir = out_dir,
    };
}

fn addDawnHeaders(step: *std.Build.Step.Compile, dawn: DawnBuild) void {
    step.step.dependOn(dawn.step);
    step.addIncludePath(.{ .cwd_relative = dawn.include_dir });
    step.addIncludePath(.{ .cwd_relative = dawn.gen_include_dir });
}

fn linkDawnConsumer(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    dawn: DawnBuild,
) void {
    addDawnHeaders(step, dawn);
    step.addLibraryPath(.{ .cwd_relative = dawn.out_dir });
    linkDawnSystemDeps(b, step);
    step.linkSystemLibrary("dawn");
    step.linkLibC();
    if (target.result.os.tag == .linux and target.result.abi != .android) {
        step.addObjectFile(.{ .cwd_relative = hostCompilerRuntimePath(b, "libstdc++.so") });
        step.addObjectFile(.{ .cwd_relative = hostCompilerRuntimePath(b, "libgcc_s.so.1") });
        step.linkSystemLibrary("pthread");
        step.linkSystemLibrary("m");
        step.linkSystemLibrary("dl");
    } else {
        linkHostCppRuntime(step, target);
    }
}

fn linkDawnSystemDeps(b: *std.Build, step: *std.Build.Step.Compile) void {
    switch (step.rootModuleTarget().os.tag) {
        .windows => {
            if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
                step.addLibraryPath(system_sdk.path("windows/lib/x86_64-windows-gnu"));
            }
            step.linkSystemLibrary("ole32");
            step.linkSystemLibrary("dxguid");
        },
        .macos => {
            if (b.lazyDependency("system_sdk", .{})) |system_sdk| {
                step.addLibraryPath(system_sdk.path("macos12/usr/lib"));
                step.addFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
            }
            step.linkSystemLibrary("objc");
            step.linkFramework("Metal");
            step.linkFramework("CoreGraphics");
            step.linkFramework("Foundation");
            step.linkFramework("IOKit");
            step.linkFramework("IOSurface");
            step.linkFramework("QuartzCore");
        },
        .linux => {
            if (step.rootModuleTarget().abi == .android) {
                step.linkSystemLibrary("android");
                step.linkSystemLibrary("log");
            }
        },
        else => {},
    }
}

fn requireLinuxDawnDeps() void {
    std.fs.accessAbsolute("/usr/include/X11/Xlib-xcb.h", .{}) catch {
        @panic("missing Linux Dawn dependency: install libx11-xcb-dev");
    };
}

fn detectWindowsSdkInfo(b: *std.Build) ?WindowsSdkInfo {
    const sdk_path = std.process.getEnvVarOwned(b.allocator, "WINDOWSSDKDIR") catch blk: {
        const fallbacks = [_][]const u8{
            "C:\\Program Files (x86)\\Windows Kits\\10",
            "C:\\Program Files\\Windows Kits\\10",
        };
        for (fallbacks) |candidate| {
            std.fs.accessAbsolute(candidate, .{}) catch continue;
            break :blk candidate;
        }
        return null;
    };
    const include_dir = b.fmt("{s}\\Include", .{sdk_path});
    var dir = std.fs.openDirAbsolute(include_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    var best: ?[]const u8 = null;
    while (iter.next() catch return null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "10.")) continue;
        if (best == null or compareWindowsSdkVersions(entry.name, best.?) == .gt) {
            best = b.dupe(entry.name);
        }
    }

    return if (best) |version| .{
        .path = sdk_path,
        .version = version,
    } else null;
}

fn compareWindowsSdkVersions(a: []const u8, b: []const u8) std.math.Order {
    var a_iter = std.mem.splitScalar(u8, a, '.');
    var b_iter = std.mem.splitScalar(u8, b, '.');

    while (true) {
        const a_part = a_iter.next();
        const b_part = b_iter.next();
        if (a_part == null and b_part == null) return .eq;

        const a_value = if (a_part) |part|
            std.fmt.parseInt(u32, part, 10) catch 0
        else
            0;
        const b_value = if (b_part) |part|
            std.fmt.parseInt(u32, part, 10) catch 0
        else
            0;

        if (a_value < b_value) return .lt;
        if (a_value > b_value) return .gt;
    }
}

fn windowsPathForCMake(b: *std.Build, path: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, path, "\\", "/") catch @panic("OOM");
}

fn shouldUseHostDawnToolchain(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    if (target.result.os.tag != host.os.tag) return false;
    if (target.result.cpu.arch != host.cpu.arch) return false;
    if (target.result.abi != host.abi) return false;
    return switch (target.result.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

fn detectWindowsHostToolchain(b: *std.Build) ?WindowsHostToolchain {
    const zig_exe_dir = std.fs.path.dirname(b.graph.zig_exe) orelse return null;
    const zig_lib_dir = b.pathJoin(&.{ zig_exe_dir, "lib" });
    const candidates = [_][]const u8{
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin",
        "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin",
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\Community\\VC\\Tools\\Llvm\\x64\\bin",
        "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Tools\\Llvm\\x64\\bin",
    };
    for (candidates) |root| {
        const clang = b.pathJoin(&.{ root, "clang.exe" });
        const clangxx = b.pathJoin(&.{ root, "clang++.exe" });
        const llvm_ar = b.pathJoin(&.{ root, "llvm-ar.exe" });
        std.fs.accessAbsolute(clang, .{}) catch continue;
        std.fs.accessAbsolute(clangxx, .{}) catch continue;
        std.fs.accessAbsolute(llvm_ar, .{}) catch continue;
        return .{
            .clang = clang,
            .clangxx = clangxx,
            .llvm_ar = llvm_ar,
            .zig_lib_dir = zig_lib_dir,
        };
    }
    return null;
}

fn windowsClangTarget(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-w64-windows-gnu",
        .aarch64 => "aarch64-w64-windows-gnu",
        else => @panic("unsupported Windows Dawn arch"),
    };
}

fn windowsZigCFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    toolchain: WindowsHostToolchain,
) []const u8 {
    const zig_root = windowsPathForCMake(b, toolchain.zig_lib_dir);
    const target_dir = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-windows-gnu",
        .aarch64 => "aarch64-windows-gnu",
        else => @panic("unsupported Windows Dawn arch"),
    };
    const arch_dir = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-windows-any",
        .aarch64 => "aarch64-windows-any",
        else => @panic("unsupported Windows Dawn arch"),
    };
    return b.fmt("-isystem \"{s}/libc/include/{s}\" -isystem \"{s}/libc/include/generic-mingw\" -isystem \"{s}/libc/include/{s}\" -isystem \"{s}/libc/include/any-windows-any\" -D __MSVCRT_VERSION__=0xE00 -D _WIN32_WINNT=0x0a00", .{
        zig_root,
        target_dir,
        zig_root,
        zig_root,
        arch_dir,
        zig_root,
    });
}

fn windowsZigCxxFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    toolchain: WindowsHostToolchain,
) []const u8 {
    const zig_root = windowsPathForCMake(b, toolchain.zig_lib_dir);
    return b.fmt("-nostdinc++ -isystem \"{s}/libcxx/include\" -isystem \"{s}/libcxxabi/include\" -isystem \"{s}/libunwind/include\" {s} -D _LIBCPP_ABI_VERSION=1 -D _LIBCPP_ABI_NAMESPACE=__1 -D _LIBCPP_HAS_THREADS=1 -D _LIBCPP_HAS_MONOTONIC_CLOCK -D _LIBCPP_HAS_TERMINAL -D _LIBCPP_HAS_MUSL_LIBC=0 -D _LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS -D _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -D _LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=0 -D _LIBCPP_HAS_FILESYSTEM=1 -D _LIBCPP_HAS_RANDOM_DEVICE -D _LIBCPP_HAS_LOCALIZATION -D _LIBCPP_HAS_UNICODE -D _LIBCPP_HAS_WIDE_CHARACTERS -D _LIBCPP_HAS_NO_STD_MODULES -D _LIBCPP_PSTL_BACKEND_SERIAL -D _LIBCPP_HARDENING_MODE_DEFAULT=_LIBCPP_HARDENING_MODE_NONE -D _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE -D _LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS", .{
        zig_root,
        zig_root,
        zig_root,
        windowsZigCFlags(b, target, toolchain),
    });
}

fn hostCompilerRuntimePath(b: *std.Build, comptime file_name: []const u8) []const u8 {
    const arg = b.fmt("-print-file-name={s}", .{file_name});
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "c++", arg },
        .max_output_bytes = 4096,
    }) catch @panic("failed to query host C++ runtime path");
    if (result.stderr.len != 0) b.allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) {
            return std.mem.trim(u8, result.stdout, "\r\n");
        },
        else => {},
    }
    @panic("host C++ compiler failed to report runtime path");
}

fn linuxSystemLibDir(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.cpu.arch) {
        .x86_64 => "/usr/lib/x86_64-linux-gnu",
        .aarch64 => "/usr/lib/aarch64-linux-gnu",
        else => @panic("unsupported Linux Dawn arch"),
    };
}

fn linuxSystemLibTriplet(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-linux-gnu",
        .aarch64 => "aarch64-linux-gnu",
        else => @panic("unsupported Linux Dawn arch"),
    };
}

fn linkHostCppRuntime(step: anytype, target: std.Build.ResolvedTarget) void {
    if (target.result.abi == .msvc) return;
    step.linkLibCpp();
}

fn dawnTargetKey(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @panic("unsupported Dawn arch"),
    };

    if (target.result.os.tag == .linux and target.result.abi == .android) {
        return b.fmt("{s}-linux-android", .{arch});
    }

    return switch (target.result.os.tag) {
        .linux => b.fmt("{s}-linux-gnu", .{arch}),
        .windows => b.fmt("{s}-windows-gnu", .{arch}),
        .macos => b.fmt("{s}-macos", .{arch}),
        else => @panic("unsupported Dawn OS"),
    };
}
