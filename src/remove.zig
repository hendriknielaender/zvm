const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const tools = @import("tools.zig");

/// try remove specified version
pub fn remove(version: []const u8, is_zls: bool) !void {
    const true_version = blk: {
        if (!is_zls)
            break :blk version;
        for (config.zls_list_1, 0..) |val, i| {
            if (tools.eql_str(val, version))
                break :blk config.zls_list_2[i];
        }
        break :blk version;
    };

    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const current_path = try if (is_zls) tools.get_zvm_current_zls(allocator) else tools.get_zvm_current_zig(allocator);

    // try remove current path
    if (tools.does_path_exist(current_path)) {
        const current_version = try tools.get_current_version(allocator, is_zls);
        if (tools.eql_str(current_version, true_version)) {
            if (builtin.os.tag == .windows) {
                try std.fs.deleteTreeAbsolute(current_path);
            } else {
                try std.fs.deleteFileAbsolute(current_path);
            }
        }
    }

    const version_path = try std.fs.path.join(allocator, &.{
        try if (is_zls)
            tools.get_zvm_zls_version(allocator)
        else
            tools.get_zvm_zig_version(allocator),
        true_version,
    });

    // try remove version path
    if (tools.does_path_exist(version_path)) {
        try std.fs.deleteTreeAbsolute(version_path);
    }
}
