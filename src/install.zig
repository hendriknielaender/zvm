const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const download = @import("download.zig");
const architecture = @import("architecture.zig");
const tools = @import("tools.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const extract = @import("extract.zig");

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

/// Try to install the specified version of zig
pub fn install_zig(version: []const u8) !void {
    const allocator = tools.get_allocator();

    const platform_str = try architecture.platform_str(architecture.DetectParams{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // get version data
    const version_data: meta.Zig.VersionData = blk: {
        const res = try tools.http_get(arena_allocator, config.zig_url);
        var zig_meta = try meta.Zig.init(res, arena_allocator);
        const tmp_val = try zig_meta.get_version_data(version, platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };

    std.debug.print("Install {s}\n", .{version_data.version});

    const reverse_platform_str = try architecture.platform_str(architecture.DetectParams{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = false,
    }) orelse unreachable;

    const file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ "zig-", reverse_platform_str, "-", version, ".", config.zig_archive_ext },
    );

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;
    const new_file = try download.download(parsed_uri, file_name, version_data.shasum, version_data.size);
    defer new_file.close();

    // get version path
    const version_path = try tools.get_zvm_path_segment(arena_allocator, "version");
    // get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, version });
    try tools.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    try extract.extrace(extract_dir, new_file, if (builtin.os.tag == .windows) .zip else .tarxz);

    try alias.set_zig_version(version);
}
