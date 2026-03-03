"use strict";
var __bootstrap = (() => {
  var __defProp = Object.defineProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // bootstrap/event-target.ts
  var EventTarget = class {
    constructor() {
      __publicField(this, "_listeners", /* @__PURE__ */ new Map());
    }
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
    constructor(type, init) {
      __publicField(this, "type");
      __publicField(this, "bubbles");
      __publicField(this, "cancelable");
      __publicField(this, "timeStamp");
      __publicField(this, "defaultPrevented", false);
      /** @internal set by EventTarget.dispatchEvent */
      __publicField(this, "_target", null);
      /** @internal set by EventTarget.dispatchEvent */
      __publicField(this, "_currentTarget", null);
      /** @internal */
      __publicField(this, "_stopProp", false);
      /** @internal */
      __publicField(this, "_stopImmediate", false);
      this.type = type;
      this.bubbles = init?.bubbles ?? false;
      this.cancelable = init?.cancelable ?? false;
      this.timeStamp = Date.now();
    }
    get target() {
      return this._target;
    }
    get currentTarget() {
      return this._currentTarget;
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
    constructor(type, init) {
      super(type, init);
      __publicField(this, "clientX");
      __publicField(this, "clientY");
      __publicField(this, "movementX");
      __publicField(this, "movementY");
      __publicField(this, "button");
      __publicField(this, "buttons");
      __publicField(this, "pointerId");
      __publicField(this, "pointerType");
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
    constructor(type, init) {
      super(type, init);
      __publicField(this, "deltaX");
      __publicField(this, "deltaY");
      __publicField(this, "deltaZ");
      __publicField(this, "deltaMode");
      this.deltaX = init?.deltaX ?? 0;
      this.deltaY = init?.deltaY ?? 0;
      this.deltaZ = init?.deltaZ ?? 0;
      this.deltaMode = init?.deltaMode ?? 0;
    }
  };
  var KeyboardEvent = class extends Event {
    constructor(type, init) {
      super(type, init);
      __publicField(this, "key");
      __publicField(this, "code");
      __publicField(this, "altKey");
      __publicField(this, "ctrlKey");
      __publicField(this, "metaKey");
      __publicField(this, "shiftKey");
      __publicField(this, "repeat");
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
    constructor(handle, device, size, usage) {
      __publicField(this, "_handle");
      __publicField(this, "_device");
      __publicField(this, "size");
      __publicField(this, "usage");
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
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPUTexture = class {
    constructor(handle, device) {
      __publicField(this, "_handle");
      __publicField(this, "_device");
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
  var GPUCanvasContext = class {
    constructor() {
      __publicField(this, "_configured", false);
      __publicField(this, "_device", null);
      __publicField(this, "_format", "bgra8unorm");
    }
    configure(config) {
      this._device = config.device;
      this._format = config.format ?? "bgra8unorm";
      this._configured = true;
      const native = getNative();
      native?.gpuConfigureContext?.(config.device._handle, this._format, config.alphaMode ?? "opaque", 0, 0);
    }
    unconfigure() {
      this._configured = false;
      this._device = null;
    }
    getCurrentTexture() {
      const native = getNative();
      const handle = native?.gpuGetCurrentTexture?.() ?? 0;
      return new GPUTexture(handle, this._device);
    }
    // Internal: called by event loop after queue.submit
    present() {
      const native = getNative();
      native?.gpuPresent?.();
    }
    get configured() {
      return this._configured;
    }
  };
  var GPUSampler = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPUShaderModule = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPUBindGroupLayout = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPUPipelineLayout = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPUBindGroup = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPURenderPipeline = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
    getBindGroupLayout(index) {
      const native = getNative();
      const handle = native?.gpuRenderPipelineGetBindGroupLayout?.(this._handle, index) ?? 0;
      return new GPUBindGroupLayout(handle);
    }
  };
  var GPUComputePipeline = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
    getBindGroupLayout(index) {
      const native = getNative();
      const handle = native?.gpuComputePipelineGetBindGroupLayout?.(this._handle, index) ?? 0;
      return new GPUBindGroupLayout(handle);
    }
  };
  var GPUCommandBuffer = class {
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
  };
  var GPURenderPassEncoder = class {
    constructor(handle) {
      __publicField(this, "_handle");
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
    constructor(handle) {
      __publicField(this, "_handle");
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
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
    submit(commandBuffers) {
      const native = getNative();
      const handles = commandBuffers.map((cb) => cb._handle);
      native?.gpuQueueSubmit?.(this._handle, handles);
    }
    writeBuffer(buffer, bufferOffset, data, dataOffset, size) {
      const native = getNative();
      native?.gpuQueueWriteBuffer?.(this._handle, buffer._handle, bufferOffset, data, dataOffset ?? 0, size ?? 0);
    }
    writeTexture(destination, data, dataLayout, size) {
      const native = getNative();
      native?.gpuQueueWriteTexture?.(this._handle, destination, data, dataLayout, size);
    }
    copyExternalImageToTexture(_source, _destination, _copySize) {
    }
  };
  var GPUDevice = class extends EventTarget {
    constructor(handle) {
      super();
      __publicField(this, "_handle");
      __publicField(this, "queue");
      __publicField(this, "features");
      __publicField(this, "limits");
      __publicField(this, "lost");
      const native = getNative();
      const queueHandle = native?.gpuGetQueue?.(handle) ?? 0;
      this._handle = handle;
      this.queue = new GPUQueue(queueHandle);
      this.features = /* @__PURE__ */ new Set([
        "core-features-and-limits",
        "depth-clip-control",
        "depth32float-stencil8",
        "texture-compression-bc",
        "indirect-first-instance",
        "rg11b10ufloat-renderable",
        "bgra8unorm-storage",
        "float32-filterable",
        "subgroups"
      ]);
      this.limits = {
        maxTextureDimension1D: 8192,
        maxTextureDimension2D: 8192,
        maxTextureDimension3D: 2048,
        maxTextureArrayLayers: 256,
        maxBindGroups: 4,
        maxBindGroupsPlusVertexBuffers: 24,
        maxBindingsPerBindGroup: 1e3,
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
        maxComputeWorkgroupsPerDimension: 65535
      };
      this.lost = new Promise(() => {
      });
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
    constructor(handle) {
      __publicField(this, "_handle");
      this._handle = handle;
    }
    async requestDevice(_descriptor) {
      const native = getNative();
      const handle = native?.gpuRequestDevice?.(this._handle) ?? 0;
      return new GPUDevice(handle);
    }
    // Adapter features — real Dawn feature names
    get features() {
      return /* @__PURE__ */ new Set([
        "core-features-and-limits",
        "depth-clip-control",
        "depth32float-stencil8",
        "texture-compression-bc",
        "indirect-first-instance",
        "rg11b10ufloat-renderable",
        "bgra8unorm-storage",
        "float32-filterable",
        "subgroups"
      ]);
    }
    get limits() {
      return {
        maxTextureDimension1D: 8192,
        maxTextureDimension2D: 8192,
        maxTextureDimension3D: 2048,
        maxTextureArrayLayers: 256,
        maxBindGroups: 4,
        maxBindGroupsPlusVertexBuffers: 24,
        maxBindingsPerBindGroup: 1e3,
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
        maxComputeWorkgroupsPerDimension: 65535
      };
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

  // bootstrap/image.ts
  var ImageBitmap = class {
    // RGBA pixels
    constructor(width, height, data) {
      __publicField(this, "width");
      __publicField(this, "height");
      __publicField(this, "_data");
      this.width = width;
      this.height = height;
      this._data = data;
    }
    close() {
    }
  };
  var ImageElement = class extends EventTarget {
    constructor() {
      super(...arguments);
      __publicField(this, "width", 0);
      __publicField(this, "height", 0);
      __publicField(this, "_src", "");
      __publicField(this, "_data", null);
      __publicField(this, "_complete", false);
      __publicField(this, "crossOrigin", null);
      // Callback-style event handlers (Three.js uses these)
      __publicField(this, "onload", null);
      __publicField(this, "onerror", null);
    }
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

  // bootstrap/dom.ts
  var CanvasStub = class extends EventTarget {
    constructor() {
      super(...arguments);
      __publicField(this, "width", 800);
      __publicField(this, "height", 600);
      __publicField(this, "style", {});
      __publicField(this, "_attributes", /* @__PURE__ */ new Map());
      __publicField(this, "_gpuContext", null);
    }
    getContext(contextId) {
      if (contextId === "webgpu") {
        if (!this._gpuContext) {
          this._gpuContext = new GPUCanvasContext();
        }
        return this._gpuContext;
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
    constructor(canvas) {
      super();
      __publicField(this, "body", new EventTarget());
      __publicField(this, "documentElement", new EventTarget());
      __publicField(this, "visibilityState", "visible");
      __publicField(this, "hidden", false);
      __publicField(this, "_canvas");
      this._canvas = canvas;
    }
    createElement(tagName) {
      const tag = tagName.toLowerCase();
      if (tag === "canvas") {
        return this._canvas;
      }
      if (tag === "img") {
        return new ImageElement();
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
        },
        removeChild(child) {
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
    constructor(document, navigator) {
      super();
      __publicField(this, "innerWidth", 800);
      __publicField(this, "innerHeight", 600);
      __publicField(this, "devicePixelRatio", 1);
      __publicField(this, "navigator");
      __publicField(this, "document");
      __publicField(this, "_rafId", 0);
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
    constructor(init) {
      __publicField(this, "_map", {});
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
    constructor(body, status, statusText, url, headers) {
      __publicField(this, "ok");
      __publicField(this, "status");
      __publicField(this, "statusText");
      __publicField(this, "url");
      __publicField(this, "headers");
      __publicField(this, "_body");
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

  // bootstrap/webgpu-constants.ts
  function installWebGPUConstants() {
    const g2 = globalThis;
    g2.GPUBufferUsage = Object.freeze({
      MAP_READ: 1,
      MAP_WRITE: 2,
      COPY_SRC: 4,
      COPY_DST: 8,
      INDEX: 16,
      VERTEX: 32,
      UNIFORM: 64,
      STORAGE: 128,
      INDIRECT: 256,
      QUERY_RESOLVE: 512
    });
    g2.GPUTextureUsage = Object.freeze({
      COPY_SRC: 1,
      COPY_DST: 2,
      TEXTURE_BINDING: 4,
      STORAGE_BINDING: 8,
      RENDER_ATTACHMENT: 16
    });
    g2.GPUMapMode = Object.freeze({
      READ: 1,
      WRITE: 2
    });
    g2.GPUShaderStage = Object.freeze({
      VERTEX: 1,
      FRAGMENT: 2,
      COMPUTE: 4
    });
  }

  // bootstrap/abort.ts
  var AbortSignal = class _AbortSignal extends EventTarget {
    constructor() {
      super(...arguments);
      __publicField(this, "aborted", false);
      __publicField(this, "reason");
      // Callback-style handler (used by some code paths)
      __publicField(this, "onabort", null);
    }
    throwIfAborted() {
      if (this.aborted) {
        throw this.reason;
      }
    }
    /** Internal: mark this signal as aborted and fire the abort event. */
    _abort(reason) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason ?? new DOMException("The operation was aborted.", "AbortError");
      const event = new Event("abort");
      if (this.onabort) this.onabort.call(this, event);
      this.dispatchEvent(event);
    }
    static abort(reason) {
      const signal = new _AbortSignal();
      signal._abort(reason ?? new DOMException("The operation was aborted.", "AbortError"));
      return signal;
    }
    static timeout(ms) {
      const signal = new _AbortSignal();
      return signal;
    }
    static any(signals) {
      const combined = new _AbortSignal();
      for (const s of signals) {
        if (s.aborted) {
          combined._abort(s.reason);
          return combined;
        }
      }
      for (const s of signals) {
        s.addEventListener("abort", () => {
          combined._abort(s.reason);
        }, { once: true });
      }
      return combined;
    }
  };
  var DOMException = class extends Error {
    constructor(message, name) {
      super(message ?? "");
      __publicField(this, "name");
      __publicField(this, "code");
      this.name = name ?? "Error";
      this.code = 0;
    }
  };
  var AbortController = class {
    constructor() {
      __publicField(this, "signal");
      this.signal = new AbortSignal();
    }
    abort(reason) {
      this.signal._abort(reason);
    }
  };
  function installAbort() {
    const g2 = globalThis;
    g2.AbortController = AbortController;
    g2.AbortSignal = AbortSignal;
    g2.DOMException = DOMException;
  }

  // bootstrap/request.ts
  var Headers = class _Headers {
    constructor(init) {
      __publicField(this, "_map", /* @__PURE__ */ new Map());
      if (init) {
        if (init instanceof _Headers) {
          init.forEach((value, name) => {
            this._map.set(name.toLowerCase(), value);
          });
        } else {
          for (const key of Object.keys(init)) {
            this._map.set(key.toLowerCase(), init[key]);
          }
        }
      }
    }
    append(name, value) {
      const key = name.toLowerCase();
      const existing = this._map.get(key);
      if (existing !== void 0) {
        this._map.set(key, existing + ", " + value);
      } else {
        this._map.set(key, value);
      }
    }
    get(name) {
      return this._map.get(name.toLowerCase()) ?? null;
    }
    set(name, value) {
      this._map.set(name.toLowerCase(), value);
    }
    has(name) {
      return this._map.has(name.toLowerCase());
    }
    delete(name) {
      this._map.delete(name.toLowerCase());
    }
    forEach(callback) {
      this._map.forEach((value, name) => {
        callback(value, name, this);
      });
    }
    entries() {
      return this._map.entries();
    }
    keys() {
      return this._map.keys();
    }
    values() {
      return this._map.values();
    }
    [Symbol.iterator]() {
      return this._map.entries();
    }
  };
  var Request = class _Request {
    constructor(input, init) {
      __publicField(this, "url");
      __publicField(this, "method");
      __publicField(this, "headers");
      __publicField(this, "signal");
      __publicField(this, "mode");
      __publicField(this, "credentials");
      __publicField(this, "cache");
      __publicField(this, "redirect");
      __publicField(this, "referrer");
      __publicField(this, "integrity");
      __publicField(this, "body");
      if (typeof input === "string") {
        this.url = input;
      } else {
        this.url = input.url;
      }
      this.method = init?.method ?? "GET";
      this.headers = new Headers(init?.headers);
      this.signal = init?.signal ?? null;
      this.mode = init?.mode ?? "cors";
      this.credentials = init?.credentials ?? "same-origin";
      this.cache = init?.cache ?? "default";
      this.redirect = init?.redirect ?? "follow";
      this.referrer = init?.referrer ?? "about:client";
      this.integrity = init?.integrity ?? "";
      this.body = init?.body ?? null;
    }
    clone() {
      return new _Request(this.url, {
        method: this.method,
        headers: this.headers,
        body: this.body,
        signal: this.signal
      });
    }
  };
  function installRequest() {
    const g2 = globalThis;
    g2.Headers = Headers;
    g2.Request = Request;
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
  var CustomEvent = class extends Event {
    constructor(type, init) {
      super(type, init);
      __publicField(this, "detail");
      this.detail = init?.detail ?? null;
    }
  };
  g.CustomEvent = CustomEvent;
  g.requestAnimationFrame = (cb) => dom.window.requestAnimationFrame(cb);
  g.cancelAnimationFrame = (id) => dom.window.cancelAnimationFrame(id);
  g.innerWidth = dom.window.innerWidth;
  g.innerHeight = dom.window.innerHeight;
  g.devicePixelRatio = dom.window.devicePixelRatio;
  installWebGPUConstants();
  installFetch();
  installImage();
  installAbort();
  installRequest();
  var URLPolyfill = class {
    constructor(url, base) {
      __publicField(this, "href");
      __publicField(this, "origin");
      __publicField(this, "protocol");
      __publicField(this, "host");
      __publicField(this, "hostname");
      __publicField(this, "port");
      __publicField(this, "pathname");
      __publicField(this, "search");
      __publicField(this, "hash");
      __publicField(this, "searchParams");
      let resolved = url;
      if (base && !url.includes("://") && !url.startsWith("data:")) {
        if (url.startsWith("/")) {
          const match = base.match(/^(https?:\/\/[^/]+)/);
          resolved = match ? match[1] + url : url;
        } else {
          const lastSlash = base.lastIndexOf("/");
          resolved = base.slice(0, lastSlash + 1) + url;
        }
      }
      this.href = resolved;
      const protoMatch = resolved.match(/^([a-z][a-z0-9+.-]*:)/i);
      this.protocol = protoMatch ? protoMatch[1] : "";
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
      const colonIdx = this.host.indexOf(":");
      if (colonIdx !== -1) {
        this.hostname = this.host.slice(0, colonIdx);
        this.port = this.host.slice(colonIdx + 1);
      } else {
        this.hostname = this.host;
        this.port = "";
      }
      this.origin = this.protocol ? this.protocol + "//" + this.host : "";
      const hashIdx = this.pathname.indexOf("#");
      if (hashIdx !== -1) {
        this.hash = this.pathname.slice(hashIdx);
        this.pathname = this.pathname.slice(0, hashIdx);
      } else {
        this.hash = "";
      }
      const searchIdx = this.pathname.indexOf("?");
      if (searchIdx !== -1) {
        this.search = this.pathname.slice(searchIdx);
        this.pathname = this.pathname.slice(0, searchIdx);
      } else {
        this.search = "";
      }
      this.searchParams = {
        get(_name) {
          return null;
        },
        has(_name) {
          return false;
        },
        toString() {
          return "";
        }
      };
    }
    toString() {
      return this.href;
    }
  };
  if (typeof g.URL === "undefined") {
    g.URL = URLPolyfill;
  }
  if (typeof g.URLSearchParams === "undefined") {
    g.URLSearchParams = class URLSearchParams {
      constructor(_init) {
        __publicField(this, "_entries", []);
      }
      get(_name) {
        return null;
      }
      has(_name) {
        return false;
      }
      set(_name, _value) {
      }
      append(_name, _value) {
      }
      delete(_name) {
      }
      toString() {
        return "";
      }
    };
  }
})();
