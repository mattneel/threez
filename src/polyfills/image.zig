const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;
const zignal = @import("zignal");

/// Registers the native image decode function on globalThis.
///
/// - `__native_decodeImage(data: Uint8Array) → { width, height, data: Uint8Array } | null`
///
/// Decodes PNG or JPEG image bytes to RGBA pixels using zignal.
/// Returns null if decoding fails.
pub fn register(ctx: *Context) !void {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const decode_fn = Value.initCFunction(ctx, &nativeDecodeImage, "__native_decodeImage", 1);
    global.setPropertyStr(ctx, "__native_decodeImage", decode_fn) catch return error.JSError;
}

/// `__native_decodeImage(data)` — decodes PNG/JPEG image bytes to RGBA.
///
/// Takes a Uint8Array of raw image bytes (PNG or JPEG).
/// Returns a JS object `{ width: number, height: number, data: Uint8Array }` with RGBA pixels,
/// or null on decode failure.
fn nativeDecodeImage(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.exception;

    if (argv.len < 1) return Value.@"null";

    const arg: Value = @bitCast(argv[0]);
    const input_data = arg.getUint8Array(ctx) orelse return Value.@"null";

    if (input_data.len < 2) return Value.@"null";

    return decodeImageData(ctx, input_data) orelse Value.@"null";
}

/// Detect format and decode image data to RGBA, returning a JS result object.
fn decodeImageData(ctx: *Context, data: []const u8) ?Value {
    const format = zignal.ImageFormat.detectFromBytes(data) orelse return null;

    return switch (format) {
        .png => decodePng(ctx, data),
        .jpeg => decodeJpeg(ctx, data),
    };
}

/// Decode PNG from in-memory bytes.
fn decodePng(ctx: *Context, data: []const u8) ?Value {
    const Rgba = zignal.Rgba;
    const allocator = std.heap.page_allocator;

    // Decode PNG data in-memory
    var png_image = zignal.png.decode(allocator, data) catch return null;
    defer png_image.deinit(allocator);

    // Convert to native image (grayscale, rgb, or rgba)
    var native_image = zignal.png.toNativeImage(allocator, png_image) catch return null;

    // Convert any format to RGBA and produce the result
    switch (native_image) {
        .grayscale => |*img| {
            defer img.deinit(allocator);
            var rgba_img = img.convert(Rgba, allocator) catch return null;
            defer rgba_img.deinit(allocator);
            return buildResultObject(ctx, rgba_img.cols, rgba_img.rows, rgba_img.asBytes());
        },
        .rgb => |*img| {
            defer img.deinit(allocator);
            var rgba_img = img.convert(Rgba, allocator) catch return null;
            defer rgba_img.deinit(allocator);
            return buildResultObject(ctx, rgba_img.cols, rgba_img.rows, rgba_img.asBytes());
        },
        .rgba => |*img| {
            defer img.deinit(allocator);
            return buildResultObject(ctx, img.cols, img.rows, img.asBytes());
        },
    }
}

/// Decode JPEG from in-memory bytes.
///
/// The zignal JPEG decoder's baseline block scan function is not publicly exported,
/// so we write the bytes to a temporary file and use the file-based loader.
fn decodeJpeg(ctx: *Context, data: []const u8) ?Value {
    const Rgba = zignal.Rgba;
    const allocator = std.heap.page_allocator;

    // Write data to a temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    tmp_dir.dir.writeFile(.{
        .sub_path = "decode.jpg",
        .data = data,
    }) catch return null;

    // Get absolute path to the temp file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("decode.jpg", &path_buf) catch return null;

    // Load as Image(Rgba) via zignal's file-based JPEG loader
    var img = zignal.Image(Rgba).load(allocator, abs_path) catch return null;
    defer img.deinit(allocator);

    return buildResultObject(ctx, img.cols, img.rows, img.asBytes());
}

/// Build a JS object `{ width, height, data }` from decoded RGBA pixels.
fn buildResultObject(ctx: *Context, width: usize, height: usize, rgba_bytes: []const u8) ?Value {
    const obj = Value.initObject(ctx);

    // Set width property
    const w_val = Value.initInt32(@intCast(width));
    obj.setPropertyStr(ctx, "width", w_val) catch return null;

    // Set height property
    const h_val = Value.initInt32(@intCast(height));
    obj.setPropertyStr(ctx, "height", h_val) catch return null;

    // Set data property (copy RGBA bytes into a Uint8Array)
    const data_val = Value.initUint8ArrayCopy(ctx, rgba_bytes);
    obj.setPropertyStr(ctx, "data", data_val) catch return null;

    return obj;
}

// =============================================================================
// Tests
// =============================================================================

const JsEngine = @import("../js_engine.zig").JsEngine;

test "__native_decodeImage is registered as a function" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\typeof __native_decodeImage === 'function'
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_decodeImage with no args returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_decodeImage() === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_decodeImage with invalid data returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_decodeImage(new Uint8Array([0, 1, 2, 3])) === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_decodeImage with empty data returns null" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    var result = try engine.eval(
        \\__native_decodeImage(new Uint8Array([])) === null
    , "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "__native_decodeImage decodes a minimal 1x1 red PNG" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    try register(engine.context);

    // Generate a minimal 1x1 red RGBA PNG in-memory using zignal
    const Rgba = zignal.Rgba;
    const allocator = std.testing.allocator;

    var img = try zignal.Image(Rgba).init(allocator, 1, 1);
    defer img.deinit(allocator);
    img.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };

    const png_data = try zignal.png.encodeImage(Rgba, allocator, img, .{ .filter_mode = .none });
    defer allocator.free(png_data);

    // Set the PNG data as a global Uint8Array
    const global = engine.context.getGlobalObject();
    defer global.deinit(engine.context);

    const js_data = Value.initUint8ArrayCopy(engine.context, png_data);
    global.setPropertyStr(engine.context, "__test_png", js_data) catch return error.JSError;

    // Decode and verify the result
    var result = try engine.eval(
        \\(function() {
        \\  var r = __native_decodeImage(__test_png);
        \\  if (r === null) return 'null';
        \\  if (r.width !== 1) return 'bad width: ' + r.width;
        \\  if (r.height !== 1) return 'bad height: ' + r.height;
        \\  if (r.data.length !== 4) return 'bad data length: ' + r.data.length;
        \\  if (r.data[0] !== 255) return 'bad R: ' + r.data[0];
        \\  if (r.data[1] !== 0) return 'bad G: ' + r.data[1];
        \\  if (r.data[2] !== 0) return 'bad B: ' + r.data[2];
        \\  if (r.data[3] !== 255) return 'bad A: ' + r.data[3];
        \\  return 'ok';
        \\})()
    , "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("ok", str);
}
