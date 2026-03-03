<!-- status: locked -->
# Three.js Integration Gap Analysis (Refreshed)

## Snapshot

- Date: 2026-03-03
- Three.js version: 0.183.2
- Three.js commit: `1939c35f2d92a4c870568da011aab54dabdfdd30`
- Pin source: `VENDORED.md`, example `package.json` files

## Validation Evidence

Commands run during this refresh:

- `npm run build` in `examples/threejs_basic`
- `timeout 15s ./zig-out/bin/threez run examples/threejs_basic/dist/test-bundle.js`
- `timeout 15s ./zig-out/bin/threez run examples/threejs_basic/dist/scene-bundle.js`
- `timeout 15s ./zig-out/bin/threez run examples/gltf_viewer/dist/gltf-bundle.js`

Observed runtime evidence:

- `=== Three.js loaded successfully ===`
- `WebGPURenderer created`
- `renderer.init() succeeded`
- `renderer.setSize() succeeded`
- `render() succeeded`
- `DamagedHelmet loaded successfully`
- No `--- ERRORS` section produced by the `test-init` probe

## Current Gap Status

### Critical Gaps

All previously identified critical gaps are now resolved for current Three.js WebGPU initialization paths.

| API/Area | Current Status | Evidence |
|---|---|---|
| `GPUBufferUsage`, `GPUTextureUsage`, `GPUMapMode`, `GPUShaderStage` globals | Implemented | `src/ts/bootstrap/webgpu-constants.ts` |
| `adapter.features`, `adapter.limits` | Implemented | `src/ts/bootstrap/gpu.ts` (`GPUAdapter`) |
| `device.features`, `device.limits`, `device.lost` | Implemented | `src/ts/bootstrap/gpu.ts` (`GPUDevice`) |
| `navigator.gpu.requestAdapter/requestDevice` | Implemented | `src/ts/bootstrap/gpu.ts`, `src/gpu_bridge.zig` |
| `document.createElementNS('canvas'/'img')` behavior | Implemented | `src/ts/bootstrap/dom.ts` |
| `AbortController` / `AbortSignal` presence | Implemented | `src/ts/bootstrap/abort.ts` |
| `Request` / `Headers` presence | Implemented | `src/ts/bootstrap/request.ts` |
| `URL` / `Blob` / `URL.createObjectURL` support | Implemented | `src/ts/bootstrap/index.ts` |

### Important Gaps

All previously identified important rendering blockers are now resolved for the tested render paths.

| API/Area | Current Status | Evidence |
|---|---|---|
| `queue.writeBuffer` | Implemented | `src/ts/bootstrap/gpu.ts` + `src/gpu_bridge.zig` |
| `queue.writeTexture` | Implemented | `src/ts/bootstrap/gpu.ts` + `src/gpu_bridge.zig` |
| `queue.copyExternalImageToTexture` | Implemented | `src/ts/bootstrap/gpu.ts` |
| `renderPipeline.getBindGroupLayout` | Implemented | `src/ts/bootstrap/gpu.ts` + `src/gpu_bridge.zig` |
| `GPUCanvasContext.configure/getCurrentTexture/present` | Implemented | `src/ts/bootstrap/gpu.ts` + `src/gpu_bridge.zig` |
| `fetch` local/data/http paths | Implemented | `src/ts/bootstrap/fetch.ts` + `src/polyfills/fetch.zig` |
| `Image`/`createImageBitmap` decode path | Implemented | `src/ts/bootstrap/image.ts` + `src/polyfills/image.zig` |

## Remaining Gaps (Deferred / Nice-to-Have)

These are non-blocking for current T21b/T22/T23 demo paths, but still incomplete vs broad browser/WebGPU parity.

| Area | Status | Impact |
|---|---|---|
| `GPUBuffer.mapAsync` semantics | Partial/stub | Readback/query-heavy workflows may not behave like browsers |
| Query APIs (`createQuerySet`, `resolveQuerySet`, occlusion/timestamp flows) | Partial/stub | Advanced profiling/occlusion paths may be limited |
| `device.pushErrorScope/popErrorScope` | Partial/stub | Limited WebGPU error-scope parity |
| `ReadableStream` + fetch progress events | Missing | Loader progress streaming behavior is reduced |
| `AbortSignal.timeout()` real timer semantics | Partial/stub | Timeout-specific abort behavior differs from browser |
| `URLSearchParams` full implementation | Partial/stub | Complex URL query manipulation may be incomplete |

## T21b Conclusion

For the target scope (Three.js WebGPU renderer init, scene render, and glTF viewer demo), the critical and important blockers from the original gap analysis are resolved.

Remaining items are deferred parity work and do not block current demo execution.
