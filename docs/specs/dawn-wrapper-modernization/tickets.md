<!-- status: locked -->
# Tickets: Dawn Wrapper Modernization

## Execution Order

Tickets are dependency-ordered. Parallel groups are marked where safe.

---

### T1: Converge native Dawn source builds under `build.zig`
**Specs**: `epic-brief.md`, `tech-plan.md` §Architecture Overview, §File Changes, §Milestone Sequencing
**Files**: [build.zig](/home/autark/src/threez/build.zig), [build.zig.zon](/home/autark/src/threez/build.zig.zon)
**Touch list**: build system, native dependency wiring
**Dependencies**: None
**Effort**: Medium
**Parallel group**: —

**Description**:
Move native Dawn source-build orchestration into `build.zig` for Windows, Linux, and Android. Remove reliance on `zgpu` library-path helpers as the authoritative native Dawn integration path.

**Acceptance Criteria**:
- [ ] `build.zig` owns the pinned Dawn revision and native target build orchestration
- [ ] Windows, Linux, and Android native builds point at the same Dawn source revision
- [ ] Native builds no longer depend on prebuilt Android Dawn archives
- [ ] Generated/header include paths required by current Dawn are available from the unified build

**Verification**:
- Native build commands for Windows, Linux, and Android complete through the Dawn build stage

**Rollback**:
- Revert build-system changes to restore the prior dependency wiring

**Failure Journal**:
- Symptom: `build.zig` failed before Dawn configuration with Zig 0.15.2 API mismatches (`std.process.run` unavailable on the actual stdlib in use, plus earlier `addExecutable` / `ArrayList` mismatches).
- Hypothesis tested: The native Dawn convergence patch could be made to work by updating the build script to the correct Zig 0.15.2 APIs while keeping the same overall design.
- Fix applied: Corrected the host-tool executable options shape, removed a shadowing local name, updated `ArrayList` usage, and simplified one `deleteTree` error path.
- Result: The design still blocks on the subprocess execution API surface available to this Zig toolchain.
- Next likely hypothesis: Replace the current imperative Dawn-preparation subprocess code with the correct Zig 0.15.2 process-spawn API, or move that prep work into build steps / a host helper that avoids relying on the unavailable API surface.

---

### T2: Introduce the raw current Dawn binding layer
**Specs**: `tech-plan.md` §Design Decisions, §Component Architecture, §Data Model
**Files**: [src/renderer/dawn/raw.zig](/home/autark/src/threez/src/renderer/dawn/raw.zig), [build.zig](/home/autark/src/threez/build.zig)
**Touch list**: raw bindings, include-path wiring
**Dependencies**: T1
**Effort**: Small
**Parallel group**: —

**Description**:
Create a minimal raw binding layer around the pinned `dawn/webgpu.h` using `@cImport`, with no policy or convenience behavior beyond namespacing.

**Acceptance Criteria**:
- [ ] Raw bindings compile against the pinned Dawn headers
- [ ] Raw layer exposes current Dawn/WebGPU types needed for adapter, device, queue, surface, strings, and futures
- [ ] No legacy `zgpu` ABI declarations are used by the new raw layer

**Verification**:
- Native compile of a small wrapper module depending only on the raw layer succeeds

**Rollback**:
- Remove the raw layer and restore prior wrapper-only dependency path

---

### T3: Implement string and async request helpers for the current API
**Specs**: `core-flows.md` §Flow 1, §Flow 2; `tech-plan.md` §Component Architecture, §Non-Negotiables / Invariants
**Files**: [src/renderer/dawn/strings.zig](/home/autark/src/threez/src/renderer/dawn/strings.zig), [src/renderer/dawn/async.zig](/home/autark/src/threez/src/renderer/dawn/async.zig), [src/renderer/dawn/raw.zig](/home/autark/src/threez/src/renderer/dawn/raw.zig)
**Touch list**: string conversion, adapter/device request lifecycle, wait/process logic
**Dependencies**: T2
**Effort**: Medium
**Parallel group**: A

**Description**:
Build the correctness-critical helper layer for `WGPUStringView`, adapter-info ownership, and current Dawn request/future handling. This ticket owns the “blocking but not frozen” init behavior.

**Acceptance Criteria**:
- [ ] `[]const u8` and nullable labels are converted correctly to `WGPUStringView`
- [ ] Adapter info strings are copied into Zig-owned memory and raw members are freed correctly
- [ ] Adapter/device request helpers use callback-info structs and current Dawn wait/process primitives
- [ ] Init path can synchronously wait for adapter/device completion without depending on removed callback entrypoints

**Verification**:
- Native smoke tests or compile-time exercise of adapter/device request helpers succeed
- Logging shows stable adapter/device status reporting

**Rollback**:
- Remove helper modules and revert call sites to the prior path

---

### T4: Implement surface creation and frame acquisition on the current API
**Specs**: `core-flows.md` §Flow 3, §Flow 4; `tech-plan.md` §Surface model, §Component Architecture
**Files**: [src/platform/native_surface.zig](/home/autark/src/threez/src/platform/native_surface.zig), [src/renderer/dawn/surface.zig](/home/autark/src/threez/src/renderer/dawn/surface.zig)
**Touch list**: native surface descriptors, surface configure/acquire/present, resize/loss handling
**Dependencies**: T2
**Effort**: Medium
**Parallel group**: A

**Description**:
Implement the current surface-based presentation path. This replaces the old swapchain mental model and defines the renderer/platform seam for native handles.

**Acceptance Criteria**:
- [ ] Native surface sources exist for Windows, Linux, Android, and best-effort macOS
- [ ] Surface configure / unconfigure works through current Dawn APIs
- [ ] Frame acquisition returns an explicit acquired-frame object with surface status
- [ ] Present path uses the current surface presentation API
- [ ] Resize / outdated / lost states are surfaced explicitly

**Verification**:
- Native compile of the surface module succeeds for in-scope native targets
- A frame can be acquired and presented from a minimal integration path on at least one desktop target

**Rollback**:
- Remove new surface module and revert frame acquisition path

---

### T5: Replace `zgpu` context ownership with a new internal `GraphicsContext`
**Specs**: `core-flows.md` §Flow 2, §Flow 3, §Flow 4; `tech-plan.md` §RendererContext, §Interfaces & Compatibility
**Files**: [src/renderer/dawn/context.zig](/home/autark/src/threez/src/renderer/dawn/context.zig), [src/window.zig](/home/autark/src/threez/src/window.zig), [src/android_window.zig](/home/autark/src/threez/src/android_window.zig), [src/android_runtime.zig](/home/autark/src/threez/src/android_runtime.zig), [src/android_app.zig](/home/autark/src/threez/src/android_app.zig)
**Touch list**: renderer context lifecycle, platform integration, surface attach/detach
**Dependencies**: T3, T4
**Effort**: Large
**Parallel group**: —

**Description**:
Replace `zgpu.GraphicsContext` as the active renderer context with the new internal `GraphicsContext` backed by the current Dawn wrapper. Preserve synchronous-looking app/runtime semantics.

**Acceptance Criteria**:
- [ ] Desktop and Android window code stop constructing `zgpu.GraphicsContext`
- [ ] New `GraphicsContext` owns instance, adapter, device, queue, and optional surface state
- [ ] Device lifetime is decoupled from transient surface lifetime
- [ ] Android lifecycle can detach and reattach surfaces without redefining renderer ownership

**Verification**:
- Windows and Linux app paths boot through the new context
- Android app path initializes through the new context without legacy compat entrypoints

**Rollback**:
- Revert the context call sites to `zgpu.GraphicsContext`

---

### T6: Port `gpu_bridge` and runtime frame flow off the old swapchain path
**Specs**: `core-flows.md` §Flow 3; `tech-plan.md` §File Changes, §Risks and Mitigations
**Files**: [src/gpu_bridge.zig](/home/autark/src/threez/src/gpu_bridge.zig), [src/runtime.zig](/home/autark/src/threez/src/runtime.zig), [src/ts/bootstrap/gpu.ts](/home/autark/src/threez/src/ts/bootstrap/gpu.ts), [src/ts/dist/bootstrap.js](/home/autark/src/threez/src/ts/dist/bootstrap.js)
**Touch list**: frame acquisition, present semantics, runtime assumptions, comments/generated JS if needed
**Dependencies**: T5
**Effort**: Medium
**Parallel group**: —

**Description**:
Migrate frame acquisition and presentation from the old `zgpu` swapchain-centric assumptions to the new surface-based context API.

**Acceptance Criteria**:
- [ ] `gpu_bridge` no longer depends on `zgpu` swapchain semantics
- [ ] Runtime frame path uses acquired-frame/present behavior from the new context
- [ ] Comments or runtime assumptions implying pre-created `zgpu` swapchain ownership are removed or updated
- [ ] Shader-module instrumentation remains intact until Android diagnosis is complete

**Verification**:
- Windows and Linux render through the migrated frame path
- Android reaches the post-wrapper runtime path cleanly

**Rollback**:
- Revert frame-path integration to the prior bridge/runtime flow

---

### T7: Remove legacy native renderer shims and old `zgpu` Dawn path from active native code
**Specs**: `epic-brief.md` §Goals, §Constraints; `tech-plan.md` §Deleted Files / Deleted Responsibilities
**Files**: [src/android_wgpu_shim.c](/home/autark/src/threez/src/android_wgpu_shim.c), [deps/zgpu/src/wgpu.zig](/home/autark/src/threez/deps/zgpu/src/wgpu.zig), [deps/zgpu/src/zgpu.zig](/home/autark/src/threez/deps/zgpu/src/zgpu.zig), [deps/zgpu/src/dawn_proc.c](/home/autark/src/threez/deps/zgpu/src/dawn_proc.c), [deps/zgpu/src/dawn.cpp](/home/autark/src/threez/deps/zgpu/src/dawn.cpp), [build.zig](/home/autark/src/threez/build.zig)
**Touch list**: dead-path removal, dependency cleanup
**Dependencies**: T6
**Effort**: Medium
**Parallel group**: —

**Description**:
Delete the legacy native renderer path and compatibility scaffolding once the new wrapper is active.

**Acceptance Criteria**:
- [ ] Active native targets no longer depend on legacy compat shims for removed WebGPU entrypoints
- [ ] Old `zgpu` native renderer path is removed from active build/runtime wiring
- [ ] Build graph no longer compiles obsolete Dawn proc compatibility code for active native paths

**Verification**:
- Native builds succeed without the removed files in the active path
- Search confirms no active native code imports the removed `zgpu` renderer path

**Rollback**:
- Restore deleted compatibility path and dependency wiring

---

### T8: Validate native targets and re-baseline the Android renderer bug
**Specs**: `epic-brief.md` §Success Criteria; `tech-plan.md` §Testing Strategy
**Files**: build/runtime files touched by prior tickets; spec note updates if needed
**Touch list**: validation, diagnosis handoff
**Dependencies**: T7
**Effort**: Medium
**Parallel group**: —

**Description**:
Run the native validation pass for the new wrapper path. Confirm Windows and Linux still boot/render, Android now reaches the real post-wrapper bug or renders successfully, and macOS remains best-effort via CI.

**Acceptance Criteria**:
- [ ] Windows boots and renders through the modernized wrapper
- [ ] Linux boots and renders through the modernized wrapper
- [ ] Android no longer fails because of old wrapper/API drift
- [ ] Android either renders or reaches the original post-wrapper bug cleanly enough for follow-up diagnosis
- [ ] macOS CI compile/run status is preserved or any regression is documented explicitly

**Verification**:
- Native build/run checks per platform
- Android install/launch/log capture
- CI confirmation for best-effort macOS path

**Rollback**:
- Revert to the last known good migration milestone and re-enable blocked path only as a temporary branch-local fallback
