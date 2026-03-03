/**
 * Three.js integration test with logging Proxy.
 *
 * This script wraps globalThis.window/document/navigator in a logging Proxy
 * BEFORE importing Three.js, to capture every property access. Then it
 * attempts to construct a WebGPURenderer, create a scene, and render.
 *
 * The output is a list of all accessed properties on browser globals,
 * plus any errors encountered.
 */

// ---------------------------------------------------------------------------
// Logging Proxy setup — must run BEFORE Three.js import
// ---------------------------------------------------------------------------

const accessLog = {
  window: new Set(),
  document: new Set(),
  navigator: new Set(),
  self: new Set(),
  errors: [],
};

function createLoggingProxy(target, name) {
  if (!target || typeof target !== "object") return target;
  return new Proxy(target, {
    get(obj, prop) {
      if (typeof prop === "string") {
        accessLog[name].add(`get:${prop}`);
      }
      try {
        const val = Reflect.get(obj, prop);
        // Wrap sub-objects for deeper tracking
        if (val && typeof val === "object" && !Array.isArray(val) && prop !== "constructor") {
          // Don't re-proxy if already proxied
          return val;
        }
        return val;
      } catch (e) {
        accessLog.errors.push(`${name}.${String(prop)} GET threw: ${e.message}`);
        return undefined;
      }
    },
    set(obj, prop, value) {
      if (typeof prop === "string") {
        accessLog[name].add(`set:${prop}`);
      }
      return Reflect.set(obj, prop, value);
    },
    has(obj, prop) {
      if (typeof prop === "string") {
        accessLog[name].add(`has:${prop}`);
      }
      return Reflect.has(obj, prop);
    },
  });
}

// Wrap existing globals in logging proxies
if (typeof globalThis.window !== "undefined") {
  globalThis.window = createLoggingProxy(globalThis.window, "window");
}
if (typeof globalThis.document !== "undefined") {
  globalThis.document = createLoggingProxy(globalThis.document, "document");
}
if (typeof globalThis.navigator !== "undefined") {
  globalThis.navigator = createLoggingProxy(globalThis.navigator, "navigator");
}
if (typeof globalThis.self !== "undefined") {
  globalThis.self = createLoggingProxy(globalThis.self, "self");
}

// ---------------------------------------------------------------------------
// Three.js import and test
// ---------------------------------------------------------------------------

async function runTest() {
  try {
    const THREE = await import("three");

    console.log("=== Three.js loaded successfully ===");
    console.log("THREE.REVISION:", THREE.REVISION);

    // Attempt to create a WebGPURenderer
    let renderer;
    try {
      const { WebGPURenderer } = await import("three/webgpu");
      renderer = new WebGPURenderer();
      console.log("WebGPURenderer created");
    } catch (e) {
      accessLog.errors.push(`WebGPURenderer constructor: ${e.message}`);
      console.error("WebGPURenderer constructor failed:", e.message);
    }

    // Attempt renderer.init()
    if (renderer) {
      try {
        await renderer.init();
        console.log("renderer.init() succeeded");
      } catch (e) {
        accessLog.errors.push(`renderer.init(): ${e.message}`);
        console.error("renderer.init() failed:", e.message);
      }

      // Attempt setSize — use actual window dimensions to match swap chain
      try {
        renderer.setSize(window.innerWidth, window.innerHeight);
        console.log("renderer.setSize() succeeded");
      } catch (e) {
        accessLog.errors.push(`renderer.setSize(): ${e.message}`);
        console.error("renderer.setSize() failed:", e.message);
      }
    }

    // Create scene objects
    let scene, camera, mesh;
    try {
      scene = new THREE.Scene();
      camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
      camera.position.z = 5;

      const geometry = new THREE.BoxGeometry(1, 1, 1);
      const material = new THREE.MeshBasicMaterial({ color: 0x00ff00 });
      mesh = new THREE.Mesh(geometry, material);
      scene.add(mesh);

      console.log("Scene objects created successfully");
    } catch (e) {
      accessLog.errors.push(`Scene creation: ${e.message}`);
      console.error("Scene creation failed:", e.message);
    }

    // Attempt render
    if (renderer && scene && camera) {
      try {
        renderer.render(scene, camera);
        console.log("render() succeeded");
      } catch (e) {
        accessLog.errors.push(`renderer.render(): ${e.message}`);
        console.error("renderer.render() failed:", e.message);
        console.error("Stack:", e.stack);
      }
    }
  } catch (e) {
    accessLog.errors.push(`Top-level import: ${e.message}`);
    console.error("Three.js import failed:", e.message);
  }

  // ---------------------------------------------------------------------------
  // Dump results
  // ---------------------------------------------------------------------------

  console.log("\n=== ACCESS LOG ===\n");

  for (const [name, accesses] of Object.entries(accessLog)) {
    if (name === "errors") continue;
    if (accesses.size > 0) {
      console.log(`--- ${name} (${accesses.size} unique accesses) ---`);
      for (const access of [...accesses].sort()) {
        console.log(`  ${access}`);
      }
    }
  }

  if (accessLog.errors.length > 0) {
    console.log(`\n--- ERRORS (${accessLog.errors.length}) ---`);
    for (const err of accessLog.errors) {
      console.log(`  ${err}`);
    }
  }
}

runTest().catch((e) => {
  console.error("Unhandled error:", e);
});
