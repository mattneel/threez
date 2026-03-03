<!-- status: locked -->
# Three.js Integration Gap Analysis

## Three.js Version
- Version: 0.183.2
- Git commit: 1939c35f2d92a4c870568da011aab54dabdfdd30
- Registry: https://registry.npmjs.org/three/-/three-0.183.2.tgz
- Date: 2026-03-02

## Analysis Method

Static analysis of Three.js 0.183.2 source code in `node_modules/three/src/`, tracing
the WebGPURenderer initialization path and all commonly-used code paths (scene graph,
geometry, materials, loaders, animation loop). Every reference to browser/DOM/Web APIs
was cross-referenced against the existing threez polyfills in `src/polyfills/` (Zig) and
`src/ts/bootstrap/` (TypeScript).

### Key files analyzed
- `renderers/webgpu/WebGPURenderer.js` -- top-level renderer class
- `renderers/webgpu/WebGPUBackend.js` -- WebGPU backend init, context setup, all GPU ops
- `renderers/common/Renderer.js` -- base renderer, canvas target, animation loop
- `renderers/common/Backend.js` -- getDomElement, createCanvasElement
- `renderers/common/Animation.js` -- requestAnimationFrame loop via `self`
- `renderers/common/CanvasTarget.js` -- domElement.width/height/style
- `renderers/webgpu/utils/WebGPUConstants.js` -- GPUShaderStage, GPUTextureUsage, etc.
- `renderers/webgpu/utils/WebGPUUtils.js` -- navigator.gpu.getPreferredCanvasFormat()
- `utils.js` -- createElementNS (document.createElementNS), createCanvasElement
- `loaders/FileLoader.js` -- fetch, Request, Headers, AbortController, ReadableStream
- `loaders/ImageLoader.js` -- createElementNS('img'), Image.src/onload/onerror
- `loaders/ImageBitmapLoader.js` -- fetch, createImageBitmap, AbortController
- `loaders/Cache.js` -- new URL()
- `core/EventDispatcher.js` -- Three.js own event system (no DOM dependency)
- `core/Timer.js` -- performance.now(), document.hidden, visibilitychange
- `core/Clock.js` -- performance.now()
- `Three.Core.js` -- window.__THREE__, CustomEvent
- `audio/AudioContext.js` -- window.AudioContext

### esbuild bundle configuration
```
entryPoints: ["test-init.js"]
bundle: true
format: "iife"
platform: "neutral"
target: "es2020"
outfile: "dist/test-bundle.js"
```
Bundle size: ~87K lines, ~3.8MB unminified (includes all of Three.js + WebGPU renderer + node system).

## Gaps

### Critical (blocks renderer init)

These APIs are called during `new WebGPURenderer()` -> `renderer.init()` and will
cause exceptions or undefined behavior if missing.

| API | Where Used | Current Status | Notes |
|-----|-----------|----------------|-------|
| `document.createElementNS()` | `utils.js:133` via `createCanvasElement()` via `Backend.getDomElement()` | **Partial** -- DocumentStub.createElementNS exists but returns generic stub, not a proper canvas | Three.js calls `createElementNS('http://www.w3.org/1999/xhtml', 'canvas')` to create the domElement if no `canvas` parameter is passed. Our stub returns a generic element, not a CanvasStub. Fix: pass `canvas` option to renderer constructor OR return CanvasStub from createElementNS for 'canvas' tag. |
| `navigator.gpu.requestAdapter()` | `WebGPUBackend.js:183` | **Implemented** -- GPU.requestAdapter() in gpu.ts | Works but Three.js passes `{ powerPreference, featureLevel: 'compatibility' }`. Our polyfill ignores options. Needs `featureLevel` support or at minimum must not crash on unknown options. |
| `adapter.features.has()` | `WebGPUBackend.js:199` | **Missing** -- GPUAdapter.features returns empty Set | Three.js iterates all GPUFeatureName values and checks `adapter.features.has(name)` to build `requiredFeatures`. Must return a Set with at least the features Dawn/zgpu supports. |
| `adapter.requestDevice()` | `WebGPUBackend.js:212` | **Implemented** -- GPUAdapter.requestDevice() in gpu.ts | Three.js passes `{ requiredFeatures, requiredLimits }`. Our polyfill ignores the descriptor. Should be fine but may need validation. |
| `device.features.has()` | `WebGPUBackend.js:220` | **Missing** -- GPUDevice has no `features` property | Three.js checks `device.features.has('core-features-and-limits')` to determine compatibility mode. Must add `features: Set<string>` to GPUDevice. |
| `device.lost` (Promise) | `WebGPUBackend.js:228` | **Missing** -- GPUDevice has no `lost` property | Three.js calls `device.lost.then(...)`. Must add `lost: Promise<GPUDeviceLostInfo>` to GPUDevice (can be a never-resolving Promise). |
| `device.limits` | `WebGPUBackend.js:1440`, `WGSLNodeBuilder.js:2290` | **Missing** -- GPUDevice has no `limits` property | Three.js reads `device.limits.maxComputeWorkgroupsPerDimension` and `device.limits.maxUniformBufferBindingSize`. Must add `limits: Record<string, number>` with Dawn defaults. |
| `navigator.gpu.getPreferredCanvasFormat()` | `WebGPUUtils.js:233` | **Implemented** -- GPU.getPreferredCanvasFormat() returns "bgra8unorm" | Works correctly. |
| `GPUTextureUsage` constants | `WebGPUBackend.js:288` | **Missing** -- not on globalThis | Three.js uses `GPUTextureUsage.RENDER_ATTACHMENT \| GPUTextureUsage.COPY_SRC`. These are native WebGPU globals. Must be defined on globalThis or self. |
| `GPUBufferUsage` constants | `WebGPUBackend.js:1035+` | **Missing** -- not on globalThis | Same as GPUTextureUsage. Three.js uses `GPUBufferUsage.INDEX`, `VERTEX`, `STORAGE`, `UNIFORM`, `COPY_SRC`, `COPY_DST`, `MAP_READ`, `QUERY_RESOLVE`, `INDIRECT`. |
| `GPUMapMode` constants | `WebGPUBackend.js:1128` | **Missing** -- not on globalThis | Three.js uses `GPUMapMode.READ`. |
| `GPUShaderStage` constants | `WebGPUConstants.js:9` | **Fallback exists** -- Three.js has `self.GPUShaderStage ? self.GPUShaderStage : { VERTEX: 1, ... }` | Three.js provides its own fallback. No action needed unless we want native parity. |
| `canvas.getContext('webgpu')` | `WebGPUBackend.js:274` | **Implemented** -- CanvasStub.getContext returns GPUCanvasContext for 'webgpu' | Works. |
| `context.configure()` | `WebGPUBackend.js:285-293` | **Implemented** -- GPUCanvasContext.configure() in gpu.ts | Three.js passes `{ device, format, usage, alphaMode, toneMapping }`. Our configure() accepts device/format/alphaMode but ignores `usage` and `toneMapping`. `usage` contains GPUTextureUsage bitflags that are currently undefined. |
| `context.getCurrentTexture()` | `WebGPUBackend.js:396` | **Implemented** -- GPUCanvasContext.getCurrentTexture() in gpu.ts | Works. |
| `self` global | `Animation.js:45`, `WebGPUConstants.js:9` | **Implemented** -- `g.self = dom.window` in index.ts | Works. The Animation module uses `self.requestAnimationFrame()` and `self.cancelAnimationFrame()`. |
| `self.requestAnimationFrame()` | `Animation.js:73` | **Implemented** -- via window alias | Three.js animation loop calls `this._context.requestAnimationFrame(update)` where `_context = self`. Our WindowStub has requestAnimationFrame. |

### Important (blocks rendering / scene setup)

These APIs are needed for a basic render cycle (scene with mesh, one render call).

| API | Where Used | Current Status | Notes |
|-----|-----------|----------------|-------|
| `device.createBuffer()` | `WebGPUBackend.js:2215+` via `WebGPUAttributeUtils` | **Implemented** -- GPUDevice.createBuffer() | Works. |
| `device.createTexture()` | `WebGPUTextureUtils.js:270+` | **Implemented** -- GPUDevice.createTexture() | Works but Three.js computes `usage` with GPUTextureUsage flags (see Critical). |
| `device.createShaderModule()` | `WebGPUPipelineUtils.js` | **Implemented** -- GPUDevice.createShaderModule() | Works. |
| `device.createRenderPipeline()` | `WebGPUPipelineUtils.js` | **Implemented** -- GPUDevice.createRenderPipeline() | Works. |
| `device.createBindGroupLayout()` | `WebGPUBindingUtils.js` | **Implemented** -- GPUDevice.createBindGroupLayout() | Three.js passes `visibility` with GPUShaderStage flags (built-in fallback exists). |
| `device.createPipelineLayout()` | `WebGPUBindingUtils.js` | **Implemented** -- GPUDevice.createPipelineLayout() | Works. |
| `device.createBindGroup()` | `WebGPUBindingUtils.js` | **Implemented** -- GPUDevice.createBindGroup() | Works. |
| `device.createSampler()` | `WebGPUTextureUtils.js` | **Implemented** -- GPUDevice.createSampler() | Works. |
| `device.createCommandEncoder()` | `WebGPUBackend.js` | **Implemented** -- GPUDevice.createCommandEncoder() | Works. |
| `queue.submit()` | `WebGPUBackend.js` | **Implemented** -- GPUQueue.submit() | Works. |
| `queue.writeBuffer()` | `WebGPUAttributeUtils.js`, `WebGPUBindingUtils.js` | **Stub** -- GPUQueue.writeBuffer() is a no-op | Three.js writes vertex/index/uniform data via writeBuffer. Must implement with native call. |
| `queue.writeTexture()` | `WebGPUTextureUtils.js` | **Stub** -- GPUQueue.writeTexture() is a no-op | Three.js writes texture data via writeTexture. Must implement with native call. |
| `queue.copyExternalImageToTexture()` | `WebGPUTextureUtils.js:761` | **Missing** -- not implemented | Three.js uses this to upload HTMLImageElement/ImageBitmap data to GPU textures. |
| `buffer.mapAsync()` | `WebGPUBackend.js:1128`, `WebGPUAttributeUtils.js:354` | **Stub** -- GPUBuffer.mapAsync() is a no-op | Used for occlusion queries, readback. Not needed for basic rendering. |
| `buffer.getMappedRange()` | `WebGPUBackend.js`, `WebGPUAttributeUtils.js` | **Stub** -- returns empty ArrayBuffer | Needed for readback operations. |
| `texture.createView()` | `WebGPUBackend.js:370-396` | **Implemented** -- GPUTexture.createView() | Works. |
| `renderPipeline.getBindGroupLayout()` | `WebGPUBindingUtils.js` | **Stub** -- returns GPUBindGroupLayout(0) | Three.js may use auto-layout pipelines. Needs real native introspection. |
| `performance.now()` | `Clock.js:71,120`, `Timer.js:24,130,165`, `NodeFrame.js:302-306` | **Implemented** -- performance.now() in performance.zig | Works correctly. |
| `console.log/warn/error` | Throughout Three.js | **Implemented** -- console polyfill in console.zig | Works. |
| `canvas.width` / `canvas.height` | `CanvasTarget.js:46-54`, `WebGPUBackend.js` | **Implemented** -- CanvasStub has width/height | Works. |
| `canvas.style` | `CanvasTarget.js:198-199` | **Partial** -- CanvasStub.style is `{}` | Three.js sets `domElement.style.width` and `domElement.style.height` on setSize(). Our empty object accepts writes silently, which is fine. |
| `canvas.setAttribute()` | `Backend.js:671`, `WebGPUBackend.js:279` | **Implemented** -- CanvasStub.setAttribute() | Three.js sets `data-engine` attribute. Works. |
| `window.__THREE__` | `Three.Core.js:174-186` | **Not needed** -- read/write on window object | Three.js checks and sets `window.__THREE__` for duplicate detection. WindowStub accepts arbitrary properties. Works. |
| `WeakMap` | Throughout Three.js | **Built-in** -- QuickJS-NG has WeakMap | No polyfill needed. |
| `Map` / `Set` | Throughout Three.js | **Built-in** -- QuickJS-NG has Map/Set | No polyfill needed. |
| `Promise` / `async/await` | Throughout Three.js | **Built-in** -- QuickJS-NG has Promise | No polyfill needed. |

### Important (blocks asset loading)

These APIs are needed when loading textures, models, or other assets.

| API | Where Used | Current Status | Notes |
|-----|-----------|----------------|-------|
| `fetch()` | `FileLoader.js:142`, `ImageBitmapLoader.js:173` | **Implemented** -- fetch polyfill in fetch.ts | Supports local files, data: URIs, HTTP/HTTPS. |
| `Request` constructor | `FileLoader.js:131` | **Missing** -- not on globalThis | Three.js creates `new Request(url, { headers, credentials, signal })`. Must implement Request class or adapt FileLoader. |
| `Headers` constructor | `FileLoader.js:132` | **Missing** -- not on globalThis | Three.js creates `new Headers(this.requestHeader)`. Must implement Headers class. |
| `Response` class | `FileLoader.js:217` | **Partial** -- FetchResponse exists but not as `Response` on globalThis | Three.js creates `new Response(stream)` for progress tracking. Our Response is installed on globalThis but lacks ReadableStream constructor. |
| `AbortController` | `FileLoader.js:66`, `ImageBitmapLoader.js:81`, `LoadingManager.js:311` | **Missing** -- not on globalThis | Three.js creates `new AbortController()` in constructor of every FileLoader and ImageBitmapLoader. Must implement. |
| `AbortSignal.any()` | `FileLoader.js:134`, `ImageBitmapLoader.js:171` | **Missing** | Three.js checks `typeof AbortSignal.any === 'function'` and falls back gracefully. Can be deferred. |
| `ReadableStream` | `FileLoader.js:175` | **Missing** -- not on globalThis | Three.js checks `typeof ReadableStream === 'undefined'` and skips progress tracking if missing. Graceful degradation -- not blocking. |
| `ProgressEvent` | `FileLoader.js:192` | **Missing** -- not on globalThis | Only used inside ReadableStream progress tracking. Skipped if ReadableStream is missing. |
| `DOMParser` | `FileLoader.js:243` | **Missing** -- not on globalThis | Only used for `responseType: 'document'`. Unlikely to be needed for 3D assets. |
| `TextDecoder` with label param | `FileLoader.js:264` | **Partial** -- TextDecoder exists but ignores encoding label | Three.js creates `new TextDecoder(label)` for custom charset. Our TextDecoder always uses UTF-8. |
| `createImageBitmap()` | `ImageBitmapLoader.js:179` | **Implemented** -- createImageBitmap in image.ts | Works for Uint8Array/ArrayBuffer/Blob sources. |
| `Image` (HTMLImageElement) | `ImageLoader.js:88` via `createElementNS('img')` | **Partial** -- Image polyfill exists but createElementNS('img') returns generic stub | Three.js calls `createElementNS('img')` which goes through `document.createElementNS()`. Our DocumentStub returns a generic object for non-'canvas' tags, NOT our ImageElement. Fix: DocumentStub.createElementNS should return ImageElement for 'img' tag. |
| `URL` constructor | `Cache.js:103` | **Missing** -- not on globalThis | Three.js calls `new URL(urlString)` for cache key normalization. Wrapped in try/catch so won't crash. |

### Nice-to-have (non-critical features)

| API | Where Used | Current Status | Notes |
|-----|-----------|----------------|-------|
| `navigator.userAgent` | `WebGPUBackend.js:144`, `WGSLNodeBuilder.js:167`, `WebGLBackend.js:194` | **Implemented** -- returns "threez/0.1.0" | Used for device-specific workarounds (Android, Firefox/Deno). Our value won't match any patterns, which is correct behavior. |
| `navigator.language` | DOM stub | **Implemented** -- returns "en-US" | Not directly used by Three.js renderer. |
| `navigator.platform` | DOM stub | **Implemented** -- returns "threez" | Not directly used by Three.js renderer. |
| `document.hidden` | `Timer.js:49` | **Partial** -- DocumentStub has `hidden: false` | Used for Page Visibility API in Timer.connect(). Our value is correct for a native app. |
| `document.visibilityState` | DocumentStub | **Implemented** -- returns "visible" | Works. |
| `document.body` | DocumentStub | **Implemented** -- returns EventTarget | Three.js controls (OrbitControls) may attach to document.body. Our stub works for addEventListener. |
| `document.documentElement` | DocumentStub | **Implemented** -- returns EventTarget | Used by some Three.js controls. |
| `window.innerWidth` / `innerHeight` | index.ts | **Implemented** -- 800x600 default | Used by user code for camera aspect ratio. Works. |
| `window.devicePixelRatio` | index.ts | **Implemented** -- 1.0 default | Works. |
| `CustomEvent` constructor | `Three.Core.js:168`, `WebGPURenderer.js:99` | **Missing** -- not on globalThis | Only used for `__THREE_DEVTOOLS__` integration. Guarded by `typeof __THREE_DEVTOOLS__ !== 'undefined'` check. Will never execute in our runtime. |
| `AudioContext` / `webkitAudioContext` | `audio/AudioContext.js:19` | **Missing** -- not on globalThis | Only used if application creates Audio objects. Not needed for 3D rendering. |
| `OffscreenCanvas` | `WebGLTextureUtils.js:1301`, `WebGLTextures.js:41` | **Missing** -- not on globalThis | Only used in WebGL fallback path, not WebGPU. |
| `Blob` | `loaders/LoaderUtils.js` | **Missing** -- not on globalThis | Used for Blob URL handling. Not needed for basic file loading. |
| `XRSession` / WebXR | `renderers/webxr/` | **Missing** -- not on globalThis | Not needed unless targeting VR/AR. |
| `canvas.getContext('2d')` | `extras/ImageUtils.js:42,79` | **Missing** | Used for sRGB-to-linear conversion of images. Not needed for WebGPU path which handles this in shaders. |
| `document.getElementById()` | `DocumentStub` | **Implemented** -- returns null | Only used in examples/user code, not core Three.js. |
| `structuredClone` | Not used | **Not needed** | Three.js does not use structuredClone. |
| `queueMicrotask` | Not used | **Not needed** | Three.js does not use queueMicrotask. |
| `crypto.getRandomValues()` | Not used | **Not needed** | Three.js uses Math.random() for its MathUtils.generateUUID(). |
| `WebSocket` / `EventSource` | Not used | **Not needed** | Three.js does not use WebSocket or EventSource. |
| `DOMMatrix` / `DOMPoint` | Not used | **Not needed** | Three.js has its own math library (Matrix4, Vector3, etc.). |
| `ResizeObserver` / `IntersectionObserver` / `MutationObserver` | Not used | **Not needed** | Three.js does not use any Observer APIs. |
| `matchMedia` / `getComputedStyle` | Not used | **Not needed** | Three.js does not use these. |

## Existing Polyfills That Cover Gaps

### Zig-level polyfills (src/polyfills/)
| Polyfill | Coverage |
|----------|----------|
| `console.zig` | console.log/warn/error/info -- **fully covers** Three.js needs |
| `performance.zig` | performance.now() -- **fully covers** Clock, Timer, NodeFrame |
| `encoding.zig` | TextEncoder/TextDecoder -- **mostly covers**, missing encoding label param |
| `fetch.zig` | __native_readFileSync, __native_decodeBase64, __native_httpFetch -- **supports** fetch polyfill |
| `timers.zig` | setTimeout/setInterval/clearTimeout/clearInterval -- **fully covers** Three.js needs |
| `image.zig` | __native_decodeImage for PNG/JPEG -- **supports** createImageBitmap polyfill |

### TypeScript-level polyfills (src/ts/bootstrap/)
| Polyfill | Coverage |
|----------|----------|
| `dom.ts` | window, document, canvas, navigator stubs -- **mostly covers** Three.js needs |
| `event-target.ts` | EventTarget with capture/once/passive -- **fully covers** |
| `events.ts` | Event, PointerEvent, WheelEvent, KeyboardEvent -- **fully covers** |
| `fetch.ts` | fetch(), Response -- **mostly covers**, missing Request/Headers classes |
| `gpu.ts` | Full WebGPU class hierarchy -- **mostly covers**, missing features/limits/lost |
| `image.ts` | Image, ImageBitmap, createImageBitmap -- **fully covers** |
| `index.ts` | Global wiring (window, document, navigator, self, rAF) -- **fully covers** |

## Recommendations for T21b

Prioritized list of polyfill work needed, ordered by impact:

### P0 -- Must fix for renderer init

1. **Add GPUTextureUsage, GPUBufferUsage, GPUMapMode constants to globalThis**
   - Three.js uses these as global constants for bitflag operations
   - Define in bootstrap/gpu.ts or a new bootstrap/webgpu-constants.ts
   - Values: standard WebGPU spec values (COPY_SRC=4, COPY_DST=8, MAP_READ=1, etc.)

2. **Add `device.features` (Set), `device.limits` (Object), `device.lost` (Promise)**
   - GPUDevice must have: `features: Set<string>`, `limits: Record<string, number>`, `lost: Promise`
   - `features` should reflect Dawn capabilities (at minimum: `core-features-and-limits`)
   - `limits` should reflect Dawn defaults (maxUniformBufferBindingSize, maxComputeWorkgroupsPerDimension, etc.)
   - `lost` can be a never-resolving Promise

3. **Add `adapter.features` (Set) with real feature detection**
   - GPUAdapter.features must return a Set of supported features from Dawn
   - Currently returns empty Set which causes Three.js to pass empty requiredFeatures

### P1 -- Must fix for rendering

4. **Implement `queue.writeBuffer()` with native call**
   - Three.js writes all vertex, index, and uniform data via writeBuffer
   - Without this, no geometry data reaches the GPU

5. **Implement `queue.writeTexture()` with native call**
   - Three.js writes texture pixel data via writeTexture
   - Without this, no textures appear

6. **Implement `queue.copyExternalImageToTexture()` or alternative**
   - Three.js uses this for ImageBitmap -> GPU texture uploads
   - Could be implemented as writeTexture on the Zig side using the ImageBitmap._data bytes

### P2 -- Must fix for asset loading

7. **Add `AbortController` / `AbortSignal` polyfill**
   - FileLoader and ImageBitmapLoader create AbortController in their constructors
   - Without this, constructing any loader will throw
   - Minimal implementation: signal property with `aborted: false`, `addEventListener()`

8. **Add `Request` and `Headers` classes**
   - FileLoader creates `new Request(url, opts)` and `new Headers(obj)`
   - Minimal implementation: Request wraps url+options, Headers wraps key-value map

9. **Fix `createElementNS('img')` to return ImageElement**
   - DocumentStub.createElementNS should detect 'img' tag and return our ImageElement
   - This enables Three.js ImageLoader to work with our Image polyfill

### P3 -- Nice to have

10. **Add `URL` constructor (minimal)**
    - Used by Cache.js for URL normalization
    - Wrapped in try/catch, so not blocking
    - Minimal: parse protocol/host/pathname/search/hash

11. **TextDecoder encoding label support**
    - FileLoader uses `new TextDecoder(label)` for non-UTF-8 content
    - Low priority since most 3D assets are binary or UTF-8

12. **Add `CustomEvent` constructor (stub)**
    - Only used for devtools integration, guarded by typeof check
    - Zero impact on rendering
