const std = @import("std");
const builtin = @import("builtin");
const dawn = @import("dawn/context.zig");
const wgpu = dawn.wgpu;
const AndroidWindow = @import("android_window.zig").AndroidWindow;
const AndroidRuntime = @import("android_runtime.zig").AndroidRuntime;
const EventBridge = @import("event_bridge.zig").EventBridge;
const fetch = @import("polyfills/fetch.zig");
const image = @import("polyfills/image.zig");

pub const c = @cImport({
    @cInclude("android_native_app_glue.h");
    @cInclude("android/native_window.h");
    @cInclude("android/input.h");
    @cInclude("android/asset_manager.h");
    @cInclude("android/log.h");
});

pub const AndroidApp = struct {
    native_app: *c.struct_android_app,
    window: ?*c.ANativeWindow = null,
    window_width: u32 = 0,
    window_height: u32 = 0,
    state: State = .created,
    gpu_window: ?AndroidWindow = null,
    runtime: ?*AndroidRuntime = null,
    event_bridge: ?*EventBridge = null,
    asset_manager: ?*c.AAssetManager = null,
    allocator: std.mem.Allocator,

    pub const State = enum {
        created,
        window_ready,
        running,
        paused,
        window_lost,
        destroyed,
    };
};

/// Entry point called from native_app_glue's android_main.
pub fn run(opaque_app: *anyopaque) void {
    const native_app: *c.struct_android_app = @ptrCast(@alignCast(opaque_app));
    logInfo("threez android_main started");

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = AndroidApp{
        .native_app = native_app,
        .allocator = allocator,
    };

    native_app.onAppCmd = onAppCmd;
    native_app.onInputEvent = onInputEvent;
    native_app.userData = @ptrCast(&app);

    // Expose the AAssetManager to the fetch polyfill for APK asset loading.
    if (native_app.activity != null) {
        const activity = native_app.activity;
        if (activity.*.assetManager != null) {
            app.asset_manager = activity.*.assetManager;
            fetch.setAssetManager(@ptrCast(activity.*.assetManager));
            logInfo("AAssetManager registered");
        }
        if (activity.*.internalDataPath != null) {
            image.setTempDir(std.mem.span(activity.*.internalDataPath)) catch {};
        }
    }

    logInfo("Waiting for window...");

    // Main loop: process events until destroyed
    while (app.state != .destroyed) {
        pollEvents(&app);

        // Initialize Dawn surface + JS runtime when window first becomes ready
        if (app.state == .window_ready and app.gpu_window == null) {
            if (app.window) |win| {
                app.gpu_window = AndroidWindow.init(allocator, win, app.window_width, app.window_height) catch |err| {
                    logFmt("GPU init failed: {}", .{err});
                    app.state = .destroyed;
                    continue;
                };
                logInfo("Dawn GPU surface created");

                // Initialize the JS runtime with the GPU context
                app.runtime = AndroidRuntime.init(allocator, app.gpu_window.?.gctx, app.window_width, app.window_height) catch |err| {
                    logFmt("Runtime init failed: {}", .{err});
                    app.state = .destroyed;
                    continue;
                };
                app.event_bridge = &app.runtime.?.event_bridge;
                logInfo("JS runtime initialized");

                // Load and evaluate user script from APK assets
                if (loadAsset(allocator, app.asset_manager, "app.js")) |script| {
                    defer allocator.free(script);
                    logFmt("Loaded app.js ({} bytes), evaluating...", .{script.len});
                    app.runtime.?.evalScript(script, "app.js") catch |err| {
                        logFmt("Script eval failed: {}", .{err});
                    };
                    logInfo("User script evaluated");
                } else {
                    logInfo("No app.js found in assets — running with bootstrap only");
                }

                app.state = .running;
            }
        }

        // Tick the JS event loop each frame (skip when paused or window lost)
        if (app.state == .running) {
            if (app.runtime) |rt| {
                rt.tick();
            }
        }
    }

    if (app.runtime) |rt| {
        app.event_bridge = null;
        rt.deinit();
        app.runtime = null;
    }
    if (app.gpu_window) |*gw| gw.deinit();
    logInfo("threez android_main exiting");
}

/// Poll and dispatch all pending events.
///
/// Blocks when paused or waiting for window (saves battery).
/// Non-blocking during active rendering.
pub fn pollEvents(app: *AndroidApp) void {
    // Block when paused/created to save battery, non-blocking otherwise
    const timeout: c_int = switch (app.state) {
        .paused, .created, .window_lost => -1,
        else => 0,
    };

    var source: ?*anyopaque = null;
    var result = c.ALooper_pollOnce(timeout, null, null, @ptrCast(&source));
    while (result >= 0) {
        if (source) |s| {
            const ps: *c.struct_android_poll_source = @ptrCast(@alignCast(s));
            if (ps.process) |process_fn| {
                process_fn(app.native_app, ps);
            }
        }
        source = null;

        if (app.native_app.destroyRequested != 0) {
            app.state = .destroyed;
            return;
        }

        // Drain remaining events non-blocking
        result = c.ALooper_pollOnce(0, null, null, @ptrCast(&source));
    }
}

fn onAppCmd(native_app: ?*c.struct_android_app, cmd: i32) callconv(.c) void {
    const app_ptr = native_app orelse return;
    const app: *AndroidApp = @ptrCast(@alignCast(app_ptr.userData));

    switch (cmd) {
        c.APP_CMD_INIT_WINDOW => {
            app.window = app_ptr.window;
            if (app_ptr.window) |win| {
                app.window_width = @intCast(c.ANativeWindow_getWidth(win));
                app.window_height = @intCast(c.ANativeWindow_getHeight(win));
            }
            app.state = .window_ready;
            logFmt("INIT_WINDOW: {}x{}", .{ app.window_width, app.window_height });
        },
        c.APP_CMD_TERM_WINDOW => {
            if (app.runtime) |rt| {
                app.event_bridge = null;
                rt.deinit();
                app.runtime = null;
            }
            if (app.gpu_window) |*gw| {
                gw.deinit();
                app.gpu_window = null;
            }
            app.window = null;
            app.state = .window_lost;
            logInfo("TERM_WINDOW");
        },
        c.APP_CMD_RESUME => {
            app.state = if (app.gpu_window != null) .running else .created;
            logInfo("RESUME");
        },
        c.APP_CMD_PAUSE => {
            app.state = .paused;
            logInfo("PAUSE");
        },
        c.APP_CMD_DESTROY => {
            app.state = .destroyed;
            logInfo("DESTROY");
        },
        c.APP_CMD_GAINED_FOCUS => logInfo("GAINED_FOCUS"),
        c.APP_CMD_LOST_FOCUS => logInfo("LOST_FOCUS"),
        c.APP_CMD_CONFIG_CHANGED => logInfo("CONFIG_CHANGED"),
        c.APP_CMD_LOW_MEMORY => logInfo("LOW_MEMORY"),
        else => {},
    }
}

// -- Asset loading helper --

fn loadAsset(allocator: std.mem.Allocator, mgr_opt: ?*c.AAssetManager, path: [*:0]const u8) ?[]u8 {
    const mgr = mgr_opt orelse return null;
    const asset = c.AAssetManager_open(mgr, path, c.AASSET_MODE_BUFFER) orelse return null;
    defer c.AAsset_close(asset);
    const len = c.AAsset_getLength(asset);
    if (len <= 0) return null;
    const ulen: usize = @intCast(len);
    const buf = allocator.alloc(u8, ulen) catch return null;
    const read = c.AAsset_read(asset, buf.ptr, ulen);
    if (read != len) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

// -- Clear-color render (T11 integration test) --

fn renderClearColor(gctx: *dawn.GraphicsContext) void {
    const view = gctx.getCurrentTextureView() orelse return;
    defer view.release();

    const encoder = gctx.device.createCommandEncoder(.{ .label = "clear" });
    defer encoder.release();

    const color_attachment = wgpu.RenderPassColorAttachment{
        .view = view,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .r = 0.15, .g = 0.15, .b = 0.25, .a = 1.0 },
    };

    const pass = encoder.beginRenderPass(.{
        .color_attachment_count = 1,
        .color_attachments = @ptrCast(&color_attachment),
        .depth_stencil_attachment = null,
    });
    pass.end();
    pass.release();

    const cmdbuf = encoder.finish(.{ .label = null });
    defer cmdbuf.release();
    gctx.queue.submit(&.{cmdbuf});
    _ = gctx.present();
}

// -- Android touch input → PointerEvent --

fn onInputEvent(native_app: ?*c.struct_android_app, event: ?*c.AInputEvent) callconv(.c) i32 {
    const app_ptr = native_app orelse return 0;
    const app: *AndroidApp = @ptrCast(@alignCast(app_ptr.userData));
    const ev = event orelse return 0;

    if (c.AInputEvent_getType(ev) != c.AINPUT_EVENT_TYPE_MOTION) return 0;

    const bridge = app.event_bridge orelse return 1; // consume but can't dispatch yet

    const action = c.AMotionEvent_getAction(ev);
    const action_masked: u32 = @intCast(action & c.AMOTION_EVENT_ACTION_MASK);
    const pointer_count = c.AMotionEvent_getPointerCount(ev);
    const pointer_index: usize = @intCast(
        (@as(u32, @intCast(action)) & @as(u32, @intCast(c.AMOTION_EVENT_ACTION_POINTER_INDEX_MASK))) >>
            @intCast(c.AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT),
    );

    switch (action_masked) {
        c.AMOTION_EVENT_ACTION_DOWN, c.AMOTION_EVENT_ACTION_POINTER_DOWN => {
            const i = pointer_index;
            dispatchTouch(bridge, "pointerdown", ev, i);
        },
        c.AMOTION_EVENT_ACTION_UP, c.AMOTION_EVENT_ACTION_POINTER_UP => {
            const i = pointer_index;
            dispatchTouch(bridge, "pointerup", ev, i);
        },
        c.AMOTION_EVENT_ACTION_MOVE => {
            // MOVE reports all active pointers
            for (0..pointer_count) |i| {
                dispatchTouch(bridge, "pointermove", ev, i);
            }
        },
        c.AMOTION_EVENT_ACTION_CANCEL => {
            for (0..pointer_count) |i| {
                dispatchTouch(bridge, "pointercancel", ev, i);
            }
        },
        else => return 0,
    }
    return 1; // consumed
}

fn dispatchTouch(bridge: *EventBridge, event_type: []const u8, ev: *c.AInputEvent, i: usize) void {
    const pointer_id: i32 = @intCast(c.AMotionEvent_getPointerId(ev, i));
    const x: f64 = @floatCast(c.AMotionEvent_getX(ev, i));
    const y: f64 = @floatCast(c.AMotionEvent_getY(ev, i));
    const pressure: f64 = @floatCast(c.AMotionEvent_getPressure(ev, i));
    const tool_type: i32 = c.AMotionEvent_getToolType(ev, i);
    const pointer_type: []const u8 = if (tool_type == c.AMOTION_EVENT_TOOL_TYPE_STYLUS) "pen" else "touch";

    bridge.onTouch(event_type, x, y, pointer_id, pointer_type, pressure);
}

// -- Logcat helpers --

fn logInfo(msg: [*:0]const u8) void {
    _ = c.__android_log_write(c.ANDROID_LOG_INFO, "threez", msg);
}

fn logFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const slice = std.fmt.bufPrint(buf[0..511], fmt, args) catch "";
    buf[slice.len] = 0;
    _ = c.__android_log_write(c.ANDROID_LOG_INFO, "threez", @ptrCast(buf[0..].ptr));
}
