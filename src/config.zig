// ! this file just store some config meta data
const std = @import("std");
const builtin = @import("builtin");

/// global allocator
pub var allocator: std.mem.Allocator = undefined;
/// home dir environment variable
pub var home_dir: []const u8 = undefined;

/// global progress root node
pub var progress_root: std.Progress.Node = undefined;

/// zig meta data url
pub const zig_meta_url: []const u8 = "https://ziglang.org/download/index.json";
/// zls meta data url
pub const zls_meta_url: []const u8 = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";

/// parsed zig url
pub const zig_url = std.Uri.parse(zig_meta_url) catch unreachable;
/// parsed zls url
pub const zls_url = std.Uri.parse(zls_meta_url) catch unreachable;

/// zig file name
pub const zig_name = switch (builtin.os.tag) {
    .windows => "zig.exe",
    .linux, .macos => "zig",
    else => @compileError("not support current platform"),
};

/// zig archive_ext
pub const zig_archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
