/**
 * WebGPU usage/mode/stage constants for globalThis.
 *
 * Three.js accesses these as global constants (e.g. GPUBufferUsage.VERTEX)
 * for bitflag operations in buffer/texture creation.
 */

export function installWebGPUConstants(): void {
  const g = globalThis as any;

  g.GPUBufferUsage = Object.freeze({
    MAP_READ: 1,
    MAP_WRITE: 2,
    COPY_SRC: 4,
    COPY_DST: 8,
    INDEX: 16,
    VERTEX: 32,
    UNIFORM: 64,
    STORAGE: 128,
    INDIRECT: 256,
    QUERY_RESOLVE: 512,
  });

  g.GPUTextureUsage = Object.freeze({
    COPY_SRC: 1,
    COPY_DST: 2,
    TEXTURE_BINDING: 4,
    STORAGE_BINDING: 8,
    RENDER_ATTACHMENT: 16,
  });

  g.GPUMapMode = Object.freeze({
    READ: 1,
    WRITE: 2,
  });

  g.GPUShaderStage = Object.freeze({
    VERTEX: 1,
    FRAGMENT: 2,
    COMPUTE: 4,
  });
}
