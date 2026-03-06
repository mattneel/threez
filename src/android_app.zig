const std = @import("std");
const builtin = @import("builtin");
const AndroidWindow = @import("android_window.zig").AndroidWindow;

pub const c = @cImport({
    @cInclude("android_native_app_glue.h");
    @cInclude("android/native_window.h");
    @cInclude("android/log.h");
});

pub const AndroidApp = struct {
    native_app: *c.struct_android_app,
    window: ?*c.ANativeWindow = null,
    window_width: u32 = 0,
    window_height: u32 = 0,
    state: State = .created,
    gpu_window: ?AndroidWindow = null,
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
    native_app.userData = @ptrCast(&app);

    logInfo("Waiting for window...");

    // Main loop: process events until destroyed
    while (app.state != .destroyed) {
        pollEvents(&app);

        // Initialize Dawn surface when window first becomes ready
        if (app.state == .window_ready and app.gpu_window == null) {
            if (app.window) |win| {
                app.gpu_window = AndroidWindow.init(allocator, win, app.window_width, app.window_height) catch |err| {
                    logFmt("GPU init failed: {}", .{err});
                    app.state = .destroyed;
                    continue;
                };
                app.state = .running;
                logInfo("Dawn GPU surface created");
            }
        }

        // TODO(T11+): Render frame when in running state
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
        .paused, .created => -1,
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
            if (app.gpu_window) |*gw| {
                gw.deinit();
                app.gpu_window = null;
            }
            app.window = null;
            app.state = .window_lost;
            logInfo("TERM_WINDOW");
        },
        c.APP_CMD_RESUME => {
            app.state = if (app.window != null) .running else .created;
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
