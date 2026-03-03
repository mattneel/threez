const std = @import("std");
const quickjs = @import("quickjs");

/// Errors that can occur during descriptor translation.
pub const DescriptorError = error{
    MissingRequiredField,
    TypeMismatch,
    InvalidEnum,
    InvalidHandle,
    JsException,
};

/// Translate a JS object's properties into a Zig struct using comptime reflection.
///
/// For each field in `T`, reads the matching property name from the JS object.
/// Undefined JS properties keep their zero-initialized default (matching WebGPU's
/// convention where most descriptor fields default to 0/null/false).
///
/// String fields (`[*:0]const u8`) are backed by QuickJS-managed memory and
/// remain valid only while the JS context is alive. The caller does NOT need
/// to free them individually -- they are collected when the context is torn down.
///
/// Nested struct fields are handled recursively.
pub fn translateDescriptor(
    comptime T: type,
    ctx: *quickjs.Context,
    js_obj: quickjs.Value,
) DescriptorError!T {
    var result: T = std.mem.zeroes(T);

    inline for (std.meta.fields(T)) |field| {
        const js_val = js_obj.getPropertyStr(ctx, field.name ++ "");
        defer js_val.deinit(ctx);

        if (!js_val.isUndefined()) {
            @field(result, field.name) = try convertValue(field.type, ctx, js_val);
        }
        // If undefined, the field keeps its zero value from std.mem.zeroes.
    }

    return result;
}

/// Convert a single JS value to the corresponding Zig type.
///
/// Supported type mappings:
///   - Signed/unsigned integers: JS number -> Zig int via toInt32/toUint32
///   - Floats: JS number -> Zig float via toFloat64
///   - Booleans: JS boolean -> Zig bool via toBool
///   - Enums: JS number -> Zig enum via @enumFromInt
///   - Optionals: JS null/undefined -> null, otherwise recurse into child type
///   - Sentinel-terminated u8 pointers: JS string -> [*:0]const u8 via toCString
///   - Structs: JS object -> recursive translateDescriptor
fn convertValue(comptime T: type, ctx: *quickjs.Context, val: quickjs.Value) DescriptorError!T {
    const info = @typeInfo(T);

    return switch (info) {
        .int => |int_info| blk: {
            if (int_info.bits <= 32) {
                if (int_info.signedness == .signed) {
                    const v = val.toInt32(ctx) catch return error.TypeMismatch;
                    break :blk @intCast(v);
                } else {
                    const v = val.toUint32(ctx) catch return error.TypeMismatch;
                    break :blk @intCast(v);
                }
            } else {
                // For larger integers (u64, i64, etc.), go through float64.
                const f = val.toFloat64(ctx) catch return error.TypeMismatch;
                break :blk @intFromFloat(f);
            }
        },
        .float => blk: {
            const f = val.toFloat64(ctx) catch return error.TypeMismatch;
            break :blk @floatCast(f);
        },
        .bool => val.toBool(ctx) catch return error.TypeMismatch,
        .@"enum" => |enum_info| blk: {
            // WebGPU enums are integer-valued in JS.
            const IntType = enum_info.tag_type;
            const int_info = @typeInfo(IntType).int;
            const raw: IntType = if (int_info.bits <= 32) r: {
                if (int_info.signedness == .signed) {
                    const v = val.toInt32(ctx) catch return error.TypeMismatch;
                    break :r @intCast(v);
                } else {
                    const v = val.toUint32(ctx) catch return error.TypeMismatch;
                    break :r @intCast(v);
                }
            } else r: {
                const f = val.toFloat64(ctx) catch return error.TypeMismatch;
                break :r @intFromFloat(f);
            };
            break :blk @enumFromInt(raw);
        },
        .optional => |opt| {
            if (val.isNull() or val.isUndefined()) return null;
            return try convertValue(opt.child, ctx, val);
        },
        .pointer => |ptr| {
            if (ptr.size == .many and ptr.sentinel_ptr != null and ptr.child == u8) {
                // [*:0]const u8 -- null-terminated string from QuickJS.
                // The returned pointer is owned by QuickJS and valid until
                // the context is freed or the string is explicitly freed.
                return val.toCString(ctx) orelse return error.TypeMismatch;
            }
            // Other pointer types are not yet supported.
            return error.TypeMismatch;
        },
        .@"struct" => {
            // Nested struct: recursively translate.
            return try translateDescriptor(T, ctx, val);
        },
        else => return error.TypeMismatch,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Helper: create a QJS runtime + context, evaluate a JS expression, and
/// return the resulting Value. The runtime and context are returned so the
/// caller can clean them up.
fn testEval(source: []const u8) struct { val: quickjs.Value, ctx: *quickjs.Context, rt: *quickjs.Runtime } {
    const rt = quickjs.Runtime.init() catch @panic("failed to create runtime");
    const ctx = quickjs.Context.init(rt) catch @panic("failed to create context");
    const val = ctx.eval(source, "<test>", .{});
    if (val.isException()) {
        const exc = ctx.getException();
        exc.deinit(ctx);
        @panic("JS eval threw an exception");
    }
    return .{ .val = val, .ctx = ctx, .rt = rt };
}

fn testCleanup(state: anytype) void {
    var s = state;
    s.val.deinit(s.ctx);
    s.ctx.deinit();
    s.rt.deinit();
}

// ---- Test descriptor structs ----

const SimpleDesc = struct {
    size: u32 = 0,
    usage: u32 = 0,
    mapped_at_creation: bool = false,
};

const InnerDesc = struct {
    value: f32 = 0,
    count: u32 = 0,
};

const NestedDesc = struct {
    label: ?[*:0]const u8 = null,
    inner: InnerDesc = std.mem.zeroes(InnerDesc),
};

const Format = enum(u32) { rgba8 = 0, bgra8 = 1, depth24 = 2 };

const EnumDesc = struct {
    format: Format = .rgba8,
    width: u32 = 0,
};

// ---- Test cases ----

test "simple: size and usage" {
    const state = testEval("({size: 1024, usage: 5})");
    defer testCleanup(state);

    const desc = try translateDescriptor(SimpleDesc, state.ctx, state.val);
    try testing.expectEqual(@as(u32, 1024), desc.size);
    try testing.expectEqual(@as(u32, 5), desc.usage);
    try testing.expectEqual(false, desc.mapped_at_creation);
}

test "bool field: mapped_at_creation" {
    const state = testEval("({size: 64, mapped_at_creation: true})");
    defer testCleanup(state);

    const desc = try translateDescriptor(SimpleDesc, state.ctx, state.val);
    try testing.expectEqual(@as(u32, 64), desc.size);
    try testing.expectEqual(true, desc.mapped_at_creation);
}

test "missing fields get zero defaults" {
    const state = testEval("({size: 512})");
    defer testCleanup(state);

    const desc = try translateDescriptor(SimpleDesc, state.ctx, state.val);
    try testing.expectEqual(@as(u32, 512), desc.size);
    try testing.expectEqual(@as(u32, 0), desc.usage);
    try testing.expectEqual(false, desc.mapped_at_creation);
}

test "nested struct" {
    const state = testEval("({inner: {value: 3.14, count: 7}})");
    defer testCleanup(state);

    const desc = try translateDescriptor(NestedDesc, state.ctx, state.val);
    try testing.expectApproxEqAbs(@as(f32, 3.14), desc.inner.value, 0.001);
    try testing.expectEqual(@as(u32, 7), desc.inner.count);
    try testing.expectEqual(@as(?[*:0]const u8, null), desc.label);
}

test "enum field" {
    const state = testEval("({format: 1, width: 256})");
    defer testCleanup(state);

    const desc = try translateDescriptor(EnumDesc, state.ctx, state.val);
    try testing.expectEqual(Format.bgra8, desc.format);
    try testing.expectEqual(@as(u32, 256), desc.width);
}

test "null optional stays null" {
    const state = testEval("({label: null})");
    defer testCleanup(state);

    const desc = try translateDescriptor(NestedDesc, state.ctx, state.val);
    try testing.expectEqual(@as(?[*:0]const u8, null), desc.label);
}

test "empty object: all defaults" {
    const state = testEval("({})");
    defer testCleanup(state);

    const desc = try translateDescriptor(SimpleDesc, state.ctx, state.val);
    try testing.expectEqual(@as(u32, 0), desc.size);
    try testing.expectEqual(@as(u32, 0), desc.usage);
    try testing.expectEqual(false, desc.mapped_at_creation);
}
