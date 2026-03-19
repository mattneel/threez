const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const dawn = @import("dawn/context.zig");

const is_android = builtin.os.tag == .linux and builtin.abi == .android;
const android_c = if (is_android) @cImport(@cInclude("android/log.h")) else struct {};

const JsEngine = @import("js_engine.zig").JsEngine;
const bootstrap = @import("bootstrap.zig");
const polyfills = @import("polyfills.zig");
const TimerQueue = polyfills.timers.TimerQueue;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const HandleTable = @import("handle_table.zig").HandleTable;
const GpuBridge = @import("gpu_bridge.zig").GpuBridge;
const EventBridge = @import("event_bridge.zig").EventBridge;
const AndroidWindow = @import("android_window.zig").AndroidWindow;

const log = std.log.scoped(.runtime);

pub const AndroidRuntime = struct {
    allocator: std.mem.Allocator,
    engine: JsEngine,
    timer_queue: TimerQueue,
    handle_table: HandleTable,
    gpu_bridge: GpuBridge,
    event_loop: EventLoop,
    event_bridge: EventBridge,

    pub fn init(
        allocator: std.mem.Allocator,
        gctx: *dawn.GraphicsContext,
        width: u32,
        height: u32,
    ) !*AndroidRuntime {
        var engine = try JsEngine.init(allocator);
        errdefer engine.deinit();

        var timer_queue = TimerQueue.init(allocator);
        errdefer timer_queue.deinit(engine.context);
        try polyfills.registerAll(engine.context, &timer_queue);

        var handle_table = try HandleTable.init(allocator, HandleTable.default_capacity);
        errdefer handle_table.deinit(allocator);

        var gpu_bridge = try GpuBridge.init(&handle_table, gctx);
        errdefer gpu_bridge.deinit();
        try gpu_bridge.register(engine.context);

        try bootstrap.init(&engine);
        try setWindowAndCanvasSize(&engine, width, height);

        var event_loop = EventLoop.init(allocator, &engine, &timer_queue);
        errdefer event_loop.deinit();
        try event_loop_mod.register(engine.context, &event_loop);
        try syncAnimationFrameGlobals(&engine);

        // Create JS event targets
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

        // Set __scriptDir to empty — Android assets use AAssetManager
        try setScriptDir(engine.context, "");

        const runtime = try allocator.create(AndroidRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{
            .allocator = allocator,
            .engine = engine,
            .timer_queue = timer_queue,
            .handle_table = handle_table,
            .gpu_bridge = gpu_bridge,
            .event_loop = event_loop,
            .event_bridge = event_bridge,
        };

        // Fix up pointers after move to heap
        runtime.gpu_bridge.handle_table_ptr = &runtime.handle_table;
        runtime.event_loop.engine = &runtime.engine;
        runtime.event_loop.timer_queue = &runtime.timer_queue;

        try polyfills.timers.register(runtime.engine.context, &runtime.timer_queue);
        try runtime.gpu_bridge.register(runtime.engine.context);
        try event_loop_mod.register(runtime.engine.context, &runtime.event_loop);
        try syncAnimationFrameGlobals(&runtime.engine);

        return runtime;
    }

    /// Evaluate a user script. Call after init.
    pub fn evalScript(self: *AndroidRuntime, js_source: []const u8, source_name: []const u8) !void {
        const source_name_z = try self.allocator.dupeZ(u8, source_name);
        defer self.allocator.free(source_name_z);

        logcat("evalScript: evaluating");
        var result = self.engine.eval(js_source, source_name_z) catch |err| {
            clearPendingException(self.engine.context);
            logcat("evalScript: JS exception during eval");
            return err;
        };
        result.deinit();

        logcat("evalScript: pumping microtasks");
        self.event_loop.pumpUntilReady();
        self.gpu_bridge.presentIfNeeded();
    }

    /// Run one frame tick (timers, microtasks, rAF, present).
    pub fn tick(self: *AndroidRuntime) void {
        self.event_loop.tick();
        self.gpu_bridge.presentIfNeeded();
    }

    pub fn deinit(self: *AndroidRuntime) void {
        self.event_bridge.deinit();
        self.event_loop.deinit();
        self.gpu_bridge.deinit();
        self.handle_table.deinit(self.allocator);
        self.timer_queue.deinit(self.engine.context);
        self.engine.deinit();
        self.allocator.destroy(self);
    }
};

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

fn logcat(msg: [*:0]const u8) void {
    if (is_android) {
        _ = android_c.__android_log_write(android_c.ANDROID_LOG_INFO, "threez", msg);
    }
}
