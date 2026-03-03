<!-- status: in-review -->
# Ticket Implementation Status: threez

## Snapshot

- Date: 2026-03-03
- Source tickets: `docs/specs/threez/tickets.md`
- Verification commands run:
  - `zig build` (repo root) — pass
  - `zig build test` (repo root) — pass
  - `zig build test` (`deps/zig-quickjs-ng`) — pass
  - `npm run build` (`src/ts`) — pass
  - `npm run typecheck` (`src/ts`) — pass
  - `timeout 12s ./zig-out/bin/threez run examples/triangle/main.js` — enters render loop
  - `timeout 12s ./zig-out/bin/threez run examples/threejs_basic/dist/scene-bundle.js` — enters render loop
  - `timeout 12s ./zig-out/bin/threez run examples/gltf_viewer/dist/gltf-bundle.js` — model loads, enters render loop
  - `timeout 12s ./zig-out/bin/threez run /tmp/http-fetch-smoke.js` — `HTTP_OK 200`

## Summary

| Status | Count |
|---|---:|
| Complete | 23 |
| Partial / Needs Verification | 5 |
| Not Started | 0 |

## Ticket Matrix

| Ticket | Status | Evidence | Notes |
|---|---|---|---|
| T1 | Complete | `build.zig`, `build.zig.zon`, `src/root.zig` | Build/test scaffolding in place and passing. |
| T2 | Complete | `deps/zig-quickjs-ng/`, `VENDORED.md` | Vendored dependency present; upstream tests pass locally. |
| T3 | Complete | `src/js_engine.zig` tests | Arithmetic/string/module eval + exception handling covered. |
| T4 | Complete | `src/window.zig`, runtime smoke logs | GLFW + zgpu window/context creation working on Linux. |
| T5 | Complete | `src/handle_table.zig` tests | Generation, free list, stale/double-free cases covered. |
| T6a | Complete | `src/io/io_uring.zig` tests | Linux backend with file/socket tests implemented. |
| T6b | Partial / Needs Verification | `src/io/kqueue.zig` | Implementation exists; not verified on macOS target in this audit. |
| T6c | Partial / Needs Verification | `src/io/iocp.zig` | Implementation exists; not verified on Windows target in this audit. |
| T7 | Complete | `src/ts/bootstrap/*`, `src/bootstrap.zig` | Bootstrap build and typecheck pass. |
| T8 | Complete | `src/polyfills/{console,performance,encoding}.zig` tests | Native polyfills are registered and tested. |
| T9 | Complete | `src/polyfills/timers.zig`, `src/event_loop.zig` tests | Timeout/interval semantics and ordering covered. |
| T10 | Complete | `src/event_loop.zig` tests | rAF, microtask drain, pump-until-ready behavior tested. |
| T11 | Complete | `src/event_bridge.zig` tests | Pointer/wheel/key/resize events mapped and tested. |
| T12 | Complete | `src/polyfills/fetch.zig`, `src/ts/bootstrap/fetch.ts` | Local file/data URI fetch path implemented and used by demos. |
| T13 | Complete | `src/polyfills/fetch.zig`, HTTP smoke script | HTTP fetch native bridge returns successful responses. |
| T14 | Complete | `src/polyfills/image.zig`, `src/ts/bootstrap/image.ts` | PNG/JPEG decode path implemented; glTF demo loads assets. |
| T15a | Complete | `src/descriptor.zig`, `src/gpu_bridge.zig` | Descriptor translation implemented and exercised by bridge tests. |
| T15b | Complete | `src/gpu_bridge.zig`, `src/ts/bootstrap/gpu.ts` | Adapter/device/queue bridge and JS classes wired. |
| T16 | Complete | `src/gpu_bridge.zig`, `src/ts/bootstrap/gpu.ts` | Buffer/texture/sampler resource path implemented. |
| T17 | Complete | `src/gpu_bridge.zig`, runtime smoke logs | Shader and pipeline creation runs in smoke scenes. |
| T18 | Complete | `src/gpu_bridge.zig` tests | Command encoder/render pass/draw/submit chain covered. |
| T19 | Complete | `src/gpu_bridge.zig` tests | Configure/getCurrentTexture/present path implemented. |
| T20 | Complete | `examples/triangle/main.js`, runtime smoke logs | Triangle demo initializes and renders continuously. |
| T21a | Complete | `docs/specs/threez/threejs-gaps.md`, `VENDORED.md` | Gap analysis and version pinning doc exists. |
| T21b | Complete | `src/ts/bootstrap/{abort,request,webgpu-constants,gpu}.ts`, `docs/specs/threez/threejs-gaps.md` | Critical/important blocker list has been reconciled to current implementation. |
| T22 | Partial / Needs Verification | `examples/threejs_basic/scene.js`, smoke logs | Scene runs; manual visual acceptance checks (lighting/projection) not captured in this audit. |
| T23 | Partial / Needs Verification | `examples/gltf_viewer/gltf-viewer.js`, smoke logs | DamagedHelmet loads, but several ticket acceptance items are not fully represented in script/tests. |
| T24 | Partial / Needs Verification | `src/main.zig`, `src/runtime.zig`, `src/root.zig`, `build.zig`, `zig-out/lib/libthreez.a` | Runtime API extraction and static library artifact are now implemented; `--assets`/`--strict` semantics and explicit embed-mode verification remain open. |

## Immediate Follow-ups

1. Verify T6b/T6c on real macOS/Windows targets (or CI cross-platform jobs) to close platform confidence gaps.
2. Decide whether T23 acceptance should be reduced to current demo scope or implement missing items (animation mixer, auto-frame, remote index flow, longer soak/perf checks).
3. Close remaining T24 gaps: implement `--assets`/`--strict` behavior and add an explicit embed-mode verification path.
