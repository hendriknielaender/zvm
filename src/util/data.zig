const std = @import("std");
const limits = @import("../memory/limits.zig");
const object_pools = @import("../memory/object_pools.zig");
const context = @import("../Context.zig");
const util_tool = @import("tool.zig");
const assert = std.debug.assert;

pub const version_manifest_name = ".zvm-version";

/// Cross-platform environment variable getter
/// Returns null if variable doesn't exist, slice if it does
pub const zvm_logo =
    \\⠀⢸⣾⣷⣿⣾⣷⣿⣾⡷⠃⠀⠀⠀⠀⠀⣴⡷⠞⠀⠀⠀⠀⠀⣼⣾⡂
    \\⠀⠈⠉⠉⠉⠉⣹⣿⡿⠁⢠⡄⠀⠀⢀⣼⢯⠏⠀⢀⡄⠀⢀⣾⣿⣿⡂
    \\⠀⠀⠀⠀⠀⣼⣿⡟⠁⠠⣿⣷⡀⢀⣼⣯⡛⠁⢠⣿⣿⣤⣾⣿⣿⣿⡂
    \\⠀⠀⠀⢀⣾⣿⡟⠀⠀⠀⢻⣿⣷⢾⢷⠏⠀⣠⣿⡋⢿⣿⣿⠏⣿⣿⡂
    \\⠀⠀⢀⣾⣿⠏⠀⠀⠀⠀⠀⢻⣯⣻⠏⠀⠀⣿⣿⡃⠈⢿⠃⠀⣿⣿⡂
    \\⠀⢀⣾⣿⣏⣀⣀⣀⣀⣀⠀⠀⢻⠊⠀⠀⠀⣿⣿⡃⠀⠀⠀⠀⣿⣿⡂
    \\⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⡧⠀⠀⠀⠀⠀⠀⣿⣿⠃⠀⠀⠀⠀⣿⣿⠂
;

/// Get zvm path segment - uses path buffer from context.
pub fn get_zvm_path_segment(buffer: *object_pools.PathBuffer, segment: []const u8) ![]const u8 {
    const ctx = try context.CliContext.get();
    var fbs = std.Io.fixedBufferStream(buffer.slice());

    // Follow XDG Base Directory specification
    const home_dir = ctx.get_home_dir();
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/{s}", .{ xdg_data, segment });
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/{s}", .{ home_dir, segment });
    }

    return try buffer.set(fbs.getWritten());
}

/// Get zvm/current/zig path.
pub fn get_zvm_current_zig(buffer: *object_pools.PathBuffer) ![]const u8 {
    const ctx = try context.CliContext.get();
    var fbs = std.Io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/current/zig", .{xdg_data});
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/current/zig", .{home_dir});
    }

    return try buffer.set(fbs.getWritten());
}

/// Get zvm/current/zls path.
pub fn get_zvm_current_zls(buffer: *object_pools.PathBuffer) ![]const u8 {
    const ctx = try context.CliContext.get();
    var fbs = std.Io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/current/zls", .{xdg_data});
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/current/zls", .{home_dir});
    }

    return try buffer.set(fbs.getWritten());
}

/// Get zvm/store path.
pub fn get_zvm_store(buffer: *object_pools.PathBuffer) ![]const u8 {
    return get_zvm_path_segment(buffer, "store");
}

/// Get zvm/version/zig path.
pub fn get_zvm_zig_version(buffer: *object_pools.PathBuffer) ![]const u8 {
    const ctx = try context.CliContext.get();
    var fbs = std.Io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/version/zig", .{xdg_data});
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/version/zig", .{home_dir});
    }

    return try buffer.set(fbs.getWritten());
}

/// Get zvm/version/zls path.
pub fn get_zvm_zls_version(buffer: *object_pools.PathBuffer) ![]const u8 {
    const ctx = try context.CliContext.get();
    var fbs = std.Io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/version/zls", .{xdg_data});
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/version/zls", .{home_dir});
    }

    return try buffer.set(fbs.getWritten());
}

pub fn write_version_manifest(install_path: []const u8, version: []const u8) !void {
    assert(install_path.len > 0);
    assert(version.len > 0);
    assert(version.len <= limits.limits.version_string_length_maximum);

    var manifest_path_buffer: [limits.limits.path_length_maximum]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}/{s}",
        .{ install_path, version_manifest_name },
    );

    const manifest_file = try std.fs.cwd().createFile(manifest_path, .{});
    defer manifest_file.close();

    try manifest_file.writeAll(version);
}

fn build_manifest_path(
    path_buffer: *object_pools.PathBuffer,
    install_path: []const u8,
) ![]const u8 {
    assert(install_path.len > 0);

    var stream = std.Io.fixedBufferStream(path_buffer.slice());
    try stream.writer().print("{s}/{s}", .{ install_path, version_manifest_name });
    return try path_buffer.set(stream.getWritten());
}

fn read_version_manifest_absolute(
    path_buffer: *object_pools.PathBuffer,
    install_path: []const u8,
    output_buffer: []u8,
) ![]const u8 {
    assert(output_buffer.len > 0);

    const manifest_path = try build_manifest_path(path_buffer, install_path);
    const manifest_file = try std.fs.openFileAbsolute(manifest_path, .{ .mode = .read_only });
    defer manifest_file.close();

    const bytes_read = try manifest_file.readAll(output_buffer);
    if (bytes_read == 0) return error.EmptyVersion;

    const version = std.mem.trim(u8, output_buffer[0..bytes_read], " \t\r\n");
    if (version.len == 0) return error.EmptyVersion;
    return version;
}

/// Try to get zig/zls version using a manifest within the active installation.
pub fn get_current_version(
    path_buffer: *object_pools.PathBuffer,
    output_buffer: []u8,
    is_zls: bool,
) ![]const u8 {
    const base_path = if (is_zls)
        try get_zvm_current_zls(path_buffer)
    else
        try get_zvm_current_zig(path_buffer);

    return try read_version_manifest_absolute(path_buffer, base_path, output_buffer);
}
