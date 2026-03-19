<!-- status: locked -->
<!-- epic-slug: android-port -->
# Epic Brief: Android Port of Threez Runtime

## Problem

Threez currently runs on Linux, macOS, and Windows — all desktop platforms using GLFW for windowing and platform-specific async I/O (io_uring, kqueue, IOCP). There is no mobile support. Android is the largest mobile platform and a natural next target, but it requires fundamentally different windowing (ANativeWindow vs GLFW), input (touch/stylus/gamepad vs keyboard/mouse), app lifecycle (Activity states vs simple run loop), and asset loading (APK bundles vs filesystem paths).

## Who's Affected

| Actor | Description |
|-------|-------------|
| **End user** | Person running the glTF viewer (and future threez apps) on an Android device |
| **App developer** | Developer using threez to build Three.js-based experiences targeting Android |
| **Threez maintainer** | Must keep Android support working alongside desktop platforms |

## Goals

1. Run the existing glTF viewer demo (DamagedHelmet.glb with OrbitControls) on Android API 26+ at interactive frame rates (60 fps target on mid-range hardware).
2. Android becomes a first-class platform: same build system (`zig build`), same JavaScript demo code, same WebGPU pipeline via Dawn-over-Vulkan.
3. Touch, gamepad, and stylus input mapped to DOM-compatible events so existing Three.js OrbitControls work without modification.
4. Assets loadable from both APK `assets/` directory and device storage.
5. App lifecycle handled correctly: pause/resume without crashing, proper GPU resource management across lifecycle transitions.

## Non-Goals

- iOS/iPadOS support (separate epic).
- Google Play Store publishing, signing, or distribution tooling.
- Android UI widgets, Java/Kotlin interop, or Android SDK services (notifications, location, etc).
- Rewriting Three.js demos to be Android-specific — the same JS should run everywhere.
- Supporting Android TV or Wear OS form factors.
- Vulkan directly (bypassing Dawn/WebGPU).

## Actors

| Actor | Interaction |
|-------|-------------|
| **NativeActivity** | Android OS creates/destroys the native activity; delivers lifecycle + input events |
| **ANativeWindow** | Provides the rendering surface; passed to Dawn for Vulkan swapchain creation |
| **AAssetManager** | Reads files bundled inside the APK |
| **AInputQueue** | Delivers touch, stylus, key, and gamepad events |
| **Dawn (Vulkan backend)** | Creates VkInstance + VkSurface from ANativeWindow; renders via WebGPU API |
| **QuickJS** | Executes Three.js + user JavaScript; unchanged from desktop |

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| App model | NativeActivity (pure native) | No Java/Kotlin needed. Simplest FFI. Matches threez's "everything in Zig" philosophy. |
| GPU backend | Dawn over Vulkan | Keeps WebGPU abstraction. Three.js code unchanged. Dawn already has Android/Vulkan support. |
| Windowing | ANativeWindow via `android_native_app_glue` | Standard NDK pattern for native apps. Provides lifecycle + input callbacks. |
| Async I/O | io_uring if kernel supports it, else epoll fallback | Android 12+ kernels have io_uring. Older devices (API 26-30) need epoll. |
| Asset loading | AAssetManager for APK assets, `std.fs` for device storage | Both paths needed: self-contained APK + developer flexibility. |
| Input mapping | Touch → PointerEvent, Gamepad → GamepadEvent, Stylus → PointerEvent with pressure | Maps to existing DOM event model. OrbitControls already handles PointerEvent. |
| Build output | APK via Zig cross-compile + bundled `aapt2`/`zipalign` | Keep everything in `zig build` — no Gradle dependency. |
| Arch targets | aarch64 + x86_64 | Real devices + emulator. Doubles binary matrix but improves dev experience. |
| Min API level | 26 (Android 8.0) | ~95% device coverage. Vulkan 1.0 guaranteed. |
| Dawn binaries | Research prebuilts first, spike build if needed | Dawn Android .so is the critical path — everything else is straightforward after it lands. |

## Success Criteria

- `zig build -Dtarget=aarch64-linux-android` and `zig build -Dtarget=x86_64-linux-android` both produce valid, installable APKs.
- DamagedHelmet.glb renders correctly on a physical Android device (API 26+).
- OrbitControls responds to touch (rotate), pinch (zoom), and two-finger drag (pan).
- Gamepad connected via Bluetooth controls the camera.
- Stylus input provides pressure data in PointerEvent.
- App survives home-button → resume cycle without crash or GPU corruption.
- Frame rate >= 30 fps on mid-range device (e.g., Pixel 4a equivalent) at 1080p.
- All existing desktop tests continue to pass (no regressions).

## Constraints

- **No Gradle/Android Studio**: Build must stay within `zig build`. APK assembly via command-line tools only.
- **Zig 0.14+**: Must work with current Zig version used by the project.
- **Dawn Android binaries**: Need to build or source Dawn `.so` for `aarch64-linux-android`. Dawn's build system (GN/CMake) supports Android but we need to integrate this into the Zig build or provide prebuilts.
- **NDK sysroot**: Zig can target Android but needs NDK headers for `ANativeWindow`, `AAssetManager`, etc. Zig ships with musl for linux-android targets but not bionic headers for NDK APIs.
- **No GLFW on Android**: zglfw dependency must be made optional / platform-conditional.

## Assumptions & Unknowns

| Item | Type | How to Validate | Owner |
|------|------|-----------------|-------|
| Dawn has working Android/Vulkan support in the version we use (via zgpu) | Assumption | Build Dawn for Android, create surface from ANativeWindow | |
| Zig can cross-compile to aarch64-linux-android with NDK sysroot | Assumption | Try `zig build -Dtarget=aarch64-linux-android` with NDK paths | |
| io_uring is available on target device kernels | Unknown | Runtime check; if unavailable, fall back to epoll | |
| QuickJS-NG compiles cleanly for Android | Assumption | Cross-compile quickjs-ng for aarch64-linux-android | |
| `android_native_app_glue` can be compiled from Zig (it's a small C file) | Assumption | Compile `android_native_app_glue.c` as part of build | |
| APK can be assembled without Gradle using aapt2 + zipalign + apksigner | Assumption | Prototype APK assembly in build.zig | |

## Kill Criteria / Stop Conditions

- **Dawn cannot create a VkSurface from ANativeWindow** in the zgpu version we depend on — would require forking or replacing the GPU backend.
- **Zig cannot produce a working `.so` for android** — fundamental toolchain gap.
- **QuickJS-NG crashes on Android** due to platform-specific memory/threading assumptions — would need upstream fixes.
- **APK assembly without Gradle proves unreliable** across Android versions — may need to accept Gradle as a build dependency.

## Context

Threez already has a clean platform abstraction pattern: compile-time `switch (builtin.os.tag)` dispatches I/O backends, and the window/event layers are isolated in `window.zig` and `event_bridge.zig`. Adding Android means adding new cases to these switches and providing Android-specific implementations behind the same interfaces. The GPU bridge, handle table, descriptor translator, JS engine, and bootstrap layers are platform-agnostic and should work unchanged.

The existing platform progression (Linux → macOS → Windows) established patterns that Android can follow. The main new complexity is the activity lifecycle model and APK packaging, which have no desktop equivalent.

## Definitions

- **NativeActivity**: An Android Activity subclass provided by the NDK that runs entirely in native code (C/C++/Zig). No Java required.
- **ANativeWindow**: Android's native window handle, analogous to HWND (Windows) or X11 Window.
- **AAssetManager**: NDK API to read files from the APK's `assets/` directory without extracting them.
- **APK**: Android Package — a ZIP file with a specific layout containing the app binary, assets, manifest, and signatures.
- **Dawn-over-Vulkan**: Dawn's WebGPU implementation using Vulkan as the underlying graphics API (as opposed to Metal on macOS or D3D12 on Windows).
