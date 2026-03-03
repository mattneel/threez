const std = @import("std");
const JsEngine = @import("js_engine.zig").JsEngine;

/// The compiled bootstrap JavaScript, bundled from TypeScript sources.
/// This file is committed to the repository so that @embedFile works
/// without requiring npm at Zig build time.
const bootstrap_js = @embedFile("ts/dist/bootstrap.js");

/// Initializes the browser API polyfills in the given JavaScript engine.
///
/// Evaluates the bootstrap script which sets up window, document,
/// navigator, Event constructors, and other DOM stubs that Three.js
/// expects. Must be called before loading any user JavaScript.
pub fn init(engine: *JsEngine) !void {
    var result = try engine.eval(bootstrap_js, "<bootstrap>");
    defer result.deinit();
}

// =============================================================================
// Tests
// =============================================================================

test "bootstrap: typeof window === 'object'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof window", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("object", str);
}

test "bootstrap: typeof document === 'object'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof document", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("object", str);
}

test "bootstrap: typeof Event === 'function'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof Event", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("function", str);
}

test "bootstrap: typeof EventTarget === 'function'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof EventTarget", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("function", str);
}

test "bootstrap: typeof PointerEvent === 'function'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof PointerEvent", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("function", str);
}

test "bootstrap: window.innerWidth === 800" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("window.innerWidth", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 800), try result.toInt32());
}

test "bootstrap: document.createElement('canvas') returns canvas stub" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval(
        "typeof document.createElement('canvas').getBoundingClientRect",
        "<test>",
    );
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("function", str);
}

test "bootstrap: canvas.getBoundingClientRect() returns correct shape" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval(
        \\(function() {
        \\  var c = document.createElement('canvas');
        \\  var r = c.getBoundingClientRect();
        \\  return r.left === 0 && r.top === 0 && r.width === 800 && r.height === 600;
        \\})()
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "bootstrap: navigator.gpu exists" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("typeof navigator.gpu", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("object", str);
}

test "bootstrap: self === window" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try init(&engine);

    var result = try engine.eval("self === window", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}
