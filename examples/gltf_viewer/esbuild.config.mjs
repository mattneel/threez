/**
 * esbuild configuration for the glTF viewer example.
 *
 * Usage:
 *   node esbuild.config.mjs
 */

import * as esbuild from "esbuild";

const shared = {
  bundle: true,
  format: "iife",
  platform: "neutral",
  target: "es2020",
  sourcemap: false,
  minify: false,
  external: [],
  supported: { "top-level-await": true },
};

await esbuild.build({
  ...shared,
  entryPoints: ["gltf-viewer.js"],
  outfile: "dist/gltf-bundle.js",
});

console.log("Bundle written to dist/gltf-bundle.js");
