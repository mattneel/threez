const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Nanosecond timestamp captured at registration time.
/// `performance.now()` returns `(current_ns - start_ns) / 1_000_000.0`.
var start_ns: i128 = 0;

/// Registers a `performance` object on globalThis with a `now()` method.
pub fn register(ctx: *Context) !void {
    start_ns = std.time.nanoTimestamp();

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const perf_obj = Value.initObject(ctx);

    const now_fn = Value.initCFunction(ctx, &performanceNow, "now", 0);
    perf_obj.setPropertyStr(ctx, "now", now_fn) catch return error.JSError;

    global.setPropertyStr(ctx, "performance", perf_obj) catch return error.JSError;
}

/// Returns milliseconds (f64) since `register` was called, with sub-ms precision.
fn performanceNow(
    _: ?*Context,
    _: Value,
    _: []const c.JSValue,
) Value {
    const now = std.time.nanoTimestamp();
    const elapsed_ns: f64 = @floatFromInt(now - start_ns);
    const elapsed_ms = elapsed_ns / 1_000_000.0;
    return Value.initFloat64(elapsed_ms);
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;

test "performance.now returns a number > 0" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("performance.now()", "<test>");
    defer result.deinit();

    const ms = try result.toFloat64();
    try std.testing.expect(ms >= 0.0);
}

test "performance.now increases over time" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var r1 = try engine.eval("performance.now()", "<test>");
    defer r1.deinit();
    const t1 = try r1.toFloat64();

    // Do a bit of work to burn some nanoseconds.
    var r2 = try engine.eval(
        \\var x = 0; for (var i = 0; i < 1000; i++) x += i;
        \\performance.now()
    , "<test>");
    defer r2.deinit();
    const t2 = try r2.toFloat64();

    try std.testing.expect(t2 >= t1);
}

test "performance.now returns a finite number" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("Number.isFinite(performance.now())", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}
