const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");

pub const WindowConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "threez",
};

pub const Window = struct {
    glfw_window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,

    /// Create a GLFW window backed by a zgpu GraphicsContext (Dawn/WebGPU).
    /// The GraphicsContext owns the GPU instance, device, surface, and swapchain.
    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        // Initialise GLFW
        try zglfw.init();
        errdefer zglfw.terminate();

        // Tell GLFW we do not want an OpenGL context — we are using WebGPU/Dawn.
        zglfw.Window.Hint.set(.client_api, .no_api);

        const glfw_window = try zglfw.createWindow(
            @intCast(config.width),
            @intCast(config.height),
            config.title,
            null,
            null,
        );
        errdefer zglfw.destroyWindow(glfw_window);

        // Build the WindowProvider that zgpu needs.
        const window_provider = zgpu.WindowProvider{
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

        // Create the zgpu GraphicsContext — this creates instance, adapter,
        // device, surface, and swapchain all in one call.
        const gctx = try zgpu.GraphicsContext.create(allocator, window_provider, .{});

        return .{
            .glfw_window = glfw_window,
            .gctx = gctx,
            .allocator = allocator,
        };
    }

    /// Tear down GPU resources, destroy the GLFW window, and terminate GLFW.
    pub fn deinit(self: *Window) void {
        self.gctx.destroy(self.allocator);
        zglfw.destroyWindow(self.glfw_window);
        zglfw.terminate();
    }

    /// Returns true when the user has requested the window to close.
    pub fn shouldClose(self: *const Window) bool {
        return self.glfw_window.shouldClose();
    }

    /// Pump the GLFW event queue.
    pub fn pollEvents(_: *Window) void {
        zglfw.pollEvents();
    }

    /// Return the window size in screen coordinates.
    pub fn getSize(self: *const Window) struct { width: u32, height: u32 } {
        const size = self.glfw_window.getSize();
        return .{
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
        };
    }

    /// Return the framebuffer size in pixels (may differ from window size on HiDPI).
    pub fn getFramebufferSize(self: *const Window) struct { width: u32, height: u32 } {
        const size = self.glfw_window.getFramebufferSize();
        return .{
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
        };
    }

    /// Return the content scale factor (≈ devicePixelRatio in browser terms).
    /// Uses the X axis scale; on most systems X == Y.
    pub fn getContentScale(self: *const Window) f32 {
        const scale = self.glfw_window.getContentScale();
        return scale[0];
    }

    // --- Convenience accessors for the underlying GPU objects ---

    pub fn getInstance(self: *const Window) zgpu.wgpu.Instance {
        return self.gctx.instance;
    }

    pub fn getDevice(self: *const Window) zgpu.wgpu.Device {
        return self.gctx.device;
    }

    pub fn getQueue(self: *const Window) zgpu.wgpu.Queue {
        return self.gctx.queue;
    }

    pub fn getSurface(self: *const Window) zgpu.wgpu.Surface {
        return self.gctx.surface;
    }
};
