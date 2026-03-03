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

  // bootstrap/gpu.ts
  var GPUBuffer = class {
    _handle;
    _device;
    size;
    usage;
    constructor(handle, device, size, usage) {
      this._handle = handle;
      this._device = device;
      this.size = size;
      this.usage = usage;
    }
    async mapAsync(_mode, _offset, _size) {
    }
    getMappedRange(_offset, _size) {
      return new ArrayBuffer(_size ?? this.size);
    }
    unmap() {
    }
    destroy() {
      const native = getNative();
      native?.gpuDestroyBuffer?.(this._handle);
    }
  };
  var GPUTextureView = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPUTexture = class {
    _handle;
    _device;
    constructor(handle, device) {
      this._handle = handle;
      this._device = device;
    }
    createView(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateTextureView?.(this._handle, descriptor ?? {}) ?? 0;
      return new GPUTextureView(handle);
    }
    destroy() {
      const native = getNative();
      native?.gpuDestroyTexture?.(this._handle);
    }
  };
  var GPUSampler = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPUShaderModule = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPUBindGroupLayout = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPUPipelineLayout = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPUBindGroup = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPURenderPipeline = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    getBindGroupLayout(_index) {
      return new GPUBindGroupLayout(0);
    }
  };
  var GPUComputePipeline = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    getBindGroupLayout(_index) {
      return new GPUBindGroupLayout(0);
    }
  };
  var GPUCommandBuffer = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
  };
  var GPURenderPassEncoder = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    setPipeline(pipeline) {
      const native = getNative();
      native?.gpuRenderPassSetPipeline?.(this._handle, pipeline._handle);
    }
    setBindGroup(index, bindGroup) {
      const native = getNative();
      native?.gpuRenderPassSetBindGroup?.(this._handle, index, bindGroup._handle);
    }
    setVertexBuffer(slot, buffer, offset, size) {
      const native = getNative();
      native?.gpuRenderPassSetVertexBuffer?.(this._handle, slot, buffer._handle, offset, size);
    }
    setIndexBuffer(buffer, format, offset, size) {
      const native = getNative();
      native?.gpuRenderPassSetIndexBuffer?.(this._handle, buffer._handle, format, offset, size);
    }
    draw(vertexCount, instanceCount, firstVertex, firstInstance) {
      const native = getNative();
      native?.gpuRenderPassDraw?.(this._handle, vertexCount, instanceCount, firstVertex, firstInstance);
    }
    drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance) {
      const native = getNative();
      native?.gpuRenderPassDrawIndexed?.(this._handle, indexCount, instanceCount, firstIndex, baseVertex, firstInstance);
    }
    end() {
      const native = getNative();
      native?.gpuRenderPassEnd?.(this._handle);
    }
  };
  var GPUCommandEncoder = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    beginRenderPass(descriptor) {
      const native = getNative();
      const handle = native?.gpuCommandEncoderBeginRenderPass?.(this._handle, descriptor) ?? 0;
      return new GPURenderPassEncoder(handle);
    }
    finish() {
      const native = getNative();
      const handle = native?.gpuCommandEncoderFinish?.(this._handle) ?? 0;
      return new GPUCommandBuffer(handle);
    }
  };
  var GPUQueue = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    submit(commandBuffers) {
      const native = getNative();
      const handles = commandBuffers.map((cb) => cb._handle);
      native?.gpuQueueSubmit?.(this._handle, handles);
    }
    writeBuffer(_buffer, _bufferOffset, _data, _dataOffset, _size) {
    }
    writeTexture(_destination, _data, _dataLayout, _size) {
    }
  };
  var GPUDevice = class extends EventTarget {
    _handle;
    queue;
    constructor(handle) {
      super();
      const native = getNative();
      const queueHandle = native?.gpuGetQueue?.(handle) ?? 0;
      this._handle = handle;
      this.queue = new GPUQueue(queueHandle);
    }
    destroy() {
    }
    // --- T16: Resource creation ---
    createBuffer(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateBuffer?.(this._handle, descriptor) ?? 0;
      return new GPUBuffer(handle, this, descriptor.size, descriptor.usage);
    }
    createTexture(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateTexture?.(this._handle, descriptor) ?? 0;
      return new GPUTexture(handle, this);
    }
    createSampler(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateSampler?.(this._handle, descriptor ?? {}) ?? 0;
      return new GPUSampler(handle);
    }
    // --- T17: Shader & pipeline creation ---
    createShaderModule(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateShaderModule?.(this._handle, descriptor) ?? 0;
      return new GPUShaderModule(handle);
    }
    createBindGroupLayout(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateBindGroupLayout?.(this._handle, descriptor) ?? 0;
      return new GPUBindGroupLayout(handle);
    }
    createPipelineLayout(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreatePipelineLayout?.(this._handle, descriptor) ?? 0;
      return new GPUPipelineLayout(handle);
    }
    createRenderPipeline(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateRenderPipeline?.(this._handle, descriptor) ?? 0;
      return new GPURenderPipeline(handle);
    }
    createComputePipeline(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateComputePipeline?.(this._handle, descriptor) ?? 0;
      return new GPUComputePipeline(handle);
    }
    createBindGroup(descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateBindGroup?.(this._handle, descriptor) ?? 0;
      return new GPUBindGroup(handle);
    }
    // --- T18: Command encoding ---
    createCommandEncoder(_descriptor) {
      const native = getNative();
      const handle = native?.gpuCreateCommandEncoder?.(this._handle) ?? 0;
      return new GPUCommandEncoder(handle);
    }
  };
  var GPUAdapter = class {
    _handle;
    constructor(handle) {
      this._handle = handle;
    }
    async requestDevice(_descriptor) {
      const native = getNative();
      const handle = native?.gpuRequestDevice?.(this._handle) ?? 0;
      return new GPUDevice(handle);
    }
    // Stub properties that Three.js may check
    get features() {
      return /* @__PURE__ */ new Set();
    }
    get limits() {
      return {};
    }
  };
  var GPU = class {
    async requestAdapter(_options) {
      const native = getNative();
      if (!native?.gpuRequestAdapter) {
        return null;
      }
      const handle = native.gpuRequestAdapter();
      return new GPUAdapter(handle);
    }
    getPreferredCanvasFormat() {
      return "bgra8unorm";
    }
  };

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
    return {
      gpu: new GPU(),
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

  // bootstrap/fetch.ts
  function guessContentType(url) {
    const dot = url.lastIndexOf(".");
    if (dot === -1) return "application/octet-stream";
    const ext = url.slice(dot).toLowerCase().split("?")[0].split("#")[0];
    switch (ext) {
      case ".json":
        return "application/json";
      case ".js":
      case ".mjs":
        return "application/javascript";
      case ".html":
      case ".htm":
        return "text/html";
      case ".css":
        return "text/css";
      case ".txt":
        return "text/plain";
      case ".png":
        return "image/png";
      case ".jpg":
      case ".jpeg":
        return "image/jpeg";
      case ".gif":
        return "image/gif";
      case ".svg":
        return "image/svg+xml";
      case ".glb":
        return "model/gltf-binary";
      case ".gltf":
        return "model/gltf+json";
      case ".wasm":
        return "application/wasm";
      case ".xml":
        return "application/xml";
      default:
        return "application/octet-stream";
    }
  }
  var FetchHeaders = class {
    _map = {};
    constructor(init) {
      if (init) {
        for (const key of Object.keys(init)) {
          this._map[key.toLowerCase()] = init[key];
        }
      }
    }
    get(name) {
      return this._map[name.toLowerCase()] ?? null;
    }
    has(name) {
      return name.toLowerCase() in this._map;
    }
    set(name, value) {
      this._map[name.toLowerCase()] = value;
    }
  };
  var FetchResponse = class {
    ok;
    status;
    statusText;
    url;
    headers;
    _body;
    constructor(body, status, statusText, url, headers) {
      this._body = body;
      this.ok = status >= 200 && status < 300;
      this.status = status;
      this.statusText = statusText;
      this.url = url;
      this.headers = new FetchHeaders(headers);
    }
    text() {
      const bytes = this._body;
      const g2 = globalThis;
      if (typeof g2.TextDecoder !== "undefined") {
        return Promise.resolve(new g2.TextDecoder().decode(bytes));
      }
      let str = "";
      for (let i = 0; i < bytes.length; i++) {
        str += String.fromCharCode(bytes[i]);
      }
      return Promise.resolve(str);
    }
    json() {
      return this.text().then((t) => JSON.parse(t));
    }
    arrayBuffer() {
      const buf = this._body.buffer.slice(
        this._body.byteOffset,
        this._body.byteOffset + this._body.byteLength
      );
      return Promise.resolve(buf);
    }
  };
  function decodeURIBytes(str) {
    const parts = [];
    for (let i = 0; i < str.length; i++) {
      if (str[i] === "%" && i + 2 < str.length) {
        parts.push(parseInt(str.slice(i + 1, i + 3), 16));
        i += 2;
      } else {
        parts.push(str.charCodeAt(i));
      }
    }
    return new Uint8Array(parts);
  }
  function fetchDataURI(url) {
    const rest = url.slice(5);
    const commaIdx = rest.indexOf(",");
    if (commaIdx === -1) {
      return new FetchResponse(
        new Uint8Array(0),
        400,
        "Bad Request",
        url,
        { "content-type": "text/plain" }
      );
    }
    const meta = rest.slice(0, commaIdx);
    const data = rest.slice(commaIdx + 1);
    const isBase64 = meta.endsWith(";base64");
    const mediaType = isBase64 ? meta.slice(0, -7) : meta;
    const contentType = mediaType || "text/plain;charset=US-ASCII";
    let body;
    if (isBase64) {
      const decoded = typeof __native_decodeBase64 === "function" ? __native_decodeBase64(data) : null;
      body = decoded ?? new Uint8Array(0);
    } else {
      body = decodeURIBytes(data);
    }
    return new FetchResponse(body, 200, "OK", url, {
      "content-type": contentType
    });
  }
  function isLocalPath(url) {
    if (url.startsWith("./") || url.startsWith("../") || url.startsWith("/")) {
      return true;
    }
    if (!url.includes("://") && !url.startsWith("data:")) {
      return true;
    }
    return false;
  }
  function fetchPolyfill(input) {
    const url = typeof input === "string" ? input : input.url ?? input.toString();
    if (url.startsWith("data:")) {
      try {
        return Promise.resolve(fetchDataURI(url));
      } catch {
        return Promise.resolve(
          new FetchResponse(new Uint8Array(0), 400, "Bad Request", url, {})
        );
      }
    }
    if (url.startsWith("http://") || url.startsWith("https://")) {
      if (typeof __native_httpFetch !== "function") {
        return Promise.resolve(
          new FetchResponse(
            new Uint8Array(0),
            0,
            "Network request not supported",
            url,
            {}
          )
        );
      }
      const result = __native_httpFetch(url);
      if (!result) {
        return Promise.resolve(
          new FetchResponse(
            new Uint8Array(0),
            0,
            "Network Error",
            url,
            {}
          )
        );
      }
      return Promise.resolve(
        new FetchResponse(
          result.body,
          result.status,
          result.statusText || "OK",
          url,
          {
            "content-type": result.contentType || "application/octet-stream"
          }
        )
      );
    }
    if (isLocalPath(url)) {
      if (typeof __native_readFileSync !== "function") {
        return Promise.resolve(
          new FetchResponse(
            new Uint8Array(0),
            500,
            "Internal Error",
            url,
            {}
          )
        );
      }
      const bytes = __native_readFileSync(url);
      if (bytes === null) {
        return Promise.resolve(
          new FetchResponse(
            new Uint8Array(0),
            404,
            "Not Found",
            url,
            { "content-type": "text/plain" }
          )
        );
      }
      const contentType = guessContentType(url);
      return Promise.resolve(
        new FetchResponse(bytes, 200, "OK", url, {
          "content-type": contentType
        })
      );
    }
    return Promise.resolve(
      new FetchResponse(
        new Uint8Array(0),
        0,
        "Network request not supported",
        url,
        {}
      )
    );
  }
  function installFetch() {
    const g2 = globalThis;
    g2.fetch = fetchPolyfill;
    g2.Response = FetchResponse;
  }

  // bootstrap/image.ts
  var ImageBitmap = class {
    width;
    height;
    _data;
    // RGBA pixels
    constructor(width, height, data) {
      this.width = width;
      this.height = height;
      this._data = data;
    }
    close() {
    }
  };
  var ImageElement = class extends EventTarget {
    width = 0;
    height = 0;
    _src = "";
    _data = null;
    _complete = false;
    crossOrigin = null;
    // Callback-style event handlers (Three.js uses these)
    onload = null;
    onerror = null;
    get src() {
      return this._src;
    }
    set src(url) {
      this._src = url;
      this._complete = false;
      Promise.resolve().then(async () => {
        try {
          const g2 = globalThis;
          const resp = await g2.fetch(url);
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
          const loadEvent = new Event("load");
          if (this.onload) this.onload.call(this);
          this.dispatchEvent(loadEvent);
        } catch (e) {
          const errorEvent = new Event("error");
          if (this.onerror) this.onerror.call(this, e);
          this.dispatchEvent(errorEvent);
        }
      });
    }
    get complete() {
      return this._complete;
    }
    get naturalWidth() {
      return this.width;
    }
    get naturalHeight() {
      return this.height;
    }
  };
  function createImageBitmap(source) {
    if (source instanceof ImageElement) {
      if (source._data && source._complete) {
        return Promise.resolve(
          new ImageBitmap(source.width, source.height, source._data)
        );
      }
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
    if (source && typeof source.arrayBuffer === "function") {
      return source.arrayBuffer().then((ab) => {
        return decodeRawBytes(new Uint8Array(ab));
      });
    }
    if (source instanceof ArrayBuffer) {
      return Promise.resolve(decodeRawBytes(new Uint8Array(source)));
    }
    if (source instanceof Uint8Array) {
      return Promise.resolve(decodeRawBytes(source));
    }
    return Promise.reject(new Error("Unsupported source type for createImageBitmap"));
  }
  function decodeRawBytes(bytes) {
    if (typeof __native_decodeImage !== "function") {
      throw new Error("__native_decodeImage not available");
    }
    const result = __native_decodeImage(bytes);
    if (!result) {
      throw new Error("Image decode failed");
    }
    return new ImageBitmap(result.width, result.height, result.data);
  }
  function installImage() {
    const g2 = globalThis;
    g2.Image = ImageElement;
    g2.ImageBitmap = ImageBitmap;
    g2.createImageBitmap = createImageBitmap;
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
  installFetch();
  installImage();
})();
