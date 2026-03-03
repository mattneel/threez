const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

/// Registers native helper functions for the fetch() polyfill on globalThis.
///
/// - `__native_readFileSync(path: string) → Uint8Array | null`
/// - `__native_decodeBase64(data: string) → Uint8Array | null`
/// - `__native_httpFetch(url: string) → { status, statusText, contentType, body } | null`
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

    const http_fn = Value.initCFunction(ctx, &nativeHttpFetch, "__native_httpFetch", 1);
    global.setPropertyStr(ctx, "__native_httpFetch", http_fn) catch return error.JSError;
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

/// `__native_httpFetch(url)` — performs an HTTP/HTTPS GET request.
///
/// Returns a JS object `{ status: number, statusText: string, contentType: string, body: Uint8Array }`
/// on success, or null on error (invalid URL, connection failure, etc.).
fn nativeHttpFetch(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) return Value.@"null";

    const arg: Value = @bitCast(argv[0]);
    const str_result = arg.toCStringLen(ctx) orelse return Value.@"null";
    const url_slice = str_result.ptr[0..str_result.len];
    defer ctx.freeCString(str_result.ptr);

    return httpFetchInner(ctx, url_slice) catch return Value.@"null";
}

/// Inner implementation of HTTP fetch, separated so we can use Zig error handling.
fn httpFetchInner(ctx: *Context, url: []const u8) !Value {
    const allocator = std.heap.page_allocator;

    const uri = std.Uri.parse(url) catch return Value.@"null";

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Create a GET request
    var req = client.request(.GET, uri, .{
        .keep_alive = false,
    }) catch return Value.@"null";
    defer req.deinit();

    // Send the request (no body for GET)
    req.sendBodiless() catch return Value.@"null";

    // Receive the response head
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return Value.@"null";

    // Extract status info before reading body (head strings are invalidated by reader())
    const status_code: i32 = @intCast(@intFromEnum(response.head.status));
    const status_phrase = response.head.status.phrase() orelse "Unknown";
    const content_type = response.head.content_type orelse "application/octet-stream";

    // We need to copy these strings before calling response.reader() which invalidates them
    const status_text_copy = allocator.dupe(u8, status_phrase) catch return Value.@"null";
    defer allocator.free(status_text_copy);

    const content_type_copy = allocator.dupe(u8, content_type) catch return Value.@"null";
    defer allocator.free(content_type_copy);

    // Read the response body
    const max_body_size = 64 * 1024 * 1024; // 64 MiB
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    const body = body_reader.allocRemaining(allocator, .limited(max_body_size)) catch return Value.@"null";
    defer allocator.free(body);

    // Build the JS result object: { status, statusText, contentType, body }
    const result = Value.initObject(ctx);

    result.setPropertyStr(ctx, "status", Value.initInt32(status_code)) catch return Value.@"null";
    result.setPropertyStr(ctx, "statusText", Value.initStringLen(ctx, status_text_copy)) catch return Value.@"null";
    result.setPropertyStr(ctx, "contentType", Value.initStringLen(ctx, content_type_copy)) catch return Value.@"null";
    result.setPropertyStr(ctx, "body", Value.initUint8ArrayCopy(ctx, body)) catch return Value.@"null";

    return result;
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

test "__native_httpFetch is registered as a function" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\typeof __native_httpFetch === "function"
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_httpFetch with no args returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_httpFetch() === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_httpFetch with invalid URL returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_httpFetch("not-a-valid-url") === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

// NOTE: Skipped unreachable-host test — TCP connect to non-routable IPs
// blocks for the OS timeout (minutes), deadlocking the test runner.
