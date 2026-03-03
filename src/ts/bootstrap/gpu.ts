/**
 * WebGPU polyfill classes for the threez runtime.
 *
 * These classes wrap native handle IDs returned by the Zig GPU bridge.
 * Since zgpu pre-creates the adapter, device, and queue at startup,
 * requestAdapter() and requestDevice() resolve immediately with the
 * pre-existing handles.
 */

import { EventTarget } from "./event-target";
import { getNative } from "./native";

// ---------------------------------------------------------------------------
// GPUBuffer
// ---------------------------------------------------------------------------

export class GPUBuffer {
  _handle: number;
  _device: GPUDevice;
  readonly size: number;
  readonly usage: number;

  constructor(handle: number, device: GPUDevice, size: number, usage: number) {
    this._handle = handle;
    this._device = device;
    this.size = size;
    this.usage = usage;
  }

  async mapAsync(_mode?: number, _offset?: number, _size?: number): Promise<void> {
    // Stub — real mapping requires async I/O bridge (future ticket)
  }

  getMappedRange(_offset?: number, _size?: number): ArrayBuffer {
    // Stub — returns empty buffer until mapping is wired
    return new ArrayBuffer(_size ?? this.size);
  }

  unmap(): void {
    // Stub
  }

  destroy(): void {
    const native = getNative();
    native?.gpuDestroyBuffer?.(this._handle);
  }
}

// ---------------------------------------------------------------------------
// GPUTexture / GPUTextureView
// ---------------------------------------------------------------------------

export class GPUTextureView {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

export class GPUTexture {
  _handle: number;
  _device: GPUDevice;
  readonly width: number;
  readonly height: number;
  readonly depthOrArrayLayers: number;
  readonly mipLevelCount: number;
  readonly sampleCount: number;
  readonly dimension: string;
  readonly format: string;
  readonly usage: number;

  constructor(handle: number, device: GPUDevice, descriptor?: {
    width?: number; height?: number; depthOrArrayLayers?: number;
    mipLevelCount?: number; sampleCount?: number; dimension?: string;
    format?: string; usage?: number;
  }) {
    this._handle = handle;
    this._device = device;
    this.width = descriptor?.width ?? 0;
    this.height = descriptor?.height ?? 1;
    this.depthOrArrayLayers = descriptor?.depthOrArrayLayers ?? 1;
    this.mipLevelCount = descriptor?.mipLevelCount ?? 1;
    this.sampleCount = descriptor?.sampleCount ?? 1;
    this.dimension = descriptor?.dimension ?? "2d";
    this.format = descriptor?.format ?? "rgba8unorm";
    this.usage = descriptor?.usage ?? 0;
  }

  createView(descriptor?: object): GPUTextureView {
    const native = getNative();
    const handle = native?.gpuCreateTextureView?.(this._handle, descriptor ?? {}) as number ?? 0;
    return new GPUTextureView(handle);
  }

  destroy(): void {
    const native = getNative();
    native?.gpuDestroyTexture?.(this._handle);
  }
}

// ---------------------------------------------------------------------------
// GPUCanvasContext
// ---------------------------------------------------------------------------

export class GPUCanvasContext {
  private _configured = false;
  private _device: GPUDevice | null = null;
  private _format: string = "bgra8unorm";

  configure(config: { device: GPUDevice; format?: string; alphaMode?: string }): void {
    this._device = config.device;
    this._format = config.format ?? "bgra8unorm";
    this._configured = true;
    const native = getNative();
    native?.gpuConfigureContext?.(config.device._handle, this._format, config.alphaMode ?? "opaque", 0, 0);
  }

  unconfigure(): void {
    this._configured = false;
    this._device = null;
  }

  getCurrentTexture(): GPUTexture {
    const native = getNative();
    const handle = native?.gpuGetCurrentTexture?.() as number ?? 0;
    return new GPUTexture(handle, this._device!, {
      format: this._format,
      usage: 0x10, // GPUTextureUsage.RENDER_ATTACHMENT
    });
  }

  // Internal: called by event loop after queue.submit
  present(): void {
    const native = getNative();
    native?.gpuPresent?.();
  }

  get configured(): boolean {
    return this._configured;
  }
}

// ---------------------------------------------------------------------------
// GPUSampler
// ---------------------------------------------------------------------------

export class GPUSampler {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

// ---------------------------------------------------------------------------
// GPUShaderModule
// ---------------------------------------------------------------------------

export class GPUShaderModule {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

// ---------------------------------------------------------------------------
// GPUBindGroupLayout / GPUPipelineLayout / GPUBindGroup
// ---------------------------------------------------------------------------

export class GPUBindGroupLayout {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

export class GPUPipelineLayout {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

export class GPUBindGroup {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

// ---------------------------------------------------------------------------
// GPURenderPipeline / GPUComputePipeline
// ---------------------------------------------------------------------------

export class GPURenderPipeline {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  getBindGroupLayout(index: number): GPUBindGroupLayout {
    const native = getNative();
    const handle = native?.gpuRenderPipelineGetBindGroupLayout?.(this._handle, index) as number ?? 0;
    return new GPUBindGroupLayout(handle);
  }
}

export class GPUComputePipeline {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  getBindGroupLayout(index: number): GPUBindGroupLayout {
    const native = getNative();
    const handle = native?.gpuComputePipelineGetBindGroupLayout?.(this._handle, index) as number ?? 0;
    return new GPUBindGroupLayout(handle);
  }
}

// ---------------------------------------------------------------------------
// GPUQuerySet
// ---------------------------------------------------------------------------

export class GPUQuerySet {
  readonly type: string;
  readonly count: number;

  constructor(type: string, count: number) {
    this.type = type;
    this.count = count;
  }

  destroy(): void {
    // Stub
  }
}

// ---------------------------------------------------------------------------
// GPUCommandBuffer
// ---------------------------------------------------------------------------

export class GPUCommandBuffer {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }
}

// ---------------------------------------------------------------------------
// GPURenderPassEncoder
// ---------------------------------------------------------------------------

export class GPURenderPassEncoder {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  setPipeline(pipeline: GPURenderPipeline): void {
    const native = getNative();
    native?.gpuRenderPassSetPipeline?.(this._handle, pipeline._handle);
  }

  setBindGroup(index: number, bindGroup: GPUBindGroup): void {
    const native = getNative();
    native?.gpuRenderPassSetBindGroup?.(this._handle, index, bindGroup._handle);
  }

  setVertexBuffer(slot: number, buffer: GPUBuffer, offset?: number, size?: number): void {
    const native = getNative();
    native?.gpuRenderPassSetVertexBuffer?.(this._handle, slot, buffer._handle, offset, size);
  }

  setIndexBuffer(buffer: GPUBuffer, format: string, offset?: number, size?: number): void {
    const native = getNative();
    native?.gpuRenderPassSetIndexBuffer?.(this._handle, buffer._handle, format, offset, size);
  }

  draw(vertexCount: number, instanceCount?: number, firstVertex?: number, firstInstance?: number): void {
    const native = getNative();
    native?.gpuRenderPassDraw?.(this._handle, vertexCount, instanceCount, firstVertex, firstInstance);
  }

  drawIndexed(indexCount: number, instanceCount?: number, firstIndex?: number, baseVertex?: number, firstInstance?: number): void {
    const native = getNative();
    native?.gpuRenderPassDrawIndexed?.(this._handle, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
  }

  drawIndirect(_indirectBuffer: GPUBuffer, _indirectOffset?: number): void {
    // Stub
  }

  drawIndexedIndirect(_indirectBuffer: GPUBuffer, _indirectOffset?: number): void {
    // Stub
  }

  setViewport(_x: number, _y: number, _width: number, _height: number, _minDepth: number, _maxDepth: number): void {
    // Stub — real Dawn call comes later
  }

  setScissorRect(_x: number, _y: number, _width: number, _height: number): void {
    // Stub
  }

  setBlendConstant(_color: object | number[]): void {
    // Stub
  }

  setStencilReference(_reference: number): void {
    // Stub
  }

  executeBundles(_bundles: object[]): void {
    // Stub
  }

  end(): void {
    const native = getNative();
    native?.gpuRenderPassEnd?.(this._handle);
  }
}

// ---------------------------------------------------------------------------
// GPUComputePassEncoder
// ---------------------------------------------------------------------------

export class GPUComputePassEncoder {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  setPipeline(pipeline: GPUComputePipeline): void {
    const native = getNative();
    native?.gpuRenderPassSetPipeline?.(this._handle, pipeline._handle);
  }

  setBindGroup(index: number, bindGroup: GPUBindGroup): void {
    const native = getNative();
    native?.gpuRenderPassSetBindGroup?.(this._handle, index, bindGroup._handle);
  }

  dispatchWorkgroups(_x: number, _y?: number, _z?: number): void {
    // Stub
  }

  dispatchWorkgroupsIndirect(_indirectBuffer: GPUBuffer, _indirectOffset?: number): void {
    // Stub
  }

  end(): void {
    // Stub
  }
}

// ---------------------------------------------------------------------------
// GPUCommandEncoder
// ---------------------------------------------------------------------------

export class GPUCommandEncoder {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  beginRenderPass(descriptor: object): GPURenderPassEncoder {
    const native = getNative();
    const handle = native?.gpuCommandEncoderBeginRenderPass?.(this._handle, descriptor) as number ?? 0;
    return new GPURenderPassEncoder(handle);
  }

  beginComputePass(_descriptor?: object): GPUComputePassEncoder {
    return new GPUComputePassEncoder(0);
  }

  copyBufferToBuffer(
    _source: GPUBuffer, _sourceOffset: number,
    _destination: GPUBuffer, _destinationOffset: number,
    _size: number,
  ): void {
    // Stub
  }

  copyBufferToTexture(_source: object, _destination: object, _copySize: object): void {
    // Stub
  }

  copyTextureToBuffer(_source: object, _destination: object, _copySize: object): void {
    // Stub
  }

  copyTextureToTexture(_source: object, _destination: object, _copySize: object): void {
    // Stub
  }

  clearBuffer(_buffer: GPUBuffer, _offset?: number, _size?: number): void {
    // Stub
  }

  resolveQuerySet(
    _querySet: object, _firstQuery: number, _queryCount: number,
    _destination: GPUBuffer, _destinationOffset: number,
  ): void {
    // Stub
  }

  finish(): GPUCommandBuffer {
    const native = getNative();
    const handle = native?.gpuCommandEncoderFinish?.(this._handle) as number ?? 0;
    return new GPUCommandBuffer(handle);
  }
}

// ---------------------------------------------------------------------------
// GPUQueue
// ---------------------------------------------------------------------------

export class GPUQueue {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  submit(commandBuffers: GPUCommandBuffer[]): void {
    const native = getNative();
    const handles = commandBuffers.map(cb => cb._handle);
    native?.gpuQueueSubmit?.(this._handle, handles);
  }

  writeBuffer(
    buffer: GPUBuffer,
    bufferOffset: number,
    data: ArrayBuffer | ArrayBufferView,
    dataOffset?: number,
    size?: number,
  ): void {
    const native = getNative();
    native?.gpuQueueWriteBuffer?.(this._handle, buffer._handle, bufferOffset, data, dataOffset ?? 0, size ?? 0);
  }

  writeTexture(
    destination: object,
    data: ArrayBuffer | ArrayBufferView,
    dataLayout: object,
    size: object,
  ): void {
    const native = getNative();
    native?.gpuQueueWriteTexture?.(this._handle, destination, data, dataLayout, size);
  }

  copyExternalImageToTexture(
    _source: object,
    _destination: object,
    _copySize: object,
  ): void {
    // Stub — real implementation in a future ticket
  }
}

// ---------------------------------------------------------------------------
// GPUDevice
// ---------------------------------------------------------------------------

export class GPUDevice extends EventTarget {
  _handle: number;
  queue: GPUQueue;
  features: Set<string>;
  limits: Record<string, number>;
  lost: Promise<{ reason: string; message: string }>;

  constructor(handle: number) {
    super();
    const native = getNative();
    const queueHandle = native?.gpuGetQueue?.(handle) as number ?? 0;
    this._handle = handle;
    this.queue = new GPUQueue(queueHandle);

    // Feature set — include core-features-and-limits plus common Dawn features
    this.features = new Set([
      "core-features-and-limits",
      "depth-clip-control",
      "depth32float-stencil8",
      "texture-compression-bc",
      "indirect-first-instance",
      "rg11b10ufloat-renderable",
      "bgra8unorm-storage",
      "float32-filterable",
      "subgroups",
    ]);

    // Dawn default GPU limits
    this.limits = {
      maxTextureDimension1D: 8192,
      maxTextureDimension2D: 8192,
      maxTextureDimension3D: 2048,
      maxTextureArrayLayers: 256,
      maxBindGroups: 4,
      maxBindGroupsPlusVertexBuffers: 24,
      maxBindingsPerBindGroup: 1000,
      maxDynamicUniformBuffersPerPipelineLayout: 10,
      maxDynamicStorageBuffersPerPipelineLayout: 8,
      maxSampledTexturesPerShaderStage: 16,
      maxSamplersPerShaderStage: 16,
      maxStorageBuffersPerShaderStage: 8,
      maxStorageTexturesPerShaderStage: 4,
      maxUniformBuffersPerShaderStage: 12,
      maxUniformBufferBindingSize: 65536,
      maxStorageBufferBindingSize: 134217728,
      minUniformBufferOffsetAlignment: 256,
      minStorageBufferOffsetAlignment: 256,
      maxVertexBuffers: 8,
      maxBufferSize: 268435456,
      maxVertexAttributes: 16,
      maxVertexBufferArrayStride: 2048,
      maxInterStageShaderComponents: 60,
      maxInterStageShaderVariables: 16,
      maxColorAttachments: 8,
      maxColorAttachmentBytesPerSample: 32,
      maxComputeWorkgroupStorageSize: 16384,
      maxComputeInvocationsPerWorkgroup: 256,
      maxComputeWorkgroupSizeX: 256,
      maxComputeWorkgroupSizeY: 256,
      maxComputeWorkgroupSizeZ: 64,
      maxComputeWorkgroupsPerDimension: 65535,
    };

    // Never-resolving promise — device is never lost in our runtime
    this.lost = new Promise(() => {});
  }

  destroy(): void {
    // Future: call __native.gpuDestroyDevice(this._handle)
  }

  // --- T16: Resource creation ---

  createBuffer(descriptor: { size: number; usage: number; mappedAtCreation?: boolean }): GPUBuffer {
    const native = getNative();
    const handle = native?.gpuCreateBuffer?.(this._handle, descriptor) as number ?? 0;
    return new GPUBuffer(handle, this, descriptor.size, descriptor.usage);
  }

  createTexture(descriptor: any): GPUTexture {
    const native = getNative();
    const handle = native?.gpuCreateTexture?.(this._handle, descriptor) as number ?? 0;
    // Extract size — can be an array [w,h,d] or object {width,height,depthOrArrayLayers}
    let w = 0, h = 1, d = 1;
    if (descriptor?.size) {
      if (Array.isArray(descriptor.size)) {
        w = descriptor.size[0] ?? 0;
        h = descriptor.size[1] ?? 1;
        d = descriptor.size[2] ?? 1;
      } else {
        w = descriptor.size.width ?? 0;
        h = descriptor.size.height ?? 1;
        d = descriptor.size.depthOrArrayLayers ?? 1;
      }
    }
    return new GPUTexture(handle, this, {
      width: w, height: h, depthOrArrayLayers: d,
      mipLevelCount: descriptor?.mipLevelCount,
      sampleCount: descriptor?.sampleCount,
      dimension: descriptor?.dimension,
      format: descriptor?.format,
      usage: descriptor?.usage,
    });
  }

  createSampler(descriptor?: object): GPUSampler {
    const native = getNative();
    const handle = native?.gpuCreateSampler?.(this._handle, descriptor ?? {}) as number ?? 0;
    return new GPUSampler(handle);
  }

  // --- T17: Shader & pipeline creation ---

  createShaderModule(descriptor: { code: string }): GPUShaderModule {
    const native = getNative();
    const handle = native?.gpuCreateShaderModule?.(this._handle, descriptor) as number ?? 0;
    return new GPUShaderModule(handle);
  }

  createBindGroupLayout(descriptor: object): GPUBindGroupLayout {
    const native = getNative();
    const handle = native?.gpuCreateBindGroupLayout?.(this._handle, descriptor) as number ?? 0;
    return new GPUBindGroupLayout(handle);
  }

  createPipelineLayout(descriptor: object): GPUPipelineLayout {
    const native = getNative();
    const handle = native?.gpuCreatePipelineLayout?.(this._handle, descriptor) as number ?? 0;
    return new GPUPipelineLayout(handle);
  }

  createRenderPipeline(descriptor: object): GPURenderPipeline {
    const native = getNative();
    const handle = native?.gpuCreateRenderPipeline?.(this._handle, descriptor) as number ?? 0;
    return new GPURenderPipeline(handle);
  }

  createComputePipeline(descriptor: object): GPUComputePipeline {
    const native = getNative();
    const handle = native?.gpuCreateComputePipeline?.(this._handle, descriptor) as number ?? 0;
    return new GPUComputePipeline(handle);
  }

  createBindGroup(descriptor: object): GPUBindGroup {
    const native = getNative();
    const handle = native?.gpuCreateBindGroup?.(this._handle, descriptor) as number ?? 0;
    return new GPUBindGroup(handle);
  }

  createQuerySet(descriptor: { type: string; count: number; label?: string }): GPUQuerySet {
    return new GPUQuerySet(descriptor.type, descriptor.count);
  }

  createRenderBundleEncoder(_descriptor: object): object {
    // Stub — returns a minimal object that won't crash
    return { finish() { return {}; } };
  }

  async createRenderPipelineAsync(descriptor: object): Promise<GPURenderPipeline> {
    return this.createRenderPipeline(descriptor);
  }

  async createComputePipelineAsync(descriptor: object): Promise<GPUComputePipeline> {
    return this.createComputePipeline(descriptor);
  }

  // --- T18: Command encoding ---

  createCommandEncoder(_descriptor?: object): GPUCommandEncoder {
    const native = getNative();
    const handle = native?.gpuCreateCommandEncoder?.(this._handle) as number ?? 0;
    return new GPUCommandEncoder(handle);
  }
}

// ---------------------------------------------------------------------------
// GPUAdapter
// ---------------------------------------------------------------------------

export class GPUAdapter {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  async requestDevice(_descriptor?: object): Promise<GPUDevice> {
    const native = getNative();
    const handle = native?.gpuRequestDevice?.(this._handle) as number ?? 0;
    return new GPUDevice(handle);
  }

  // Adapter features — real Dawn feature names
  get features(): Set<string> {
    return new Set([
      "core-features-and-limits",
      "depth-clip-control",
      "depth32float-stencil8",
      "texture-compression-bc",
      "indirect-first-instance",
      "rg11b10ufloat-renderable",
      "bgra8unorm-storage",
      "float32-filterable",
      "subgroups",
    ]);
  }

  get limits(): Record<string, number> {
    return {
      maxTextureDimension1D: 8192,
      maxTextureDimension2D: 8192,
      maxTextureDimension3D: 2048,
      maxTextureArrayLayers: 256,
      maxBindGroups: 4,
      maxBindGroupsPlusVertexBuffers: 24,
      maxBindingsPerBindGroup: 1000,
      maxDynamicUniformBuffersPerPipelineLayout: 10,
      maxDynamicStorageBuffersPerPipelineLayout: 8,
      maxSampledTexturesPerShaderStage: 16,
      maxSamplersPerShaderStage: 16,
      maxStorageBuffersPerShaderStage: 8,
      maxStorageTexturesPerShaderStage: 4,
      maxUniformBuffersPerShaderStage: 12,
      maxUniformBufferBindingSize: 65536,
      maxStorageBufferBindingSize: 134217728,
      minUniformBufferOffsetAlignment: 256,
      minStorageBufferOffsetAlignment: 256,
      maxVertexBuffers: 8,
      maxBufferSize: 268435456,
      maxVertexAttributes: 16,
      maxVertexBufferArrayStride: 2048,
      maxInterStageShaderComponents: 60,
      maxInterStageShaderVariables: 16,
      maxColorAttachments: 8,
      maxColorAttachmentBytesPerSample: 32,
      maxComputeWorkgroupStorageSize: 16384,
      maxComputeInvocationsPerWorkgroup: 256,
      maxComputeWorkgroupSizeX: 256,
      maxComputeWorkgroupSizeY: 256,
      maxComputeWorkgroupSizeZ: 64,
      maxComputeWorkgroupsPerDimension: 65535,
    };
  }
}

// ---------------------------------------------------------------------------
// GPU (navigator.gpu)
// ---------------------------------------------------------------------------

export class GPU {
  async requestAdapter(_options?: object): Promise<GPUAdapter | null> {
    const native = getNative();
    if (!native?.gpuRequestAdapter) {
      return null;
    }
    const handle = native.gpuRequestAdapter() as number;
    return new GPUAdapter(handle);
  }

  getPreferredCanvasFormat(): string {
    return "bgra8unorm";
  }
}
