# three.zig

`three.zig` is a native runtime for Three.js `WebGPURenderer` applications.
It runs bundled JavaScript in QuickJS-NG, provides the browser APIs that
Three.js expects, and forwards WebGPU calls to native Dawn.

The goal is to let existing Three.js WebGPU projects run as native apps without
Electron, a browser shell, or a WebView.

The project is still early. The current executable and Zig import name are
still `threez` while the public project name moves to `three.zig`.

## What Works Today

- Native desktop windowing on Linux and Windows.
- Android APK builds using `NativeActivity`.
- Source-built Dawn/Tint for native targets (unified across all platforms).
- QuickJS-NG JavaScript execution with a browser-like runtime surface.
- Three.js `WebGPURenderer` enough to run the glTF viewer example.
- Built-in top-right FPS overlay for runtime smoke testing.
- Local, `blob:`, `data:`, and basic HTTP fetch paths.
- Image loading and `createImageBitmap` paths used by the included examples.

See [docs/STATUS.md](docs/STATUS.md) for detailed project status and architecture.

Known limits:

- This is a WebGPU runtime, not a browser. DOM support is intentionally minimal.
- `WebGLRenderer` is out of scope for now.
- macOS is best-effort through CI until there is regular local hardware testing.
- The WebGPU and browser-polyfill surface grows by running real Three.js apps and filling gaps.

## Quick Start

Build the runtime:

```sh
zig build
```

Run the included glTF viewer:

```sh
./zig-out/bin/threez run examples/gltf_viewer/dist/gltf-bundle.js
```

Or through the Zig build runner:

```sh
zig build run -- run examples/gltf_viewer/dist/gltf-bundle.js
```

The expected smoke signal is:

```text
DamagedHelmet loaded successfully
```

## Running Existing Three.js Code

`three.zig` expects a single bundled JavaScript file. Bundle your app and its
dependencies with a tool like esbuild, then pass the bundle to `threez run`.

Your app should use `WebGPURenderer`:

```js
import * as THREE from "three";
import { WebGPURenderer } from "three/webgpu";

const renderer = new WebGPURenderer();
await renderer.init();

document.body.appendChild(renderer.domElement);
renderer.setAnimationLoop(() => {
  renderer.render(scene, camera);
});
```

Bundle it as an IIFE or otherwise self-contained script:

```js
// esbuild.config.mjs
import * as esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["src/main.js"],
  outfile: "dist/app-bundle.js",
  bundle: true,
  format: "iife",
  platform: "neutral",
  target: "es2020",
});
```

Run it:

```sh
threez run dist/app-bundle.js
```

Relative asset loads are resolved from the current working directory first,
then relative to the bundle directory, then one level above the bundle directory.
For a separate asset root, pass `--assets`:

```sh
threez run --assets ./public dist/app-bundle.js
```

## Creating A New App

Start with a normal Three.js project layout:

```text
my-app/
  package.json
  src/main.js
  public/
  esbuild.config.mjs
```

Install the JavaScript-side dependencies:

```sh
npm install three
npm install --save-dev esbuild
```

Use the same bundling shape as the examples: `bundle: true`, `format: "iife"`,
`platform: "neutral"`, and `target: "es2020"` or newer.

Then run:

```sh
npm run build
threez run --assets public dist/app-bundle.js
```

The example in `examples/gltf_viewer` is the best template for a real app with
models, textures, async loading, orbit controls, and Three.js WebGPU materials.

## CLI

```text
threez run [options] <script.js>
```

Options:

```text
-W, --width <u32>        Window width (default: 1280)
-H, --height <u32>       Window height (default: 720)
-t, --title <str>        Window title (default: "three.zig")
-a, --assets <str>       Assets directory for fetch() resolution
-m, --max-handles <u32>  Max GPU handle table capacity (default: 65536)
    --strict             Abort on JavaScript exceptions
-h, --help               Display help
```

## Building From Source

Required everywhere:

- Zig `0.15.2`
- CMake
- Ninja
- a C/C++ toolchain
- a GPU and driver that support the target native backend

Linux uses Dawn's Vulkan backend:

```sh
sudo apt install cmake ninja-build build-essential llvm libx11-xcb-dev libx11-dev libxcb1-dev libvulkan-dev
zig build
```

Windows uses Dawn's D3D12 backend. Build from a Windows filesystem checkout,
not a WSL UNC path:

```powershell
zig build
zig build run -- run examples\gltf_viewer\dist\gltf-bundle.js
```

You need CMake, Ninja, Visual Studio Build Tools with LLVM/Clang, and the
Windows SDK installed.

Android builds an APK:

```sh
export ANDROID_HOME=/path/to/android/sdk
export ANDROID_NDK_HOME=/path/to/android/ndk

zig build apk -Dtarget=aarch64-linux-android -Dassets=/absolute/path/to/assets
```

The current Android build expects SDK build-tools `35.0.0`, platform
`android-35`, and an NDK with the Android CMake toolchain file. The APK output
is installed to `zig-out/threez.apk`.

The Android runtime loads `app.js` from the APK asset root. To package the glTF
example:

```sh
rm -rf /tmp/threezig-apk-assets
mkdir -p /tmp/threezig-apk-assets/assets
cp examples/gltf_viewer/dist/gltf-bundle.js /tmp/threezig-apk-assets/app.js
cp examples/gltf_viewer/assets/DamagedHelmet.glb /tmp/threezig-apk-assets/assets/

zig build apk -Dtarget=aarch64-linux-android -Dassets=/tmp/threezig-apk-assets
```

## Smoke Testing

For platform-specific smoke testing instructions and automated scripts, see [docs/SMOKE.md](docs/SMOKE.md).

Quick smoke commands:
- Desktop (Linux/WSL): `./scripts/smoke.sh`
- Desktop (Windows): `scripts\smoke.bat`
- Android: `./scripts/smoke-android.sh full`

All smoke tests use the same glTF viewer bundle (DamagedHelmet) to verify the runtime works correctly.

## Contributor Notes

The active native renderer path is source-built Dawn/Tint through `build.zig`.
The pinned Dawn revision (commit 03e999815027) lives in `build.zig`, and build
outputs are cached under `.zig-cache/dawn/`. This unified build path works across
Linux, Windows, and Android.

See [docs/STATUS.md](docs/STATUS.md) for detailed architecture and migration notes.

High-level layout:

```text
src/
  dawn/             current Dawn/WebGPU wrapper
  ts/bootstrap/     TypeScript browser/WebGPU polyfills
  ts/dist/          generated bootstrap used by the runtime
  gpu_bridge.zig    JS WebGPU object bridge to native handles
  runtime.zig       desktop runtime loop
  android_*.zig     Android runtime, lifecycle, and window glue
examples/
  gltf_viewer/      primary Three.js WebGPU smoke app
  threejs_basic/    smaller renderer/bootstrap examples
docs/specs/         design notes and implementation history
```

When changing the TypeScript bootstrap, update the generated
`src/ts/dist/bootstrap.js` as part of the same change. The native runtime embeds
the generated file.

Useful checks:

```sh
zig build
timeout 20s ./zig-out/bin/threez run examples/gltf_viewer/dist/gltf-bundle.js
zig build test
```

For Android:

```sh
zig build apk -Dtarget=aarch64-linux-android -Dassets=/tmp/threezig-apk-assets
adb install -r zig-out/threez.apk
```

Do not commit local SDK installs or build outputs. `.gitignore` excludes
`.zig-cache/`, `zig-out/`, Android SDK `platforms/`, `build-tools/`, and
`licenses/`.
