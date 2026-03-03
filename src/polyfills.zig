const std = @import("std");
const quickjs = @import("quickjs");

pub const console_polyfill = @import("polyfills/console.zig");
pub const performance_polyfill = @import("polyfills/performance.zig");
pub const encoding = @import("polyfills/encoding.zig");

/// Registers all native polyfills (console, performance, TextEncoder/TextDecoder)
/// into the given QuickJS context's globalThis.
pub fn registerAll(ctx: *quickjs.Context) !void {
    try console_polyfill.register(ctx);
    try performance_polyfill.register(ctx);
    try encoding.register(ctx);
}

test {
    std.testing.refAllDecls(@This());
}

// =============================================================================
// Integration test — all polyfills registered together
// =============================================================================

const JsEngine = @import("js_engine.zig").JsEngine;

test "registerAll installs console, performance, and encoding" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try registerAll(engine.context);

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
}
