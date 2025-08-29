const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const context = @import("../context.zig");
const object_pools = @import("../object_pools.zig");
const limits = @import("../limits.zig").limits;

/// Cross-platform environment variable getter
/// Returns null if variable doesn't exist, slice if it does
fn getenv_cross_platform(comptime var_name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, we'd need an allocator for std.process.getEnvVarOwned
        // For now, return null on Windows for these optional env vars
        return null;
    } else {
        return std.posix.getenv(var_name);
    }
}

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
    var fbs = std.io.fixedBufferStream(buffer.slice());

    // Follow XDG Base Directory specification
    const home_dir = ctx.get_home_dir();
    if (getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
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
    var fbs = std.io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
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
    var fbs = std.io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
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
    var fbs = std.io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
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
    var fbs = std.io.fixedBufferStream(buffer.slice());

    const home_dir = ctx.get_home_dir();
    if (getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/version/zls", .{xdg_data});
    } else {
        // Use XDG default: $HOME/.local/share/.zm
        try fbs.writer().print("{s}/.local/share/.zm/version/zls", .{home_dir});
    }

    return try buffer.set(fbs.getWritten());
}

/// Try to get zig/zls version using pre-allocated buffers.
pub fn get_current_version(
    path_buffer: *object_pools.PathBuffer,
    output_buffer: []u8,
    is_zls: bool,
) ![]const u8 {
    // Build executable path.
    const exe_name = if (is_zls) config.zls_name else config.zig_name;
    const base_path = if (is_zls)
        try get_zvm_current_zls(path_buffer)
    else
        try get_zvm_current_zig(path_buffer);

    // Need to copy base_path to avoid aliasing when we build the full path
    var base_path_copy: [limits.path_length_maximum]u8 = undefined;
    const base_path_len = base_path.len;
    @memcpy(base_path_copy[0..base_path_len], base_path);

    // Build full path.
    var fbs = std.io.fixedBufferStream(path_buffer.slice());
    try fbs.writer().print("{s}/{s}", .{ base_path_copy[0..base_path_len], exe_name });
    const current_path = fbs.getWritten();

    // Create child process with static args.
    const args = [_][]const u8{ current_path, if (is_zls) "--version" else "version" };
    var child_process = std.process.Child.init(&args, std.heap.page_allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
        var file_reader = stdout.reader(&reader_buffer);

        // takeDelimiterExclusive returns the line directly or an error
        const result = file_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EmptyVersion,
            error.StreamTooLong => return error.BufferTooSmall,
            error.ReadFailed => return error.FailedToReadVersion,
            else => return err,
        };

        if (result.len > output_buffer.len) return error.BufferTooSmall;
        @memcpy(output_buffer[0..result.len], result);
        return output_buffer[0..result.len];
    }

    return error.FailedToReadVersion;
}
