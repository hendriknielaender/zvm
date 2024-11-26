//! This file is used to install zig or zls
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const util_arch = @import("util/arch.zig");
const util_data = @import("util/data.zig");
const util_extract = @import("util/extract.zig");
const util_tool = @import("util/tool.zig");
const util_http = @import("util/http.zig");
const util_minisign = @import("util/minisign.zig");

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

/// try install specified version
pub fn install(version: []const u8, is_zls: bool) !void {
    if (is_zls) {
        try install_zls(version);
    } else {
        try install_zig(version);
    }
}

/// Try to install the specified version of zig
fn install_zig(version: []const u8) !void {
    std.debug.print("install start", .{});

    var allocator = util_data.get_allocator();

    const platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // Get version path
    const version_path = try util_data.get_zvm_zig_version(arena_allocator);
    // Get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, version });

    // Get version data
    const version_data: meta.Zig.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zig_url);
        var zig_meta = try meta.Zig.init(res, arena_allocator);
        const tmp_val = try zig_meta.get_version_data(version, platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };

    std.debug.print("version: {s}\n", .{version_data.version});

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(version, false);
        return;
    }

    const reverse_platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = false,
    }) orelse unreachable;

    const file_name_base = std.fs.path.basename(version_data.tarball);

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;

    std.debug.print("parsed url: {s}\n", .{version_data.tarball});

    // Download the tarball
    const tarball_file = try util_http.download(parsed_uri, file_name_base, version_data.shasum, version_data.size);
    defer tarball_file.close();

    std.debug.print("download done\n", .{});

    // Derive signature URI by appending ".minisig" to the tarball URL
    var signature_uri_buffer: [1024]u8 = undefined;
    const signature_uri_buf = try std.fmt.bufPrint(
        &signature_uri_buffer,
        "{s}.minisig",
        .{version_data.tarball}, // Use the original tarball URL
    );

    const signature_uri = try std.Uri.parse(signature_uri_buffer[0..signature_uri_buf.len]);

    std.debug.print("signature url: {s}\n", .{signature_uri_buffer[0..signature_uri_buf.len]});

    // Define signature file name
    const signature_file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ file_name_base, ".minisig" },
    );

    // Download the signature file
    const minisig_file = try util_http.download(signature_uri, signature_file_name, null, null);
    defer minisig_file.close();

    // Get paths to the tarball and signature files
    const zvm_store_path = try util_data.get_zvm_path_segment(allocator, "store");
    defer allocator.free(zvm_store_path);
    const tarball_path = try std.fs.path.join(arena_allocator, &.{ zvm_store_path, file_name_base });
    const sig_path = try std.fs.path.join(arena_allocator, &.{ zvm_store_path, signature_file_name });

    // Perform Minisign Verification
    try util_minisign.verify(
        &allocator,
        sig_path,
        config.ZIG_MINISIGN_PUBLIC_KEY,
        tarball_path,
    );

    // Proceed with extraction after successful verification
    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    try util_extract.extract(extract_dir, tarball_file, if (builtin.os.tag == .windows) .zip else .tarxz, false);

    const sub_path = try std.fs.path.join(arena_allocator, &.{
        extract_path, try std.mem.concat(
            arena_allocator,
            u8,
            &.{ "zig-", reverse_platform_str, "-", version },
        ),
    });
    defer std.fs.deleteTreeAbsolute(sub_path) catch unreachable;

    std.debug.print("sub path: {s}\n", .{sub_path});

    try util_tool.copy_dir(sub_path, extract_path);

    try alias.set_version(version, false);
}

/// Try to install the specified version of zls
fn install_zls(version: []const u8) !void {
    const true_version = blk: {
        if (util_tool.eql_str("master", version)) {
            std.debug.print("Sorry, the 'install zls' feature is not supported at this time. Please compile zls locally.", .{});
            return;
        }

        for (config.zls_list_1, 0..) |val, i| {
            if (util_tool.eql_str(val, version))
                break :blk config.zls_list_2[i];
        }
        break :blk version;
    };
    const allocator = util_data.get_allocator();

    const reverse_platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // get version path
    const version_path = try util_data.get_zvm_zls_version(arena_allocator);
    // get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, true_version });

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(true_version, true);
        return;
    }

    // get version data
    const version_data: meta.Zls.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zls_url);
        var zls_meta = try meta.Zls.init(res, arena_allocator);
        const tmp_val = try zls_meta.get_version_data(true_version, reverse_platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };

    const file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ "zls-", reverse_platform_str, "-", true_version, ".", config.archive_ext },
    );

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;
    const new_file = try util_http.download(parsed_uri, file_name, null, version_data.size);
    defer new_file.close();

    try util_tool.try_create_path(extract_path);

    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});
    try util_extract.extract(extract_dir, new_file, if (builtin.os.tag == .windows)
        .zip
    else
        .tarxz, true);

    try alias.set_version(true_version, true);
}

pub fn build_zls() !void {}
