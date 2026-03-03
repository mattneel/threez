const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Registers native helper functions for the fetch() polyfill on globalThis.
///
/// - `__native_readFileSync(path: string) → Uint8Array | null`
/// - `__native_decodeBase64(data: string) → Uint8Array | null`
///
/// The actual `fetch()` API is implemented in JavaScript (bootstrap/fetch.ts)
/// and calls these native functions for I/O.
pub fn register(ctx: *Context) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const read_fn = Value.initCFunction(ctx, &nativeReadFileSync, "__native_readFileSync", 1);
    global.setPropertyStr(ctx, "__native_readFileSync", read_fn) catch return error.JSError;

    const b64_fn = Value.initCFunction(ctx, &nativeDecodeBase64, "__native_decodeBase64", 1);
    global.setPropertyStr(ctx, "__native_decodeBase64", b64_fn) catch return error.JSError;
}

/// `__native_readFileSync(path)` — reads a file from the local filesystem.
///
/// Returns a Uint8Array with the file contents, or null if the file
/// cannot be opened (e.g. not found, permission denied).
fn nativeReadFileSync(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) return Value.@"null";

    const arg: Value = @bitCast(argv[0]);
    const str_result = arg.toCStringLen(ctx) orelse return Value.@"null";
    const path_slice = str_result.ptr[0..str_result.len];
    defer ctx.freeCString(str_result.ptr);

    // Open the file, returning null on failure (not found, etc.)
    const file = std.fs.cwd().openFile(path_slice, .{}) catch return Value.@"null";
    defer file.close();

    // Read entire contents. Use a generous max size (64 MiB).
    const max_size = 64 * 1024 * 1024;
    const contents = file.readToEndAlloc(std.heap.page_allocator, max_size) catch return Value.@"null";
    defer std.heap.page_allocator.free(contents);

    // Copy into a JS Uint8Array
    return Value.initUint8ArrayCopy(ctx, contents);
}

/// `__native_decodeBase64(data)` — decodes a base64-encoded string.
///
/// Returns a Uint8Array with the decoded bytes, or null on invalid input.
fn nativeDecodeBase64(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) return Value.@"null";

    const arg: Value = @bitCast(argv[0]);
    const str_result = arg.toCStringLen(ctx) orelse return Value.@"null";
    const b64_slice = str_result.ptr[0..str_result.len];
    defer ctx.freeCString(str_result.ptr);

    // Calculate decoded size and decode
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_slice) catch return Value.@"null";
    const decoded = std.heap.page_allocator.alloc(u8, decoded_size) catch return Value.@"null";
    defer std.heap.page_allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, b64_slice) catch return Value.@"null";

    return Value.initUint8ArrayCopy(ctx, decoded);
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;
const encoding = @import("encoding.zig");

test "__native_readFileSync reads a temp file" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    // Create a temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "test_fetch.txt",
        .data = "hello from fetch",
    });

    // Get the absolute path to the temp file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp_dir.dir.realpath("test_fetch.txt", &path_buf);

    // Set the path as a JS global variable, then run the test code.
    const global = engine.context.getGlobalObject();
    defer global.deinit(engine.context);

    const path_val = Value.initStringLen(engine.context, abs_path);
    global.setPropertyStr(engine.context, "__test_path", path_val) catch return error.JSError;

    var result = try engine.eval(
        \\(function() {
        \\  var result = __native_readFileSync(__test_path);
        \\  if (result === null) return "null";
        \\  var str = "";
        \\  for (var i = 0; i < result.length; i++) {
        \\    str += String.fromCharCode(result[i]);
        \\  }
        \\  return str;
        \\})()
    , "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("hello from fetch", str);
}

test "__native_readFileSync returns null for missing file" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_readFileSync("/nonexistent/path/file.txt") === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_decodeBase64 decodes valid base64" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);
    try encoding.register(engine.context);

    var result = try engine.eval(
        \\(function() {
        \\  var bytes = __native_decodeBase64("SGVsbG8=");
        \\  if (bytes === null) return "null";
        \\  var str = "";
        \\  for (var i = 0; i < bytes.length; i++) {
        \\    str += String.fromCharCode(bytes[i]);
        \\  }
        \\  return str;
        \\})()
    , "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("Hello", str);
}

test "__native_decodeBase64 returns null for invalid base64" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_decodeBase64("!!!invalid!!!") === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_readFileSync with no args returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_readFileSync() === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}
