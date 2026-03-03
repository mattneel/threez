const std = @import("std");
const clap = @import("clap");
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

const version_string = "0.1.0";

// =============================================================================
// Subcommand definitions
// =============================================================================

const SubCommand = enum { run, version, help };

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommand),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

const run_params = clap.parseParamsComptime(
    \\-h, --help                  Display this help and exit.
    \\-W, --width <u32>           Window width (default: 1280).
    \\-H, --height <u32>          Window height (default: 720).
    \\-t, --title <str>           Window title (default: "threez").
    \\-a, --assets <str>          Assets directory for fetch() resolution.
    \\-m, --max-handles <u32>     Max GPU handle table capacity (default: 65536).
    \\    --strict                 Enable strict mode (abort on JS exceptions).
    \\<str>
    \\
);

// =============================================================================
// Entry point
// =============================================================================

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next(); // skip program name

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        printMainHelp();
        return;
    }

    const command = res.positionals[0] orelse {
        printMainHelp();
        std.process.exit(1);
    };

    switch (command) {
        .help => printMainHelp(),
        .version => {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("threez " ++ version_string ++ "\n") catch {};
        },
        .run => runMain(allocator, &iter) catch |err| {
            std.debug.print("error: {}\n", .{err});
            std.process.exit(1);
        },
    }
}

fn printMainHelp() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\threez — native Three.js runtime
        \\
        \\Usage: threez <command> [options]
        \\
        \\Commands:
        \\  run       Run a JavaScript file
        \\  version   Print version information
        \\  help      Display this help
        \\
        \\Use "threez run --help" for run-specific options.
        \\
    ) catch {};
}

// =============================================================================
// `threez run <script.js> [options]`
// =============================================================================

fn runMain(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &run_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll(
            \\threez run — run a JavaScript file
            \\
            \\Usage: threez run [options] <script.js>
            \\
            \\Options:
            \\  -W, --width <u32>        Window width (default: 1280)
            \\  -H, --height <u32>       Window height (default: 720)
            \\  -t, --title <str>        Window title (default: "threez")
            \\  -a, --assets <str>       Assets directory for fetch() resolution
            \\  -m, --max-handles <u32>  Max GPU handle table capacity (default: 65536)
            \\      --strict             Enable strict mode (abort on JS exceptions)
            \\  -h, --help               Display this help
            \\
        ) catch {};
        return;
    }

    const js_path = res.positionals[0] orelse {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("error: missing required argument: <script.js>\n\nUsage: threez run [options] <script.js>\n") catch {};
        std.process.exit(1);
    };

    const win_width: u32 = res.args.width orelse 1280;
    const win_height: u32 = res.args.height orelse 720;
    const title_owned = if (res.args.title) |t| try allocator.dupeZ(u8, t) else null;
    defer if (title_owned) |t| allocator.free(t);
    const win_title: [:0]const u8 = title_owned orelse "threez";
    const max_handles: u32 = res.args.@"max-handles" orelse HandleTable.default_capacity;
    _ = res.args.assets; // reserved for future use
    _ = res.args.strict; // reserved for future use

    try runScript(allocator, js_path, .{
        .width = win_width,
        .height = win_height,
        .title = win_title,
        .max_handles = max_handles,
    });
}

const RunConfig = struct {
    width: u32,
    height: u32,
    title: [:0]const u8,
    max_handles: u32,
};

/// State passed to GLFW callbacks via the window user pointer.
const CallbackState = struct {
    event_bridge: *EventBridge,
};

fn runScript(allocator: std.mem.Allocator, js_path: []const u8, config: RunConfig) !void {
    // Create the window (GLFW + zgpu/Dawn)
    var window = try Window.init(allocator, .{
        .width = config.width,
        .height = config.height,
        .title = config.title,
    });
    defer window.deinit();

    // Initialize JS engine
    var engine = try JsEngine.init(allocator);
    defer engine.deinit();

    // Timer queue
    var timer_queue = TimerQueue.init(allocator);
    defer timer_queue.deinit(engine.context);

    // Register polyfills (console, performance, encoding, fetch, timers, image)
    try polyfills.registerAll(engine.context, &timer_queue);

    // Handle table + GPU bridge
    var handle_table = try HandleTable.init(allocator, config.max_handles);
    defer handle_table.deinit(allocator);

    var gpu_bridge = try GpuBridge.init(&handle_table);
    defer gpu_bridge.deinit();
    try gpu_bridge.register(engine.context);

    // Run bootstrap (window, document, navigator, Event classes, etc.)
    try bootstrap.init(&engine);

    // Event loop (requestAnimationFrame, cancelAnimationFrame)
    var event_loop = EventLoop.init(allocator, &engine, &timer_queue);
    defer event_loop.deinit();
    try event_loop_mod.register(engine.context, &event_loop);

    // Event bridge (GLFW → DOM events)
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

    const js_canvas = blk: {
        var canvas_result = engine.eval("document.createElement('canvas')", "<main>") catch {
            return error.BootstrapFailed;
        };
        const val = canvas_result.value;
        _ = &canvas_result;
        break :blk val;
    };

    var event_bridge = EventBridge.init(engine.context, js_window, js_document, js_canvas);
    defer event_bridge.deinit();

    // Set up GLFW callbacks via user pointer
    var callback_state = CallbackState{ .event_bridge = &event_bridge };
    window.glfw_window.setUserPointer(@ptrCast(&callback_state));

    _ = window.glfw_window.setCursorPosCallback(&glfwCursorPosCallback);
    _ = window.glfw_window.setMouseButtonCallback(&glfwMouseButtonCallback);
    _ = window.glfw_window.setScrollCallback(&glfwScrollCallback);
    _ = window.glfw_window.setKeyCallback(&glfwKeyCallback);
    _ = window.glfw_window.setFramebufferSizeCallback(&glfwFramebufferSizeCallback);
    _ = window.glfw_window.setCursorEnterCallback(&glfwCursorEnterCallback);

    // Load and eval user script
    const js_source = std.fs.cwd().readFileAlloc(allocator, js_path, 64 * 1024 * 1024) catch |err| {
        std.debug.print("error: failed to read '{s}': {}\n", .{ js_path, err });
        std.process.exit(1);
    };
    defer allocator.free(js_source);

    const js_path_z = try allocator.dupeZ(u8, js_path);
    defer allocator.free(js_path_z);

    var result = engine.eval(js_source, js_path_z) catch |err| {
        std.debug.print("error: JS exception loading '{s}': {}\n", .{ js_path, err });
        std.process.exit(1);
    };
    result.deinit();

    // Pump microtasks / timers until the app registers its first rAF
    event_loop.pumpUntilReady();

    // Main loop
    while (!window.shouldClose()) {
        window.pollEvents();
        event_loop.tick();
    }
}

// =============================================================================
// GLFW Callback Trampolines
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
