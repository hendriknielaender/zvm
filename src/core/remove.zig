//! For removing the zig or zls
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../metadata.zig");
const util_data = @import("../util/data.zig");
const util_tool = @import("../util/tool.zig");
const context = @import("../Context.zig");
const paths = @import("../platform/paths.zig");
const limits = @import("../memory/limits.zig");
const detect_version = @import("detect_version.zig");
const assert = std.debug.assert;

/// Try remove specified version.
pub fn remove(ctx: *context.CliContext, version: []const u8, is_zls: bool) !void {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    const true_version = if (is_zls) map_zls_version(version) else version;
    assert(true_version.len > 0);

    if (!is_zls) {
        try clear_default_if_active(ctx, true_version);
    }

    var current_path_buffer = try ctx.scratch(.path);
    defer current_path_buffer.release();

    const current_path = try if (is_zls)
        util_data.get_zvm_current_zls(current_path_buffer)
    else
        util_data.get_zvm_current_zig(current_path_buffer);

    assert(current_path.len > 0);
    assert(current_path.len <= limits.path_length_maximum);

    // Remove the current symlink/manifest only when it points at the
    // version being removed; another active version must stay untouched.
    if (util_tool.does_path_exist(ctx.io, current_path)) {
        if (try version_is_active(ctx, true_version, is_zls)) {
            if (builtin.os.tag == .windows) {
                try std.Io.Dir.cwd().deleteTree(ctx.io, current_path);
            } else {
                try std.Io.Dir.deleteFileAbsolute(ctx.io, current_path);
            }
        }
    }

    // Get version path.
    var base_path_buffer = try ctx.scratch(.path);
    defer base_path_buffer.release();

    const base_path = try if (is_zls)
        util_data.get_zvm_zls_version(base_path_buffer)
    else
        util_data.get_zvm_zig_version(base_path_buffer);

    assert(base_path.len > 0);
    assert(base_path.len <= limits.path_length_maximum);

    var version_path_buffer = try ctx.scratch(.path);
    defer version_path_buffer.release();

    const version_path = try version_path_buffer.set(
        try std.fmt.bufPrint(version_path_buffer.slice(), "{s}/{s}", .{ base_path, true_version }),
    );

    assert(version_path.len > 0);
    assert(version_path.len <= limits.path_length_maximum);
    // Assert relationship: version_path contains base_path and true_version
    assert(version_path.len >= base_path.len + true_version.len + 1); // +1 for '/'

    // Try remove version path.
    if (util_tool.does_path_exist(ctx.io, version_path)) {
        assert(std.mem.indexOf(u8, version_path, paths.zvm_dir_name) != null);

        try std.Io.Dir.cwd().deleteTree(ctx.io, version_path);

        // Postcondition: deleteTree succeeded, so the version must be gone.
        assert(!util_tool.does_path_exist(ctx.io, version_path));
    }
}

/// Map a zls alias version to its true version using the metadata tables.
/// Unknown versions map to themselves.
fn map_zls_version(version: []const u8) []const u8 {
    assert(version.len > 0);
    assert(config.zls_list_1.len == config.zls_list_2.len);

    for (config.zls_list_1, config.zls_list_2) |alias_version, true_version| {
        if (util_tool.eql_str(alias_version, version)) return true_version;
    }
    return version;
}

/// Whether `version` is the active installation. Checks the default-version
/// marker first (smart Zig mode: current/zig points to zvm and the marker
/// identifies the active Zig), then falls back to the installation manifest.
fn version_is_active(ctx: *context.CliContext, version: []const u8, is_zls: bool) !bool {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    if (!is_zls) {
        var default_version_buffer: [limits.version_string_length_maximum]u8 = undefined;
        const default_version = detect_version.find_default_version_in_buffer(
            ctx,
            &default_version_buffer,
        ) catch null;

        if (default_version) |default_version_value| {
            if (util_tool.eql_str(default_version_value, version)) return true;
        }
    }

    var version_buffer = try ctx.scratch(.path);
    defer version_buffer.release();

    var output_buffer: [limits.temp_buffer_size]u8 = undefined;
    assert(output_buffer.len >= limits.version_string_length_maximum);

    const current_version = util_data.get_current_version(
        ctx.io,
        version_buffer,
        &output_buffer,
        is_zls,
    ) catch |err| switch (err) {
        error.EmptyVersion, error.FileNotFound => return false,
        else => return err,
    };

    assert(current_version.len > 0);
    assert(current_version.len <= output_buffer.len);
    return util_tool.eql_str(current_version, version);
}

fn clear_default_if_active(ctx: *context.CliContext, version: []const u8) !void {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    var default_version_buffer: [limits.version_string_length_maximum]u8 = undefined;
    const default_version = detect_version.find_default_version_in_buffer(
        ctx,
        &default_version_buffer,
    ) catch null;

    const value = default_version orelse return;
    if (!util_tool.eql_str(value, version)) return;

    var default_version_path_buffer = try ctx.scratch(.path);
    defer default_version_path_buffer.release();

    const default_version_path = try util_data.get_zvm_path_segment(
        default_version_path_buffer,
        "default_version",
    );

    std.Io.Dir.deleteFileAbsolute(ctx.io, default_version_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
