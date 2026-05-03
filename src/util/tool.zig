const std = @import("std");
const object_pools = @import("../memory/object_pools.zig");
const assert = std.debug.assert;

var environment_map: ?*const std.process.Environ.Map = null;

pub fn set_environment_map(map: *const std.process.Environ.Map) void {
    environment_map = map;
}

pub fn get_environment_map() ?*const std.process.Environ.Map {
    return environment_map;
}

/// Cross-platform environment variable getter
pub fn getenv_cross_platform(var_name: []const u8) ?[]const u8 {
    if (environment_map) |map| return map.get(var_name);
    return null;
}

/// eql str
pub fn eql_str(str1: []const u8, str2: []const u8) bool {
    return std.mem.eql(u8, str1, str2);
}

/// Detects a pinned Zig dev build such as `0.16.0-dev.2973+06b85a4fd`.
/// Dev builds are only published under the `master` key in `index.json`,
/// so callers must resolve them via the master entry and verify that the
/// entry's `version` field matches exactly.
pub fn is_dev_version(version: []const u8) bool {
    assert(version.len > 0);
    assert(version.len < 128);
    return std.mem.indexOf(u8, version, "-dev.") != null;
}

/// Detects any version that lives under the `master` index entry: the
/// literal `master` alias and pinned dev builds. Used to pick master-style
/// arch naming and the master lookup path during install.
pub fn is_master_like_version(version: []const u8) bool {
    assert(version.len > 0);
    assert(version.len < 128);
    return eql_str(version, "master") or is_dev_version(version);
}

/// try to create path
pub fn try_create_path(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

// check dir exist
pub fn does_path_exist(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

// Check if directory path exists
pub fn does_path_exist2(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

/// Nested copy dir using static allocation.
/// only copy dir and file, no including link
pub fn copy_dir_static(
    io: std.Io,
    source_dir: []const u8,
    dest_dir: []const u8,
    source_path_buffer: *object_pools.PathBuffer,
    dest_path_buffer: *object_pools.PathBuffer,
) !void {
    var source = try std.Io.Dir.openDirAbsolute(io, source_dir, .{ .iterate = true });
    defer source.close(io);

    std.Io.Dir.createDirAbsolute(io, dest_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists)
            return err;
    };

    var dest = try std.Io.Dir.openDirAbsolute(io, dest_dir, .{ .iterate = true });
    defer dest.close(io);

    var iterate = source.iterate();
    while (try iterate.next(io)) |entry| {
        const entry_name = entry.name;

        // Build source sub path.
        source_path_buffer.reset();
        const source_sub_path = try source_path_buffer.set(
            try std.fmt.bufPrint(source_path_buffer.slice(), "{s}/{s}", .{ source_dir, entry_name }),
        );

        // Build dest sub path.
        dest_path_buffer.reset();
        const dest_sub_path = try dest_path_buffer.set(
            try std.fmt.bufPrint(dest_path_buffer.slice(), "{s}/{s}", .{ dest_dir, entry_name }),
        );

        switch (entry.kind) {
            .directory => try copy_dir_static(io, source_sub_path, dest_sub_path, source_path_buffer, dest_path_buffer),
            .file => try std.Io.Dir.copyFileAbsolute(source_sub_path, dest_sub_path, io, .{}),
            else => {},
        }
    }
}
