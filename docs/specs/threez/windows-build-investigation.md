<!-- status: locked -->
# Windows Build Investigation and Resolution

## Scope

- Investigate why native Windows builds were failing.
- Restore `zig build` and `zig build test` on Windows.
- Determine whether the Windows platform ticket (T6c: IOCP) can be closed.

## Failure Reproduction

Initial Windows run (`zig build`) failed during configure with:

- `panic: no dependency named 'system_sdk' in build.zig.zon`

After adding `system_sdk`, the next blockers surfaced:

- `error: writing lib files not yet implemented for COFF`
- `error: unable to update file ... threez.pdb ... FileNotFound`
- `zig build test` failed in `io.iocp.test.IocpPoll: file read` with panic from `CreateIoCompletionPort` / `INVALID_PARAMETER`

## Root Causes

1. `build.zig.zon` was missing `system_sdk`, which `zgpu_build.linkSystemDeps()` expects on Windows.
2. Build config forced `-fno-lld` on Windows (`use_lld = false`), which breaks COFF static-library output in this setup.
3. IOCP file tests were associating regular file handles that were not opened with `FILE_FLAG_OVERLAPPED` (required for IOCP file ops).
4. `associate()` used `std.os.windows.CreateIoCompletionPort` wrapper path that panics on `INVALID_PARAMETER`, turning a recoverable error into an abort.

## Fixes Applied

1. Added `system_sdk` dependency in [`build.zig.zon`](/C:/src/threez/build.zig.zon).
2. Updated [`build.zig`](/C:/src/threez/build.zig) to:
   - Use LLD on Windows (`use_lld = true` only on Windows targets).
   - Set `strip = true` on Windows modules to avoid missing PDB install artifact path in this toolchain/target configuration.
3. Updated IOCP implementation/tests in [`src/io/iocp.zig`](/C:/src/threez/src/io/iocp.zig):
   - `associate()` now returns `error.InvalidIocpAssociation` for `INVALID_PARAMETER` instead of panicking.
   - Added helper to open temporary files with `FILE_FLAG_OVERLAPPED`.
   - File-based IOCP tests now use overlapped file handles.

## Verification

All commands run on Windows (`target: x86_64-windows-gnu`):

1. `zig build -freference-trace` -> pass
2. `zig build test --summary all -freference-trace` -> pass (`190/190 tests passed`)
3. `zig test src/io/iocp.zig -target x86_64-windows-gnu -O Debug` -> pass (`9/9 tests passed`)

Note: `event_loop` warning logs (`rAF callback exception: Error: boom`) still appear during tests but do not fail the suite and are expected in existing tests.

## Ticket Closure Decision

T6c (Platform I/O: IOCP on Windows) can be closed based on:

- Successful Windows compile/build.
- IOCP-specific test suite passing on Windows.
- Full project test suite passing on Windows.

## Runtime Follow-up (2026-03-03)

After build/test fixes, `zig build run -- run examples\\gltf_viewer\\dist\\gltf-bundle.js` initially failed with:

- `SyntaxError: invalid UTF-8 sequence`

Observed behavior:

- `examples/triangle/main.js` ran.
- Bundled files (`scene-bundle.js`, `gltf-bundle.js`) failed before entering app logic.

Resolution:

1. [`src/window.zig`](/C:/src/threez/src/window.zig) was updated so GLFW `Platform.x11` hint is only set on Linux (fixes prior `PlatformUnavailable` on Windows).
2. [`src/main.zig`](/C:/src/threez/src/main.zig) now passes a NUL-terminated script buffer (`dupeZ`) into runtime eval path.

Verification:

- `zig build run -- run examples\\gltf_viewer\\dist\\gltf-bundle.js` -> exits 0, no UTF-8 parser error.
