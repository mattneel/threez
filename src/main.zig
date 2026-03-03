const std = @import("std");
const zglfw = @import("zglfw");
const quickjs = @import("quickjs");

const JsEngine = @import("js_engine.zig").JsEngine;
const bootstrap = @import("bootstrap.zig");
const polyfills = @import("polyfills.zig");
const TimerQueue = polyfills.timers.TimerQueue;
const event_loop_mod = @import("event_loop.zig");
const EventLoop = event_loop_mod.EventLoop;
const Window = @import("window.zig").Window;
const HandleTable = @import("handle_table.zig").HandleTable;
const GpuBridge = @import("gpu_bridge.zig").GpuBridge;
const EventBridge = @import("event_bridge.zig").EventBridge;

const log = std.log.scoped(.threez);

/// State passed to GLFW callbacks via the window user pointer.
const CallbackState = struct {
    event_bridge: *EventBridge,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // =========================================================================
    // Parse CLI args
    // =========================================================================
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name
    const js_path = args.next() orelse {
        log.err("Usage: threez <script.js>", .{});
        std.process.exit(1);
    };

    // =========================================================================
    // Create the window (GLFW + zgpu/Dawn)
    // =========================================================================
    var window = try Window.init(allocator, .{
        .width = 1280,
        .height = 720,
        .title = "threez",
    });
    defer window.deinit();

    // =========================================================================
    // Initialize JS engine
    // =========================================================================
    var engine = try JsEngine.init(allocator);
    defer engine.deinit();

    // =========================================================================
    // Timer queue
    // =========================================================================
    var timer_queue = TimerQueue.init(allocator);
    defer timer_queue.deinit(engine.context);

    // =========================================================================
    // Register polyfills (console, performance, encoding, fetch, timers, image)
    // =========================================================================
    try polyfills.registerAll(engine.context, &timer_queue);

    // =========================================================================
    // Handle table + GPU bridge
    // =========================================================================
    var handle_table = try HandleTable.init(allocator, HandleTable.default_capacity);
    defer handle_table.deinit(allocator);

    var gpu_bridge = try GpuBridge.init(&handle_table);
    defer gpu_bridge.deinit();
    try gpu_bridge.register(engine.context);

    // =========================================================================
    // Run bootstrap (window, document, navigator, Event classes, etc.)
    // =========================================================================
    try bootstrap.init(&engine);

    // =========================================================================
    // Event loop (requestAnimationFrame, cancelAnimationFrame)
    // =========================================================================
    var event_loop = EventLoop.init(allocator, &engine, &timer_queue);
    defer event_loop.deinit();
    try event_loop_mod.register(engine.context, &event_loop);

    // =========================================================================
    // Event bridge (GLFW -> DOM events)
    //
    // After bootstrap.init(), the global JS objects window, document, and the
    // canvas stub are available. We retrieve them and create the EventBridge.
    // =========================================================================
    const js_window = blk: {
        const global = engine.context.getGlobalObject();
        defer global.deinit(engine.context);
        break :blk global.getPropertyStr(engine.context, "window");
    };

    const js_document = blk: {
        const global = engine.context.getGlobalObject();
        defer global.deinit(engine.context);
        break :blk global.getPropertyStr(engine.context, "document");
    };

    // The bootstrap's DocumentStub returns the same canvas for every
    // createElement('canvas') call, so this gives us the shared canvas.
    const js_canvas = blk: {
        var canvas_result = engine.eval("document.createElement('canvas')", "<main>") catch {
            log.err("Failed to get canvas from bootstrap", .{});
            std.process.exit(1);
        };
        // Extract the raw Value and do NOT deinit the EvalResult wrapper,
        // because we want to keep the Value alive for EventBridge.
        const val = canvas_result.value;
        // We must still let the EvalResult know not to free it -- since
        // EvalResult.deinit frees .value, we avoid calling it. The Value
        // ownership transfers to EventBridge, which will deinit it.
        _ = &canvas_result; // suppress unused
        break :blk val;
    };

    var event_bridge = EventBridge.init(engine.context, js_window, js_document, js_canvas);
    defer event_bridge.deinit();

    // Set up GLFW callbacks via user pointer.
    var callback_state = CallbackState{
        .event_bridge = &event_bridge,
    };
    window.glfw_window.setUserPointer(@ptrCast(&callback_state));

    _ = window.glfw_window.setCursorPosCallback(&glfwCursorPosCallback);
    _ = window.glfw_window.setMouseButtonCallback(&glfwMouseButtonCallback);
    _ = window.glfw_window.setScrollCallback(&glfwScrollCallback);
    _ = window.glfw_window.setKeyCallback(&glfwKeyCallback);
    _ = window.glfw_window.setFramebufferSizeCallback(&glfwFramebufferSizeCallback);
    _ = window.glfw_window.setCursorEnterCallback(&glfwCursorEnterCallback);

    // =========================================================================
    // Load and eval user script
    // =========================================================================
    const js_source = std.fs.cwd().readFileAlloc(allocator, js_path, 64 * 1024 * 1024) catch |err| {
        log.err("Failed to read '{s}': {}", .{ js_path, err });
        std.process.exit(1);
    };
    defer allocator.free(js_source);

    // Null-terminate the path for QuickJS filename parameter.
    const js_path_z = try allocator.dupeZ(u8, js_path);
    defer allocator.free(js_path_z);

    var result = engine.eval(js_source, js_path_z) catch |err| {
        log.err("JS error loading '{s}': {}", .{ js_path, err });
        std.process.exit(1);
    };
    result.deinit();

    // Pump microtasks / timers until the app registers its first rAF.
    event_loop.pumpUntilReady();

    log.info("Entering main loop", .{});

    // =========================================================================
    // Main loop
    // =========================================================================
    while (!window.shouldClose()) {
        window.pollEvents();
        event_loop.tick();
        // Future: present frame via swapchain
    }

    log.info("Shutting down", .{});
}

// =============================================================================
// GLFW Callback Trampolines
//
// These are C-calling-convention functions that retrieve the CallbackState
// from the GLFW window user pointer and forward to the EventBridge.
// =============================================================================

fn glfwCursorPosCallback(glfw_win: *zglfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onMouseMove(xpos, ypos);
}

fn glfwMouseButtonCallback(
    glfw_win: *zglfw.Window,
    button: zglfw.MouseButton,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onMouseButton(
        @intFromEnum(button),
        @intFromEnum(action),
        @bitCast(mods),
    );
}

fn glfwScrollCallback(glfw_win: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onScroll(xoffset, yoffset);
}

fn glfwKeyCallback(
    glfw_win: *zglfw.Window,
    key: zglfw.Key,
    scancode: c_int,
    action: zglfw.Action,
    mods: zglfw.Mods,
) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onKey(
        @intFromEnum(key),
        scancode,
        @intFromEnum(action),
        @bitCast(mods),
    );
}

fn glfwFramebufferSizeCallback(glfw_win: *zglfw.Window, width: c_int, height: c_int) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onResize(@intCast(width), @intCast(height));
}

fn glfwCursorEnterCallback(glfw_win: *zglfw.Window, entered: c_int) callconv(.c) void {
    const state = glfw_win.getUserPointer(CallbackState) orelse return;
    state.event_bridge.onCursorEnter(entered != 0);
}
