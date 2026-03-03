const std = @import("std");
const clap = @import("clap");
const runtime_mod = @import("runtime.zig");
const HandleTable = @import("handle_table.zig").HandleTable;

const log = std.log.scoped(.threez);

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
            log.err("run failed: {}", .{err});
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
    const assets_dir = res.args.assets;
    const error_mode: runtime_mod.ErrorMode = if (res.args.strict != 0) .fail_fast else .resilient;

    const js_source = std.fs.cwd().readFileAlloc(allocator, js_path, 64 * 1024 * 1024) catch |err| {
        log.err("failed to read '{s}': {}", .{ js_path, err });
        return err;
    };
    defer allocator.free(js_source);

    // Keep a sentinel byte after the script contents. QuickJS receives an
    // explicit length, but some parser paths are more stable with a trailing 0.
    const js_source_z = try allocator.dupeZ(u8, js_source);
    defer allocator.free(js_source_z);

    const script_dir = std.fs.path.dirname(js_path) orelse ".";
    try runScript(allocator, js_source_z[0 .. js_source_z.len - 1], .{
        .width = win_width,
        .height = win_height,
        .title = win_title,
        .max_handles = max_handles,
        .assets_dir = assets_dir,
        .script_dir = script_dir,
        .source_name = js_path,
        .error_mode = error_mode,
    });
}

fn runScript(
    allocator: std.mem.Allocator,
    js_source: []const u8,
    config: runtime_mod.RuntimeConfig,
) !void {
    const runtime = try runtime_mod.init(allocator, js_source, config);
    defer runtime.deinit();
    try runtime.runLoop();
}
