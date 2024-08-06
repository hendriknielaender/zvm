const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const tools = @import("tools.zig");
const config = @import("config.zig");

/// try to set zig version
/// this will use system link on unix-like
/// for windows, this will use copy dir
pub fn set_version(version: []const u8, is_zls: bool) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    try tools.try_create_path(try tools.get_zvm_path_segment(arena_allocator, "current"));

    const version_path = try std.fs.path.join(
        arena_allocator,
        &.{
            if (is_zls)
                try tools.get_zvm_zls_version(arena_allocator)
            else
                try tools.get_zvm_zig_version(arena_allocator),
            version,
        },
    );

    std.fs.accessAbsolute(version_path, .{}) catch |err| {
        if (err != error.FileNotFound)
            return err;

        std.debug.print("zig {s} is not installed, please install it!\n", .{version});
        std.process.exit(1);
    };

    const symlink_path = if (is_zls)
        try tools.get_zvm_current_zls(arena_allocator)
    else
        try tools.get_zvm_current_zig(arena_allocator);

    try update_current(version_path, symlink_path);
    if (is_zls) {
        try verify_zls_version(version);
    } else {
        try verify_zig_version(version);
    }
}

fn update_current(zig_path: []const u8, symlink_path: []const u8) !void {
    assert(zig_path.len > 0);
    assert(symlink_path.len > 0);

    if (builtin.os.tag == .windows) {
        if (tools.does_path_exist(symlink_path)) try std.fs.deleteTreeAbsolute(symlink_path);
        try tools.copy_dir(zig_path, symlink_path);
        return;
    }

    // when platform is not windows, this is execute here

    // when file exist(it is a systemlink), delete it
    if (tools.does_path_exist(symlink_path)) try std.fs.cwd().deleteFile(symlink_path);

    // system link it
    try std.posix.symlink(zig_path, symlink_path);
}

/// verify current zig version
fn verify_zig_version(expected_version: []const u8) !void {
    const allocator = tools.get_allocator();

    const actual_version = try tools.get_version(allocator, false);
    defer allocator.free(actual_version);

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        std.debug.print("Expected Zig version {s}, but currently using {s}. Please check.\n", .{ expected_version, actual_version });
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expected_version});
    }
}

/// verify current zig version
fn verify_zls_version(expected_version: []const u8) !void {
    const allocator = tools.get_allocator();

    const actual_version = try tools.get_version(allocator, true);
    defer allocator.free(actual_version);

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        std.debug.print("Expected Zls version {s}, but currently using {s}. Please check.\n", .{ expected_version, actual_version });
    } else {
        std.debug.print("Now using Zls version {s}\n", .{expected_version});
    }
}
