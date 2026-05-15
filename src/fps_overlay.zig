const std = @import("std");

const dawn = @import("dawn/context.zig");
const raw = @import("dawn/raw.zig");

const max_vertices = 2048;
const sample_count = 1;

const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

const white = [4]f32{ 0.92, 0.96, 1.0, 1.0 };
const shadow = [4]f32{ 0.0, 0.0, 0.0, 0.55 };

const shader_source =
    \\struct VertexInput {
    \\  @location(0) position : vec2<f32>,
    \\  @location(1) color : vec4<f32>,
    \\};
    \\
    \\struct VertexOutput {
    \\  @builtin(position) position : vec4<f32>,
    \\  @location(0) color : vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn vs_main(input : VertexInput) -> VertexOutput {
    \\  var output : VertexOutput;
    \\  output.position = vec4<f32>(input.position, 0.0, 1.0);
    \\  output.color = input.color;
    \\  return output;
    \\}
    \\
    \\@fragment
    \\fn fs_main(input : VertexOutput) -> @location(0) vec4<f32> {
    \\  return input.color;
    \\}
;

pub const FpsOverlay = struct {
    shader_module: ?raw.c.WGPUShaderModule = null,
    pipeline: ?raw.c.WGPURenderPipeline = null,
    vertex_buffer: ?raw.c.WGPUBuffer = null,
    vertices: [max_vertices]Vertex = undefined,
    frame_count: u32 = 0,
    display_fps: u32 = 0,
    window_start_ns: i128 = 0,

    pub fn draw(self: *FpsOverlay, gctx: *dawn.GraphicsContext) void {
        const view = gctx.current_surface_view orelse return;
        self.updateFps();
        self.ensureGpuResources(gctx) catch return;

        const vertex_count = self.buildVertices(
            @floatFromInt(gctx.surface_config.width),
            @floatFromInt(gctx.surface_config.height),
        );
        if (vertex_count == 0) return;

        const vertex_bytes = self.vertices[0..vertex_count];
        raw.c.wgpuQueueWriteBuffer(
            @ptrCast(gctx.queue),
            self.vertex_buffer.?,
            0,
            vertex_bytes.ptr,
            vertex_bytes.len * @sizeOf(Vertex),
        );

        const encoder = raw.c.wgpuDeviceCreateCommandEncoder(@ptrCast(gctx.device), null) orelse return;
        defer raw.c.wgpuCommandEncoderRelease(encoder);

        var color_attachment = std.mem.zeroes(raw.c.WGPURenderPassColorAttachment);
        color_attachment.view = @ptrCast(view);
        color_attachment.depthSlice = raw.c.WGPU_DEPTH_SLICE_UNDEFINED;
        color_attachment.loadOp = raw.c.WGPULoadOp_Load;
        color_attachment.storeOp = raw.c.WGPUStoreOp_Store;
        color_attachment.clearValue = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

        var pass_desc = std.mem.zeroes(raw.c.WGPURenderPassDescriptor);
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attachment;

        const pass = raw.c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse return;
        raw.c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline.?);
        raw.c.wgpuRenderPassEncoderSetVertexBuffer(
            pass,
            0,
            self.vertex_buffer.?,
            0,
            vertex_count * @sizeOf(Vertex),
        );
        raw.c.wgpuRenderPassEncoderDraw(pass, @intCast(vertex_count), 1, 0, 0);
        raw.c.wgpuRenderPassEncoderEnd(pass);
        raw.c.wgpuRenderPassEncoderRelease(pass);

        const commands = raw.c.wgpuCommandEncoderFinish(encoder, null) orelse return;
        defer raw.c.wgpuCommandBufferRelease(commands);
        raw.c.wgpuQueueSubmit(@ptrCast(gctx.queue), 1, &commands);
    }

    pub fn deinit(self: *FpsOverlay) void {
        if (self.vertex_buffer) |buffer| {
            raw.c.wgpuBufferRelease(buffer);
            self.vertex_buffer = null;
        }
        if (self.pipeline) |pipeline| {
            raw.c.wgpuRenderPipelineRelease(pipeline);
            self.pipeline = null;
        }
        if (self.shader_module) |module| {
            raw.c.wgpuShaderModuleRelease(module);
            self.shader_module = null;
        }
    }

    fn updateFps(self: *FpsOverlay) void {
        const now = std.time.nanoTimestamp();
        if (self.window_start_ns == 0) {
            self.window_start_ns = now;
        }

        self.frame_count += 1;
        const elapsed = now - self.window_start_ns;
        if (elapsed >= 500 * std.time.ns_per_ms) {
            const fps = @divTrunc(@as(i128, self.frame_count) * std.time.ns_per_s, elapsed);
            self.display_fps = @intCast(@min(fps, 9999));
            self.frame_count = 0;
            self.window_start_ns = now;
        }
    }

    fn ensureGpuResources(self: *FpsOverlay, gctx: *dawn.GraphicsContext) !void {
        if (self.pipeline != null and self.vertex_buffer != null) return;

        var wgsl_desc = std.mem.zeroes(raw.c.WGPUShaderSourceWGSL);
        wgsl_desc.chain.sType = raw.c.WGPUSType_ShaderSourceWGSL;
        wgsl_desc.code = stringView(shader_source);

        var shader_desc = std.mem.zeroes(raw.c.WGPUShaderModuleDescriptor);
        shader_desc.nextInChain = &wgsl_desc.chain;
        shader_desc.label = stringView("three.zig FPS overlay");

        const shader_module = raw.c.wgpuDeviceCreateShaderModule(@ptrCast(gctx.device), &shader_desc) orelse return error.FpsOverlayInitFailed;
        errdefer raw.c.wgpuShaderModuleRelease(shader_module);

        var attributes = [_]raw.c.WGPUVertexAttribute{
            .{
                .format = raw.c.WGPUVertexFormat_Float32x2,
                .offset = @offsetOf(Vertex, "position"),
                .shaderLocation = 0,
            },
            .{
                .format = raw.c.WGPUVertexFormat_Float32x4,
                .offset = @offsetOf(Vertex, "color"),
                .shaderLocation = 1,
            },
        };

        var vertex_layout = std.mem.zeroes(raw.c.WGPUVertexBufferLayout);
        vertex_layout.arrayStride = @sizeOf(Vertex);
        vertex_layout.stepMode = raw.c.WGPUVertexStepMode_Vertex;
        vertex_layout.attributeCount = attributes.len;
        vertex_layout.attributes = &attributes;

        var vertex_state = std.mem.zeroes(raw.c.WGPUVertexState);
        vertex_state.module = shader_module;
        vertex_state.entryPoint = stringView("vs_main");
        vertex_state.bufferCount = 1;
        vertex_state.buffers = &vertex_layout;

        var blend = std.mem.zeroes(raw.c.WGPUBlendState);
        blend.color.operation = raw.c.WGPUBlendOperation_Add;
        blend.color.srcFactor = raw.c.WGPUBlendFactor_SrcAlpha;
        blend.color.dstFactor = raw.c.WGPUBlendFactor_OneMinusSrcAlpha;
        blend.alpha.operation = raw.c.WGPUBlendOperation_Add;
        blend.alpha.srcFactor = raw.c.WGPUBlendFactor_One;
        blend.alpha.dstFactor = raw.c.WGPUBlendFactor_OneMinusSrcAlpha;

        var color_target = std.mem.zeroes(raw.c.WGPUColorTargetState);
        color_target.format = gctx.surface_config.format;
        color_target.blend = &blend;
        color_target.writeMask = raw.c.WGPUColorWriteMask_All;

        var fragment_state = std.mem.zeroes(raw.c.WGPUFragmentState);
        fragment_state.module = shader_module;
        fragment_state.entryPoint = stringView("fs_main");
        fragment_state.targetCount = 1;
        fragment_state.targets = &color_target;

        var primitive = std.mem.zeroes(raw.c.WGPUPrimitiveState);
        primitive.topology = raw.c.WGPUPrimitiveTopology_TriangleList;
        primitive.stripIndexFormat = raw.c.WGPUIndexFormat_Undefined;
        primitive.frontFace = raw.c.WGPUFrontFace_CCW;
        primitive.cullMode = raw.c.WGPUCullMode_None;

        var multisample = std.mem.zeroes(raw.c.WGPUMultisampleState);
        multisample.count = sample_count;
        multisample.mask = 0xFFFFFFFF;
        multisample.alphaToCoverageEnabled = 0;

        var pipeline_desc = std.mem.zeroes(raw.c.WGPURenderPipelineDescriptor);
        pipeline_desc.label = stringView("three.zig FPS overlay pipeline");
        pipeline_desc.vertex = vertex_state;
        pipeline_desc.fragment = &fragment_state;
        pipeline_desc.primitive = primitive;
        pipeline_desc.multisample = multisample;

        const pipeline = raw.c.wgpuDeviceCreateRenderPipeline(@ptrCast(gctx.device), &pipeline_desc) orelse return error.FpsOverlayInitFailed;
        errdefer raw.c.wgpuRenderPipelineRelease(pipeline);

        var buffer_desc = std.mem.zeroes(raw.c.WGPUBufferDescriptor);
        buffer_desc.label = stringView("three.zig FPS overlay vertices");
        buffer_desc.usage = raw.c.WGPUBufferUsage_Vertex | raw.c.WGPUBufferUsage_CopyDst;
        buffer_desc.size = max_vertices * @sizeOf(Vertex);

        const vertex_buffer = raw.c.wgpuDeviceCreateBuffer(@ptrCast(gctx.device), &buffer_desc) orelse return error.FpsOverlayInitFailed;

        self.shader_module = shader_module;
        self.pipeline = pipeline;
        self.vertex_buffer = vertex_buffer;
    }

    fn buildVertices(self: *FpsOverlay, width: f32, height: f32) usize {
        if (width <= 0 or height <= 0) return 0;

        var text_buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "FPS {d}", .{self.display_fps}) catch "FPS ?";
        const cell = std.math.clamp(@floor(height / 180.0), 3.0, 6.0);
        const gap = cell;
        const glyph_w = 5.0 * cell;
        const glyph_h = 7.0 * cell;
        const text_w = @as(f32, @floatFromInt(text.len)) * glyph_w + @as(f32, @floatFromInt(text.len - 1)) * gap;
        const pad = 8.0;
        const bg_pad = 5.0;
        const x = @max(pad, width - pad - text_w);
        const y = pad;

        var count: usize = 0;
        self.addRect(&count, width, height, x - bg_pad, y - bg_pad, text_w + bg_pad * 2.0, glyph_h + bg_pad * 2.0, shadow);

        var cursor_x = x;
        for (text) |ch| {
            self.addGlyph(&count, width, height, ch, cursor_x, y, cell, white);
            cursor_x += glyph_w + gap;
        }

        return count;
    }

    fn addGlyph(
        self: *FpsOverlay,
        count: *usize,
        width: f32,
        height: f32,
        ch: u8,
        x: f32,
        y: f32,
        cell: f32,
        color: [4]f32,
    ) void {
        const rows = glyphRows(ch);
        for (rows, 0..) |row, row_index| {
            for (0..5) |col| {
                const bit: u3 = @intCast(4 - col);
                if (((row >> bit) & 1) == 0) continue;
                self.addRect(
                    count,
                    width,
                    height,
                    x + @as(f32, @floatFromInt(col)) * cell,
                    y + @as(f32, @floatFromInt(row_index)) * cell,
                    cell,
                    cell,
                    color,
                );
            }
        }
    }

    fn addRect(
        self: *FpsOverlay,
        count: *usize,
        surface_width: f32,
        surface_height: f32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32,
    ) void {
        if (count.* + 6 > max_vertices) return;

        const x0 = (x / surface_width) * 2.0 - 1.0;
        const x1 = ((x + w) / surface_width) * 2.0 - 1.0;
        const y0 = 1.0 - (y / surface_height) * 2.0;
        const y1 = 1.0 - ((y + h) / surface_height) * 2.0;

        const verts = [_]Vertex{
            .{ .position = .{ x0, y0 }, .color = color },
            .{ .position = .{ x1, y0 }, .color = color },
            .{ .position = .{ x0, y1 }, .color = color },
            .{ .position = .{ x1, y0 }, .color = color },
            .{ .position = .{ x1, y1 }, .color = color },
            .{ .position = .{ x0, y1 }, .color = color },
        };
        @memcpy(self.vertices[count.* .. count.* + verts.len], &verts);
        count.* += verts.len;
    }
};

fn glyphRows(ch: u8) [7]u5 {
    return switch (ch) {
        '0' => .{ 0b11111, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b11111 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b11110, 0b00001, 0b00001, 0b11110, 0b10000, 0b10000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b10010, 0b10010, 0b10010, 0b11111, 0b00010, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01111, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b11110 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

fn stringView(slice: []const u8) raw.c.WGPUStringView {
    var view = std.mem.zeroes(raw.c.WGPUStringView);
    view.data = if (slice.len > 0) @ptrCast(slice.ptr) else null;
    view.length = slice.len;
    return view;
}
