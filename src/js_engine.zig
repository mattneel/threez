const std = @import("std");
const quickjs = @import("quickjs");

const log = std.log.scoped(.js);

/// A high-level wrapper around the QuickJS-NG JavaScript engine.
///
/// Manages a QuickJS Runtime and Context pair, providing a simple
/// interface for evaluating JavaScript code from Zig.
pub const JsEngine = struct {
    allocator: std.mem.Allocator,
    runtime: *quickjs.Runtime,
    context: *quickjs.Context,

    /// Initializes a new JavaScript engine with a fresh runtime and context.
    pub fn init(allocator: std.mem.Allocator) !JsEngine {
        const runtime: *quickjs.Runtime = try .init();
        errdefer runtime.deinit();

        // Three.js TSL's node system creates deep recursion chains during
        // shader compilation. The default QuickJS stack limit (256KB) is
        // too small; increase to 8MB to match typical browser limits.
        runtime.setMaxStackSize(8 * 1024 * 1024);

        const context: *quickjs.Context = try .init(runtime);
        errdefer context.deinit();

        return .{
            .allocator = allocator,
            .runtime = runtime,
            .context = context,
        };
    }

    /// Tears down the JavaScript engine, freeing the context and runtime.
    pub fn deinit(self: *JsEngine) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    /// Evaluates a JavaScript expression and returns the result.
    ///
    /// The caller must call `deinit` on the returned `EvalResult` when done.
    pub fn eval(self: *JsEngine, source: []const u8, filename: [:0]const u8) !EvalResult {
        const value = self.context.eval(source, filename, .{});
        if (value.isException()) {
            const exc = self.context.getException();
            if (exc.toCString(self.context)) |msg| {
                log.info("{s}", .{std.mem.span(msg)});
                self.context.freeCString(msg);
            }
            exc.deinit(self.context);
            return error.JSException;
        }
        return .{
            .value = value,
            .ctx = self.context,
        };
    }

    /// Evaluates JavaScript source as an ES module.
    ///
    /// The caller must call `deinit` on the returned `EvalResult` when done.
    pub fn evalModule(self: *JsEngine, source: []const u8, filename: [:0]const u8) !EvalResult {
        const value = self.context.eval(source, filename, .{ .type = .module });
        if (value.isException()) {
            const exc = self.context.getException();
            if (exc.toCString(self.context)) |msg| {
                log.info("{s}", .{std.mem.span(msg)});
                self.context.freeCString(msg);
            }
            exc.deinit(self.context);
            return error.JSException;
        }
        return .{
            .value = value,
            .ctx = self.context,
        };
    }

    /// Returns the global object for this engine's context.
    ///
    /// The caller must call `deinit` on the returned `EvalResult` when done.
    pub fn getGlobal(self: *JsEngine) EvalResult {
        return .{
            .value = self.context.getGlobalObject(),
            .ctx = self.context,
        };
    }
};

/// The result of a JavaScript evaluation.
///
/// Wraps a QuickJS `Value` together with the context it belongs to,
/// providing convenient accessors for extracting Zig types and ensuring
/// proper cleanup via `deinit`.
pub const EvalResult = struct {
    value: quickjs.Value,
    ctx: *quickjs.Context,

    /// Frees the underlying JavaScript value.
    pub fn deinit(self: *EvalResult) void {
        self.value.deinit(self.ctx);
    }

    /// Extracts the result as a 32-bit integer.
    pub fn toInt32(self: *const EvalResult) !i32 {
        return self.value.toInt32(self.ctx);
    }

    /// Extracts the result as a 64-bit float.
    pub fn toFloat64(self: *const EvalResult) !f64 {
        return self.value.toFloat64(self.ctx);
    }

    /// Extracts the result as a C string.
    ///
    /// Returns a sentinel-terminated pointer owned by QuickJS.
    /// The caller must free it with `freeCString` when done, or
    /// use `toSlice` for a more ergonomic Zig slice.
    pub fn toCString(self: *const EvalResult) ![:0]const u8 {
        const ptr = self.value.toCString(self.ctx) orelse return error.JSError;
        return std.mem.span(ptr);
    }

    /// Frees a C string previously obtained from `toCString`.
    pub fn freeCString(self: *const EvalResult, str: [:0]const u8) void {
        self.ctx.freeCString(str.ptr);
    }

    /// Returns true if this result represents a JavaScript exception.
    pub fn isException(self: *const EvalResult) bool {
        return self.value.isException();
    }

    /// Returns true if this result is a JavaScript object.
    pub fn isObject(self: *const EvalResult) bool {
        return self.value.isObject();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "eval arithmetic: 1 + 1 == 2" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.eval("1 + 1", "<test>");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), try result.toInt32());
}

test "eval string: 'hello ' + 'world' == 'hello world'" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.eval("'hello ' + 'world'", "<test>");
    defer result.deinit();

    const str = try result.toCString();
    defer result.freeCString(str);
    try std.testing.expectEqualStrings("hello world", str);
}

test "eval module: export const x = 42 (no error)" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.evalModule("export const x = 42;", "<test>");
    defer result.deinit();
}

test "exception handling: eval invalid syntax returns error" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    const result = engine.eval("}{invalid", "<test>");
    try std.testing.expectError(error.JSException, result);
}

test "getGlobal returns an object" {
    var engine = try JsEngine.init(std.testing.allocator);
    defer engine.deinit();

    var global = engine.getGlobal();
    defer global.deinit();

    try std.testing.expect(global.isObject());
}
