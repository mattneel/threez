const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Registers `TextEncoder` and `TextDecoder` constructor functions on globalThis.
pub fn register(ctx: *Context) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    // --- TextEncoder ---
    // Create a constructor function. When called with `new`, it returns an
    // object with an `encode` method.
    const encoder_ctor = Value.initCFunction2(
        ctx,
        &textEncoderConstructor,
        "TextEncoder",
        0,
        .constructor_or_func,
        0,
    );
    global.setPropertyStr(ctx, "TextEncoder", encoder_ctor) catch return error.JSError;

    // --- TextDecoder ---
    const decoder_ctor = Value.initCFunction2(
        ctx,
        &textDecoderConstructor,
        "TextDecoder",
        0,
        .constructor_or_func,
        0,
    );
    global.setPropertyStr(ctx, "TextDecoder", decoder_ctor) catch return error.JSError;
}

/// `new TextEncoder()` constructor.
///
/// Returns an object with an `encode(string)` method and an `encoding` property.
fn textEncoderConstructor(
    ctx_opt: ?*Context,
    _: Value,
    _: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    const obj = Value.initObject(ctx);

    // encoding property (always "utf-8")
    obj.setPropertyStr(ctx, "encoding", Value.initString(ctx, "utf-8")) catch return Value.exception;

    // encode method
    const encode_fn = Value.initCFunction(ctx, &textEncoderEncode, "encode", 1);
    obj.setPropertyStr(ctx, "encode", encode_fn) catch return Value.exception;

    return obj;
}

/// `TextEncoder.prototype.encode(string)` — returns a Uint8Array of UTF-8 bytes.
fn textEncoderEncode(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) {
        return Value.initUint8ArrayCopy(ctx, "");
    }

    const arg: Value = @bitCast(argv[0]);
    const str_result = arg.toCStringLen(ctx);

    if (str_result) |info| {
        const slice = info.ptr[0..info.len];
        const result = Value.initUint8ArrayCopy(ctx, slice);
        ctx.freeCString(info.ptr);
        return result;
    } else {
        // If conversion fails, return an empty Uint8Array.
        return Value.initUint8ArrayCopy(ctx, "");
    }
}

/// `new TextDecoder()` constructor.
///
/// Returns an object with a `decode(bufferSource)` method and an `encoding` property.
fn textDecoderConstructor(
    ctx_opt: ?*Context,
    _: Value,
    _: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    const obj = Value.initObject(ctx);

    // encoding property (always "utf-8")
    obj.setPropertyStr(ctx, "encoding", Value.initString(ctx, "utf-8")) catch return Value.exception;

    // decode method
    const decode_fn = Value.initCFunction(ctx, &textDecoderDecode, "decode", 1);
    obj.setPropertyStr(ctx, "decode", decode_fn) catch return Value.exception;

    return obj;
}

/// `TextDecoder.prototype.decode(bufferSource)` — returns a JS string from the bytes.
///
/// Accepts Uint8Array, ArrayBuffer, or any typed array.
fn textDecoderDecode(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) {
        return Value.initStringLen(ctx, "");
    }

    const arg: Value = @bitCast(argv[0]);

    // Try Uint8Array first (most common case).
    if (arg.getUint8Array(ctx)) |buf| {
        return Value.initStringLen(ctx, buf);
    }

    // Try raw ArrayBuffer.
    if (arg.getArrayBuffer(ctx)) |buf| {
        return Value.initStringLen(ctx, buf);
    }

    // Try generic typed array — get the underlying ArrayBuffer and use byte range.
    if (arg.getTypedArrayBuffer(ctx)) |info| {
        defer info.value.deinit(ctx);
        if (info.value.getArrayBuffer(ctx)) |full_buf| {
            const slice = full_buf[info.byte_offset..][0..info.byte_length];
            return Value.initStringLen(ctx, slice);
        }
    }

    // If nothing matched, return empty string.
    return Value.initStringLen(ctx, "");
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;

test "TextEncoder.encode('hello') has length 5" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextEncoder().encode('hello').length", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 5), try result.toInt32());
}

test "TextEncoder.encode returns Uint8Array" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextEncoder().encode('hi') instanceof Uint8Array", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "TextEncoder.encode has correct byte values" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\var e = new TextEncoder().encode('AB');
        \\e[0] === 65 && e[1] === 66
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "TextDecoder.decode round-trips with TextEncoder" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\var enc = new TextEncoder();
        \\var dec = new TextDecoder();
        \\dec.decode(enc.encode('hello world'))
    , "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("hello world", str);
}

test "TextDecoder.decode with ArrayBuffer" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\var buf = new Uint8Array([72, 105]).buffer;
        \\new TextDecoder().decode(buf)
    , "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("Hi", str);
}

test "TextEncoder.encoding is 'utf-8'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextEncoder().encoding", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("utf-8", str);
}

test "TextDecoder.encoding is 'utf-8'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextDecoder().encoding", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("utf-8", str);
}

test "TextEncoder.encode with empty string" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextEncoder().encode('').length", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 0), try result.toInt32());
}

test "TextDecoder.decode with no argument returns empty string" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval("new TextDecoder().decode()", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("", str);
}
