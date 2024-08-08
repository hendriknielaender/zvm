//! For removing the zig or zls
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util_data = @import("util/data.zig");
const util_tool = @import("util/tool.zig");

/// try remove specified version
pub fn remove(version: []const u8, is_zls: bool) !void {
    const true_version = blk: {
        if (!is_zls)
            break :blk version;
        for (config.zls_list_1, 0..) |val, i| {
            if (util_tool.eql_str(val, version))
                break :blk config.zls_list_2[i];
        }
        break :blk version;
    };

    var arena = std.heap.ArenaAllocator.init(util_data.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const current_path = try if (is_zls) util_data.get_zvm_current_zls(allocator) else util_data.get_zvm_current_zig(allocator);

    // try remove current path
    if (util_tool.does_path_exist(current_path)) {
        const current_version = try util_data.get_current_version(allocator, is_zls);
        if (util_tool.eql_str(current_version, true_version)) {
            if (builtin.os.tag == .windows) {
                try std.fs.deleteTreeAbsolute(current_path);
            } else {
                try std.fs.deleteFileAbsolute(current_path);
            }
        }
    }

    const version_path = try std.fs.path.join(allocator, &.{
        try if (is_zls)
            util_data.get_zvm_zls_version(allocator)
        else
            util_data.get_zvm_zig_version(allocator),
        true_version,
    });

    // try remove version path
    if (util_tool.does_path_exist(version_path)) {
        try std.fs.deleteTreeAbsolute(version_path);
    }
}
