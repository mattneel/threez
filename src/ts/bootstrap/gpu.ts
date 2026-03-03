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
// GPUQueue
// ---------------------------------------------------------------------------

export class GPUQueue {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  submit(_commandBuffers: any[]): void {
    // Stub — wired in T18 (command encoding)
  }

  writeBuffer(
    _buffer: GPUBuffer,
    _bufferOffset: number,
    _data: ArrayBuffer | ArrayBufferView,
    _dataOffset?: number,
    _size?: number,
  ): void {
    // Stub — wired in T18
  }

  writeTexture(
    _destination: object,
    _data: ArrayBuffer | ArrayBufferView,
    _dataLayout: object,
    _size: object,
  ): void {
    // Stub — wired in T18
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
