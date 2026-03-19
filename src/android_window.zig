const std = @import("std");
const dawn = @import("dawn/context.zig");
const android_app_mod = @import("android_app.zig");
const c = android_app_mod.c;

const log = std.log.scoped(.android_window);

/// File-scoped state for zgpu WindowProvider callbacks (which take no context arg).
var g_native_window: ?*c.ANativeWindow = null;
var g_width: u32 = 0;
var g_height: u32 = 0;

pub const AndroidWindow = struct {
    gctx: *dawn.GraphicsContext,
    allocator: std.mem.Allocator,
    native_window: *c.ANativeWindow,

    pub fn init(allocator: std.mem.Allocator, native_window: *c.ANativeWindow, width: u32, height: u32) !AndroidWindow {
        // Set file-scoped state for WindowProvider callbacks.
        g_native_window = native_window;
        g_width = width;
        g_height = height;

        const window_provider = dawn.WindowProvider{
            .window = @ptrCast(native_window),
            .fn_getTime = &getTime,
            .fn_getFramebufferSize = &getFramebufferSize,
            .fn_getAndroidNativeWindow = &getAndroidNativeWindow,
        };

        log.info("creating GraphicsContext for ANativeWindow {}x{}", .{ width, height });
        const gctx = try dawn.GraphicsContext.create(allocator, window_provider, .{});

        return .{
            .gctx = gctx,
            .allocator = allocator,
            .native_window = native_window,
        };
    }

    pub fn deinit(self: *AndroidWindow) void {
        self.gctx.destroy(self.allocator);
        g_native_window = null;
    }

    pub fn getSize(self: *const AndroidWindow) struct { width: u32, height: u32 } {
        _ = self;
        return .{ .width = g_width, .height = g_height };
    }

    pub fn updateSize(self: *AndroidWindow, width: u32, height: u32) void {
        _ = self;
        g_width = width;
        g_height = height;
    }
};

// -- zgpu WindowProvider callbacks --

fn getTime() f64 {
    const ts = std.posix.clock_gettime(.MONOTONIC) catch return 0;
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
}

fn getFramebufferSize(_: *const anyopaque) [2]u32 {
    return .{ g_width, g_height };
}

fn getAndroidNativeWindow() callconv(.c) ?*anyopaque {
    return @ptrCast(g_native_window);
}
