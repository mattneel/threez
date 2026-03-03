/**
 * Image and createImageBitmap polyfills for Three.js texture loading.
 *
 * Provides:
 *   - ImageBitmap: decoded RGBA pixel container
 *   - Image (HTMLImageElement stub): loads images via fetch + native decode
 *   - createImageBitmap(): decodes image data to ImageBitmap
 */

import { EventTarget } from "./event-target";
import { Event } from "./events";

declare function __native_decodeImage(
  data: Uint8Array
): { width: number; height: number; data: Uint8Array } | null;

// ---------------------------------------------------------------------------
// ImageBitmap
// ---------------------------------------------------------------------------

export class ImageBitmap {
  width: number;
  height: number;
  _data: Uint8Array; // RGBA pixels

  constructor(width: number, height: number, data: Uint8Array) {
    this.width = width;
    this.height = height;
    this._data = data;
  }

  close(): void {
    // no-op for now
  }
}

// ---------------------------------------------------------------------------
// Image (HTMLImageElement stub)
// ---------------------------------------------------------------------------

export class ImageElement extends EventTarget {
  width = 0;
  height = 0;
  _src = "";
  _data: Uint8Array | null = null;
  _complete = false;
  crossOrigin: string | null = null;

  // Callback-style event handlers (Three.js uses these)
  onload: ((this: ImageElement) => void) | null = null;
  onerror: ((this: ImageElement, event?: any) => void) | null = null;

  get src(): string {
    return this._src;
  }

  set src(url: string) {
    this._src = url;
    this._complete = false;

    // Defer loading via microtask so event handlers can be attached after setting src
    Promise.resolve().then(async () => {
      try {
        const g = globalThis as any;
        const resp = await g.fetch(url);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const buf = new Uint8Array(await resp.arrayBuffer());

        if (typeof __native_decodeImage !== "function") {
          throw new Error("__native_decodeImage not available");
        }

        const result = __native_decodeImage(buf);
        if (!result) throw new Error("Image decode failed");

        this.width = result.width;
        this.height = result.height;
        this._data = result.data;
        this._complete = true;

        // Fire load event
        const loadEvent = new Event("load");
        if (this.onload) this.onload.call(this);
        this.dispatchEvent(loadEvent);
      } catch (e) {
        // Fire error event
        const errorEvent = new Event("error");
        if (this.onerror) this.onerror.call(this, e);
        this.dispatchEvent(errorEvent);
      }
    });
  }

  get complete(): boolean {
    return this._complete;
  }

  get naturalWidth(): number {
    return this.width;
  }

  get naturalHeight(): number {
    return this.height;
  }
}

// ---------------------------------------------------------------------------
// createImageBitmap
// ---------------------------------------------------------------------------

/**
 * Decode image data to an ImageBitmap.
 *
 * Supports:
 *   - ImageElement (uses already-decoded data if available, or raw bytes)
 *   - Blob (with arrayBuffer method)
 *   - ArrayBuffer / Uint8Array (raw image bytes)
 */
export function createImageBitmap(source: any): Promise<ImageBitmap> {
  // If source is an ImageElement with decoded data, reuse it
  if (source instanceof ImageElement) {
    if (source._data && source._complete) {
      return Promise.resolve(
        new ImageBitmap(source.width, source.height, source._data)
      );
    }
    // Wait for load
    return new Promise((resolve, reject) => {
      source.addEventListener(
        "load",
        () => {
          if (source._data) {
            resolve(
              new ImageBitmap(source.width, source.height, source._data)
            );
          } else {
            reject(new Error("Image has no data after load"));
          }
        },
        { once: true }
      );
      source.addEventListener(
        "error",
        () => {
          reject(new Error("Image failed to load"));
        },
        { once: true }
      );
    });
  }

  // If source is a Blob with arrayBuffer()
  if (source && typeof source.arrayBuffer === "function") {
    return source.arrayBuffer().then((ab: ArrayBuffer) => {
      return decodeRawBytes(new Uint8Array(ab));
    });
  }

  // If source is an ArrayBuffer
  if (source instanceof ArrayBuffer) {
    return Promise.resolve(decodeRawBytes(new Uint8Array(source)));
  }

  // If source is a Uint8Array or typed array
  if (source instanceof Uint8Array) {
    return Promise.resolve(decodeRawBytes(source));
  }

  return Promise.reject(new Error("Unsupported source type for createImageBitmap"));
}

function decodeRawBytes(bytes: Uint8Array): ImageBitmap {
  if (typeof __native_decodeImage !== "function") {
    throw new Error("__native_decodeImage not available");
  }

  const result = __native_decodeImage(bytes);
  if (!result) {
    throw new Error("Image decode failed");
  }

  return new ImageBitmap(result.width, result.height, result.data);
}

// ---------------------------------------------------------------------------
// Install on globalThis
// ---------------------------------------------------------------------------

export function installImage(): void {
  const g = globalThis as any;
  g.Image = ImageElement;
  g.ImageBitmap = ImageBitmap;
  g.createImageBitmap = createImageBitmap;
}
