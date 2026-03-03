/**
 * Type declarations for the __native global bridge.
 *
 * These functions are registered by Zig into the QuickJS context
 * before bootstrap.js runs. The actual implementations will be
 * wired up in later tickets; for now this file serves as the
 * typed contract between TypeScript and Zig.
 */

export interface NativeBridge {
  /** Request the pre-created GPU adapter (returns an opaque handle ID). */
  gpuRequestAdapter?(): number;
  /** Request the pre-created GPU device (returns an opaque handle ID). */
  gpuRequestDevice?(adapterId: number): number;
  /** Get the pre-created queue for a device (returns an opaque handle ID). */
  gpuGetQueue?(deviceId: number): number;

  /** Get the current window/surface dimensions. */
  getWindowWidth?(): number;
  getWindowHeight?(): number;
  getDevicePixelRatio?(): number;

  /** Request the next animation frame. */
  requestAnimationFrame?(callback: (time: number) => void): number;
  cancelAnimationFrame?(id: number): void;

  /** Logging bridge. */
  log?(level: string, ...args: unknown[]): void;

  /** Read a file synchronously, returning raw bytes or null on failure. */
  readFileSync?(path: string): Uint8Array | null;

  /** Decode a base64 string to raw bytes, or null on invalid input. */
  decodeBase64?(data: string): Uint8Array | null;

  /** Perform an HTTP/HTTPS GET request, returning response info or null on error. */
  httpFetch?(url: string): {
    status: number;
    statusText: string;
    contentType: string;
    body: Uint8Array;
  } | null;

  /** Decode PNG/JPEG image bytes to RGBA pixels, or null on failure. */
  decodeImage?(data: Uint8Array): {
    width: number;
    height: number;
    data: Uint8Array;
  } | null;

  // --- T16: Buffer / Texture / Sampler creation & destruction ---

  /** Create a GPU buffer, returning an opaque handle ID. */
  gpuCreateBuffer?(deviceId: number, descriptor: object): number;
  /** Create a GPU texture, returning an opaque handle ID. */
  gpuCreateTexture?(deviceId: number, descriptor: object): number;
  /** Create a texture view from a texture, returning an opaque handle ID. */
  gpuCreateTextureView?(textureId: number, descriptor?: object): number;
  /** Create a GPU sampler, returning an opaque handle ID. */
  gpuCreateSampler?(deviceId: number, descriptor?: object): number;
  /** Destroy a GPU buffer, releasing its handle. */
  gpuDestroyBuffer?(bufferId: number): void;
  /** Destroy a GPU texture, releasing its handle. */
  gpuDestroyTexture?(textureId: number): void;

  // --- T17: Shader / Pipeline / BindGroup creation ---

  /** Create a shader module from WGSL source, returning an opaque handle ID. */
  gpuCreateShaderModule?(deviceId: number, descriptor: object): number;
  /** Create a bind group layout, returning an opaque handle ID. */
  gpuCreateBindGroupLayout?(deviceId: number, descriptor: object): number;
  /** Create a pipeline layout, returning an opaque handle ID. */
  gpuCreatePipelineLayout?(deviceId: number, descriptor: object): number;
  /** Create a render pipeline, returning an opaque handle ID. */
  gpuCreateRenderPipeline?(deviceId: number, descriptor: object): number;
  /** Create a compute pipeline, returning an opaque handle ID. */
  gpuCreateComputePipeline?(deviceId: number, descriptor: object): number;
  /** Create a bind group, returning an opaque handle ID. */
  gpuCreateBindGroup?(deviceId: number, descriptor: object): number;

  // --- T18: Command encoding / render pass ---

  /** Create a command encoder, returning an opaque handle ID. */
  gpuCreateCommandEncoder?(deviceId: number): number;
  /** Begin a render pass on a command encoder, returning a render pass handle ID. */
  gpuCommandEncoderBeginRenderPass?(encoderId: number, descriptor: object): number;
  /** Set the pipeline on a render pass encoder. */
  gpuRenderPassSetPipeline?(passId: number, pipelineId: number): void;
  /** Set a bind group on a render pass encoder. */
  gpuRenderPassSetBindGroup?(passId: number, index: number, bindGroupId: number): void;
  /** Set a vertex buffer on a render pass encoder. */
  gpuRenderPassSetVertexBuffer?(passId: number, slot: number, bufferId: number, offset?: number, size?: number): void;
  /** Set the index buffer on a render pass encoder. */
  gpuRenderPassSetIndexBuffer?(passId: number, bufferId: number, format: string, offset?: number, size?: number): void;
  /** Record a draw call on a render pass encoder. */
  gpuRenderPassDraw?(passId: number, vertexCount: number, instanceCount?: number, firstVertex?: number, firstInstance?: number): void;
  /** Record an indexed draw call on a render pass encoder. */
  gpuRenderPassDrawIndexed?(passId: number, indexCount: number, instanceCount?: number, firstIndex?: number, baseVertex?: number, firstInstance?: number): void;
  /** End a render pass, freeing the render pass handle. */
  gpuRenderPassEnd?(passId: number): void;
  /** Finish command encoding, returning a command buffer handle ID. */
  gpuCommandEncoderFinish?(encoderId: number): number;
  /** Submit command buffers to a queue. */
  gpuQueueSubmit?(queueId: number, commandBuffers: number[]): void;
}

/**
 * The __native global, if registered by the Zig host.
 * May be undefined if bootstrap is evaluated in a plain QuickJS context
 * without native bindings (e.g., during testing).
 */
declare const __native: NativeBridge | undefined;

export function getNative(): NativeBridge | undefined {
  return typeof __native !== "undefined" ? __native : undefined;
}
