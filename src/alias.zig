//! This file is used to create soft links and verify version
//! for Windows, we will use copy dir (creating symlinks requires admin privileges)
//! for setting versions.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const util_data = @import("util/data.zig");
const util_tool = @import("util/tool.zig");

/// Try to set the Zig version.
/// This will use a symlink on Unix-like systems.
/// For Windows, this will copy the directory.
pub fn set_version(version: []const u8, is_zls: bool) !void {
    var arena = std.heap.ArenaAllocator.init(util_data.get_allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    try util_tool.try_create_path(try util_data.get_zvm_path_segment(arena_allocator, "current"));

    const version_path = try std.fs.path.join(
        arena_allocator,
        &.{
            if (is_zls)
                try util_data.get_zvm_zls_version(arena_allocator)
            else
                try util_data.get_zvm_zig_version(arena_allocator),
            version,
        },
    );

    std.fs.accessAbsolute(version_path, .{}) catch |err| {
        if (err != error.FileNotFound)
            return err;

        const err_msg = "{s} version {s} is not installed. Please install it before proceeding.\n";
        try std.io.getStdErr().writer().print(err_msg, .{ if (is_zls) "zls" else "Zig", version });
        std.process.exit(1);
    };

    const symlink_path = if (is_zls)
        try util_data.get_zvm_current_zls(arena_allocator)
    else
        try util_data.get_zvm_current_zig(arena_allocator);

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
        if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteTreeAbsolute(symlink_path);
        try util_tool.copy_dir(zig_path, symlink_path);
        return;
    }

    // Remove existing symlink if it exists
    if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteFileAbsolute(symlink_path);

    // Create symlink to the version directory
    try std.posix.symlink(zig_path, symlink_path);
}

/// Verify the current Zig version
fn verify_zig_version(expected_version: []const u8) !void {
    const allocator = util_data.get_allocator();

    const actual_version = try util_data.get_current_version(allocator, false);
    defer allocator.free(actual_version);

    var stdout = std.io.getStdOut().writer();

    if (std.mem.eql(u8, expected_version, "master")) {
        try stdout.print("Now using Zig version {s}\n", .{actual_version});
    } else if (!std.mem.eql(u8, expected_version, actual_version)) {
        const err_msg = "Expected Zig version {s}, but currently using {s}. Please check.\n";
        try std.io.getStdErr().writer().print(err_msg, .{ expected_version, actual_version });
    } else {
        try stdout.print("Now using Zig version {s}\n", .{expected_version});
    }
}

/// Verify the current zls version
fn verify_zls_version(expected_version: []const u8) !void {
    const allocator = util_data.get_allocator();

    const actual_version = try util_data.get_current_version(allocator, true);
    defer allocator.free(actual_version);

    var stdout = std.io.getStdOut().writer();

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        const err_msg = "Expected zls version {s}, but currently using {s}. Please check.\n";
        try std.io.getStdErr().writer().print(err_msg, .{ expected_version, actual_version });
    } else {
        try stdout.print("Now using zls version {s}\n", .{expected_version});
    }
}
