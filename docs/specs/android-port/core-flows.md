<!-- status: locked -->
<!-- epic-slug: android-port -->
# Core Flows: Android Port

## Flow 1: App Lifecycle State Machine

**Actors**: Android OS, NativeActivity, Threez Runtime
**Trigger**: User launches the app / OS lifecycle events
**Invariant**: GPU resources are only used when ANativeWindow is valid

```mermaid
stateDiagram-v2
    [*] --> Created : android_main() called
    Created --> WindowReady : APP_CMD_INIT_WINDOW (ANativeWindow available)
    WindowReady --> Running : Dawn surface created, JS evaluated, rAF loop started
    Running --> Running : frame loop (poll events → tick JS → present)
    Running --> Paused : APP_CMD_PAUSE
    Paused --> Running : APP_CMD_RESUME
    Running --> WindowLost : APP_CMD_TERM_WINDOW
    Paused --> WindowLost : APP_CMD_TERM_WINDOW
    WindowLost --> WindowReady : APP_CMD_INIT_WINDOW (new ANativeWindow)
    WindowLost --> [*] : APP_CMD_DESTROY
    Paused --> [*] : APP_CMD_DESTROY
    Running --> [*] : APP_CMD_DESTROY
```

**Key constraints**:
- Between `TERM_WINDOW` and a new `INIT_WINDOW`, no GPU operations may occur. Dawn surface + swapchain must be destroyed.
- Between `PAUSE` and `RESUME`, the entire JS event loop freezes — no rAF, no timers, no microtasks. Saves battery and avoids GPU errors from background execution.
- `APP_CMD_DESTROY` triggers full cleanup: JS engine, GPU bridge, handle table, event loop.

**Desktop comparison**: Desktop has none of this — the window exists for the entire process lifetime. On Android, the window can be destroyed and recreated (e.g., screen rotation, task switcher).

## Flow 2: Startup Sequence

**Actors**: Android OS, NativeActivity glue, Threez Runtime, Dawn, QuickJS

```mermaid
sequenceDiagram
    participant OS as Android OS
    participant Glue as native_app_glue
    participant RT as Threez Runtime
    participant Dawn as Dawn (Vulkan)
    participant QJS as QuickJS

    OS->>Glue: android_main(android_app*)
    Glue->>RT: init(android_app)
    RT->>RT: Store AAssetManager, internal data path
    RT->>RT: Wait for APP_CMD_INIT_WINDOW
    OS-->>Glue: APP_CMD_INIT_WINDOW
    Glue-->>RT: onNativeWindowCreated(ANativeWindow*)
    RT->>Dawn: createInstance() + createSurface(ANativeWindow)
    Dawn->>Dawn: vkCreateAndroidSurfaceKHR
    Dawn-->>RT: wgpu::Surface
    RT->>Dawn: requestAdapter → requestDevice
    Dawn-->>RT: adapter, device, queue
    RT->>RT: init handle table, GPU bridge
    RT->>QJS: create JS runtime + context
    RT->>QJS: evaluate bootstrap.js (polyfills)
    RT->>QJS: evaluate user script (gltf-viewer.js)
    QJS-->>RT: rAF callback registered
    RT->>RT: Enter render loop
```

**Key difference from desktop**: On desktop, GLFW window creation and Dawn surface creation happen synchronously in `runScript()`. On Android, we must wait for `APP_CMD_INIT_WINDOW` before creating the Dawn surface. The JS engine can be initialized earlier, but the GPU bridge can't be connected until the window exists.

## Flow 3: Render Loop (per frame)

**Actors**: Threez Runtime, ALooper, AInputQueue, QuickJS, Dawn
**Trigger**: Continuous while in Running state
**Invariant**: One present per frame, no GPU ops if window is lost

```mermaid
sequenceDiagram
    participant Looper as ALooper
    participant RT as Threez Runtime
    participant Input as AInputQueue
    participant EB as Event Bridge
    participant QJS as QuickJS
    participant Dawn as Dawn

    loop Every frame
        RT->>Looper: ALooper_pollAll(0) (non-blocking)
        Looper-->>RT: lifecycle commands (if any)
        RT->>RT: Handle APP_CMD_* (pause/resume/window)
        Looper-->>RT: input events available
        RT->>Input: AInputQueue_getEvent()
        Input-->>RT: AInputEvent* (touch/key/gamepad)
        RT->>EB: translateAndDispatch(event)
        EB->>QJS: dispatchEvent(domEvent)
        QJS-->>EB: (handlers run)
        RT->>RT: Tick event loop (timers, microtasks)
        RT->>QJS: Fire rAF callbacks
        QJS->>Dawn: WebGPU render commands (via GPU bridge)
        Dawn-->>RT: Frame rendered
        RT->>Dawn: present swapchain
    end
```

**Desktop comparison**: Desktop uses `glfwPollEvents()` instead of `ALooper_pollAll()`, and GLFW callbacks instead of `AInputQueue`. The rest (tick event loop, fire rAF, present) is identical.

## Flow 4: Input Event Translation

**Actors**: AInputQueue, Event Bridge, QuickJS
**Trigger**: User touches screen, presses gamepad button, uses stylus

### Touch → PointerEvent

```
AInputEvent (AMOTION_EVENT_ACTION_DOWN/MOVE/UP)
  ├── getX(), getY()              → clientX, clientY
  ├── getPointerId()              → pointerId
  ├── getPressure()               → pressure
  ├── getToolType()               → pointerType ("touch" | "pen")
  ├── getActionMasked()           → type ("pointerdown" | "pointermove" | "pointerup")
  └── getPointerCount()           → (multi-touch: dispatch per pointer)
```

**Multi-touch for OrbitControls**:
- 1 finger drag → `pointermove` → OrbitControls rotate
- 2 finger pinch → two `pointermove` events → OrbitControls zoom (distance change)
- 2 finger drag → two `pointermove` events → OrbitControls pan (centroid movement)

### Gamepad → GamepadEvent + KeyboardEvent

```
AInputEvent (AINPUT_SOURCE_GAMEPAD)
  ├── Axis events (AMOTION_EVENT_AXIS_*)  → Gamepad API axes
  ├── Button events (AKEY_EVENT_ACTION_*)  → Gamepad API buttons
  └── Mapped to navigator.getGamepads() polling model
```

### Stylus → PointerEvent (with extras)

```
AInputEvent (AMOTION_EVENT_TOOL_TYPE_STYLUS)
  ├── All touch fields above
  ├── getPressure()       → pressure (0.0–1.0, higher precision than finger)
  ├── getTiltX/Y()        → tiltX, tiltY
  └── pointerType = "pen"
```

## Flow 5: Asset Loading

**Actors**: JavaScript (fetch/GLTFLoader), Fetch Polyfill, AAssetManager / std.fs
**Trigger**: `fetch("DamagedHelmet.glb")` or `fetch("/sdcard/models/scene.glb")`

```mermaid
sequenceDiagram
    participant JS as JavaScript
    participant Fetch as Fetch Polyfill
    participant AAM as AAssetManager
    participant FS as std.fs

    JS->>Fetch: fetch(url)
    Fetch->>Fetch: Resolve path (relative to __scriptDir)

    alt Path starts with "asset://" or is relative
        Fetch->>AAM: AAssetManager_open(path)
        AAM-->>Fetch: AAsset* (or null)
        alt Asset found
            Fetch->>AAM: AAsset_read() → buffer
            AAM-->>Fetch: bytes
        else Asset not found
            Fetch-->>JS: Response { status: 404 }
        end
    else Absolute path (e.g. /sdcard/...)
        Fetch->>FS: std.fs.openFileAbsolute(path)
        FS-->>Fetch: file bytes
    else HTTP URL
        Fetch->>Fetch: std.http.Client.fetch(url)
    end

    Fetch-->>JS: Response { status: 200, body: ArrayBuffer }
```

**Key design choice**: Relative paths default to AAssetManager (APK-bundled). Absolute paths use filesystem. HTTP URLs use the network. This lets the same JS code (`fetch("DamagedHelmet.glb")`) work on both desktop (filesystem) and Android (APK assets) without changes.

## Flow 6: GPU Surface Lifecycle (Window Recreate)

**Actors**: Android OS, Threez Runtime, Dawn
**Trigger**: Screen rotation, task switcher return, split-screen toggle

```mermaid
sequenceDiagram
    participant OS as Android OS
    participant RT as Threez Runtime
    participant Dawn as Dawn

    Note over RT: Running state, rendering frames
    OS->>RT: APP_CMD_TERM_WINDOW
    RT->>RT: Stop render loop
    RT->>Dawn: destroy swapchain
    RT->>Dawn: destroy surface
    Note over RT: WindowLost state, no GPU ops

    OS->>RT: APP_CMD_INIT_WINDOW (new ANativeWindow*)
    RT->>Dawn: createSurface(newWindow)
    RT->>Dawn: configure swapchain (may have new dimensions)
    RT->>RT: Resume render loop
    Note over RT: Running state again
```

**Critical detail**: The handle table and JS-side GPU objects (device, queue, pipeline, etc.) survive the window recreate. Only the surface and swapchain are destroyed/recreated. This means the JS application doesn't need to know about window recreation — it just sees a resize event.
