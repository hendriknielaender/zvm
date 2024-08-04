const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const tools = @import("tools.zig");
const config = @import("config.zig");

/// try to set zig version
/// this will use system link on unix-like
/// for windows, this will use copy dir
pub fn set_zig_version(version: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const user_home = tools.get_home();
    const version_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ user_home, ".zm", "versions", version });
    const symlink_path = try tools.get_zvm_path_segment(arena_allocator, "current");

    try update_current(version_path, symlink_path);
    try verify_zig_version(version);
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

    const actual_version = try tools.get_zig_version(allocator);
    defer allocator.free(actual_version);

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        std.debug.print("Expected Zig version {s}, but currently using {s}. Please check.\n", .{ expected_version, actual_version });
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expected_version});
    }
}
