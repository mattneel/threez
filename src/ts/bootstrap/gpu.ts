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

  constructor(handle: number, device: GPUDevice) {
    this._handle = handle;
    this._device = device;
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
    return new GPUTexture(handle, this._device!);
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

  getBindGroupLayout(_index: number): GPUBindGroupLayout {
    // Stub — requires native introspection (future)
    return new GPUBindGroupLayout(0);
  }
}

export class GPUComputePipeline {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  getBindGroupLayout(_index: number): GPUBindGroupLayout {
    // Stub — requires native introspection (future)
    return new GPUBindGroupLayout(0);
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

  end(): void {
    const native = getNative();
    native?.gpuRenderPassEnd?.(this._handle);
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
    _buffer: GPUBuffer,
    _bufferOffset: number,
    _data: ArrayBuffer | ArrayBufferView,
    _dataOffset?: number,
    _size?: number,
  ): void {
    // Stub — real implementation in a future ticket
  }

  writeTexture(
    _destination: object,
    _data: ArrayBuffer | ArrayBufferView,
    _dataLayout: object,
    _size: object,
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

  constructor(handle: number) {
    super();
    const native = getNative();
    const queueHandle = native?.gpuGetQueue?.(handle) as number ?? 0;
    this._handle = handle;
    this.queue = new GPUQueue(queueHandle);
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

  createTexture(descriptor: object): GPUTexture {
    const native = getNative();
    const handle = native?.gpuCreateTexture?.(this._handle, descriptor) as number ?? 0;
    return new GPUTexture(handle, this);
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

  // Stub properties that Three.js may check
  get features(): Set<string> {
    return new Set();
  }

  get limits(): Record<string, number> {
    return {};
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
