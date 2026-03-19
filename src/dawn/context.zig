const std = @import("std");
const builtin = @import("builtin");
const raw = @import("raw.zig");
const zgpu = @import("zgpu");

pub const wgpu = zgpu.wgpu;

const log = std.log.scoped(.dawn_context);
const emscripten = builtin.target.os.tag == .emscripten;

pub const WindowProvider = struct {
    window: *anyopaque,
    fn_getTime: *const fn () f64,
    fn_getFramebufferSize: *const fn (window: *const anyopaque) [2]u32,
    fn_getWin32Window: *const fn (window: *const anyopaque) callconv(.c) *anyopaque = undefined,
    fn_getX11Display: *const fn () callconv(.c) *anyopaque = undefined,
    fn_getX11Window: *const fn (window: *const anyopaque) callconv(.c) u32 = undefined,
    fn_getWaylandDisplay: ?*const fn () callconv(.c) *anyopaque = null,
    fn_getWaylandSurface: ?*const fn (window: *const anyopaque) callconv(.c) *anyopaque = null,
    fn_getCocoaWindow: *const fn (window: *const anyopaque) callconv(.c) ?*anyopaque = undefined,
    fn_getAndroidNativeWindow: ?*const fn () callconv(.c) ?*anyopaque = null,

    fn getTime(self: WindowProvider) f64 {
        return self.fn_getTime();
    }

    fn getFramebufferSize(self: WindowProvider) [2]u32 {
        return self.fn_getFramebufferSize(self.window);
    }

    fn getWin32Window(self: WindowProvider) ?*anyopaque {
        return self.fn_getWin32Window(self.window);
    }

    fn getX11Display(self: WindowProvider) ?*anyopaque {
        return self.fn_getX11Display();
    }

    fn getX11Window(self: WindowProvider) u32 {
        return self.fn_getX11Window(self.window);
    }

    fn getWaylandDisplay(self: WindowProvider) ?*anyopaque {
        if (self.fn_getWaylandDisplay) |f| return f();
        return null;
    }

    fn getWaylandSurface(self: WindowProvider) ?*anyopaque {
        if (self.fn_getWaylandSurface) |f| return f(self.window);
        return null;
    }

    fn getCocoaWindow(self: WindowProvider) ?*anyopaque {
        return self.fn_getCocoaWindow(self.window);
    }

    fn getAndroidNativeWindow(self: WindowProvider) ?*anyopaque {
        if (self.fn_getAndroidNativeWindow) |f| return f();
        return null;
    }
};

pub const GraphicsContextOptions = struct {
    present_mode: wgpu.PresentMode = .fifo,
    required_features: []const wgpu.FeatureName = &.{},
    required_limits: ?*const wgpu.RequiredLimits = null,
};

pub const GraphicsContext = struct {
    window_provider: WindowProvider,
    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    queue: wgpu.Queue,
    surface: wgpu.Surface,
    surface_config: raw.c.WGPUSurfaceConfiguration,
    current_surface_texture: ?raw.c.WGPUTexture = null,
    current_surface_view: ?wgpu.TextureView = null,

    pub fn create(
        allocator: std.mem.Allocator,
        window_provider: WindowProvider,
        options: GraphicsContextOptions,
    ) !*GraphicsContext {
        var instance_desc = std.mem.zeroes(raw.c.WGPUInstanceDescriptor);
        const raw_instance: raw.c.WGPUInstance = if (emscripten)
            @ptrCast(wgpu.createInstance(.{}))
        else
            raw.c.wgpuCreateInstance(&instance_desc) orelse return error.NoGraphicsInstance;
        const instance: wgpu.Instance = @ptrCast(raw_instance);
        errdefer instance.release();

        const surface = createSurfaceForWindow(instance, window_provider);
        errdefer surface.release();

        var adapter_options = std.mem.zeroes(raw.c.WGPURequestAdapterOptions);
        adapter_options.compatibleSurface = @ptrCast(surface);
        adapter_options.backendType = raw.c.WGPUBackendType_Undefined;
        adapter_options.powerPreference = raw.c.WGPUPowerPreference_HighPerformance;
        const raw_adapter = raw.requestAdapterSync(raw_instance, &adapter_options) catch |err| {
            log.err("requestAdapterSync failed: {s}", .{@errorName(err)});
            return error.NoGraphicsAdapter;
        };
        const adapter: wgpu.Adapter = @ptrCast(raw_adapter);
        errdefer adapter.release();

        var device_desc = std.mem.zeroes(raw.c.WGPUDeviceDescriptor);
        device_desc.requiredFeatureCount = @intCast(options.required_features.len);
        device_desc.requiredFeatures = if (options.required_features.len != 0)
            @ptrCast(options.required_features.ptr)
        else
            null;
        device_desc.requiredLimits = if (options.required_limits) |limits|
            @ptrCast(limits)
        else
            null;
        device_desc.uncapturedErrorCallbackInfo.callback = logUnhandledError;
        device_desc.uncapturedErrorCallbackInfo.userdata1 = null;
        device_desc.uncapturedErrorCallbackInfo.userdata2 = null;
        const raw_device = raw.requestDeviceSync(raw_instance, raw_adapter, &device_desc) catch |err| {
            log.err("requestDeviceSync failed: {s}", .{@errorName(err)});
            return error.NoGraphicsDevice;
        };
        const device: wgpu.Device = @ptrCast(raw_device);
        errdefer device.release();

        const queue = device.getQueue();
        const framebuffer_size = window_provider.getFramebufferSize();
        var surface_caps = std.mem.zeroes(raw.c.WGPUSurfaceCapabilities);
        const caps_status = raw.c.wgpuSurfaceGetCapabilities(@ptrCast(surface), @ptrCast(adapter), &surface_caps);
        if (caps_status != raw.c.WGPUStatus_Success) {
            log.err("surface capabilities query failed: status={d}", .{caps_status});
            return error.NoSurfaceCapabilities;
        }
        defer raw.c.wgpuSurfaceCapabilitiesFreeMembers(surface_caps);

        var surface_config = std.mem.zeroes(raw.c.WGPUSurfaceConfiguration);
        surface_config.device = @ptrCast(device);
        surface_config.format = chooseSurfaceFormat(surface_caps);
        surface_config.usage = raw.c.WGPUTextureUsage_RenderAttachment;
        surface_config.width = @intCast(framebuffer_size[0]);
        surface_config.height = @intCast(framebuffer_size[1]);
        surface_config.viewFormatCount = 0;
        surface_config.viewFormats = null;
        surface_config.alphaMode = chooseCompositeAlphaMode(surface_caps);
        surface_config.presentMode = choosePresentMode(options.present_mode, surface_caps);
        raw.c.wgpuSurfaceConfigure(@ptrCast(surface), &surface_config);
        log.info("surface configured: format={d} presentMode={d} alphaMode={d} size={}x{}", .{
            surface_config.format,
            surface_config.presentMode,
            surface_config.alphaMode,
            surface_config.width,
            surface_config.height,
        });

        const gctx = try allocator.create(GraphicsContext);
        gctx.* = .{
            .window_provider = window_provider,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .surface = surface,
            .surface_config = surface_config,
        };
        return gctx;
    }

    pub fn destroy(self: *GraphicsContext, allocator: std.mem.Allocator) void {
        self.releaseCurrentSurfaceFrame();
        raw.c.wgpuSurfaceUnconfigure(@ptrCast(self.surface));
        self.surface.release();
        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.instance.release();
        allocator.destroy(self);
    }

    pub fn resize(self: *GraphicsContext, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (self.surface_config.width == width and self.surface_config.height == height) return;

        self.releaseCurrentSurfaceFrame();
        self.surface_config.width = width;
        self.surface_config.height = height;
        raw.c.wgpuSurfaceConfigure(@ptrCast(self.surface), &self.surface_config);
        log.info("surface resized to {}x{}", .{ width, height });
    }

    pub fn getCurrentTextureView(self: *GraphicsContext) ?wgpu.TextureView {
        if (self.current_surface_view) |view| return view;

        var surface_texture = std.mem.zeroes(raw.c.WGPUSurfaceTexture);
        raw.c.wgpuSurfaceGetCurrentTexture(@ptrCast(self.surface), &surface_texture);
        switch (surface_texture.status) {
            raw.c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
            raw.c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            => {},
            else => {
                log.err("surface getCurrentTexture failed: status={d}", .{surface_texture.status});
                return null;
            },
        }

        if (surface_texture.texture == null) {
            log.err("surface getCurrentTexture returned null texture", .{});
            return null;
        }

        const view = raw.c.wgpuTextureCreateView(surface_texture.texture, null);
        if (view == null) {
            log.err("surface texture view creation failed", .{});
            raw.c.wgpuTextureRelease(surface_texture.texture);
            return null;
        }

        self.current_surface_texture = surface_texture.texture;
        self.current_surface_view = @ptrCast(view);
        return self.current_surface_view.?;
    }

    pub fn present(self: *GraphicsContext) enum {
        normal_execution,
        swap_chain_resized,
    } {
        if (!emscripten) {
            const status = raw.c.wgpuSurfacePresent(@ptrCast(self.surface));
            if (status != raw.c.WGPUStatus_Success) {
                log.err("surface present failed: status={d}", .{status});
            }
        }
        self.releaseCurrentSurfaceFrame();

        const fb_size = self.window_provider.getFramebufferSize();
        if (self.surface_config.width != fb_size[0] or
            self.surface_config.height != fb_size[1])
        {
            if (fb_size[0] != 0 and fb_size[1] != 0) {
                self.resize(@intCast(fb_size[0]), @intCast(fb_size[1]));
                return .swap_chain_resized;
            }
        }

        return .normal_execution;
    }

    fn releaseCurrentSurfaceFrame(self: *GraphicsContext) void {
        if (self.current_surface_view) |view| {
            view.release();
            self.current_surface_view = null;
        }
        if (self.current_surface_texture) |texture| {
            raw.c.wgpuTextureRelease(texture);
            self.current_surface_texture = null;
        }
    }
};

const SurfaceDescriptorTag = enum {
    metal_layer,
    windows_hwnd,
    xlib,
    wayland,
    android_native_window,
};

const SurfaceDescriptor = union(SurfaceDescriptorTag) {
    metal_layer: struct {
        label: ?[*:0]const u8 = null,
        layer: *anyopaque,
    },
    windows_hwnd: struct {
        label: ?[*:0]const u8 = null,
        hinstance: *anyopaque,
        hwnd: *anyopaque,
    },
    xlib: struct {
        label: ?[*:0]const u8 = null,
        display: *anyopaque,
        window: u32,
    },
    wayland: struct {
        label: ?[*:0]const u8 = null,
        display: *anyopaque,
        surface: *anyopaque,
    },
    android_native_window: struct {
        label: ?[*:0]const u8 = null,
        window: *anyopaque,
    },
};

fn isLinuxDesktopLike(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .linux,
        .freebsd,
        .openbsd,
        .dragonfly,
        => true,
        else => false,
    };
}

fn createSurfaceForWindow(instance: wgpu.Instance, window_provider: WindowProvider) wgpu.Surface {
    const os_tag = builtin.target.os.tag;

    const descriptor = switch (os_tag) {
        .windows => SurfaceDescriptor{
            .windows_hwnd = .{
                .label = "basic surface",
                .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
                .hwnd = window_provider.getWin32Window().?,
            },
        },
        .macos => macos: {
            const ns_window = window_provider.getCocoaWindow().?;
            const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque);
            msgSend(ns_view, "setWantsLayer:", .{true}, void);
            const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque);
            if (layer == null) @panic("failed to create Metal layer");
            msgSend(ns_view, "setLayer:", .{layer.?}, void);

            const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64);
            msgSend(layer.?, "setContentsScale:", .{scale_factor}, void);

            break :macos SurfaceDescriptor{
                .metal_layer = .{
                    .label = "basic surface",
                    .layer = layer.?,
                },
            };
        },
        else => if (builtin.target.abi == .android) android: {
            break :android SurfaceDescriptor{
                .android_native_window = .{
                    .label = "basic surface",
                    .window = window_provider.getAndroidNativeWindow().?,
                },
            };
        } else if (isLinuxDesktopLike(os_tag)) linux: {
            if (window_provider.getWaylandDisplay()) |wl_display| {
                break :linux SurfaceDescriptor{
                    .wayland = .{
                        .label = "basic surface",
                        .display = wl_display,
                        .surface = window_provider.getWaylandSurface().?,
                    },
                };
            }
            break :linux SurfaceDescriptor{
                .xlib = .{
                    .label = "basic surface",
                    .display = window_provider.getX11Display().?,
                    .window = window_provider.getX11Window(),
                },
            };
        } else unreachable,
    };

    const raw_instance: raw.c.WGPUInstance = @ptrCast(instance);
    const raw_surface = switch (descriptor) {
        .metal_layer => |src| blk: {
            var source = std.mem.zeroes(raw.c.WGPUSurfaceSourceMetalLayer);
            source.chain.next = null;
            source.chain.sType = raw.c.WGPUSType_SurfaceSourceMetalLayer;
            source.layer = src.layer;

            var desc = std.mem.zeroes(raw.c.WGPUSurfaceDescriptor);
            desc.nextInChain = @ptrCast(&source.chain);
            desc.label = rawStringViewZ(src.label);
            break :blk raw.c.wgpuInstanceCreateSurface(raw_instance, &desc);
        },
        .windows_hwnd => |src| blk: {
            var source = std.mem.zeroes(raw.c.WGPUSurfaceSourceWindowsHWND);
            source.chain.next = null;
            source.chain.sType = raw.c.WGPUSType_SurfaceSourceWindowsHWND;
            source.hinstance = src.hinstance;
            source.hwnd = src.hwnd;

            var desc = std.mem.zeroes(raw.c.WGPUSurfaceDescriptor);
            desc.nextInChain = @ptrCast(&source.chain);
            desc.label = rawStringViewZ(src.label);
            break :blk raw.c.wgpuInstanceCreateSurface(raw_instance, &desc);
        },
        .xlib => |src| blk: {
            var source = std.mem.zeroes(raw.c.WGPUSurfaceSourceXlibWindow);
            source.chain.next = null;
            source.chain.sType = raw.c.WGPUSType_SurfaceSourceXlibWindow;
            source.display = src.display;
            source.window = src.window;

            var desc = std.mem.zeroes(raw.c.WGPUSurfaceDescriptor);
            desc.nextInChain = @ptrCast(&source.chain);
            desc.label = rawStringViewZ(src.label);
            break :blk raw.c.wgpuInstanceCreateSurface(raw_instance, &desc);
        },
        .wayland => |src| blk: {
            var source = std.mem.zeroes(raw.c.WGPUSurfaceSourceWaylandSurface);
            source.chain.next = null;
            source.chain.sType = raw.c.WGPUSType_SurfaceSourceWaylandSurface;
            source.display = src.display;
            source.surface = src.surface;

            var desc = std.mem.zeroes(raw.c.WGPUSurfaceDescriptor);
            desc.nextInChain = @ptrCast(&source.chain);
            desc.label = rawStringViewZ(src.label);
            break :blk raw.c.wgpuInstanceCreateSurface(raw_instance, &desc);
        },
        .android_native_window => |src| blk: {
            var source = std.mem.zeroes(raw.c.WGPUSurfaceSourceAndroidNativeWindow);
            source.chain.next = null;
            source.chain.sType = raw.c.WGPUSType_SurfaceSourceAndroidNativeWindow;
            source.window = src.window;

            var desc = std.mem.zeroes(raw.c.WGPUSurfaceDescriptor);
            desc.nextInChain = @ptrCast(&source.chain);
            desc.label = rawStringViewZ(src.label);
            break :blk raw.c.wgpuInstanceCreateSurface(raw_instance, &desc);
        },
    };
    if (raw_surface == null) @panic("failed to create Dawn surface");
    return @ptrCast(raw_surface);
}

fn rawStringViewZ(str: ?[*:0]const u8) raw.c.WGPUStringView {
    var view = std.mem.zeroes(raw.c.WGPUStringView);
    if (str) |s| {
        view.data = @ptrCast(s);
        view.length = std.mem.len(s);
    }
    return view;
}

fn chooseSurfaceFormat(caps: raw.c.WGPUSurfaceCapabilities) raw.c.WGPUTextureFormat {
    const formats = if (caps.formats != null) caps.formats[0..caps.formatCount] else &.{};
    const preferred = [_]raw.c.WGPUTextureFormat{
        raw.c.WGPUTextureFormat_BGRA8Unorm,
        raw.c.WGPUTextureFormat_RGBA8Unorm,
        raw.c.WGPUTextureFormat_BGRA8UnormSrgb,
        raw.c.WGPUTextureFormat_RGBA8UnormSrgb,
    };
    for (preferred) |want| {
        for (formats) |have| {
            if (have == want) return have;
        }
    }
    if (formats.len > 0) return formats[0];
    return raw.c.WGPUTextureFormat_BGRA8Unorm;
}

fn choosePresentMode(requested: wgpu.PresentMode, caps: raw.c.WGPUSurfaceCapabilities) raw.c.WGPUPresentMode {
    const modes = if (caps.presentModes != null) caps.presentModes[0..caps.presentModeCount] else &.{};
    const desired: raw.c.WGPUPresentMode = switch (requested) {
        .immediate => raw.c.WGPUPresentMode_Immediate,
        .mailbox => raw.c.WGPUPresentMode_Mailbox,
        else => raw.c.WGPUPresentMode_Fifo,
    };
    for (modes) |mode| {
        if (mode == desired) return mode;
    }
    for (modes) |mode| {
        if (mode == raw.c.WGPUPresentMode_Fifo) return mode;
    }
    if (modes.len > 0) return modes[0];
    return raw.c.WGPUPresentMode_Fifo;
}

fn chooseCompositeAlphaMode(caps: raw.c.WGPUSurfaceCapabilities) raw.c.WGPUCompositeAlphaMode {
    const modes = if (caps.alphaModes != null) caps.alphaModes[0..caps.alphaModeCount] else &.{};
    for (modes) |mode| {
        if (mode == raw.c.WGPUCompositeAlphaMode_Opaque) return mode;
    }
    if (modes.len > 0) return modes[0];
    return raw.c.WGPUCompositeAlphaMode_Auto;
}

fn logUnhandledError(
    device: [*c]const raw.c.WGPUDevice,
    err_type: raw.c.WGPUErrorType,
    message: raw.c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    const msg = raw.stringViewToSlice(message);
    switch (err_type) {
        raw.c.WGPUErrorType_NoError => log.info("No error: {s}", .{msg}),
        raw.c.WGPUErrorType_Validation => log.err("Validation: {s}", .{msg}),
        raw.c.WGPUErrorType_OutOfMemory => log.err("Out of memory: {s}", .{msg}),
        raw.c.WGPUErrorType_Internal => log.err("Internal error: {s}", .{msg}),
        else => log.err("GPU error {d}: {s}", .{ err_type, msg }),
    }
}

const objc = struct {
    const SEL = ?*opaque {};
    const Class = ?*opaque {};

    extern fn sel_getUid(str: [*:0]const u8) SEL;
    extern fn objc_getClass(name: [*:0]const u8) Class;
    extern fn objc_msgSend() void;
};

fn msgSend(obj: *anyopaque, sel_name: [*:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const Fn = switch (@typeInfo(@TypeOf(args))) {
        .@"struct" => |info| blk: {
            var params: [info.fields.len + 2]std.builtin.Type.Fn.Param = undefined;
            params[0] = .{ .is_noalias = false, .type = *anyopaque };
            params[1] = .{ .is_noalias = false, .type = objc.SEL };
            inline for (info.fields, 0..) |field, i| {
                params[i + 2] = .{ .is_noalias = false, .type = field.type };
            }
            break :blk @Type(.{ .@"fn" = .{
                .calling_convention = .c,
                .is_generic = false,
                .is_var_args = false,
                .return_type = ReturnType,
                .params = &params,
            } });
        },
        else => @compileError("expected tuple args"),
    };

    const func: *const Fn = @ptrCast(&objc.objc_msgSend);
    const sel = objc.sel_getUid(sel_name) orelse @panic("missing Objective-C selector");
    return @call(.never_inline, func, .{ obj, sel } ++ args);
}
