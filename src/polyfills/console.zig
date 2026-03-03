const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Registers a `console` object on globalThis with log, warn, error, and info methods.
pub fn register(ctx: *Context) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const console_obj = Value.initObject(ctx);

    // log/info write to stdout; warn/error write to stderr.
    const log_fn = Value.initCFunction(ctx, &consoleLogStdout, "log", 0);
    console_obj.setPropertyStr(ctx, "log", log_fn) catch return error.JSError;

    const info_fn = Value.initCFunction(ctx, &consoleLogStdout, "info", 0);
    console_obj.setPropertyStr(ctx, "info", info_fn) catch return error.JSError;

    const warn_fn = Value.initCFunction(ctx, &consoleLogStderr, "warn", 0);
    console_obj.setPropertyStr(ctx, "warn", warn_fn) catch return error.JSError;

    const error_fn = Value.initCFunction(ctx, &consoleLogStderr, "error", 0);
    console_obj.setPropertyStr(ctx, "error", error_fn) catch return error.JSError;

    global.setPropertyStr(ctx, "console", console_obj) catch return error.JSError;
}

/// console.log / console.info — writes to stderr.
/// All console output goes to stderr because stdout is reserved for the Zig
/// test runner protocol and for structured CLI output.  This is appropriate
/// for a graphics runtime where console output is purely for debugging.
fn consoleLogStdout(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    writeArgs(ctx_opt, argv, std.fs.File.stderr());
    return Value.undefined;
}

/// console.warn / console.error — writes to stderr.
fn consoleLogStderr(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    writeArgs(ctx_opt, argv, std.fs.File.stderr());
    return Value.undefined;
}

/// Shared helper: iterate args, convert to string, write space-separated with trailing newline.
fn writeArgs(ctx_opt: ?*Context, argv: []const c.JSValue, file: std.fs.File) void {
    const ctx = ctx_opt orelse return;

    for (argv, 0..) |raw_arg, i| {
        if (i > 0) file.writeAll(" ") catch {};

        const arg: Value = @bitCast(raw_arg);

        // JS_ToCString handles all types (numbers, booleans, null, undefined, objects).
        const str_ptr = arg.toCString(ctx);
        if (str_ptr) |ptr| {
            const span = std.mem.span(ptr);
            file.writeAll(span) catch {};
            ctx.freeCString(ptr);
        } else {
            file.writeAll("[object]") catch {};
        }
    }
    file.writeAll("\n") catch {};
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

test "console.warn evaluates without exception" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("console.warn('warning message'); 'ok'", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("ok", str);
}

test "console.error evaluates without exception" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("console.error('error message'); 'ok'", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("ok", str);
}

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
