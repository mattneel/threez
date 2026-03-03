# Vendored Dependencies

## zig-quickjs-ng

- Upstream: https://github.com/mitchellh/zig-quickjs-ng
- Commit: eb1d44ce43fd64f8403c1a94fad242ebae04d1fb
- Date: 2026-01-06
- Location: deps/zig-quickjs-ng/
- See: deps/zig-quickjs-ng/VENDORED.md for patch details

## Three.js (examples/threejs_basic)

- Upstream: https://github.com/mrdoob/three.js
- Version: 0.183.2
- Commit: 1939c35f2d92a4c870568da011aab54dabdfdd30
- Registry: https://registry.npmjs.org/three/-/three-0.183.2.tgz
- Date pinned: 2026-03-02
- Location: examples/threejs_basic/node_modules/three/
- Purpose: Integration testing and gap analysis for threez WebGPU polyfill layer
- Notes: Installed via npm, not vendored into source tree. Pin version in package.json.
