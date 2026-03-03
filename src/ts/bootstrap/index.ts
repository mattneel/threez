/**
 * Bootstrap entry point for the threez runtime.
 *
 * This file is bundled into a single IIFE by esbuild and injected
 * into QuickJS-NG before any user code runs. It sets up the browser
 * API polyfills that Three.js expects.
 */

import { EventTarget } from "./event-target";
import { Event, PointerEvent, WheelEvent, KeyboardEvent } from "./events";
import { createDOM } from "./dom";
import { installFetch } from "./fetch";
import { installImage } from "./image";
import { installWebGPUConstants } from "./webgpu-constants";
import { installAbort } from "./abort";
import { installRequest } from "./request";

// Create the wired-up DOM instances
const dom = createDOM();

// Assign to globalThis so user code sees browser-like globals
const g = globalThis as any;

g.window = dom.window;
g.document = dom.document;
g.navigator = dom.navigator;
g.self = dom.window;

// Event constructors
g.Event = Event;
g.PointerEvent = PointerEvent;
g.WheelEvent = WheelEvent;
g.KeyboardEvent = KeyboardEvent;
g.EventTarget = EventTarget;

// CustomEvent stub — extends Event with a detail property
class CustomEvent extends Event {
  readonly detail: any;

  constructor(type: string, init?: { bubbles?: boolean; cancelable?: boolean; detail?: any }) {
    super(type, init);
    this.detail = init?.detail ?? null;
  }
}
g.CustomEvent = CustomEvent;

// window-level convenience aliases
g.requestAnimationFrame = (cb: (time: number) => void) =>
  dom.window.requestAnimationFrame(cb);
g.cancelAnimationFrame = (id: number) =>
  dom.window.cancelAnimationFrame(id);
g.innerWidth = dom.window.innerWidth;
g.innerHeight = dom.window.innerHeight;
g.devicePixelRatio = dom.window.devicePixelRatio;

// Install WebGPU usage/mode/stage constants (GPUBufferUsage, GPUTextureUsage, etc.)
installWebGPUConstants();

// Install fetch() polyfill for local filesystem access
installFetch();

// Install Image, ImageBitmap, createImageBitmap polyfills
installImage();

// Install AbortController / AbortSignal / DOMException polyfills
installAbort();

// Install Request / Headers polyfills
installRequest();

// ---------------------------------------------------------------------------
// Blob + URL.createObjectURL / revokeObjectURL
// ---------------------------------------------------------------------------

const _blobRegistry = new Map<string, { data: Uint8Array; type: string }>();
let _blobIdCounter = 0;

class BlobPolyfill {
  _data: Uint8Array;
  readonly size: number;
  readonly type: string;

  constructor(parts?: any[], options?: { type?: string }) {
    this.type = options?.type ?? "";
    // Concatenate all parts into a single Uint8Array
    const buffers: Uint8Array[] = [];
    let totalLen = 0;
    if (parts) {
      for (const part of parts) {
        let bytes: Uint8Array;
        if (part instanceof Uint8Array) {
          bytes = part;
        } else if (part instanceof ArrayBuffer) {
          bytes = new Uint8Array(part);
        } else if (ArrayBuffer.isView(part)) {
          bytes = new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
        } else if (typeof part === "string") {
          // Simple ASCII encoding
          bytes = new Uint8Array(part.length);
          for (let i = 0; i < part.length; i++) {
            bytes[i] = part.charCodeAt(i);
          }
        } else if (part instanceof BlobPolyfill) {
          bytes = part._data;
        } else {
          const s = String(part);
          bytes = new Uint8Array(s.length);
          for (let i = 0; i < s.length; i++) {
            bytes[i] = s.charCodeAt(i);
          }
        }
        buffers.push(bytes);
        totalLen += bytes.length;
      }
    }
    const merged = new Uint8Array(totalLen);
    let offset = 0;
    for (const buf of buffers) {
      merged.set(buf, offset);
      offset += buf.length;
    }
    this._data = merged;
    this.size = totalLen;
  }

  arrayBuffer(): Promise<ArrayBuffer> {
    const bytes = this._data.slice();
    return Promise.resolve(bytes.buffer as ArrayBuffer);
  }

  text(): Promise<string> {
    let str = "";
    for (let i = 0; i < this._data.length; i++) {
      str += String.fromCharCode(this._data[i]);
    }
    return Promise.resolve(str);
  }

  slice(start?: number, end?: number, contentType?: string): BlobPolyfill {
    const sliced = this._data.slice(start ?? 0, end ?? this._data.length);
    return new BlobPolyfill([sliced], { type: contentType ?? this.type });
  }
}

g.Blob = BlobPolyfill;

// Minimal URL constructor — used by Three.js Cache.js in try/catch
class URLPolyfill {
  href: string;
  origin: string;
  protocol: string;
  host: string;
  hostname: string;
  port: string;
  pathname: string;
  search: string;
  hash: string;
  searchParams: any;

  constructor(url: string, base?: string) {
    // Very minimal parsing — enough for Three.js which only uses it
    // for URL validation in try/catch blocks
    let resolved = url;
    if (base && !url.includes("://") && !url.startsWith("data:")) {
      // Simple base resolution
      if (url.startsWith("/")) {
        // Extract origin from base
        const match = base.match(/^(https?:\/\/[^/]+)/);
        resolved = match ? match[1] + url : url;
      } else {
        const lastSlash = base.lastIndexOf("/");
        resolved = base.slice(0, lastSlash + 1) + url;
      }
    }

    this.href = resolved;

    // Parse protocol
    const protoMatch = resolved.match(/^([a-z][a-z0-9+.-]*:)/i);
    this.protocol = protoMatch ? protoMatch[1] : "";

    // Parse host/pathname/search/hash
    const afterProto = this.protocol ? resolved.slice(this.protocol.length) : resolved;
    if (afterProto.startsWith("//")) {
      const rest = afterProto.slice(2);
      const pathStart = rest.indexOf("/");
      if (pathStart === -1) {
        this.host = rest;
        this.pathname = "/";
      } else {
        this.host = rest.slice(0, pathStart);
        this.pathname = rest.slice(pathStart);
      }
    } else {
      this.host = "";
      this.pathname = afterProto;
    }

    // Extract port from host
    const colonIdx = this.host.indexOf(":");
    if (colonIdx !== -1) {
      this.hostname = this.host.slice(0, colonIdx);
      this.port = this.host.slice(colonIdx + 1);
    } else {
      this.hostname = this.host;
      this.port = "";
    }

    this.origin = this.protocol ? this.protocol + "//" + this.host : "";

    // Extract hash
    const hashIdx = this.pathname.indexOf("#");
    if (hashIdx !== -1) {
      this.hash = this.pathname.slice(hashIdx);
      this.pathname = this.pathname.slice(0, hashIdx);
    } else {
      this.hash = "";
    }

    // Extract search
    const searchIdx = this.pathname.indexOf("?");
    if (searchIdx !== -1) {
      this.search = this.pathname.slice(searchIdx);
      this.pathname = this.pathname.slice(0, searchIdx);
    } else {
      this.search = "";
    }

    // Stub searchParams
    this.searchParams = {
      get(_name: string): string | null { return null; },
      has(_name: string): boolean { return false; },
      toString(): string { return ""; },
    };
  }

  toString(): string {
    return this.href;
  }
}

// Static methods for object URL management
(URLPolyfill as any).createObjectURL = function (blob: any): string {
  const id = `blob:threez/${++_blobIdCounter}`;
  _blobRegistry.set(id, { data: blob._data, type: blob.type || "application/octet-stream" });
  return id;
};

(URLPolyfill as any).revokeObjectURL = function (url: string): void {
  _blobRegistry.delete(url);
};

// Export blob registry for fetch to access
(g as any).__blobRegistry = _blobRegistry;

if (typeof g.URL === "undefined") {
  g.URL = URLPolyfill;
}
// GLTFLoader accesses URL via `self.URL` — self is our WindowStub, not globalThis
(dom.window as any).URL = g.URL;
if (typeof g.URLSearchParams === "undefined") {
  g.URLSearchParams = class URLSearchParams {
    private _entries: [string, string][] = [];
    constructor(_init?: string | Record<string, string>) {}
    get(_name: string): string | null { return null; }
    has(_name: string): boolean { return false; }
    set(_name: string, _value: string): void {}
    append(_name: string, _value: string): void {}
    delete(_name: string): void {}
    toString(): string { return ""; }
  };
}
