<!-- status: locked -->
<!-- epic-slug: android-port -->
# Tickets: Android Port

## Execution Order

```
T1: Dawn Android Spike (no deps)                     ← CRITICAL PATH
T2: Zig Android cross-compile skeleton (no deps)     ← parallel with T1
  T3: Vendor NDK headers + native_app_glue (T2)
  T4: Epoll I/O backend (T2)
  T5: Android NativeActivity lifecycle (T3)
  T6: APK packaging in build.zig (T3, T5)
  T7: Dawn + zgpu Android surface integration (T1, T5)
  T8: Android asset loading via AAssetManager (T3, T4)
  T9: Android console.log → logcat + file (T5)
  T10: Android touch input → PointerEvent (T5)
  T11: Triangle renders on device (T6, T7)
  T12: JS engine + bootstrap on Android (T5, T8, T9)
  T13: glTF viewer running on device (T11, T12, T10)
  T14: Lifecycle robustness (pause/resume/rotate) (T13)
  T15: Gamepad + stylus input (T10, T13)
  T16: x86_64 Android + emulator support (T13)
```

**Execution strategy**: T1 (Dawn spike) runs first as a standalone gate. If T1 succeeds, T2-T16 proceed. If T1 fails, re-evaluate the entire approach.

**Parallel groups** (after T1 gate passes):
- Group A: T2 (starts immediately after T1 gate)
- Group B: T3, T4 (both depend only on T2)
- Group C: T8, T9, T10 (independent once T3/T5 done)
- Group D: T14, T15, T16 (polish, all depend on T13)

---

### T1: Dawn Android Spike — Build and Validate

**Specs**: epic-brief.md §Kill Criteria, tech-plan.md §Risks
**Files**: New build scripts/docs (outside main source tree), `build.zig.zon` (eventually)
**Touch list**: Dawn build, Android Vulkan surface
**Dependencies**: None — critical path blocker
**Effort**: Large (spike — 1-3 days of investigation)
**Parallel group**: A (with T2)

**Description**:
Determine whether Dawn can produce a working `libdawn.so` for `aarch64-linux-android` and create a Vulkan surface from an ANativeWindow. This is the single biggest risk — if this fails, the port is blocked.

**Implementation Steps**:

Step 1 — Research existing prebuilts
- Check zgpu's Dawn binary sources (the URLs in `build.zig.zon` lines 27-50) for Android variants
- Check the upstream Dawn project (https://dawn.googlesource.com/dawn) for Android build docs
- Check if any Zig community projects have already built Dawn for Android
- Document findings

Step 2 — Build Dawn for Android
- Clone Dawn repo
- Configure for Android target using GN or CMake:
  ```
  gn gen out/android-arm64 --args='
    target_os="android"
    target_cpu="arm64"
    android_ndk_root="<path>"
    is_debug=false
    dawn_enable_vulkan=true
    dawn_enable_opengl=false
    dawn_enable_metal=false
    dawn_enable_d3d12=false
  '
  ```
- Build `libdawn.so` (or `libwebgpu_dawn.so`)
- Record build steps, required Dawn version, output artifact names and sizes

Step 3 — Validate on device
- Create a minimal C/Zig program that:
  1. Calls `wgpuCreateInstance()`
  2. Creates a Vulkan surface from a dummy ANativeWindow (via NativeActivity)
  3. Requests adapter + device
  4. Clears to a solid color and presents
- Deploy to physical device via adb
- Verify rendering

Step 4 — Package as prebuilt
- Create a tarball matching zgpu's expected format
- Test that `build.zig.zon` can fetch it (local file:// URL for now)
- Document the exact Dawn commit hash and build flags

**Acceptance Criteria**:
- [ ] `libdawn.so` for aarch64-linux-android exists and is < 25 MB
- [ ] `wgpuCreateInstance()` succeeds on a physical Android device
- [ ] A Vulkan surface can be created from ANativeWindow
- [ ] A clear-color frame presents without errors
- [ ] Build steps documented and reproducible
- [ ] Prebuilt archive format compatible with `build.zig.zon` lazy dependency

**Verification**:
- Commands: Dawn build script completes, `adb install` + `adb shell am start` on test APK
- Manual: Visual confirmation of solid color on device screen

**Rollback**: This is a spike — no production code changes. Discard if it fails.

**Kill criteria**: If Dawn cannot create a VkSurface from ANativeWindow, or if the Vulkan backend crashes on Android, escalate immediately — this blocks the entire epic.

---

### T2: Zig Android Cross-Compile Skeleton

**Specs**: tech-plan.md §Design Decisions (entry point, GLFW conditionality)
**Files**: `build.zig`, `src/main.zig`
**Touch list**: build system, main entry point
**Dependencies**: None
**Effort**: Small (2-4 hours)
**Parallel group**: A (with T1)

**Description**:
Make `zig build -Dtarget=aarch64-linux-android` compile successfully, producing a shared library (`.so`). No rendering, no NativeActivity — just prove the toolchain works. Skip zglfw when targeting Android.

**Implementation Steps**:

Step 1 — Detect Android target in build.zig
- After `standardTargetOptions()` (line 5), check:
  ```zig
  const is_android = target.result.os.tag == .linux and target.result.abi == .android;
  ```
- Use this flag throughout build.zig

Step 2 — Conditionally skip zglfw
- The `zglfw` dependency (build.zig.zon line 52) should not be fetched/linked for Android
- Guard zglfw module import and linking with `if (!is_android)`
- Same for the zglfw import in window.zig — use `@import("builtin")` to skip

Step 3 — Set shared library output for Android
- Android native libs must be `.so` files, not executables
- Use `b.addSharedLibrary()` instead of `b.addExecutable()` when targeting Android
- Export `android_main` symbol (for now, a stub that does nothing)

Step 4 — Verify cross-compilation
- Run `zig build -Dtarget=aarch64-linux-android`
- Confirm `.so` output exists in `zig-out/lib/`
- Confirm no zglfw symbols in the binary

**Edge Cases**:
| Case | Resolution |
|------|-----------|
| Zig can't find Android libc | Zig ships musl for android targets — should work. If not, investigate `--sysroot`. |
| QuickJS has platform-specific ifdefs | QuickJS-NG uses `__linux__` which matches Android. Verify `__ANDROID__` isn't required. |
| LLVM backend required (line 38 in build.zig) | Should work for Android targets too — verify. |

**Acceptance Criteria**:
- [ ] `zig build -Dtarget=aarch64-linux-android` completes without errors
- [ ] Output is a `.so` file
- [ ] zglfw is not linked
- [ ] Desktop build (`zig build`) still works unchanged

**Verification**:
- Commands: `zig build -Dtarget=aarch64-linux-android`, `file zig-out/lib/libthreez.so`, `nm -D zig-out/lib/libthreez.so | grep android_main`
- Desktop regression: `zig build`

**Rollback**: Revert build.zig changes.

---

### T3: Vendor NDK Headers + native_app_glue

**Specs**: tech-plan.md §Design Decisions (NDK headers: vendor minimal)
**Files**: `deps/android-ndk/` (new), `src/android_native_app_glue.c` (new), `src/android_native_app_glue.h` (new), `build.zig`
**Touch list**: vendored deps, build system
**Dependencies**: T2
**Effort**: Small (2-3 hours)
**Parallel group**: B (with T4)

**Description**:
Vendor the minimal set of NDK headers needed for NativeActivity, ANativeWindow, AAssetManager, AInputQueue, ALooper, and the `android_native_app_glue` source file. Add them to the Zig build.

**Implementation Steps**:

Step 1 — Identify required headers
From the NDK (r26+), copy these headers to `deps/android-ndk/`:
- `android/native_activity.h`
- `android/native_window.h`
- `android/native_window_jni.h`
- `android/asset_manager.h`
- `android/asset_manager_jni.h`
- `android/input.h`
- `android/keycodes.h`
- `android/looper.h`
- `android/log.h`
- `android/configuration.h`
- `android/rect.h`
- `jni.h` (minimal — just the types needed by native_activity.h)

Step 2 — Vendor android_native_app_glue
- Copy `android_native_app_glue.c` and `.h` from NDK sources (`sources/android/native_app_glue/`)
- Place in `src/` or `deps/android-ndk/`
- These are Apache 2.0 licensed — add license notice

Step 3 — Add to build.zig
- When `is_android`:
  - Add `deps/android-ndk/` to C include path
  - Compile `android_native_app_glue.c` as a C source file
  - Link `libandroid`, `liblog` (Android system libraries)

Step 4 — Verify
- Create a minimal Zig file that `@cImport`s `<android/native_activity.h>`
- Confirm it compiles for aarch64-linux-android

**Acceptance Criteria**:
- [ ] NDK headers vendored in `deps/android-ndk/`
- [ ] `android_native_app_glue.c` compiles as part of the build
- [ ] Zig code can `@cImport` NDK types (ANativeWindow, AAssetManager, etc.)
- [ ] License notice included
- [ ] Desktop build unaffected

**Verification**:
- Commands: `zig build -Dtarget=aarch64-linux-android` with test import file

**Rollback**: Remove `deps/android-ndk/` directory.

---

### T4: Epoll I/O Backend

**Specs**: tech-plan.md §Data Model (EpollPoll), §File Changes
**Files**: `src/io/epoll.zig` (new), `src/io/poll.zig` (modified)
**Touch list**: I/O subsystem
**Dependencies**: T2
**Effort**: Medium (4-6 hours)
**Parallel group**: B (with T3)

**Description**:
Implement an epoll-based async I/O backend following the same interface as io_uring, kqueue, and IOCP. This is the primary I/O path for Android (and could serve as fallback on older Linux).

**Implementation Steps**:

Step 1 — Create `src/io/epoll.zig`
- Follow the pattern in `src/io/kqueue.zig` (closest analog — also does sync file I/O + async socket I/O)
- Struct: `EpollPoll` with:
  - `epoll_fd: std.posix.fd_t` (from `epoll_create1(0)`)
  - `events: [256]std.os.linux.epoll_event` (poll buffer)
  - `completions: BoundedArray(Completion, 256)`
- Implement `init()`, `deinit()`, `submit()`, `poll()` matching the IOPoll interface

Step 2 — File I/O (synchronous, like kqueue)
- `readFile()`: Use `pread()` with immediate completion
- `writeFile()`: Use `pwrite()` with immediate completion
- Return completions inline (no epoll involvement for file I/O)

Step 3 — Socket I/O (async via epoll)
- `connect()`: `epoll_ctl(ADD, fd, EPOLLOUT)` → poll returns when connected
- `recv()`: `epoll_ctl(ADD, fd, EPOLLIN)` → poll returns when readable
- `send()`: `epoll_ctl(ADD, fd, EPOLLOUT)` → poll returns when writable
- Use `EPOLLET` (edge-triggered) for efficiency

Step 4 — Wire into poll.zig
- In `src/io/poll.zig`, update the switch:
  ```zig
  pub const IOPoll = switch (builtin.os.tag) {
      .linux => if (builtin.abi == .android)
          @import("epoll.zig").EpollPoll
      else
          @import("io_uring.zig").IoUringPoll,
      // ... rest unchanged
  };
  ```

Step 5 — Tests
- Unit tests in `epoll.zig` guarded with `if (builtin.os.tag == .linux)`
- Test sync file read/write
- Test epoll socket connect/recv/send (if possible in test harness)

**Edge Cases**:
| Case | Resolution |
|------|-----------|
| `epoll_create1` not available (very old kernel) | Fall back to `epoll_create(256)` |
| EINTR during `epoll_wait` | Retry (standard pattern) |
| Edge-triggered missing events | Use EPOLLET + EPOLLONESHOT, re-arm after each event |

**Acceptance Criteria**:
- [ ] `EpollPoll` implements the same interface as `IoUringPoll` / `KqueuePoll`
- [ ] File read/write works synchronously
- [ ] Socket I/O works asynchronously via epoll
- [ ] `poll.zig` selects epoll for android abi
- [ ] Unit tests pass on Linux
- [ ] Desktop build + tests unaffected

**Verification**:
- Commands: `zig build test` (on Linux host), `zig build -Dtarget=aarch64-linux-android` compiles

**Rollback**: Remove `src/io/epoll.zig`, revert `poll.zig` change.

---

### T5: Android NativeActivity Lifecycle

**Specs**: core-flows.md §Flow 1 (lifecycle state machine), §Flow 2 (startup sequence)
**Files**: `src/android_app.zig` (new), `src/main.zig` (modified)
**Touch list**: app lifecycle, main entry point
**Dependencies**: T3
**Effort**: Medium (4-6 hours)
**Parallel group**: —

**Description**:
Implement the Android NativeActivity lifecycle state machine. Handle `APP_CMD_*` callbacks, manage window state, provide the same "poll events + get dimensions" interface that `window.zig` provides on desktop.

**Implementation Steps**:

Step 1 — Create `src/android_app.zig`
- Import NDK types via `@cImport(<android/native_activity.h>)` and native_app_glue
- Define `AndroidApp` struct per tech-plan data model:
  ```zig
  const AndroidApp = struct {
      native_app: *c.android_app,
      window: ?*c.ANativeWindow,
      window_width: u32,
      window_height: u32,
      state: State,
      asset_manager: *c.AAssetManager,

      const State = enum { created, window_ready, running, paused, window_lost, destroyed };
  };
  ```

Step 2 — Handle lifecycle commands
- Register `onAppCmd` callback with `native_app_glue`:
  ```zig
  fn onAppCmd(app: *c.android_app, cmd: i32) void {
      switch (cmd) {
          c.APP_CMD_INIT_WINDOW => { ... },
          c.APP_CMD_TERM_WINDOW => { ... },
          c.APP_CMD_PAUSE => { ... },
          c.APP_CMD_RESUME => { ... },
          c.APP_CMD_DESTROY => { ... },
      }
  }
  ```
- On `INIT_WINDOW`: store ANativeWindow, query dimensions via `ANativeWindow_getWidth/Height`, transition to `window_ready`
- On `TERM_WINDOW`: set window to null, transition to `window_lost`
- On `PAUSE`/`RESUME`: toggle state for render loop freeze

Step 3 — Poll events
- `pollEvents()` wraps `ALooper_pollAll(0, ...)`:
  - Returns lifecycle commands (handled internally)
  - Returns input events (passed to caller)
  - Non-blocking (timeout = 0) during render loop
  - Blocking (timeout = -1) during paused state to save battery

Step 4 — Export `android_main`
- In `src/main.zig`, add:
  ```zig
  pub export fn android_main(app: *c.android_app) void {
      // Initialize AndroidApp
      // Wait for INIT_WINDOW
      // Then proceed to runtime init (similar to desktop runScript)
  }
  ```
- Guard desktop `main()` with `if (!is_android)` comptime check

Step 5 — Logging
- Use `__android_log_print` for early lifecycle debug messages (before console.log polyfill is ready)
- Tag: "threez"

**Acceptance Criteria**:
- [ ] `android_main` is exported from the `.so`
- [ ] Lifecycle state machine handles all APP_CMD_* transitions
- [ ] `pollEvents()` returns input events and handles lifecycle internally
- [ ] Window dimensions are available after `INIT_WINDOW`
- [ ] Paused state blocks in `ALooper_pollAll(-1)` (saves battery)
- [ ] Desktop `main()` still works unchanged
- [ ] Debug logging visible in logcat

**Verification**:
- Commands: `zig build -Dtarget=aarch64-linux-android`, `nm -D` shows `android_main`
- On-device: `adb logcat -s threez` shows lifecycle transitions

**Rollback**: Remove `src/android_app.zig`, revert `main.zig`.

---

### T6: APK Packaging in build.zig

**Specs**: epic-brief.md §Constraints (no Gradle), tech-plan.md §Design Decisions (APK assembly)
**Files**: `build.zig` (modified), `AndroidManifest.xml` (new)
**Touch list**: build system, packaging
**Dependencies**: T3, T5
**Effort**: Medium (4-6 hours)
**Parallel group**: —

**Description**:
Add an APK assembly step to `build.zig` that packages the `.so`, `AndroidManifest.xml`, and assets into a signed, installable APK using `aapt2`, `zipalign`, and `apksigner`.

**Implementation Steps**:

Step 1 — Create AndroidManifest.xml
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.threez.gltfviewer"
    android:versionCode="1"
    android:versionName="1.0">

    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="33" />
    <uses-feature android:glEsVersion="0x00030001" android:required="true" />
    <uses-feature android:name="android.hardware.vulkan.level" android:version="0" android:required="true" />

    <application android:hasCode="false" android:label="Threez glTF Viewer">
        <activity android:name="android.app.NativeActivity"
            android:configChanges="orientation|screenSize|keyboardHidden">
            <meta-data android:name="android.app.lib_name" android:value="threez" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

Step 2 — Add build.zig APK step
- New build step `apk` that:
  1. Compiles the `.so` (depends on main compile step)
  2. Runs `aapt2 link` with manifest + assets
  3. Injects `.so` into APK at `lib/arm64-v8a/libthreez.so`
  4. Runs `zipalign -f 4`
  5. Runs `apksigner sign --ks debug.keystore`
- Accept `ANDROID_SDK_HOME` as build option or environment variable
- Generate debug keystore if not present (`keytool -genkey`)

Step 3 — Assets directory
- Copy JS files + glTF assets into APK `assets/` directory
- Copy `bootstrap.js` into assets
- Copy example scripts and models

Step 4 — Install step
- Add `adb-install` build step: `adb install -r <apk>`
- `zig build apk -Dtarget=aarch64-linux-android && zig build adb-install`

**Edge Cases**:
| Case | Resolution |
|------|-----------|
| aapt2/zipalign not found | Clear error message with download instructions |
| Debug keystore doesn't exist | Auto-generate with `keytool` |
| APK too large (>100MB) | Strip Dawn .so, compress assets |

**Acceptance Criteria**:
- [ ] `zig build apk -Dtarget=aarch64-linux-android` produces a valid APK
- [ ] APK contains `lib/arm64-v8a/libthreez.so`
- [ ] APK contains `assets/` with JS + glTF files
- [ ] APK installs on device via `adb install`
- [ ] App icon appears in launcher
- [ ] App launches (even if it just shows black screen + logcat output at this stage)
- [ ] Desktop build unaffected

**Verification**:
- Commands: `zig build apk ...`, `adb install`, `adb shell am start -n com.threez.gltfviewer/android.app.NativeActivity`
- Manual: App appears in launcher and launches

**Rollback**: Revert build.zig APK step, remove AndroidManifest.xml.

---

### T7: Dawn + zgpu Android Surface Integration

**Specs**: tech-plan.md §Design Decisions (try extending zgpu), §Risks (zgpu surface creation)
**Files**: `build.zig.zon` (modified), `src/gpu_bridge.zig` (modified), possibly zgpu fork
**Touch list**: GPU subsystem, dependencies
**Dependencies**: T1, T5
**Effort**: Medium-Large (4-8 hours)
**Parallel group**: —

**Description**:
Integrate the Dawn Android binaries (from T1) into the build system and make the GPU bridge create a WebGPU surface from ANativeWindow. Try extending zgpu's `WindowProvider` first; if that doesn't work, use raw wgpu API for surface creation on Android.

**Implementation Steps**:

Step 1 — Add Dawn Android deps to build.zig.zon
- Add lazy dependencies for Android Dawn binaries:
  ```
  .@"dawn-aarch64-linux-android" = .{ .url = "...", .hash = "...", .lazy = true },
  .@"dawn-x86_64-linux-android" = .{ .url = "...", .hash = "...", .lazy = true },
  ```
- Update build.zig to select the right Dawn binary based on target

Step 2 — Try extending zgpu WindowProvider
- Examine zgpu's `WindowProvider` struct for extensibility
- If it has a generic native-window mechanism, add Android callback:
  ```zig
  .fn_getAndroidWindow = struct {
      fn f() *anyopaque {
          return @ptrCast(android_app.window.?);
      }
  }.f,
  ```
- If zgpu's `GraphicsContext.create()` can accept this, use it

Step 3 — Fallback: raw wgpu surface creation
- If zgpu can't handle Android, create the surface manually:
  ```zig
  const surface_desc = wgpu.SurfaceDescriptor{
      .next_in_chain = @ptrCast(&wgpu.SurfaceDescriptorFromAndroidNativeWindow{
          .window = android_app.window.?,
      }),
  };
  const surface = instance.createSurface(surface_desc);
  ```
- Then request adapter, device, queue manually (bypassing zgpu.GraphicsContext)

Step 4 — Update gpu_bridge.zig
- On Android, pass the manually-created surface/device/queue to `GpuBridge.init()`
- The rest of the GPU bridge (handle table, descriptor translation) works unchanged

Step 5 — Validate
- Compile for Android target
- Verify Dawn `.so` is linked
- Test surface creation on device (from T6 APK)

**Gotchas**:
- zgpu may embed platform-specific surface creation in `GraphicsContext` that's hard to extend without forking
- Dawn's wgpu header may need `WGPUSurfaceDescriptorFromAndroidNativeWindow` — verify it's present in the version we use
- The Dawn `.so` must be placed in the APK's `lib/arm64-v8a/` alongside `libthreez.so`

**Acceptance Criteria**:
- [ ] Dawn Android binaries integrated into build system
- [ ] WebGPU surface created from ANativeWindow on device
- [ ] Adapter + device + queue obtained successfully
- [ ] GPU bridge initialized with Android-created objects
- [ ] Desktop GPU path unchanged

**Verification**:
- On-device: logcat shows successful surface/adapter/device creation
- Commands: `zig build -Dtarget=aarch64-linux-android` links Dawn

**Rollback**: Revert build.zig.zon and gpu_bridge.zig changes.

---

### T8: Android Asset Loading via AAssetManager

**Specs**: core-flows.md §Flow 5 (asset loading), tech-plan.md §Design Decisions (asset loading)
**Files**: `src/polyfills/fetch.zig` (modified)
**Touch list**: fetch polyfill
**Dependencies**: T3, T4
**Effort**: Small (2-3 hours)
**Parallel group**: C (with T9, T10)

**Description**:
On Android, make `__native_readFileSync` use AAssetManager for relative paths (APK-bundled files) and `std.fs` for absolute paths. HTTP fetch is unchanged.

**Implementation Steps**:

Step 1 — Store AAssetManager globally
- In `android_app.zig`, expose the AAssetManager pointer
- Set it during `android_main` init from `native_app.activity.assetManager`

Step 2 — Modify `__native_readFileSync` in fetch.zig
- At the top of the function, check if path is relative (doesn't start with `/`):
  ```zig
  if (comptime builtin.abi == .android) {
      if (!std.fs.path.isAbsolute(path)) {
          return readFromAssetManager(path);
      }
  }
  // Fall through to existing std.fs.cwd().openFile() for absolute paths
  ```

Step 3 — Implement `readFromAssetManager`
```zig
fn readFromAssetManager(path: [*:0]const u8) ?[]const u8 {
    const asset = c.AAssetManager_open(asset_mgr, path, c.AASSET_MODE_BUFFER);
    if (asset == null) return null;
    defer c.AAsset_close(asset);
    const len = c.AAsset_getLength(asset);
    const buf = allocator.alloc(u8, @intCast(len)) catch return null;
    const read = c.AAsset_read(asset, buf.ptr, @intCast(len));
    if (read != len) { allocator.free(buf); return null; }
    return buf;
}
```

Step 4 — Test
- Bundle a test file in APK assets
- Verify `fetch("test.txt")` reads it correctly on device
- Verify `fetch("/sdcard/test.txt")` still uses filesystem

**Acceptance Criteria**:
- [ ] Relative paths read from APK assets via AAssetManager
- [ ] Absolute paths still use `std.fs` (filesystem)
- [ ] HTTP URLs still use `std.http.Client`
- [ ] 64 MiB file size limit still enforced
- [ ] Desktop fetch behavior unchanged

**Verification**:
- On-device: `fetch("bootstrap.js")` returns content from APK
- Desktop: existing fetch tests pass

**Rollback**: Revert fetch.zig changes.

---

### T9: Android console.log → Logcat + File

**Specs**: tech-plan.md §Open Questions (#5 logging)
**Files**: `src/polyfills/console.zig` (modified or new wrapper)
**Touch list**: console polyfill
**Dependencies**: T5
**Effort**: Small (1-2 hours)
**Parallel group**: C (with T8, T10)

**Description**:
On Android, route `console.log/warn/error` to both `__android_log_print` (logcat) and a log file on device internal storage.

**Implementation Steps**:

Step 1 — Find the console polyfill
- Locate where `console.log` is implemented (likely `src/polyfills/console.zig`)
- Understand current output mechanism (probably `std.io.getStdOut()` or `std.debug.print`)

Step 2 — Add Android logcat output
- When `builtin.abi == .android`:
  ```zig
  const c = @cImport(@cInclude("android/log.h"));
  fn androidLog(level: c_int, msg: [*:0]const u8) void {
      _ = c.__android_log_print(level, "threez", "%s", msg);
  }
  ```
- Map console.log → `ANDROID_LOG_INFO`, console.warn → `ANDROID_LOG_WARN`, console.error → `ANDROID_LOG_ERROR`

Step 3 — Add file logging
- Open log file at `android_app.native_app.activity.internalDataPath ++ "/threez.log"`
- Append each log line with timestamp
- Flush after each write (or on a timer)

Step 4 — Dual output
- On Android: write to both logcat and file
- On desktop: existing behavior unchanged

**Acceptance Criteria**:
- [ ] `console.log("hello")` appears in `adb logcat -s threez`
- [ ] Same message appears in `/data/data/com.threez.gltfviewer/files/threez.log`
- [ ] Log levels correctly mapped (info/warn/error)
- [ ] Desktop console output unchanged

**Verification**:
- Commands: `adb logcat -s threez`, `adb shell cat /data/data/com.threez.gltfviewer/files/threez.log`

**Rollback**: Revert console polyfill changes.

---

### T10: Android Touch Input → PointerEvent

**Specs**: core-flows.md §Flow 4 (input event translation)
**Files**: `src/event_bridge.zig` (modified)
**Touch list**: event system
**Dependencies**: T5
**Effort**: Medium (4-6 hours)
**Parallel group**: C (with T8, T9)

**Description**:
Translate Android touch input (from AInputQueue) into DOM PointerEvents so that Three.js OrbitControls works with touch gestures. Multi-touch is essential for pinch-zoom and two-finger pan.

**Implementation Steps**:

Step 1 — Add Android input handler to event_bridge.zig
- On Android, register `onInputEvent` callback with native_app_glue
- Function signature: `fn onInputEvent(app: *c.android_app, event: *c.AInputEvent) callconv(.C) i32`

Step 2 — Translate motion events
```zig
fn translateMotionEvent(event: *c.AInputEvent) void {
    const action = c.AMotionEvent_getAction(event);
    const action_masked = action & c.AMOTION_EVENT_ACTION_MASK;
    const pointer_count = c.AMotionEvent_getPointerCount(event);

    // For each pointer (multi-touch)
    for (0..pointer_count) |i| {
        const pointer_id = c.AMotionEvent_getPointerId(event, i);
        const x = c.AMotionEvent_getX(event, i);
        const y = c.AMotionEvent_getY(event, i);
        const pressure = c.AMotionEvent_getPressure(event, i);
        const tool_type = c.AMotionEvent_getToolType(event, i);

        const dom_event = PointerEvent{
            .type = switch (action_masked) {
                c.AMOTION_EVENT_ACTION_DOWN, c.AMOTION_EVENT_ACTION_POINTER_DOWN => "pointerdown",
                c.AMOTION_EVENT_ACTION_MOVE => "pointermove",
                c.AMOTION_EVENT_ACTION_UP, c.AMOTION_EVENT_ACTION_POINTER_UP => "pointerup",
                c.AMOTION_EVENT_ACTION_CANCEL => "pointercancel",
                else => continue,
            },
            .clientX = x,
            .clientY = y,
            .pointerId = pointer_id,
            .pressure = pressure,
            .pointerType = if (tool_type == c.AMOTION_EVENT_TOOL_TYPE_STYLUS) "pen" else "touch",
        };

        dispatchToJS(dom_event);
    }
}
```

Step 3 — Handle pointer index for DOWN/UP
- `ACTION_POINTER_DOWN` and `ACTION_POINTER_UP` encode the pointer index in the upper bits
- Extract with `(action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT`

Step 4 — Dispatch to JS
- Call the same `dispatchEvent` path used by GLFW mouse events
- Create JS PointerEvent object with all fields

Step 5 — Test gestures
- Single finger drag → continuous pointermove events → OrbitControls rotate
- Two finger pinch → two pointers with changing distance → zoom
- Two finger drag → two pointers with same delta → pan

**Edge Cases**:
| Case | Resolution |
|------|-----------|
| Pointer cancel (gesture intercepted by OS) | Dispatch `pointercancel` → OrbitControls resets |
| Very rapid multi-touch | Process all pointers in a single event batch |
| Touch outside rendering area | Shouldn't happen (fullscreen NativeActivity) |

**Acceptance Criteria**:
- [ ] Single touch generates `pointerdown` → `pointermove` → `pointerup` sequence
- [ ] Multi-touch generates separate pointer IDs per finger
- [ ] `clientX`/`clientY` are in window coordinates
- [ ] `pressure` is populated (non-zero for finger touch)
- [ ] `pointerType` is "touch" for finger, "pen" for stylus
- [ ] OrbitControls responds to: rotate (1 finger), zoom (pinch), pan (2 finger drag)
- [ ] Desktop mouse/pointer events unchanged

**Verification**:
- On-device: Touch the screen, verify OrbitControls rotates the model
- Logcat: Log dispatched event types and coordinates for debugging

**Rollback**: Revert event_bridge.zig Android additions.

---

### T11: Triangle Renders on Device

**Specs**: tech-plan.md §Milestone Sequencing (M3)
**Files**: No new files — integration test of T5, T6, T7
**Touch list**: integration
**Dependencies**: T6, T7
**Effort**: Small (2-3 hours)
**Parallel group**: —

**Description**:
End-to-end validation: build an APK that renders a clear-color or simple triangle on a physical Android device. This proves the full pipeline: NativeActivity → ANativeWindow → Dawn VkSurface → WebGPU render → present.

**Implementation Steps**:

Step 1 — Wire up rendering in android_main
- After `INIT_WINDOW`: create Dawn surface (T7), configure swapchain
- In render loop: acquire texture, create command encoder, render pass with clear color, submit, present
- Use the existing `gpu_bridge.zig` surface acquisition path

Step 2 — Build and deploy
- `zig build apk -Dtarget=aarch64-linux-android`
- `adb install -r zig-out/threez.apk`
- `adb shell am start -n com.threez.gltfviewer/android.app.NativeActivity`

Step 3 — Debug
- Watch `adb logcat -s threez` for errors
- Common issues: Dawn validation errors, Vulkan driver issues, swapchain format mismatch
- If clear color works, try loading the triangle example (may need T12 first)

**Acceptance Criteria**:
- [ ] Solid color fills the screen on physical device
- [ ] No Vulkan validation errors in logcat
- [ ] Frame rate is stable (no flicker or tearing)
- [ ] App doesn't crash after 30 seconds of running

**Verification**:
- Manual: Visual confirmation on device
- Logcat: No errors, frame timing logs

**Rollback**: N/A — integration test, no new code.

---

### T12: JS Engine + Bootstrap on Android

**Specs**: core-flows.md §Flow 2 (startup sequence)
**Files**: `src/runtime.zig` (modified)
**Touch list**: runtime initialization
**Dependencies**: T5, T8, T9
**Effort**: Medium (4-6 hours)
**Parallel group**: —

**Description**:
Initialize QuickJS on Android, load bootstrap.js from APK assets, evaluate polyfills, and run user JavaScript. This is the bridge between "triangle renders" and "Three.js works".

**Implementation Steps**:

Step 1 — Abstract runtime initialization
- In `runtime.zig`, factor out platform-agnostic init:
  - JS engine creation
  - Bootstrap evaluation
  - Polyfill registration
  - GPU bridge init (after surface exists)
  - Event bridge init
  - User script evaluation

Step 2 — Android runtime entry
- After `INIT_WINDOW` and Dawn surface creation:
  1. Init JS engine (platform-agnostic)
  2. Read `bootstrap.js` from APK assets (T8)
  3. Evaluate bootstrap
  4. Register polyfills (console via logcat+file, fetch via AAssetManager, etc.)
  5. Init GPU bridge with Android-created device/queue
  6. Create JS window/document/canvas objects (with Android window dimensions)
  7. Read user script from APK assets
  8. Evaluate user script
  9. Enter render loop

Step 3 — Asset path setup
- Set `__scriptDir` to "" (empty) on Android — all relative paths go through AAssetManager
- Or set it to the APK asset directory name if scripts are in a subdirectory

Step 4 — Verify
- Bundle a simple script: `console.log("hello from Android"); requestAnimationFrame(() => console.log("rAF fired"));`
- Verify both messages appear in logcat

**Acceptance Criteria**:
- [ ] QuickJS initializes on Android without errors
- [ ] `bootstrap.js` loads from APK assets
- [ ] `console.log` works (logcat + file)
- [ ] `fetch` works (reads from APK assets)
- [ ] `requestAnimationFrame` fires
- [ ] `setTimeout` / `setInterval` work
- [ ] User script evaluates successfully
- [ ] All polyfills (Event, EventTarget, DOM stubs, WebGPU constants) available

**Verification**:
- Logcat: "hello from Android", "rAF fired"
- On-device: No crashes during init

**Rollback**: Revert runtime.zig abstraction.

---

### T13: glTF Viewer Running on Device

**Specs**: epic-brief.md §Goals (#1), tech-plan.md §Milestone Sequencing (M8)
**Files**: APK asset configuration (ensure gltf-viewer.js + DamagedHelmet.glb + Three.js bundled)
**Touch list**: integration, assets
**Dependencies**: T11, T12, T10
**Effort**: Medium (4-6 hours — mostly debugging)
**Parallel group**: —

**Description**:
The big integration milestone: DamagedHelmet.glb renders on a physical Android device with touch-based OrbitControls. The same `gltf-viewer.js` that runs on desktop runs on Android.

**Implementation Steps**:

Step 1 — Bundle assets in APK
- Ensure APK `assets/` contains:
  - `gltf-viewer.js` (or `dist/gltf-viewer.js` if bundled)
  - `DamagedHelmet.glb`
  - `three.module.js` and dependencies (GLTFLoader, OrbitControls, WebGPURenderer)
  - `bootstrap.js`

Step 2 — Configure runtime to load gltf-viewer
- Set the user script path to `gltf-viewer.js` (resolved via AAssetManager)
- Ensure `__scriptDir` is set correctly for relative asset resolution

Step 3 — Debug render issues
- Common issues to watch for:
  - Texture format mismatches (Android Vulkan may prefer different swapchain formats)
  - Shader compilation errors (Tint/SPIR-V differences on Android Vulkan)
  - Missing WebGPU features (check device limits)
  - GLTFLoader path resolution
  - Three.js `self.URL` / `dom.window.URL` setup (see MEMORY.md)

Step 4 — Touch verification
- Rotate the helmet with single finger
- Zoom with pinch
- Pan with two fingers
- Verify smooth interaction

Step 5 — Performance check
- Use `adb shell dumpsys gfxinfo` for frame timing
- Target: >= 30 fps at device resolution
- If slow, check if Dawn validation layer is enabled (disable for release)

**Acceptance Criteria**:
- [ ] DamagedHelmet.glb renders correctly (geometry + PBR textures)
- [ ] Ambient + directional lighting visible
- [ ] Single-finger rotate works
- [ ] Pinch zoom works
- [ ] Two-finger pan works
- [ ] >= 30 fps on test device
- [ ] No JS errors in logcat
- [ ] No Vulkan validation errors

**Verification**:
- Manual: Visual comparison with desktop rendering
- Logcat: Clean output, frame timing

**Rollback**: N/A — integration milestone.

---

### T14: Lifecycle Robustness (Pause/Resume/Rotate)

**Specs**: core-flows.md §Flow 1 (state machine), §Flow 6 (surface lifecycle)
**Files**: `src/android_app.zig` (modified), `src/gpu_bridge.zig` (modified)
**Touch list**: lifecycle, GPU surface management
**Dependencies**: T13
**Effort**: Medium (4-6 hours)
**Parallel group**: D (with T15, T16)

**Description**:
Make the app survive lifecycle transitions: home button → resume, screen rotation, task switcher, split-screen. The GPU surface must be destroyed and recreated without crashing or corrupting state.

**Implementation Steps**:

Step 1 — Implement surface destroy/recreate
- On `APP_CMD_TERM_WINDOW`:
  1. Stop render loop (set flag)
  2. Wait for any in-flight GPU work (`device.poll(true)` or similar)
  3. Destroy swapchain
  4. Destroy surface
  5. Set window to null
- On `APP_CMD_INIT_WINDOW` (after previous window lost):
  1. Create new surface from new ANativeWindow
  2. Configure new swapchain (dimensions may have changed)
  3. Dispatch synthetic resize event to JS
  4. Resume render loop

Step 2 — Implement JS freeze on pause
- On `APP_CMD_PAUSE`:
  1. Set `paused = true`
  2. Render loop checks `paused` and skips all JS ticks + GPU presents
  3. `pollEvents()` uses blocking timeout (-1) to sleep until resume
- On `APP_CMD_RESUME`:
  1. Set `paused = false`
  2. Render loop resumes

Step 3 — Synthetic resize event
- After surface recreate, dispatch to JS:
  ```javascript
  window.innerWidth = newWidth;
  window.innerHeight = newHeight;
  window.dispatchEvent(new Event('resize'));
  ```
- The gltf-viewer's per-frame resize polling will pick up the new dimensions

Step 4 — Test scenarios
- Home button → app icon → resume
- Power button → unlock → resume
- Screen rotation (if not locked)
- Recent apps → back to app
- Split-screen toggle

**Acceptance Criteria**:
- [ ] Home → resume: rendering continues, no crash
- [ ] Screen rotation: surface recreated, scene renders at new dimensions
- [ ] Resize event dispatched after rotation
- [ ] No GPU errors during transition
- [ ] JS state preserved across pause/resume (camera position, loaded model)
- [ ] Battery: app doesn't consume CPU/GPU while paused

**Verification**:
- Manual: Execute each test scenario on device
- Logcat: No errors during transitions, lifecycle logs show correct state changes

**Rollback**: Revert android_app.zig and gpu_bridge.zig lifecycle changes.

---

### T15: Gamepad + Stylus Input

**Specs**: core-flows.md §Flow 4 (gamepad, stylus sections), epic-brief.md §Goals (#3)
**Files**: `src/event_bridge.zig` (modified)
**Touch list**: event system
**Dependencies**: T10, T13
**Effort**: Medium (4-6 hours)
**Parallel group**: D (with T14, T16)

**Description**:
Add gamepad and stylus input handling. Gamepad via Bluetooth maps to camera controls. Stylus provides pressure/tilt data in PointerEvents.

**Implementation Steps**:

Step 1 — Gamepad detection
- Android reports gamepad events through AInputQueue with source `AINPUT_SOURCE_GAMEPAD` / `AINPUT_SOURCE_JOYSTICK`
- Detect connected gamepads via input source flags
- Implement `navigator.getGamepads()` polyfill returning gamepad state

Step 2 — Gamepad axis/button mapping
- Map `AMOTION_EVENT_AXIS_X/Y` → left stick
- Map `AMOTION_EVENT_AXIS_Z/RZ` → right stick
- Map `AKEY_EVENT_*` for gamepad buttons (A/B/X/Y, triggers, bumpers)
- Store state in a `Gamepad` struct, updated on each event
- `navigator.getGamepads()` returns current state (polling model, like spec)

Step 3 — Gamepad → camera control
- Option A: Map right stick to synthetic mouse moves → OrbitControls
- Option B: Dispatch gamepad events, let JS handle mapping
- Recommendation: Option B (more flexible, follows web spec)

Step 4 — Stylus enhancements
- T10 already handles stylus as `pointerType = "pen"`
- Add additional stylus properties:
  - `tiltX`, `tiltY` from `AMotionEvent_getAxisValue(AXIS_TILT, ...)`
  - Higher precision `pressure` (stylus has 4096 levels vs 256 for finger)
  - `twist` if available (`AXIS_ORIENTATION`)

Step 5 — Test
- Connect Bluetooth gamepad, verify axes and buttons
- Use stylus, verify pressure/tilt in PointerEvent

**Acceptance Criteria**:
- [ ] Bluetooth gamepad detected and reported via `navigator.getGamepads()`
- [ ] Gamepad axes (sticks) and buttons correctly mapped
- [ ] Stylus `tiltX`/`tiltY` populated in PointerEvent
- [ ] Stylus pressure has higher precision than finger touch
- [ ] No interference with touch input when gamepad/stylus not in use

**Verification**:
- Manual: Pair gamepad, test all axes/buttons. Use stylus, verify pressure response.
- Logcat: Log gamepad state changes, stylus properties

**Rollback**: Revert event_bridge.zig gamepad/stylus additions.

---

### T16: x86_64 Android + Emulator Support

**Specs**: epic-brief.md §Design Decisions (arch targets: aarch64 + x86_64)
**Files**: `build.zig` (modified), `build.zig.zon` (modified), `AndroidManifest.xml` (modified if needed)
**Touch list**: build system, packaging
**Dependencies**: T13
**Effort**: Medium (4-6 hours)
**Parallel group**: D (with T14, T15)

**Description**:
Add x86_64-linux-android target support for Android emulator. Build Dawn for x86_64-android. Produce APKs with both ABIs or separate per-arch APKs.

**Implementation Steps**:

Step 1 — Dawn x86_64 Android build
- Repeat T1 spike for `target_cpu="x64"` Android
- Produce `libdawn.so` for x86_64-linux-android
- Add to build.zig.zon as lazy dependency

Step 2 — Build system support
- Verify `zig build -Dtarget=x86_64-linux-android` compiles
- APK packaging places `.so` in `lib/x86_64/` (not `lib/arm64-v8a/`)

Step 3 — Multi-ABI APK (optional)
- Consider whether to produce:
  - Single APK with both `lib/arm64-v8a/` and `lib/x86_64/` (simpler, larger)
  - Separate APKs per arch (smaller, more complex distribution)
- Start with separate APKs (simpler build logic)

Step 4 — Emulator testing
- Create AVD with x86_64 image + Vulkan support
- Install x86_64 APK
- Verify rendering (emulator Vulkan may have limitations)

**Acceptance Criteria**:
- [ ] `zig build -Dtarget=x86_64-linux-android` produces valid `.so`
- [ ] x86_64 APK installs and runs on emulator
- [ ] glTF viewer renders on emulator (may have reduced quality)
- [ ] aarch64 build unaffected

**Verification**:
- Emulator: Visual rendering of DamagedHelmet
- Commands: Both arch builds complete without errors

**Rollback**: Revert build.zig.zon x86_64 deps, revert build.zig changes.
