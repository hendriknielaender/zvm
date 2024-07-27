const std = @import("std");
const builtin = @import("builtin");

var allocator: std.mem.Allocator = undefined;
var home_dir: []const u8 = undefined;

pub const log = std.log.scoped(.zvm);

/// Initialize the data.
pub fn data_init(tmp_allocator: std.mem.Allocator) !void {
    allocator = tmp_allocator;
    home_dir = if (builtin.os.tag == .windows)
        try std.process.getEnvVarOwned(allocator, "USERPROFILE")
    else
        std.posix.getenv("HOME") orelse ".";
}

/// Deinitialize the data.
pub fn data_deinit() void {
    if (builtin.os.tag == .windows)
        allocator.free(home_dir);
}

/// Get home directory.
pub fn get_home() []const u8 {
    return home_dir;
}

/// Get the allocator.
pub fn get_allocator() std.mem.Allocator {
    return allocator;
}

/// get zvm path segment
pub fn get_zvm_path_segment(tmp_allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    return std.fs.path.join(
        tmp_allocator,
        &[_][]const u8{ get_home(), ".zm", segment },
    );
}
