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
const Progress = std.Progress;

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

/// try install specified version
pub fn install(version: []const u8, is_zls: bool, root_node: Progress.Node) !void {
    if (is_zls) {
        try install_zls(version);
    } else {
        try install_zig(version, root_node);
    }
}

/// Try to install the specified version of zig
fn install_zig(version: []const u8, root_node: Progress.Node) !void {
    var allocator = util_data.get_allocator();

    const platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var items_done: usize = 0;

    // Step 1: Get version path
    const version_path = try util_data.get_zvm_zig_version(arena_allocator);
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Step 2: Get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, version });
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Step 3: Get version data
    const version_data: meta.Zig.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zig_url);
        var zig_meta = try meta.Zig.init(res, arena_allocator);
        const tmp_val = try zig_meta.get_version_data(version, platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };
    items_done += 1;
    root_node.setCompletedItems(items_done);

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(version, false);
        root_node.end();
        return;
    }

    // Step 4: Download the tarball
    const file_name = std.fs.path.basename(version_data.tarball);
    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;

    // Create a child progress node for the download
    const download_node = root_node.start("download zig", version_data.size);
    const tarball_file = try util_http.download(parsed_uri, file_name, version_data.shasum, version_data.size, download_node);
    // defer tarball_file.close();
    download_node.end();
    items_done += 1;

    root_node.setCompletedItems(items_done);

    // Step 5: Download the signature file
    var signature_uri_buffer: [1024]u8 = undefined;
    const signature_uri_buf = try std.fmt.bufPrint(
        &signature_uri_buffer,
        "{s}.minisig",
        .{version_data.tarball},
    );

    const signature_uri = try std.Uri.parse(signature_uri_buffer[0..signature_uri_buf.len]);

    const signature_file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ file_name, ".minisig" },
    );

    // Create a child progress node for the signature download
    const sig_download_node = root_node.start("verifying file signature", 0);
    const minisig_file = try util_http.download(signature_uri, signature_file_name, null, null, sig_download_node);
    defer minisig_file.close();
    // sig_download_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Step 6: Perform Minisign Verification
    const zvm_store_path = try util_data.get_zvm_path_segment(allocator, "store");
    defer allocator.free(zvm_store_path);
    const tarball_path = try std.fs.path.join(arena_allocator, &.{ zvm_store_path, file_name });
    const sig_path = try std.fs.path.join(arena_allocator, &.{ zvm_store_path, signature_file_name });

    try util_minisign.verify(
        &allocator,
        sig_path,
        config.ZIG_MINISIGN_PUBLIC_KEY,
        tarball_path,
    );
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Proceed with extraction after successful verification
    const extract_node = root_node.start("extracting zig", 0);
    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});
    try util_extract.extract(extract_dir, tarball_file, if (builtin.os.tag == .windows) .zip else .tarxz, false, extract_node);
    extract_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Set the version alias
    try alias.set_version(version, false);

    root_node.end();
}

/// Try to install the specified version of zls
fn install_zls(version: []const u8) !void {
    const true_version = blk: {
        if (util_tool.eql_str("master", version)) {
            const zls_message = "Sorry, the 'install zls' feature is not supported at this time. Please compile zls locally.";
            try std.io.getStdOut().writer().print("{s}", .{zls_message});
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

    // Determine total steps
    const total_steps = 4;

    // Initialize progress root node
    const root_node = std.Progress.start(.{
        .root_name = "Installing ZLS",
        .estimated_total_items = total_steps,
    });

    var items_done: usize = 0;

    // Step 1: Get version path
    const version_path = try util_data.get_zvm_zls_version(arena_allocator);
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Step 2: Get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, true_version });
    items_done += 1;
    root_node.setCompletedItems(items_done);

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(true_version, true);
        root_node.end();
        return;
    }

    // Step 3: Get version data
    const version_data: meta.Zls.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zls_url);
        var zls_meta = try meta.Zls.init(res, arena_allocator);
        const tmp_val = try zls_meta.get_version_data(true_version, reverse_platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Step 4: Download the tarball
    const file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ "zls-", reverse_platform_str, "-", true_version, ".", config.archive_ext },
    );

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;

    // Create a child progress node for the download
    const download_node = root_node.start("Downloading ZLS tarball", version_data.size);
    const new_file = try util_http.download(parsed_uri, file_name, null, version_data.size, download_node);
    defer new_file.close();
    download_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Proceed with extraction
    const extract_node = root_node.start("Extracting ZLS tarball", 0);
    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});
    try util_extract.extract(extract_dir, new_file, if (builtin.os.tag == .windows) .zip else .tarxz, true, extract_node);
    extract_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    try alias.set_version(true_version, true);
}

pub fn build_zls() !void {}
