/**
 * Three.js simple scene render (T22).
 *
 * Renders a colored box with a directional light using Three.js WebGPURenderer.
 * This is the first Three.js scene running through the threez native runtime.
 *
 * Usage:
 *   1. cd examples/threejs_basic && node esbuild.config.mjs
 *   2. threez run dist/scene-bundle.js
 */

import * as THREE from "three";
import { WebGPURenderer } from "three/webgpu";

async function main() {
  // --- Renderer ---
  const renderer = new WebGPURenderer({ antialias: true });
  await renderer.init();
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.setClearColor(0x1a1a2e);

  // --- Scene ---
  const scene = new THREE.Scene();

  // --- Camera ---
  const camera = new THREE.PerspectiveCamera(
    70,
    window.innerWidth / window.innerHeight,
    0.1,
    100,
  );
  camera.position.set(2, 2, 3);
  camera.lookAt(0, 0, 0);

  // --- Box ---
  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const material = new THREE.MeshStandardMaterial({ color: 0x4cc9f0 });
  const mesh = new THREE.Mesh(geometry, material);
  scene.add(mesh);

  // --- Lighting ---
  const ambient = new THREE.AmbientLight(0x404040);
  scene.add(ambient);

  const directional = new THREE.DirectionalLight(0xffffff, 1.5);
  directional.position.set(3, 4, 5);
  scene.add(directional);

  // --- Animation loop ---
  renderer.setAnimationLoop((time) => {
    const t = time * 0.001;
    mesh.rotation.x = t * 0.5;
    mesh.rotation.y = t * 0.7;
    renderer.render(scene, camera);
  });
}

main().catch((e) => {
  console.error("Scene failed:", e.message || e);
});
