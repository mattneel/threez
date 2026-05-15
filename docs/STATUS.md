# Project Status

Last updated: 2026-05-15

## Current State: Source-Built Dawn Baseline

The project has migrated from prebuilt Dawn dependencies to source-built Dawn/Tint through Zig build steps. This is now the canonical build path for all native targets.

### What Changed

**Before:**
- Relied on zgpu's prebuilt Dawn binaries
- Limited to desktop platforms (Linux, Windows, macOS)
- Android support blocked by prebuilt binary incompatibility with NDK

**After:**
- Dawn/Tint source-built via Zig build steps (pinned commit `03e999815027`)
- Unified build path across Linux, Windows, and Android
- Android APK builds using same Dawn source as desktop
- zgpu now used only for windowing (GLFW) on desktop, not for WebGPU

### Architecture Updates

**Renderer/Platform Split:**
- `renderer = dawn`: Native WebGPU implementation through Dawn/Tint (source-built)
- `platform = OS/windowing abstraction`: Linux (GLFW), Windows (GLFW), Android (NativeActivity), macOS (best-effort via GLFW)

**Dawn Integration:**
- Build steps in `build.zig`: `addDawnMriTool`, `addDawnPrepTool`, `addNativeDawnBuild`
- Cached under `.zig-cache/dawn/` with commit-specific directories
- Platform-specific toolchains: hostcc (Linux/Windows), android-ndk (Android), zigcc (fallback)
- Automatic patching for Windows compatibility (MinGW, D3D12)

**Removed Dependencies:**
- No reliance on prebuilt Dawn binaries from zgpu
- Legacy zgpu WebGPU paths are out of scope

### Platform Status

| Platform | Build Status | Runtime Status | Notes |
|----------|-------------|----------------|-------|
| Linux (x86_64) | ✅ Working | ✅ Working | Vulkan backend, primary dev target |
| Windows (x86_64) | ✅ Working | ✅ Working | D3D12 backend, requires VS Build Tools with LLVM |
| Android (ARM64) | ✅ Working | ✅ Working | Vulkan backend, NativeActivity, APK builds |
| macOS | ⚠️ Best-effort | ⚠️ Best-effort | Metal backend, CI-only (no local hardware access) |

### Known Working Features

- QuickJS-NG evaluates bundled Three.js app code
- Browser-ish runtime shims sufficient for glTF viewer bundle
- Native WebGPU calls route through modern Dawn API wrapper
- Unified Dawn-backed runtime across Linux, Windows, Android
- DamagedHelmet glTF example renders on all platforms
- Native FPS overlay (top-right corner)
- Android lifecycle handling (orientation changes, app focus)
- APK asset bundling with `-Dassets` flag

### Build Commands

**Desktop (Linux/Windows):**
```bash
zig build
./zig-out/bin/threez run examples/gltf_viewer/dist/gltf-bundle.js
```

**Android:**
```bash
export ANDROID_HOME=/path/to/android/sdk
export ANDROID_NDK_HOME=/path/to/android/ndk
zig build apk -Dtarget=aarch64-linux-android -Dassets=/path/to/assets
adb install -r zig-out/threez.apk
```

### Smoke Testing

Automated smoke scripts are available in `scripts/`:
- `scripts/smoke.sh` - Desktop smoke (Linux/WSL)
- `scripts/smoke.bat` - Desktop smoke (Windows)
- `scripts/smoke-android.sh` - Android smoke (install, run, logs, screenshot, rotation)

See `docs/SMOKE.md` for complete smoke testing guide.

### Dependencies

**Current Zig Dependencies:**
- `zig-quickjs-ng` (vendored, patched to Zig 0.15.x) - JavaScript runtime
- `zgpu` (windowing/GLFW on desktop only) - Windowing abstraction
- `zignal` - Image decoding (PNG/JPEG)
- `zig-clap` - CLI argument parsing

**Native Dependencies (source-built):**
- Dawn/Tint (commit 03e999815027) - WebGPU implementation
- CMake, Ninja - Build tools for Dawn
- Platform SDKs: Vulkan (Linux), Windows SDK (Windows), Android NDK (Android)

### Outstanding Work

From handoff priorities:
1. ✅ Commit session handoff with timestamp
2. ✅ Add/refine smoke commands for all platforms
3. 🔄 Update project status/roadmap docs (this document)
4. ⏳ Continue isolating/removing remaining zgpu coupling
5. ⏳ Improve Android APK asset staging
6. ⏳ Keep macOS best-effort through CI

### Technical Debt

- **zgpu coupling**: Some public APIs and build surfaces may still reference zgpu patterns that could be simplified
- **Android asset staging**: Currently requires manual `/tmp/threezig-apk-assets` setup
- **macOS verification**: Limited CI coverage, no regular hardware testing

### Migration Notes

For developers updating from older versions:
1. Run `zig build` - Dawn will be source-built automatically on first run
2. Android builds now require `ANDROID_HOME` and `ANDROID_NDK_HOME` environment variables
3. Desktop smoke tests should use the new scripts in `scripts/`
4. Legacy zgpu WebGPU paths are no longer supported

### Future Considerations

- **WebGL compatibility**: Not currently planned, but could be added as a compatibility renderer
- **Additional mobile platforms**: iOS could be explored using similar source-built Dawn approach
- **Dawn updates**: Commit pin can be updated in `build.zig` when needed
- **Performance optimization**: Source-built Dawn allows for target-specific optimizations