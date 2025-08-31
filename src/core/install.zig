const std = @import("std");
const builtin = @import("builtin");
const config = @import("../metadata.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const util_arch = @import("../util/arch.zig");
const util_data = @import("../util/data.zig");
const util_extract = @import("../io/extract.zig");
const util_tool = @import("../util/tool.zig");
const http_client = @import("../io/http_client.zig");
const util_minimumisign = @import("../io/minisign.zig");
const context = @import("../Context.zig");
const object_pools = @import("../memory/object_pools.zig");
const limits = @import("../memory/limits.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.install);
const Progress = std.Progress;

/// Helper function to download a file with hash verification
/// This wraps HttpClient.downloadFile to provide the same interface as the old download_static
fn download_file_with_verification(
    ctx: *context.CliContext,
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
    progress_node: std.Progress.Node,
) !std.fs.File {
    var store_path_buffer = try ctx.acquire_path_buffer();
    defer store_path_buffer.reset();
    const zvm_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");
    var store = try std.fs.cwd().makeOpenPath(zvm_path, .{});
    defer store.close();

    if (util_tool.does_path_exist2(store, file_name)) {
        if (shasum) |expected_hash| {
            const file = try store.openFile(file_name, .{});
            defer file.close();

            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [limits.limits.temp_buffer_size]u8 = undefined;
            while (true) {
                const byte_nums = try file.read(&buffer);
                if (byte_nums == 0) break;
                sha256.update(buffer[0..byte_nums]);
            }
            var result = std.mem.zeroes([32]u8);
            sha256.final(&result);

            if (verify_hash(result, expected_hash)) {
                try file.seekTo(0);
                progress_node.end();
                // Re-open the file for reading (like the old code did)
                return try store.openFile(file_name, .{});
            }
        }
        try store.deleteFile(file_name);
    }

    const new_file = try store.createFile(file_name, .{ .read = true });

    try http_client.HttpClient.download_file(ctx, uri, .{}, new_file, progress_node);

    if (size) |expected_size| {
        const file_stat = try new_file.stat();
        if (file_stat.size != expected_size) {
            try store.deleteFile(file_name);
            return error.IncorrectSize;
        }
    }

    if (shasum) |expected_hash| {
        try new_file.seekTo(0);
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [512]u8 = undefined;
        while (true) {
            const bytes_read = try new_file.read(&buffer);
            if (bytes_read == 0) break;
            sha256.update(buffer[0..bytes_read]);
        }
        var result = std.mem.zeroes([32]u8);
        sha256.final(&result);

        if (!verify_hash(result, expected_hash)) {
            try store.deleteFile(file_name);
            return error.HashMismatch;
        }
    }

    new_file.close();
    return try store.openFile(file_name, .{});
}

fn verify_hash(computed_hash: [32]u8, actual_hash_string: [64]u8) bool {
    var expected: [32]u8 = undefined;
    for (0..32) |i| {
        const high = std.fmt.charToDigit(actual_hash_string[i * 2], 16) catch return false;
        const low = std.fmt.charToDigit(actual_hash_string[i * 2 + 1], 16) catch return false;
        expected[i] = (high << 4) | low;
    }
    return std.mem.eql(u8, &computed_hash, &expected);
}

pub fn install(
    ctx: *context.CliContext,
    version: []const u8,
    is_zls: bool,
    root_node: Progress.Node,
) !void {
    assert(version.len > 0);
    assert(version.len < 100); // Reasonable version length
    if (is_zls) {
        try install_zls(ctx, version, root_node);
    } else {
        try install_zig(ctx, version, root_node);
    }
}

fn install_zig(
    ctx: *context.CliContext,
    version: []const u8,
    root_node: Progress.Node,
) !void {
    assert(version.len > 0);
    assert(version.len < 100);

    const is_master = std.mem.eql(u8, version, "master");

    // Get platform string and store it in a persistent buffer
    const platform_buffer = try ctx.acquire_path_buffer();
    const platform_str = try get_platform_string_into_buffer(is_master, platform_buffer);

    var items_done: u32 = 0;

    // Get paths and store them locally to avoid lifetime issues
    var version_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    var extract_path_storage: [limits.limits.path_length_maximum]u8 = undefined;

    const version_path = blk: {
        const version_path_buffer = try ctx.acquire_path_buffer();
        defer version_path_buffer.reset();
        const path = try util_data.get_zvm_zig_version(version_path_buffer);
        @memcpy(version_path_storage[0..path.len], path);
        break :blk version_path_storage[0..path.len];
    };
    items_done += 1;
    root_node.setCompletedItems(items_done);

    const extract_path = blk: {
        const extract_path_buffer = try ctx.acquire_path_buffer();
        defer extract_path_buffer.reset();
        var fbs = std.io.fixedBufferStream(extract_path_buffer.slice());
        try fbs.writer().print("{s}/{s}", .{ version_path, version });
        const path = try extract_path_buffer.set(fbs.getWritten());
        @memcpy(extract_path_storage[0..path.len], path);
        break :blk extract_path_storage[0..path.len];
    };
    items_done += 1;
    root_node.setCompletedItems(items_done);

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(ctx, version, false);
        root_node.end();
        return;
    }

    const version_data = try fetch_version_data(ctx, platform_str, version, &items_done, root_node);

    const tarball_file = try download_with_mirrors(ctx, version_data, root_node, &items_done);
    defer tarball_file.close();

    root_node.setCompletedItems(items_done);

    try download_and_verify_signature(ctx, version_data, &items_done, root_node);

    try extract_and_install(ctx, extract_path, tarball_file, &items_done, root_node);

    try alias.set_version(ctx, version, false);

    root_node.end();
}

fn get_platform_string_into_buffer(is_master: bool, platform_buffer: *object_pools.PathBuffer) ![]const u8 {
    const platform_str = try util_arch.platform_str_static(
        platform_buffer,
        .{
            .os = builtin.os.tag,
            .arch = builtin.cpu.arch,
            .reverse = true,
            .is_master = is_master,
        },
    ) orelse {
        log.err("Unsupported platform: {s}-{s} is not supported for version {s}", .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            if (is_master) "master" else "release",
        });
        return error.UnsupportedPlatform;
    };

    assert(platform_str.len > 0);
    assert(platform_str.len < 100);

    return platform_str;
}

fn fetch_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
    items_done: *u32,
    root_node: Progress.Node,
) !meta.Zig.VersionData {
    assert(version.len > 0);
    assert(platform_str.len > 0);
    assert(items_done.* >= 0);

    const res = try http_client.HttpClient.fetch(ctx, config.zig_url, .{});

    assert(res.len > 0);

    var zig_meta = try meta.Zig.init(res, ctx.get_json_allocator());
    defer zig_meta.deinit();

    const tmp_val = try zig_meta.get_version_data(version, platform_str, ctx.get_json_allocator());

    const version_data = tmp_val orelse {
        log.err("Unsupported version '{s}' for platform '{s}'. Check available versions with 'zvm list'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    assert(version_data.tarball.len > 0);
    assert(version_data.size > 0);
    assert(version_data.shasum.len > 0);

    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);

    return version_data;
}

fn download_and_verify_signature(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    assert(version_data.tarball.len > 0);
    assert(items_done.* >= 0);

    const file_name = std.fs.path.basename(version_data.tarball);
    assert(file_name.len > 0);
    assert(file_name.len <= version_data.tarball.len);

    const signature_file_name = try build_signature_filename(ctx, file_name);

    var sig_url_buffer: [limits.limits.url_length_maximum]u8 = undefined;
    const sig_url = try std.fmt.bufPrint(&sig_url_buffer, "{s}.minisig", .{version_data.tarball});

    const sig_download_node = root_node.start("verifying file signature", 0);
    const minisig_file = try download_file_from_url(ctx, sig_url, signature_file_name, null, null, sig_download_node);
    minisig_file.close();
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);

    // not file handles.
    try verify_signature(ctx, file_name, signature_file_name);
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);
}

fn build_signature_filename(ctx: *context.CliContext, file_name: []const u8) ![]const u8 {
    assert(file_name.len > 0);

    var sig_name_buffer = try ctx.acquire_path_buffer();

    var sig_name_fbs = std.io.fixedBufferStream(sig_name_buffer.slice());
    try sig_name_fbs.writer().print("{s}.minisig", .{file_name});
    return try sig_name_buffer.set(sig_name_fbs.getWritten());
}

fn download_file_from_url(
    ctx: *context.CliContext,
    url: []const u8,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
    progress_node: std.Progress.Node,
) !std.fs.File {
    const uri = try std.Uri.parse(url);
    return try download_file_with_verification(ctx, uri, file_name, shasum, size, progress_node);
}

fn verify_signature(
    ctx: *context.CliContext,
    file_name: []const u8,
    signature_file_name: []const u8,
) !void {
    assert(file_name.len > 0);
    assert(signature_file_name.len > 0);

    var store_path_buffer = try ctx.acquire_path_buffer();
    defer store_path_buffer.reset();
    const zvm_store_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");

    var tarball_path_buffer = try ctx.acquire_path_buffer();
    defer tarball_path_buffer.reset();
    var tarball_fbs = std.io.fixedBufferStream(tarball_path_buffer.slice());
    try tarball_fbs.writer().print("{s}/{s}", .{ zvm_store_path, file_name });
    const tarball_path = try tarball_path_buffer.set(tarball_fbs.getWritten());

    var sig_path_buffer = try ctx.acquire_path_buffer();
    defer sig_path_buffer.reset();
    var sig_path_fbs = std.io.fixedBufferStream(sig_path_buffer.slice());
    try sig_path_fbs.writer().print("{s}/{s}", .{ zvm_store_path, signature_file_name });
    const sig_path = try sig_path_buffer.set(sig_path_fbs.getWritten());

    try util_minimumisign.verify_static(
        ctx,
        sig_path,
        config.ZIG_MINISIGN_PUBLIC_KEY,
        tarball_path,
    );
}

fn extract_and_install(
    ctx: *context.CliContext,
    extract_path: []const u8,
    tarball_file: std.fs.File,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    assert(extract_path.len > 0);
    assert(items_done.* >= 0);

    const extract_node = root_node.start("extracting zig", 0);

    if (util_tool.does_path_exist(extract_path)) {
        try std.fs.deleteTreeAbsolute(extract_path);
    }

    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    var extract_op = try ctx.acquire_extract_operation();
    defer extract_op.release();

    util_extract.extract_static(
        extract_op,
        extract_dir,
        tarball_file,
        if (builtin.os.tag == .windows) .zip else .tarxz,
        false,
        extract_node,
    ) catch |err| {
        log.err("Extraction failed with error: {s} for path: {s}", .{ @errorName(err), extract_path });

        try std.fs.deleteTreeAbsolute(extract_path);
        return err;
    };

    extract_node.end();
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);
}

/// Attempts to download the Zig tarball from the primary source or mirrors.
/// Returns the downloaded file handle on success.
fn download_with_mirrors(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    root_node: Progress.Node,
    items_done: *u32,
) !std.fs.File {
    assert(version_data.tarball.len > 0);
    assert(version_data.size > 0);
    assert(items_done.* >= 0);

    const file_name = std.fs.path.basename(version_data.tarball);
    assert(file_name.len > 0);
    assert(file_name.len <= version_data.tarball.len);

    if (config.preferred_mirror) |mirror_index| {
        if (mirror_index < config.zig_mirrors.len) {
            const mirror_url = config.zig_mirrors[mirror_index][0];

            var mirror_uri_buffer = try ctx.acquire_path_buffer();
            defer mirror_uri_buffer.reset();

            const mirror_uri = try construct_mirror_uri(mirror_uri_buffer, mirror_url, file_name);

            var node_name_buffer = try ctx.acquire_path_buffer();
            defer node_name_buffer.reset();
            var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
            try fbs.writer().print("download zig (mirror {d}): {s}", .{ mirror_index, mirror_url });
            const node_name = node_name_buffer.used_slice();

            const download_node = root_node.start(node_name, version_data.size);

            const result = download_file_with_verification(ctx, mirror_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
                download_node.end();
                log.warn("Failed to download from preferred mirror {s}: {s}", .{ mirror_url, @errorName(err) });
                // Continue to try official source and other mirrors.
                return try download_with_fallbacks(ctx, version_data, file_name, root_node, items_done);
            };
            download_node.end();
            items_done.* += 1;
            return result;
        } else {
            log.warn("Specified mirror index {d} is out of range (0-{d})", .{ mirror_index, config.zig_mirrors.len - 1 });
        }
    } else {
        log.debug("No preferred mirror specified, using official source", .{});
    }

    return try download_with_fallbacks(ctx, version_data, file_name, root_node, items_done);
}

fn download_with_fallbacks(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    file_name: []const u8,
    root_node: Progress.Node,
    items_done: *u32,
) !std.fs.File {
    assert(version_data.tarball.len > 0);
    assert(file_name.len > 0);
    assert(items_done.* >= 0);

    const parsed_uri = try std.Uri.parse(version_data.tarball);

    log.info("Downloading from official source: {s}", .{version_data.tarball});

    var node_name_buffer = try ctx.acquire_path_buffer();
    defer node_name_buffer.reset();
    var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
    try fbs.writer().print("download zig (official): {s}", .{version_data.tarball});
    const node_name = node_name_buffer.used_slice();

    const download_node = root_node.start(node_name, version_data.size);

    const result = download_file_with_verification(ctx, parsed_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
        download_node.end();
        log.warn("Failed to download from official source: {s}", .{@errorName(err)});

        return try download_from_mirrors(ctx, version_data, file_name, root_node);
    };

    download_node.end();
    items_done.* += 1;
    return result;
}

/// Attempts to download from each mirror in sequence until one succeeds.
fn download_from_mirrors(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    file_name: []const u8,
    root_node: Progress.Node,
) !std.fs.File {
    assert(version_data.tarball.len > 0);
    assert(file_name.len > 0);

    for (config.zig_mirrors, 0..) |mirror_info, i| {
        const mirror_url = mirror_info[0];
        const mirror_maintainer = mirror_info[1];

        log.info("Trying mirror {d} ({s}): {s}", .{ i, mirror_maintainer, mirror_url });

        var mirror_uri_buffer = try ctx.acquire_path_buffer();
        defer mirror_uri_buffer.reset();
        const mirror_uri = construct_mirror_uri(mirror_uri_buffer, mirror_url, file_name) catch |err| {
            log.warn("Failed to construct mirror URI for {s}: {s}", .{ mirror_url, @errorName(err) });
            continue;
        };

        var node_name_buffer = try ctx.acquire_path_buffer();
        defer node_name_buffer.reset();
        var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
        try fbs.writer().print("download zig (mirror {d}): {s}", .{ i, mirror_url });
        const node_name = node_name_buffer.used_slice();

        const download_node = root_node.start(node_name, version_data.size);

        const result = download_file_with_verification(ctx, mirror_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
            download_node.end();
            log.warn("Failed to download from mirror {s}: {s}", .{ mirror_url, @errorName(err) });
            continue;
        };

        download_node.end();
        return result;
    }

    log.err("All download attempts failed from {} mirrors", .{config.zig_mirrors.len});
    return error.AllDownloadsFailed;
}

fn construct_mirror_uri(buffer: *object_pools.PathBuffer, mirror_url: []const u8, file_name: []const u8) !std.Uri {
    assert(mirror_url.len > 0);
    assert(mirror_url.len < limits.limits.url_length_maximum / 2);
    assert(file_name.len > 0);
    assert(file_name.len < limits.limits.path_length_maximum);

    var fbs = std.io.fixedBufferStream(buffer.slice());

    if (mirror_url[mirror_url.len - 1] == '/') {
        try fbs.writer().print("{s}{s}", .{ mirror_url, file_name });
    } else {
        try fbs.writer().print("{s}/{s}", .{ mirror_url, file_name });
    }

    const uri_str = try buffer.set(fbs.getWritten());

    assert(uri_str.len > 0);
    assert(uri_str.len <= limits.limits.url_length_maximum);

    return try std.Uri.parse(uri_str);
}

fn install_zls(ctx: *context.CliContext, version: []const u8, root_node: Progress.Node) !void {
    assert(version.len > 0);
    assert(version.len < 100);

    var platform_str_buffer: [100]u8 = undefined;
    const platform_str_temp = try get_zls_platform_string(ctx);
    if (platform_str_temp.len > platform_str_buffer.len) {
        return error.PlatformStringTooLong;
    }
    @memcpy(platform_str_buffer[0..platform_str_temp.len], platform_str_temp);
    const platform_str = platform_str_buffer[0..platform_str_temp.len];

    // Get version path directly
    var version_path_buffer = try ctx.acquire_path_buffer();
    defer version_path_buffer.reset();
    const version_path = try util_data.get_zvm_zls_version(version_path_buffer);

    // Format extract path directly
    var extract_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const extract_path = try std.fmt.bufPrint(&extract_path_storage, "{s}/{s}", .{ version_path, version });

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(ctx, version, true);
        return;
    }

    const version_data = try fetch_zls_version_data(ctx, platform_str, version);
    const tarball_file = try download_zls(ctx, version_data, root_node);
    defer tarball_file.close();

    try extract_zls(ctx, extract_path, tarball_file, root_node);

    try alias.set_version(ctx, version, true);
}

fn get_zls_platform_string(ctx: *context.CliContext) ![]const u8 {
    const platform_str = try util_arch.platform_str_for_zls(ctx) orelse {
        log.err("Unsupported platform for ZLS: {s}-{s}", .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        });
        return error.UnsupportedPlatform;
    };
    assert(platform_str.len > 0);
    assert(platform_str.len < 100);
    return platform_str;
}

fn fetch_zls_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zls.VersionData {
    assert(platform_str.len > 0);
    assert(version.len > 0);

    const res = try http_client.HttpClient.fetch(ctx, config.zls_url, .{});
    assert(res.len > 0);

    var zls_meta = try meta.Zls.init(res, ctx.get_json_allocator());
    defer zls_meta.deinit();

    const version_data = try zls_meta.get_version_data(version, platform_str, ctx.get_json_allocator()) orelse {
        log.err("Unsupported ZLS version '{s}' for platform '{s}'. Check available versions with 'zvm ls --zls'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    assert(version_data.tarball.len > 0);
    assert(version_data.size > 0);

    return version_data;
}

fn download_zls(
    ctx: *context.CliContext,
    version_data: meta.Zls.VersionData,
    root_node: Progress.Node,
) !std.fs.File {
    assert(version_data.tarball.len > 0);
    assert(version_data.size > 0);

    const parsed_uri = try std.Uri.parse(version_data.tarball);
    const file_name = std.fs.path.basename(version_data.tarball);

    assert(file_name.len > 0);
    assert(file_name.len <= version_data.tarball.len);

    const download_node = root_node.start("downloading zls", version_data.size);
    const tarball_file = try download_file_with_verification(ctx, parsed_uri, file_name, null, version_data.size, download_node);
    download_node.end();

    return tarball_file;
}

fn extract_zls(
    ctx: *context.CliContext,
    extract_path: []const u8,
    tarball_file: std.fs.File,
    root_node: Progress.Node,
) !void {
    assert(extract_path.len > 0);

    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    var extract_op = try ctx.acquire_extract_operation();
    defer extract_op.release();

    // ZLS uses .tar.xz format for non-Windows platforms
    try util_extract.extract_static(
        extract_op,
        extract_dir,
        tarball_file,
        if (builtin.os.tag == .windows) .zip else .tarxz,
        true,
        root_node,
    );
}
