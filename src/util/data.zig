const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

pub const zvm_logo =
    \\⠀⢸⣾⣷⣿⣾⣷⣿⣾⡷⠃⠀⠀⠀⠀⠀⣴⡷⠞⠀⠀⠀⠀⠀⣼⣾⡂
    \\⠀⠈⠉⠉⠉⠉⣹⣿⡿⠁⢠⡄⠀⠀⢀⣼⢯⠏⠀⢀⡄⠀⢀⣾⣿⣿⡂
    \\⠀⠀⠀⠀⠀⣼⣿⡟⠁⠠⣿⣷⡀⢀⣼⣯⡛⠁⢠⣿⣿⣤⣾⣿⣿⣿⡂
    \\⠀⠀⠀⢀⣾⣿⡟⠀⠀⠀⢻⣿⣷⢾⢷⠏⠀⣠⣿⡋⢿⣿⣿⠏⣿⣿⡂
    \\⠀⠀⢀⣾⣿⠏⠀⠀⠀⠀⠀⢻⣯⣻⠏⠀⠀⣿⣿⡃⠈⢿⠃⠀⣿⣿⡂
    \\⠀⢀⣾⣿⣏⣀⣀⣀⣀⣀⠀⠀⢻⠊⠀⠀⠀⣿⣿⡃⠀⠀⠀⠀⣿⣿⡂
    \\⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⡧⠀⠀⠀⠀⠀⠀⣿⣿⠃⠀⠀⠀⠀⣿⣿⠂
;

/// Initialize the data.
pub fn data_init(tmp_allocator: std.mem.Allocator) !void {
    config.allocator = tmp_allocator;
    config.home_dir = if (builtin.os.tag == .windows)
        try std.process.getEnvVarOwned(config.allocator, "USERPROFILE")
    else
        std.posix.getenv("HOME") orelse ".";
}

/// Deinitialize the data.
pub fn data_deinit() void {
    if (builtin.os.tag == .windows)
        config.allocator.free(config.home_dir);
}

/// Get home directory.
pub fn get_home() []const u8 {
    return config.home_dir;
}

/// Get the allocator.
pub fn get_allocator() std.mem.Allocator {
    return config.allocator;
}

/// Get zvm path segment
pub fn get_zvm_path_segment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ get_home(), ".zm", segment });
}

pub fn get_zvm_current_zig(allocator: std.mem.Allocator) ![]u8 {
    const current = try get_zvm_path_segment(allocator, "current");
    defer allocator.free(current);
    return try std.fs.path.join(allocator, &[_][]const u8{ current, "zig" });
}

pub fn get_zvm_current_zls(allocator: std.mem.Allocator) ![]u8 {
    const current = try get_zvm_path_segment(allocator, "current");
    defer allocator.free(current);
    return try std.fs.path.join(allocator, &[_][]const u8{ current, "zls" });
}

pub fn get_zvm_store(allocator: std.mem.Allocator) ![]u8 {
    return get_zvm_path_segment(allocator, "store");
}

pub fn get_zvm_zig_version(allocator: std.mem.Allocator) ![]u8 {
    const current = try get_zvm_path_segment(allocator, "version");
    defer allocator.free(current);
    return try std.fs.path.join(allocator, &[_][]const u8{ current, "zig" });
}

pub fn get_zvm_zls_version(allocator: std.mem.Allocator) ![]u8 {
    const current = try get_zvm_path_segment(allocator, "version");
    defer allocator.free(current);
    return try std.fs.path.join(allocator, &[_][]const u8{ current, "zls" });
}

/// try to get zig/zls version
pub fn get_current_version(allocator: std.mem.Allocator, is_zls: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const current_path = try std.fs.path.join(arena_allocator, &.{
        if (is_zls)
            try get_zvm_current_zls(arena_allocator)
        else
            try get_zvm_current_zig(arena_allocator),
        if (is_zls)
            config.zls_name
        else
            config.zig_name,
    });

    // here we must use the absolute path, we can not just use "zig"
    // because child process will use environment variable
    var child_process = std.process.Child.init(&[_][]const u8{ current_path, if (is_zls) "--version" else "version" }, arena_allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        const version = try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
        return version;
    }

    return error.FailedToReadVersion;
}
