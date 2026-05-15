const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 4) {
        std.debug.print("Usage: stage_android_assets <output_dir> <bundle_js> <assets_dir>\n", .{});
        std.process.exit(1);
    }

    const output_dir = args[1];
    const bundle_js = args[2];
    const assets_dir = args[3];

    // Create output directory structure
    try std.fs.cwd().makePath(output_dir);
    try std.fs.cwd().makePath(try std.fs.path.join(allocator, &.{ output_dir, "assets" }));

    // Copy bundle.js to app.js using readAll/writeAll
    {
        const app_js_path = try std.fs.path.join(allocator, &.{ output_dir, "app.js" });
        defer allocator.free(app_js_path);
        const contents = try std.fs.cwd().readFileAlloc(allocator, bundle_js, std.math.maxInt(usize));
        defer allocator.free(contents);
        try std.fs.cwd().writeFile(.{ .sub_path = app_js_path, .data = contents });
    }

    // Copy all files from assets directory
    {
        var assets_dir_obj = try std.fs.cwd().openDir(assets_dir, .{ .iterate = true });
        defer assets_dir_obj.close();

        var iter = assets_dir_obj.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            const src_path = try std.fs.path.join(allocator, &.{ assets_dir, entry.name });
            defer allocator.free(src_path);
            const dst_path = try std.fs.path.join(allocator, &.{ output_dir, "assets", entry.name });
            defer allocator.free(dst_path);

            const contents = try std.fs.cwd().readFileAlloc(allocator, src_path, std.math.maxInt(usize));
            defer allocator.free(contents);
            try std.fs.cwd().writeFile(.{ .sub_path = dst_path, .data = contents });
        }
    }

    std.debug.print("Staged Android assets to {s}\n", .{output_dir});

    // Check for memory leaks
    _ = gpa.deinit();
}