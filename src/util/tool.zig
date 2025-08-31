const std = @import("std");
const builtin = @import("builtin");
const object_pools = @import("../memory/object_pools.zig");

/// Cross-platform environment variable getter
pub fn getenv_cross_platform(var_name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, env vars need special handling due to WTF-16 encoding
        // For optional env vars, just return null
        return null;
    } else {
        return std.posix.getenv(var_name);
    }
}

/// eql str
pub fn eql_str(str1: []const u8, str2: []const u8) bool {
    return std.mem.eql(u8, str1, str2);
}

/// try to create path
pub fn try_create_path(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err|
        if (err != error.PathAlreadyExists) return err;
}

// check dir exist
pub fn does_path_exist(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

// Check if directory path exists
pub fn does_path_exist2(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

/// Nested copy dir using static allocation.
/// only copy dir and file, no including link
pub fn copy_dir_static(
    source_dir: []const u8,
    dest_dir: []const u8,
    source_path_buffer: *object_pools.PathBuffer,
    dest_path_buffer: *object_pools.PathBuffer,
) !void {
    var source = try std.fs.openDirAbsolute(source_dir, .{ .iterate = true });
    defer source.close();

    std.fs.makeDirAbsolute(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists)
            return err;
    };

    var dest = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest.close();

    var iterate = source.iterate();
    while (try iterate.next()) |entry| {
        const entry_name = entry.name;

        // Build source sub path.
        source_path_buffer.reset();
        var fbs_src = std.io.fixedBufferStream(source_path_buffer.slice());
        try fbs_src.writer().print("{s}/{s}", .{ source_dir, entry_name });
        const source_sub_path = try source_path_buffer.set(fbs_src.getWritten());

        // Build dest sub path.
        dest_path_buffer.reset();
        var fbs_dest = std.io.fixedBufferStream(dest_path_buffer.slice());
        try fbs_dest.writer().print("{s}/{s}", .{ dest_dir, entry_name });
        const dest_sub_path = try dest_path_buffer.set(fbs_dest.getWritten());

        switch (entry.kind) {
            .directory => try copy_dir_static(source_sub_path, dest_sub_path, source_path_buffer, dest_path_buffer),
            .file => try std.fs.copyFileAbsolute(source_sub_path, dest_sub_path, .{}),
            else => {},
        }
    }
}
