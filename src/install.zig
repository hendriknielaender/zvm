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
    const tarball_file = try download_with_mirrors(version_data, root_node, &items_done);

    root_node.setCompletedItems(items_done);

    // Step 5: Download the signature file
    const file_name = std.fs.path.basename(version_data.tarball);
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

/// Attempts to download the Zig tarball from the primary source or mirrors
/// Returns the downloaded file handle on success
fn download_with_mirrors(
    version_data: meta.Zig.VersionData,
    root_node: Progress.Node,
    items_done: *usize,
) !std.fs.File {
    const allocator = util_data.get_allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const file_name = std.fs.path.basename(version_data.tarball);

    // Try preferred mirror first if specified
    if (config.preferred_mirror) |mirror_index| {
        if (mirror_index < config.zig_mirrors.len) {
            const mirror_url = config.zig_mirrors[mirror_index][0];

            // Construct the full mirror URL for the specific file
            const mirror_uri = try construct_mirror_uri(arena_allocator, mirror_url, file_name);

            const download_node = root_node.start(try std.fmt.allocPrint(arena_allocator, "download zig (mirror {d}): {s}", .{ mirror_index, mirror_url }), version_data.size);

            const result = util_http.download(mirror_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
                download_node.end();
                std.log.warn("Failed to download from preferred mirror {s}: {s}", .{ mirror_url, @errorName(err) });
                // Continue to try official source and other mirrors
                return try download_with_fallbacks(version_data, file_name, root_node, items_done);
            };
            download_node.end();
            items_done.* += 1;
            return result;
        } else {
            std.log.warn("Specified mirror index {d} is out of range (0-{d})", .{ mirror_index, config.zig_mirrors.len - 1 });
        }
    } else {
        std.log.debug("No preferred mirror specified, using official source", .{});
    }

    // Try official source first, then fall back to mirrors if that fails
    return try download_with_fallbacks(version_data, file_name, root_node, items_done);
}

fn download_with_fallbacks(
    version_data: meta.Zig.VersionData,
    file_name: []const u8,
    root_node: Progress.Node,
    items_done: *usize,
) !std.fs.File {
    const allocator = util_data.get_allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Try official source first
    const parsed_uri = try std.Uri.parse(version_data.tarball);

    // Log that we're using the official source
    std.log.info("Downloading from official source: {s}", .{version_data.tarball});

    const download_node = root_node.start(try std.fmt.allocPrint(arena_allocator, "download zig (official): {s}", .{version_data.tarball}), version_data.size);

    const result = util_http.download(parsed_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
        download_node.end();
        std.log.warn("Failed to download from official source: {s}", .{@errorName(err)});

        // Try each mirror in sequence
        return try download_from_mirrors(arena_allocator, version_data, file_name, root_node);
    };

    download_node.end();
    items_done.* += 1;
    return result;
}

/// Attempts to download from each mirror in sequence until one succeeds
fn download_from_mirrors(
    allocator: std.mem.Allocator,
    version_data: meta.Zig.VersionData,
    file_name: []const u8,
    root_node: Progress.Node,
) !std.fs.File {
    for (config.zig_mirrors, 0..) |mirror_info, i| {
        const mirror_url = mirror_info[0];
        const mirror_maintainer = mirror_info[1];

        // Log which mirror we're trying
        std.log.info("Trying mirror {d}/{d}: {s} ({s})", .{ i + 1, config.zig_mirrors.len, mirror_url, mirror_maintainer });

        const mirror_uri = try construct_mirror_uri(allocator, mirror_url, file_name);
        const mirror_node = root_node.start(
            try std.fmt.allocPrint(allocator, "mirror {d}/{d}: {s}", .{ i + 1, config.zig_mirrors.len, mirror_url }),
            version_data.size,
        );

        const result = util_http.download(mirror_uri, file_name, version_data.shasum, version_data.size, mirror_node) catch |err| {
            mirror_node.end();
            std.log.warn("Mirror {s} ({s}) failed: {s}", .{ mirror_url, mirror_maintainer, @errorName(err) });
            continue;
        };

        mirror_node.end();
        std.log.info("Successfully downloaded from mirror: {s} ({s})", .{ mirror_url, mirror_maintainer });
        return result;
    }

    return error.AllMirrorsFailed;
}

/// Constructs a URI for a mirror download
fn construct_mirror_uri(allocator: std.mem.Allocator, mirror_url: []const u8, file_name: []const u8) !std.Uri {
    // Extract version and platform from filename
    // Format is typically: zig-<os>-<arch>-<version>.<ext>
    const version_start = std.mem.lastIndexOfScalar(u8, file_name, '-') orelse return error.InvalidFileName;
    const version = file_name[version_start + 1 .. std.mem.indexOf(u8, file_name, ".") orelse file_name.len];

    const mirror_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
        mirror_url,
        version,
        file_name,
    });

    return std.Uri.parse(mirror_path);
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

    const parsed_uri = std.Uri.parse(version_data.tarball) catch @panic("Invalid tarball data");

    // Create a child progress node for the download
    const download_node = root_node.start(try std.fmt.allocPrint(arena_allocator, "Downloading zls: {s}", .{version_data.tarball}), version_data.size);
    const new_file = try util_http.download(parsed_uri, file_name, null, version_data.size, download_node);
    defer new_file.close();
    download_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    // Proceed with extraction
    const extract_node = root_node.start("Extracting zls tarball", 0);
    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});
    try util_extract.extract(extract_dir, new_file, if (builtin.os.tag == .windows) .zip else .tarxz, true, extract_node);
    extract_node.end();
    items_done += 1;
    root_node.setCompletedItems(items_done);

    try alias.set_version(true_version, true);
}

pub fn build_zls() !void {}
