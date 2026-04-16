const util_tool = @import("../util/tool.zig");

pub fn has_env_var(var_name: []const u8) bool {
    return util_tool.getenv_cross_platform(var_name) != null;
}

pub fn get_env_var(var_name: []const u8, buffer: []u8) !?[]const u8 {
    const value = util_tool.getenv_cross_platform(var_name) orelse return null;
    if (value.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub fn get_env_var_cross_platform(var_name: []const u8) ?[]const u8 {
    return util_tool.getenv_cross_platform(var_name);
}
