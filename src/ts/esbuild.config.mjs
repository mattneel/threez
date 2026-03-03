import * as esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["bootstrap/index.ts"],
  outfile: "dist/bootstrap.js",
  bundle: true,
  format: "iife",
  platform: "neutral",
  target: "es2023",
});
