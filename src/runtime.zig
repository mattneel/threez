const std = @import("std");
const zglfw = @import("zglfw");
const quickjs = @import("quickjs");
const Value = quickjs.Value;

const JsEngine = @import("js_engine.zig").JsEngine;
const bootstrap = @import("bootstrap.zig");
const polyfills = @import("polyfills.zig");
const TimerQueue = polyfills.timers.TimerQueue;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const Window = @import("window.zig").Window;
const HandleTable = @import("handle_table.zig").HandleTable;
const GpuBridge = @import("gpu_bridge.zig").GpuBridge;
const EventBridge = @import("event_bridge.zig").EventBridge;

const log = std.log.scoped(.runtime);

pub const ErrorMode = enum {
    resilient,
    fail_fast,
};

pub const RuntimeConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "threez",
    max_handles: u32 = HandleTable.default_capacity,
    assets_dir: ?[]const u8 = null,
    script_dir: []const u8 = ".",
    source_name: []const u8 = "<script>",
    error_mode: ErrorMode = .resilient,
};

const CallbackState = struct {
    event_bridge: *EventBridge,
    gpu_bridge: *GpuBridge,
};

const PromiseTrackerState = struct {
    fail_fast: bool,
    had_unhandled_rejection: bool = false,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    window: Window,
    engine: JsEngine,
    timer_queue: TimerQueue,
    handle_table: HandleTable,
    gpu_bridge: GpuBridge,
    event_loop: EventLoop,
    event_bridge: EventBridge,
    callback_state: CallbackState,
    error_mode: ErrorMode,
    promise_state: PromiseTrackerState,

    pub fn init(
        allocator: std.mem.Allocator,
        js_source: []const u8,
        config: RuntimeConfig,
    ) !*Runtime {
        var window = try Window.init(allocator, .{
            .width = config.width,
            .height = config.height,
            .title = config.title,
        });
        errdefer window.deinit();

        var engine = try JsEngine.init(allocator);
        errdefer engine.deinit();

        var promise_state = PromiseTrackerState{
            .fail_fast = config.error_mode == .fail_fast,
        };
        engine.runtime.setHostPromiseRejectionTracker(PromiseTrackerState, &promise_state, &promiseRejectionTracker);

        var timer_queue = TimerQueue.init(allocator);
        errdefer timer_queue.deinit(engine.context);
        try polyfills.registerAll(engine.context, &timer_queue);

        var handle_table = try HandleTable.init(allocator, config.max_handles);
        errdefer handle_table.deinit(allocator);

        var gpu_bridge = try GpuBridge.init(&handle_table, window.gctx);
        errdefer gpu_bridge.deinit();
        try gpu_bridge.register(engine.context);

        try bootstrap.init(&engine);
        try setWindowAndCanvasSize(&engine, window.getSize().width, window.getSize().height);

        var event_loop = EventLoop.init(allocator, &engine, &timer_queue);
        errdefer event_loop.deinit();
        event_loop.setFailFast(config.error_mode == .fail_fast);
        try event_loop_mod.register(engine.context, &event_loop);
        try syncAnimationFrameGlobals(&engine);

        const js_window = blk: {
            const global = engine.context.getGlobalObject();
            defer global.deinit(engine.context);
            break :blk global.getPropertyStr(engine.context, "window");
        };
        var own_js_window = true;
        defer if (own_js_window) js_window.deinit(engine.context);

        const js_document = blk: {
            const global = engine.context.getGlobalObject();
            defer global.deinit(engine.context);
            break :blk global.getPropertyStr(engine.context, "document");
        };
        var own_js_document = true;
        defer if (own_js_document) js_document.deinit(engine.context);

        const js_canvas = blk: {
            var canvas_result = engine.eval("document.createElement('canvas')", "<runtime>") catch {
                clearPendingException(engine.context);
                return error.BootstrapFailed;
            };
            const val = canvas_result.value;
            _ = &canvas_result;
            break :blk val;
        };
        var own_js_canvas = true;
        defer if (own_js_canvas) js_canvas.deinit(engine.context);

        var event_bridge = EventBridge.init(engine.context, js_window, js_document, js_canvas);
        own_js_window = false;
        own_js_document = false;
        own_js_canvas = false;
        errdefer event_bridge.deinit();

        const runtime_script_dir = config.assets_dir orelse config.script_dir;
        try setScriptDir(engine.context, runtime_script_dir);

        const source_name_z = try allocator.dupeZ(u8, config.source_name);
        defer allocator.free(source_name_z);

        log.info("evaluating '{s}'", .{config.source_name});
        var result = engine.eval(js_source, source_name_z) catch |err| {
            clearPendingException(engine.context);
            log.err("JS exception loading '{s}': {}", .{ config.source_name, err });
            return err;
        };
        result.deinit();

        log.info("pumping microtasks until rAF registered", .{});
        event_loop.pumpUntilReady();
        gpu_bridge.presentIfNeeded();

        if (event_loop.raf_callbacks.items.len == 0) {
            log.warn("no rAF callbacks registered after pump — animation loop may not be running", .{});
        } else {
            log.info("rAF registered, {} callback(s) pending", .{event_loop.raf_callbacks.items.len});
        }

        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .window = window,
            .engine = engine,
            .timer_queue = timer_queue,
            .handle_table = handle_table,
            .gpu_bridge = gpu_bridge,
            .event_loop = event_loop,
            .event_bridge = event_bridge,
            .callback_state = undefined,
            .error_mode = config.error_mode,
            .promise_state = promise_state,
        };

        runtime.gpu_bridge.handle_table_ptr = &runtime.handle_table;
        runtime.event_loop.engine = &runtime.engine;
        runtime.event_loop.timer_queue = &runtime.timer_queue;

        // Re-register closures with stable pointers now that runtime-owned
        // fields are at their final address.
        try polyfills.timers.register(runtime.engine.context, &runtime.timer_queue);
        try runtime.gpu_bridge.register(runtime.engine.context);
        try event_loop_mod.register(runtime.engine.context, &runtime.event_loop);
        try syncAnimationFrameGlobals(&runtime.engine);
        runtime.engine.runtime.setHostPromiseRejectionTracker(PromiseTrackerState, &runtime.promise_state, &promiseRejectionTracker);

        runtime.callback_state = .{
            .event_bridge = &runtime.event_bridge,
            .gpu_bridge = &runtime.gpu_bridge,
        };

        runtime.window.glfw_window.setUserPointer(@ptrCast(&runtime.callback_state));
        _ = runtime.window.glfw_window.setCursorPosCallback(&glfwCursorPosCallback);
        _ = runtime.window.glfw_window.setMouseButtonCallback(&glfwMouseButtonCallback);
        _ = runtime.window.glfw_window.setScrollCallback(&glfwScrollCallback);
        _ = runtime.window.glfw_window.setKeyCallback(&glfwKeyCallback);
        _ = runtime.window.glfw_window.setFramebufferSizeCallback(&glfwFramebufferSizeCallback);
        _ = runtime.window.glfw_window.setCursorEnterCallback(&glfwCursorEnterCallback);

        return runtime;
    }

    pub fn runLoop(self: *Runtime) !void {
        log.info("entering main loop", .{});
        while (!self.window.shouldClose() and self.event_loop.running) {
            self.window.pollEvents();
            self.event_loop.tick();
            self.gpu_bridge.presentIfNeeded();
            if (self.error_mode == .fail_fast and self.promise_state.had_unhandled_rejection) {
                self.event_loop.stop();
            }
        }
        log.info("main loop exited", .{});
        if (self.error_mode == .fail_fast and (self.event_loop.hasFatalError() or self.promise_state.had_unhandled_rejection)) {
            return error.StrictModeAbort;
        }
    }

    pub fn deinit(self: *Runtime) void {
        self.window.glfw_window.setUserPointer(null);

        self.event_bridge.deinit();
        self.event_loop.deinit();
        self.gpu_bridge.deinit();
        self.handle_table.deinit(self.allocator);
        self.timer_queue.deinit(self.engine.context);
        self.engine.deinit();
        self.window.deinit();

        self.allocator.destroy(self);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    js_source: []const u8,
    config: RuntimeConfig,
) !*Runtime {
    return Runtime.init(allocator, js_source, config);
}

fn setScriptDir(ctx: *quickjs.Context, script_dir: []const u8) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const path_val = Value.initStringLen(ctx, script_dir);
    global.setPropertyStr(ctx, "__scriptDir", path_val) catch return error.BootstrapFailed;
}

fn setWindowAndCanvasSize(engine: *JsEngine, width: u32, height: u32) !void {
    var buf: [512]u8 = @splat(0);
    const set_size_js = std.fmt.bufPrint(
        &buf,
        "window.innerWidth={0};window.innerHeight={1};document.createElement('canvas').width={0};document.createElement('canvas').height={1};",
        .{ width, height },
    ) catch unreachable;
    var r = engine.eval(set_size_js, "<runtime>") catch {
        clearPendingException(engine.context);
        return error.BootstrapFailed;
    };
    r.deinit();
}

fn syncAnimationFrameGlobals(engine: *JsEngine) !void {
    var r = engine.eval(
        "window.requestAnimationFrame = requestAnimationFrame;" ++
            "window.cancelAnimationFrame = cancelAnimationFrame;",
        "<runtime>",
    ) catch {
        clearPendingException(engine.context);
        return error.BootstrapFailed;
    };
    r.deinit();
}

fn clearPendingException(ctx: *quickjs.Context) void {
    const exc = ctx.getException();
    exc.deinit(ctx);
}

fn glfwCursorPosCallback(glfw_win: *zglfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onMouseMove(xpos, ypos);
}

fn glfwMouseButtonCallback(
    glfw_win: *zglfw.Window,
    button: zglfw.MouseButton,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onMouseButton(
        @intFromEnum(button),
        @intFromEnum(action),
        @bitCast(mods),
    );
}

fn glfwScrollCallback(glfw_win: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onScroll(xoffset, yoffset);
}

fn glfwKeyCallback(
    glfw_win: *zglfw.Window,
    key: zglfw.Key,
    scancode: c_int,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onKey(
        @intFromEnum(key),
        scancode,
        @intFromEnum(action),
        @bitCast(mods),
    );
}

fn glfwFramebufferSizeCallback(glfw_win: *zglfw.Window, width: c_int, height: c_int) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    if (width > 0 and height > 0) {
        state.gpu_bridge.onFramebufferResize(@intCast(width), @intCast(height));
    }
    state.event_bridge.onResize(@intCast(width), @intCast(height));
}

fn glfwCursorEnterCallback(glfw_win: *zglfw.Window, entered: c_int) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onCursorEnter(entered != 0);
}

fn promiseRejectionTracker(
    state_opt: ?*PromiseTrackerState,
    ctx: *quickjs.Context,
    _: quickjs.Value,
    reason: quickjs.Value,
    is_handled: bool,
) void {
    if (is_handled) return;

    const state = state_opt orelse return;
    state.had_unhandled_rejection = true;

    if (reason.toCString(ctx)) |msg| {
        log.err("unhandled promise rejection: {s}", .{std.mem.span(msg)});
        ctx.freeCString(msg);
    } else {
        log.err("unhandled promise rejection (non-string reason)", .{});
    }

    if (state.fail_fast) {
        log.err("strict mode: aborting on unhandled promise rejection", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}
