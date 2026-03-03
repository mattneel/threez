/**
 * DOM stub objects for QuickJS-NG.
 *
 * Provides window, document, canvas, and navigator polyfills
 * with the subset of properties that Three.js expects.
 */

import { EventTarget } from "./event-target";
import { getNative } from "./native";
import { GPU, GPUCanvasContext } from "./gpu";
import { ImageElement } from "./image";

// ---------------------------------------------------------------------------
// Canvas stub
// ---------------------------------------------------------------------------

export class CanvasStub extends EventTarget {
  width: number = 800;
  height: number = 600;
  style: Record<string, string> = {};
  private _attributes: Map<string, string> = new Map();
  private _gpuContext: GPUCanvasContext | null = null;

  getContext(contextId: string): any {
    if (contextId === "webgpu") {
      if (!this._gpuContext) {
        this._gpuContext = new GPUCanvasContext();
      }
      return this._gpuContext;
    }
    return null;
  }

  getBoundingClientRect(): {
    left: number;
    top: number;
    width: number;
    height: number;
    right: number;
    bottom: number;
    x: number;
    y: number;
  } {
    return {
      left: 0,
      top: 0,
      width: this.width,
      height: this.height,
      right: this.width,
      bottom: this.height,
      x: 0,
      y: 0,
    };
  }

  setAttribute(name: string, value: string): void {
    this._attributes.set(name, value);
  }

  getAttribute(name: string): string | null {
    return this._attributes.get(name) ?? null;
  }

  // Three.js sometimes checks for these
  get clientWidth(): number {
    return this.width;
  }
  get clientHeight(): number {
    return this.height;
  }
}

// ---------------------------------------------------------------------------
// Navigator stub
// ---------------------------------------------------------------------------

function createNavigator(): {
  gpu: GPU;
  userAgent: string;
  language: string;
  platform: string;
} {
  return {
    gpu: new GPU(),
    userAgent: "threez/0.1.0",
    language: "en-US",
    platform: "threez",
  };
}

// ---------------------------------------------------------------------------
// Document stub
// ---------------------------------------------------------------------------

export class DocumentStub extends EventTarget {
  body: EventTarget = new EventTarget();
  documentElement: EventTarget = new EventTarget();
  visibilityState: string = "visible";
  hidden: boolean = false;

  private _canvas: CanvasStub;

  constructor(canvas: CanvasStub) {
    super();
    this._canvas = canvas;
  }

  createElement(tagName: string): any {
    const tag = tagName.toLowerCase();
    if (tag === "canvas") {
      return this._canvas;
    }
    if (tag === "img") {
      return new ImageElement();
    }
    // Return a minimal element stub for other tags
    return {
      style: {},
      setAttribute() {},
      getAttribute() {
        return null;
      },
      appendChild(child: any) {
        return child;
      },
      removeChild(child: any) {
        return child;
      },
    };
  }

  getElementById(_id: string): any {
    return null;
  }

  createElementNS(_namespace: string, tagName: string): any {
    return this.createElement(tagName);
  }
}

// ---------------------------------------------------------------------------
// Window stub
// ---------------------------------------------------------------------------

export class WindowStub extends EventTarget {
  innerWidth: number = 800;
  innerHeight: number = 600;
  devicePixelRatio: number = 1.0;

  navigator: ReturnType<typeof createNavigator>;
  document: DocumentStub;

  private _rafId: number = 0;

  constructor(document: DocumentStub, navigator: ReturnType<typeof createNavigator>) {
    super();
    this.document = document;
    this.navigator = navigator;
  }

  get self(): this {
    return this;
  }

  requestAnimationFrame(callback: (time: number) => void): number {
    const native = getNative();
    if (native?.requestAnimationFrame) {
      return native.requestAnimationFrame(callback);
    }
    // Stub: assign an id but never actually call back
    return ++this._rafId;
  }

  cancelAnimationFrame(id: number): void {
    const native = getNative();
    if (native?.cancelAnimationFrame) {
      native.cancelAnimationFrame(id);
    }
    // Stub: no-op
  }
}

// ---------------------------------------------------------------------------
// Factory: create the wired-up DOM instances
// ---------------------------------------------------------------------------

export interface DOMInstances {
  canvas: CanvasStub;
  navigator: ReturnType<typeof createNavigator>;
  document: DocumentStub;
  window: WindowStub;
}

export function createDOM(): DOMInstances {
  const canvas = new CanvasStub();
  const navigator = createNavigator();
  const document = new DocumentStub(canvas);
  const window = new WindowStub(document, navigator);

  return { canvas, navigator, document, window };
}
