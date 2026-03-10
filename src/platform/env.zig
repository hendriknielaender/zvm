const std = @import("std");
const builtin = @import("builtin");

pub fn has_env_var(var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var key_w: [256:0]u16 = undefined;
    const key_len = std.unicode.utf8ToUtf16Le(key_w[0..], var_name) catch return false;
    key_w[key_len] = 0;
    return std.process.getenvW(key_w[0..key_len :0].ptr) != null;
}

pub fn get_env_var(var_name: []const u8, buffer: []u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var key_w: [256:0]u16 = undefined;
    const key_len = std.unicode.utf8ToUtf16Le(key_w[0..], var_name) catch return error.InvalidWtf8;
    key_w[key_len] = 0;

    const result_w = std.process.getenvW(key_w[0..key_len :0].ptr) orelse return null;
    const result_len = std.unicode.wtf16LeToWtf8(buffer, result_w);
    if (result_len > buffer.len) return error.BufferTooSmall;
    return buffer[0..result_len];
}

pub fn get_env_var_cross_platform(var_name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return null;
    } else {
        return std.posix.getenv(var_name);
    }
}
