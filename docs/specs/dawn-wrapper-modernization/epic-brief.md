<!-- status: locked -->
<!-- epic-slug: dawn-wrapper-modernization -->
# Epic Brief: Dawn Wrapper Modernization

## Problem

`threez` currently cannot evaluate newer Dawn/Tint behavior cleanly because the codebase mixes:

- source-built Dawn on Android only
- prebuilt / older integration assumptions elsewhere
- an ancient handwritten `zgpu` WebGPU ABI layer that no longer matches current `webgpu.h`

This creates two concrete problems:

1. Android crash debugging is blocked by wrapper drift, so "does newer Dawn/Tint fix the shader crash?" cannot be answered cleanly.
2. Desktop and Android renderer paths are drifting apart even though they should share the same Dawn-backed renderer contract.

## Who's Affected

- **Renderer maintainers**: they cannot upgrade Dawn/Tint without chasing stale ABI symbols and behavior.
- **Platform implementers**: Android and desktop integration are coupled to renderer churn instead of a clean platform boundary.
- **App/runtime developers**: they cannot trust that behavior observed on one native target meaningfully represents the others.

## Actors

| Actor | Description |
|-------|-------------|
| **Renderer layer** | The Dawn-backed rendering backend used by `threez` today |
| **Platform layer** | Android / desktop windowing, lifecycle, and native surface integration |
| **App layer** | The `threez` runtime and sample apps using the renderer |
| **Future renderer backends** | Deliberately out-of-scope backends that motivate keeping the renderer/platform seam clean |

## Goals

- Establish Dawn as a single pinned source dependency for all native targets in scope.
- Replace stale handwritten low-level WebGPU ABI assumptions and `zgpu` dependency assumptions with a current, trustworthy wrapper surface.
- Preserve the architectural split: renderer backend vs platform/windowing abstraction.
- Make Android and desktop exercise the same Dawn/WebGPU contract wherever platform differences are not inherent.
- Unblock meaningful diagnosis of the Android shader crash on a current Dawn/Tint stack.

## Non-Goals

- Supporting Emscripten / web targets in this epic.
- Adding a new OpenGL / ES2 renderer in this epic.
- Reworking app-level rendering semantics beyond what is required by the wrapper migration.
- Shipping new user-facing rendering features.
- Preserving `zgpu` as a dependency or compatibility boundary.

## Constraints

- `renderer = Dawn` for this epic.
- `platform = OS/windowing/native-surface abstraction`; platform code should not absorb renderer concerns.
- Native targets should converge on one wrapper story, not a pile of compatibility shims.
- Existing code paths should keep working incrementally enough to permit staged migration instead of a full stop-the-world rewrite.
- The migration must leave a credible path for additional renderer backends later.
- Final state must not depend on legacy compatibility shims for removed WebGPU entrypoints.
- Current native targets in scope are Windows, Linux, and Android; Android is the active port pressure.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Native renderer backend | Dawn | Existing renderer direction; current issue is integration drift, not backend choice |
| Dependency strategy | Source-built Dawn for native targets | Avoid stale prebuilt static libraries and ABI mismatch surprises |
| ABI strategy | Proper current wrapper, not ongoing symbol-by-symbol shims | The current breakage spans callbacks, strings, swapchain/surface, descriptors, and request lifecycles |
| Architecture split | Renderer and platform stay separate | Required for maintainability and future backend expansion |
| Legacy wrapper strategy | Replace `zgpu`/old `wgpu` assumptions rather than preserve them | The existing bindings are known stale and are now blocking the port |

## Success Criteria

- Native builds no longer rely on vendored prebuilt Android Dawn archives.
- Android, Windows, and Linux use the same current Dawn/WebGPU wrapper model where platform differences are not inherent.
- The renderer wrapper no longer depends on removed legacy WebGPU entrypoints such as old callback and swapchain APIs.
- The app boots and renders on all native targets in scope: Windows, Linux, and Android.
- The app can be run on Android against the modernized Dawn stack far enough to evaluate the original crash meaningfully.

## Out of Scope

- Web / Emscripten support
- WebGL2 compatibility renderer work
- Rendering feature additions
- UI / sample redesign
- Wide architectural cleanup outside renderer/platform boundaries

## Context

Recent investigation showed:

- newer Dawn/Tint can be source-built for Android in this repo
- the old Android prebuilt archive was not the root cause of the observed breakage
- after upgrading Dawn, the repo hits broad wrapper/API drift:
  - old adapter properties API
  - old callback signatures
  - old swapchain APIs
  - old C-string label assumptions versus `WGPUStringView`

That means this epic is not "upgrade one library and retest." It is a dependency and wrapper modernization effort needed to make future Dawn/Tint updates routine.

## Definitions

- **Renderer backend**: the implementation of GPU resource creation, shader/pipeline management, submission, and presentation.
- **Platform layer**: the OS-facing code that provides windows, lifecycle, input, and native surface handles.
- **Wrapper**: the Zig-side interface sitting above Dawn's C API and below the app/runtime code.
- **Meaningful crash reproduction**: reproducing the original Android failure after wrapper/API compatibility issues are removed, so the result reflects Dawn/Tint behavior rather than integration drift.
- **No legacy compatibility**: the final state does not ship old-entrypoint shims as part of the renderer path.

## Assumptions & Unknowns

| Item | Type | How to Validate | Owner |
|------|------|-----------------|-------|
| Native targets can share one low-level Dawn binding strategy | Assumption | Port Android and one desktop target through the same wrapper surface | Engineering |
| Existing app/runtime renderer call sites can survive a wrapper replacement with manageable churn | Assumption | Confirm through tech plan touch list and staged migration plan | Engineering |
| Emscripten can remain out of scope without harming this epic | Assumption | Confirmed by epic scope | Engineering |
| The original Android Tint crash still exists once wrapper drift is removed | Unknown | Reproduce after migration | Engineering |

## Kill Criteria / Stop Conditions

Pause and re-scope if any of the following becomes true:

- Current Dawn requires a wrapper shape that makes cross-platform convergence unrealistic without a much larger renderer rewrite.
- The existing app/runtime contract depends on old `zgpu` behavior that cannot be removed without turning this into a broader renderer rewrite.
- The migration cost expands into a general renderer rewrite instead of a wrapper/dependency modernization.
