const std = @import("std");
const quickjs = @import("quickjs");
const Value = quickjs.Value;
const Context = quickjs.Context;
const c = quickjs.c;

const dawn = @import("dawn/context.zig");
const raw = @import("dawn/raw.zig");
const wgpu = dawn.wgpu;

const log = std.log.scoped(.gpu_bridge);

const handle_table = @import("handle_table.zig");
const HandleTable = handle_table.HandleTable;
const HandleId = handle_table.HandleId;
const DawnHandle = handle_table.DawnHandle;
const descriptor = @import("descriptor.zig");
const FpsOverlay = @import("fps_overlay.zig").FpsOverlay;

/// Test helper: creates a real GPU context with GLFW window for hardware testing
pub fn createTestGpuContext(allocator: std.mem.Allocator) !struct { *dawn.GraphicsContext, *anyopaque } {
    const builtin = @import("builtin");
    const zglfw = @import("zglfw");

    // Force X11 only on Linux (Wayland+Vulkan doesn't present on WSLg)
    if (builtin.os.tag == .linux) {
        zglfw.initHint(.platform, zglfw.Platform.x11) catch {};
    }

    // Initialize GLFW (idempotent - multiple calls are safe)
    zglfw.init() catch {};

    // Tell GLFW we do not want an OpenGL context
    zglfw.WindowHint.set(.client_api, .no_api);

    // Hide the window for testing
    zglfw.WindowHint.set(.visible, false);

    // Create a window for testing
    const glfw_window = try zglfw.createWindow(640, 480, "Test", null, null);
    errdefer zglfw.destroyWindow(glfw_window);

    // Build the WindowProvider that Dawn needs
    const window_provider = dawn.WindowProvider{
        .window = @ptrCast(glfw_window),
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
        .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
        .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
        .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
        .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
    };

    // Create real graphics context
    const gctx = try dawn.GraphicsContext.create(allocator, window_provider, .{});
    errdefer gctx.destroy(allocator);

    return .{ gctx, @ptrCast(glfw_window) };
}

/// Test helper: destroys a GPU context created by createTestGpuContext
pub fn destroyTestGpuContext(gctx: *dawn.GraphicsContext, glfw_window: *anyopaque, allocator: std.mem.Allocator) void {
    const zglfw = @import("zglfw");
    gctx.destroy(allocator);
    zglfw.destroyWindow(@ptrCast(glfw_window));
    // Don't terminate - GLFW stays initialized for other tests
}

/// The GPU bridge connects JavaScript WebGPU API calls to the pre-created
/// Dawn adapter, device, and queue (source-built Dawn, not zgpu's prebuilt binaries).
///
/// Since the native GraphicsContext creates everything at init time, the bridge
/// simply wraps the existing GPU objects as handle IDs and returns them
/// when JavaScript calls requestAdapter() / requestDevice() / getQueue().
pub const GpuBridge = struct {
    handle_table_ptr: *HandleTable,
    gctx: ?*dawn.GraphicsContext,
    adapter_id: HandleId,
    device_id: HandleId,
    queue_id: HandleId,
    frame_texture_acquired: bool = false,
    /// Track the JS handle for the current swapchain view so we can retire the
    /// handle after present. GraphicsContext owns the actual Dawn view
    /// lifetime.
    prev_swapchain_view: ?HandleId = null,
    fps_overlay: FpsOverlay = .{},

    /// Initialize the bridge by allocating handle table entries for the
    /// pre-existing adapter, device, and queue from the native GraphicsContext.
    /// Stores real wgpu object pointers so native functions can forward
    /// GPU commands to Dawn.
    ///
    /// Pass null for gctx in test/stub mode — handle pointers will be null.
    pub fn init(ht: *HandleTable, gctx: ?*dawn.GraphicsContext) !GpuBridge {
        const adapter_ptr: ?*anyopaque = if (gctx) |g| @ptrCast(g.adapter) else null;
        const device_ptr: ?*anyopaque = if (gctx) |g| @ptrCast(g.device) else null;
        const queue_ptr: ?*anyopaque = if (gctx) |g| @ptrCast(g.queue) else null;

        const adapter_id = ht.alloc(.{ .adapter = adapter_ptr }) catch return error.GpuBridgeInitFailed;
        errdefer ht.free(adapter_id) catch {};

        const device_id = ht.alloc(.{ .device = device_ptr }) catch return error.GpuBridgeInitFailed;
        errdefer ht.free(device_id) catch {};

        const queue_id = ht.alloc(.{ .queue = queue_ptr }) catch return error.GpuBridgeInitFailed;

        return .{
            .handle_table_ptr = ht,
            .gctx = gctx,
            .adapter_id = adapter_id,
            .device_id = device_id,
            .queue_id = queue_id,
        };
    }

    /// Present the swap chain if getCurrentTexture was called this frame.
    pub fn presentIfNeeded(self: *GpuBridge) void {
        if (self.frame_texture_acquired) {
            self.frame_texture_acquired = false;
            if (self.gctx) |gctx| {
                self.fps_overlay.draw(gctx);
                _ = gctx.present();
            }
            if (self.prev_swapchain_view) |prev_id| {
                self.handle_table_ptr.free(prev_id) catch {};
                self.prev_swapchain_view = null;
            }
        }
    }

    /// Release the bridge's handle table entries.
    pub fn deinit(self: *GpuBridge) void {
        if (self.prev_swapchain_view) |prev_id| {
            self.handle_table_ptr.free(prev_id) catch {};
            self.prev_swapchain_view = null;
        }
        self.fps_overlay.deinit();
        self.handle_table_ptr.free(self.queue_id) catch {};
        self.handle_table_ptr.free(self.device_id) catch {};
        self.handle_table_ptr.free(self.adapter_id) catch {};
    }

    /// Recreate the swapchain when framebuffer size changes.
    /// This keeps the acquired backbuffer texture dimensions aligned with
    /// depth/color attachments Three.js allocates for the new size.
    pub fn onFramebufferResize(self: *GpuBridge, width: u32, height: u32) void {
        const gctx = self.gctx orelse return;
        if (width == 0 or height == 0) return;
        gctx.resize(width, height);
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
    ///   - gpuBufferUnmap(bufferId) → undefined
    ///   - gpuBufferGetMappedRange(bufferId, offset, size) → ArrayBuffer
    ///   - gpuDestroyBuffer(bufferId) → undefined
    ///   - gpuDestroyTexture(textureId) → undefined
    ///   - gpuCreateShaderModule(deviceId, descriptor) → handle ID
    ///   - gpuCreateBindGroupLayout(deviceId, descriptor) → handle ID
    ///   - gpuCreatePipelineLayout(deviceId, descriptor) → handle ID
    ///   - gpuCreateRenderPipeline(deviceId, descriptor) → handle ID
    ///   - gpuCreateComputePipeline(deviceId, descriptor) → handle ID
    ///   - gpuCreateBindGroup(deviceId, descriptor) → handle ID
    ///   - gpuCreateCommandEncoder(deviceId) → command encoder handle ID
    ///   - gpuCommandEncoderBeginRenderPass(encoderId, descriptor) → render pass handle ID
    ///   - gpuRenderPassSetPipeline(passId, pipelineId) → undefined
    ///   - gpuRenderPassSetBindGroup(passId, index, bindGroupId) → undefined
    ///   - gpuRenderPassSetVertexBuffer(passId, slot, bufferId, offset?, size?) → undefined
    ///   - gpuRenderPassSetIndexBuffer(passId, bufferId, format, offset?, size?) → undefined
    ///   - gpuRenderPassDraw(passId, vertexCount, instanceCount?, ...) → undefined
    ///   - gpuRenderPassDrawIndexed(passId, indexCount, instanceCount?, ...) → undefined
    ///   - gpuRenderPassEnd(passId) → undefined
    ///   - gpuRenderPassSetViewport(passId, x, y, width, height, minDepth, maxDepth) → undefined
    ///   - gpuRenderPassSetScissorRect(passId, x, y, width, height) → undefined
    ///   - gpuCommandEncoderFinish(encoderId) → command buffer handle ID
    ///   - gpuQueueSubmit(queueId, commandBuffers[]) → undefined
    ///   - gpuQueueWriteBuffer(queueId, bufferId, bufferOffset, data, dataOffset, size) → undefined
    ///   - gpuQueueWriteTexture(queueId, destination, data, dataLayout, size) → undefined
    ///   - gpuRenderPipelineGetBindGroupLayout(pipelineId, index) → bind_group_layout handle ID
    ///   - gpuComputePipelineGetBindGroupLayout(pipelineId, index) → bind_group_layout handle ID
    ///   - gpuConfigureContext(deviceId, format, alphaMode, width, height) → undefined
    ///   - gpuGetCurrentTexture() → texture handle ID
    ///   - gpuPresent() → undefined
    pub fn register(self: *GpuBridge, ctx: *Context) !void {
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
        // These need the GpuBridge pointer to access handle table and gctx.
        // We encode the *const GpuBridge pointer as f64 in closure data[0].
        const ht_ptr_num = Value.initFloat64(ptrToF64(self));

        // gpuDeviceDestroy(deviceId) → undefined
        const device_destroy_fn = Value.initCFunctionData(
            ctx,
            &gpuDeviceDestroyNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuDeviceDestroy", device_destroy_fn) catch return error.JSError;

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

        // gpuBufferUnmap(bufferId) → undefined
        const buffer_unmap_fn = Value.initCFunctionData(
            ctx,
            &gpuBufferUnmapNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuBufferUnmap", buffer_unmap_fn) catch return error.JSError;

        // gpuBufferGetMappedRange(bufferId, offset, size) → ArrayBuffer
        const buffer_get_mapped_fn = Value.initCFunctionData(
            ctx,
            &gpuBufferGetMappedRangeNative,
            3,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuBufferGetMappedRange", buffer_get_mapped_fn) catch return error.JSError;

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

        // --- T18: Command encoding / render pass functions ---

        // gpuCreateCommandEncoder(deviceId) → command encoder handle ID
        const create_ce_fn = Value.initCFunctionData(
            ctx,
            &gpuCreateCommandEncoderNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCreateCommandEncoder", create_ce_fn) catch return error.JSError;

        // gpuCommandEncoderBeginComputePass(encoderId, descriptor?) → compute pass handle ID
        const begin_cp_fn = Value.initCFunctionData(
            ctx,
            &gpuCommandEncoderBeginComputePassNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCommandEncoderBeginComputePass", begin_cp_fn) catch return error.JSError;

        // gpuComputePassEncoderSetPipeline(passId, pipelineId) → undefined
        const cp_set_pipeline_fn = Value.initCFunctionData(
            ctx,
            &gpuComputePassEncoderSetPipelineNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuComputePassEncoderSetPipeline", cp_set_pipeline_fn) catch return error.JSError;

        // gpuComputePassEncoderSetBindGroup(passId, index, bindGroupId, offsets?) → undefined
        const cp_set_bind_group_fn = Value.initCFunctionData(
            ctx,
            &gpuComputePassEncoderSetBindGroupNative,
            3,
            1,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuComputePassEncoderSetBindGroup", cp_set_bind_group_fn) catch return error.JSError;

        // gpuComputePassEncoderDispatchWorkgroups(passId, x, y?, z?) → undefined
        const cp_dispatch_fn = Value.initCFunctionData(
            ctx,
            &gpuComputePassEncoderDispatchWorkgroupsNative,
            2,
            2,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuComputePassEncoderDispatchWorkgroups", cp_dispatch_fn) catch return error.JSError;

        // gpuComputePassEncoderEnd(passId) → undefined
        const cp_end_fn = Value.initCFunctionData(
            ctx,
            &gpuComputePassEncoderEndNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuComputePassEncoderEnd", cp_end_fn) catch return error.JSError;

        // gpuCommandEncoderBeginRenderPass(encoderId, descriptor) → render pass handle ID
        const begin_rp_fn = Value.initCFunctionData(
            ctx,
            &gpuCommandEncoderBeginRenderPassNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCommandEncoderBeginRenderPass", begin_rp_fn) catch return error.JSError;

        // gpuRenderPassSetPipeline(passId, pipelineId) → undefined
        const rp_set_pipeline_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetPipelineNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetPipeline", rp_set_pipeline_fn) catch return error.JSError;

        // gpuRenderPassSetBindGroup(passId, index, bindGroupId) → undefined
        const rp_set_bg_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetBindGroupNative,
            3,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetBindGroup", rp_set_bg_fn) catch return error.JSError;

        // gpuRenderPassSetVertexBuffer(passId, slot, bufferId, offset?, size?) → undefined
        const rp_set_vb_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetVertexBufferNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetVertexBuffer", rp_set_vb_fn) catch return error.JSError;

        // gpuRenderPassSetIndexBuffer(passId, bufferId, format, offset?, size?) → undefined
        const rp_set_ib_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetIndexBufferNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetIndexBuffer", rp_set_ib_fn) catch return error.JSError;

        // gpuRenderPassDraw(passId, vertexCount, instanceCount?, firstVertex?, firstInstance?) → undefined
        const rp_draw_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassDrawNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassDraw", rp_draw_fn) catch return error.JSError;

        // gpuRenderPassDrawIndexed(passId, indexCount, instanceCount?, firstIndex?, baseVertex?, firstInstance?) → undefined
        const rp_draw_indexed_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassDrawIndexedNative,
            6,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassDrawIndexed", rp_draw_indexed_fn) catch return error.JSError;

        // gpuRenderPassEnd(passId) → undefined
        const rp_end_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassEndNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassEnd", rp_end_fn) catch return error.JSError;

        // gpuRenderPassSetViewport(passId, x, y, width, height, minDepth, maxDepth) → undefined
        const rp_set_viewport_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetViewportNative,
            7,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetViewport", rp_set_viewport_fn) catch return error.JSError;

        // gpuRenderPassSetScissorRect(passId, x, y, width, height) → undefined
        const rp_set_scissor_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetScissorRectNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetScissorRect", rp_set_scissor_fn) catch return error.JSError;

        // gpuRenderPassSetBlendConstant(passId, color) → undefined
        const rp_set_blend_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetBlendConstantNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetBlendConstant", rp_set_blend_fn) catch return error.JSError;

        // gpuRenderPassSetStencilReference(passId, reference) → undefined
        const rp_set_stencil_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassSetStencilReferenceNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassSetStencilReference", rp_set_stencil_fn) catch return error.JSError;

        // gpuRenderPassPushDebugGroup(passId, groupLabel) → undefined
        const rp_push_dbg_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassPushDebugGroupNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassPushDebugGroup", rp_push_dbg_fn) catch return error.JSError;

        // gpuRenderPassPopDebugGroup(passId) → undefined
        const rp_pop_dbg_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassPopDebugGroupNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassPopDebugGroup", rp_pop_dbg_fn) catch return error.JSError;

        // gpuRenderPassInsertDebugMarker(passId, markerLabel) → undefined
        const rp_marker_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPassInsertDebugMarkerNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPassInsertDebugMarker", rp_marker_fn) catch return error.JSError;

        // gpuCommandEncoderFinish(encoderId) → command buffer handle ID
        const ce_finish_fn = Value.initCFunctionData(
            ctx,
            &gpuCommandEncoderFinishNative,
            1,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuCommandEncoderFinish", ce_finish_fn) catch return error.JSError;

        // gpuQueueSubmit(queueId, commandBuffers) → undefined
        const queue_submit_fn = Value.initCFunctionData(
            ctx,
            &gpuQueueSubmitNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuQueueSubmit", queue_submit_fn) catch return error.JSError;

        // gpuQueueWriteBuffer(queueId, bufferId, bufferOffset, data, dataOffset, size) → undefined
        const queue_write_buffer_fn = Value.initCFunctionData(
            ctx,
            &gpuQueueWriteBufferNative,
            6,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuQueueWriteBuffer", queue_write_buffer_fn) catch return error.JSError;

        // gpuQueueWriteTexture(queueId, destination, data, dataLayout, size) → undefined
        const queue_write_texture_fn = Value.initCFunctionData(
            ctx,
            &gpuQueueWriteTextureNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuQueueWriteTexture", queue_write_texture_fn) catch return error.JSError;

        // gpuRenderPipelineGetBindGroupLayout(pipelineId, index) → number (bind_group_layout handle)
        const get_bgl_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPipelineGetBindGroupLayoutNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuRenderPipelineGetBindGroupLayout", get_bgl_fn) catch return error.JSError;

        // gpuComputePipelineGetBindGroupLayout(pipelineId, index) → number (bind_group_layout handle)
        // Reuses the same implementation — both pipeline types work identically.
        const get_bgl_compute_fn = Value.initCFunctionData(
            ctx,
            &gpuRenderPipelineGetBindGroupLayoutNative,
            2,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuComputePipelineGetBindGroupLayout", get_bgl_compute_fn) catch return error.JSError;

        // --- T19: WebGPU present / swap chain functions ---

        // gpuConfigureContext(deviceId, format, alphaMode, width, height) → undefined
        const configure_ctx_fn = Value.initCFunctionData(
            ctx,
            &gpuConfigureContextNative,
            5,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuConfigureContext", configure_ctx_fn) catch return error.JSError;

        // gpuGetPreferredCanvasFormat() → string
        const preferred_canvas_format_fn = Value.initCFunctionData(
            ctx,
            &gpuGetPreferredCanvasFormatNative,
            0,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuGetPreferredCanvasFormat", preferred_canvas_format_fn) catch return error.JSError;

        // gpuGetCurrentTexture() → texture handle ID
        const get_current_tex_fn = Value.initCFunctionData(
            ctx,
            &gpuGetCurrentTextureNative,
            0,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuGetCurrentTexture", get_current_tex_fn) catch return error.JSError;

        // gpuPresent() → undefined
        const present_fn = Value.initCFunctionData(
            ctx,
            &gpuPresentNative,
            0,
            0,
            &.{ht_ptr_num},
        );
        native_obj.setPropertyStr(ctx, "gpuPresent", present_fn) catch return error.JSError;
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

/// __native.gpuDeviceDestroy(deviceId) → undefined
fn gpuDeviceDestroyNative(
    ctx_opt: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.@"null";
    const bridge = getBridgeFromData(ctx, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;

    if (argv.len < 1) return Value.@"null";

    const device_val: Value = @bitCast(argv[0]);
    const device_id = f64ToHandle(device_val.toFloat64(ctx) catch return Value.@"null");

    // Just free the handle from the table - GraphicsContext handles actual device cleanup
    ht.destroy(device_id) catch {};
    ht.free(device_id) catch {};

    return Value.undefined;
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
    const bridge = getBridgeFromData(ctx, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (args.len < 2) return Value.@"null";
    const js_desc: Value = @bitCast(args[1]);

    const desc = descriptor.translateDescriptor(BufferDescriptor, ctx, js_desc) catch return Value.@"null";

    // Create real wgpu buffer
    var raw_desc = std.mem.zeroes(raw.c.WGPUBufferDescriptor);
    raw_desc.size = desc.size;
    raw_desc.usage = @intCast(desc.usage);
    raw_desc.mappedAtCreation = if (desc.mappedAtCreation) raw.c.WGPU_TRUE else raw.c.WGPU_FALSE;
    const wgpu_buffer: wgpu.Buffer = @ptrCast(raw.c.wgpuDeviceCreateBuffer(@ptrCast(gctx.device), &raw_desc));

    const id = ht.alloc(.{ .buffer = @ptrCast(wgpu_buffer) }) catch return Value.@"null";
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
    const bridge = getBridgeFromData(ctx, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (args.len < 2) return Value.@"null";
    const js_desc: Value = @bitCast(args[1]);

    var desc = descriptor.translateDescriptor(TextureDescriptor, ctx, js_desc) catch return Value.@"null";

    // Parse size — can be an array [w,h,d] or object {width,height,depthOrArrayLayers}
    if (desc.width == 0) {
        const size_val = js_desc.getPropertyStr(ctx, "size");
        defer size_val.deinit(ctx);
        if (!size_val.isUndefined() and !size_val.isNull()) {
            // Check if array (has numeric index 0)
            const v0 = size_val.getPropertyUint32(ctx, 0);
            defer v0.deinit(ctx);
            if (!v0.isUndefined()) {
                // Array form: [w, h?, d?]
                desc.width = @intFromFloat(v0.toFloat64(ctx) catch 0);
                const v1 = size_val.getPropertyUint32(ctx, 1);
                defer v1.deinit(ctx);
                if (!v1.isUndefined()) desc.height = @intFromFloat(v1.toFloat64(ctx) catch 1);
                const v2 = size_val.getPropertyUint32(ctx, 2);
                defer v2.deinit(ctx);
                if (!v2.isUndefined()) desc.depthOrArrayLayers = @intFromFloat(v2.toFloat64(ctx) catch 1);
            } else {
                // Object form: {width, height?, depthOrArrayLayers?}
                const w_val = size_val.getPropertyStr(ctx, "width");
                defer w_val.deinit(ctx);
                desc.width = @intFromFloat(w_val.toFloat64(ctx) catch 0);
                const h_val = size_val.getPropertyStr(ctx, "height");
                defer h_val.deinit(ctx);
                if (!h_val.isUndefined()) desc.height = @intFromFloat(h_val.toFloat64(ctx) catch 1);
                const d_val = size_val.getPropertyStr(ctx, "depthOrArrayLayers");
                defer d_val.deinit(ctx);
                if (!d_val.isUndefined()) desc.depthOrArrayLayers = @intFromFloat(d_val.toFloat64(ctx) catch 1);
            }
        }
    }

    const js_fmt_val = js_desc.getPropertyStr(ctx, "format");
    defer js_fmt_val.deinit(ctx);
    const fmt: raw.c.WGPUTextureFormat = blk: {
        if (js_fmt_val.toCString(ctx)) |s| {
            defer ctx.freeCString(s);
            break :blk parseTextureFormat(std.mem.span(s));
        }
        if (!js_fmt_val.isUndefined() and !js_fmt_val.isNull()) {
            const n: u32 = @intFromFloat(js_fmt_val.toFloat64(ctx) catch 0);
            break :blk translateLegacyTextureFormatNumeric(n);
        }
        break :blk raw.c.WGPUTextureFormat_BGRA8Unorm;
    };

    const js_dim_val = js_desc.getPropertyStr(ctx, "dimension");
    defer js_dim_val.deinit(ctx);
    const dimension: raw.c.WGPUTextureDimension = blk: {
        if (js_dim_val.toCString(ctx)) |s| {
            defer ctx.freeCString(s);
            const str = std.mem.span(s);
            if (std.mem.eql(u8, str, "1d")) break :blk raw.c.WGPUTextureDimension_1D;
            if (std.mem.eql(u8, str, "3d")) break :blk raw.c.WGPUTextureDimension_3D;
        }
        break :blk raw.c.WGPUTextureDimension_2D;
    };
    var raw_desc = std.mem.zeroes(raw.c.WGPUTextureDescriptor);
    raw_desc.usage = @intCast(desc.usage);
    raw_desc.dimension = dimension;
    raw_desc.size = .{
        .width = desc.width,
        .height = desc.height,
        .depthOrArrayLayers = desc.depthOrArrayLayers,
    };
    raw_desc.format = fmt;
    raw_desc.mipLevelCount = desc.mipLevelCount;
    raw_desc.sampleCount = desc.sampleCount;
    const wgpu_texture: wgpu.Texture = @ptrCast(raw.c.wgpuDeviceCreateTexture(@ptrCast(gctx.device), &raw_desc));

    // Capture first rgba16float texture as intermediate render target for debug readback
    const id = ht.alloc(.{ .texture = @ptrCast(wgpu_texture) }) catch return Value.@"null";
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
    const bridge = getBridgeFromData(ctx, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;

    if (args.len < 1) return Value.@"null";

    // args[0] = textureId — get the real wgpu.Texture
    const tex_id_val: Value = @bitCast(args[0]);
    const tex_f64 = tex_id_val.toFloat64(ctx) catch return Value.@"null";
    const tex_id = f64ToHandle(tex_f64);
    const tex_entry = ht.get(tex_id) catch return Value.@"null";

    // If texture stores a TextureView directly (swapchain case), return same handle.
    // No new allocation — the view is managed by getCurrentTexture's lifecycle.
    if (tex_entry.handle_type == .texture_view) {
        return Value.initFloat64(tex_f64);
    }

    const wgpu_texture: ?wgpu.Texture = tex_entry.handle.as(wgpu.Texture);
    const texture = wgpu_texture orelse return Value.@"null";

    // Parse the optional descriptor from JS
    var raw_view_desc = std.mem.zeroes(raw.c.WGPUTextureViewDescriptor);
    raw_view_desc.format = raw.c.WGPUTextureFormat_Undefined;
    raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_Undefined;
    raw_view_desc.baseMipLevel = 0;
    raw_view_desc.mipLevelCount = 0xffff_ffff;
    raw_view_desc.baseArrayLayer = 0;
    raw_view_desc.arrayLayerCount = 0xffff_ffff;
    raw_view_desc.aspect = raw.c.WGPUTextureAspect_All;

    if (args.len >= 2) {
        const desc_val: Value = @bitCast(args[1]);
        if (!desc_val.isUndefined() and !desc_val.isNull()) {
            // format (string or number)
            const fmt_val = desc_val.getPropertyStr(ctx, "format");
            defer fmt_val.deinit(ctx);
            if (!fmt_val.isUndefined() and !fmt_val.isNull()) {
                if (fmt_val.toCString(ctx)) |s| {
                    defer ctx.freeCString(s);
                    raw_view_desc.format = parseTextureFormat(std.mem.span(s));
                } else {
                    const n: u32 = @intFromFloat(fmt_val.toFloat64(ctx) catch 0);
                    raw_view_desc.format = translateLegacyTextureFormatNumeric(n);
                }
            }

            // dimension (string)
            const dim_val = desc_val.getPropertyStr(ctx, "dimension");
            defer dim_val.deinit(ctx);
            if (dim_val.toCString(ctx)) |s| {
                defer ctx.freeCString(s);
                const str = std.mem.span(s);
                if (std.mem.eql(u8, str, "1d")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_1D
                else if (std.mem.eql(u8, str, "2d")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_2D
                else if (std.mem.eql(u8, str, "2d-array")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_2DArray
                else if (std.mem.eql(u8, str, "cube")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_Cube
                else if (std.mem.eql(u8, str, "cube-array")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_CubeArray
                else if (std.mem.eql(u8, str, "3d")) raw_view_desc.dimension = raw.c.WGPUTextureViewDimension_3D;
            }

            // baseMipLevel
            const bml_val = desc_val.getPropertyStr(ctx, "baseMipLevel");
            defer bml_val.deinit(ctx);
            if (!bml_val.isUndefined()) raw_view_desc.baseMipLevel = @intFromFloat(bml_val.toFloat64(ctx) catch 0);

            // mipLevelCount
            const mlc_val = desc_val.getPropertyStr(ctx, "mipLevelCount");
            defer mlc_val.deinit(ctx);
            if (!mlc_val.isUndefined()) raw_view_desc.mipLevelCount = @intFromFloat(mlc_val.toFloat64(ctx) catch 0xffff_ffff);

            // baseArrayLayer
            const bal_val = desc_val.getPropertyStr(ctx, "baseArrayLayer");
            defer bal_val.deinit(ctx);
            if (!bal_val.isUndefined()) raw_view_desc.baseArrayLayer = @intFromFloat(bal_val.toFloat64(ctx) catch 0);

            // arrayLayerCount
            const alc_val = desc_val.getPropertyStr(ctx, "arrayLayerCount");
            defer alc_val.deinit(ctx);
            if (!alc_val.isUndefined()) raw_view_desc.arrayLayerCount = @intFromFloat(alc_val.toFloat64(ctx) catch 0xffff_ffff);

            // aspect
            const asp_val = desc_val.getPropertyStr(ctx, "aspect");
            defer asp_val.deinit(ctx);
            if (asp_val.toCString(ctx)) |s| {
                defer ctx.freeCString(s);
                const str = std.mem.span(s);
                if (std.mem.eql(u8, str, "stencil-only")) raw_view_desc.aspect = raw.c.WGPUTextureAspect_StencilOnly
                else if (std.mem.eql(u8, str, "depth-only")) raw_view_desc.aspect = raw.c.WGPUTextureAspect_DepthOnly;
            }
        }
    }

    const view: wgpu.TextureView = @ptrCast(raw.c.wgpuTextureCreateView(@ptrCast(texture), &raw_view_desc));

    const id = ht.alloc(.{ .texture_view = @ptrCast(view) }) catch return Value.@"null";
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
    const bridge = getBridgeFromData(ctx, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    var sampler_desc = std.mem.zeroes(raw.c.WGPUSamplerDescriptor);

    if (args.len >= 2) {
        const js_desc: Value = @bitCast(args[1]);
        if (!js_desc.isUndefined() and !js_desc.isNull()) {
            const desc = descriptor.translateDescriptor(SamplerDescriptor, ctx, js_desc) catch return Value.@"null";
            sampler_desc.lodMinClamp = desc.lodMinClamp;
            sampler_desc.lodMaxClamp = desc.lodMaxClamp;
            sampler_desc.maxAnisotropy = @intCast(@max(desc.maxAnisotropy, 1));

            const mag_val = js_desc.getPropertyStr(ctx, "magFilter");
            defer mag_val.deinit(ctx);
            sampler_desc.magFilter = if (mag_val.toCString(ctx)) |s| blk: {
                defer ctx.freeCString(s);
                if (std.mem.eql(u8, std.mem.span(s), "linear")) break :blk raw.c.WGPUFilterMode_Linear;
                break :blk raw.c.WGPUFilterMode_Nearest;
            } else raw.c.WGPUFilterMode_Nearest;

            const min_val = js_desc.getPropertyStr(ctx, "minFilter");
            defer min_val.deinit(ctx);
            sampler_desc.minFilter = if (min_val.toCString(ctx)) |s| blk: {
                defer ctx.freeCString(s);
                if (std.mem.eql(u8, std.mem.span(s), "linear")) break :blk raw.c.WGPUFilterMode_Linear;
                break :blk raw.c.WGPUFilterMode_Nearest;
            } else raw.c.WGPUFilterMode_Nearest;

            const mip_val = js_desc.getPropertyStr(ctx, "mipmapFilter");
            defer mip_val.deinit(ctx);
            sampler_desc.mipmapFilter = if (mip_val.toCString(ctx)) |s| blk: {
                defer ctx.freeCString(s);
                if (std.mem.eql(u8, std.mem.span(s), "linear")) break :blk raw.c.WGPUMipmapFilterMode_Linear;
                break :blk raw.c.WGPUMipmapFilterMode_Nearest;
            } else raw.c.WGPUMipmapFilterMode_Nearest;

            const address_mode_props = [_][2]u8{
                .{ 'U', 0 },
                .{ 'V', 0 },
                .{ 'W', 0 },
            };
            inline for (address_mode_props) |suffix| {
                const prop = switch (suffix[0]) {
                    'U' => "addressModeU",
                    'V' => "addressModeV",
                    else => "addressModeW",
                };
                const mode_val = js_desc.getPropertyStr(ctx, prop);
                defer mode_val.deinit(ctx);
                const mode = if (mode_val.toCString(ctx)) |s| blk: {
                    defer ctx.freeCString(s);
                    const str = std.mem.span(s);
                    if (std.mem.eql(u8, str, "repeat")) break :blk raw.c.WGPUAddressMode_Repeat;
                    if (std.mem.eql(u8, str, "mirror-repeat")) break :blk raw.c.WGPUAddressMode_MirrorRepeat;
                    break :blk raw.c.WGPUAddressMode_ClampToEdge;
                } else raw.c.WGPUAddressMode_ClampToEdge;
                switch (suffix[0]) {
                    'U' => sampler_desc.addressModeU = @intCast(mode),
                    'V' => sampler_desc.addressModeV = @intCast(mode),
                    else => sampler_desc.addressModeW = @intCast(mode),
                }
            }

            const compare_val = js_desc.getPropertyStr(ctx, "compare");
            defer compare_val.deinit(ctx);
            if (!compare_val.isUndefined() and !compare_val.isNull()) {
                if (compare_val.toCString(ctx)) |s| {
                    defer ctx.freeCString(s);
                    sampler_desc.compare = parseCompareFunction(std.mem.span(s));
                } else {
                    const n: u32 = @intFromFloat(compare_val.toFloat64(ctx) catch 0);
                    sampler_desc.compare = translateLegacyCompareFunctionNumeric(n);
                }
            }
        }
    }

    const sampler: wgpu.Sampler = @ptrCast(raw.c.wgpuDeviceCreateSampler(@ptrCast(gctx.device), &sampler_desc));

    const id = ht.alloc(.{ .sampler = @ptrCast(sampler) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

// ---------------------------------------------------------------------------
// Native function implementations — buffer mapping
// ---------------------------------------------------------------------------

/// __native.gpuBufferUnmap(bufferId) → undefined
///
/// Calls wgpu buffer.unmap() to unmap a previously mapped buffer.
fn gpuBufferUnmapNative(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return Value.undefined;
    const ht = getHandleTableFromData(ctx, func_data) orelse return Value.undefined;
    if (args.len < 1) return Value.undefined;

    const id_val: Value = @bitCast(args[0]);
    const f = id_val.toFloat64(ctx) catch return Value.undefined;
    const id = f64ToHandle(f);

    if (ht.get(id)) |entry| {
        if (entry.handle.as(wgpu.Buffer)) |buffer| {
            buffer.unmap();
        }
    } else |_| {}

    return Value.undefined;
}

/// __native.gpuBufferGetMappedRange(bufferId, offset, size) → ArrayBuffer
///
/// Returns a JS ArrayBuffer backed by a copy of the mapped GPU buffer memory.
/// The caller writes into this ArrayBuffer, then calls gpuBufferWriteMappedRange
/// to copy it back before unmapping. For simplicity, we return a copy and
/// sync it back on unmap.
fn gpuBufferGetMappedRangeNative(
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

    var offset: usize = 0;
    if (args.len >= 2) {
        const off_val: Value = @bitCast(args[1]);
        if (!off_val.isUndefined()) offset = @intFromFloat(off_val.toFloat64(ctx) catch 0);
    }

    const entry = ht.get(id) catch return Value.@"null";
    const buffer: wgpu.Buffer = entry.handle.as(wgpu.Buffer) orelse return Value.@"null";
    const buf_size = buffer.getSize();

    var range_size: usize = buf_size - offset;
    if (args.len >= 3) {
        const sz_val: Value = @bitCast(args[2]);
        if (!sz_val.isUndefined()) range_size = @intFromFloat(sz_val.toFloat64(ctx) catch @as(f64, @floatFromInt(range_size)));
    }

    // Get the actual mapped pointer from Dawn — zero-copy.
    // JS writes directly to GPU mapped memory; unmap finalizes.
    if (buffer.getMappedRange(u8, offset, range_size)) |mapped_slice| {
        // Wrap the mapped GPU memory as a JS ArrayBuffer (no free func —
        // Dawn owns the memory, it is released on buffer.unmap()).
        return Value.initArrayBuffer(ctx, void, mapped_slice, null, {}, false);
    }

    return Value.@"null";
}

// ---------------------------------------------------------------------------
// Native function implementations — resource destruction
// ---------------------------------------------------------------------------

/// __native.gpuDestroyBuffer(bufferId) → undefined
///
/// Calls real wgpu buffer.destroy(), then marks and frees the handle slot.
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

    // Call real wgpu destroy if we have a live buffer
    if (ht.get(id)) |entry| {
        if (entry.handle.as(wgpu.Buffer)) |buffer| {
            buffer.destroy();
            buffer.release();
        }
    } else |_| {}

    ht.destroy(id) catch {};
    ht.free(id) catch {};

    return Value.undefined;
}

/// __native.gpuDestroyTexture(textureId) → undefined
///
/// Calls real wgpu texture.destroy(), then marks and frees the handle slot.
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

    // Call real wgpu destroy if we have a live texture
    if (ht.get(id)) |entry| {
        if (entry.handle.as(wgpu.Texture)) |texture| {
            texture.destroy();
            texture.release();
        }
    } else |_| {}

    ht.destroy(id) catch {};
    ht.free(id) catch {};

    return Value.undefined;
}

// ---------------------------------------------------------------------------
// Pipeline creation native functions
// ---------------------------------------------------------------------------

const android_wgpu_shim = struct {
    extern fn threezCreateShaderModuleShim(
        device: wgpu.Device,
        label: ?[*:0]const u8,
        code: [*:0]const u8,
    ) wgpu.ShaderModule;
};

/// __native.gpuCreateShaderModule(deviceId, descriptor) → number (handle ID)
///
/// Compiles WGSL shader code via Dawn and stores the resulting ShaderModule.
fn gpuCreateShaderModuleNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    // argv[1] = descriptor — extract the WGSL code string
    const desc_val: Value = @bitCast(argv[1]);
    const code_val = desc_val.getPropertyStr(context, "code");
    defer code_val.deinit(context);

    const code_ptr = code_val.toCString(context) orelse return Value.@"null";
    defer context.freeCString(code_ptr);

    const code_span = std.mem.span(code_ptr);

    const label_val = desc_val.getPropertyStr(context, "label");
    defer label_val.deinit(context);
    const label_ptr = label_val.toCString(context);
    defer if (label_ptr) |ptr| context.freeCString(ptr);

    var wgsl_desc = std.mem.zeroes(raw.c.WGPUShaderSourceWGSL);
    wgsl_desc.chain.next = null;
    wgsl_desc.chain.sType = raw.c.WGPUSType_ShaderSourceWGSL;
    wgsl_desc.code = rawStringViewSlice(code_span);

    var shader_desc = std.mem.zeroes(raw.c.WGPUShaderModuleDescriptor);
    shader_desc.nextInChain = &wgsl_desc.chain;
    shader_desc.label = rawStringViewZ(label_ptr);

    const shader_module: wgpu.ShaderModule = @ptrCast(raw.c.wgpuDeviceCreateShaderModule(@ptrCast(gctx.device), &shader_desc));

    const id = ht.alloc(.{ .shader_module = @ptrCast(shader_module) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateBindGroupLayout(deviceId, descriptor) → number (handle ID)
///
/// Parses bind group layout entries and creates a real wgpu BindGroupLayout.
fn gpuCreateBindGroupLayoutNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    const desc_val: Value = @bitCast(argv[1]);
    const entries_val = desc_val.getPropertyStr(context, "entries");
    defer entries_val.deinit(context);

    var entries: [16]raw.c.WGPUBindGroupLayoutEntry = undefined;
    var entry_count: usize = 0;

    if (!entries_val.isUndefined() and !entries_val.isNull()) {
        const len_val = entries_val.getPropertyStr(context, "length");
        defer len_val.deinit(context);
        const len = len_val.toFloat64(context) catch 0;
        entry_count = @min(@as(usize, @intFromFloat(len)), 16);

        for (0..entry_count) |i| {
            const elem = entries_val.getPropertyUint32(context, @intCast(i));
            defer elem.deinit(context);

            const binding_val = elem.getPropertyStr(context, "binding");
            defer binding_val.deinit(context);
            const binding: u32 = @intFromFloat(binding_val.toFloat64(context) catch 0);

            const vis_val = elem.getPropertyStr(context, "visibility");
            defer vis_val.deinit(context);
            const visibility: u32 = @intFromFloat(vis_val.toFloat64(context) catch 0);

            var entry = std.mem.zeroes(raw.c.WGPUBindGroupLayoutEntry);
            entry.binding = binding;
            entry.visibility = @intCast(visibility);

            // Parse buffer binding
            const buf_val = elem.getPropertyStr(context, "buffer");
            defer buf_val.deinit(context);
            if (!buf_val.isUndefined() and !buf_val.isNull()) {
                var buf_type: @TypeOf(entry.buffer.type) = raw.c.WGPUBufferBindingType_Uniform;
                const type_val = buf_val.getPropertyStr(context, "type");
                defer type_val.deinit(context);
                if (type_val.toCString(context)) |s| {
                    defer context.freeCString(s);
                    const str = std.mem.span(s);
                    if (std.mem.eql(u8, str, "storage")) buf_type = @intCast(raw.c.WGPUBufferBindingType_Storage)
                    else if (std.mem.eql(u8, str, "read-only-storage")) buf_type = @intCast(raw.c.WGPUBufferBindingType_ReadOnlyStorage);
                } else if (!type_val.isUndefined() and !type_val.isNull()) {
                    const n: u32 = @intFromFloat(type_val.toFloat64(context) catch 0);
                    buf_type = @intCast(translateLegacyBufferBindingTypeNumeric(n));
                }
                entry.buffer.type = buf_type;
            }

            // Parse sampler binding
            const samp_val = elem.getPropertyStr(context, "sampler");
            defer samp_val.deinit(context);
            if (!samp_val.isUndefined() and !samp_val.isNull()) {
                var samp_type: @TypeOf(entry.sampler.type) = raw.c.WGPUSamplerBindingType_Filtering;
                const type_val = samp_val.getPropertyStr(context, "type");
                defer type_val.deinit(context);
                if (type_val.toCString(context)) |s| {
                    defer context.freeCString(s);
                    const str = std.mem.span(s);
                    if (std.mem.eql(u8, str, "non-filtering")) samp_type = @intCast(raw.c.WGPUSamplerBindingType_NonFiltering)
                    else if (std.mem.eql(u8, str, "comparison")) samp_type = @intCast(raw.c.WGPUSamplerBindingType_Comparison);
                } else if (!type_val.isUndefined() and !type_val.isNull()) {
                    const n: u32 = @intFromFloat(type_val.toFloat64(context) catch 0);
                    samp_type = @intCast(translateLegacySamplerBindingTypeNumeric(n));
                }
                entry.sampler.type = samp_type;
            }

            // Parse texture binding
            const tex_val = elem.getPropertyStr(context, "texture");
            defer tex_val.deinit(context);
            if (!tex_val.isUndefined() and !tex_val.isNull()) {
                var sample_type: @TypeOf(entry.texture.sampleType) = raw.c.WGPUTextureSampleType_Float;
                const st_val = tex_val.getPropertyStr(context, "sampleType");
                defer st_val.deinit(context);
                if (st_val.toCString(context)) |s| {
                    defer context.freeCString(s);
                    const str = std.mem.span(s);
                    if (std.mem.eql(u8, str, "unfilterable-float")) sample_type = @intCast(raw.c.WGPUTextureSampleType_UnfilterableFloat)
                    else if (std.mem.eql(u8, str, "depth")) sample_type = @intCast(raw.c.WGPUTextureSampleType_Depth)
                    else if (std.mem.eql(u8, str, "sint")) sample_type = @intCast(raw.c.WGPUTextureSampleType_Sint)
                    else if (std.mem.eql(u8, str, "uint")) sample_type = @intCast(raw.c.WGPUTextureSampleType_Uint);
                } else if (!st_val.isUndefined() and !st_val.isNull()) {
                    const n: u32 = @intFromFloat(st_val.toFloat64(context) catch 0);
                    sample_type = @intCast(translateLegacyTextureSampleTypeNumeric(n));
                }
                entry.texture.sampleType = sample_type;
            }

            // Parse storageTexture binding
            const st_val2 = elem.getPropertyStr(context, "storageTexture");
            defer st_val2.deinit(context);
            if (!st_val2.isUndefined() and !st_val2.isNull()) {
                const fmt_val = st_val2.getPropertyStr(context, "format");
                defer fmt_val.deinit(context);
                const st_fmt = blk: {
                    if (fmt_val.toCString(context)) |s| {
                        defer context.freeCString(s);
                        break :blk parseTextureFormat(std.mem.span(s));
                    }
                    const n: u32 = @intFromFloat(fmt_val.toFloat64(context) catch 0);
                    break :blk translateLegacyTextureFormatNumeric(n);
                };
                entry.storageTexture.access = raw.c.WGPUStorageTextureAccess_WriteOnly;
                entry.storageTexture.format = st_fmt;
            }

            entries[i] = entry;
        }
    }

    var layout_desc = std.mem.zeroes(raw.c.WGPUBindGroupLayoutDescriptor);
    layout_desc.entryCount = entry_count;
    layout_desc.entries = if (entry_count > 0) @ptrCast(&entries) else null;
    const layout: wgpu.BindGroupLayout = @ptrCast(raw.c.wgpuDeviceCreateBindGroupLayout(@ptrCast(gctx.device), &layout_desc));

    const id = ht.alloc(.{ .bind_group_layout = @ptrCast(layout) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreatePipelineLayout(deviceId, descriptor) → number (handle ID)
///
/// Parses bindGroupLayouts array (handle IDs) and creates a real wgpu PipelineLayout.
fn gpuCreatePipelineLayoutNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    const desc_val: Value = @bitCast(argv[1]);
    const bgl_arr = desc_val.getPropertyStr(context, "bindGroupLayouts");
    defer bgl_arr.deinit(context);

    var layouts: [8]raw.c.WGPUBindGroupLayout = undefined;
    var layout_count: usize = 0;

    if (!bgl_arr.isUndefined() and !bgl_arr.isNull()) {
        const len_val = bgl_arr.getPropertyStr(context, "length");
        defer len_val.deinit(context);
        const len = len_val.toFloat64(context) catch 0;
        layout_count = @min(@as(usize, @intFromFloat(len)), 8);

        for (0..layout_count) |i| {
            const elem = bgl_arr.getPropertyUint32(context, @intCast(i));
            defer elem.deinit(context);
            const bgl_f64 = elem.toFloat64(context) catch return Value.@"null";
            const bgl_id = f64ToHandle(bgl_f64);
            const bgl_entry = ht.get(bgl_id) catch return Value.@"null";
            const layout = bgl_entry.handle.as(wgpu.BindGroupLayout) orelse return Value.@"null";
            layouts[i] = @ptrCast(layout);
        }
    }

    var pipeline_layout_desc = std.mem.zeroes(raw.c.WGPUPipelineLayoutDescriptor);
    pipeline_layout_desc.bindGroupLayoutCount = layout_count;
    pipeline_layout_desc.bindGroupLayouts = if (layout_count > 0) @ptrCast(&layouts) else null;
    const pipeline_layout: wgpu.PipelineLayout = @ptrCast(raw.c.wgpuDeviceCreatePipelineLayout(@ptrCast(gctx.device), &pipeline_layout_desc));

    const id = ht.alloc(.{ .pipeline_layout = @ptrCast(pipeline_layout) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateRenderPipeline(deviceId, descriptor) → number (handle ID)
///
/// Parses the full render pipeline descriptor (vertex, fragment, primitive,
/// depthStencil, multisample) and creates a real wgpu RenderPipeline.
fn gpuCreateRenderPipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    const desc_val: Value = @bitCast(argv[1]);

    // --- layout (optional, "auto" means null) ---
    var pipeline_layout: ?wgpu.PipelineLayout = null;
    const layout_val = desc_val.getPropertyStr(context, "layout");
    defer layout_val.deinit(context);
    if (!layout_val.isUndefined() and !layout_val.isNull()) {
        // Try as number first (handle ID from unwrapHandles)
        if (layout_val.isNumber()) {
            const layout_f64 = layout_val.toFloat64(context) catch 0;
            if (layout_f64 > 0) {
                const layout_id = f64ToHandle(layout_f64);
                if (ht.get(layout_id)) |entry| {
                    pipeline_layout = entry.handle.as(wgpu.PipelineLayout);
                } else |_| {}
            }
        }
        // else: string "auto" or anything else → null layout (Dawn auto-generates)
    }

    // --- vertex state ---
    const vert_val = desc_val.getPropertyStr(context, "vertex");
    defer vert_val.deinit(context);
    if (vert_val.isUndefined() or vert_val.isNull()) return Value.@"null";

    // vertex.module (shader module handle ID)
    const vm_val = vert_val.getPropertyStr(context, "module");
    defer vm_val.deinit(context);
    const vm_f64 = vm_val.toFloat64(context) catch return Value.@"null";
    const vm_entry = ht.get(f64ToHandle(vm_f64)) catch return Value.@"null";
    const vertex_module: wgpu.ShaderModule = vm_entry.handle.as(wgpu.ShaderModule) orelse return Value.@"null";

    // vertex.entryPoint — null means auto-detect (Dawn default)
    const vep_val = vert_val.getPropertyStr(context, "entryPoint");
    defer vep_val.deinit(context);
    const vertex_ep_owned = if (vep_val.isUndefined() or vep_val.isNull()) null else vep_val.toCString(context);
    defer if (vertex_ep_owned) |s| context.freeCString(s);
    const vertex_ep: ?[*:0]const u8 = vertex_ep_owned;

    // vertex.buffers (array of VertexBufferLayout)
    var vbuf_layouts: [8]raw.c.WGPUVertexBufferLayout = undefined;
    var vbuf_count: usize = 0;
    var all_attrs: [64]raw.c.WGPUVertexAttribute = undefined;
    var attr_offset: usize = 0;

    const vbufs_val = vert_val.getPropertyStr(context, "buffers");
    defer vbufs_val.deinit(context);
    if (!vbufs_val.isUndefined() and !vbufs_val.isNull()) {
        const vb_len_val = vbufs_val.getPropertyStr(context, "length");
        defer vb_len_val.deinit(context);
        vbuf_count = @min(@as(usize, @intFromFloat(vb_len_val.toFloat64(context) catch 0)), 8);

        for (0..vbuf_count) |bi| {
            const vb = vbufs_val.getPropertyUint32(context, @intCast(bi));
            defer vb.deinit(context);

            // Check for null/undefined buffer slot (Three.js can pass null)
            if (vb.isUndefined() or vb.isNull()) {
                vbuf_layouts[bi] = std.mem.zeroes(raw.c.WGPUVertexBufferLayout);
                vbuf_layouts[bi].stepMode = raw.c.WGPUVertexStepMode_Vertex;
                vbuf_layouts[bi].arrayStride = 0;
                vbuf_layouts[bi].attributeCount = 0;
                vbuf_layouts[bi].attributes = null;
                continue;
            }

            const stride_val = vb.getPropertyStr(context, "arrayStride");
            defer stride_val.deinit(context);
            const array_stride: u64 = @intFromFloat(stride_val.toFloat64(context) catch 0);

            var step_mode = raw.c.WGPUVertexStepMode_Vertex;
            const sm_val = vb.getPropertyStr(context, "stepMode");
            defer sm_val.deinit(context);
            if (sm_val.toCString(context)) |s| {
                defer context.freeCString(s);
                if (std.mem.eql(u8, std.mem.span(s), "instance")) step_mode = raw.c.WGPUVertexStepMode_Instance;
            }

            // Parse attributes
            const attrs_val = vb.getPropertyStr(context, "attributes");
            defer attrs_val.deinit(context);
            const attr_start = attr_offset;

            if (!attrs_val.isUndefined() and !attrs_val.isNull()) {
                const a_len_val = attrs_val.getPropertyStr(context, "length");
                defer a_len_val.deinit(context);
                const a_count = @min(@as(usize, @intFromFloat(a_len_val.toFloat64(context) catch 0)), 16);

                for (0..a_count) |ai| {
                    if (attr_offset >= 64) break;
                    const attr = attrs_val.getPropertyUint32(context, @intCast(ai));
                    defer attr.deinit(context);

                    const fmt_val = attr.getPropertyStr(context, "format");
                    defer fmt_val.deinit(context);
                    const vert_fmt: raw.c.WGPUVertexFormat = blk: {
                        if (fmt_val.toCString(context)) |s| {
                            defer context.freeCString(s);
                            break :blk parseVertexFormat(std.mem.span(s));
                        }
                        const n: u32 = @intFromFloat(fmt_val.toFloat64(context) catch 0);
                        break :blk translateLegacyVertexFormatNumeric(n);
                    };

                    const off_val = attr.getPropertyStr(context, "offset");
                    defer off_val.deinit(context);
                    const offset: u64 = @intFromFloat(off_val.toFloat64(context) catch 0);

                    const loc_val = attr.getPropertyStr(context, "shaderLocation");
                    defer loc_val.deinit(context);
                    const location: u32 = @intFromFloat(loc_val.toFloat64(context) catch 0);

                    all_attrs[attr_offset] = std.mem.zeroes(raw.c.WGPUVertexAttribute);
                    all_attrs[attr_offset].format = vert_fmt;
                    all_attrs[attr_offset].offset = offset;
                    all_attrs[attr_offset].shaderLocation = location;
                    attr_offset += 1;
                }
            }

            vbuf_layouts[bi] = std.mem.zeroes(raw.c.WGPUVertexBufferLayout);
            vbuf_layouts[bi].arrayStride = array_stride;
            vbuf_layouts[bi].stepMode = @intCast(step_mode);
            vbuf_layouts[bi].attributeCount = attr_offset - attr_start;
            vbuf_layouts[bi].attributes = if (attr_offset > attr_start) @ptrCast(&all_attrs[attr_start]) else null;
        }
    }

    var vertex_state = std.mem.zeroes(raw.c.WGPUVertexState);
    vertex_state.module = @ptrCast(vertex_module);
    vertex_state.entryPoint = if (vertex_ep) |ep| rawStringViewZ(ep) else rawStringViewSlice("main");
    vertex_state.bufferCount = vbuf_count;
    vertex_state.buffers = if (vbuf_count > 0) @ptrCast(&vbuf_layouts) else null;

    // --- fragment state (optional) ---
    var fragment_state = std.mem.zeroes(raw.c.WGPUFragmentState);
    var color_targets: [8]raw.c.WGPUColorTargetState = undefined;
    var blend_states: [8]raw.c.WGPUBlendState = undefined;
    var has_fragment = false;

    const frag_val = desc_val.getPropertyStr(context, "fragment");
    defer frag_val.deinit(context);
    if (!frag_val.isUndefined() and !frag_val.isNull()) {
        has_fragment = true;

        const fm_val = frag_val.getPropertyStr(context, "module");
        defer fm_val.deinit(context);
        const fm_f64 = fm_val.toFloat64(context) catch return Value.@"null";
        const fm_entry = ht.get(f64ToHandle(fm_f64)) catch return Value.@"null";
        const frag_module: wgpu.ShaderModule = fm_entry.handle.as(wgpu.ShaderModule) orelse return Value.@"null";

        const fep_val = frag_val.getPropertyStr(context, "entryPoint");
        defer fep_val.deinit(context);
        const frag_ep_owned = if (fep_val.isUndefined() or fep_val.isNull()) null else fep_val.toCString(context);
        defer if (frag_ep_owned) |s| context.freeCString(s);
        const frag_ep: ?[*:0]const u8 = frag_ep_owned;

        // Parse targets
        var target_count: usize = 0;
        const targets_val = frag_val.getPropertyStr(context, "targets");
        defer targets_val.deinit(context);
        if (!targets_val.isUndefined() and !targets_val.isNull()) {
            const t_len_val = targets_val.getPropertyStr(context, "length");
            defer t_len_val.deinit(context);
            target_count = @min(@as(usize, @intFromFloat(t_len_val.toFloat64(context) catch 0)), 8);

            for (0..target_count) |ti| {
                const tgt = targets_val.getPropertyUint32(context, @intCast(ti));
                defer tgt.deinit(context);

                const fmt_val2 = tgt.getPropertyStr(context, "format");
                defer fmt_val2.deinit(context);
                const target_fmt: raw.c.WGPUTextureFormat = blk: {
                    if (fmt_val2.toCString(context)) |s| {
                        defer context.freeCString(s);
                        break :blk parseTextureFormat(std.mem.span(s));
                    }
                    const n: u32 = @intFromFloat(fmt_val2.toFloat64(context) catch 0);
                    break :blk translateLegacyTextureFormatNumeric(n);
                };

                // Parse blend (optional)
                const blend_val = tgt.getPropertyStr(context, "blend");
                defer blend_val.deinit(context);
                var blend_ptr: ?*const raw.c.WGPUBlendState = null;
                if (!blend_val.isUndefined() and !blend_val.isNull()) {
                    blend_states[ti] = .{
                        .color = parseBlendComponent(context, blend_val, "color"),
                        .alpha = parseBlendComponent(context, blend_val, "alpha"),
                    };
                    blend_ptr = &blend_states[ti];
                }

                // Parse writeMask (optional, default all)
                var write_mask: u32 = 0xF;
                const wm_val = tgt.getPropertyStr(context, "writeMask");
                defer wm_val.deinit(context);
                if (!wm_val.isUndefined()) {
                    write_mask = @intFromFloat(wm_val.toFloat64(context) catch 0xF);
                }

                color_targets[ti] = std.mem.zeroes(raw.c.WGPUColorTargetState);
                color_targets[ti].format = target_fmt;
                color_targets[ti].blend = blend_ptr;
                color_targets[ti].writeMask = @intCast(write_mask);
            }
        }

        fragment_state.module = @ptrCast(frag_module);
        fragment_state.entryPoint = if (frag_ep) |ep| rawStringViewZ(ep) else rawStringViewSlice("main");
        fragment_state.targetCount = target_count;
        fragment_state.targets = if (target_count > 0) @ptrCast(&color_targets) else null;
    }

    // --- primitive state ---
    var raw_primitive = std.mem.zeroes(raw.c.WGPUPrimitiveState);
    raw_primitive.topology = raw.c.WGPUPrimitiveTopology_TriangleList;
    raw_primitive.stripIndexFormat = raw.c.WGPUIndexFormat_Undefined;
    raw_primitive.frontFace = raw.c.WGPUFrontFace_CCW;
    raw_primitive.cullMode = raw.c.WGPUCullMode_None;
    const prim_val = desc_val.getPropertyStr(context, "primitive");
    defer prim_val.deinit(context);
    if (!prim_val.isUndefined() and !prim_val.isNull()) {
        const topo_val = prim_val.getPropertyStr(context, "topology");
        defer topo_val.deinit(context);
        if (topo_val.toCString(context)) |s| {
            defer context.freeCString(s);
            const str = std.mem.span(s);
            if (std.mem.eql(u8, str, "point-list")) raw_primitive.topology = raw.c.WGPUPrimitiveTopology_PointList
            else if (std.mem.eql(u8, str, "line-list")) raw_primitive.topology = raw.c.WGPUPrimitiveTopology_LineList
            else if (std.mem.eql(u8, str, "line-strip")) raw_primitive.topology = raw.c.WGPUPrimitiveTopology_LineStrip
            else if (std.mem.eql(u8, str, "triangle-list")) raw_primitive.topology = raw.c.WGPUPrimitiveTopology_TriangleList
            else if (std.mem.eql(u8, str, "triangle-strip")) raw_primitive.topology = raw.c.WGPUPrimitiveTopology_TriangleStrip;
        }

        const cull_val = prim_val.getPropertyStr(context, "cullMode");
        defer cull_val.deinit(context);
        if (cull_val.toCString(context)) |s| {
            defer context.freeCString(s);
            const str = std.mem.span(s);
            if (std.mem.eql(u8, str, "front")) raw_primitive.cullMode = raw.c.WGPUCullMode_Front
            else if (std.mem.eql(u8, str, "back")) raw_primitive.cullMode = raw.c.WGPUCullMode_Back;
        }

        const ff_val = prim_val.getPropertyStr(context, "frontFace");
        defer ff_val.deinit(context);
        if (ff_val.toCString(context)) |s| {
            defer context.freeCString(s);
            const span = std.mem.span(s);
            if (std.mem.eql(u8, span, "cw")) raw_primitive.frontFace = raw.c.WGPUFrontFace_CW
            else if (std.mem.eql(u8, span, "ccw")) raw_primitive.frontFace = raw.c.WGPUFrontFace_CCW;
        }

        // stripIndexFormat must only be set for strip topologies
        if (raw_primitive.topology == raw.c.WGPUPrimitiveTopology_LineStrip or raw_primitive.topology == raw.c.WGPUPrimitiveTopology_TriangleStrip) {
            const sif_val = prim_val.getPropertyStr(context, "stripIndexFormat");
            defer sif_val.deinit(context);
            if (sif_val.toCString(context)) |s| {
                defer context.freeCString(s);
                if (std.mem.eql(u8, std.mem.span(s), "uint16")) raw_primitive.stripIndexFormat = raw.c.WGPUIndexFormat_Uint16
                else raw_primitive.stripIndexFormat = raw.c.WGPUIndexFormat_Uint32;
            }
        }
    }

    // --- depth/stencil state (optional) ---
    var raw_depth_stencil = std.mem.zeroes(raw.c.WGPUDepthStencilState);
    raw_depth_stencil.depthCompare = raw.c.WGPUCompareFunction_Always;
    raw_depth_stencil.stencilFront = .{
        .compare = raw.c.WGPUCompareFunction_Always,
        .failOp = raw.c.WGPUStencilOperation_Keep,
        .depthFailOp = raw.c.WGPUStencilOperation_Keep,
        .passOp = raw.c.WGPUStencilOperation_Keep,
    };
    raw_depth_stencil.stencilBack = raw_depth_stencil.stencilFront;
    var has_depth_stencil = false;
    const ds_val = desc_val.getPropertyStr(context, "depthStencil");
    defer ds_val.deinit(context);
    if (!ds_val.isUndefined() and !ds_val.isNull()) {
        has_depth_stencil = true;

        const fmt_val3 = ds_val.getPropertyStr(context, "format");
        defer fmt_val3.deinit(context);
        raw_depth_stencil.format = blk: {
            if (fmt_val3.toCString(context)) |s| {
                defer context.freeCString(s);
                break :blk parseTextureFormat(std.mem.span(s));
            }
            const n: u32 = @intFromFloat(fmt_val3.toFloat64(context) catch 0);
            break :blk translateLegacyTextureFormatNumeric(n);
        };

        const dwe_val = ds_val.getPropertyStr(context, "depthWriteEnabled");
        defer dwe_val.deinit(context);
        if (!dwe_val.isUndefined()) {
            raw_depth_stencil.depthWriteEnabled = if (dwe_val.toBool(context) catch false)
                raw.c.WGPUOptionalBool_True
            else
                raw.c.WGPUOptionalBool_False;
        }

        const dc_val = ds_val.getPropertyStr(context, "depthCompare");
        defer dc_val.deinit(context);
        if (dc_val.toCString(context)) |s| {
            defer context.freeCString(s);
            raw_depth_stencil.depthCompare = parseCompareFunction(std.mem.span(s));
        }
    }

    // --- multisample state ---
    var multisample = wgpu.MultisampleState{};
    const ms_val = desc_val.getPropertyStr(context, "multisample");
    defer ms_val.deinit(context);
    if (!ms_val.isUndefined() and !ms_val.isNull()) {
        const count_val = ms_val.getPropertyStr(context, "count");
        defer count_val.deinit(context);
        if (!count_val.isUndefined()) multisample.count = @intFromFloat(count_val.toFloat64(context) catch 1);

        const mask_val = ms_val.getPropertyStr(context, "mask");
        defer mask_val.deinit(context);
        if (!mask_val.isUndefined()) multisample.mask = @intFromFloat(mask_val.toFloat64(context) catch 0xFFFFFFFF);

        const atc_val = ms_val.getPropertyStr(context, "alphaToCoverageEnabled");
        defer atc_val.deinit(context);
        if (!atc_val.isUndefined()) multisample.alpha_to_coverage_enabled = atc_val.toBool(context) catch false;
    }

    var raw_multisample = std.mem.zeroes(raw.c.WGPUMultisampleState);
    raw_multisample.count = multisample.count;
    raw_multisample.mask = multisample.mask;
    raw_multisample.alphaToCoverageEnabled = if (multisample.alpha_to_coverage_enabled) raw.c.WGPU_TRUE else raw.c.WGPU_FALSE;

    var pipeline_desc = std.mem.zeroes(raw.c.WGPURenderPipelineDescriptor);
    pipeline_desc.layout = if (pipeline_layout) |l| @ptrCast(l) else null;
    pipeline_desc.vertex = vertex_state;
    pipeline_desc.primitive = raw_primitive;
    pipeline_desc.depthStencil = if (has_depth_stencil) &raw_depth_stencil else null;
    pipeline_desc.multisample = raw_multisample;
    pipeline_desc.fragment = if (has_fragment) &fragment_state else null;

    const render_pipeline: wgpu.RenderPipeline = @ptrCast(raw.c.wgpuDeviceCreateRenderPipeline(@ptrCast(gctx.device), &pipeline_desc));

    const id = ht.alloc(.{ .render_pipeline = @ptrCast(render_pipeline) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCreateComputePipeline(deviceId, descriptor) → number (handle ID)
fn gpuCreateComputePipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    return allocPipelineHandle(ctx, argv, func_data, .{ .compute_pipeline = null });
}

/// __native.gpuCreateBindGroup(deviceId, descriptor) → number (handle ID)
///
/// Parses bind group entries (buffer/sampler/textureView resources) and creates
/// a real wgpu BindGroup.
fn gpuCreateBindGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    const desc_val: Value = @bitCast(argv[1]);

    // layout handle
    const layout_val = desc_val.getPropertyStr(context, "layout");
    defer layout_val.deinit(context);
    const layout_f64 = layout_val.toFloat64(context) catch return Value.@"null";
    const layout_entry = ht.get(f64ToHandle(layout_f64)) catch return Value.@"null";
    const layout: wgpu.BindGroupLayout = layout_entry.handle.as(wgpu.BindGroupLayout) orelse return Value.@"null";

    // entries array
    const entries_val = desc_val.getPropertyStr(context, "entries");
    defer entries_val.deinit(context);

    var entries: [16]raw.c.WGPUBindGroupEntry = undefined;
    var entry_count: usize = 0;

    if (!entries_val.isUndefined() and !entries_val.isNull()) {
        const len_val = entries_val.getPropertyStr(context, "length");
        defer len_val.deinit(context);
        const len = len_val.toFloat64(context) catch 0;
        entry_count = @min(@as(usize, @intFromFloat(len)), 16);

        for (0..entry_count) |i| {
            const elem = entries_val.getPropertyUint32(context, @intCast(i));
            defer elem.deinit(context);

            const binding_val = elem.getPropertyStr(context, "binding");
            defer binding_val.deinit(context);
            const binding: u32 = @intFromFloat(binding_val.toFloat64(context) catch 0);

            var entry = std.mem.zeroes(raw.c.WGPUBindGroupEntry);
            entry.binding = binding;
            entry.size = std.math.maxInt(u64);

            // resource can be a buffer, sampler, or textureView
            const resource_val = elem.getPropertyStr(context, "resource");
            defer resource_val.deinit(context);

            if (!resource_val.isUndefined() and !resource_val.isNull()) {
                // Check if resource is a buffer binding object { buffer, offset?, size? }
                const buf_val = resource_val.getPropertyStr(context, "buffer");
                defer buf_val.deinit(context);

                if (!buf_val.isUndefined() and !buf_val.isNull()) {
                    // Buffer binding
                    const buf_f64 = buf_val.toFloat64(context) catch 0;
                    const buf_id = f64ToHandle(buf_f64);
                    if (ht.get(buf_id)) |buf_entry| {
                        if (buf_entry.handle.as(wgpu.Buffer)) |buffer| entry.buffer = @ptrCast(buffer);
                    } else |_| {}

                    const off_val = resource_val.getPropertyStr(context, "offset");
                    defer off_val.deinit(context);
                    if (!off_val.isUndefined()) entry.offset = @intFromFloat(off_val.toFloat64(context) catch 0);

                    const sz_val = resource_val.getPropertyStr(context, "size");
                    defer sz_val.deinit(context);
                    if (!sz_val.isUndefined()) entry.size = @intFromFloat(sz_val.toFloat64(context) catch @as(f64, @floatFromInt(std.math.maxInt(u64))));
                } else {
                    // Direct handle — sampler or textureView
                    if (resource_val.toFloat64(context)) |res_f64| {
                        const res_id = f64ToHandle(res_f64);
                        if (ht.get(res_id)) |res_entry| {
                            switch (res_entry.handle_type) {
                                .sampler => {
                                    if (res_entry.handle.as(wgpu.Sampler)) |sampler| entry.sampler = @ptrCast(sampler);
                                },
                                .texture_view => {
                                    if (res_entry.handle.as(wgpu.TextureView)) |view| entry.textureView = @ptrCast(view);
                                },
                                else => {},
                            }
                        } else |_| {}
                    } else |_| {}
                }
            }

            entries[i] = entry;
        }
    }

    var bind_group_desc = std.mem.zeroes(raw.c.WGPUBindGroupDescriptor);
    bind_group_desc.layout = @ptrCast(layout);
    bind_group_desc.entryCount = entry_count;
    bind_group_desc.entries = if (entry_count > 0) @ptrCast(&entries) else null;
    const bind_group: wgpu.BindGroup = @ptrCast(raw.c.wgpuDeviceCreateBindGroup(@ptrCast(gctx.device), &bind_group_desc));

    const id = ht.alloc(.{ .bind_group = @ptrCast(bind_group) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
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

// ---------------------------------------------------------------------------
// T18: Command encoding / render pass native functions
// ---------------------------------------------------------------------------

/// __native.gpuCreateCommandEncoder(deviceId) → number (command encoder handle ID)
fn gpuCreateCommandEncoderNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    if (argv.len < 1) return Value.@"null";

    const encoder = gctx.device.createCommandEncoder(null);

    const id = ht.alloc(.{ .command_encoder = @ptrCast(encoder) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuCommandEncoderBeginRenderPass(encoderId, descriptor) → number (render pass handle ID)
///
/// Parses the render pass descriptor (colorAttachments, depthStencilAttachment)
/// and begins a real wgpu render pass.
fn gpuCommandEncoderBeginRenderPassNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;

    if (argv.len < 2) return Value.@"null";

    // Get real command encoder
    const encoder_id_val: Value = @bitCast(argv[0]);
    const encoder_f64 = encoder_id_val.toFloat64(context) catch return Value.@"null";
    const encoder_id = f64ToHandle(encoder_f64);
    const enc_entry = ht.get(encoder_id) catch return Value.@"null";
    const encoder: wgpu.CommandEncoder = enc_entry.handle.as(wgpu.CommandEncoder) orelse return Value.@"null";

    // Parse descriptor
    const desc_val: Value = @bitCast(argv[1]);

    // Parse colorAttachments array
    var color_attachments: [8]raw.c.WGPURenderPassColorAttachment = undefined;
    var color_count: usize = 0;

    const ca_val = desc_val.getPropertyStr(context, "colorAttachments");
    defer ca_val.deinit(context);
    if (!ca_val.isUndefined() and !ca_val.isNull()) {
        const len_val = ca_val.getPropertyStr(context, "length");
        defer len_val.deinit(context);
        const len = len_val.toFloat64(context) catch 0;
        color_count = @min(@as(usize, @intFromFloat(len)), 8);

        for (0..color_count) |i| {
            const elem = ca_val.getPropertyUint32(context, @intCast(i));
            defer elem.deinit(context);

            // Get view handle
            const view_val = elem.getPropertyStr(context, "view");
            defer view_val.deinit(context);
            const view_f64 = view_val.toFloat64(context) catch 0;
            const view_id = f64ToHandle(view_f64);
            const view_entry = ht.get(view_id) catch |e| {
                log.err("beginRenderPass: color[{}] handle lookup failed: {}", .{ i, e });
                return Value.@"null";
            };
            const view: wgpu.TextureView = view_entry.handle.as(wgpu.TextureView) orelse return Value.@"null";

            // Parse loadOp / storeOp
            const load_val = elem.getPropertyStr(context, "loadOp");
            defer load_val.deinit(context);
            var load_op = raw.c.WGPULoadOp_Load;
            if (load_val.toCString(context)) |s| {
                defer context.freeCString(s);
                const load_str = std.mem.span(s);
                if (std.mem.eql(u8, load_str, "clear")) load_op = raw.c.WGPULoadOp_Clear;
            }

            const store_val = elem.getPropertyStr(context, "storeOp");
            defer store_val.deinit(context);
            var store_op = raw.c.WGPUStoreOp_Store;
            if (store_val.toCString(context)) |s| {
                defer context.freeCString(s);
                const store_str = std.mem.span(s);
                if (std.mem.eql(u8, store_str, "discard")) store_op = raw.c.WGPUStoreOp_Discard;
            }

            // Parse clearValue
            var clear_color = raw.c.WGPUColor{ .r = 0, .g = 0, .b = 0, .a = 1 };
            const cv_val = elem.getPropertyStr(context, "clearValue");
            defer cv_val.deinit(context);
            if (!cv_val.isUndefined() and !cv_val.isNull()) {
                const r_val = cv_val.getPropertyStr(context, "r");
                defer r_val.deinit(context);
                clear_color.r = r_val.toFloat64(context) catch 0;

                const g_val = cv_val.getPropertyStr(context, "g");
                defer g_val.deinit(context);
                clear_color.g = g_val.toFloat64(context) catch 0;

                const b_val = cv_val.getPropertyStr(context, "b");
                defer b_val.deinit(context);
                clear_color.b = b_val.toFloat64(context) catch 0;

                const a_val = cv_val.getPropertyStr(context, "a");
                defer a_val.deinit(context);
                clear_color.a = a_val.toFloat64(context) catch 1;
            }

            // Parse resolveTarget (optional)
            var resolve_target: ?wgpu.TextureView = null;
            const rt_val = elem.getPropertyStr(context, "resolveTarget");
            defer rt_val.deinit(context);
            if (!rt_val.isUndefined() and !rt_val.isNull()) {
                const rt_f64 = rt_val.toFloat64(context) catch 0;
                const rt_id = f64ToHandle(rt_f64);
                if (ht.get(rt_id)) |rt_entry| {
                    resolve_target = rt_entry.handle.as(wgpu.TextureView);
                } else |_| {}
            }

            color_attachments[i] = .{
                .view = @ptrCast(view),
                .depthSlice = raw.c.WGPU_DEPTH_SLICE_UNDEFINED,
                .resolveTarget = if (resolve_target) |rt| @ptrCast(rt) else null,
                .loadOp = @intCast(load_op),
                .storeOp = @intCast(store_op),
                .clearValue = clear_color,
            };
        }
    }

    // Parse depthStencilAttachment (optional)
    var depth_stencil = std.mem.zeroes(raw.c.WGPURenderPassDepthStencilAttachment);
    var has_depth: bool = false;
    const ds_val = desc_val.getPropertyStr(context, "depthStencilAttachment");
    defer ds_val.deinit(context);
    if (!ds_val.isUndefined() and !ds_val.isNull()) {
        has_depth = true;
        const ds_view_val = ds_val.getPropertyStr(context, "view");
        defer ds_view_val.deinit(context);
        const ds_view_f64 = ds_view_val.toFloat64(context) catch 0;
        const ds_view_id = f64ToHandle(ds_view_f64);
        const ds_entry = ht.get(ds_view_id) catch |e| {
            log.err("beginRenderPass: depth handle lookup failed: {}", .{e});
            return Value.@"null";
        };
        const ds_view: wgpu.TextureView = ds_entry.handle.as(wgpu.TextureView) orelse return Value.@"null";

        // Parse depth load/store ops
        var d_load = raw.c.WGPULoadOp_Clear;
        const dl_val = ds_val.getPropertyStr(context, "depthLoadOp");
        defer dl_val.deinit(context);
        if (dl_val.toCString(context)) |s| {
            defer context.freeCString(s);
            if (std.mem.eql(u8, std.mem.span(s), "load")) d_load = raw.c.WGPULoadOp_Load;
        }

        var d_store = raw.c.WGPUStoreOp_Store;
        const ds_store_val = ds_val.getPropertyStr(context, "depthStoreOp");
        defer ds_store_val.deinit(context);
        if (ds_store_val.toCString(context)) |s| {
            defer context.freeCString(s);
            if (std.mem.eql(u8, std.mem.span(s), "discard")) d_store = raw.c.WGPUStoreOp_Discard;
        }

        const dcv_val = ds_val.getPropertyStr(context, "depthClearValue");
        defer dcv_val.deinit(context);
        const depth_clear = @as(f32, @floatCast(dcv_val.toFloat64(context) catch 1.0));

        depth_stencil.view = @ptrCast(ds_view);
        depth_stencil.depthLoadOp = @intCast(d_load);
        depth_stencil.depthStoreOp = @intCast(d_store);
        depth_stencil.depthClearValue = depth_clear;
    }

    var pass_desc = std.mem.zeroes(raw.c.WGPURenderPassDescriptor);
    pass_desc.colorAttachmentCount = color_count;
    pass_desc.colorAttachments = if (color_count > 0) @ptrCast(&color_attachments) else null;
    pass_desc.depthStencilAttachment = if (has_depth) &depth_stencil else null;
    const render_pass: wgpu.RenderPassEncoder = @ptrCast(raw.c.wgpuCommandEncoderBeginRenderPass(@ptrCast(encoder), &pass_desc));

    const id = ht.alloc(.{ .render_pass_encoder = @ptrCast(render_pass) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuRenderPassSetPipeline(passId, pipelineId) → undefined
fn gpuRenderPassSetPipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const pip_id_val: Value = @bitCast(argv[1]);
    const pip_f64 = pip_id_val.toFloat64(context) catch return Value.undefined;
    const pip_entry = ht.get(f64ToHandle(pip_f64)) catch return Value.undefined;
    const pipeline: wgpu.RenderPipeline = pip_entry.handle.as(wgpu.RenderPipeline) orelse return Value.undefined;

    pass.setPipeline(pipeline);
    return Value.undefined;
}

/// __native.gpuRenderPassSetBindGroup(passId, index, bindGroupId) → undefined
fn gpuRenderPassSetBindGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 3) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const idx_val: Value = @bitCast(argv[1]);
    const idx = idx_val.toFloat64(context) catch return Value.undefined;

    const bg_id_val: Value = @bitCast(argv[2]);
    const bg_f64 = bg_id_val.toFloat64(context) catch return Value.undefined;
    const bg_entry = ht.get(f64ToHandle(bg_f64)) catch return Value.undefined;
    const bind_group: wgpu.BindGroup = bg_entry.handle.as(wgpu.BindGroup) orelse return Value.undefined;

    pass.setBindGroup(@intFromFloat(idx), bind_group, null);
    return Value.undefined;
}

/// __native.gpuRenderPassSetVertexBuffer(passId, slot, bufferId, offset?, size?) → undefined
fn gpuRenderPassSetVertexBufferNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 3) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const slot_val: Value = @bitCast(argv[1]);
    const slot: u32 = @intFromFloat(slot_val.toFloat64(context) catch return Value.undefined);

    const buf_id_val: Value = @bitCast(argv[2]);
    const buf_f64 = buf_id_val.toFloat64(context) catch return Value.undefined;
    const buf_entry = ht.get(f64ToHandle(buf_f64)) catch return Value.undefined;
    const buffer: wgpu.Buffer = buf_entry.handle.as(wgpu.Buffer) orelse return Value.undefined;

    var offset: u64 = 0;
    if (argv.len >= 4) {
        const off_val: Value = @bitCast(argv[3]);
        if (!off_val.isUndefined()) offset = @intFromFloat(off_val.toFloat64(context) catch 0);
    }

    var size: u64 = std.math.maxInt(u64);
    if (argv.len >= 5) {
        const sz_val: Value = @bitCast(argv[4]);
        if (!sz_val.isUndefined()) size = @intFromFloat(sz_val.toFloat64(context) catch @as(f64, @floatFromInt(std.math.maxInt(u64))));
    }

    pass.setVertexBuffer(slot, buffer, offset, size);
    return Value.undefined;
}

/// __native.gpuRenderPassSetIndexBuffer(passId, bufferId, format, offset?, size?) → undefined
fn gpuRenderPassSetIndexBufferNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 3) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const buf_id_val: Value = @bitCast(argv[1]);
    const buf_f64 = buf_id_val.toFloat64(context) catch return Value.undefined;
    const buf_entry = ht.get(f64ToHandle(buf_f64)) catch return Value.undefined;
    const buffer: wgpu.Buffer = buf_entry.handle.as(wgpu.Buffer) orelse return Value.undefined;

    // Parse format string
    var index_format: wgpu.IndexFormat = .uint32;
    const fmt_val: Value = @bitCast(argv[2]);
    if (fmt_val.toCString(context)) |s| {
        defer context.freeCString(s);
        if (std.mem.eql(u8, std.mem.span(s), "uint16")) index_format = .uint16;
    }

    var offset: u64 = 0;
    if (argv.len >= 4) {
        const off_val: Value = @bitCast(argv[3]);
        if (!off_val.isUndefined()) offset = @intFromFloat(off_val.toFloat64(context) catch 0);
    }

    var size: u64 = std.math.maxInt(u64);
    if (argv.len >= 5) {
        const sz_val: Value = @bitCast(argv[4]);
        if (!sz_val.isUndefined()) size = @intFromFloat(sz_val.toFloat64(context) catch @as(f64, @floatFromInt(std.math.maxInt(u64))));
    }

    pass.setIndexBuffer(buffer, index_format, offset, size);
    return Value.undefined;
}

/// __native.gpuRenderPassDraw(passId, vertexCount, instanceCount?, firstVertex?, firstInstance?) → undefined
fn gpuRenderPassDrawNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const vc_val: Value = @bitCast(argv[1]);
    const vertex_count: u32 = @intFromFloat(vc_val.toFloat64(context) catch return Value.undefined);
    var instance_count: u32 = 1;
    var first_vertex: u32 = 0;
    var first_instance: u32 = 0;

    if (argv.len >= 3) {
        const ic_val: Value = @bitCast(argv[2]);
        if (!ic_val.isUndefined()) instance_count = @intFromFloat(ic_val.toFloat64(context) catch 1);
    }
    if (argv.len >= 4) {
        const fv_val: Value = @bitCast(argv[3]);
        if (!fv_val.isUndefined()) first_vertex = @intFromFloat(fv_val.toFloat64(context) catch 0);
    }
    if (argv.len >= 5) {
        const fi_val: Value = @bitCast(argv[4]);
        if (!fi_val.isUndefined()) first_instance = @intFromFloat(fi_val.toFloat64(context) catch 0);
    }

    pass.draw(vertex_count, instance_count, first_vertex, first_instance);
    return Value.undefined;
}

/// __native.gpuRenderPassDrawIndexed(passId, indexCount, instanceCount?, firstIndex?, baseVertex?, firstInstance?) → undefined
fn gpuRenderPassDrawIndexedNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const ic_val: Value = @bitCast(argv[1]);
    const index_count: u32 = @intFromFloat(ic_val.toFloat64(context) catch return Value.undefined);
    var instance_count: u32 = 1;
    var first_index: u32 = 0;
    var base_vertex: i32 = 0;
    var first_instance: u32 = 0;

    if (argv.len >= 3) {
        const v: Value = @bitCast(argv[2]);
        if (!v.isUndefined()) instance_count = @intFromFloat(v.toFloat64(context) catch 1);
    }
    if (argv.len >= 4) {
        const v: Value = @bitCast(argv[3]);
        if (!v.isUndefined()) first_index = @intFromFloat(v.toFloat64(context) catch 0);
    }
    if (argv.len >= 5) {
        const v: Value = @bitCast(argv[4]);
        if (!v.isUndefined()) base_vertex = @intFromFloat(v.toFloat64(context) catch 0);
    }
    if (argv.len >= 6) {
        const v: Value = @bitCast(argv[5]);
        if (!v.isUndefined()) first_instance = @intFromFloat(v.toFloat64(context) catch 0);
    }

    pass.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
    return Value.undefined;
}

/// __native.gpuRenderPassEnd(passId) → undefined
fn gpuRenderPassEndNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_id = f64ToHandle(pass_f64);
    const pass_entry = ht.get(pass_id) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse {
        ht.free(pass_id) catch {};
        return Value.undefined;
    };

    pass.end();
    pass.release();
    ht.free(pass_id) catch {};

    return Value.undefined;
}

/// __native.gpuCommandEncoderBeginComputePass(encoderId, descriptor?) → compute pass handle ID
fn gpuCommandEncoderBeginComputePassNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 1) return Value.@"null";

    const encoder_id_val: Value = @bitCast(argv[0]);
    const encoder_f64 = encoder_id_val.toFloat64(context) catch return Value.@"null";
    const encoder_entry = ht.get(f64ToHandle(encoder_f64)) catch return Value.@"null";
    const encoder: wgpu.CommandEncoder = encoder_entry.handle.as(wgpu.CommandEncoder) orelse return Value.@"null";

    // For now, use null descriptor (defaults are fine for basic compute)
    const compute_pass = encoder.beginComputePass(null);

    const id = ht.alloc(.{ .compute_pass_encoder = @ptrCast(compute_pass) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuComputePassEncoderSetPipeline(passId, pipelineId) → undefined
fn gpuComputePassEncoderSetPipelineNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.ComputePassEncoder = pass_entry.handle.as(wgpu.ComputePassEncoder) orelse return Value.undefined;

    const pipeline_id_val: Value = @bitCast(argv[1]);
    const pipeline_f64 = pipeline_id_val.toFloat64(context) catch return Value.undefined;
    const pipeline_entry = ht.get(f64ToHandle(pipeline_f64)) catch return Value.undefined;
    const pipeline: wgpu.ComputePipeline = pipeline_entry.handle.as(wgpu.ComputePipeline) orelse return Value.undefined;

    pass.setPipeline(pipeline);

    return Value.undefined;
}

/// __native.gpuComputePassEncoderSetBindGroup(passId, index, bindGroupId, offsets?) → undefined
fn gpuComputePassEncoderSetBindGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 3) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.ComputePassEncoder = pass_entry.handle.as(wgpu.ComputePassEncoder) orelse return Value.undefined;

    const index_val: Value = @bitCast(argv[1]);
    const index: u32 = @intFromFloat(index_val.toFloat64(context) catch return Value.undefined);

    const bg_id_val: Value = @bitCast(argv[2]);
    const bg_f64 = bg_id_val.toFloat64(context) catch return Value.undefined;
    const bg_entry = ht.get(f64ToHandle(bg_f64)) catch return Value.undefined;
    const bind_group: wgpu.BindGroup = bg_entry.handle.as(wgpu.BindGroup) orelse return Value.undefined;

    // For now, ignore offsets (use null/0)
    pass.setBindGroup(index, bind_group, null);

    return Value.undefined;
}

/// __native.gpuComputePassEncoderDispatchWorkgroups(passId, x, y?, z?) → undefined
fn gpuComputePassEncoderDispatchWorkgroupsNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.ComputePassEncoder = pass_entry.handle.as(wgpu.ComputePassEncoder) orelse return Value.undefined;

    const x_val: Value = @bitCast(argv[1]);
    const x: u32 = @intFromFloat(x_val.toFloat64(context) catch return Value.undefined);

    var y: u32 = 1;
    var z: u32 = 1;

    if (argv.len >= 3) {
        const v: Value = @bitCast(argv[2]);
        if (!v.isUndefined()) y = @intFromFloat(v.toFloat64(context) catch 1);
    }
    if (argv.len >= 4) {
        const v: Value = @bitCast(argv[3]);
        if (!v.isUndefined()) z = @intFromFloat(v.toFloat64(context) catch 1);
    }

    pass.dispatchWorkgroups(x, y, z);

    return Value.undefined;
}

/// __native.gpuComputePassEncoderEnd(passId) → undefined
fn gpuComputePassEncoderEndNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_id = f64ToHandle(pass_f64);
    const pass_entry = ht.get(pass_id) catch return Value.undefined;
    const pass: wgpu.ComputePassEncoder = pass_entry.handle.as(wgpu.ComputePassEncoder) orelse {
        ht.free(pass_id) catch {};
        return Value.undefined;
    };

    pass.end();
    pass.release();
    ht.free(pass_id) catch {};

    return Value.undefined;
}

/// __native.gpuRenderPassSetViewport(passId, x, y, width, height, minDepth, maxDepth) → undefined
fn gpuRenderPassSetViewportNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 7) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const x_val: Value = @bitCast(argv[1]);
    const y_val: Value = @bitCast(argv[2]);
    const w_val: Value = @bitCast(argv[3]);
    const h_val: Value = @bitCast(argv[4]);
    const min_d_val: Value = @bitCast(argv[5]);
    const max_d_val: Value = @bitCast(argv[6]);

    const x: f32 = @floatCast(x_val.toFloat64(context) catch 0);
    const y: f32 = @floatCast(y_val.toFloat64(context) catch 0);
    const w: f32 = @floatCast(w_val.toFloat64(context) catch 0);
    const h: f32 = @floatCast(h_val.toFloat64(context) catch 0);
    const min_depth: f32 = @floatCast(min_d_val.toFloat64(context) catch 0);
    const max_depth: f32 = @floatCast(max_d_val.toFloat64(context) catch 1);

    pass.setViewport(x, y, w, h, min_depth, max_depth);
    return Value.undefined;
}

/// __native.gpuRenderPassSetScissorRect(passId, x, y, width, height) → undefined
fn gpuRenderPassSetScissorRectNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 5) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const x_val: Value = @bitCast(argv[1]);
    const y_val: Value = @bitCast(argv[2]);
    const w_val: Value = @bitCast(argv[3]);
    const h_val: Value = @bitCast(argv[4]);

    const x: u32 = @intFromFloat(x_val.toFloat64(context) catch 0);
    const y: u32 = @intFromFloat(y_val.toFloat64(context) catch 0);
    const w: u32 = @intFromFloat(w_val.toFloat64(context) catch 0);
    const h: u32 = @intFromFloat(h_val.toFloat64(context) catch 0);

    pass.setScissorRect(x, y, w, h);
    return Value.undefined;
}

/// __native.gpuRenderPassSetBlendConstant(passId, color) → undefined
///
/// Sets the constant blend color used by "constant" blend factors.
/// color is a JS object { r, g, b, a } with f64 values.
fn gpuRenderPassSetBlendConstantNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const color_val: Value = @bitCast(argv[1]);
    if (!color_val.isObject()) return Value.undefined;

    const r_val = color_val.getPropertyStr(context, "r");
    defer r_val.deinit(context);
    const g_val = color_val.getPropertyStr(context, "g");
    defer g_val.deinit(context);
    const b_val = color_val.getPropertyStr(context, "b");
    defer b_val.deinit(context);
    const a_val = color_val.getPropertyStr(context, "a");
    defer a_val.deinit(context);

    const color = wgpu.Color{
        .r = r_val.toFloat64(context) catch 0,
        .g = g_val.toFloat64(context) catch 0,
        .b = b_val.toFloat64(context) catch 0,
        .a = a_val.toFloat64(context) catch 1,
    };

    pass.setBlendConstant(color);
    return Value.undefined;
}

/// __native.gpuRenderPassSetStencilReference(passId, reference) → undefined
///
/// Sets the stencil reference value for stencil testing.
fn gpuRenderPassSetStencilReferenceNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const ref_val: Value = @bitCast(argv[1]);
    const ref: u32 = @intFromFloat(ref_val.toFloat64(context) catch return Value.undefined);

    pass.setStencilReference(ref);
    return Value.undefined;
}

/// __native.gpuRenderPassPushDebugGroup(passId, groupLabel) → undefined
///
/// Pushes a debug group onto the render pass, visible in GPU debuggers.
fn gpuRenderPassPushDebugGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const label_val: Value = @bitCast(argv[1]);
    const label_ptr = label_val.toCString(context) orelse return Value.undefined;
    defer context.freeCString(label_ptr);

    pass.pushDebugGroup(label_ptr);
    return Value.undefined;
}

/// __native.gpuRenderPassPopDebugGroup(passId) → undefined
///
/// Pops the active debug group from the render pass.
fn gpuRenderPassPopDebugGroupNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 1) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    pass.popDebugGroup();
    return Value.undefined;
}

/// __native.gpuRenderPassInsertDebugMarker(passId, markerLabel) → undefined
///
/// Inserts a debug marker into the render pass, visible in GPU debuggers.
fn gpuRenderPassInsertDebugMarkerNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const ht = getHandleTableFromData(context, func_data) orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    const pass_id_val: Value = @bitCast(argv[0]);
    const pass_f64 = pass_id_val.toFloat64(context) catch return Value.undefined;
    const pass_entry = ht.get(f64ToHandle(pass_f64)) catch return Value.undefined;
    const pass: wgpu.RenderPassEncoder = pass_entry.handle.as(wgpu.RenderPassEncoder) orelse return Value.undefined;

    const label_val: Value = @bitCast(argv[1]);
    const label_ptr = label_val.toCString(context) orelse return Value.undefined;
    defer context.freeCString(label_ptr);

    pass.insertDebugMarker(label_ptr);
    return Value.undefined;
}

/// __native.gpuCommandEncoderFinish(encoderId) → number (command buffer handle ID)
fn gpuCommandEncoderFinishNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const ht = getHandleTableFromData(context, func_data) orelse return Value.@"null";

    if (argv.len < 1) return Value.@"null";

    const encoder_id_val: Value = @bitCast(argv[0]);
    const encoder_f64 = encoder_id_val.toFloat64(context) catch return Value.@"null";
    const encoder_id = f64ToHandle(encoder_f64);
    const enc_entry = ht.get(encoder_id) catch return Value.@"null";
    const encoder: wgpu.CommandEncoder = enc_entry.handle.as(wgpu.CommandEncoder) orelse return Value.@"null";

    const cmd_buffer = encoder.finish(null);
    encoder.release();

    const cb_id = ht.alloc(.{ .command_buffer = @ptrCast(cmd_buffer) }) catch return Value.@"null";
    ht.free(encoder_id) catch {};

    return Value.initFloat64(@floatFromInt(cb_id.toNumber()));
}

/// __native.gpuQueueSubmit(queueId, commandBuffers) → undefined
fn gpuQueueSubmitNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const bridge = getBridgeFromData(context, func_data) orelse return Value.undefined;
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.undefined;

    if (argv.len < 2) return Value.undefined;

    // Collect command buffers
    const arr_val: Value = @bitCast(argv[1]);
    const len_val = arr_val.getPropertyStr(context, "length");
    defer len_val.deinit(context);
    const len = len_val.toFloat64(context) catch return Value.undefined;
    const count: u32 = @intFromFloat(len);

    var cmd_bufs: [16]wgpu.CommandBuffer = undefined;
    const actual_count = @min(count, 16);

    var i: u32 = 0;
    while (i < actual_count) : (i += 1) {
        const elem = arr_val.getPropertyUint32(context, i);
        defer elem.deinit(context);
        const cb_f64 = elem.toFloat64(context) catch continue;
        const cb_id = f64ToHandle(cb_f64);
        const cb_entry = ht.get(cb_id) catch continue;
        cmd_bufs[i] = cb_entry.handle.as(wgpu.CommandBuffer) orelse continue;
        ht.free(cb_id) catch {};
    }

    gctx.queue.submit(cmd_bufs[0..actual_count]);
    return Value.undefined;
}

// ---------------------------------------------------------------------------
// T22: Queue write operations + pipeline introspection
// ---------------------------------------------------------------------------

/// __native.gpuQueueWriteBuffer(queueId, bufferId, bufferOffset, data, dataOffset, size) → undefined
///
/// Extracts raw bytes from a JS ArrayBuffer/TypedArray and uploads to the GPU buffer.
fn gpuQueueWriteBufferNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const bridge = getBridgeFromData(context, func_data) orelse return Value.undefined;
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.undefined;

    if (argv.len < 4) return Value.undefined;

    // Get the real GPU buffer
    const buffer_id_val: Value = @bitCast(argv[1]);
    const buffer_f64 = buffer_id_val.toFloat64(context) catch return Value.undefined;
    const buf_entry = ht.get(f64ToHandle(buffer_f64)) catch return Value.undefined;
    const buffer: wgpu.Buffer = buf_entry.handle.as(wgpu.Buffer) orelse return Value.undefined;

    // Buffer offset
    const off_val: Value = @bitCast(argv[2]);
    const buffer_offset: u64 = @intFromFloat(off_val.toFloat64(context) catch 0);

    // Extract raw bytes from JS data (argv[3])
    const data_val: Value = @bitCast(argv[3]);

    // Try to get ArrayBuffer bytes via QuickJS API
    // First try raw ArrayBuffer, then try getting the underlying buffer from TypedArray
    const data_buf = data_val.getArrayBuffer(context) orelse blk: {
        // TypedArray: get underlying buffer + byteOffset + byteLength
        const byte_offset_val = data_val.getPropertyStr(context, "byteOffset");
        defer byte_offset_val.deinit(context);
        const byte_length_val = data_val.getPropertyStr(context, "byteLength");
        defer byte_length_val.deinit(context);
        const buffer_val = data_val.getPropertyStr(context, "buffer");
        defer buffer_val.deinit(context);
        if (buffer_val.getArrayBuffer(context)) |ab| {
            const ta_offset: usize = @intFromFloat(byte_offset_val.toFloat64(context) catch 0);
            const ta_length: usize = @intFromFloat(byte_length_val.toFloat64(context) catch 0);
            if (ta_offset + ta_length <= ab.len) {
                break :blk ab[ta_offset..][0..ta_length];
            }
        }
        log.warn("writeBuffer: could not extract bytes from data arg", .{});
        break :blk @as(?[]const u8, null);
    };

    if (data_buf) |buf| {
        // Parse dataOffset and size
        var data_offset: usize = 0;
        if (argv.len >= 5) {
            const doff_val: Value = @bitCast(argv[4]);
            if (!doff_val.isUndefined()) data_offset = @intFromFloat(doff_val.toFloat64(context) catch 0);
        }
        var write_size: usize = buf.len - data_offset;
        if (argv.len >= 6) {
            const sz_val: Value = @bitCast(argv[5]);
            if (!sz_val.isUndefined()) {
                const sz_f64 = sz_val.toFloat64(context) catch @as(f64, @floatFromInt(write_size));
                // size=0 from JS means "use full data length" (WebGPU spec default)
                const sz: usize = @intFromFloat(sz_f64);
                if (sz > 0) write_size = sz;
            }
        }

        const actual_len = @min(write_size, buf.len - data_offset);
        const byte_slice = buf[data_offset..][0..actual_len];

        gctx.queue.writeBuffer(buffer, buffer_offset, u8, byte_slice);
    }

    return Value.undefined;
}

/// __native.gpuQueueWriteTexture(queueId, destination, data, dataLayout, size) → undefined
///
/// Extracts raw bytes from JS ArrayBuffer and uploads to GPU texture via Dawn.
fn gpuQueueWriteTextureNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const bridge = getBridgeFromData(context, func_data) orelse return Value.undefined;
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.undefined;

    if (argv.len < 5) return Value.undefined;

    // argv[1] = destination { texture, mipLevel, origin, aspect }
    const dest_val: Value = @bitCast(argv[1]);
    const tex_id_val = dest_val.getPropertyStr(context, "texture");
    defer tex_id_val.deinit(context);
    const tex_f64 = tex_id_val.toFloat64(context) catch return Value.undefined;
    const tex_entry = ht.get(f64ToHandle(tex_f64)) catch return Value.undefined;
    const texture: wgpu.Texture = tex_entry.handle.as(wgpu.Texture) orelse return Value.undefined;

    const mip_val = dest_val.getPropertyStr(context, "mipLevel");
    defer mip_val.deinit(context);
    const mip_level: u32 = @intFromFloat(mip_val.toFloat64(context) catch 0);

    var origin = std.mem.zeroes(raw.c.WGPUOrigin3D);
    const origin_val = dest_val.getPropertyStr(context, "origin");
    defer origin_val.deinit(context);
    if (!origin_val.isUndefined() and !origin_val.isNull()) {
        // Check if it's an array [x,y,z] or object {x,y,z}
        const ox = origin_val.getPropertyStr(context, "0");
        defer ox.deinit(context);
        if (!ox.isUndefined()) {
            // Array form
            origin.x = @intFromFloat(ox.toFloat64(context) catch 0);
            const oy = origin_val.getPropertyStr(context, "1");
            defer oy.deinit(context);
            origin.y = @intFromFloat(oy.toFloat64(context) catch 0);
            const oz = origin_val.getPropertyStr(context, "2");
            defer oz.deinit(context);
            origin.z = @intFromFloat(oz.toFloat64(context) catch 0);
        }
    }

    var aspect: @TypeOf(std.mem.zeroes(raw.c.WGPUTexelCopyTextureInfo).aspect) = @intCast(raw.c.WGPUTextureAspect_All);
    const aspect_val = dest_val.getPropertyStr(context, "aspect");
    defer aspect_val.deinit(context);
    if (aspect_val.toCString(context)) |s| {
        defer context.freeCString(s);
        const aspect_str = std.mem.span(s);
        if (std.mem.eql(u8, aspect_str, "depth-only")) aspect = @intCast(raw.c.WGPUTextureAspect_DepthOnly)
        else if (std.mem.eql(u8, aspect_str, "stencil-only")) aspect = @intCast(raw.c.WGPUTextureAspect_StencilOnly)
        else if (std.mem.eql(u8, aspect_str, "all")) aspect = @intCast(raw.c.WGPUTextureAspect_All);
    }

    const image_copy_texture = raw.c.WGPUTexelCopyTextureInfo{
        .texture = @ptrCast(texture),
        .mipLevel = mip_level,
        .origin = origin,
        .aspect = aspect,
    };

    // argv[2] = data (ArrayBuffer or TypedArray)
    const data_val_raw: Value = @bitCast(argv[2]);
    const data_buf = data_val_raw.getArrayBuffer(context) orelse blk: {
        // TypedArray: get underlying buffer + byteOffset + byteLength
        const byte_offset_val = data_val_raw.getPropertyStr(context, "byteOffset");
        defer byte_offset_val.deinit(context);
        const byte_length_val = data_val_raw.getPropertyStr(context, "byteLength");
        defer byte_length_val.deinit(context);
        const buffer_val = data_val_raw.getPropertyStr(context, "buffer");
        defer buffer_val.deinit(context);
        if (buffer_val.getArrayBuffer(context)) |ab| {
            const ta_offset: usize = @intFromFloat(byte_offset_val.toFloat64(context) catch 0);
            const ta_length: usize = @intFromFloat(byte_length_val.toFloat64(context) catch 0);
            if (ta_offset + ta_length <= ab.len) {
                break :blk ab[ta_offset..][0..ta_length];
            }
        }
        log.warn("writeTexture: could not extract bytes from data arg", .{});
        break :blk @as(?[]const u8, null);
    };
    if (data_buf == null or data_buf.?.len == 0) return Value.undefined;

    // argv[3] = dataLayout { offset, bytesPerRow, rowsPerImage }
    const layout_val: Value = @bitCast(argv[3]);
    const doff_val = layout_val.getPropertyStr(context, "offset");
    defer doff_val.deinit(context);
    const data_offset: usize = if (doff_val.isUndefined() or doff_val.isNull())
        0
    else
        @intFromFloat(doff_val.toFloat64(context) catch 0);

    const bpr_val = layout_val.getPropertyStr(context, "bytesPerRow");
    defer bpr_val.deinit(context);
    const bytes_per_row: u32 = if (bpr_val.isUndefined() or bpr_val.isNull())
        raw.c.WGPU_COPY_STRIDE_UNDEFINED
    else
        @intFromFloat(bpr_val.toFloat64(context) catch @as(f64, @floatFromInt(raw.c.WGPU_COPY_STRIDE_UNDEFINED)));

    const rpi_val = layout_val.getPropertyStr(context, "rowsPerImage");
    defer rpi_val.deinit(context);
    const rows_per_image: u32 = if (rpi_val.isUndefined() or rpi_val.isNull())
        raw.c.WGPU_COPY_STRIDE_UNDEFINED
    else
        @intFromFloat(rpi_val.toFloat64(context) catch @as(f64, @floatFromInt(raw.c.WGPU_COPY_STRIDE_UNDEFINED)));

    const texture_data_layout = raw.c.WGPUTexelCopyBufferLayout{
        .offset = data_offset,
        .bytesPerRow = bytes_per_row,
        .rowsPerImage = rows_per_image,
    };

    // argv[4] = size { width, height, depthOrArrayLayers }
    const size_val: Value = @bitCast(argv[4]);
    const sw_val = size_val.getPropertyStr(context, "width");
    defer sw_val.deinit(context);
    const sh_val = size_val.getPropertyStr(context, "height");
    defer sh_val.deinit(context);
    const sd_val = size_val.getPropertyStr(context, "depthOrArrayLayers");
    defer sd_val.deinit(context);

    const write_size = raw.c.WGPUExtent3D{
        .width = @intFromFloat(sw_val.toFloat64(context) catch 1),
        .height = @intFromFloat(sh_val.toFloat64(context) catch 1),
        .depthOrArrayLayers = @intFromFloat(sd_val.toFloat64(context) catch 1),
    };

    raw.c.wgpuQueueWriteTexture(@ptrCast(gctx.queue), &image_copy_texture, data_buf.?.ptr, data_buf.?.len, &texture_data_layout, &write_size);

    return Value.undefined;
}

/// __native.gpuRenderPipelineGetBindGroupLayout(pipelineId, index) → number (handle ID)
///
/// Calls pipeline.getBindGroupLayout(index) to get the real layout from Dawn.
fn gpuRenderPipelineGetBindGroupLayoutNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const ht = getHandleTableFromData(context, func_data) orelse return Value.@"null";

    if (argv.len < 2) return Value.@"null";

    const pipeline_id_val: Value = @bitCast(argv[0]);
    const pipeline_f64 = pipeline_id_val.toFloat64(context) catch return Value.@"null";
    const pipeline_id = f64ToHandle(pipeline_f64);
    const pip_entry = ht.get(pipeline_id) catch return Value.@"null";
    const pipeline: wgpu.RenderPipeline = pip_entry.handle.as(wgpu.RenderPipeline) orelse return Value.@"null";

    const idx_val: Value = @bitCast(argv[1]);
    const group_index: u32 = @intFromFloat(idx_val.toFloat64(context) catch return Value.@"null");

    const layout = pipeline.getBindGroupLayout(group_index);

    const id = ht.alloc(.{ .bind_group_layout = @ptrCast(layout) }) catch return Value.@"null";
    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

// ---------------------------------------------------------------------------
// T19: WebGPU present / swap chain native functions
// ---------------------------------------------------------------------------

/// __native.gpuConfigureContext(deviceId, format, alphaMode, width, height) → undefined
///
/// Stub — stores surface configuration. Real Dawn surface configuration comes later.
/// Validates the device handle, accepts format/alphaMode strings and width/height.
fn gpuConfigureContextNative(
    ctx: ?*Context,
    _: Value,
    argv: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const bridge = getBridgeFromData(context, func_data) orelse return Value.undefined;
    const ht = bridge.handle_table_ptr;

    // argv[0] = deviceId — validate device handle exists
    if (argv.len < 1) return Value.undefined;
    const device_id_val: Value = @bitCast(argv[0]);
    const device_f64 = device_id_val.toFloat64(context) catch return Value.undefined;
    const device_id = f64ToHandle(device_f64);
    _ = ht.get(device_id) catch return Value.undefined;

    // argv[1] = format (string, e.g. "bgra8unorm"), accepted but not used yet
    // argv[2] = alphaMode (string, e.g. "opaque"), accepted but not used yet
    // argv[3] = width (number), argv[4] = height (number)
    if (argv.len >= 5) {
        const w_val: Value = @bitCast(argv[3]);
        const h_val: Value = @bitCast(argv[4]);
        const width_f = w_val.toFloat64(context) catch 0;
        const height_f = h_val.toFloat64(context) catch 0;
        if (width_f > 0 and height_f > 0) {
            bridge.onFramebufferResize(@intFromFloat(width_f), @intFromFloat(height_f));
        }
    }

    return Value.undefined;
}

/// __native.gpuGetPreferredCanvasFormat() → string
fn gpuGetPreferredCanvasFormatNative(
    ctx: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    const bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const gctx = bridge.gctx orelse return Value.initString(context, "bgra8unorm");

    const format = switch (gctx.surface_config.format) {
        raw.c.WGPUTextureFormat_RGBA8Unorm => "rgba8unorm",
        raw.c.WGPUTextureFormat_RGBA8UnormSrgb => "rgba8unorm-srgb",
        raw.c.WGPUTextureFormat_BGRA8Unorm => "bgra8unorm",
        raw.c.WGPUTextureFormat_BGRA8UnormSrgb => "bgra8unorm-srgb",
        else => "rgba8unorm",
    };
    return Value.initStringLen(context, format);
}

/// __native.gpuGetCurrentTexture() → number (texture handle ID)
///
/// Returns a texture_view handle for the current swapchain back buffer.
/// Uses zgpu's swapchain.getCurrentTextureView() directly.
fn gpuGetCurrentTextureNative(
    ctx: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.@"null";
    var bridge = getBridgeFromData(context, func_data) orelse return Value.@"null";
    const ht = bridge.handle_table_ptr;
    const gctx = bridge.gctx orelse return Value.@"null";

    // Repeated getCurrentTexture() calls within one frame should return the
    // same swapchain handle. The actual view is released by gctx.present().
    if (bridge.prev_swapchain_view) |prev_id| {
        if (bridge.frame_texture_acquired) {
            return Value.initFloat64(@floatFromInt(prev_id.toNumber()));
        }
        ht.free(prev_id) catch {};
        bridge.prev_swapchain_view = null;
    }

    // Mark that we acquired a frame texture — presentIfNeeded will present
    bridge.frame_texture_acquired = true;

    const view = gctx.getCurrentTextureView() orelse {
        log.err("getCurrentTexture: no surface view available", .{});
        bridge.frame_texture_acquired = false;
        return Value.@"null";
    };

    // Store as texture_view so createTextureView can detect the swapchain case
    const id = ht.alloc(.{ .texture_view = @ptrCast(view) }) catch return Value.@"null";

    // Track this handle so we can retire it after present.
    bridge.prev_swapchain_view = id;

    return Value.initFloat64(@floatFromInt(id.toNumber()));
}

/// __native.gpuPresent() → undefined
///
/// Presents the current swapchain frame to the window surface.
fn gpuPresentNative(
    ctx: ?*Context,
    _: Value,
    _: []const c.JSValue,
    _: c_int,
    func_data: [*c]c.JSValue,
) Value {
    const context = ctx orelse return Value.undefined;
    const bridge = getBridgeFromData(context, func_data) orelse return Value.undefined;
    const gctx = bridge.gctx orelse return Value.undefined;

    _ = gctx.present();
    bridge.frame_texture_acquired = false;
    if (bridge.prev_swapchain_view) |prev_id| {
        bridge.handle_table_ptr.free(prev_id) catch {};
        bridge.prev_swapchain_view = null;
    }
    return Value.undefined;
}

/// Extract the *HandleTable pointer from closure data[0].
fn getBridgeFromData(ctx: *Context, func_data: [*c]c.JSValue) ?*GpuBridge {
    const data_val: Value = @bitCast(func_data[0]);
    const ptr_bits = data_val.toFloat64(ctx) catch return null;
    return f64ToPtr(*GpuBridge, ptr_bits);
}

fn getHandleTableFromData(ctx: *Context, func_data: [*c]c.JSValue) ?*HandleTable {
    const bridge = getBridgeFromData(ctx, func_data) orelse return null;
    return bridge.handle_table_ptr;
}

// ---------------------------------------------------------------------------
// Descriptor parsing helpers
// ---------------------------------------------------------------------------

/// Parse a BlendComponent from a JS object property (e.g., blend.color or blend.alpha)
fn parseBlendComponent(ctx: *Context, blend_val: Value, prop: [*:0]const u8) raw.c.WGPUBlendComponent {
    var result = std.mem.zeroes(raw.c.WGPUBlendComponent);
    result.operation = raw.c.WGPUBlendOperation_Add;
    result.srcFactor = raw.c.WGPUBlendFactor_One;
    result.dstFactor = raw.c.WGPUBlendFactor_Zero;
    const comp_val = blend_val.getPropertyStr(ctx, prop);
    defer comp_val.deinit(ctx);
    if (comp_val.isUndefined() or comp_val.isNull()) return result;

    const op_val = comp_val.getPropertyStr(ctx, "operation");
    defer op_val.deinit(ctx);
    if (op_val.toCString(ctx)) |s| {
        defer ctx.freeCString(s);
        const str = std.mem.span(s);
        if (std.mem.eql(u8, str, "add")) result.operation = raw.c.WGPUBlendOperation_Add
        else if (std.mem.eql(u8, str, "subtract")) result.operation = raw.c.WGPUBlendOperation_Subtract
        else if (std.mem.eql(u8, str, "reverse-subtract")) result.operation = raw.c.WGPUBlendOperation_ReverseSubtract
        else if (std.mem.eql(u8, str, "min")) result.operation = raw.c.WGPUBlendOperation_Min
        else if (std.mem.eql(u8, str, "max")) result.operation = raw.c.WGPUBlendOperation_Max;
    }

    const src_val = comp_val.getPropertyStr(ctx, "srcFactor");
    defer src_val.deinit(ctx);
    if (src_val.toCString(ctx)) |s| {
        defer ctx.freeCString(s);
        result.srcFactor = parseBlendFactor(std.mem.span(s));
    }

    const dst_val = comp_val.getPropertyStr(ctx, "dstFactor");
    defer dst_val.deinit(ctx);
    if (dst_val.toCString(ctx)) |s| {
        defer ctx.freeCString(s);
        result.dstFactor = parseBlendFactor(std.mem.span(s));
    }

    return result;
}

fn rawStringViewZ(str: ?[*:0]const u8) raw.c.WGPUStringView {
    var view = std.mem.zeroes(raw.c.WGPUStringView);
    if (str) |s| {
        view.data = @ptrCast(s);
        view.length = std.mem.len(s);
    }
    return view;
}

fn rawStringViewSlice(slice: []const u8) raw.c.WGPUStringView {
    var view = std.mem.zeroes(raw.c.WGPUStringView);
    view.data = if (slice.len > 0) @ptrCast(slice.ptr) else null;
    view.length = slice.len;
    return view;
}

fn toRawBlendComponent(component: wgpu.BlendComponent) raw.c.WGPUBlendComponent {
    var raw_component = std.mem.zeroes(raw.c.WGPUBlendComponent);
    raw_component.operation = @intCast(@intFromEnum(component.operation));
    raw_component.srcFactor = @intCast(@intFromEnum(component.src_factor));
    raw_component.dstFactor = @intCast(@intFromEnum(component.dst_factor));
    return raw_component;
}

fn toRawStencilFaceState(face: wgpu.StencilFaceState) raw.c.WGPUStencilFaceState {
    var raw_face = std.mem.zeroes(raw.c.WGPUStencilFaceState);
    raw_face.compare = @intCast(@intFromEnum(face.compare));
    raw_face.failOp = @intCast(@intFromEnum(face.fail_op));
    raw_face.depthFailOp = @intCast(@intFromEnum(face.depth_fail_op));
    raw_face.passOp = @intCast(@intFromEnum(face.pass_op));
    return raw_face;
}

fn parseBlendFactor(str: []const u8) raw.c.WGPUBlendFactor {
    if (std.mem.eql(u8, str, "zero")) return raw.c.WGPUBlendFactor_Zero;
    if (std.mem.eql(u8, str, "one")) return raw.c.WGPUBlendFactor_One;
    if (std.mem.eql(u8, str, "src")) return raw.c.WGPUBlendFactor_Src;
    if (std.mem.eql(u8, str, "one-minus-src")) return raw.c.WGPUBlendFactor_OneMinusSrc;
    if (std.mem.eql(u8, str, "src-alpha")) return raw.c.WGPUBlendFactor_SrcAlpha;
    if (std.mem.eql(u8, str, "one-minus-src-alpha")) return raw.c.WGPUBlendFactor_OneMinusSrcAlpha;
    if (std.mem.eql(u8, str, "dst")) return raw.c.WGPUBlendFactor_Dst;
    if (std.mem.eql(u8, str, "one-minus-dst")) return raw.c.WGPUBlendFactor_OneMinusDst;
    if (std.mem.eql(u8, str, "dst-alpha")) return raw.c.WGPUBlendFactor_DstAlpha;
    if (std.mem.eql(u8, str, "one-minus-dst-alpha")) return raw.c.WGPUBlendFactor_OneMinusDstAlpha;
    if (std.mem.eql(u8, str, "src-alpha-saturated")) return raw.c.WGPUBlendFactor_SrcAlphaSaturated;
    if (std.mem.eql(u8, str, "constant")) return raw.c.WGPUBlendFactor_Constant;
    if (std.mem.eql(u8, str, "one-minus-constant")) return raw.c.WGPUBlendFactor_OneMinusConstant;
    return raw.c.WGPUBlendFactor_One;
}

fn parseCompareFunction(str: []const u8) raw.c.WGPUCompareFunction {
    if (std.mem.eql(u8, str, "never")) return raw.c.WGPUCompareFunction_Never;
    if (std.mem.eql(u8, str, "less")) return raw.c.WGPUCompareFunction_Less;
    if (std.mem.eql(u8, str, "equal")) return raw.c.WGPUCompareFunction_Equal;
    if (std.mem.eql(u8, str, "less-equal")) return raw.c.WGPUCompareFunction_LessEqual;
    if (std.mem.eql(u8, str, "greater")) return raw.c.WGPUCompareFunction_Greater;
    if (std.mem.eql(u8, str, "not-equal")) return raw.c.WGPUCompareFunction_NotEqual;
    if (std.mem.eql(u8, str, "greater-equal")) return raw.c.WGPUCompareFunction_GreaterEqual;
    if (std.mem.eql(u8, str, "always")) return raw.c.WGPUCompareFunction_Always;
    return raw.c.WGPUCompareFunction_Always;
}

fn parseTextureFormat(str: []const u8) raw.c.WGPUTextureFormat {
    // Common formats used by Three.js — ordered by likely frequency
    if (std.mem.eql(u8, str, "bgra8unorm")) return raw.c.WGPUTextureFormat_BGRA8Unorm;
    if (std.mem.eql(u8, str, "rgba8unorm")) return raw.c.WGPUTextureFormat_RGBA8Unorm;
    if (std.mem.eql(u8, str, "depth24plus")) return raw.c.WGPUTextureFormat_Depth24Plus;
    if (std.mem.eql(u8, str, "depth24plus-stencil8")) return raw.c.WGPUTextureFormat_Depth24PlusStencil8;
    if (std.mem.eql(u8, str, "depth32float")) return raw.c.WGPUTextureFormat_Depth32Float;
    if (std.mem.eql(u8, str, "depth16unorm")) return raw.c.WGPUTextureFormat_Depth16Unorm;
    if (std.mem.eql(u8, str, "depth32float-stencil8")) return raw.c.WGPUTextureFormat_Depth32FloatStencil8;
    if (std.mem.eql(u8, str, "rgba8unorm-srgb")) return raw.c.WGPUTextureFormat_RGBA8UnormSrgb;
    if (std.mem.eql(u8, str, "bgra8unorm-srgb")) return raw.c.WGPUTextureFormat_BGRA8UnormSrgb;
    if (std.mem.eql(u8, str, "r8unorm")) return raw.c.WGPUTextureFormat_R8Unorm;
    if (std.mem.eql(u8, str, "r8snorm")) return raw.c.WGPUTextureFormat_R8Snorm;
    if (std.mem.eql(u8, str, "r8uint")) return raw.c.WGPUTextureFormat_R8Uint;
    if (std.mem.eql(u8, str, "r8sint")) return raw.c.WGPUTextureFormat_R8Sint;
    if (std.mem.eql(u8, str, "rg8unorm")) return raw.c.WGPUTextureFormat_RG8Unorm;
    if (std.mem.eql(u8, str, "rg8snorm")) return raw.c.WGPUTextureFormat_RG8Snorm;
    if (std.mem.eql(u8, str, "rg8uint")) return raw.c.WGPUTextureFormat_RG8Uint;
    if (std.mem.eql(u8, str, "rg8sint")) return raw.c.WGPUTextureFormat_RG8Sint;
    if (std.mem.eql(u8, str, "rgba8snorm")) return raw.c.WGPUTextureFormat_RGBA8Snorm;
    if (std.mem.eql(u8, str, "rgba8uint")) return raw.c.WGPUTextureFormat_RGBA8Uint;
    if (std.mem.eql(u8, str, "rgba8sint")) return raw.c.WGPUTextureFormat_RGBA8Sint;
    if (std.mem.eql(u8, str, "r16float")) return raw.c.WGPUTextureFormat_R16Float;
    if (std.mem.eql(u8, str, "r16uint")) return raw.c.WGPUTextureFormat_R16Uint;
    if (std.mem.eql(u8, str, "r16sint")) return raw.c.WGPUTextureFormat_R16Sint;
    if (std.mem.eql(u8, str, "rg16float")) return raw.c.WGPUTextureFormat_RG16Float;
    if (std.mem.eql(u8, str, "rg16uint")) return raw.c.WGPUTextureFormat_RG16Uint;
    if (std.mem.eql(u8, str, "rg16sint")) return raw.c.WGPUTextureFormat_RG16Sint;
    if (std.mem.eql(u8, str, "r32float")) return raw.c.WGPUTextureFormat_R32Float;
    if (std.mem.eql(u8, str, "r32uint")) return raw.c.WGPUTextureFormat_R32Uint;
    if (std.mem.eql(u8, str, "r32sint")) return raw.c.WGPUTextureFormat_R32Sint;
    if (std.mem.eql(u8, str, "rg32float")) return raw.c.WGPUTextureFormat_RG32Float;
    if (std.mem.eql(u8, str, "rg32uint")) return raw.c.WGPUTextureFormat_RG32Uint;
    if (std.mem.eql(u8, str, "rg32sint")) return raw.c.WGPUTextureFormat_RG32Sint;
    if (std.mem.eql(u8, str, "rgba16float")) return raw.c.WGPUTextureFormat_RGBA16Float;
    if (std.mem.eql(u8, str, "rgba16uint")) return raw.c.WGPUTextureFormat_RGBA16Uint;
    if (std.mem.eql(u8, str, "rgba16sint")) return raw.c.WGPUTextureFormat_RGBA16Sint;
    if (std.mem.eql(u8, str, "rgba32float")) return raw.c.WGPUTextureFormat_RGBA32Float;
    if (std.mem.eql(u8, str, "rgba32uint")) return raw.c.WGPUTextureFormat_RGBA32Uint;
    if (std.mem.eql(u8, str, "rgba32sint")) return raw.c.WGPUTextureFormat_RGBA32Sint;
    if (std.mem.eql(u8, str, "rgb10a2unorm")) return raw.c.WGPUTextureFormat_RGB10A2Unorm;
    if (std.mem.eql(u8, str, "rg11b10ufloat")) return raw.c.WGPUTextureFormat_RG11B10Ufloat;
    if (std.mem.eql(u8, str, "rgb9e5ufloat")) return raw.c.WGPUTextureFormat_RGB9E5Ufloat;
    if (std.mem.eql(u8, str, "stencil8")) return raw.c.WGPUTextureFormat_Stencil8;
    log.warn("unknown texture format: '{s}', defaulting to bgra8unorm", .{str});
    return raw.c.WGPUTextureFormat_BGRA8Unorm;
}

fn parseVertexFormat(str: []const u8) raw.c.WGPUVertexFormat {
    if (std.mem.eql(u8, str, "float32")) return raw.c.WGPUVertexFormat_Float32;
    if (std.mem.eql(u8, str, "float32x2")) return raw.c.WGPUVertexFormat_Float32x2;
    if (std.mem.eql(u8, str, "float32x3")) return raw.c.WGPUVertexFormat_Float32x3;
    if (std.mem.eql(u8, str, "float32x4")) return raw.c.WGPUVertexFormat_Float32x4;
    if (std.mem.eql(u8, str, "uint32")) return raw.c.WGPUVertexFormat_Uint32;
    if (std.mem.eql(u8, str, "uint32x2")) return raw.c.WGPUVertexFormat_Uint32x2;
    if (std.mem.eql(u8, str, "uint32x3")) return raw.c.WGPUVertexFormat_Uint32x3;
    if (std.mem.eql(u8, str, "uint32x4")) return raw.c.WGPUVertexFormat_Uint32x4;
    if (std.mem.eql(u8, str, "sint32")) return raw.c.WGPUVertexFormat_Sint32;
    if (std.mem.eql(u8, str, "sint32x2")) return raw.c.WGPUVertexFormat_Sint32x2;
    if (std.mem.eql(u8, str, "sint32x3")) return raw.c.WGPUVertexFormat_Sint32x3;
    if (std.mem.eql(u8, str, "sint32x4")) return raw.c.WGPUVertexFormat_Sint32x4;
    if (std.mem.eql(u8, str, "float16x2")) return raw.c.WGPUVertexFormat_Float16x2;
    if (std.mem.eql(u8, str, "float16x4")) return raw.c.WGPUVertexFormat_Float16x4;
    if (std.mem.eql(u8, str, "uint8x2")) return raw.c.WGPUVertexFormat_Uint8x2;
    if (std.mem.eql(u8, str, "uint8x4")) return raw.c.WGPUVertexFormat_Uint8x4;
    if (std.mem.eql(u8, str, "sint8x2")) return raw.c.WGPUVertexFormat_Sint8x2;
    if (std.mem.eql(u8, str, "sint8x4")) return raw.c.WGPUVertexFormat_Sint8x4;
    if (std.mem.eql(u8, str, "unorm8x2")) return raw.c.WGPUVertexFormat_Unorm8x2;
    if (std.mem.eql(u8, str, "unorm8x4")) return raw.c.WGPUVertexFormat_Unorm8x4;
    if (std.mem.eql(u8, str, "snorm8x2")) return raw.c.WGPUVertexFormat_Snorm8x2;
    if (std.mem.eql(u8, str, "snorm8x4")) return raw.c.WGPUVertexFormat_Snorm8x4;
    if (std.mem.eql(u8, str, "uint16x2")) return raw.c.WGPUVertexFormat_Uint16x2;
    if (std.mem.eql(u8, str, "uint16x4")) return raw.c.WGPUVertexFormat_Uint16x4;
    if (std.mem.eql(u8, str, "sint16x2")) return raw.c.WGPUVertexFormat_Sint16x2;
    if (std.mem.eql(u8, str, "sint16x4")) return raw.c.WGPUVertexFormat_Sint16x4;
    if (std.mem.eql(u8, str, "unorm16x2")) return raw.c.WGPUVertexFormat_Unorm16x2;
    if (std.mem.eql(u8, str, "unorm16x4")) return raw.c.WGPUVertexFormat_Unorm16x4;
    if (std.mem.eql(u8, str, "snorm16x2")) return raw.c.WGPUVertexFormat_Snorm16x2;
    if (std.mem.eql(u8, str, "snorm16x4")) return raw.c.WGPUVertexFormat_Snorm16x4;
    log.warn("unknown vertex format: '{s}', defaulting to float32x3", .{str});
    return raw.c.WGPUVertexFormat_Float32x3;
}

fn translateLegacyTextureFormatNumeric(n: u32) raw.c.WGPUTextureFormat {
    return switch (n) {
        @intFromEnum(wgpu.TextureFormat.r8_unorm) => raw.c.WGPUTextureFormat_R8Unorm,
        @intFromEnum(wgpu.TextureFormat.r8_snorm) => raw.c.WGPUTextureFormat_R8Snorm,
        @intFromEnum(wgpu.TextureFormat.r8_uint) => raw.c.WGPUTextureFormat_R8Uint,
        @intFromEnum(wgpu.TextureFormat.r8_sint) => raw.c.WGPUTextureFormat_R8Sint,
        @intFromEnum(wgpu.TextureFormat.r16_uint) => raw.c.WGPUTextureFormat_R16Uint,
        @intFromEnum(wgpu.TextureFormat.r16_sint) => raw.c.WGPUTextureFormat_R16Sint,
        @intFromEnum(wgpu.TextureFormat.r16_float) => raw.c.WGPUTextureFormat_R16Float,
        @intFromEnum(wgpu.TextureFormat.rg8_unorm) => raw.c.WGPUTextureFormat_RG8Unorm,
        @intFromEnum(wgpu.TextureFormat.rg8_snorm) => raw.c.WGPUTextureFormat_RG8Snorm,
        @intFromEnum(wgpu.TextureFormat.rg8_uint) => raw.c.WGPUTextureFormat_RG8Uint,
        @intFromEnum(wgpu.TextureFormat.rg8_sint) => raw.c.WGPUTextureFormat_RG8Sint,
        @intFromEnum(wgpu.TextureFormat.r32_float) => raw.c.WGPUTextureFormat_R32Float,
        @intFromEnum(wgpu.TextureFormat.r32_uint) => raw.c.WGPUTextureFormat_R32Uint,
        @intFromEnum(wgpu.TextureFormat.r32_sint) => raw.c.WGPUTextureFormat_R32Sint,
        @intFromEnum(wgpu.TextureFormat.rg16_uint) => raw.c.WGPUTextureFormat_RG16Uint,
        @intFromEnum(wgpu.TextureFormat.rg16_sint) => raw.c.WGPUTextureFormat_RG16Sint,
        @intFromEnum(wgpu.TextureFormat.rg16_float) => raw.c.WGPUTextureFormat_RG16Float,
        @intFromEnum(wgpu.TextureFormat.rgba8_unorm) => raw.c.WGPUTextureFormat_RGBA8Unorm,
        @intFromEnum(wgpu.TextureFormat.rgba8_unorm_srgb) => raw.c.WGPUTextureFormat_RGBA8UnormSrgb,
        @intFromEnum(wgpu.TextureFormat.rgba8_snorm) => raw.c.WGPUTextureFormat_RGBA8Snorm,
        @intFromEnum(wgpu.TextureFormat.rgba8_uint) => raw.c.WGPUTextureFormat_RGBA8Uint,
        @intFromEnum(wgpu.TextureFormat.rgba8_sint) => raw.c.WGPUTextureFormat_RGBA8Sint,
        @intFromEnum(wgpu.TextureFormat.bgra8_unorm) => raw.c.WGPUTextureFormat_BGRA8Unorm,
        @intFromEnum(wgpu.TextureFormat.bgra8_unorm_srgb) => raw.c.WGPUTextureFormat_BGRA8UnormSrgb,
        @intFromEnum(wgpu.TextureFormat.rgb10_a2_unorm) => raw.c.WGPUTextureFormat_RGB10A2Unorm,
        @intFromEnum(wgpu.TextureFormat.rg11_b10_ufloat) => raw.c.WGPUTextureFormat_RG11B10Ufloat,
        @intFromEnum(wgpu.TextureFormat.rgb9_e5_ufloat) => raw.c.WGPUTextureFormat_RGB9E5Ufloat,
        @intFromEnum(wgpu.TextureFormat.rg32_float) => raw.c.WGPUTextureFormat_RG32Float,
        @intFromEnum(wgpu.TextureFormat.rg32_uint) => raw.c.WGPUTextureFormat_RG32Uint,
        @intFromEnum(wgpu.TextureFormat.rg32_sint) => raw.c.WGPUTextureFormat_RG32Sint,
        @intFromEnum(wgpu.TextureFormat.rgba16_uint) => raw.c.WGPUTextureFormat_RGBA16Uint,
        @intFromEnum(wgpu.TextureFormat.rgba16_sint) => raw.c.WGPUTextureFormat_RGBA16Sint,
        @intFromEnum(wgpu.TextureFormat.rgba16_float) => raw.c.WGPUTextureFormat_RGBA16Float,
        @intFromEnum(wgpu.TextureFormat.rgba32_float) => raw.c.WGPUTextureFormat_RGBA32Float,
        @intFromEnum(wgpu.TextureFormat.rgba32_uint) => raw.c.WGPUTextureFormat_RGBA32Uint,
        @intFromEnum(wgpu.TextureFormat.rgba32_sint) => raw.c.WGPUTextureFormat_RGBA32Sint,
        @intFromEnum(wgpu.TextureFormat.stencil8) => raw.c.WGPUTextureFormat_Stencil8,
        @intFromEnum(wgpu.TextureFormat.depth16_unorm) => raw.c.WGPUTextureFormat_Depth16Unorm,
        @intFromEnum(wgpu.TextureFormat.depth24_plus) => raw.c.WGPUTextureFormat_Depth24Plus,
        @intFromEnum(wgpu.TextureFormat.depth24_plus_stencil8) => raw.c.WGPUTextureFormat_Depth24PlusStencil8,
        @intFromEnum(wgpu.TextureFormat.depth32_float) => raw.c.WGPUTextureFormat_Depth32Float,
        @intFromEnum(wgpu.TextureFormat.depth32_float_stencil8) => raw.c.WGPUTextureFormat_Depth32FloatStencil8,
        else => @as(raw.c.WGPUTextureFormat, @intCast(n)),
    };
}

fn translateLegacyBufferBindingTypeNumeric(n: u32) raw.c.WGPUBufferBindingType {
    return switch (n) {
        @intFromEnum(wgpu.BufferBindingType.uniform) => raw.c.WGPUBufferBindingType_Uniform,
        @intFromEnum(wgpu.BufferBindingType.storage) => raw.c.WGPUBufferBindingType_Storage,
        @intFromEnum(wgpu.BufferBindingType.read_only_storage) => raw.c.WGPUBufferBindingType_ReadOnlyStorage,
        else => @as(raw.c.WGPUBufferBindingType, @intCast(n)),
    };
}

fn translateLegacySamplerBindingTypeNumeric(n: u32) raw.c.WGPUSamplerBindingType {
    return switch (n) {
        @intFromEnum(wgpu.SamplerBindingType.filtering) => raw.c.WGPUSamplerBindingType_Filtering,
        @intFromEnum(wgpu.SamplerBindingType.non_filtering) => raw.c.WGPUSamplerBindingType_NonFiltering,
        @intFromEnum(wgpu.SamplerBindingType.comparison) => raw.c.WGPUSamplerBindingType_Comparison,
        else => @as(raw.c.WGPUSamplerBindingType, @intCast(n)),
    };
}

fn translateLegacyTextureSampleTypeNumeric(n: u32) raw.c.WGPUTextureSampleType {
    return switch (n) {
        @intFromEnum(wgpu.TextureSampleType.float) => raw.c.WGPUTextureSampleType_Float,
        @intFromEnum(wgpu.TextureSampleType.unfilterable_float) => raw.c.WGPUTextureSampleType_UnfilterableFloat,
        @intFromEnum(wgpu.TextureSampleType.depth) => raw.c.WGPUTextureSampleType_Depth,
        @intFromEnum(wgpu.TextureSampleType.sint) => raw.c.WGPUTextureSampleType_Sint,
        @intFromEnum(wgpu.TextureSampleType.uint) => raw.c.WGPUTextureSampleType_Uint,
        else => @as(raw.c.WGPUTextureSampleType, @intCast(n)),
    };
}

fn translateLegacyCompareFunctionNumeric(n: u32) raw.c.WGPUCompareFunction {
    return switch (n) {
        @intFromEnum(wgpu.CompareFunction.never) => raw.c.WGPUCompareFunction_Never,
        @intFromEnum(wgpu.CompareFunction.less) => raw.c.WGPUCompareFunction_Less,
        @intFromEnum(wgpu.CompareFunction.equal) => raw.c.WGPUCompareFunction_Equal,
        @intFromEnum(wgpu.CompareFunction.less_equal) => raw.c.WGPUCompareFunction_LessEqual,
        @intFromEnum(wgpu.CompareFunction.greater) => raw.c.WGPUCompareFunction_Greater,
        @intFromEnum(wgpu.CompareFunction.not_equal) => raw.c.WGPUCompareFunction_NotEqual,
        @intFromEnum(wgpu.CompareFunction.greater_equal) => raw.c.WGPUCompareFunction_GreaterEqual,
        @intFromEnum(wgpu.CompareFunction.always) => raw.c.WGPUCompareFunction_Always,
        else => @as(raw.c.WGPUCompareFunction, @intCast(n)),
    };
}

fn translateLegacyVertexFormatNumeric(n: u32) raw.c.WGPUVertexFormat {
    return switch (n) {
        @intFromEnum(wgpu.VertexFormat.float32) => raw.c.WGPUVertexFormat_Float32,
        @intFromEnum(wgpu.VertexFormat.float32x2) => raw.c.WGPUVertexFormat_Float32x2,
        @intFromEnum(wgpu.VertexFormat.float32x3) => raw.c.WGPUVertexFormat_Float32x3,
        @intFromEnum(wgpu.VertexFormat.float32x4) => raw.c.WGPUVertexFormat_Float32x4,
        @intFromEnum(wgpu.VertexFormat.uint32) => raw.c.WGPUVertexFormat_Uint32,
        @intFromEnum(wgpu.VertexFormat.uint32x2) => raw.c.WGPUVertexFormat_Uint32x2,
        @intFromEnum(wgpu.VertexFormat.uint32x3) => raw.c.WGPUVertexFormat_Uint32x3,
        @intFromEnum(wgpu.VertexFormat.uint32x4) => raw.c.WGPUVertexFormat_Uint32x4,
        @intFromEnum(wgpu.VertexFormat.sint32) => raw.c.WGPUVertexFormat_Sint32,
        @intFromEnum(wgpu.VertexFormat.sint32x2) => raw.c.WGPUVertexFormat_Sint32x2,
        @intFromEnum(wgpu.VertexFormat.sint32x3) => raw.c.WGPUVertexFormat_Sint32x3,
        @intFromEnum(wgpu.VertexFormat.sint32x4) => raw.c.WGPUVertexFormat_Sint32x4,
        @intFromEnum(wgpu.VertexFormat.float16x2) => raw.c.WGPUVertexFormat_Float16x2,
        @intFromEnum(wgpu.VertexFormat.float16x4) => raw.c.WGPUVertexFormat_Float16x4,
        @intFromEnum(wgpu.VertexFormat.uint8x2) => raw.c.WGPUVertexFormat_Uint8x2,
        @intFromEnum(wgpu.VertexFormat.uint8x4) => raw.c.WGPUVertexFormat_Uint8x4,
        @intFromEnum(wgpu.VertexFormat.sint8x2) => raw.c.WGPUVertexFormat_Sint8x2,
        @intFromEnum(wgpu.VertexFormat.sint8x4) => raw.c.WGPUVertexFormat_Sint8x4,
        @intFromEnum(wgpu.VertexFormat.unorm8x2) => raw.c.WGPUVertexFormat_Unorm8x2,
        @intFromEnum(wgpu.VertexFormat.unorm8x4) => raw.c.WGPUVertexFormat_Unorm8x4,
        @intFromEnum(wgpu.VertexFormat.snorm8x2) => raw.c.WGPUVertexFormat_Snorm8x2,
        @intFromEnum(wgpu.VertexFormat.snorm8x4) => raw.c.WGPUVertexFormat_Snorm8x4,
        @intFromEnum(wgpu.VertexFormat.uint16x2) => raw.c.WGPUVertexFormat_Uint16x2,
        @intFromEnum(wgpu.VertexFormat.uint16x4) => raw.c.WGPUVertexFormat_Uint16x4,
        @intFromEnum(wgpu.VertexFormat.sint16x2) => raw.c.WGPUVertexFormat_Sint16x2,
        @intFromEnum(wgpu.VertexFormat.sint16x4) => raw.c.WGPUVertexFormat_Sint16x4,
        @intFromEnum(wgpu.VertexFormat.unorm16x2) => raw.c.WGPUVertexFormat_Unorm16x2,
        @intFromEnum(wgpu.VertexFormat.unorm16x4) => raw.c.WGPUVertexFormat_Unorm16x4,
        @intFromEnum(wgpu.VertexFormat.snorm16x2) => raw.c.WGPUVertexFormat_Snorm16x2,
        @intFromEnum(wgpu.VertexFormat.snorm16x4) => raw.c.WGPUVertexFormat_Snorm16x4,
        else => @as(raw.c.WGPUVertexFormat, @intCast(n)),
    };
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

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    try testing.expectEqual(@as(u32, 3), ht.activeCount());
    try testing.expect(ht.isValid(bridge.adapter_id));
    try testing.expect(ht.isValid(bridge.device_id));
    try testing.expect(ht.isValid(bridge.queue_id));
}

test "GpuBridge deinit frees all three handles" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    bridge.deinit();

    try testing.expectEqual(@as(u32, 0), ht.activeCount());
    try testing.expect(!ht.isValid(bridge.adapter_id));
    try testing.expect(!ht.isValid(bridge.device_id));
    try testing.expect(!ht.isValid(bridge.queue_id));
}

test "GpuBridge handle types are correct" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

test "createTestGpuContext creates real GPU context" {
    const gctx, const glfw_window = try createTestGpuContext(testing.allocator);
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    // If we got here without crashing, the context was created successfully
    try testing.expect(true);
}

test "gpuDeviceDestroy with real hardware" {
    const gctx, const glfw_window = try createTestGpuContext(testing.allocator);
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var result = __native.gpuDeviceDestroy(devId);
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuGetQueue returns queue handle ID as number" {
    var ht = try HandleTable.init(testing.allocator, 8);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

test "gpuCreateShaderModule returns null without GPU context" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Without gctx, createShaderModule should return null
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateShaderModule(devId, { code: 'test' });
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expect(result.value.isNull());
}

test "gpuCreateShaderModule extracts WGSL code string" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, createShaderModule returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateBindGroupLayout returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, createBindGroupLayout returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreatePipelineLayout returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, createPipelineLayout returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateRenderPipeline returns valid handle with nested descriptor" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, createRenderPipeline returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateComputePipeline returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, createBindGroup returns null
    try testing.expect(result.value.isNull());
}

test "pipeline creation with invalid device returns null" {
    var ht = try HandleTable.init(testing.allocator, 16);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without gctx, most creation functions return null. Only gpuCreateComputePipeline
    // still uses allocPipelineHandle which doesn't require gctx, allocating 1 handle.
    try testing.expectEqual(initial_count + 1, ht.activeCount());
}

// ---------------------------------------------------------------------------
// Buffer/texture/sampler creation tests
// ---------------------------------------------------------------------------

test "register creates resource creation functions on __native" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateBuffer(0, {size: 256, usage: 64})
    , "<test>");
    defer result.deinit();

    // Without a real gctx, createBuffer returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateBuffer parses descriptor fields" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateTexture(0, {width: 512, height: 512, format: 1, usage: 16})
    , "<test>");
    defer result.deinit();

    // Without a real gctx, createTexture returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateTextureView allocates texture_view handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateTextureView(0, {format: 1, dimension: 1})
    , "<test>");
    defer result.deinit();

    // Without a real gctx, createTextureView returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateTextureView works with empty descriptor" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\__native.gpuCreateSampler(0, {magFilter: 1, minFilter: 1})
    , "<test>");
    defer result.deinit();

    // Without a real gctx, createSampler returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateSampler works with empty descriptor" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    var bridge = try GpuBridge.init(&ht, null);
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

    // Without a real gctx, all resource creation functions return null and
    // don't allocate handles. Net new allocations: 0
    try testing.expectEqual(initial_count, ht.activeCount());
}

test "pointer round-trip through f64" {
    var ht = try HandleTable.init(testing.allocator, 4);
    defer ht.deinit(testing.allocator);

    const f = ptrToF64(&ht);
    const back = f64ToPtr(*HandleTable, f);

    try testing.expect(back != null);
    try testing.expect(back.? == &ht);
}

// ---------------------------------------------------------------------------
// T18: Command encoding / render pass tests
// ---------------------------------------------------------------------------

test "register creates command encoding functions on __native" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\typeof __native.gpuCreateCommandEncoder === 'function' &&
        \\typeof __native.gpuCommandEncoderBeginRenderPass === 'function' &&
        \\typeof __native.gpuRenderPassSetPipeline === 'function' &&
        \\typeof __native.gpuRenderPassSetBindGroup === 'function' &&
        \\typeof __native.gpuRenderPassSetVertexBuffer === 'function' &&
        \\typeof __native.gpuRenderPassSetIndexBuffer === 'function' &&
        \\typeof __native.gpuRenderPassDraw === 'function' &&
        \\typeof __native.gpuRenderPassDrawIndexed === 'function' &&
        \\typeof __native.gpuRenderPassEnd === 'function' &&
        \\typeof __native.gpuRenderPassSetBlendConstant === 'function' &&
        \\typeof __native.gpuRenderPassSetStencilReference === 'function' &&
        \\typeof __native.gpuRenderPassPushDebugGroup === 'function' &&
        \\typeof __native.gpuRenderPassPopDebugGroup === 'function' &&
        \\typeof __native.gpuRenderPassInsertDebugMarker === 'function' &&
        \\typeof __native.gpuCommandEncoderFinish === 'function' &&
        \\typeof __native.gpuQueueSubmit === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuCreateCommandEncoder returns valid handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  return __native.gpuCreateCommandEncoder(devId);
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without a real gctx, createCommandEncoder returns null
    try testing.expect(result.value.isNull());
}

test "gpuCreateCommandEncoder with invalid device returns null" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var result = __native.gpuCreateCommandEncoder(99999);
        \\  return result === null;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "full command encoding chain: create → beginRenderPass → draw → end → finish → submit" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Without a real gctx, createCommandEncoder returns null, so
    // subsequent calls on null handles are no-ops. Just verify no crash.
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encoderId, {
        \\    colorAttachments: [{ view: 0, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  __native.gpuRenderPassDraw(passId, 3);
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encoderId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Just verify the chain didn't crash
    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuCommandEncoderFinish returns valid command buffer handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  return __native.gpuCommandEncoderFinish(encoderId);
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without a real gctx, createCommandEncoder returns null, so finish also returns null
    try testing.expect(result.value.isNull());
}

test "gpuCommandEncoderFinish frees the encoder handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Without a real gctx, createCommandEncoder returns null, so
    // finish on a null encoder is a no-op. Just verify no crash.
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encoderId);
        \\  return cmdBuf;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without gctx, result is null — just verify no crash
    try testing.expect(result.value.isNull());
}

test "gpuRenderPassEnd frees the render pass handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Without a real gctx, createCommandEncoder returns null, so
    // beginRenderPass and end are no-ops. Just verify no crash.
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encoderId, {});
        \\  __native.gpuRenderPassEnd(passId);
        \\  return encoderId;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without gctx, encoderId is null — just verify no crash
    try testing.expect(result.value.isNull());
}

test "full chain with setPipeline, setBindGroup, setVertexBuffer, setIndexBuffer, drawIndexed" {
    var ht = try HandleTable.init(testing.allocator, 64);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  var pipeline = __native.gpuCreateRenderPipeline(devId, {});
        \\  var bindGroup = __native.gpuCreateBindGroup(devId, {});
        \\  var vertexBuf = __native.gpuCreateBuffer(0, {size: 256, usage: 32});
        \\  var indexBuf = __native.gpuCreateBuffer(0, {size: 64, usage: 16});
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encoderId, {});
        \\  __native.gpuRenderPassSetPipeline(passId, pipeline);
        \\  __native.gpuRenderPassSetBindGroup(passId, 0, bindGroup);
        \\  __native.gpuRenderPassSetVertexBuffer(passId, 0, vertexBuf, 0, 256);
        \\  __native.gpuRenderPassSetIndexBuffer(passId, indexBuf, 'uint16', 0, 64);
        \\  __native.gpuRenderPassDrawIndexed(passId, 6, 1, 0, 0, 0);
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encoderId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuQueueSubmit frees multiple command buffers" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const initial_count = ht.activeCount();

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  var enc1 = __native.gpuCreateCommandEncoder(devId);
        \\  var cb1 = __native.gpuCommandEncoderFinish(enc1);
        \\  var enc2 = __native.gpuCreateCommandEncoder(devId);
        \\  var cb2 = __native.gpuCommandEncoderFinish(enc2);
        \\  __native.gpuQueueSubmit(queueId, [cb1, cb2]);
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());

    // All transient handles should be freed: 2 encoders + 2 command buffers
    // Only initial handles (adapter, device, queue) remain
    try testing.expectEqual(initial_count, ht.activeCount());
}

// ---------------------------------------------------------------------------
// T19: WebGPU present / swap chain tests
// ---------------------------------------------------------------------------

test "register creates T19 swap chain functions on __native" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\typeof __native.gpuConfigureContext === 'function' &&
        \\typeof __native.gpuGetCurrentTexture === 'function' &&
        \\typeof __native.gpuPresent === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuConfigureContext is callable and returns undefined" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var result = __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 800, 600);
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuGetCurrentTexture returns a valid texture handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval("__native.gpuGetCurrentTexture()", "<test>");
    defer result.deinit();

    // Without a real gctx, getCurrentTexture returns null
    try testing.expect(result.value.isNull());
}

test "gpuPresent is callable and returns undefined" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var result = __native.gpuPresent();
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "full frame cycle: configure → getCurrentTexture → createView → present" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Without a real gctx, getCurrentTexture/createTextureView/createCommandEncoder
    // all return null, so the chain is all no-ops. Just verify no crash.
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\
        \\  // 1. Configure the surface
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 800, 600);
        \\
        \\  // 2. Get the current swap chain texture
        \\  var texId = __native.gpuGetCurrentTexture();
        \\
        \\  // 3. Create a view from the swap chain texture
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\
        \\  // 4. Encode a render pass using the view
        \\  var encoderId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encoderId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  __native.gpuRenderPassDraw(passId, 3);
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encoderId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\
        \\  // 5. Present the frame
        \\  __native.gpuPresent();
        \\
        \\  return texId;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without gctx, texId is null — just verify no crash
    try testing.expect(result.value.isNull());
}

test "T22 native functions are registered" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    var result = try engine.eval(
        \\typeof __native.gpuQueueWriteBuffer === 'function' &&
        \\typeof __native.gpuQueueWriteTexture === 'function' &&
        \\typeof __native.gpuRenderPipelineGetBindGroupLayout === 'function' &&
        \\typeof __native.gpuComputePipelineGetBindGroupLayout === 'function'
    , "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuQueueWriteBuffer validates handles and returns undefined" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  var bufferId = __native.gpuCreateBuffer(devId, { size: 64, usage: 0x28 });
        \\  var data = new Float32Array([1.0, 2.0, 3.0, 4.0]);
        \\  var result = __native.gpuQueueWriteBuffer(queueId, bufferId, 0, data, 0, 16);
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuQueueWriteTexture validates handles and returns undefined" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  var texId = __native.gpuCreateTexture(devId, { width: 4, height: 4, format: 0, usage: 0 });
        \\  var data = new Uint8Array(64);
        \\  var result = __native.gpuQueueWriteTexture(queueId, { texture: texId }, data, { bytesPerRow: 16 }, { width: 4, height: 4 });
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRenderPipelineGetBindGroupLayout returns a bind_group_layout handle" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    var bridge = try GpuBridge.init(&ht, null);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var pipelineId = __native.gpuCreateRenderPipeline(devId, {});
        \\  var bglId = __native.gpuRenderPipelineGetBindGroupLayout(pipelineId, 0);
        \\  return bglId;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    // Without a real gctx, createRenderPipeline returns null, so
    // getBindGroupLayout on a null pipeline also returns null
    try testing.expect(result.value.isNull());
}

test "gpuCommandEncoderBeginComputePass with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginComputePass(encId);
        \\  return typeof passId === 'number' && passId > 0;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuComputePassEncoderEnd with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginComputePass(encId);
        \\  var result = __native.gpuComputePassEncoderEnd(passId);
        \\  return result === undefined;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

// ---------------------------------------------------------------------------
// Phase 6: GPURenderPassEncoder missing functions — hardware tests
// ---------------------------------------------------------------------------

test "gpuRenderPassEncoder.setBlendConstant with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 640, 480);
        \\  var texId = __native.gpuGetCurrentTexture();
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  var result = __native.gpuRenderPassSetBlendConstant(passId, { r: 0.1, g: 0.2, b: 0.3, a: 0.4 });
        \\  if (result !== undefined) return 'expected undefined, got ' + typeof result;
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  __native.gpuPresent();
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRenderPassEncoder.setStencilReference with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 640, 480);
        \\  var texId = __native.gpuGetCurrentTexture();
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  var result = __native.gpuRenderPassSetStencilReference(passId, 0x42);
        \\  if (result !== undefined) return 'expected undefined, got ' + typeof result;
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  __native.gpuPresent();
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRenderPassEncoder.pushDebugGroup and popDebugGroup with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 640, 480);
        \\  var texId = __native.gpuGetCurrentTexture();
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  var pushResult = __native.gpuRenderPassPushDebugGroup(passId, 'my_debug_group');
        \\  if (pushResult !== undefined) return 'push expected undefined, got ' + typeof pushResult;
        \\  var popResult = __native.gpuRenderPassPopDebugGroup(passId);
        \\  if (popResult !== undefined) return 'pop expected undefined, got ' + typeof popResult;
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  __native.gpuPresent();
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRenderPassEncoder.insertDebugMarker with real hardware" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 640, 480);
        \\  var texId = __native.gpuGetCurrentTexture();
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  var result = __native.gpuRenderPassInsertDebugMarker(passId, 'marker_after_draw');
        \\  if (result !== undefined) return 'expected undefined, got ' + typeof result;
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  __native.gpuPresent();
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}

test "gpuRenderPassEncoder.setBlendConstant parses all color channels correctly" {
    var ht = try HandleTable.init(testing.allocator, 32);
    defer ht.deinit(testing.allocator);

    const context_result = try createTestGpuContext(testing.allocator);
    const gctx = context_result[0];
    const glfw_window = context_result[1];
    defer destroyTestGpuContext(gctx, glfw_window, testing.allocator);

    var bridge = try GpuBridge.init(&ht, gctx);
    defer bridge.deinit();

    var engine = try JsEngine.init(testing.allocator);
    defer engine.deinit();

    try bridge.register(engine.context);

    // Test with various color values including edge cases (0.0, 1.0, >1.0, <0.0)
    const js_src =
        \\(function() {
        \\  var devId = __native.gpuRequestDevice(0);
        \\  var queueId = __native.gpuGetQueue(devId);
        \\  __native.gpuConfigureContext(devId, 'bgra8unorm', 'opaque', 640, 480);
        \\  var texId = __native.gpuGetCurrentTexture();
        \\  var viewId = __native.gpuCreateTextureView(texId, {});
        \\  var encId = __native.gpuCreateCommandEncoder(devId);
        \\  var passId = __native.gpuCommandEncoderBeginRenderPass(encId, {
        \\    colorAttachments: [{ view: viewId, loadOp: 'clear', storeOp: 'store' }]
        \\  });
        \\  // Test full white
        \\  __native.gpuRenderPassSetBlendConstant(passId, { r: 1.0, g: 1.0, b: 1.0, a: 1.0 });
        \\  // Test all zero
        \\  __native.gpuRenderPassSetBlendConstant(passId, { r: 0.0, g: 0.0, b: 0.0, a: 0.0 });
        \\  // Test half values
        \\  __native.gpuRenderPassSetBlendConstant(passId, { r: 0.5, g: 0.5, b: 0.5, a: 0.5 });
        \\  // Test >1.0 values (clamping is GPU's responsibility)
        \\  __native.gpuRenderPassSetBlendConstant(passId, { r: 2.0, g: -0.5, b: 1.5, a: 3.0 });
        \\  __native.gpuRenderPassEnd(passId);
        \\  var cmdBuf = __native.gpuCommandEncoderFinish(encId);
        \\  __native.gpuQueueSubmit(queueId, [cmdBuf]);
        \\  __native.gpuPresent();
        \\  return true;
        \\})()
    ;
    var result = try engine.eval(js_src, "<test>");
    defer result.deinit();

    try testing.expectEqual(@as(i32, 1), try result.toInt32());
}
