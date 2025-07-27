//! For removing the zig or zls
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util_data = @import("util/data.zig");
const util_tool = @import("util/tool.zig");
const context = @import("context.zig");
const limits = @import("limits.zig");

/// Try remove specified version.
pub fn remove(ctx: *context.CliContext, version: []const u8, is_zls: bool, debug: bool) !void {
    _ = debug;

    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version.len > 0);
    std.debug.assert(version.len < 100); // Reasonable version length

    const true_version = blk: {
        if (!is_zls)
            break :blk version;
        for (config.zls_list_1, 0..) |val, i| {
            // Validate index bounds
            std.debug.assert(i < config.zls_list_1.len);
            std.debug.assert(i < config.zls_list_2.len);

            if (util_tool.eql_str(val, version))
                break :blk config.zls_list_2[i];
        }
        break :blk version;
    };

    std.debug.assert(true_version.len > 0);
    std.debug.assert(true_version.len <= version.len or is_zls);

    // Get current path using path buffer.
    var current_path_buffer = try ctx.acquire_path_buffer();
    defer current_path_buffer.reset();
    // current_path_buffer is a pointer, not optional - no need for null check

    const current_path = try if (is_zls)
        util_data.get_zvm_current_zls(current_path_buffer)
    else
        util_data.get_zvm_current_zig(current_path_buffer);

    std.debug.assert(current_path.len > 0);
    std.debug.assert(current_path.len <= limits.limits.path_length_maximum);

    // Try remove current path.
    if (util_tool.does_path_exist(current_path)) {
        // Get current version.
        var version_buffer = try ctx.acquire_path_buffer();
        defer version_buffer.reset();
        // version_buffer is a pointer, not optional - no need for null check

        var output_buffer: [256]u8 = undefined;
        // Validate buffer size
        std.debug.assert(output_buffer.len >= 256);
        std.debug.assert(output_buffer.len >= limits.limits.version_string_length_maximum);

        const current_version = try util_data.get_current_version(
            version_buffer,
            &output_buffer,
            is_zls,
        );

        std.debug.assert(current_version.len > 0);
        std.debug.assert(current_version.len <= output_buffer.len);

        if (util_tool.eql_str(current_version, true_version)) {
            if (builtin.os.tag == .windows) {
                try std.fs.deleteTreeAbsolute(current_path);
            } else {
                try std.fs.deleteFileAbsolute(current_path);
            }
        }
    }

    // Get version path.
    var base_path_buffer = try ctx.acquire_path_buffer();
    defer base_path_buffer.reset();
    // base_path_buffer is a pointer, not optional - no need for null check

    const base_path = try if (is_zls)
        util_data.get_zvm_zls_version(base_path_buffer)
    else
        util_data.get_zvm_zig_version(base_path_buffer);

    std.debug.assert(base_path.len > 0);
    std.debug.assert(base_path.len <= limits.limits.path_length_maximum);

    var version_path_buffer = try ctx.acquire_path_buffer();
    defer version_path_buffer.reset();
    // version_path_buffer is a pointer, not optional - no need for null check

    var fbs = std.io.fixedBufferStream(version_path_buffer.slice());
    try fbs.writer().print("{s}/{s}", .{ base_path, true_version });
    const version_path = try version_path_buffer.set(fbs.getWritten());

    std.debug.assert(version_path.len > 0);
    std.debug.assert(version_path.len <= limits.limits.path_length_maximum);
    // Assert relationship: version_path contains base_path and true_version
    std.debug.assert(version_path.len >= base_path.len + true_version.len + 1); // +1 for '/'

    // Try remove version path.
    if (util_tool.does_path_exist(version_path)) {
        std.debug.assert(std.mem.indexOf(u8, version_path, ".zm") != null);

        try std.fs.deleteTreeAbsolute(version_path);

        if (!util_tool.does_path_exist(version_path)) {
            std.debug.assert(!util_tool.does_path_exist(version_path));
        }
    }
}
