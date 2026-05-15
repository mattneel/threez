# three.zig session handoff

Last updated: 2026-05-15 19:14 -04:00

**Staleness warning**: This document reflects the project state at the timestamp above. If significant work has been done since this date, verify current status with git log and actual smoke tests before relying on this information.

## Current project direction

The project is now branded as **three.zig** / **ThreeZig**: a native runtime for running Three.js WebGPURenderer code through QuickJS and Dawn/WGPU, without a browser or Emscripten/Web target.

Renderer and platform are intentionally split:

- `renderer = dawn`: native WebGPU implementation through Dawn/Tint.
- `platform = OS/windowing abstraction`: Linux, Windows, Android, and best-effort macOS.

Legacy compatibility paths are out of scope for now. GL/WebGL2 may become a future compatibility renderer, but it is not part of the current sprint.

## Current implementation state

The repo has moved away from trusting old prebuilt/static WebGPU dependencies. Dawn/Tint are now source-built through Zig build steps and used consistently across native targets.

Known working pieces:

- QuickJS-NG evaluates bundled Three.js app code.
- Browser-ish runtime shims are sufficient for the current glTF viewer bundle.
- Native WebGPU calls route through the modern Dawn API wrapper.
- Linux and Windows desktop paths were unified under the same Dawn-backed runtime.
- Android builds an APK using the same Dawn source-build path.
- The DamagedHelmet glTF example bundle is the real smoke target, not a trivial version check.
- A native FPS overlay was added and renders in the top-right.

Recent commits before this handoff:

- `8ed7a22 Add native FPS overlay`
- `92f9f79 Add three.zig README and branding`
- `27e413f Remove Android SDK license cache`
- `a5e2745 Remove vendored Android SDK platform`
- `0c3fdca Fix real glTF viewer smoke on native targets`
- `237c183 Unify native Dawn integration across platforms`

At last known check, `master` was pushed to `origin/master` and the working tree was clean before this handoff file was added.

## Android smoke result

Phone was connected from WSL2 through Windows `adb.exe`:

```sh
/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
```

Device was authorized and visible:

```text
3C15AT00DT500000 device
```

Useful Android environment paths:

```sh
export ANDROID_HOME=/home/autark/android/sdk
export ANDROID_NDK_HOME=/home/autark/android/android-ndk-r27c
```

SDK/NDK pieces observed:

- `/home/autark/android/sdk/build-tools/35.0.0/aapt2`
- `/home/autark/android/sdk/build-tools/35.0.0/apksigner`
- `/home/autark/android/sdk/platforms/android-35/android.jar`
- `/home/autark/android/android-ndk-r27c`

APK asset staging used:

```sh
/tmp/threezig-apk-assets/app.js
/tmp/threezig-apk-assets/assets/DamagedHelmet.glb
```

Build command that succeeded:

```sh
ANDROID_HOME=/home/autark/android/sdk \
ANDROID_NDK_HOME=/home/autark/android/android-ndk-r27c \
zig build apk -Dtarget=aarch64-linux-android -Dassets=/tmp/threezig-apk-assets
```

Install command that succeeded:

```sh
/mnt/c/Users/requi/Downloads/platform-tools/adb.exe install -r zig-out/threez.apk
```

Android package/activity:

```text
package: com.threez.gltfviewer
activity: android.app.NativeActivity
native library: threez
```

Launch command:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
PKG=com.threez.gltfviewer
$ADB logcat -c
$ADB shell am force-stop "$PKG"
$ADB shell monkey -p "$PKG" 1
```

Observed good app logs:

```text
threez android_main started
AAssetManager registered
INIT_WINDOW: 1272x2772
creating GraphicsContext for ANativeWindow 1272x2772
surface configured: format=22 presentMode=1 alphaMode=4 size=1272x2772
Dawn GPU surface created
JS runtime initialized
Loaded app.js (2492973 bytes), evaluating...
DamagedHelmet loaded successfully
User script evaluated
GAINED_FOCUS
```

Screenshot confirmed:

- DamagedHelmet rendered on-device.
- Native FPS overlay visible in the top-right as `FPS 60`.

Rotation smoke:

- Saved device rotation settings.
- Forced landscape, waited, checked PID.
- Forced portrait, waited, checked PID.
- Restored prior rotation settings.
- App PID stayed alive through both orientation changes.
- Logs showed two `CONFIG_CHANGED` events.
- Android crash buffer was empty.

Only notable Android log:

```text
Dawn Warning: maxDynamicUniformBuffersPerPipelineLayout artificially reduced from 32 to 16 to fit dynamic offset allocation limit.
```

This warning was nonfatal during smoke.

## Desktop smoke expectations

The user specifically cares that desktop smoke runs the real glTF example bundle, not a simple version check.

Linux and Windows were previously smoked with the DamagedHelmet glTF bundle after the unified Dawn path landed. Windows build was also confirmed by the user after the FPS overlay commit.

Next session should avoid claiming desktop is still good unless it actually re-runs the glTF bundle. If asked to smoke desktop, run the real viewer bundle and report concrete output/behavior.

## Important cleanup already done

Android SDK artifacts were removed from the repo:

- `platforms/android-33` should not be tracked.
- `licenses/` was identified as Android SDK state and removed from the repo.

Do not re-vendor Android SDK platforms/licenses into this repository.

## Current handoff priorities

Recommended next work, in order:

1. Commit this handoff file if the user wants the handoff preserved in git.
2. Add or refine documented smoke commands/scripts so Linux, Windows, and Android all exercise the same glTF viewer bundle.
3. Update project status/roadmap docs now that the source-built Dawn path is the baseline.
4. Continue isolating/removing remaining `zgpu` coupling if any remains in public APIs or build surfaces.
5. Improve Android APK asset staging so examples are less dependent on manual `/tmp/threezig-apk-assets` setup.
6. Keep macOS best-effort through CI unless the user provides hardware access.

## User preferences and constraints

The user prioritizes:

1. Correctness.
2. Performance.
3. Developer experience.

Other explicit preferences:

- Prefer source-built Dawn/Tint over downloaded static dependencies.
- Keep everything possible inside Zig build steps.
- Do not preserve legacy `zgpu`/old WGPU paths for compatibility.
- No Emscripten/Web target is needed for this project direction.
- The real smoke test is the glTF viewer bundle.
- Android is the active porting pressure point.
- macOS is best-effort because the user cannot test it locally.

## Useful commands

Targeted Android app logs:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
$ADB logcat -d -v time -s threez:D threez.zig:D threez.js:D Dawn:W AndroidRuntime:E DEBUG:E
```

Android crash buffer:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
$ADB logcat -b crash -d -v time
```

Android screenshot:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
$ADB exec-out screencap -p > /tmp/threezig-android-smoke.png
```

Android PID check:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
$ADB shell pidof com.threez.gltfviewer
```

Minimal Android rotation smoke:

```sh
ADB=/mnt/c/Users/requi/Downloads/platform-tools/adb.exe
PKG=com.threez.gltfviewer
ACCEL=$($ADB shell settings get system accelerometer_rotation | tr -d '\r')
ROT=$($ADB shell settings get system user_rotation | tr -d '\r')
$ADB logcat -c
$ADB shell settings put system accelerometer_rotation 0
$ADB shell settings put system user_rotation 1
sleep 3
$ADB shell pidof "$PKG"
$ADB shell settings put system user_rotation 0
sleep 3
$ADB shell pidof "$PKG"
if [ "$ACCEL" = "null" ]; then $ADB shell settings delete system accelerometer_rotation >/dev/null 2>&1 || true; else $ADB shell settings put system accelerometer_rotation "$ACCEL"; fi
if [ "$ROT" = "null" ]; then $ADB shell settings delete system user_rotation >/dev/null 2>&1 || true; else $ADB shell settings put system user_rotation "$ROT"; fi
$ADB logcat -d -v time -s threez:D threez.zig:D threez.js:D Dawn:W AndroidRuntime:E DEBUG:E
$ADB logcat -b crash -d -v time
```

## Caveats for the next session

This handoff is based on observed command output during the previous session. If precise repo state matters, check git status before committing or pushing. Do not assume generated Android build outputs or `/tmp/threezig-apk-assets` still exist after a restart.
