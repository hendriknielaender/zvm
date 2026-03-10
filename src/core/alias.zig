//! This file is used to create soft links and verify version
//! for Windows, we will use copy dir (creating symlinks requires admin privileges)
//! for setting versions.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const util_data = @import("../util/data.zig");
const util_tool = @import("../util/tool.zig");
const util_output = @import("../util/output.zig");
const context = @import("../Context.zig");
const object_pools = @import("../memory/object_pools.zig");
const limits = @import("../memory/limits.zig");

const log = std.log.scoped(.alias);

/// Try to set the Zig version.
/// This will use a symlink on Unix-like systems.
/// For Windows, this will copy the directory.
pub fn set_version(ctx: *context.CliContext, version: []const u8, is_zls: bool) !void {
    // Create current directory path.
    var current_dir_buffer = try ctx.acquire_path_buffer();
    defer current_dir_buffer.reset();
    const current_dir = try util_data.get_zvm_path_segment(current_dir_buffer, "current");
    try util_tool.try_create_path(current_dir);

    // Get version path.
    var base_path_buffer = try ctx.acquire_path_buffer();
    defer base_path_buffer.reset();
    const base_path = if (is_zls)
        try util_data.get_zvm_zls_version(base_path_buffer)
    else
        try util_data.get_zvm_zig_version(base_path_buffer);

    var version_path_buffer = try ctx.acquire_path_buffer();
    defer version_path_buffer.reset();
    var fbs = std.Io.fixedBufferStream(version_path_buffer.slice());
    try fbs.writer().print("{s}/{s}", .{ base_path, version });
    const version_path = try version_path_buffer.set(fbs.getWritten());

    std.fs.accessAbsolute(version_path, .{}) catch |err| {
        if (err != error.FileNotFound)
            return err;

        util_output.fatal(
            .version_not_found,
            "{s} version {s} is not installed. Please install it before proceeding.",
            .{ if (is_zls) "zls" else "Zig", version },
        );
    };

    ensure_version_manifest(version_path, version) catch |err| switch (err) {
        error.PathAlreadyExists => unreachable,
        else => return err,
    };

    // Get symlink path.
    var symlink_path_buffer = try ctx.acquire_path_buffer();
    defer symlink_path_buffer.reset();
    const symlink_path = if (is_zls)
        try util_data.get_zvm_current_zls(symlink_path_buffer)
    else
        try util_data.get_zvm_current_zig(symlink_path_buffer);

    try update_current(version_path, symlink_path);

    if (is_zls) {
        try verify_zls_version(ctx, version);
    } else {
        // Persist the fallback version after the current link is valid.
        try save_default_version(ctx, version);
        try verify_zig_version(ctx, version);
    }
}

fn ensure_version_manifest(version_path: []const u8, version: []const u8) !void {
    assert(version_path.len > 0);
    assert(version.len > 0);

    var manifest_path_buffer: [limits.limits.path_length_maximum]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}/{s}",
        .{ version_path, util_data.version_manifest_name },
    );

    if (util_tool.does_path_exist(manifest_path)) {
        return;
    }

    try util_data.write_version_manifest(version_path, version);
}

fn save_default_version(ctx: *context.CliContext, version: []const u8) !void {
    var default_version_path_buffer = try ctx.acquire_path_buffer();
    defer default_version_path_buffer.reset();

    const default_version_path = try util_data.get_zvm_path_segment(
        default_version_path_buffer,
        "default_version",
    );
    const zvm_dir = std.fs.path.dirname(default_version_path) orelse {
        log.err("Invalid default version path: {s}", .{default_version_path});
        return error.InvalidDefaultVersionPath;
    };

    try util_tool.try_create_path(zvm_dir);

    const file = try std.fs.cwd().createFile(default_version_path, .{});
    defer file.close();

    try file.writeAll(version);
}

fn update_current(zig_path: []const u8, symlink_path: []const u8) !void {
    assert(zig_path.len > 0);
    assert(symlink_path.len > 0);

    if (builtin.os.tag == .windows) {
        if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteTreeAbsolute(symlink_path);
        // For Windows, use temporary buffers for copying directories.
        // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
        var source_buffer: object_pools.PathBuffer = .{ .data = undefined };
        // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
        var dest_buffer: object_pools.PathBuffer = .{ .data = undefined };
        try util_tool.copy_dir_static(zig_path, symlink_path, &source_buffer, &dest_buffer);
        return;
    }

    const symlink_dirname = std.fs.path.dirname(symlink_path) orelse {
        log.err("Invalid current path: {s}", .{symlink_path});
        return error.InvalidCurrentPath;
    };
    const symlink_basename = std.fs.path.basename(symlink_path);

    var current_dir = try std.fs.openDirAbsolute(symlink_dirname, .{});
    defer current_dir.close();

    var temp_name_buffer: [64]u8 = undefined;
    while (true) {
        const temp_name = try std.fmt.bufPrint(
            &temp_name_buffer,
            "{s}.tmp.{x}",
            .{ symlink_basename, std.crypto.random.int(u64) },
        );

        current_dir.symLink(zig_path, temp_name, .{ .is_directory = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer current_dir.deleteFile(temp_name) catch {};

        try current_dir.rename(temp_name, symlink_basename);
        break;
    }
}

/// Verify the current Zig version.
fn verify_zig_version(ctx: *context.CliContext, expected_version: []const u8) !void {
    var path_buffer = try ctx.acquire_path_buffer();
    defer path_buffer.reset();
    var output_buffer: [limits.limits.temp_buffer_size]u8 = undefined;

    const actual_version = try util_data.get_current_version(
        path_buffer,
        &output_buffer,
        false,
    );

    if (std.mem.eql(u8, expected_version, "master")) {
        emit_selected_version("zig", expected_version, actual_version);
        return;
    }

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        emit_selected_version_mismatch("zig", expected_version, actual_version);
        return;
    }

    emit_selected_version("zig", expected_version, expected_version);
}

/// Verify the current zls version.
fn verify_zls_version(ctx: *context.CliContext, expected_version: []const u8) !void {
    var path_buffer = try ctx.acquire_path_buffer();
    defer path_buffer.reset();
    var output_buffer: [limits.limits.temp_buffer_size]u8 = undefined;

    const actual_version = try util_data.get_current_version(
        path_buffer,
        &output_buffer,
        true,
    );

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        emit_selected_version_mismatch("zls", expected_version, actual_version);
        return;
    }

    emit_selected_version("zls", expected_version, expected_version);
}

fn emit_selected_version(tool_name: []const u8, requested_version: []const u8, active_version: []const u8) void {
    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "tool", .value = .{ .string = tool_name } },
            .{ .key = "requested_version", .value = .{ .string = requested_version } },
            .{ .key = "active_version", .value = .{ .string = active_version } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.success("Now using {s} version {s}", .{ tool_name, active_version });
}

fn emit_selected_version_mismatch(
    tool_name: []const u8,
    expected_version: []const u8,
    actual_version: []const u8,
) void {
    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "tool", .value = .{ .string = tool_name } },
            .{ .key = "expected_version", .value = .{ .string = expected_version } },
            .{ .key = "active_version", .value = .{ .string = actual_version } },
            .{ .key = "ok", .value = .{ .boolean = false } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.err(
        "Expected {s} version {s}, but currently using {s}. Please check.",
        .{ tool_name, expected_version, actual_version },
    );
}
