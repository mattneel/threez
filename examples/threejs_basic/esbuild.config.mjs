/**
 * esbuild configuration for bundling Three.js examples.
 *
 * Builds all entry points into dist/ as IIFE bundles for the
 * threez QuickJS-NG runtime.
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
  entryPoints: ["test-init.js"],
  outfile: "dist/test-bundle.js",
});

await esbuild.build({
  ...shared,
  entryPoints: ["scene.js"],
  outfile: "dist/scene-bundle.js",
});

console.log("Bundles written to dist/");
