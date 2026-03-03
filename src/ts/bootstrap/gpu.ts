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
// GPUQueue
// ---------------------------------------------------------------------------

export class GPUQueue {
  _handle: number;

  constructor(handle: number) {
    this._handle = handle;
  }

  // Future: submit(), writeBuffer(), writeTexture(), etc.
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
