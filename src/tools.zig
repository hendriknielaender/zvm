const std = @import("std");
const builtin = @import("builtin");

var allocator: std.mem.Allocator = undefined;

var home_dir: []const u8 = undefined;

pub const log = std.log.scoped(.zvm);

/// init the data
pub fn dataInit(tmp_allocator: std.mem.Allocator) !void {
    allocator = tmp_allocator;
    // setting the home dir
    home_dir = if (builtin.os.tag == .windows)
        try std.process.getEnvVarOwned(allocator, "USERPROFILE")
    else
        std.posix.getenv("HOME") orelse ".";
}

/// deinit the data
pub fn dataDeinit() void {
    if (builtin.os.tag == .windows)
        allocator.free(home_dir);
}

/// get home dir
pub fn getHome() []const u8 {
    return home_dir;
}

/// get the allocator
pub fn getAllocator() std.mem.Allocator {
    return allocator;
}

pub fn getZvmPathSegment(_allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    return std.fs.path.join(
        _allocator,
        &[_][]const u8{ getHome(), ".zm", segment },
    );
}

