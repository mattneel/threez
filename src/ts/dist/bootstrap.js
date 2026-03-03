"use strict";
(() => {
  // bootstrap/event-target.ts
  var EventTarget = class {
    _listeners = /* @__PURE__ */ new Map();
    addEventListener(type, callback, options) {
      if (callback === null) return;
      const { capture, once, passive } = normalizeOptions(options);
      let list = this._listeners.get(type);
      if (!list) {
        list = [];
        this._listeners.set(type, list);
      }
      const cb = callback;
      for (const entry of list) {
        if (entry.callback === cb && entry.capture === capture) {
          return;
        }
      }
      list.push({ callback: cb, capture, once, passive });
    }
    removeEventListener(type, callback, options) {
      if (callback === null) return;
      const { capture } = normalizeOptions(options);
      const list = this._listeners.get(type);
      if (!list) return;
      for (let i = 0; i < list.length; i++) {
        if (list[i].callback === callback && list[i].capture === capture) {
          list.splice(i, 1);
          if (list.length === 0) {
            this._listeners.delete(type);
          }
          return;
        }
      }
    }
    dispatchEvent(event) {
      event._target = this;
      event._currentTarget = this;
      const list = this._listeners.get(event.type);
      if (!list) return !event.defaultPrevented;
      const entries = list.slice();
      for (const entry of entries) {
        if (event._stopImmediate) break;
        if (entry.once) {
          this.removeEventListener(event.type, entry.callback, {
            capture: entry.capture
          });
        }
        if (typeof entry.callback === "function") {
          entry.callback(event);
        } else {
          entry.callback.handleEvent(event);
        }
      }
      return !event.defaultPrevented;
    }
  };
  function normalizeOptions(options) {
    if (typeof options === "boolean") {
      return { capture: options, once: false, passive: false };
    }
    return {
      capture: options?.capture ?? false,
      once: options?.once ?? false,
      passive: options?.passive ?? false
    };
  }

  // bootstrap/events.ts
  var Event = class {
    type;
    bubbles;
    cancelable;
    timeStamp;
    defaultPrevented = false;
    /** @internal set by EventTarget.dispatchEvent */
    _target = null;
    /** @internal set by EventTarget.dispatchEvent */
    _currentTarget = null;
    /** @internal */
    _stopProp = false;
    /** @internal */
    _stopImmediate = false;
    get target() {
      return this._target;
    }
    get currentTarget() {
      return this._currentTarget;
    }
    constructor(type, init) {
      this.type = type;
      this.bubbles = init?.bubbles ?? false;
      this.cancelable = init?.cancelable ?? false;
      this.timeStamp = Date.now();
    }
    preventDefault() {
      if (this.cancelable) {
        this.defaultPrevented = true;
      }
    }
    stopPropagation() {
      this._stopProp = true;
    }
    stopImmediatePropagation() {
      this._stopProp = true;
      this._stopImmediate = true;
    }
  };
  var PointerEvent = class extends Event {
    clientX;
    clientY;
    movementX;
    movementY;
    button;
    buttons;
    pointerId;
    pointerType;
    constructor(type, init) {
      super(type, init);
      this.clientX = init?.clientX ?? 0;
      this.clientY = init?.clientY ?? 0;
      this.movementX = init?.movementX ?? 0;
      this.movementY = init?.movementY ?? 0;
      this.button = init?.button ?? 0;
      this.buttons = init?.buttons ?? 0;
      this.pointerId = init?.pointerId ?? 0;
      this.pointerType = init?.pointerType ?? "";
    }
  };
  var WheelEvent = class extends Event {
    deltaX;
    deltaY;
    deltaZ;
    deltaMode;
    constructor(type, init) {
      super(type, init);
      this.deltaX = init?.deltaX ?? 0;
      this.deltaY = init?.deltaY ?? 0;
      this.deltaZ = init?.deltaZ ?? 0;
      this.deltaMode = init?.deltaMode ?? 0;
    }
  };
  var KeyboardEvent = class extends Event {
    key;
    code;
    altKey;
    ctrlKey;
    metaKey;
    shiftKey;
    repeat;
    constructor(type, init) {
      super(type, init);
      this.key = init?.key ?? "";
      this.code = init?.code ?? "";
      this.altKey = init?.altKey ?? false;
      this.ctrlKey = init?.ctrlKey ?? false;
      this.metaKey = init?.metaKey ?? false;
      this.shiftKey = init?.shiftKey ?? false;
      this.repeat = init?.repeat ?? false;
    }
  };

  // bootstrap/native.ts
  function getNative() {
    return typeof __native !== "undefined" ? __native : void 0;
  }

  // bootstrap/dom.ts
  var CanvasStub = class extends EventTarget {
    width = 800;
    height = 600;
    style = {};
    _attributes = /* @__PURE__ */ new Map();
    getContext(contextId) {
      if (contextId === "webgpu") {
        return {
          configure(config) {
          },
          getCurrentTexture() {
            return {};
          },
          getPreferredFormat() {
            return "bgra8unorm";
          }
        };
      }
      return null;
    }
    getBoundingClientRect() {
      return {
        left: 0,
        top: 0,
        width: this.width,
        height: this.height,
        right: this.width,
        bottom: this.height,
        x: 0,
        y: 0
      };
    }
    setAttribute(name, value) {
      this._attributes.set(name, value);
    }
    getAttribute(name) {
      return this._attributes.get(name) ?? null;
    }
    // Three.js sometimes checks for these
    get clientWidth() {
      return this.width;
    }
    get clientHeight() {
      return this.height;
    }
  };
  function createNavigator() {
    const gpu = {
      requestAdapter() {
        const native = getNative();
        if (native?.gpuRequestAdapter) {
          return Promise.resolve(native.gpuRequestAdapter());
        }
        return Promise.resolve({
          requestDevice() {
            return Promise.resolve({});
          },
          features: /* @__PURE__ */ new Set(),
          limits: {}
        });
      }
    };
    return {
      gpu,
      userAgent: "threez/0.1.0",
      language: "en-US",
      platform: "threez"
    };
  }
  var DocumentStub = class extends EventTarget {
    body = new EventTarget();
    documentElement = new EventTarget();
    visibilityState = "visible";
    hidden = false;
    _canvas;
    constructor(canvas) {
      super();
      this._canvas = canvas;
    }
    createElement(tagName) {
      if (tagName === "canvas") {
        return this._canvas;
      }
      return {
        style: {},
        setAttribute() {
        },
        getAttribute() {
          return null;
        },
        appendChild(child) {
          return child;
        }
      };
    }
    getElementById(_id) {
      return null;
    }
    createElementNS(_namespace, tagName) {
      return this.createElement(tagName);
    }
  };
  var WindowStub = class extends EventTarget {
    innerWidth = 800;
    innerHeight = 600;
    devicePixelRatio = 1;
    navigator;
    document;
    _rafId = 0;
    constructor(document, navigator) {
      super();
      this.document = document;
      this.navigator = navigator;
    }
    get self() {
      return this;
    }
    requestAnimationFrame(callback) {
      const native = getNative();
      if (native?.requestAnimationFrame) {
        return native.requestAnimationFrame(callback);
      }
      return ++this._rafId;
    }
    cancelAnimationFrame(id) {
      const native = getNative();
      if (native?.cancelAnimationFrame) {
        native.cancelAnimationFrame(id);
      }
    }
  };
  function createDOM() {
    const canvas = new CanvasStub();
    const navigator = createNavigator();
    const document = new DocumentStub(canvas);
    const window = new WindowStub(document, navigator);
    return { canvas, navigator, document, window };
  }

  // bootstrap/index.ts
  var dom = createDOM();
  var g = globalThis;
  g.window = dom.window;
  g.document = dom.document;
  g.navigator = dom.navigator;
  g.self = dom.window;
  g.Event = Event;
  g.PointerEvent = PointerEvent;
  g.WheelEvent = WheelEvent;
  g.KeyboardEvent = KeyboardEvent;
  g.EventTarget = EventTarget;
  g.requestAnimationFrame = (cb) => dom.window.requestAnimationFrame(cb);
  g.cancelAnimationFrame = (id) => dom.window.cancelAnimationFrame(id);
  g.innerWidth = dom.window.innerWidth;
  g.innerHeight = dom.window.innerHeight;
  g.devicePixelRatio = dom.window.devicePixelRatio;
})();
