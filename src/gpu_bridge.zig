const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

const handle_table = @import("handle_table.zig");
const HandleTable = handle_table.HandleTable;
const HandleId = handle_table.HandleId;

/// The GPU bridge connects JavaScript WebGPU API calls to the pre-created
/// zgpu/Dawn adapter, device, and queue.
///
/// Since zgpu's GraphicsContext creates everything at init time, the bridge
/// simply wraps the existing GPU objects as handle IDs and returns them
/// when JavaScript calls requestAdapter() / requestDevice() / getQueue().
pub const GpuBridge = struct {
    handle_table_ptr: *HandleTable,
    adapter_id: HandleId,
    device_id: HandleId,
    queue_id: HandleId,

    /// Initialize the bridge by allocating handle table entries for the
    /// pre-existing adapter, device, and queue.
    ///
    /// The DawnHandle payloads are void placeholders for now — T16+ will
    /// fill in real Dawn opaque pointers.
    pub fn init(ht: *HandleTable) !GpuBridge {
        const adapter_id = ht.alloc(.{ .adapter = {} }) catch return error.GpuBridgeInitFailed;
        errdefer ht.free(adapter_id) catch {};

        const device_id = ht.alloc(.{ .device = {} }) catch return error.GpuBridgeInitFailed;
        errdefer ht.free(device_id) catch {};

        const queue_id = ht.alloc(.{ .queue = {} }) catch return error.GpuBridgeInitFailed;

        return .{
            .handle_table_ptr = ht,
            .adapter_id = adapter_id,
            .device_id = device_id,
            .queue_id = queue_id,
        };
    }

    /// Release the bridge's handle table entries.
    pub fn deinit(self: *GpuBridge) void {
        self.handle_table_ptr.free(self.queue_id) catch {};
        self.handle_table_ptr.free(self.device_id) catch {};
        self.handle_table_ptr.free(self.adapter_id) catch {};
    }

    /// Register the GPU bridge native functions onto the __native object
    /// in the given QuickJS context.
    ///
    /// Creates or retrieves the `__native` global object and attaches:
    ///   - gpuRequestAdapter()  → returns adapter handle as number
    ///   - gpuRequestDevice(adapterId) → returns device handle as number
    ///   - gpuGetQueue(deviceId) → returns queue handle as number
    pub fn register(self: *const GpuBridge, ctx: *Context) !void {
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);

        // Get or create the __native object on globalThis.
        var native_obj = global.getPropertyStr(ctx, "__native");
        if (native_obj.isUndefined()) {
            native_obj.deinit(ctx);
            native_obj = Value.initObject(ctx);
            global.setPropertyStr(ctx, "__native", native_obj) catch return error.JSError;
            // setPropertyStr takes ownership, so re-fetch for further use.
            native_obj = global.getPropertyStr(ctx, "__native");
        }
        defer native_obj.deinit(ctx);

        // Bind each function with its handle ID as closure data.
        const adapter_num = Value.initFloat64(handleToF64(self.adapter_id));
        const device_num = Value.initFloat64(handleToF64(self.device_id));
        const queue_num = Value.initFloat64(handleToF64(self.queue_id));

        // gpuRequestAdapter() — closure data[0] = adapter handle
        const req_adapter_fn = Value.initCFunctionData(
            ctx,
            &gpuRequestAdapterNative,
            0, // length (no JS args)
            0, // magic
            &.{adapter_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRequestAdapter", req_adapter_fn) catch return error.JSError;

        // gpuRequestDevice(adapterId) — closure data[0] = device handle
        const req_device_fn = Value.initCFunctionData(
            ctx,
            &gpuRequestDeviceNative,
            1, // length (takes adapterId arg, but we ignore it and return pre-created device)
            0,
            &.{device_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRequestDevice", req_device_fn) catch return error.JSError;

        // gpuGetQueue(deviceId) — closure data[0] = queue handle
        const get_queue_fn = Value.initCFunctionData(
            ctx,
            &gpuGetQueueNative,
            1, // length (takes deviceId arg)
            0,
            &.{queue_num},
        );
        native_obj.setPropertyStr(ctx, "gpuGetQueue", get_queue_fn) catch return error.JSError;
    }
};

// ---------------------------------------------------------------------------
// Native function implementations
// ---------------------------------------------------------------------------

/// __native.gpuRequestAdapter() → number (adapter handle ID)
fn gpuRequestAdapterNative(
    _: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    // data[0] is the adapter handle ID as f64
    return @bitCast(func_data[0]);
}

/// __native.gpuRequestDevice(adapterId) → number (device handle ID)
fn gpuRequestDeviceNative(
    _: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    // data[0] is the device handle ID as f64
    return @bitCast(func_data[0]);
}

/// __native.gpuGetQueue(deviceId) → number (queue handle ID)
fn gpuGetQueueNative(
    _: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    // data[0] is the queue handle ID as f64
    return @bitCast(func_data[0]);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a HandleId to f64 for passing to JavaScript.
fn handleToF64(id: HandleId) f64 {
    return @floatFromInt(id.toNumber());
}

/// Convert an f64 from JavaScript back to a HandleId.
pub fn f64ToHandle(f: f64) HandleId {
    return HandleId.fromNumber(@intFromFloat(f));
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const JsEngine = @import("js_engine.zig").JsEngine;

test "GpuBridge init allocates three handles" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    try testing.expectEqual(@as(u32, 3), ht.activeCount());
    try testing.expect(ht.isValid(bridge.adapter_id));
    try testing.expect(ht.isValid(bridge.device_id));
    try testing.expect(ht.isValid(bridge.queue_id));
}

test "GpuBridge deinit frees all three handles" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    bridge.deinit();

    try testing.expectEqual(@as(u32, 0), ht.activeCount());
    try testing.expect(!ht.isValid(bridge.adapter_id));
    try testing.expect(!ht.isValid(bridge.device_id));
    try testing.expect(!ht.isValid(bridge.queue_id));
}

test "GpuBridge handle types are correct" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    const adapter_entry = try ht.get(bridge.adapter_id);
    try testing.expectEqual(handle_table.HandleType.adapter, adapter_entry.handle_type);

    const device_entry = try ht.get(bridge.device_id);
    try testing.expectEqual(handle_table.HandleType.device, device_entry.handle_type);

    const queue_entry = try ht.get(bridge.queue_id);
    try testing.expectEqual(handle_table.HandleType.queue, queue_entry.handle_type);
}

test "HandleId round-trip through f64 conversion" {
    const id = HandleId{ .index = 42, .generation = 7 };
    const f = handleToF64(id);
    const back = f64ToHandle(f);

    try testing.expectEqual(id.index, back.index);
    try testing.expectEqual(id.generation, back.generation);
}

test "register creates __native object with GPU functions" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Verify __native exists and has the expected functions
    var result = try engine.eval(
        \\typeof __native.gpuRequestAdapter === 'function' &&
        \\typeof __native.gpuRequestDevice === 'function' &&
        \\typeof __native.gpuGetQueue === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRequestAdapter returns adapter handle ID as number" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval("__native.gpuRequestAdapter()", "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expectEqual(bridge.adapter_id.index, returned_id.index);
    try testing.expectEqual(bridge.adapter_id.generation, returned_id.generation);
}

test "gpuRequestDevice returns device handle ID as number" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Pass the adapter handle as argument (ignored in current impl)
    var result = try engine.eval("__native.gpuRequestDevice(0)", "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expectEqual(bridge.device_id.index, returned_id.index);
    try testing.expectEqual(bridge.device_id.generation, returned_id.generation);
}

test "gpuGetQueue returns queue handle ID as number" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Pass the device handle as argument (ignored in current impl)
    var result = try engine.eval("__native.gpuGetQueue(0)", "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expectEqual(bridge.queue_id.index, returned_id.index);
    try testing.expectEqual(bridge.queue_id.generation, returned_id.generation);
}

test "register preserves existing __native properties" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    // Set up an existing __native object with a dummy property
    var setup = try engine.eval("globalThis.__native = { existingProp: 42 }", "<test>");
    setup.deinit();

    try bridge.register(engine.context);

    // Verify existing property is preserved
    var result = try engine.eval("__native.existingProp", "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 42), try result.toInt32());
}

test "returned handle IDs are valid in handle table" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Get adapter handle from JS and verify it's valid
    var result = try engine.eval("__native.gpuRequestAdapter()", "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.adapter, entry.handle_type);
}
