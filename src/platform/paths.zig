const std = @import("std");
const builtin = @import("builtin");
const Errors = @import("../Errors.zig");
const util_tool = @import("../util/tool.zig");

pub fn get_home_path(allocator: std.mem.Allocator, buffer: []u8) ![]const u8 {
    _ = allocator;

    if (builtin.os.tag == .windows) {
        const home = util_tool.getenv_cross_platform("USERPROFILE") orelse {
            return Errors.ZvmError.HomeNotFound;
        };

        if (home.len >= buffer.len) {
            return Errors.ZvmError.HomePathTooLong;
        }

        @memcpy(buffer[0..home.len], home);
        return buffer[0..home.len];
    } else {
        const home = util_tool.getenv_cross_platform("HOME") orelse {
            return Errors.ZvmError.HomeNotFound;
        };

        if (home.len >= buffer.len) {
            return Errors.ZvmError.HomePathTooLong;
        }

        @memcpy(buffer[0..home.len], home);
        return buffer[0..home.len];
    }
}

pub fn get_zvm_home_path(home: []const u8, buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (util_tool.getenv_cross_platform("ZVM_HOME")) |zvm_home| {
            if (zvm_home.len >= buffer.len) {
                return Errors.ZvmError.HomePathTooLong;
            }
            @memcpy(buffer[0..zvm_home.len], zvm_home);
            return buffer[0..zvm_home.len];
        } else {
            var stream = @import("compat").fixedBufferStream(buffer);
            try stream.writer().print("{s}\\.zm", .{home});
            return stream.getWritten();
        }
    } else {
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            var stream = @import("compat").fixedBufferStream(buffer);
            try stream.writer().print("{s}/.zm", .{xdg_data});
            return stream.getWritten();
        } else {
            var stream = @import("compat").fixedBufferStream(buffer);
            try stream.writer().print("{s}/.local/share/.zm", .{home});
            return stream.getWritten();
        }
    }
}
