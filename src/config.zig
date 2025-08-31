const std = @import("std");
const builtin = @import("builtin");
const util_output = @import("util/output.zig");
const metadata = @import("metadata.zig");

zvm_home: []const u8,
verify_signatures: bool,
output_mode: util_output.OutputMode,
color_mode: util_output.ColorMode,
log_level: std.log.Level,
preferred_mirror: ?usize,

home_buffer: [512]u8,
zvm_home_buffer: [512]u8,

const Self = @This();

pub fn init() Self {
    var config = Self{
        .zvm_home = "",
        .verify_signatures = true,
        .output_mode = .human_readable,
        .color_mode = .always_use_color,
        .log_level = .info,
        .preferred_mirror = null,
        .home_buffer = undefined,
        .zvm_home_buffer = undefined,
    };

    config.loadFromEnv();
    return config;
}

fn loadFromEnv(self: *Self) void {
    const home = self.getHomePath() catch return;
    self.zvm_home = self.getZvmHomePath(home) catch return;

    if (self.getEnvVar("ZVM_VERIFY_SIGNATURES")) |verify_str| {
        self.verify_signatures = std.mem.eql(u8, verify_str, "true");
    }

    self.preferred_mirror = metadata.preferred_mirror;
}

fn getHomePath(self: *Self) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const home = std.posix.getenv("USERPROFILE") orelse return error.HomeNotFound;
        if (home.len >= self.home_buffer.len) return error.HomePathTooLong;
        @memcpy(self.home_buffer[0..home.len], home);
        return self.home_buffer[0..home.len];
    } else {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        if (home.len >= self.home_buffer.len) return error.HomePathTooLong;
        @memcpy(self.home_buffer[0..home.len], home);
        return self.home_buffer[0..home.len];
    }
}

fn getZvmHomePath(self: *Self, home: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (self.getEnvVar("ZVM_HOME")) |zvm_home| {
            if (zvm_home.len >= self.zvm_home_buffer.len) return error.HomePathTooLong;
            @memcpy(self.zvm_home_buffer[0..zvm_home.len], zvm_home);
            return self.zvm_home_buffer[0..zvm_home.len];
        } else {
            var stream = std.io.fixedBufferStream(&self.zvm_home_buffer);
            try stream.writer().print("{s}\\.zm", .{home});
            return stream.getWritten();
        }
    } else {
        if (std.posix.getenv("XDG_DATA_HOME")) |xdg_data| {
            var stream = std.io.fixedBufferStream(&self.zvm_home_buffer);
            try stream.writer().print("{s}/.zm", .{xdg_data});
            return stream.getWritten();
        } else {
            var stream = std.io.fixedBufferStream(&self.zvm_home_buffer);
            try stream.writer().print("{s}/.local/share/.zm", .{home});
            return stream.getWritten();
        }
    }
}

fn getEnvVar(self: *Self, name: []const u8) ?[]const u8 {
    _ = self;
    return std.posix.getenv(name);
}

pub fn validate(self: Self) !void {
    if (self.zvm_home.len == 0) {
        return error.InvalidConfig;
    }

    if (self.output_mode == .machine_json and self.color_mode == .always_use_color) {
        return error.InvalidConfig;
    }
}
