const std = @import("std");
const quickjs = @import("quickjs");

pub const console_polyfill = @import("polyfills/console.zig");
pub const performance_polyfill = @import("polyfills/performance.zig");
pub const encoding = @import("polyfills/encoding.zig");
pub const fetch = @import("polyfills/fetch.zig");
pub const timers = @import("polyfills/timers.zig");

/// Registers all native polyfills (console, performance, TextEncoder/TextDecoder,
/// fetch helpers, setTimeout/setInterval/clearTimeout/clearInterval) into the
/// given QuickJS context's globalThis.
pub fn registerAll(ctx: *quickjs.Context, timer_queue: *timers.TimerQueue) !void {
    try console_polyfill.register(ctx);
    try performance_polyfill.register(ctx);
    try encoding.register(ctx);
    try fetch.register(ctx);
    try timers.register(ctx, timer_queue);
}

test {
    std.testing.refAllDecls(@This());
}

// =============================================================================
// Integration test — all polyfills registered together
// =============================================================================

const JsEngine = @import("js_engine.zig").JsEngine;

test "registerAll installs console, performance, encoding, and timers" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();
    var queue = timers.TimerQueue.init(std.testing.allocator);
    defer queue.deinit(engine.context);

    try registerAll(engine.context, &queue);

    // console
    var r1 = try engine.eval("typeof console.log", "<test>");
    defer r1.deinit();
    const s1 = try r1.toCString();
    defer r1.freeCString(s1);
    try std.testing.expectEqualStrings("function", s1);

    // performance
    var r2 = try engine.eval("typeof performance.now", "<test>");
    defer r2.deinit();
    const s2 = try r2.toCString();
    defer r2.freeCString(s2);
    try std.testing.expectEqualStrings("function", s2);

    // TextEncoder
    var r3 = try engine.eval("typeof TextEncoder", "<test>");
    defer r3.deinit();
    const s3 = try r3.toCString();
    defer r3.freeCString(s3);
    try std.testing.expectEqualStrings("function", s3);

    // TextDecoder
    var r4 = try engine.eval("typeof TextDecoder", "<test>");
    defer r4.deinit();
    const s4 = try r4.toCString();
    defer r4.freeCString(s4);
    try std.testing.expectEqualStrings("function", s4);

    // setTimeout
    var r5 = try engine.eval("typeof setTimeout", "<test>");
    defer r5.deinit();
    const s5 = try r5.toCString();
    defer r5.freeCString(s5);
    try std.testing.expectEqualStrings("function", s5);

    // setInterval
    var r6 = try engine.eval("typeof setInterval", "<test>");
    defer r6.deinit();
    const s6 = try r6.toCString();
    defer r6.freeCString(s6);
    try std.testing.expectEqualStrings("function", s6);

    // __native_readFileSync
    var r7 = try engine.eval("typeof __native_readFileSync", "<test>");
    defer r7.deinit();
    const s7 = try r7.toCString();
    defer r7.freeCString(s7);
    try std.testing.expectEqualStrings("function", s7);

    // __native_decodeBase64
    var r8 = try engine.eval("typeof __native_decodeBase64", "<test>");
    defer r8.deinit();
    const s8 = try r8.toCString();
    defer r8.freeCString(s8);
    try std.testing.expectEqualStrings("function", s8);
}
