const std = @import("std");
const builtin = @import("builtin");

var allocator: std.mem.Allocator = undefined;
var home_dir: []const u8 = undefined;

pub const zig_meta_url: []const u8 = "https://ziglang.org/download/index.json";
pub const zls_meta_url: []const u8 = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";

pub const zig_url = std.Uri.parse(zig_meta_url) catch unreachable;
pub const zls_url = std.Uri.parse(zls_meta_url) catch unreachable;

pub const zig_name = switch (builtin.os.tag) {
    .windows => "zig.exe",
    .linux => "zig",
    .macos => "zig",
    else => @compileError("not support current platform"),
};

pub const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
