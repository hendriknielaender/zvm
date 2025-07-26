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
const util_minimumisign = @import("util/minisign.zig");
const context = @import("context.zig");
const object_pools = @import("object_pools.zig");
const limits = @import("limits.zig");
const Progress = std.Progress;

/// Try install specified version.
pub fn install(
    ctx: *context.CliContext,
    version: []const u8,
    is_zls: bool,
    root_node: Progress.Node,
    debug: bool,
) !void {
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version.len > 0);
    std.debug.assert(version.len < 100); // Reasonable version length
    if (is_zls) {
        try install_zls(ctx, version, root_node, debug);
    } else {
        try install_zig(ctx, version, root_node, debug);
    }
}

/// Try to install the specified version of zig.
fn install_zig(
    ctx: *context.CliContext,
    version: []const u8,
    root_node: Progress.Node,
    debug: bool,
) !void {
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version.len > 0);
    std.debug.assert(version.len < 100);

    if (debug) {
        std.debug.print("[DEBUG] Starting installation of Zig version: {s}\n", .{version});
    }

    const is_master = std.mem.eql(u8, version, "master");

    // Get platform string
    const platform_str = try get_platform_string(ctx, is_master, debug);

    var items_done: u32 = 0;

    // Get installation paths
    const paths = try get_install_paths(ctx, version, &items_done, root_node);

    // Check if already installed
    if (util_tool.does_path_exist(paths.extract_path)) {
        try alias.set_version(ctx, version, false);
        root_node.end();
        return;
    }

    // Fetch version metadata
    const version_data = try fetch_version_data(ctx, version, platform_str, &items_done, root_node, debug);

    // Download tarball
    const tarball_file = try download_with_mirrors(ctx, version_data, root_node, &items_done);

    root_node.setCompletedItems(items_done);

    // Download and verify signature
    try download_and_verify_signature(ctx, version_data, tarball_file, &items_done, root_node);

    // Extract and install
    try extract_and_install(ctx, paths.extract_path, tarball_file, &items_done, root_node);

    // Set the version alias
    try alias.set_version(ctx, version, false);

    root_node.end();
}

/// Installation paths structure
const InstallPaths = struct {
    version_path: []const u8,
    extract_path: []const u8,
};

/// Get platform string for the current system
fn get_platform_string(ctx: *context.CliContext, is_master: bool, debug: bool) ![]const u8 {
    // ctx is a pointer, not optional - no need for null check

    if (debug) {
        std.debug.print("[DEBUG] Is master version: {}\n", .{is_master});
        std.debug.print("[DEBUG] OS: {s}, Arch: {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    }

    var platform_buffer = try ctx.acquire_path_buffer();
    defer platform_buffer.reset();

    const platform_str = try util_arch.platform_str_static(
        platform_buffer,
        .{
            .os = builtin.os.tag,
            .arch = builtin.cpu.arch,
            .reverse = true,
            .is_master = is_master,
        },
    ) orelse {
        std.log.err("Unsupported platform: {s}-{s} is not supported for version {s}", .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            if (is_master) "master" else "release",
        });
        return error.UnsupportedPlatform;
    };

    std.debug.assert(platform_str.len > 0);
    std.debug.assert(platform_str.len < 100);

    if (debug) {
        std.debug.print("[DEBUG] Platform string: {s}\n", .{platform_str});
    }

    return platform_str;
}

/// Get installation paths
fn get_install_paths(
    ctx: *context.CliContext,
    version: []const u8,
    items_done: *u32,
    root_node: Progress.Node,
) !InstallPaths {
    std.debug.assert(version.len > 0);
    std.debug.assert(items_done.* >= 0);

    // Get version path
    var version_path_buffer = try ctx.acquire_path_buffer();
    defer version_path_buffer.reset();

    const version_path = try util_data.get_zvm_zig_version(version_path_buffer);
    std.debug.assert(version_path.len > 0);
    std.debug.assert(version_path.len <= limits.limits.path_length_maximum);

    items_done.* += 1;
    std.debug.assert(items_done.* > 0);
    root_node.setCompletedItems(items_done.*);

    // Get extract path
    var extract_path_buffer = try ctx.acquire_path_buffer();
    defer extract_path_buffer.reset();

    var fbs = std.io.fixedBufferStream(extract_path_buffer.slice());
    try fbs.writer().print("{s}/{s}", .{ version_path, version });
    const extract_path = try extract_path_buffer.set(fbs.getWritten());

    std.debug.assert(extract_path.len > 0);
    std.debug.assert(extract_path.len <= limits.limits.path_length_maximum);

    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);

    return InstallPaths{
        .version_path = version_path,
        .extract_path = extract_path,
    };
}

/// Fetch version metadata from the server
fn fetch_version_data(
    ctx: *context.CliContext,
    version: []const u8,
    platform_str: []const u8,
    items_done: *u32,
    root_node: Progress.Node,
    debug: bool,
) !meta.Zig.VersionData {
    std.debug.assert(version.len > 0);
    std.debug.assert(platform_str.len > 0);
    std.debug.assert(items_done.* >= 0);

    if (debug) {
        std.debug.print("[DEBUG] Fetching version data from: {s}\n", .{config.zig_meta_url});
    }

    var http_op = try ctx.acquire_http_operation();
    defer http_op.release();

    const res = try util_http.http_get_static(http_op, config.zig_url);
    // Validate response
    std.debug.assert(res.len > 0);

    if (debug) {
        std.debug.print("[DEBUG] HTTP response received, parsing metadata...\n", .{});
    }

    // Parse metadata
    var zig_meta = try meta.Zig.init(res, ctx.get_allocator());
    defer zig_meta.deinit();

    const tmp_val = try zig_meta.get_version_data(version, platform_str, ctx.get_allocator());

    if (debug) {
        debug_print_version_data(tmp_val, version, platform_str);
    }

    const version_data = tmp_val orelse {
        std.log.err("Unsupported version '{s}' for platform '{s}'. Check available versions with 'zvm list'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(version_data.size > 0);
    std.debug.assert(version_data.shasum.len > 0);

    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);

    return version_data;
}

/// Debug print version data
fn debug_print_version_data(version_data: ?meta.Zig.VersionData, version: []const u8, platform_str: []const u8) void {
    if (version_data) |vd| {
        std.debug.print("[DEBUG] Version data found:\n", .{});
        std.debug.print("[DEBUG]   Tarball: {s}\n", .{vd.tarball});
        std.debug.print("[DEBUG]   Size: {d}\n", .{vd.size});
        std.debug.print("[DEBUG]   Shasum: {s}\n", .{vd.shasum});
    } else {
        std.debug.print("[DEBUG] No version data found for version {s} on platform {s}\n", .{ version, platform_str });
    }
}

/// Download and verify the minisign signature
fn download_and_verify_signature(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    tarball_file: std.fs.File,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(items_done.* >= 0);
    std.debug.assert(tarball_file.handle != 0);

    const file_name = std.fs.path.basename(version_data.tarball);
    std.debug.assert(file_name.len > 0);
    std.debug.assert(file_name.len <= version_data.tarball.len);

    // Download signature file
    const signature_file_name = try build_signature_filename(ctx, file_name);
    const signature_uri = try build_signature_uri(ctx, version_data.tarball);

    const sig_download_node = root_node.start("verifying file signature", 0);
    const minisig_file = try util_http.download_static(ctx, signature_uri, signature_file_name, null, null, sig_download_node);
    defer minisig_file.close();
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);

    // Verify signature
    // Note: We use path-based verification because minisign requires file paths,
    // not file handles. The tarball_file parameter ensures the file is properly
    // closed after verification completes.
    try verify_signature(ctx, file_name, signature_file_name);
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);
}

/// Build signature filename
fn build_signature_filename(ctx: *context.CliContext, file_name: []const u8) ![]const u8 {
    std.debug.assert(file_name.len > 0);

    var sig_name_buffer = try ctx.acquire_path_buffer();
    defer sig_name_buffer.reset();
    var sig_name_fbs = std.io.fixedBufferStream(sig_name_buffer.slice());
    try sig_name_fbs.writer().print("{s}.minisig", .{file_name});
    return try sig_name_buffer.set(sig_name_fbs.getWritten());
}

/// Build signature URI
fn build_signature_uri(ctx: *context.CliContext, tarball_url: []const u8) !std.Uri {
    std.debug.assert(tarball_url.len > 0);

    var sig_uri_buffer = try ctx.acquire_path_buffer();
    defer sig_uri_buffer.reset();

    var sig_fbs = std.io.fixedBufferStream(sig_uri_buffer.slice());
    try sig_fbs.writer().print("{s}.minisig", .{tarball_url});
    const signature_uri_str = sig_fbs.getWritten();

    // Validate URI string
    std.debug.assert(signature_uri_str.len > 0);
    std.debug.assert(signature_uri_str.len < limits.limits.url_length_maximum);

    return try std.Uri.parse(signature_uri_str);
}

/// Verify the minisign signature
fn verify_signature(
    ctx: *context.CliContext,
    file_name: []const u8,
    signature_file_name: []const u8,
) !void {
    std.debug.assert(file_name.len > 0);
    std.debug.assert(signature_file_name.len > 0);

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

/// Extract tarball and complete installation
fn extract_and_install(
    ctx: *context.CliContext,
    extract_path: []const u8,
    tarball_file: std.fs.File,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    std.debug.assert(extract_path.len > 0);
    std.debug.assert(items_done.* >= 0);

    const extract_node = root_node.start("extracting zig", 0);
    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    var extract_op = try ctx.acquire_extract_operation();
    defer extract_op.release();

    try util_extract.extract_static(
        extract_op,
        extract_dir,
        tarball_file,
        if (builtin.os.tag == .windows) .zip else .tarxz,
        false,
        extract_node,
    );
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
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(version_data.size > 0);
    std.debug.assert(items_done.* >= 0);

    const file_name = std.fs.path.basename(version_data.tarball);
    std.debug.assert(file_name.len > 0);
    std.debug.assert(file_name.len <= version_data.tarball.len);

    // Try preferred mirror first if specified.
    if (config.preferred_mirror) |mirror_index| {
        if (mirror_index < config.zig_mirrors.len) {
            const mirror_url = config.zig_mirrors[mirror_index][0];

            // Construct the full mirror URL for the specific file.
            var mirror_uri_buffer = try ctx.acquire_path_buffer();
            defer mirror_uri_buffer.reset();
            // mirror_uri_buffer is a pointer, not optional - no need for null check

            const mirror_uri = try construct_mirror_uri(mirror_uri_buffer, mirror_url, file_name);

            var node_name_buffer = try ctx.acquire_path_buffer();
            defer node_name_buffer.reset();
            var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
            try fbs.writer().print("download zig (mirror {d}): {s}", .{ mirror_index, mirror_url });
            const node_name = node_name_buffer.used_slice();

            const download_node = root_node.start(node_name, version_data.size);

            const result = util_http.download_static(ctx, mirror_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
                download_node.end();
                std.log.warn("Failed to download from preferred mirror {s}: {s}", .{ mirror_url, @errorName(err) });
                // Continue to try official source and other mirrors.
                return try download_with_fallbacks(ctx, version_data, file_name, root_node, items_done);
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

    // Try official source first, then fall back to mirrors if that fails.
    return try download_with_fallbacks(ctx, version_data, file_name, root_node, items_done);
}

fn download_with_fallbacks(
    ctx: *context.CliContext,
    version_data: meta.Zig.VersionData,
    file_name: []const u8,
    root_node: Progress.Node,
    items_done: *u32,
) !std.fs.File {
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(file_name.len > 0);
    std.debug.assert(items_done.* >= 0);
    // Try official source first.
    const parsed_uri = try std.Uri.parse(version_data.tarball);

    // Log that we're using the official source.
    std.log.info("Downloading from official source: {s}", .{version_data.tarball});

    var node_name_buffer = try ctx.acquire_path_buffer();
    defer node_name_buffer.reset();
    var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
    try fbs.writer().print("download zig (official): {s}", .{version_data.tarball});
    const node_name = node_name_buffer.used_slice();

    const download_node = root_node.start(node_name, version_data.size);

    const result = util_http.download_static(ctx, parsed_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
        download_node.end();
        std.log.warn("Failed to download from official source: {s}", .{@errorName(err)});

        // Try each mirror in sequence.
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
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(file_name.len > 0);

    for (config.zig_mirrors, 0..) |mirror_info, i| {
        const mirror_url = mirror_info[0];
        const mirror_maintainer = mirror_info[1];

        std.log.info("Trying mirror {d} ({s}): {s}", .{ i, mirror_maintainer, mirror_url });

        // Construct the full mirror URL for the specific file.
        var mirror_uri_buffer = try ctx.acquire_path_buffer();
        defer mirror_uri_buffer.reset();
        const mirror_uri = construct_mirror_uri(mirror_uri_buffer, mirror_url, file_name) catch |err| {
            std.log.warn("Failed to construct mirror URI for {s}: {s}", .{ mirror_url, @errorName(err) });
            continue;
        };

        var node_name_buffer = try ctx.acquire_path_buffer();
        defer node_name_buffer.reset();
        var fbs = std.io.fixedBufferStream(node_name_buffer.slice());
        try fbs.writer().print("download zig (mirror {d}): {s}", .{ i, mirror_url });
        const node_name = node_name_buffer.used_slice();

        const download_node = root_node.start(node_name, version_data.size);

        const result = util_http.download_static(ctx, mirror_uri, file_name, version_data.shasum, version_data.size, download_node) catch |err| {
            download_node.end();
            std.log.warn("Failed to download from mirror {s}: {s}", .{ mirror_url, @errorName(err) });
            continue;
        };

        download_node.end();
        return result;
    }

    std.log.err("All download attempts failed from {} mirrors", .{config.zig_mirrors.len});
    return error.AllDownloadsFailed;
}

/// Constructs a full mirror URI by appending the file name to the mirror base URL.
fn construct_mirror_uri(buffer: *object_pools.PathBuffer, mirror_url: []const u8, file_name: []const u8) !std.Uri {
    // buffer is a pointer, not optional - no need for null check
    std.debug.assert(mirror_url.len > 0);
    std.debug.assert(mirror_url.len < limits.limits.url_length_maximum / 2);
    std.debug.assert(file_name.len > 0);
    std.debug.assert(file_name.len < limits.limits.path_length_maximum);

    var fbs = std.io.fixedBufferStream(buffer.slice());

    // Ensure the mirror URL ends with a slash.
    if (mirror_url[mirror_url.len - 1] == '/') {
        try fbs.writer().print("{s}{s}", .{ mirror_url, file_name });
    } else {
        try fbs.writer().print("{s}/{s}", .{ mirror_url, file_name });
    }

    const uri_str = try buffer.set(fbs.getWritten());

    std.debug.assert(uri_str.len > 0);
    std.debug.assert(uri_str.len <= limits.limits.url_length_maximum);

    return try std.Uri.parse(uri_str);
}

/// Try to install ZLS.
fn install_zls(ctx: *context.CliContext, version: []const u8, root_node: Progress.Node, debug: bool) !void {
    // ctx is a pointer, not optional - no need for null check
    std.debug.assert(version.len > 0);
    std.debug.assert(version.len < 100);

    if (debug) {
        std.debug.print("[DEBUG] Starting installation of ZLS version: {s}\n", .{version});
    }

    // Get platform string for ZLS
    const platform_str = try get_zls_platform_string(ctx);

    // Get installation paths
    const paths = try get_zls_install_paths(ctx, version);

    // Check if already installed
    if (util_tool.does_path_exist(paths.extract_path)) {
        try alias.set_version(ctx, version, true);
        return;
    }

    // Fetch and download ZLS
    const version_data = try fetch_zls_version_data(ctx, platform_str, version);
    const tarball_file = try download_zls(ctx, version_data, root_node);
    defer tarball_file.close();

    // Extract and install
    try extract_zls(ctx, paths.extract_path, tarball_file, root_node);

    try alias.set_version(ctx, version, true);
}

/// Get platform string for ZLS
fn get_zls_platform_string(ctx: *context.CliContext) ![]const u8 {
    const platform_str = try util_arch.platform_str_for_zls(ctx) orelse {
        std.log.err("Unsupported platform for ZLS: {s}-{s}", .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        });
        return error.UnsupportedPlatform;
    };
    std.debug.assert(platform_str.len > 0);
    std.debug.assert(platform_str.len < 100);
    return platform_str;
}

/// ZLS installation paths structure
const ZlsPaths = struct {
    version_path: []const u8,
    extract_path: []const u8,
};

/// Get ZLS installation paths
fn get_zls_install_paths(ctx: *context.CliContext, version: []const u8) !ZlsPaths {
    std.debug.assert(version.len > 0);

    var version_path_buffer = try ctx.acquire_path_buffer();
    defer version_path_buffer.reset();

    const version_path = try util_data.get_zvm_zls_version(version_path_buffer);
    std.debug.assert(version_path.len > 0);
    std.debug.assert(version_path.len <= limits.limits.path_length_maximum);

    var extract_path_buffer = try ctx.acquire_path_buffer();
    defer extract_path_buffer.reset();

    var fbs = std.io.fixedBufferStream(extract_path_buffer.slice());
    try fbs.writer().print("{s}/{s}", .{ version_path, version });
    const extract_path = try extract_path_buffer.set(fbs.getWritten());

    std.debug.assert(extract_path.len > 0);
    std.debug.assert(extract_path.len <= limits.limits.path_length_maximum);

    return ZlsPaths{
        .version_path = version_path,
        .extract_path = extract_path,
    };
}

/// Fetch ZLS version metadata
fn fetch_zls_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zls.VersionData {
    std.debug.assert(platform_str.len > 0);
    std.debug.assert(version.len > 0);

    var http_op = try ctx.acquire_http_operation();
    defer http_op.release();

    const res = try util_http.http_get_static(http_op, config.zls_url);
    std.debug.assert(res.len > 0);

    var zls_meta = try meta.Zls.init(res, ctx.get_allocator());
    defer zls_meta.deinit();

    const version_data = try zls_meta.get_version_data(platform_str, version, ctx.get_allocator()) orelse {
        std.log.err("Unsupported ZLS version '{s}' for platform '{s}'. Check available versions with 'zvm ls --zls'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(version_data.size > 0);

    return version_data;
}

/// Download ZLS tarball
fn download_zls(
    ctx: *context.CliContext,
    version_data: meta.Zls.VersionData,
    root_node: Progress.Node,
) !std.fs.File {
    std.debug.assert(version_data.tarball.len > 0);
    std.debug.assert(version_data.size > 0);

    const parsed_uri = try std.Uri.parse(version_data.tarball);
    const file_name = std.fs.path.basename(version_data.tarball);

    std.debug.assert(file_name.len > 0);
    std.debug.assert(file_name.len <= version_data.tarball.len);

    const download_node = root_node.start("downloading zls", version_data.size);
    const tarball_file = try util_http.download_static(ctx, parsed_uri, file_name, null, version_data.size, download_node);
    download_node.end();

    return tarball_file;
}

/// Extract ZLS to installation directory
fn extract_zls(
    ctx: *context.CliContext,
    extract_path: []const u8,
    tarball_file: std.fs.File,
    root_node: Progress.Node,
) !void {
    std.debug.assert(extract_path.len > 0);

    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    var extract_op = try ctx.acquire_extract_operation();
    defer extract_op.release();

    try util_extract.extract_static(
        extract_op,
        extract_dir,
        tarball_file,
        if (builtin.os.tag == .windows) .zip else .tarGz,
        true,
        root_node,
    );
}

pub fn build_zls() !void {}
