const std = @import("std");
const threez = @import("threez");

const embedded_script = @embedFile("triangle/main.js");

pub fn main() !void {
    const cfg = threez.runtime.RuntimeConfig{
        .source_name = "<embedded:triangle>",
        .script_dir = "examples/triangle",
        .assets_dir = "examples/triangle",
        .error_mode = .resilient,
    };

    _ = cfg;
    _ = threez.runtime.init;
    _ = threez.runtime.Runtime.runLoop;

    std.debug.print("embed-check script bytes: {}\n", .{embedded_script.len});
}
