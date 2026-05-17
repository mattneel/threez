const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 4) {
        std.debug.print("Usage: dawn_configure_check <src_dir> <build_dir> <stamp_file> [cmake_args...]\n", .{});
        return error.InvalidArgs;
    }

    const src_dir = args[1];
    const build_dir = args[2];
    const stamp_file = args[3];
    
    // Collect cmake args (everything after the first 3 arguments)
    const cmake_args = args[4..];

    // Key CMake files to monitor for changes
    const cmake_files = [_][]const u8{
        "CMakeLists.txt",
        "cmake/Config.cmake",
        "cmake/DawnDependencies.cmake",
        "cmake/DawnUtils.cmake",
        "cmake/TintDependencies.cmake",
    };

    // Check if stamp file exists
    const stamp_exists = blk: {
        _ = std.fs.cwd().statFile(stamp_file) catch break :blk false;
        break :blk true;
    };

    if (stamp_exists) {
        const stamp_stat = try std.fs.cwd().statFile(stamp_file);
        const stamp_mtime = stamp_stat.mtime;

        var needs_reconfigure = false;
        for (cmake_files) |cmake_file| {
            const cmake_path = try std.fs.path.join(allocator, &.{ src_dir, cmake_file });
            defer allocator.free(cmake_path);

            const cmake_file_exists = blk: {
                _ = std.fs.cwd().statFile(cmake_path) catch break :blk false;
                break :blk true;
            };
            
            if (cmake_file_exists) {
                const cmake_stat = try std.fs.cwd().statFile(cmake_path);
                if (cmake_stat.mtime > stamp_mtime) {
                    std.debug.print("CMake file {s} is newer than stamp, reconfiguring\n", .{cmake_file});
                    needs_reconfigure = true;
                    break;
                }
            }
        }

        if (!needs_reconfigure) {
            const build_exists = blk: {
            var dir = std.fs.cwd().openDir(build_dir, .{}) catch break :blk false;
            dir.close();
            break :blk true;
        };
            if (!build_exists) {
                std.debug.print("Build directory doesn't exist, reconfiguring\n", .{});
                needs_reconfigure = true;
            }
        }

        if (!needs_reconfigure) {
            std.debug.print("CMake configuration is up-to-date, skipping\n", .{});
            return;
        }
    } else {
        std.debug.print("Stamp file doesn't exist, configuring\n", .{});
    }

    std.debug.print("Running CMake configuration...\n", .{});

    // Run CMake configuration with the provided args
    const cmake_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = cmake_args,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(cmake_result.stdout);
    defer allocator.free(cmake_result.stderr);

    if (cmake_result.stdout.len > 0) {
        std.debug.print("{s}", .{cmake_result.stdout});
    }
    if (cmake_result.stderr.len > 0) {
        std.debug.print("{s}", .{cmake_result.stderr});
    }

    switch (cmake_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("CMake configuration failed with exit code {d}\n", .{code});
            return error.CMakeFailed;
        },
        else => {
            std.debug.print("CMake configuration failed\n", .{});
            return error.CMakeFailed;
        },
    }

    // Create stamp file
    const stamp_dir = std.fs.path.dirname(stamp_file) orelse ".";
    try std.fs.cwd().makePath(stamp_dir);
    
    const stamp_file_handle = try std.fs.cwd().createFile(stamp_file, .{});
    defer stamp_file_handle.close();
    
    const timestamp = std.time.timestamp();
    var buf: [64]u8 = undefined;
    const timestamp_str = try std.fmt.bufPrint(&buf, "{d}\n", .{timestamp});
    try stamp_file_handle.writeAll(timestamp_str);
    
    std.debug.print("CMake configuration completed, stamp file created\n", .{});
}