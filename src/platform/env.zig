const std = @import("std");
const builtin = @import("builtin");

pub fn hasEnvVar(var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = std.process.getEnvVarOwned(arena.allocator(), var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };

    return result.len > 0;
}

pub fn getEnvVar(allocator: std.mem.Allocator, var_name: []const u8, buffer: []u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;

    const result = std.process.getEnvVarOwned(allocator, var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };

    if (result.len >= buffer.len) {
        return error.BufferTooSmall;
    }

    @memcpy(buffer[0..result.len], result);
    return buffer[0..result.len];
}

pub fn getEnvVarCrossPlatform(var_name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return null;
    } else {
        return std.posix.getenv(var_name);
    }
}
