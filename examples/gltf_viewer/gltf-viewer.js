/**
 * glTF Viewer Demo (T23).
 *
 * Loads and renders DamagedHelmet.glb with PBR materials and OrbitControls.
 *
 * Usage:
 *   1. cd examples/gltf_viewer && npm install && node esbuild.config.mjs
 *   2. threez run dist/gltf-bundle.js
 */

import * as THREE from "three";
import { WebGPURenderer } from "three/webgpu";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

async function main() {
  // --- Renderer ---
  const renderer = new WebGPURenderer({ antialias: false });
  await renderer.init();
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.setClearColor(0x333355);

  // --- Scene ---
  const scene = new THREE.Scene();

  // --- Camera ---
  const camera = new THREE.PerspectiveCamera(
    45,
    window.innerWidth / window.innerHeight,
    0.1,
    100,
  );
  camera.position.set(0, 0, 3);

  // --- OrbitControls ---
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.target.set(0, 0, 0);
  controls.enableDamping = true;
  controls.dampingFactor = 0.05;
  controls.update();

  // --- Lighting ---
  const ambient = new THREE.AmbientLight(0xffffff, 0.8);
  scene.add(ambient);

  const directional = new THREE.DirectionalLight(0xffffff, 2.0);
  directional.position.set(3, 4, 5);
  scene.add(directional);

  const fillLight = new THREE.DirectionalLight(0xffffff, 1.0);
  fillLight.position.set(-3, 0, -3);
  scene.add(fillLight);

  // --- Load glTF model ---
  const loader = new GLTFLoader();
  loader.load(
    "assets/DamagedHelmet.glb",
    (gltf) => {
      scene.add(gltf.scene);
      console.log("DamagedHelmet loaded successfully");
    },
    (progress) => {
      if (progress.total > 0) {
        const pct = Math.round((progress.loaded / progress.total) * 100);
        console.log(`Loading: ${pct}%`);
      }
    },
    (error) => {
      console.error("Failed to load glTF:", error.message || error);
    },
  );

  // --- Resize handling ---
  // Poll for size changes each frame (robust against swap chain timing).
  let currentWidth = window.innerWidth;
  let currentHeight = window.innerHeight;

  function handleResize() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    if (w !== currentWidth || h !== currentHeight) {
      currentWidth = w;
      currentHeight = h;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
  }

  // --- Animation loop ---
  renderer.setAnimationLoop((time) => {
    handleResize();
    controls.update();
    renderer.render(scene, camera);
  });
}

main().catch((e) => {
  console.error("glTF viewer failed:", e.message || e);
});
