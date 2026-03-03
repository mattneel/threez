<!-- status: locked -->
# Tickets: threez

## Ticket Detail Level: Detailed

Greenfield, novel territory. Detailed tickets reduce agent drift.

## Testing Strategy

TDD throughout. Test aggregation via root.zig:
```zig
test {
    std.testing.refAllDecls(@This());
}
```
Set up during project init (T1). Each module is `pub const`-imported in root.zig, so `zig build test` runs all tests automatically. No build.zig edits per module. Write tests alongside implementation in every ticket.

## Execution Order

```
T1:  Project scaffolding + build.zig + root.zig test agg   (M0, no deps)
T2:  Vendor + patch zig-quickjs-ng for Zig 0.15            (M0, no deps)         ← parallel A
T3:  QuickJS-NG integration: eval hello world               (M0, deps: T1, T2)
T4:  zgpu window creation                                   (M0, deps: T1)        ← parallel B
T5:  Handle table                                           (M5, no deps)         ← parallel B
T6a: Platform I/O: interface + io_uring (Linux)             (M3, deps: T1)        ← parallel B
T6b: Platform I/O: kqueue (macOS)                           (M3, deps: T6a)
T6c: Platform I/O: IOCP (Windows)                           (M3, deps: T6a)       ← parallel C with T6b
T7:  TypeScript bootstrap: EventTarget + DOM shims          (M1, deps: T3)
T8:  Native polyfills: console, performance, encoding       (M1, deps: T3)        ← parallel D with T7
T9:  Timer queue + setTimeout/setInterval                   (M2, deps: T3, T7)
T10: Event loop: frame tick + rAF                           (M2, deps: T4, T9)
T11: GLFW → DOM event bridge                                (M2, deps: T7, T10)
T12: Fetch polyfill (local filesystem)                      (M3, deps: T6a, T7, T8)
T13: Fetch polyfill (HTTP)                                  (M3, deps: T6a, T12)
T14: Image decode pipeline (zignal)                         (M4, deps: T7, T12)
T15a: Comptime descriptor translator                        (M5, deps: T3)        ← parallel E with T5
T15b: WebGPU bridge: adapter + device                       (M5, deps: T4, T5, T7, T15a)
T16: WebGPU bridge: buffers + textures + samplers           (M5, deps: T15b)
T17: WebGPU bridge: shaders + pipelines                     (M5, deps: T15b)      ← parallel F with T16
T18: WebGPU bridge: command encoding + render pass          (M6, deps: T16, T17)
T19: WebGPU bridge: present (swap chain)                    (M6, deps: T18)
T20: Triangle test: first native WebGPU render              (M6, deps: T19)
T21a: Three.js integration: gap analysis                    (M7, deps: T12, T14, T19)
T21b: Three.js integration: fix polyfill gaps               (M7, deps: T21a)
T22: Three.js integration: simple scene render              (M7, deps: T21b)
T23: Target demo: webgpu_loader_gltf                        (M8, deps: T11, T13, T14, T22)
T24: CLI + library packaging                                (M9, deps: T23)
```

### Parallel Groups

| Group | Tickets | Condition |
|-------|---------|-----------|
| A | T1, T2 | Independent scaffolding, no shared files |
| B | T4, T5, T6a, T15a | All depend only on T1 or nothing; no file overlap |
| C | T6b, T6c | Independent platform backends, same interface |
| D | T7, T8 | Both depend only on T3, different files |
| E | T5, T15a | Pure data structure vs pure generic translator, no overlap |
| F | T16, T17 | Independent WebGPU resource types |

---

### T1: Project scaffolding + build.zig + test aggregation
**Specs**: tech-plan.md §File Layout, §Design Decisions
**Files**: `build.zig`, `build.zig.zon`, `src/main.zig` (stub), `src/root.zig`, `LICENSE`, `.gitignore`
**Dependencies**: None
**Effort**: Small
**Parallel group**: A

**Description**:
Create the project skeleton with anyzig / Zig 0.15.2. build.zig.zon declares dependencies (zgpu, zignal, zig-clap). root.zig is the library root with `test { std.testing.refAllDecls(@This()); }` for test aggregation. All future modules are `pub const`-imported in root.zig so `zig build test` catches everything.

**Acceptance Criteria**:
- [ ] `zig build` succeeds (deps fetch, compile completes)
- [ ] `zig build run` prints "threez" and exits 0
- [ ] `zig build test` runs and passes (even if only the root test)
- [ ] root.zig has `test { std.testing.refAllDecls(@This()); }`
- [ ] build.zig.zon lists zgpu, zignal, zig-clap as dependencies
- [ ] LICENSE file contains MIT license
- [ ] .gitignore covers zig-cache, zig-out

**Implementation Steps**:

Step 1 — `zig init` with anyzig targeting 0.15.2

Step 2 — Create build.zig.zon
- name: "threez", version: "0.0.1"
- minimum_zig_version: "0.15.2"
- dependencies: zgpu (git), zignal (git), zig-clap (git)
- Note: zig-quickjs-ng vendored in T2, not a .zon dep

Step 3 — Create build.zig
- Add exe target "threez" from src/main.zig
- Add lib module from src/root.zig
- Link zgpu, zignal, zig-clap modules
- Add test step from root.zig
- Install step

Step 4 — Create src/root.zig
```zig
const std = @import("std");
// Future modules will be pub const imported here
test {
    std.testing.refAllDecls(@This());
}
```

Step 5 — Create src/main.zig stub
```zig
const std = @import("std");
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("threez\n", .{});
}
```

Step 6 — LICENSE (MIT), .gitignore (zig-cache, zig-out, node_modules)

---

### T2: Vendor + patch zig-quickjs-ng for Zig 0.15
**Specs**: epic-brief.md §Design Decisions, tech-plan.md §Design Decisions
**Files**: `deps/zig-quickjs-ng/` (vendored), `deps/zig-quickjs-ng/VENDORED.md`
**Dependencies**: None
**Effort**: Medium
**Parallel group**: A

**Description**:
Fork/vendor mitchellh/zig-quickjs-ng into deps/. Patch build.zig and source files to compile on Zig 0.15.2. Key changes: calling convention `.C` → `.c`, ArrayList API updates, build system API changes.

**Acceptance Criteria**:
- [ ] `deps/zig-quickjs-ng/` contains vendored source
- [ ] Library compiles without errors on Zig 0.15.2
- [ ] QuickJS-NG's bundled tests pass
- [ ] VENDORED.md documents upstream commit hash + patches applied
- [ ] Minimal eval test works: create runtime, create context, eval "1+1" == 2

**Implementation Steps**:

Step 1 — Vendor the source
- Clone mitchellh/zig-quickjs-ng at latest commit
- Place in deps/zig-quickjs-ng/
- Create VENDORED.md noting upstream hash + date

Step 2 — Patch for Zig 0.15.2
- Update minimum_zig_version
- Fix calling convention: `.C` → `.c`
- Fix ArrayList API if needed
- Fix any build system API changes (addLibrary, translateC)
- Iterate `zig build` until clean

Step 3 — Verify existing tests pass

---

### T3: QuickJS-NG integration: eval hello world
**Specs**: core-flows.md §Flow 3 (Phase 2), tech-plan.md §QuickJS Engine
**Files**: `src/js_engine.zig`, update `src/root.zig`
**Dependencies**: T1, T2
**Effort**: Small

**Description**:
Create js_engine.zig wrapper. Init QuickJS runtime + context, eval JS string, retrieve result, clean up. Wire into root.zig for test aggregation.

**Acceptance Criteria**:
- [ ] `JsEngine.init(allocator)` creates runtime + context
- [ ] `engine.eval("1 + 1")` returns integer 2
- [ ] `engine.eval("'hello ' + 'world'")` returns "hello world"
- [ ] `engine.evalModule(source)` evaluates ES module syntax
- [ ] `engine.deinit()` cleans up without leaks
- [ ] JS exceptions caught and reportable
- [ ] `pub const js_engine = @import("js_engine.zig")` in root.zig
- [ ] `zig build test` runs js_engine tests via refAllDecls

**Implementation Steps**:

Step 1 — Define JsEngine struct
- Fields: allocator, qjs_runtime, qjs_context
- init/deinit

Step 2 — Implement eval + evalModule
- Handle exceptions via getException + toCString

Step 3 — Value extraction helpers
- toInt32, toFloat64, toCString, type checking

Step 4 — Wire into root.zig: `pub const js_engine = @import("js_engine.zig");`

Step 5 — Tests: arithmetic, strings, modules, exceptions, cleanup

---

### T4: zgpu window creation
**Specs**: core-flows.md §Flow 3 (Phase 1), tech-plan.md §Runtime
**Files**: `src/window.zig`, update `src/root.zig`
**Dependencies**: T1
**Effort**: Small
**Parallel group**: B

**Description**:
Create a GLFW window via zgpu. Init GPU instance and surface. Proves zgpu integration.

**Acceptance Criteria**:
- [ ] `Window.init(config)` creates GLFW window with specified dimensions
- [ ] GPU instance + surface created
- [ ] shouldClose(), pollEvents(), getSize(), getContentScale() work
- [ ] `window.deinit()` cleans up
- [ ] Works on Linux
- [ ] Wired into root.zig

---

### T5: Handle table
**Specs**: tech-plan.md §Handle Table, core-flows.md §Flow 5
**Files**: `src/handle_table.zig`, update `src/root.zig`
**Dependencies**: None
**Effort**: Small
**Parallel group**: B, E

**Description**:
Dense array + free list + generation counter. 64K one-time alloc, configurable. Pure data structure, no external deps.

**Acceptance Criteria**:
- [ ] init(allocator, capacity) — one-time alloc, default 64K
- [ ] alloc(dawn_handle, handle_type) → HandleId
- [ ] get(handle_id) → handle or error (stale generation, freed)
- [ ] free(handle_id) — mark free, increment generation
- [ ] destroy(handle_id) — mark destroyed (explicit .destroy() path)
- [ ] Free list reuse correct
- [ ] Generation counter prevents ABA
- [ ] Double-free detected and safe
- [ ] Capacity exhaustion returns error
- [ ] Wired into root.zig
- [ ] Comprehensive unit tests

**Implementation Steps**:

Step 1 — Define types: HandleId (packed: index u32 + generation u16), HandleEntry, HandleType enum, DawnHandle tagged union (void placeholder initially)

Step 2 — Implement HandleTable: init (alloc + free list chain), alloc (pop free list), get (bounds + generation + alive check), free (push free list + gen++), destroy (mark destroyed flag)

Step 3 — Wire into root.zig

Step 4 — Tests: alloc+get, free+realloc, stale handle, double-free, capacity overflow, destroy vs free

---

### T6a: Platform I/O: interface + io_uring (Linux)
**Specs**: tech-plan.md §Platform I/O Abstraction
**Files**: `src/io/poll.zig`, `src/io/io_uring.zig`, update `src/root.zig`
**Dependencies**: T1
**Effort**: Medium
**Parallel group**: B

**Description**:
Define the platform I/O interface and implement the io_uring backend for Linux. This is the primary dev platform and the first backend to get right.

**Acceptance Criteria**:
- [ ] IOPoll comptime-dispatches to IoUringPoll on Linux
- [ ] init(allocator) sets up io_uring ring (queue depth 256)
- [ ] submitRead(fd, buffer, userdata) queues IORING_OP_READ
- [ ] submitConnect, submitRecv, submitSend queue socket ops
- [ ] poll(timeout_ms) returns Completion array
- [ ] File reads complete correctly (write temp file → submitRead → poll → verify bytes)
- [ ] Socket round-trip works (socketpair → send+recv)
- [ ] Wired into root.zig
- [ ] Unit tests with real I/O

**Implementation Steps**:

Step 1 — Define interface in poll.zig
- `pub const IOPoll = switch (builtin.os.tag) { .linux => IoUringPoll, .macos => KqueuePoll, .windows => IocpPoll, else => @compileError(...) };`
- Define Completion { userdata, result, op_type }
- Define OpType enum

Step 2 — Implement IoUringPoll
- init: std.os.linux.IoUring.init(256)
- submitRead: prep_read SQE, set userdata
- submitConnect/Recv/Send: prep_connect/recv/send SQEs
- poll: submit + peek_batch_cqe → map CQEs to Completions
- deinit: ring.deinit()

Step 3 — Tests: file read, socket pair round-trip, multiple concurrent ops

---

### T6b: Platform I/O: kqueue (macOS)
**Specs**: tech-plan.md §Platform I/O Abstraction
**Files**: `src/io/kqueue.zig`
**Dependencies**: T6a (interface defined there)
**Effort**: Medium
**Parallel group**: C

**Description**:
kqueue backend for macOS/BSD. True async for sockets. Synchronous preadv fallback for regular files (kqueue can't async regular files).

**Acceptance Criteria**:
- [ ] KqueuePoll implements same interface as IoUringPoll
- [ ] Socket I/O: EVFILT_READ/EVFILT_WRITE, async connect/recv/send
- [ ] File I/O: preadv immediate completion (synchronous but fast)
- [ ] poll(timeout_ms) via kevent() with timeout
- [ ] Compiles on macOS (CI stretch, local dev if available)
- [ ] Same test suite as T6a passes

**Implementation Steps**:

Step 1 — KqueuePoll struct: kq fd, changelist, pending ops

Step 2 — Socket ops: register EVFILT_READ/WRITE, handle in poll via kevent

Step 3 — File ops: preadv directly, return completion immediately (fake async)

Step 4 — Ensure interface compatibility: same Completion type, same method signatures

---

### T6c: Platform I/O: IOCP (Windows)
**Specs**: tech-plan.md §Platform I/O Abstraction
**Files**: `src/io/iocp.zig`
**Dependencies**: T6a (interface defined there)
**Effort**: Medium
**Parallel group**: C

**Description**:
IOCP backend for Windows. True async for both files and sockets.

**Acceptance Criteria**:
- [ ] IocpPoll implements same interface as IoUringPoll
- [ ] CreateIoCompletionPort, ReadFile with OVERLAPPED, WSARecv/WSASend
- [ ] poll via GetQueuedCompletionStatusEx
- [ ] Compiles on Windows (CI stretch)
- [ ] Same test suite as T6a passes

**Implementation Steps**:

Step 1 — IocpPoll struct: iocp handle, overlapped pool

Step 2 — File ops: ReadFile with OVERLAPPED structure

Step 3 — Socket ops: WSARecv/WSASend with OVERLAPPED

Step 4 — poll: GetQueuedCompletionStatusEx → map to Completions

---

### T7: TypeScript bootstrap: EventTarget + DOM shims
**Specs**: tech-plan.md §DOM Shims, core-flows.md §Flow 8
**Files**: `src/ts/bootstrap/`, `src/ts/tsconfig.json`, `src/ts/package.json`, `src/ts/esbuild.config.mjs`
**Dependencies**: T3
**Effort**: Medium
**Parallel group**: D

**Description**:
TypeScript polyfill layer. EventTarget, Event classes, minimal DOM tree, native bridge interface. esbuild → bootstrap.js. tsc --noEmit validates.

**Acceptance Criteria**:
- [ ] `npm run build` in src/ts/ produces bootstrap.js
- [ ] `tsc --noEmit` passes zero errors
- [ ] EventTarget: addEventListener, removeEventListener, dispatchEvent
- [ ] Event, PointerEvent, WheelEvent, KeyboardEvent constructors
- [ ] window, document, canvas stubs with expected properties
- [ ] navigator.gpu stub (wired to __native later)
- [ ] document.createElement("canvas") returns canvas stub
- [ ] canvas.getBoundingClientRect() → { left: 0, top: 0, width, height }
- [ ] bootstrap.js evaluable by QuickJS-NG without errors
- [ ] Zig integration test: inject bootstrap.js → verify `typeof window === "object"`

**Implementation Steps**:

Step 1 — TS project setup: package.json (esbuild + typescript), tsconfig.json (strict, ES2023, noEmit), esbuild.config.mjs

Step 2 — event-target.ts: EventTarget class, addEventListener/removeEventListener/dispatchEvent, capture/once/passive support

Step 3 — events.ts: Event, PointerEvent, WheelEvent, KeyboardEvent

Step 4 — dom.ts: window (EventTarget), document (EventTarget), canvas (EventTarget), minimal property stubs

Step 5 — native.ts: `__native` global type declarations

Step 6 — index.ts: wire together, globalThis.window = window, etc.

Step 7 — Zig bootstrap.zig: @embedFile("bootstrap.js"), eval into QJS before user code

---

### T8: Native polyfills: console, performance, encoding
**Specs**: tech-plan.md §Components
**Files**: `src/polyfills/console.zig`, `src/polyfills/performance.zig`, `src/polyfills/encoding.zig`, `src/bootstrap.zig`, update `src/root.zig`
**Dependencies**: T3
**Effort**: Small
**Parallel group**: D

**Description**:
Simplest native polyfills. Register as global functions in QJS.

**Acceptance Criteria**:
- [ ] console.log/warn/error/info work (stdout/stderr routing)
- [ ] console.log handles multiple args, numbers, objects
- [ ] performance.now() returns f64 ms since runtime start, sub-ms precision
- [ ] TextEncoder.encode("hello") → Uint8Array
- [ ] TextDecoder.decode(bytes) → string
- [ ] All registered via bootstrap.zig
- [ ] Wired into root.zig
- [ ] Unit + integration tests

---

### T9: Timer queue + setTimeout/setInterval
**Specs**: tech-plan.md §Event Loop, core-flows.md §Flow 4
**Files**: `src/polyfills/timers.zig`, update bootstrap TS wiring, update `src/root.zig`
**Dependencies**: T3, T7
**Effort**: Small

**Description**:
Timer queue (min-heap) + setTimeout/setInterval/clearTimeout/clearInterval.

**Acceptance Criteria**:
- [ ] setTimeout fires after delay, setInterval repeats
- [ ] clearTimeout/clearInterval cancel
- [ ] Timer IDs unique integers
- [ ] delay 0 fires next tick (not synchronous)
- [ ] Queue orders correctly by fire time
- [ ] Wired into root.zig
- [ ] Unit + integration tests

---

### T10: Event loop: frame tick + rAF
**Specs**: core-flows.md §Flow 4, §Flow 9, tech-plan.md §Event Loop
**Files**: `src/event_loop.zig`, update `src/runtime.zig`, update `src/root.zig`
**Dependencies**: T4, T9
**Effort**: Medium

**Description**:
Main frame loop. Zig owns it. Each tick: poll GLFW → process timers → poll I/O → drain microtasks → call rAF → present.

**Acceptance Criteria**:
- [ ] EventLoop.init(...) works
- [ ] eventLoop.run() enters loop, returns on window close
- [ ] rAF callback called once per frame with monotonic timestamp
- [ ] Timers fire within the loop
- [ ] QJS job queue drained each frame
- [ ] PumpUntilReady phase: loops until rAF registered
- [ ] Wired into root.zig

---

### T11: GLFW → DOM event bridge
**Specs**: core-flows.md §Flow 8, tech-plan.md §DOM Events
**Files**: `src/event_bridge.zig`, update `src/root.zig`
**Dependencies**: T7, T10
**Effort**: Medium

**Description**:
Translate GLFW input callbacks → synthetic DOM events → dispatch to JS EventTarget.

**Acceptance Criteria**:
- [ ] Mouse move → PointerEvent("pointermove") with clientX, clientY, movementX/Y
- [ ] Mouse button → PointerEvent("pointerdown"/"pointerup") with button
- [ ] Scroll → WheelEvent("wheel") with deltaY
- [ ] Key press/release → KeyboardEvent("keydown"/"keyup") with key, code
- [ ] Window resize → Event("resize"), innerWidth/Height updated
- [ ] Pointer enter/leave events
- [ ] OrbitControls-compatible properties
- [ ] GLFW key → DOM key/code mapping table
- [ ] Wired into root.zig

---

### T12: Fetch polyfill (local filesystem)
**Specs**: core-flows.md §Flow 6, tech-plan.md §Fetch
**Files**: `src/polyfills/fetch.zig`, `src/ts/bootstrap/fetch.ts`, update `src/root.zig`
**Dependencies**: T6a, T7, T8
**Effort**: Medium

**Description**:
fetch() for local file paths. URL parse → local path → async read via IOPoll → Response.

**Acceptance Criteria**:
- [ ] fetch("./file.txt") reads relative to assets dir
- [ ] fetch("/absolute/path") reads absolute
- [ ] fetch("data:...") decodes data URI inline
- [ ] response.ok, response.status (200/404)
- [ ] response.arrayBuffer(), response.json(), response.text()
- [ ] response.headers.get("content-type") guessed from extension
- [ ] Returns Promise, resolves asynchronously
- [ ] Not-found → response.ok = false, status 404
- [ ] Wired into root.zig
- [ ] Integration test: write temp file → fetch → verify

---

### T13: Fetch polyfill (HTTP)
**Specs**: core-flows.md §Flow 6 (HTTP path)
**Files**: `src/io/http_client.zig`, update `src/polyfills/fetch.zig`, update `src/root.zig`
**Dependencies**: T6a, T12
**Effort**: Medium

**Description**:
Extend fetch() for HTTP(S) URLs. Zig std.http.Client via platform I/O.

**Acceptance Criteria**:
- [ ] fetch("https://...") works
- [ ] HTTP status, headers accessible
- [ ] HTTPS/TLS works
- [ ] Timeout on unresponsive server
- [ ] Network error → promise rejects
- [ ] Wired into root.zig

---

### T14: Image decode pipeline (zignal)
**Specs**: core-flows.md §Flow 7
**Files**: `src/polyfills/image.zig`, `src/ts/bootstrap/image.ts`, update `src/root.zig`
**Dependencies**: T7, T12
**Effort**: Medium

**Description**:
Image constructor + createImageBitmap via zignal PNG/JPEG decode.

**Acceptance Criteria**:
- [ ] new Image(); img.src = "texture.png" → fetch + decode + "load" event
- [ ] createImageBitmap(blob) → Promise<ImageBitmap>
- [ ] PNG + JPEG decode to RGBA u8
- [ ] Data URI images decode
- [ ] img.width, img.height set
- [ ] onerror / "error" event on failure
- [ ] Wired into root.zig

---

### T15a: Comptime descriptor translator
**Specs**: tech-plan.md §Comptime Descriptor Translation
**Files**: `src/descriptor.zig`, update `src/root.zig`
**Dependencies**: T3
**Effort**: Medium
**Parallel group**: B, E

**Description**:
Generic comptime function that reflects on a Zig struct type and auto-reads matching properties from a JS object. This is the mechanical core of the WebGPU bridge — one function handles all ~30+ descriptor types.

**Acceptance Criteria**:
- [ ] `translateDescriptor(BufferDescriptor, ctx, js_obj)` reads size, usage, mappedAtCreation
- [ ] Handles: u32, i32, f32, f64, bool → direct conversion
- [ ] Handles: enums → integer cast
- [ ] Handles: ?T (optional) → check isUndefined
- [ ] Handles: []const u8 / [*:0]const u8 → toCString
- [ ] Handles: nested structs → recursive translateDescriptor
- [ ] Handles: HandleId fields → special case for handle lookups
- [ ] Missing required fields → error
- [ ] Undefined optional fields → zero/null default
- [ ] Wired into root.zig
- [ ] Unit tests with mock JS objects for each type case

**Implementation Steps**:

Step 1 — Core translateDescriptor generic
```zig
pub fn translateDescriptor(
    comptime T: type,
    ctx: *quickjs.Context,
    js_obj: quickjs.Value,
) !T {
    var result: T = std.mem.zeroes(T);
    inline for (std.meta.fields(T)) |field| {
        const js_val = js_obj.getPropertyStr(ctx, field.name);
        defer js_val.deinit(ctx);
        if (!js_val.isUndefined()) {
            @field(result, field.name) = try convertValue(field.type, ctx, js_val);
        }
    }
    return result;
}
```

Step 2 — convertValue: comptime switch on type
- Integers: toInt32 or toFloat64 + cast
- Floats: toFloat64
- Bools: toBool
- Enums: toInt32 + @enumFromInt
- Optionals: recurse on child type
- Strings: toCString
- Structs: recursive translateDescriptor
- HandleId: extract index + generation from JS number

Step 3 — Tests with real QJS context: create JS objects with various property types, translate, verify struct values match

---

### T15b: WebGPU bridge: adapter + device
**Specs**: core-flows.md §Flow 5, tech-plan.md §WebGPU Bridge
**Files**: `src/gpu_bridge.zig`, update `src/ts/bootstrap/gpu.ts`, update `src/root.zig`
**Dependencies**: T4, T5, T7, T15a
**Effort**: Medium

**Description**:
Core WebGPU bridge: navigator.gpu.requestAdapter() → GPUAdapter, adapter.requestDevice() → GPUDevice. Wire GPU class prototypes in TypeScript.

**Acceptance Criteria**:
- [ ] navigator.gpu.requestAdapter() → Promise<GPUAdapter> backed by zgpu
- [ ] adapter.requestDevice() → Promise<GPUDevice> backed by zgpu
- [ ] adapter.features and adapter.limits accessible
- [ ] device.queue exists
- [ ] Handles stored in HandleTable
- [ ] GC finalizer releases handles
- [ ] TypeScript GPU/GPUAdapter/GPUDevice classes wired to __native
- [ ] Wired into root.zig
- [ ] Integration test: JS requestAdapter → requestDevice succeeds

---

### T16: WebGPU bridge: buffers + textures + samplers
**Specs**: tech-plan.md §WebGPU Polyfill Classes
**Files**: update `src/gpu_bridge.zig`, update `src/ts/bootstrap/gpu.ts`
**Dependencies**: T15b
**Effort**: Medium
**Parallel group**: F

**Description**:
createBuffer, createTexture, createTextureView, createSampler. Buffer mapping. Queue writeBuffer/writeTexture.

**Acceptance Criteria**:
- [ ] device.createBuffer(descriptor) → GPUBuffer
- [ ] device.createTexture(descriptor) → GPUTexture
- [ ] texture.createView(descriptor?) → GPUTextureView
- [ ] device.createSampler(descriptor?) → GPUSampler
- [ ] buffer.mapAsync() → Promise, getMappedRange() → ArrayBuffer, unmap()
- [ ] queue.writeBuffer, queue.writeTexture work
- [ ] buffer.destroy() / texture.destroy() release handles
- [ ] Comptime translator handles all descriptor types

---

### T17: WebGPU bridge: shaders + pipelines
**Specs**: tech-plan.md §WebGPU Polyfill Classes
**Files**: update `src/gpu_bridge.zig`, update `src/ts/bootstrap/gpu.ts`
**Dependencies**: T15b
**Effort**: Medium
**Parallel group**: F

**Description**:
createShaderModule (WGSL), createBindGroupLayout, createPipelineLayout, createRenderPipeline, createComputePipeline, createBindGroup.

**Acceptance Criteria**:
- [ ] createShaderModule({ code: wgsl }) works
- [ ] createBindGroupLayout, createPipelineLayout work
- [ ] createRenderPipeline with vertex/fragment stages works
- [ ] createComputePipeline works
- [ ] createBindGroup works
- [ ] WGSL string passed correctly (no encoding corruption)
- [ ] Comptime translator handles nested descriptors (VertexState, FragmentState)

---

### T18: WebGPU bridge: command encoding + render pass
**Specs**: core-flows.md §Flow 5
**Files**: update `src/gpu_bridge.zig`, update `src/ts/bootstrap/gpu.ts`
**Dependencies**: T16, T17
**Effort**: Medium

**Description**:
Command recording path: createCommandEncoder → beginRenderPass → setPipeline/setBindGroup/setVertexBuffer/draw → end → finish → queue.submit.

**Acceptance Criteria**:
- [ ] createCommandEncoder → GPUCommandEncoder
- [ ] beginRenderPass(descriptor) → GPURenderPassEncoder
- [ ] setPipeline, setBindGroup, setVertexBuffer, setIndexBuffer
- [ ] draw(vertexCount), drawIndexed(indexCount)
- [ ] pass.end(), encoder.finish() → GPUCommandBuffer
- [ ] queue.submit([commandBuffer])
- [ ] Handle IDs forwarded correctly through full chain

---

### T19: WebGPU bridge: present (swap chain)
**Specs**: core-flows.md §Flow 4 (present step)
**Files**: update `src/gpu_bridge.zig`, update `src/event_loop.zig`
**Dependencies**: T18
**Effort**: Small

**Description**:
Surface configuration + getCurrentTexture + frame present.

**Acceptance Criteria**:
- [ ] context.configure({ device, format, alphaMode }) configures zgpu surface
- [ ] context.getCurrentTexture() returns swap chain texture view
- [ ] Present happens after queue.submit
- [ ] Resize → reconfigure surface
- [ ] No tearing or corruption

---

### T20: Triangle test: first native WebGPU render
**Specs**: tech-plan.md §M6 gate
**Files**: `examples/triangle/main.js`
**Dependencies**: T19
**Effort**: Small

**Description**:
End-to-end: JS creates pipeline + vertex shader + fragment shader → draws colored triangle. First visual proof-of-life.

**Acceptance Criteria**:
- [ ] Triangle renders in GLFW window
- [ ] Vertex colors interpolated correctly
- [ ] No crashes, no GPU validation errors
- [ ] Window stays open, can close cleanly

---

### T21a: Three.js integration: gap analysis
**Specs**: tech-plan.md §M7, §Risks
**Files**: `examples/threejs_basic/`, analysis document
**Dependencies**: T12, T14, T19
**Effort**: Medium

**Description**:
Bundle Three.js (latest, pinned commit hash) with esbuild. Attempt to evaluate in threez. Instrument with logging Proxy on window/document/navigator to capture every property access. Document all missing polyfills, unexpected API calls, and error paths.

**Acceptance Criteria**:
- [ ] Three.js version pinned (exact version + commit hash in VENDORED.md)
- [ ] esbuild bundle configuration documented
- [ ] Logging Proxy captures all property accesses on global objects
- [ ] Complete list of missing/failing APIs documented
- [ ] Each gap categorized: critical (blocks init), important (blocks render), nice-to-have
- [ ] Gap list saved to docs/specs/threez/threejs-gaps.md
- [ ] No code fixes in this ticket — analysis only

**Implementation Steps**:

Step 1 — Pin Three.js: `npm install three@latest`, record version + hash

Step 2 — esbuild config: bundle three/webgpu entry, ESM format, test different target settings

Step 3 — Instrument: inject logging Proxy before bootstrap.js
```js
const handler = { get(target, prop) { console.log(`ACCESS: ${target.constructor?.name}.${prop}`); return Reflect.get(target, prop); } };
globalThis.window = new Proxy(window, handler);
// similar for document, navigator
```

Step 4 — Attempt eval, capture output, categorize every logged access and every thrown error

Step 5 — Write docs/specs/threez/threejs-gaps.md with prioritized gap list

---

### T21b: Three.js integration: fix polyfill gaps
**Specs**: docs/specs/threez/threejs-gaps.md (output of T21a)
**Files**: Various polyfill files (TS + Zig), update `src/root.zig`
**Dependencies**: T21a
**Effort**: Large

**Description**:
Fix every critical and important gap identified in T21a. Add missing API stubs, extend existing polyfills, handle edge cases. Goal: `new THREE.WebGPURenderer()` + `await renderer.init()` succeeds.

**Acceptance Criteria**:
- [ ] All "critical" gaps from threejs-gaps.md resolved
- [ ] All "important" gaps resolved
- [ ] `new THREE.WebGPURenderer({ canvas })` succeeds
- [ ] `await renderer.init()` resolves (adapter + device acquired)
- [ ] `renderer.setSize(w, h)` works
- [ ] `renderer.setAnimationLoop(fn)` registers callback
- [ ] No "X is not a function" or "Y is undefined" from Three.js
- [ ] threejs-gaps.md updated with resolution notes

---

### T22: Three.js integration: simple scene render
**Specs**: tech-plan.md §M7
**Files**: update `examples/threejs_basic/`
**Dependencies**: T21b
**Effort**: Medium

**Description**:
Render a Three.js scene: colored box + directional light. Full render pipeline through Three.js abstractions.

**Acceptance Criteria**:
- [ ] Box renders in window
- [ ] Lighting visible (not flat)
- [ ] Background color clears
- [ ] Multiple frames, no crashes
- [ ] No GPU validation errors
- [ ] Camera projection correct (3D perspective)

---

### T23: Target demo: webgpu_loader_gltf
**Specs**: epic-brief.md §M1 Target, tech-plan.md §M8
**Files**: `examples/gltf_viewer/`
**Dependencies**: T11, T13, T14, T22
**Effort**: Large

**Description**:
Capstone. Adapt webgpu_loader_gltf demo. DamagedHelmet, orbit controls, animations, LDR environment (swap UltraHDR → standard JPEG).

**Acceptance Criteria**:
- [ ] DamagedHelmet.glb loads and renders
- [ ] PBR materials correct (metallic/roughness)
- [ ] LDR environment lighting works
- [ ] OrbitControls: drag rotate, scroll zoom, damping
- [ ] AnimationMixer plays animations
- [ ] Camera auto-frames model (Box3 math)
- [ ] Window resize updates viewport
- [ ] fetch() loads local assets + remote model-index.json
- [ ] Stable 60fps on reasonable hardware
- [ ] No crashes over 5 minutes of interaction

**Implementation Steps**:

Step 1 — Prepare assets: DamagedHelmet.glb, LDR JPEG env map, local model-index.json

Step 2 — Port demo to TypeScript: remove UltraHDRLoader → TextureLoader, remove Inspector/GUI, bundle with esbuild

Step 3 — Run and fix iteratively (GLTFLoader will exercise new WebGPU methods, texture formats, etc.)

Step 4 — Performance: verify 60fps, profile if needed

---

### T24: CLI + library packaging
**Specs**: epic-brief.md §Design Decisions, tech-plan.md §CLI
**Files**: update `src/main.zig`, library public API in `src/root.zig`
**Dependencies**: T23
**Effort**: Medium

**Description**:
Polish CLI (zig-clap) and library embed API.

**Acceptance Criteria**:
- [ ] `threez run <bundle.js>` loads and runs JS bundle
- [ ] `--assets <dir>`, `--width N`, `--height N`, `--strict`, `--max-handles N`, `--title`
- [ ] `--help`, `--version`
- [ ] Library: `threez.init(allocator, js_source, config) → Runtime`
- [ ] Library: `runtime.runLoop()`, `runtime.deinit()`
- [ ] @embedFile embed mode works
- [ ] `zig build` produces CLI binary + library artifact

---

## Summary

| Milestone | Tickets | Gate |
|-----------|---------|------|
| M0: Scaffolding | T1, T2, T3, T4 | zig build, QJS eval, GLFW window |
| M1: Bootstrap | T7, T8 | TS polyfills, console, performance |
| M2: Event loop | T9, T10, T11 | Timers, rAF, DOM events |
| M3: Platform I/O + Fetch | T6a, T6b, T6c, T12, T13 | io_uring/kqueue/IOCP, local+HTTP fetch |
| M4: Images | T14 | PNG/JPEG decode via zignal |
| M5: WebGPU core | T5, T15a, T15b, T16, T17 | Handle table, descriptors, adapter/device, resources, shaders |
| M6: WebGPU render | T18, T19, T20 | Command encoding, present, triangle renders |
| M7: Three.js | T21a, T21b, T22 | Gap analysis, fix gaps, simple scene |
| M8: Target demo | T23 | webgpu_loader_gltf runs |
| M9: Packaging | T24 | CLI + library |

**Total: 28 tickets across 10 milestones.**

### Critical Path

```
T1 → T3 → T7 → T9 → T10 → T11 ─────────────────────────────────┐
T2 ↗                                                              │
T1 → T4 ──────────────────→ T15b → T16 → T18 → T19 → T20       │
T1 → T6a → T12 → T13 ────────────────────────────────────┐       │
T3 → T15a ↗               T12 → T14 ─────────────────────┤       │
T1 → T5 ─────────────────→ T15b                           │       │
                                                           ↓       ↓
                                              T21a → T21b → T22 → T23 → T24
```
