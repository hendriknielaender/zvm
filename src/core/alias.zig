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
const detect_version = @import("detect_version.zig");

const log = std.log.scoped(.alias);

// Cleaner access to I/O buffer size
const io_buffer_size = limits.limits.io_buffer_size_maximum;

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

        const err_msg = "{s} version {s} is not installed. Please install it before proceeding.\n";
        var buffer: [io_buffer_size]u8 = undefined;
        var stderr_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(err_msg, .{ if (is_zls) "zls" else "Zig", version });
        try stderr.flush();
        std.process.exit(@intFromEnum(util_output.ExitCode.version_not_found));
    };

    // Get symlink path.
    var symlink_path_buffer = try ctx.acquire_path_buffer();
    defer symlink_path_buffer.reset();
    const symlink_path = if (is_zls)
        try util_data.get_zvm_current_zls(symlink_path_buffer)
    else
        try util_data.get_zvm_current_zig(symlink_path_buffer);

    if (is_zls) {
        // For ZLS, use traditional behavior (point directly to zls binary)
        try update_current(version_path, symlink_path);
        try verify_zls_version(ctx, version);
    } else {
        // For Zig, point to zvm binary for smart version detection
        try update_current_to_zvm(ctx, symlink_path);

        // Save the default version for when no build.zig.zon exists
        try save_default_version(ctx, version);

        // Print success message for smart mode
        var stdout_buffer: [io_buffer_size]u8 = undefined;
        var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print("Now using smart Zig version detection (default: {s})\n", .{version});
        try stdout.flush();
    }
}

fn save_default_version(ctx: *context.CliContext, version: []const u8) !void {
    var zm_path_buffer = try ctx.acquire_path_buffer();
    defer zm_path_buffer.reset();

    const home_dir = ctx.get_home_dir();
    var stream = std.Io.fixedBufferStream(zm_path_buffer.slice());

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try stream.writer().print("{s}/.zm", .{xdg_data});
    } else {
        try stream.writer().print("{s}/.local/share/.zm", .{home_dir});
    }

    const zm_dir = try zm_path_buffer.set(stream.getWritten());

    // Ensure .zm directory exists
    std.fs.makeDirAbsolute(zm_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use a separate buffer for the config file path
    var config_path_buffer = try ctx.acquire_path_buffer();
    defer config_path_buffer.reset();

    var config_stream = std.Io.fixedBufferStream(config_path_buffer.slice());
    try config_stream.writer().print("{s}/default_version", .{zm_dir});
    const config_path = try config_path_buffer.set(config_stream.getWritten());

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();

    try file.writeAll(version);
}

fn update_current_to_zvm(ctx: *context.CliContext, symlink_path: []const u8) !void {
    assert(symlink_path.len > 0);

    // Get the default version that was set
    const default_version = detect_version.find_default_version(ctx) catch |err| {
        log.err("Failed to find default version: {s}", .{@errorName(err)});
        return err;
    };

    if (default_version == null) {
        log.err("No default version set. Please run 'zvm use <version>' first.", .{});
        return error.NoDefaultVersion;
    }

    // Build path to the actual zig binary for the default version
    var zig_binary_path_buffer = try ctx.acquire_path_buffer();
    defer zig_binary_path_buffer.reset();

    const home_dir = ctx.get_home_dir();
    var fbs = std.Io.fixedBufferStream(zig_binary_path_buffer.slice());

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/version/zig/{s}/zig", .{ xdg_data, default_version.? });
    } else {
        try fbs.writer().print("{s}/.local/share/.zm/version/zig/{s}/zig", .{ home_dir, default_version.? });
    }

    const zig_binary_path = try zig_binary_path_buffer.set(fbs.getWritten());

    // Verify the zig binary exists
    std.fs.accessAbsolute(zig_binary_path, .{}) catch |err| {
        log.err("Zig binary not found at {s}: {s}", .{ zig_binary_path, @errorName(err) });
        log.err("Please ensure version {s} is properly installed", .{default_version.?});
        return err;
    };

    if (builtin.os.tag == .windows) {
        if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteTreeAbsolute(symlink_path);
        // On Windows, copy the zig executable to the current location
        try std.fs.copyFileAbsolute(zig_binary_path, symlink_path, .{});
        return;
    }

    // Remove existing symlink if it exists
    if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteFileAbsolute(symlink_path);

    // Create symlink to the actual zig binary
    try std.posix.symlink(zig_binary_path, symlink_path);
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

    // Remove existing symlink if it exists.
    if (util_tool.does_path_exist(symlink_path)) try std.fs.deleteFileAbsolute(symlink_path);

    // Create symlink to the version directory.
    try std.posix.symlink(zig_path, symlink_path);
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

    var stdout_buffer: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, expected_version, "master")) {
        try stdout.print("Now using Zig version {s}\n", .{actual_version});
        try stdout.flush();
    } else if (!std.mem.eql(u8, expected_version, actual_version)) {
        const err_msg = "Expected Zig version {s}, but currently using {s}. Please check.\n";
        var stderr_buffer: [io_buffer_size]u8 = undefined;
        var stderr_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(err_msg, .{ expected_version, actual_version });
        try stderr.flush();
    } else {
        try stdout.print("Now using Zig version {s}\n", .{expected_version});
        try stdout.flush();
    }
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

    var stdout_buffer: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        const err_msg = "Expected zls version {s}, but currently using {s}. Please check.\n";
        var stderr_buffer: [io_buffer_size]u8 = undefined;
        var stderr_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &stderr_buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(err_msg, .{ expected_version, actual_version });
        try stderr.flush();
    } else {
        try stdout.print("Now using zls version {s}\n", .{expected_version});
        try stdout.flush();
    }
}
