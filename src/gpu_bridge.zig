const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

const handle_table = @import("handle_table.zig");
const HandleTable = handle_table.HandleTable;
const HandleId = handle_table.HandleId;
const descriptor = @import("descriptor.zig");

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
    ///   - gpuCreateBuffer(deviceId, descriptor) → buffer handle ID
    ///   - gpuCreateTexture(deviceId, descriptor) → texture handle ID
    ///   - gpuCreateTextureView(textureId, descriptor?) → texture view handle ID
    ///   - gpuCreateSampler(deviceId, descriptor?) → sampler handle ID
    ///   - gpuDestroyBuffer(bufferId) → undefined
    ///   - gpuDestroyTexture(textureId) → undefined
    ///   - gpuCreateShaderModule(deviceId, descriptor) → handle ID
    ///   - gpuCreateBindGroupLayout(deviceId, descriptor) → handle ID
    ///   - gpuCreatePipelineLayout(deviceId, descriptor) → handle ID
    ///   - gpuCreateRenderPipeline(deviceId, descriptor) → handle ID
    ///   - gpuCreateComputePipeline(deviceId, descriptor) → handle ID
    ///   - gpuCreateBindGroup(deviceId, descriptor) → handle ID
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

        // --- Resource creation / destruction functions ---
        // These need the handle table pointer to allocate new handles.
        // We encode the *HandleTable pointer as f64 in closure data[0].
        const ht_ptr_num = Value.initFloat64(ptrToF64(self.handle_table_ptr));

        // gpuCreateBuffer(deviceId, descriptor) → buffer handle ID
        const create_buffer_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateBufferNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateBuffer", create_buffer_fn) catch return error.JSError;

        // gpuCreateTexture(deviceId, descriptor) → texture handle ID
        const create_texture_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateTextureNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateTexture", create_texture_fn) catch return error.JSError;

        // gpuCreateTextureView(textureId, descriptor?) → texture view handle ID
        const create_texture_view_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateTextureViewNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateTextureView", create_texture_view_fn) catch return error.JSError;

        // gpuCreateSampler(deviceId, descriptor?) → sampler handle ID
        const create_sampler_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateSamplerNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateSampler", create_sampler_fn) catch return error.JSError;

        // gpuDestroyBuffer(bufferId) → undefined
        const destroy_buffer_fn = Value.initCFunctionData(
            ctx,
            &gpuDestroyBufferNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuDestroyBuffer", destroy_buffer_fn) catch return error.JSError;

        // gpuDestroyTexture(textureId) → undefined
        const destroy_texture_fn = Value.initCFunctionData(
            ctx,
            &gpuDestroyTextureNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuDestroyTexture", destroy_texture_fn) catch return error.JSError;

        // --- Pipeline creation functions ---

        // gpuCreateShaderModule(deviceId, descriptor) → handle ID
        const create_shader_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateShaderModuleNative,
            2, // length (deviceId, descriptor)
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateShaderModule", create_shader_fn) catch return error.JSError;

        // gpuCreateBindGroupLayout(deviceId, descriptor) → handle ID
        const create_bgl_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateBindGroupLayoutNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateBindGroupLayout", create_bgl_fn) catch return error.JSError;

        // gpuCreatePipelineLayout(deviceId, descriptor) → handle ID
        const create_pl_fn = Value.initCFunctionData(
            ctx,
            &gpuCreatePipelineLayoutNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreatePipelineLayout", create_pl_fn) catch return error.JSError;

        // gpuCreateRenderPipeline(deviceId, descriptor) → handle ID
        const create_rp_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateRenderPipelineNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateRenderPipeline", create_rp_fn) catch return error.JSError;

        // gpuCreateComputePipeline(deviceId, descriptor) → handle ID
        const create_cp_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateComputePipelineNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateComputePipeline", create_cp_fn) catch return error.JSError;

        // gpuCreateBindGroup(deviceId, descriptor) → handle ID
        const create_bg_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateBindGroupNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateBindGroup", create_bg_fn) catch return error.JSError;
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
// Descriptor structs (Zig mirrors of WebGPU descriptors)
// ---------------------------------------------------------------------------

/// Matches GPUBufferDescriptor from the WebGPU spec.
pub const BufferDescriptor = struct {
    size: u64 = 0,
    usage: u32 = 0,
    mappedAtCreation: bool = false,
    label: ?[*:0]const u8 = null,
};

/// Matches GPUTextureDescriptor from the WebGPU spec.
pub const TextureDescriptor = struct {
    width: u32 = 0,
    height: u32 = 1,
    depthOrArrayLayers: u32 = 1,
    mipLevelCount: u32 = 1,
    sampleCount: u32 = 1,
    format: u32 = 0,
    usage: u32 = 0,
    dimension: u32 = 0,
    label: ?[*:0]const u8 = null,
};

/// Matches GPUTextureViewDescriptor from the WebGPU spec.
pub const TextureViewDescriptor = struct {
    format: u32 = 0,
    dimension: u32 = 0,
    aspect: u32 = 0,
    baseMipLevel: u32 = 0,
    mipLevelCount: u32 = 0,
    baseArrayLayer: u32 = 0,
    arrayLayerCount: u32 = 0,
    label: ?[*:0]const u8 = null,
};

/// Matches GPUSamplerDescriptor from the WebGPU spec.
pub const SamplerDescriptor = struct {
    addressModeU: u32 = 0,
    addressModeV: u32 = 0,
    addressModeW: u32 = 0,
    magFilter: u32 = 0,
    minFilter: u32 = 0,
    mipmapFilter: u32 = 0,
    lodMinClamp: f32 = 0,
    lodMaxClamp: f32 = 32,
    compare: u32 = 0,
    maxAnisotropy: u32 = 1,
    label: ?[*:0]const u8 = null,
};

// ---------------------------------------------------------------------------
// Native function implementations — buffer/texture/sampler creation
// ---------------------------------------------------------------------------

/// __native.gpuCreateBuffer(deviceId, descriptor) → number (buffer handle ID)
fn gpuCreateBufferNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";

    // args[1] is the descriptor JS object
    if (args.len < 2) return Value.@"null";
    const js_desc: Value = @bitCast(args[1]);

    // Parse the descriptor (proves the comptime translator works)
    _ = descriptor.translateDescriptor(BufferDescriptor, ctx, js_desc) catch return Value.@"null";

    // Allocate a buffer handle in the table
    const id = ht.alloc(.{ .buffer = {} }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateTexture(deviceId, descriptor) → number (texture handle ID)
fn gpuCreateTextureNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";

    if (args.len < 2) return Value.@"null";
    const js_desc: Value = @bitCast(args[1]);

    _ = descriptor.translateDescriptor(TextureDescriptor, ctx, js_desc) catch return Value.@"null";

    const id = ht.alloc(.{ .texture = {} }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateTextureView(textureId, descriptor?) → number (texture view handle ID)
fn gpuCreateTextureViewNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";

    // descriptor is optional; if provided, parse it
    if (args.len >= 2) {
        const js_desc: Value = @bitCast(args[1]);
        if (!js_desc.isUndefined() and !js_desc.isNull()) {
            _ = descriptor.translateDescriptor(TextureViewDescriptor, ctx, js_desc) catch return Value.@"null";
        }
    }

    const id = ht.alloc(.{ .texture_view = {} }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateSampler(deviceId, descriptor?) → number (sampler handle ID)
fn gpuCreateSamplerNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";

    // descriptor is optional; if provided, parse it
    if (args.len >= 2) {
        const js_desc: Value = @bitCast(args[1]);
        if (!js_desc.isUndefined() and !js_desc.isNull()) {
            _ = descriptor.translateDescriptor(SamplerDescriptor, ctx, js_desc) catch return Value.@"null";
        }
    }

    const id = ht.alloc(.{ .sampler = {} }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

// ---------------------------------------------------------------------------
// Native function implementations — resource destruction
// ---------------------------------------------------------------------------

/// __native.gpuDestroyBuffer(bufferId) → undefined
///
/// Marks the buffer handle as destroyed, then frees the slot.
fn gpuDestroyBufferNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";
    if (args.len < 1) return Value.@"null";

    const id_val: Value = @bitCast(args[0]);
    const f = id_val.toFloat64(ctx) catch return Value.@"null";
    const id = f64ToHandle(f);

    // Mark destroyed then free the slot
    ht.destroy(id) catch {};
    ht.free(id) catch {};

    return Value.undefined;
}

/// __native.gpuDestroyTexture(textureId) → undefined
///
/// Marks the texture handle as destroyed, then frees the slot.
fn gpuDestroyTextureNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.@"null";
    if (args.len < 1) return Value.@"null";

    const id_val: Value = @bitCast(args[0]);
    const f = id_val.toFloat64(ctx) catch return Value.@"null";
    const id = f64ToHandle(f);

    ht.destroy(id) catch {};
    ht.free(id) catch {};

    return Value.undefined;
}

// ---------------------------------------------------------------------------
// Pipeline creation native functions
// ---------------------------------------------------------------------------

/// __native.gpuCreateShaderModule(deviceId, descriptor) → number (handle ID)
///
/// Extracts the WGSL `code` string from the descriptor to prove string passing
/// works, then allocates a shader_module handle.
fn gpuCreateShaderModuleNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const ht = getHandleTableFromData(context, func_data) orelse return Value.@"null";

    // argv[0] = deviceId (validate the device handle exists)
    if (argv.len < 2) return Value.@"null";
    const device_id_val: Value = @bitCast(argv[0]);
    const device_f64 = device_id_val.toFloat64(context) catch return Value.@"null";
    const device_id = f64ToHandle(device_f64);
    _ = ht.get(device_id) catch return Value.@"null";

    // argv[1] = descriptor — extract the WGSL code string
    const desc_val: Value = @bitCast(argv[1]);
    const code_val = desc_val.getPropertyStr(context, "code");
    defer code_val.deinit(context);

    if (code_val.toCString(context)) |code_ptr| {
        defer context.freeCString(code_ptr);
        const code = std.mem.span(code_ptr);
        // Verify we got the code string (proves string passing works).
        _ = code;
    }

    // Allocate handle
    const id = ht.alloc(.{ .shader_module = {} }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateBindGroupLayout(deviceId, descriptor) → number (handle ID)
fn gpuCreateBindGroupLayoutNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .bind_group_layout = {} });
}

/// __native.gpuCreatePipelineLayout(deviceId, descriptor) → number (handle ID)
fn gpuCreatePipelineLayoutNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .pipeline_layout = {} });
}

/// __native.gpuCreateRenderPipeline(deviceId, descriptor) → number (handle ID)
///
/// For now, just validates the device and allocates a handle. The complex
/// nested descriptor (vertex, fragment, primitive, etc.) will be fully parsed
/// when real Dawn API calls are integrated.
fn gpuCreateRenderPipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .render_pipeline = {} });
}

/// __native.gpuCreateComputePipeline(deviceId, descriptor) → number (handle ID)
fn gpuCreateComputePipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .compute_pipeline = {} });
}

/// __native.gpuCreateBindGroup(deviceId, descriptor) → number (handle ID)
fn gpuCreateBindGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .bind_group = {} });
}

/// Shared helper for pipeline creation functions that just need to validate
/// the device handle and allocate a new handle of the given type.
fn allocPipelineHandle(
    ctx: ?*Context,
    argv: []const c.JSValue,
    func_data: [*c]c.JSValue,
    dawn_handle: handle_table.DawnHandle,
) Value {
    const context = ctx orelse return Value.@"null";
    const ht = getHandleTableFromData(context, func_data) orelse return Value.@"null";

    // argv[0] = deviceId — validate device handle exists
    if (argv.len < 2) return Value.@"null";
    const device_id_val: Value = @bitCast(argv[0]);
    const device_f64 = device_id_val.toFloat64(context) catch return Value.@"null";
    const device_id = f64ToHandle(device_f64);
    _ = ht.get(device_id) catch return Value.@"null";

    // Allocate handle
    const id = ht.alloc(dawn_handle) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// Extract the *HandleTable pointer from closure data[0].
fn getHandleTableFromData(ctx: *Context, func_data: [*c]c.JSValue) ?*HandleTable {
    const data_val: Value = @bitCast(func_data[0]);
    const ptr_bits = data_val.toFloat64(ctx) catch return null;
    return f64ToPtr(*HandleTable, ptr_bits);
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

/// Encode a pointer as f64 for storage in closure data.
/// On x86-64 Linux, user-space pointers use at most 47 bits of virtual
/// address space, so they fit losslessly in f64's 53-bit mantissa.
fn ptrToF64(ptr: anytype) f64 {
    const addr: usize = @intFromPtr(ptr);
    return @floatFromInt(addr);
}

/// Decode an f64 back to a typed pointer.
fn f64ToPtr(comptime T: type, f: f64) ?T {
    const addr: usize = @intFromFloat(f);
    if (addr == 0) return null;
    return @ptrFromInt(addr);
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

// ---------------------------------------------------------------------------
// Pipeline creation function tests
// ---------------------------------------------------------------------------

test "register creates pipeline creation functions on __native" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\typeof __native.gpuCreateShaderModule === 'function' &&
        \\typeof __native.gpuCreateBindGroupLayout === 'function' &&
        \\typeof __native.gpuCreatePipelineLayout === 'function' &&
        \\typeof __native.gpuCreateRenderPipeline === 'function' &&
        \\typeof __native.gpuCreateComputePipeline === 'function' &&
        \\typeof __native.gpuCreateBindGroup === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuCreateShaderModule returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Create shader module with WGSL code
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateShaderModule(devId, { code: '@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }' });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.shader_module, entry.handle_type);
}

test "gpuCreateShaderModule extracts WGSL code string" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Pass a code string with special characters to verify string passing
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateShaderModule(devId, {
        \\    code: 'struct VertexOutput { @builtin(position) pos: vec4f };\n@vertex fn main() -> VertexOutput { var out: VertexOutput; return out; }'
        \\  });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // If string parsing failed, we'd get null instead of a valid handle
    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));
}

test "gpuCreateBindGroupLayout returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateBindGroupLayout(devId, { entries: [] });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.bind_group_layout, entry.handle_type);
}

test "gpuCreatePipelineLayout returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreatePipelineLayout(devId, { bindGroupLayouts: [] });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.pipeline_layout, entry.handle_type);
}

test "gpuCreateRenderPipeline returns valid handle with nested descriptor" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Pass a complex nested descriptor like Three.js would
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateRenderPipeline(devId, {
        \\    vertex: { module: 1, entryPoint: 'vs_main', buffers: [] },
        \\    fragment: { module: 2, entryPoint: 'fs_main', targets: [{ format: 'bgra8unorm' }] },
        \\    primitive: { topology: 'triangle-list' },
        \\    depthStencil: { format: 'depth24plus', depthWriteEnabled: true },
        \\    multisample: { count: 1 }
        \\  });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.render_pipeline, entry.handle_type);
}

test "gpuCreateComputePipeline returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateComputePipeline(devId, {
        \\    compute: { module: 1, entryPoint: 'main' }
        \\  });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.compute_pipeline, entry.handle_type);
}

test "gpuCreateBindGroup returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateBindGroup(devId, {
        \\    layout: 1,
        \\    entries: [{ binding: 0, resource: { buffer: 1 } }]
        \\  });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.bind_group, entry.handle_type);
}

test "pipeline creation with invalid device returns null" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Use a bogus device ID that doesn't exist
    const js_src =
        \\(function() {
        \\  var result = __native.gpuCreateShaderModule(99999, { code: 'fn main() {}' });
        \\  return result === null;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "handle table allocates correct types for each pipeline creation" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Create one of each type and verify count
    const initial_count = ht.activeCount();

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  __native.gpuCreateShaderModule(devId, { code: 'fn main() {}' });
        \\  __native.gpuCreateBindGroupLayout(devId, { entries: [] });
        \\  __native.gpuCreatePipelineLayout(devId, { bindGroupLayouts: [] });
        \\  __native.gpuCreateRenderPipeline(devId, {});
        \\  __native.gpuCreateComputePipeline(devId, {});
        \\  __native.gpuCreateBindGroup(devId, {});
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // 6 new handles should have been allocated
    try testing.expectEqual(initial_count + 6, ht.activeCount());
}

// ---------------------------------------------------------------------------
// Buffer/texture/sampler creation tests
// ---------------------------------------------------------------------------

test "register creates resource creation functions on __native" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\typeof __native.gpuCreateBuffer === 'function' &&
        \\typeof __native.gpuCreateTexture === 'function' &&
        \\typeof __native.gpuCreateTextureView === 'function' &&
        \\typeof __native.gpuCreateSampler === 'function' &&
        \\typeof __native.gpuDestroyBuffer === 'function' &&
        \\typeof __native.gpuDestroyTexture === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuCreateBuffer allocates buffer handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const before = ht.activeCount();

    var result = try engine.eval(
        \\__native.gpuCreateBuffer(0, {size: 256, usage: 64})
    , "<test>");
    defer result.deinit();

    // Should have allocated one more handle
    try testing.expectEqual(before + 1, ht.activeCount());

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.buffer, entry.handle_type);
}

test "gpuCreateBuffer parses descriptor fields" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // This descriptor includes all fields — if parsing fails, we'd get null
    var result = try engine.eval(
        \\__native.gpuCreateBuffer(0, {size: 1024, usage: 5, mappedAtCreation: true})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));
}

test "gpuCreateTexture allocates texture handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateTexture(0, {width: 512, height: 512, format: 1, usage: 16})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.texture, entry.handle_type);
}

test "gpuCreateTextureView allocates texture_view handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateTextureView(0, {format: 1, dimension: 1})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.texture_view, entry.handle_type);
}

test "gpuCreateTextureView works with empty descriptor" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateTextureView(0, {})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));
}

test "gpuCreateSampler allocates sampler handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateSampler(0, {magFilter: 1, minFilter: 1})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);

    try testing.expect(ht.isValid(returned_id));

    const entry = try ht.get(returned_id);
    try testing.expectEqual(handle_table.HandleType.sampler, entry.handle_type);
}

test "gpuCreateSampler works with empty descriptor" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateSampler(0, {})
    , "<test>");
    defer result.deinit();

    const returned_f64 = try result.toFloat64();
    const returned_id = f64ToHandle(returned_f64);
    try testing.expect(ht.isValid(returned_id));
}

test "gpuDestroyBuffer destroys and frees handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Create a buffer, then destroy it via JS
    var result = try engine.eval(
        \\(function() {
        \\  var buf = __native.gpuCreateBuffer(0, {size: 128, usage: 32});
        \\  var countBefore = buf;
        \\  __native.gpuDestroyBuffer(buf);
        \\  return buf;
        \\})()
    , "<test>");
    defer result.deinit();

    const buf_f64 = try result.toFloat64();
    const buf_id = f64ToHandle(buf_f64);

    // Handle should now be freed
    try testing.expect(!ht.isValid(buf_id));
}

test "gpuDestroyTexture destroys and frees handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Create a texture, then destroy it via JS
    var result = try engine.eval(
        \\(function() {
        \\  var tex = __native.gpuCreateTexture(0, {width: 64, height: 64, usage: 16});
        \\  __native.gpuDestroyTexture(tex);
        \\  return tex;
        \\})()
    , "<test>");
    defer result.deinit();

    const tex_f64 = try result.toFloat64();
    const tex_id = f64ToHandle(tex_f64);

    try testing.expect(!ht.isValid(tex_id));
}

test "resource creation allocates correct handle types" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const initial_count = ht.activeCount();

    var result = try engine.eval(
        \\(function() {
        \\  __native.gpuCreateBuffer(0, {size: 64, usage: 1});
        \\  __native.gpuCreateTexture(0, {width: 16, height: 16, usage: 1});
        \\  __native.gpuCreateTextureView(0, {});
        \\  __native.gpuCreateSampler(0, {});
        \\  return true;
        \\})()
    , "<test>");
    defer result.deinit();

    // 4 new handles should have been allocated
    try testing.expectEqual(initial_count + 4, ht.activeCount());
}

test "pointer round-trip through f64" {
    var ht = try HandleTable.init(testing.allocator, 4);
    defer ht.deinit(testing.allocator);

    const f = ptrToF64(&ht);
    const back = f64ToPtr(*HandleTable, f);

    try testing.expect(back != null);
    try testing.expect(back.? == &ht);
}
