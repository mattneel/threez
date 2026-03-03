# Vendored: zig-quickjs-ng

Upstream: https://github.com/mitchellh/zig-quickjs-ng
Commit: eb1d44ce43fd64f8403c1a94fad242ebae04d1fb
Date: 2026-01-06

## Patches applied:
- build.zig.zon: Updated `.minimum_zig_version` from "0.14.0" to "0.15.0" for Zig 0.15 compatibility
- src/context.zig: Added "eval 1+1 equals 2" smoke test (runtime -> context -> eval -> check result)
