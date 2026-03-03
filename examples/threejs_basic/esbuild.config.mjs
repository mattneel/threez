/**
 * esbuild configuration for bundling the Three.js test script.
 *
 * Bundles test-init.js into a single IIFE file (dist/test-bundle.js)
 * that can be evaluated in the threez QuickJS-NG runtime.
 *
 * Usage:
 *   npx esbuild --bundle test-init.js --format=iife --outfile=dist/test-bundle.js
 *
 * Or via this config:
 *   node esbuild.config.mjs
 */

import * as esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["test-init.js"],
  bundle: true,
  format: "iife",
  outfile: "dist/test-bundle.js",
  platform: "neutral",
  target: "es2020",
  sourcemap: false,
  minify: false,
  // Don't mark any imports as external — bundle everything
  external: [],
  // Treat top-level await correctly
  supported: {
    "top-level-await": true,
  },
});

console.log("Bundle written to dist/test-bundle.js");
