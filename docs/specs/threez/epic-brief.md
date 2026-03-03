

# Epic Brief: threez

## Problem

Three.js is the dominant 3D graphics library on the web. Its new WebGPU renderer (r171+) and TSL (Three Shading Language) represent a modern, high-performance rendering pipeline. But shipping a Three.js project as a native desktop app today means:

- **Electron**: 200MB+ binary, full Chromium overhead, memory-hungry, slow startup
- **Tauri**: Lighter, but still a webview — WebGPU support varies by platform webview, no guaranteed GPU path
- **Headless Chrome**: Full browser engine, defeats the purpose

There is no way to take a standard Three.js WebGPU project and run it natively with direct GPU access, small binary size, and fast startup. The polyfill gap between "browser JS environment" and "native GPU rendering" has never been bridged for WebGPU.

Nobody has done this before. This is novel territory.

## Who's Affected

**Three.js developers** who want to ship their web-bound projects natively without Electron or Tauri. They write modern Three.js (ES2023+, TSL shaders, WebGPURenderer), bundle with esbuild, point threez at the bundle, and get a native binary.

## Actors


| Actor                  | Description                                                                      |
| ---------------------- | -------------------------------------------------------------------------------- |
| **App developer**      | Writes Three.js WebGPU code, bundles with esbuild, uses threez to run natively   |
| **End user**           | Runs the native app — expects a window, mouse/keyboard input, GPU-accelerated 3D |
| **QuickJS-NG runtime** | Executes the bundled JS — needs Web API polyfills to satisfy Three.js            |
| **zgpu/Dawn**          | Native WebGPU implementation — receives forwarded calls from JS polyfill layer   |
| **Host OS**            | Windowing (GLFW via zgpu), input events, filesystem, GPU drivers                 |


## Goals

1. Run unmodified Three.js WebGPU code (TSL shaders, WebGPURenderer, standard scene graph) in a native window
2. Forward WebGPU API calls from JS directly to Dawn via zgpu — real GPU, not software rendering
3. Support OrbitControls and mouse/keyboard input
4. Produce small, fast-starting native binaries (target: <20MB, <1s startup)
5. Cross-platform: Linux, macOS, Windows (via zgpu's Dawn backend: Vulkan, Metal, DX12)
6. No Electron, no Tauri, no webview, no browser engine

## Non-Goals

- Full browser compatibility (no layout engine, no CSS, no full DOM)
- Node.js/npm ecosystem compatibility (user bundles with esbuild, no node_modules at runtime)
- Audio, video, or media APIs (future epic)
- Networking beyond fetch (no WebSocket, WebRTC — future epic)
- Mobile platforms (future epic)
- Hot reload / dev server (future epic)
- Three.js Inspector/GUI polyfill (lil-gui depends on DOM/CSS — out of scope for M1)

## Design Decisions


| Decision          | Choice                                                                    | Rationale                                                                                                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| JS engine         | QuickJS-NG via mitchellh/zig-quickjs-ng (vendored, patched to Zig 0.15.x) | ES2023+, tiny footprint, 96% API coverage in Zig bindings, hand-written idiomatic wrappers                                                                                                                         |
| GPU backend       | zgpu (Dawn), targets Zig 0.15.1+                                          | Native WebGPU impl, cross-platform (Vulkan/Metal/DX12), GLFW windowing included, prebuilt Dawn binaries                                                                                                            |
| Zig version       | 0.15.2 (latest stable)                                                    | zgpu requires 0.15.1+; zig-quickjs-ng targets 0.14 but migration is tractable                                                                                                                                      |
| Async model       | Cooperative single-thread event loop                                      | Poll-based: QuickJS job queue + I/O completion callbacks. Like txiki.js. Single JS thread, Zig handles async I/O and posts results back as resolved promises                                                       |
| Polyfill strategy | Broad web-compat layer, prioritizing WebGPU + TSL path                    | navigator.gpu → zgpu, Canvas shim, fetch → local FS + HTTP, rAF → GLFW frame loop, Image → zignal, performance.now, TextEncoder/Decoder, console, setTimeout/setInterval                                           |
| DOM events        | General EventTarget implementation                                        | Full EventTarget shim on canvas/window — not just minimal. GLFW callbacks → synthetic DOM events (pointerdown, pointermove, wheel, resize, keydown, etc.). Pays for itself as more controls/interactions are added |
| JS bundling       | esbuild (user-side)                                                       | User bundles their Three.js project into a single ESM file; threez consumes the bundle                                                                                                                             |
| Image decoding    | zignal (PNG/JPEG)                                                         | Zero-dependency Zig library, targets 0.15-dev, MIT. HDR deferred to M2 (swap demo env map to LDR JPEG for M1)                                                                                                      |
| Fetch             | Local filesystem + HTTP                                                   | Local paths by default; optional HTTP via Zig std.http.Client for remote assets. Both async via event loop                                                                                                         |
| Windowing         | GLFW via zgpu                                                             | Already bundled, cross-platform, handles input                                                                                                                                                                     |
| Shader pipeline   | TSL → WGSL (in JS) → Dawn                                                 | Zero translation needed — WGSL is Dawn's native shader language                                                                                                                                                    |
| Module system     | Single-bundle ESM eval                                                    | QuickJS-NG supports ES modules; esbuild resolves all imports at bundle time                                                                                                                                        |
| Distribution      | CLI + library                                                             | CLI: `threez run bundle.js` (zig-clap for arg parsing). Library: import as Zig dependency, embed JS at compile time. Both modes                                                                                    |
| License           | MIT                                                                       | All deps are MIT or BSD-3 compatible                                                                                                                                                                               |


## Milestone 1 Target

The **webgpu_loader_gltf** Three.js demo running in a native window with OrbitControls. Modified to use LDR JPEG environment map (swap UltraHDRLoader for standard TextureLoader) since zignal doesn't support UltraHDR yet. This exercises:

- WebGPURenderer with async init
- GLTFLoader (binary .glb parsing, PBR materials)
- OrbitControls (mouse input: drag, scroll, damping)
- AnimationMixer (skeletal animation playback)
- PerspectiveCamera, Scene, Box3 (bounding box math)
- fetch() for loading model index JSON + binary assets (local + remote)
- requestAnimationFrame via setAnimationLoop
- window resize handling
- DOM EventTarget for input events

## Success Criteria

- webgpu_loader_gltf demo (LDR variant) runs in a native window: DamagedHelmet model, environment lighting, orbit controls, animations
- GPU-accelerated rendering via Dawn (not software fallback)
- `zig build run` produces a working binary
- `threez run bundle.js` CLI mode works
- Binary size under 20MB (excluding user JS/assets)
- Startup to first frame under 1 second
- Works on at least Linux (primary dev target), with macOS/Windows as stretch

## Out of Scope

- Package manager / dependency resolution for JS (user bundles with esbuild)
- DevTools, inspector, debugger
- Multi-window support
- Accessibility APIs
- Print/PDF/screenshot export
- Plugin system
- lil-gui / Three.js Inspector (DOM/CSS dependent)
- UltraHDR / HDR / EXR image formats (M2)

## Context

### Prior Art


| Project                      | What it proves                                      | What it lacks                    |
| ---------------------------- | --------------------------------------------------- | -------------------------------- |
| **txiki.js**                 | QuickJS-NG + cooperative event loop + Web APIs work | Zero graphics                    |
| **Athena PS2**               | QuickJS + native rendering pipeline works           | Not WebGPU, not Zig              |
| **Mach Engine**              | Zig + Dawn/WebGPU is viable for native graphics     | No JS, no Three.js               |
| **headless-gl + Three.js**   | Three.js can run outside browser                    | WebGL only, CPU-based, no WebGPU |
| **mitchellh/zig-quickjs-ng** | Zig embeds QuickJS-NG cleanly with idiomatic API    | No graphics integration          |


### Key Technical Insight

The TSL → WGSL → Dawn pipeline is the golden path. Three.js compiles TSL shaders to WGSL inside JS. Dawn consumes WGSL natively. Zero custom shader translation needed. The main work is bridging the WebGPU API surface (GPUDevice, GPUBuffer, GPURenderPipeline, etc.) and the supporting Web APIs.

### Critical Risk: The Polyfill Surface

Three.js WebGPURenderer assumes a browser. The webgpu_loader_gltf demo touches:


| Web API                                             | Native Implementation                                     |
| --------------------------------------------------- | --------------------------------------------------------- |
| `navigator.gpu`                                     | → zgpu/Dawn adapter/device enumeration                    |
| `HTMLCanvasElement` / `getContext('webgpu')`        | → zgpu surface + GLFW window                              |
| `GPUDevice`, `GPUBuffer`, `GPURenderPipeline`, etc. | → zgpu WebGPU API forwarding                              |
| `requestAnimationFrame` / `setAnimationLoop`        | → GLFW frame loop                                         |
| `fetch()`                                           | → local FS read or Zig HTTP client (async via event loop) |
| `Image` / `createImageBitmap`                       | → zignal PNG/JPEG decode                                  |
| `window.innerWidth/Height`, `devicePixelRatio`      | → GLFW window queries                                     |
| `window.addEventListener(...)`                      | → general EventTarget + GLFW callback bridge              |
| `pointer/mouse/wheel/keyboard events`               | → GLFW input → synthetic DOM events                       |
| `performance.now()`                                 | → `std.time.nanoTimestamp()`                              |
| `TextEncoder` / `TextDecoder`                       | → direct UTF-8 (Zig strings are UTF-8)                    |
| `console.log/warn/error`                            | → stderr/stdout                                           |
| `setTimeout` / `setInterval`                        | → event loop timer queue                                  |
| `document.createElement` / `body.appendChild`       | → minimal DOM shim (no-op or canvas stub)                 |


Strategy: incremental. Trace what the target demo actually calls at runtime, implement those paths first, expand as needed. Many APIs only need the subset Three.js uses, not full spec compliance.

### Dependency Matrix


| Dependency      | Version  | Zig Compat                                           | License |
| --------------- | -------- | ---------------------------------------------------- | ------- |
| QuickJS-NG      | v0.11+   | via mitchellh bindings (vendored, patched 0.14→0.15) | MIT     |
| zgpu            | latest   | 0.15.1+                                              | MIT     |
| zignal          | v0.9.1   | 0.15-dev                                             | MIT     |
| zig-clap        | latest   | 0.15.x                                               | MIT     |
| Dawn (via zgpu) | prebuilt | N/A (C ABI)                                          | BSD-3   |


