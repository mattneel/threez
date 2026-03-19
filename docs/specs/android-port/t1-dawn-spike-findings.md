# T1: Dawn Android Spike — Findings

## Status: SPIKE COMPLETE — aarch64 cross-compilation verified

## 1. Dawn Android Prebuilt: Built Successfully

No prebuilt Dawn Android binaries existed anywhere. We built them from source.

### Build Process (CMake + NDK)

**Prerequisites:**
- Android NDK r27c at `$ANDROID_NDK_HOME` (default: `/home/autark/android/android-ndk-r27c`)
- CMake 3.22+, Ninja, GN (installed via `sudo cp gn /usr/local/bin/gn` from CIPD)

**Dawn Version:** Official Dawn at commit `216d841e30` (June 30, 2023) — matches the hexops/dawn `generated-2023-06-30.1688174725` branch used by `mach-gpu-dawn` to build the existing desktop prebuilts.

**Header Verification:** The generated `webgpu.h` at this commit is byte-identical to `deps/zgpu/libs/dawn/include/dawn/webgpu.h`.

**Build Steps (aarch64):**

```bash
# 1. Clone Dawn at the matching commit
git clone --shallow-since="2023-06-28" https://dawn.googlesource.com/dawn dawn-official
cd dawn-official
git checkout 216d841e30

# 2. Fetch third-party dependencies (no depot_tools needed)
python3 tools/fetch_dawn_dependencies.py --shallow

# 3. Configure CMake for Android arm64
cmake -S . -B build-android-arm64 \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-Wno-switch-default -Wno-unsafe-buffer-usage" \
  -DDAWN_SUPPORTS_GLFW_FOR_WINDOWING=OFF \
  -DDAWN_ENABLE_VULKAN=ON \
  -DDAWN_ENABLE_NULL=OFF -DDAWN_ENABLE_METAL=OFF \
  -DDAWN_ENABLE_D3D11=OFF -DDAWN_ENABLE_D3D12=OFF \
  -DDAWN_ENABLE_DESKTOP_GL=OFF -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_USE_GLFW=OFF -DDAWN_USE_X11=OFF -DDAWN_USE_WAYLAND=OFF \
  -DDAWN_BUILD_SAMPLES=OFF -DDAWN_BUILD_TESTS=OFF \
  -DTINT_BUILD_TESTS=OFF -DTINT_BUILD_GLSL_WRITER=OFF \
  -DTINT_BUILD_HLSL_WRITER=OFF -DTINT_BUILD_MSL_WRITER=OFF \
  -DTINT_BUILD_BENCHMARKS=OFF -DDAWN_BUILD_BENCHMARKS=OFF \
  -G Ninja

# 4. Build (781 compilation units, ~5 min on 32 cores)
ninja -C build-android-arm64 -j$(nproc) dawn_native dawn_proc dawn_platform libtint dawn_wire

# 5. Merge all static libs into single libdawn.a
AR=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar
STRIP=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
mkdir -p /tmp/dawn-merge
for lib in $(find build-android-arm64 -name '*.a'); do
    cd /tmp/dawn-merge && $AR x "$lib"
done
$AR rcs /tmp/dawn-merge/libdawn.a /tmp/dawn-merge/*.o
$STRIP --strip-debug /tmp/dawn-merge/libdawn.a
# Result: ~42 MB stripped static library
```

**For x86_64:** Same steps but with `-DANDROID_ABI=x86_64`.

### CMake Gotchas
- **`-Wno-switch-default`**: NDK r27c's clang is newer than what Dawn was tested with; triggers `-Werror` on missing default labels
- **`DAWN_SUPPORTS_GLFW_FOR_WINDOWING=OFF`**: Must be set explicitly for Android or CMake errors (variable undefined on Android)
- **`-Wno-unsafe-buffer-usage`**: Additional warning suppression needed for NDK r27c clang

## 2. zgpu Changes Applied

All 6 changes from the research phase were applied to the vendored `deps/zgpu/`:

| File | Change | Status |
|------|--------|--------|
| `wgpu.zig` | Added `SurfaceDescriptorFromAndroidNativeWindow` struct | Done |
| `zgpu.zig` | Added `fn_getAndroidNativeWindow` + method to `WindowProvider` | Done |
| `zgpu.zig` | Added `android_native_window` to `SurfaceDescriptorTag` | Done |
| `zgpu.zig` | Added android case to `createSurfaceForWindow()` | Done |
| `build.zig` | Added android to `addLibraryPathsTo()` with lazy deps | Done |
| `build.zig` | Added android to `checkTargetSupported()` | Done |
| `build.zig` | Added `linkSystemDeps()` for android (libandroid + liblog) | Done |
| `build.zig.zon` | Added `dawn_aarch64_linux_android` + `dawn_x86_64_linux_android` lazy deps | Done |

## 3. Build System Changes

### `build.zig`
- `is_android` detection: `target.result.os.tag == .linux and target.result.abi == .android`
- Android builds shared library (`.dynamic`) instead of executable
- zglfw, clap, static lib, run step, embed-check, tests: all guarded with `if (!is_android)`
- NDK sysroot via `exe.setLibCFile(libc_conf)` + NDK library path for system libs
- Uses LLVM backend (required for QuickJS extern struct returns)

### `deps/zig-quickjs-ng/build.zig`
- Modified `translateC()` to add NDK sysroot include paths when targeting Android
- Fixes: Zig's `TranslateC` step doesn't pass `--libc` to subprocess

### `deps/android-sysroot/*.conf`
- Libc configuration files pointing at NDK r27c sysroot
- Must include ALL fields (`include_dir`, `sys_include_dir`, `crt_dir`, `msvc_lib_dir`, `kernel32_lib_dir`, `kernel_header_dir`, `gcc_dir`) even if empty

## 4. Verified Build Commands

```bash
# Desktop (unchanged)
zig build                                    # ✅ passes

# Android aarch64
zig build -Dtarget=aarch64-linux-android \
  --libc deps/android-sysroot/aarch64-libc.conf   # ✅ passes

# Output: zig-out/lib/libthreez.so (24 MB, ELF aarch64)
```

## 5. Remaining for Full Spike

- [x] Dawn Android prebuilt built and packaged
- [x] Cross-compilation pipeline working end-to-end
- [ ] Build Dawn for x86_64-linux-android (in progress)
- [ ] Test `wgpuCreateInstance()` on physical device
- [ ] Test surface creation with ANativeWindow on device
