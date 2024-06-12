const std = @import("std");
const builtin = @import("builtin");

var allocator: std.mem.Allocator = undefined;

var home_dir: []const u8 = undefined;

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
