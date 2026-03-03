const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

const log = std.log.scoped(.console);

/// Registers a `console` object on globalThis with log, warn, error, and info methods.
pub fn register(ctx: *Context) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const console_obj = Value.initObject(ctx);

    const log_fn = Value.initCFunction(ctx, &consoleLog, "log", 0);
    console_obj.setPropertyStr(ctx, "log", log_fn) catch return error.JSError;

    const info_fn = Value.initCFunction(ctx, &consoleInfo, "info", 0);
    console_obj.setPropertyStr(ctx, "info", info_fn) catch return error.JSError;

    const warn_fn = Value.initCFunction(ctx, &consoleWarn, "warn", 0);
    console_obj.setPropertyStr(ctx, "warn", warn_fn) catch return error.JSError;

    const error_fn = Value.initCFunction(ctx, &consoleError, "error", 0);
    console_obj.setPropertyStr(ctx, "error", error_fn) catch return error.JSError;

    global.setPropertyStr(ctx, "console", console_obj) catch return error.JSError;
}

fn consoleLog(ctx_opt: ?*Context, _: Value, argv: []const c.JSValue) Value {
    logArgs(.info, ctx_opt, argv);
    return Value.undefined;
}

fn consoleInfo(ctx_opt: ?*Context, _: Value, argv: []const c.JSValue) Value {
    logArgs(.info, ctx_opt, argv);
    return Value.undefined;
}

fn consoleWarn(ctx_opt: ?*Context, _: Value, argv: []const c.JSValue) Value {
    logArgs(.warn, ctx_opt, argv);
    return Value.undefined;
}

fn consoleError(ctx_opt: ?*Context, _: Value, argv: []const c.JSValue) Value {
    logArgs(.err, ctx_opt, argv);
    return Value.undefined;
}

/// Build a single message string from JS args and emit via std.log.
fn logArgs(comptime level: std.log.Level, ctx_opt: ?*Context, argv: []const c.JSValue) void {
    const ctx = ctx_opt orelse return;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    for (argv, 0..) |raw_arg, i| {
        if (i > 0) writer.writeAll(" ") catch break;

        const arg: Value = @bitCast(raw_arg);
        const str_ptr = arg.toCString(ctx);
        if (str_ptr) |ptr| {
            writer.writeAll(std.mem.span(ptr)) catch break;
            ctx.freeCString(ptr);
        } else {
            writer.writeAll("[object]") catch break;
        }
    }

    const msg = fbs.getWritten();
    switch (level) {
        .info => log.info("{s}", .{msg}),
        .warn => log.warn("{s}", .{msg}),
        .err => log.err("{s}", .{msg}),
        .debug => log.debug("{s}", .{msg}),
    }
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;

test "console.log evaluates without exception" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("console.log('test', 42, true, null, undefined); 'ok'", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("ok", str);
}

// console.warn and console.error are verified callable by the
// "console methods exist as functions" test. We don't invoke them
// here because std.log.warn/err trigger the Zig test runner's
// "logged errors" detection, which correctly flags them as test failures.

test "console.info evaluates without exception" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("console.info('info message'); 'ok'", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("ok", str);
}

test "console methods exist as functions" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\typeof console.log === 'function' &&
        \\typeof console.warn === 'function' &&
        \\typeof console.error === 'function' &&
        \\typeof console.info === 'function'
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}
