const std = @import("std");
const util_output = @import("util/output.zig");
const util_tool = @import("util/tool.zig");
const paths = @import("platform/paths.zig");
const metadata = @import("metadata.zig");
const assert = std.debug.assert;

zvm_home: []const u8,
verify_signatures: bool,
output_mode: util_output.OutputMode,
color_mode: util_output.ColorMode,
log_level: std.log.Level,
preferred_mirror: ?usize,

home_buffer: [512]u8,
zvm_home_buffer: [512]u8,
env_buffer: [512]u8,

const Self = @This();

pub fn init() Self {
    var config = Self{
        .zvm_home = "",
        .verify_signatures = true,
        .output_mode = .human_readable,
        .color_mode = .always_use_color,
        .log_level = .info,
        .preferred_mirror = null,
        // SAFETY: home_buffer is initialized by get_home_path() before use
        .home_buffer = undefined,
        // SAFETY: zvm_home_buffer is initialized by get_zvm_home_path() before use
        .zvm_home_buffer = undefined,
        // SAFETY: env_buffer is used for temporary environment variable storage
        .env_buffer = undefined,
    };

    config.load_from_env();
    return config;
}

fn load_from_env(self: *Self) void {
    const home = paths.get_home_path(&self.home_buffer) catch return;
    self.zvm_home = paths.get_zvm_root(&self.zvm_home_buffer, home) catch return;

    assert(self.zvm_home.len > 0);
    assert(self.zvm_home.len <= self.zvm_home_buffer.len);

    if (self.get_env_var("ZVM_VERIFY_SIGNATURES")) |verify_str| {
        self.verify_signatures = std.mem.eql(u8, verify_str, "true");
    }

    self.preferred_mirror = metadata.preferred_mirror;
}

fn get_env_var(self: *Self, name: []const u8) ?[]const u8 {
    const value = util_tool.getenv_cross_platform(name) orelse return null;
    if (value.len > self.env_buffer.len) return null;
    @memcpy(self.env_buffer[0..value.len], value);
    return self.env_buffer[0..value.len];
}

pub fn validate(self: Self) !void {
    if (self.zvm_home.len == 0) {
        return error.InvalidConfig;
    }

    if (self.output_mode == .machine_json and self.color_mode == .always_use_color) {
        return error.InvalidConfig;
    }
}
