const std = @import("std");
const data = @import("data.zig");

/// Free str array
pub fn free_str_array(str_arr: []const []const u8, allocator: std.mem.Allocator) void {
    for (str_arr) |str|
        allocator.free(str);

    allocator.free(str_arr);
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

/// Nested copy dir
/// only copy dir and file, no including link
pub fn copy_dir(source_dir: []const u8, dest_dir: []const u8) !void {
    var source = try std.fs.openDirAbsolute(source_dir, .{ .iterate = true });
    defer source.close();

    std.fs.makeDirAbsolute(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists)
            return err;
    };

    var dest = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest.close();

    var iterate = source.iterate();
    const allocator = data.get_allocator();
    while (try iterate.next()) |entry| {
        const entry_name = entry.name;

        const source_sub_path = try std.fs.path.join(allocator, &.{ source_dir, entry_name });
        defer allocator.free(source_sub_path);

        const dest_sub_path = try std.fs.path.join(allocator, &.{ dest_dir, entry_name });
        defer allocator.free(dest_sub_path);

        switch (entry.kind) {
            .directory => try copy_dir(source_sub_path, dest_sub_path),
            .file => try std.fs.copyFileAbsolute(source_sub_path, dest_sub_path, .{}),
            else => {},
        }
    }
}
