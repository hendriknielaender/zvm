const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("../metadata.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const util_arch = @import("../util/arch.zig");
const util_data = @import("../util/data.zig");
const util_extract = @import("../io/extract.zig");
const util_tool = @import("../util/tool.zig");
const http_client = @import("../io/http_client.zig");
const minisign = @import("../io/minisign.zig");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");
const community_mirrors = @import("community_mirrors.zig");
const signals = @import("../platform/signals.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.install);
const Progress = std.Progress;
const cleanup_timeout_seconds: u32 = 10;

const DownloadFile = *const fn (
    ctx: *context.CliContext,
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?u64,
    progress_node: std.Progress.Node,
) anyerror!std.Io.File;

const ReleaseKind = enum {
    zig,
    zls,
};

const Release = struct {
    kind: ReleaseKind,
    version_buffer: [limits.version_string_length_maximum]u8,
    version_len: u32,
    /// Official download URL. Mirror URLs are derived from this URL's file
    /// name at download time, so only the official source is stored.
    tarball_url_buffer: [limits.url_length_maximum]u8,
    tarball_url_len: u32,
    hash: ?[64]u8,
    size: u64,
    signature_url_buffer: [limits.url_length_maximum]u8,
    signature_url_len: u32,
    extract_path_buffer: [limits.path_length_maximum]u8,
    extract_path_len: u32,
    staging_path_buffer: [limits.path_length_maximum]u8,
    staging_path_len: u32,

    comptime {
        // Release lives on the install path's stack frame; keep it bounded.
        assert(@sizeOf(Release) <= 20 * 1024);
    }

    fn init(self: *Release, kind: ReleaseKind) void {
        self.* = .{
            .kind = kind,
            // SAFETY: version_buffer is read only after set_version writes version_len bytes.
            .version_buffer = undefined,
            .version_len = 0,
            // SAFETY: tarball_url_buffer is read only after set_tarball_url writes tarball_url_len bytes.
            .tarball_url_buffer = undefined,
            .tarball_url_len = 0,
            .hash = null,
            .size = 0,
            // SAFETY: signature_url_buffer is read only when signature_url_len is non-zero.
            .signature_url_buffer = undefined,
            .signature_url_len = 0,
            // SAFETY: extract_path_buffer is read only after set_extract_path writes extract_path_len bytes.
            .extract_path_buffer = undefined,
            .extract_path_len = 0,
            // SAFETY: staging_path_buffer is read only after set_extract_path_from_parts writes staging_path_len bytes.
            .staging_path_buffer = undefined,
            .staging_path_len = 0,
        };
    }

    fn version(self: *const Release) []const u8 {
        assert(self.version_len > 0);
        return self.version_buffer[0..self.version_len];
    }

    fn tarball_url(self: *const Release) []const u8 {
        assert(self.tarball_url_len > 0);
        return self.tarball_url_buffer[0..self.tarball_url_len];
    }

    fn signature_url(self: *const Release) ?[]const u8 {
        if (self.signature_url_len > 0) {
            return self.signature_url_buffer[0..self.signature_url_len];
        } else {
            return null;
        }
    }

    fn extract_path(self: *const Release) []const u8 {
        assert(self.extract_path_len > 0);
        return self.extract_path_buffer[0..self.extract_path_len];
    }

    fn staging_path(self: *const Release) []const u8 {
        assert(self.staging_path_len > 0);
        return self.staging_path_buffer[0..self.staging_path_len];
    }

    fn is_zls(self: *const Release) bool {
        return self.kind == .zls;
    }

    fn set_version(self: *Release, version_text: []const u8) !void {
        assert(version_text.len > 0);
        assert(version_text.len <= self.version_buffer.len);

        @memcpy(self.version_buffer[0..version_text.len], version_text);
        self.version_len = @intCast(version_text.len);
    }

    fn set_extract_path(self: *Release, install_path: []const u8) !void {
        assert(install_path.len > 0);
        assert(install_path.len <= self.extract_path_buffer.len);

        @memcpy(self.extract_path_buffer[0..install_path.len], install_path);
        self.extract_path_len = @intCast(install_path.len);
    }

    fn set_extract_path_from_parts(
        self: *Release,
        ctx: *context.CliContext,
        version_root: []const u8,
        version_text: []const u8,
    ) !void {
        assert(version_root.len > 0);
        assert(version_text.len > 0);

        var path_buffer = try ctx.scratch(.path);
        defer path_buffer.release();
        const install_path = try path_buffer.set(
            try std.fmt.bufPrint(path_buffer.slice(), "{s}/{s}", .{ version_root, version_text }),
        );
        try self.set_extract_path(install_path);

        // Staging lives under the same parent as the final path so the
        // publish rename never crosses filesystems. The process id keeps
        // concurrent installs of the same version from clobbering each
        // other's staging tree.
        const staging = try std.fmt.bufPrint(
            &self.staging_path_buffer,
            "{s}/.staging/{s}-{d}",
            .{ version_root, version_text, util_tool.process_id() },
        );
        self.staging_path_len = @intCast(staging.len);

        assert(self.staging_path_len > 0);
        assert(!std.mem.eql(u8, self.staging_path(), self.extract_path()));
    }

    fn set_tarball_url(self: *Release, url: []const u8) !void {
        assert(url.len > 0);
        assert(url.len <= self.tarball_url_buffer.len);

        @memcpy(self.tarball_url_buffer[0..url.len], url);
        self.tarball_url_len = @intCast(url.len);
    }

    fn set_signature_url(self: *Release, url: []const u8) !void {
        assert(url.len > 0);
        assert(url.len <= self.signature_url_buffer.len);

        @memcpy(self.signature_url_buffer[0..url.len], url);
        self.signature_url_len = @intCast(url.len);
    }
};

const InstallProgress = struct {
    root_node: Progress.Node,
    items_done: u32,

    fn init(root_node: Progress.Node) InstallProgress {
        return .{
            .root_node = root_node,
            .items_done = 0,
        };
    }

    fn finish_item(self: *InstallProgress) void {
        self.items_done += 1;
        self.root_node.setCompletedItems(self.items_done);
    }

    fn start(self: *InstallProgress, name: []const u8, estimated_total_items: usize) Progress.Node {
        return self.root_node.start(name, estimated_total_items);
    }
};

/// Helper function to download a file with hash verification
/// This wraps HttpClient.downloadFile to provide the same interface as the old download_static
pub fn download_file_with_verification(
    ctx: *context.CliContext,
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?u64,
    progress_node: std.Progress.Node,
) !std.Io.File {
    defer progress_node.end();
    try signals.check();
    var store_path_buffer = try ctx.scratch(.path);
    defer store_path_buffer.release();
    const zvm_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");
    var store = try std.Io.Dir.cwd().createDirPathOpen(ctx.io, zvm_path, .{});
    defer store.close(ctx.io);

    if (util_tool.does_path_exist2(ctx.io, store, file_name)) {
        if (shasum) |expected_hash| {
            const file = try store.openFile(ctx.io, file_name, .{});
            defer file.close(ctx.io);

            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [limits.temp_buffer_size]u8 = undefined;
            var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
            var file_reader = file.reader(ctx.io, &reader_buffer);
            while (true) {
                try signals.check();
                const byte_nums = try file_reader.interface.readSliceShort(&buffer);
                if (byte_nums == 0) break;
                sha256.update(buffer[0..byte_nums]);
            }
            var result = std.mem.zeroes([32]u8);
            sha256.final(&result);

            if (verify_hash(result, expected_hash)) {
                // Re-open the file for reading (like the old code did)
                return try store.openFile(ctx.io, file_name, .{});
            }
        }
        try store.deleteFile(ctx.io, file_name);
    }

    const new_file = try store.createFile(ctx.io, file_name, .{ .read = true });
    errdefer new_file.close(ctx.io);

    try http_client.HttpClient.download_file(ctx, uri, .{}, new_file, progress_node);
    try signals.check();

    if (size) |expected_size| {
        const file_stat = try new_file.stat(ctx.io);
        if (file_stat.size != expected_size) {
            try store.deleteFile(ctx.io, file_name);
            return error.IncorrectSize;
        }
    }

    if (shasum) |expected_hash| {
        var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [512]u8 = undefined;
        var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
        var file_reader = new_file.reader(ctx.io, &reader_buffer);
        while (true) {
            try signals.check();
            const bytes_read = try file_reader.interface.readSliceShort(&buffer);
            if (bytes_read == 0) break;
            sha256.update(buffer[0..bytes_read]);
        }
        var result = std.mem.zeroes([32]u8);
        sha256.final(&result);

        if (!verify_hash(result, expected_hash)) {
            try store.deleteFile(ctx.io, file_name);
            return error.HashMismatch;
        }
    }

    new_file.close(ctx.io);
    return try store.openFile(ctx.io, file_name, .{});
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
    assert(version.len <= limits.version_string_length_maximum);

    if (try switch_to_installed_release(ctx, version, is_zls)) {
        return;
    }

    // SAFETY: resolve_*_release initializes release before install_release reads it.
    var release: Release = undefined;
    // Mirrors apply to Zig only; zls downloads always use the official URL.
    var mirrors = community_mirrors.UrlList.init();
    if (is_zls) {
        try resolve_zls_release(ctx, &release, version);
    } else {
        try resolve_zig_release(ctx, &release, version);
        load_community_mirrors(ctx, &mirrors);
    }
    try install_release(ctx, &release, &mirrors, root_node);
}

fn switch_to_installed_release(
    ctx: *context.CliContext,
    version: []const u8,
    is_zls: bool,
) !bool {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    var version_root_buffer = try ctx.scratch(.path);
    defer version_root_buffer.release();
    const version_root = if (is_zls)
        try util_data.get_zvm_zls_version(version_root_buffer)
    else
        try util_data.get_zvm_zig_version(version_root_buffer);

    var install_path_buffer = try ctx.scratch(.path);
    defer install_path_buffer.release();
    const install_path = try install_path_buffer.set(
        try std.fmt.bufPrint(install_path_buffer.slice(), "{s}/{s}", .{
            version_root,
            version,
        }),
    );

    return switch_if_installed(ctx, install_path, version, is_zls);
}

/// Switch to the install at `install_path` when it is complete, returning
/// true. Legacy installs (predating the manifest) are verified through
/// their tool binary and given a manifest so later checks see them as
/// complete. Torn directories are deleted so the caller reinstalls them.
fn switch_if_installed(
    ctx: *context.CliContext,
    install_path: []const u8,
    version: []const u8,
    is_zls: bool,
) !bool {
    assert(install_path.len > 0);
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    const state = try util_data.classify_install(ctx.io, install_path, version, is_zls);
    switch (state) {
        .missing => return false,
        .torn => {
            log.warn("Incomplete installation at {s}; removing it before reinstalling.", .{
                install_path,
            });
            try std.Io.Dir.cwd().deleteTree(ctx.io, install_path);
            assert(!util_tool.does_path_exist(ctx.io, install_path));
            return false;
        },
        .installed_legacy => {
            try util_data.write_version_manifest(ctx.io, install_path, version);
        },
        .installed => {},
    }

    try alias.set_version(ctx, version, is_zls);
    return true;
}

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.InstallCommand,
    progress_node: Progress.Node,
) !void {
    const version = command.get_version();
    try install(ctx, version, command.tool == .zls, progress_node);
}

pub fn progress_items(command: validation.ValidatedCommand.InstallCommand) u16 {
    _ = command;
    return 5;
}

fn resolve_zig_release(
    ctx: *context.CliContext,
    release: *Release,
    version: []const u8,
) !void {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    const is_master = util_tool.is_master_like_version(version);

    var platform_buffer = try ctx.scratch(.path);
    defer platform_buffer.release();
    const platform_str = try get_platform_string_into_buffer(is_master, platform_buffer);
    const version_data = try fetch_version_data(ctx, platform_str, version);

    var version_root_storage: [limits.path_length_maximum]u8 = undefined;
    const version_root = try resolve_zig_version_root(ctx, &version_root_storage);

    release.init(.zig);
    try release.set_version(version_data.version());
    try release.set_extract_path_from_parts(ctx, version_root, release.version());
    release.hash = version_data.shasum;
    release.size = version_data.size;
    try release.set_tarball_url(version_data.tarball());

    var signature_url_buffer: [limits.url_length_maximum]u8 = undefined;
    const signature_url = try std.fmt.bufPrint(&signature_url_buffer, "{s}.minisig", .{
        version_data.tarball(),
    });
    try release.set_signature_url(signature_url);

    assert(release.tarball_url().len > 0);
    assert(release.signature_url() != null);
}

fn resolve_zls_release(
    ctx: *context.CliContext,
    release: *Release,
    version: []const u8,
) !void {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    var platform_str_buffer: [limits.platform_string_length_maximum]u8 = undefined;
    const platform_str_temp = try get_zls_platform_string(ctx);
    if (platform_str_temp.len <= platform_str_buffer.len) {
        @memcpy(platform_str_buffer[0..platform_str_temp.len], platform_str_temp);
    } else {
        return error.PlatformStringTooLong;
    }
    const platform_str = platform_str_buffer[0..platform_str_temp.len];

    // Stable releases live in the GitHub releases index. Master and pinned
    // dev builds live behind the `select-version` endpoint, which returns a
    // different JSON shape (per-platform tarball + shasum + size).
    if (util_tool.is_master_like_version(version)) {
        try resolve_zls_master_release(ctx, release, version, platform_str);
        return;
    }

    const version_data = try fetch_zls_version_data(ctx, platform_str, version);

    var version_path_buffer = try ctx.scratch(.path);
    defer version_path_buffer.release();
    const version_root = try util_data.get_zvm_zls_version(version_path_buffer);

    release.init(.zls);
    try release.set_version(version_data.version());
    try release.set_extract_path_from_parts(ctx, version_root, release.version());
    release.hash = null;
    release.size = version_data.size;
    try release.set_tarball_url(version_data.tarball());

    assert(release.tarball_url().len > 0);
    assert(release.signature_url() == null);
}

fn resolve_zls_master_release(
    ctx: *context.CliContext,
    release: *Release,
    version: []const u8,
    platform_str: []const u8,
) !void {
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);
    assert(platform_str.len > 0);
    assert(util_tool.is_master_like_version(version));

    const version_data = try fetch_zls_master_version_data(ctx, platform_str, version);

    var version_path_buffer = try ctx.scratch(.path);
    defer version_path_buffer.release();
    const version_root = try util_data.get_zvm_zls_version(version_path_buffer);

    release.init(.zls);
    try release.set_version(version_data.version());
    try release.set_extract_path_from_parts(ctx, version_root, release.version());
    release.hash = version_data.shasum;
    release.size = version_data.size;
    try release.set_tarball_url(version_data.tarball());

    assert(release.tarball_url().len > 0);
    assert(release.signature_url() == null);
    assert(release.hash != null);
}

fn install_release(
    ctx: *context.CliContext,
    release: *const Release,
    mirrors: *const community_mirrors.UrlList,
    root_node: Progress.Node,
) !void {
    assert(release.version().len > 0);
    assert(release.tarball_url().len > 0);
    assert(release.size > 0);
    assert(release.extract_path().len > 0);
    assert(release.staging_path().len > 0);

    if (try switch_if_installed(ctx, release.extract_path(), release.version(), release.is_zls())) {
        return;
    }

    // Failures only ever leave a staging tree behind; the final path is
    // written exclusively by the publish rename, so cleanup never needs
    // to touch a completed install.
    errdefer |err| if (err == error.Interrupted) {
        cleanup_interrupted_install(ctx, release.staging_path());
    } else {
        cleanup_staging_best_effort(ctx, release.staging_path());
    };

    var progress = InstallProgress.init(root_node);
    try signals.check();
    const tarball_file = try acquire_release(
        ctx,
        release,
        mirrors,
        download_file_with_verification,
        &progress,
    );
    defer tarball_file.close(ctx.io);

    try stage_release(ctx, release, tarball_file, &progress);
    try signals.check();
    try publish_release(ctx, release);

    try alias.set_version(ctx, release.version(), release.is_zls());
}

/// Commit a fully staged release to its final path. The manifest is the
/// completion record: it is written and made durable inside the staging
/// tree first, then the rename publishes both at once — so the final path
/// either does not exist or holds a complete, manifest-carrying install.
fn publish_release(ctx: *context.CliContext, release: *const Release) !void {
    const staging_path = release.staging_path();
    const extract_path = release.extract_path();
    assert(staging_path.len > 0);
    assert(extract_path.len > 0);
    assert(util_tool.does_path_exist(ctx.io, staging_path));

    try util_data.write_version_manifest(ctx.io, staging_path, release.version());

    std.Io.Dir.renameAbsolute(staging_path, extract_path, ctx.io) catch |err| switch (err) {
        // A concurrent install published this version first. Published
        // directories always carry a manifest (verified below), so ours
        // is redundant; discard the staging tree and use the winner.
        error.DirNotEmpty => {
            const state = try util_data.classify_install(
                ctx.io,
                extract_path,
                release.version(),
                release.is_zls(),
            );
            if (state != .installed) return err;
            try std.Io.Dir.cwd().deleteTree(ctx.io, staging_path);
        },
        else => return err,
    };

    const published = try util_data.classify_install(
        ctx.io,
        extract_path,
        release.version(),
        release.is_zls(),
    );
    assert(published == .installed);
    assert(!util_tool.does_path_exist(ctx.io, staging_path));
}

/// Remove the staging tree after a failed install. Best effort: the next
/// install of this version overwrites its own staging path anyway, and
/// `zvm clean` sweeps whatever remains.
fn cleanup_staging_best_effort(ctx: *context.CliContext, staging_path: []const u8) void {
    assert(staging_path.len > 0);

    std.Io.Dir.cwd().deleteTree(ctx.io, staging_path) catch |err| {
        log.warn("Failed to remove staging directory {s}: {s}", .{
            staging_path,
            @errorName(err),
        });
    };
}

/// Load and order the community mirror list, tolerating failure: mirrors
/// are an optimization, and the official URL always remains as fallback.
fn load_community_mirrors(ctx: *context.CliContext, mirrors: *community_mirrors.UrlList) void {
    assert(mirrors.count == 0);

    community_mirrors.load(ctx, mirrors) catch |err| {
        mirrors.* = community_mirrors.UrlList.init();
        log.warn("Unable to use community mirrors: {s}", .{@errorName(err)});
        return;
    };
    mirrors.order(ctx.io, metadata.preferred_mirror);
}

/// Download the release tarball, trying each mirror in preference order and
/// the official URL last. Mirror URLs are derived per attempt from the
/// mirror base and the official tarball's file name.
fn acquire_release(
    ctx: *context.CliContext,
    release: *const Release,
    mirrors: *const community_mirrors.UrlList,
    download_file: DownloadFile,
    progress: *InstallProgress,
) !std.Io.File {
    assert(release.tarball_url().len > 0);
    assert(release.size > 0);
    assert(mirrors.count <= community_mirrors.max);
    if (release.kind == .zls) assert(mirrors.count == 0);

    const file_name = community_mirrors.basename(release.tarball_url());
    assert(file_name.len > 0);

    const attempts_total = mirrors.count + 1;
    var index: u32 = 0;
    while (index < attempts_total) : (index += 1) {
        var download_url_buffer = try ctx.scratch(.path);
        defer download_url_buffer.release();
        const download_url = if (index < mirrors.count)
            community_mirrors.construct_tarball_url(
                download_url_buffer,
                mirrors.get(index),
                file_name,
            ) catch |err| {
                log.warn("Invalid mirror URL {s}: {s}", .{ mirrors.get(index), @errorName(err) });
                continue;
            }
        else
            release.tarball_url();

        const uri = std.Uri.parse(download_url) catch |err| {
            log.warn("Invalid download URL {s}: {s}", .{ download_url, @errorName(err) });
            continue;
        };

        var node_name_buffer = try ctx.scratch(.path);
        defer node_name_buffer.release();
        const label = if (release.kind == .zig) "download zig" else "download zls";
        _ = try std.fmt.bufPrint(node_name_buffer.slice(), "{s}: {s}", .{ label, download_url });
        const node_name = node_name_buffer.used_slice();
        const download_node = progress.start(node_name, progress_items_from_size(release.size));

        const file = download_file(
            ctx,
            uri,
            file_name,
            release.hash,
            release.size,
            download_node,
        ) catch |err| {
            log.warn("Failed to download from {s}: {s}", .{ download_url, @errorName(err) });
            continue;
        };
        progress.finish_item();

        if (release.signature_url() != null) {
            verify_release_signature(ctx, release, download_url, progress) catch |err| {
                file.close(ctx.io);
                log.warn("Failed to verify download from {s}: {s}", .{ download_url, @errorName(err) });
                continue;
            };
        }

        return file;
    }

    log.err("All download attempts failed for {s}", .{release.version()});
    return error.AllDownloadsFailed;
}

fn verify_release_signature(
    ctx: *context.CliContext,
    release: *const Release,
    tarball_url: []const u8,
    progress: *InstallProgress,
) !void {
    assert(release.kind == .zig);
    assert(tarball_url.len > 0);

    const tarball_name = community_mirrors.basename(tarball_url);
    assert(tarball_name.len > 0);

    var sig_name_buffer = try ctx.scratch(.path);
    defer sig_name_buffer.release();
    const signature_file_name = try sig_name_buffer.print("{s}.minisig", .{tarball_name});

    var sig_url_buffer = try ctx.scratch(.path);
    defer sig_url_buffer.release();
    const signature_url = try community_mirrors.construct_signature_url(sig_url_buffer, tarball_url);

    const sig_download_node = progress.start("verifying file signature", 0);
    const minisig_file = try download_file_from_url(
        ctx,
        signature_url,
        signature_file_name,
        null,
        null,
        sig_download_node,
    );
    minisig_file.close(ctx.io);
    progress.finish_item();

    try verify_signature(ctx, tarball_name, signature_file_name);
    progress.finish_item();
}

fn stage_release(
    ctx: *context.CliContext,
    release: *const Release,
    tarball_file: std.Io.File,
    progress: *InstallProgress,
) !void {
    assert(release.staging_path().len > 0);

    var tarball_path_buffer = try ctx.scratch(.path);
    defer tarball_path_buffer.release();
    const zvm_store_path = try util_data.get_zvm_path_segment(tarball_path_buffer, "store");
    const tarball_file_name = community_mirrors.basename(release.tarball_url());
    var tarball_path_storage: [limits.path_length_maximum]u8 = undefined;
    const tarball_path = try std.fmt.bufPrint(&tarball_path_storage, "{s}/{s}", .{
        zvm_store_path,
        tarball_file_name,
    });

    try extract_to_staging(
        ctx,
        release.staging_path(),
        tarball_file,
        tarball_path,
        release.is_zls(),
        &progress.items_done,
        progress.root_node,
    );
}

fn resolve_zig_version_root(
    ctx: *context.CliContext,
    storage: *[limits.path_length_maximum]u8,
) ![]const u8 {
    assert(storage.len > 0);

    var path_buffer = try ctx.scratch(.path);
    defer path_buffer.release();
    const path = try util_data.get_zvm_zig_version(path_buffer);
    assert(path.len > 0);
    assert(path.len <= storage.len);
    @memcpy(storage[0..path.len], path);
    return storage[0..path.len];
}

/// Delete the staging tree after an interrupt. Only staging is ever
/// deleted: published installs are created atomically by publish_release,
/// so an interrupt can never leave one half-written.
fn cleanup_interrupted_install(ctx: *context.CliContext, staging_path: []const u8) void {
    assert(staging_path.len > 0);

    signals.begin_cleanup();
    defer signals.end_cleanup();

    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buffer);
    stderr_writer.interface.writeAll("\ninterrupted, cleaning up...\n") catch |err| {
        log.debug("Failed to write interrupted cleanup message: {s}", .{@errorName(err)});
    };
    stderr_writer.interface.flush() catch |err| {
        log.debug("Failed to flush interrupted cleanup message: {s}", .{@errorName(err)});
    };

    cleanup_delete_tree_with_timeout(ctx, staging_path) catch |err| {
        log.warn("Interrupted cleanup failed for {s}: {s}", .{ staging_path, @errorName(err) });
    };
}

fn cleanup_delete_tree_with_timeout(ctx: *context.CliContext, extract_path: []const u8) !void {
    assert(extract_path.len > 0);
    assert(cleanup_timeout_seconds > 0);

    const Outcome = union(enum) {
        completed: anyerror!void,
        timed_out: void,
    };

    var select_buffer: [2]Outcome = undefined;
    // Race cleanup against a timer and cancel whichever arm loses.
    var select: std.Io.Select(Outcome) = .init(ctx.io, &select_buffer);
    select.concurrent(.completed, cleanup_delete_tree, .{
        ctx.io,
        extract_path,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return cleanup_delete_tree(ctx.io, extract_path),
    };
    select.concurrent(.timed_out, cleanup_sleep, .{
        ctx.io,
        cleanup_timeout_seconds,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            const outcome = @field(std.Io.Select(Outcome), "await")(&select) catch |await_err| switch (await_err) {
                error.Canceled => {
                    _ = select.cancel();
                    return error.Canceled;
                },
            };
            return switch (outcome) {
                .completed => |result| {
                    _ = select.cancel();
                    return result;
                },
                .timed_out => unreachable,
            };
        },
    };

    const winner = @field(std.Io.Select(Outcome), "await")(&select) catch |err| switch (err) {
        error.Canceled => {
            _ = select.cancel();
            return error.Canceled;
        },
    };
    _ = select.cancel();

    switch (winner) {
        .completed => |result| return result,
        .timed_out => return error.CleanupTimeout,
    }
}

fn cleanup_delete_tree(io: std.Io, extract_path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, extract_path);
}

fn cleanup_sleep(io: std.Io, seconds: u32) void {
    const duration: std.Io.Duration = .fromSeconds(@intCast(seconds));
    // A canceled timer is the losing Select arm, so no error is reported.
    std.Io.sleep(io, duration, .awake) catch return;
}

pub fn get_platform_string_into_buffer(is_master: bool, platform_buffer: anytype) ![]const u8 {
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
    assert(platform_str.len <= limits.platform_string_length_maximum);

    return platform_str;
}

fn fetch_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zig.VersionData {
    assert(version.len > 0);
    assert(platform_str.len > 0);

    const res = try http_client.HttpClient.fetch(ctx, metadata.zig_url, .{});

    assert(res.len > 0);

    const version_data = try meta.Zig.get_version_data(res, version, platform_str) orelse {
        log.err("Unsupported version '{s}' for platform '{s}'. Check available versions with " ++
            "'zvm list'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    assert(version_data.tarball().len > 0);
    assert(version_data.size > 0);
    assert(version_data.shasum.len > 0);

    return version_data;
}

fn download_file_from_url(
    ctx: *context.CliContext,
    url: []const u8,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?u64,
    progress_node: std.Progress.Node,
) !std.Io.File {
    const uri = try std.Uri.parse(url);
    return try download_file_with_verification(ctx, uri, file_name, shasum, size, progress_node);
}

fn progress_items_from_size(size_bytes: u64) usize {
    assert(size_bytes > 0);

    const progress_items_max_u64: u64 = std.math.maxInt(usize);
    if (size_bytes <= progress_items_max_u64) {
        return @intCast(size_bytes);
    } else {
        // Progress metadata is bounded by usize even when the file size is not.
        return std.math.maxInt(usize);
    }
}

fn verify_signature(
    ctx: *context.CliContext,
    file_name: []const u8,
    signature_file_name: []const u8,
) !void {
    assert(file_name.len > 0);
    assert(signature_file_name.len > 0);

    var store_path_buffer = try ctx.scratch(.path);
    defer store_path_buffer.release();
    const zvm_store_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");

    var tarball_path_buffer = try ctx.scratch(.path);
    defer tarball_path_buffer.release();
    const tarball_path = try tarball_path_buffer.set(
        try std.fmt.bufPrint(tarball_path_buffer.slice(), "{s}/{s}", .{
            zvm_store_path,
            file_name,
        }),
    );

    var sig_path_buffer = try ctx.scratch(.path);
    defer sig_path_buffer.release();
    const sig_path = try sig_path_buffer.set(
        try std.fmt.bufPrint(sig_path_buffer.slice(), "{s}/{s}", .{
            zvm_store_path,
            signature_file_name,
        }),
    );

    try minisign.verify_static_with_file(
        ctx,
        sig_path,
        metadata.ZIG_MINISIGN_PUBLIC_KEY,
        tarball_path,
        file_name,
    );
}

/// Extract the tarball into the staging tree. The final install path is
/// never written here; publish_release renames the staging tree into
/// place once it is complete.
fn extract_to_staging(
    ctx: *context.CliContext,
    staging_path: []const u8,
    tarball_file: std.Io.File,
    tarball_path: []const u8,
    is_zls: bool,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    assert(staging_path.len > 0);
    assert(tarball_path.len > 0);
    assert(items_done.* >= 0);

    const extract_node = root_node.start("extracting zig", 0);
    errdefer extract_node.end();
    try signals.check();

    // A stale tree can exist here if a previous process with the same id
    // was killed mid-extraction; start from an empty directory.
    if (util_tool.does_path_exist(ctx.io, staging_path)) {
        try std.Io.Dir.cwd().deleteTree(ctx.io, staging_path);
    }

    try util_tool.try_create_path(ctx.io, staging_path);
    var staging_dir = try std.Io.Dir.openDirAbsolute(ctx.io, staging_path, .{});
    defer staging_dir.close(ctx.io);

    var extract_op = try ctx.scratch(.extract);
    defer extract_op.release();

    const file_type: util_extract.ExtractFileType = if (builtin.os.tag == .windows)
        .zip
    else
        .tarxz;

    util_extract.extract_static(
        ctx.io,
        extract_op.operation(),
        staging_dir,
        tarball_file,
        file_type,
        is_zls,
        extract_node,
        tarball_path,
    ) catch |err| {
        log.err("Extraction failed with error: {s} for path: {s}", .{
            @errorName(err),
            staging_path,
        });

        try std.Io.Dir.cwd().deleteTree(ctx.io, staging_path);
        return err;
    };

    extract_node.end();
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);
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
    assert(platform_str.len <= limits.platform_string_length_maximum);
    return platform_str;
}

fn fetch_zls_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zls.VersionData {
    assert(platform_str.len > 0);
    assert(version.len > 0);

    const res = try http_client.HttpClient.fetch(ctx, metadata.zls_url, .{});
    assert(res.len > 0);

    const version_data = try meta.Zls.get_version_data(res, version, platform_str) orelse {
        log.err("Unsupported ZLS version '{s}' for platform '{s}'. Check available versions " ++
            "with 'zvm list-remote --zls'", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    assert(version_data.tarball().len > 0);
    assert(version_data.size > 0);

    return version_data;
}

/// Percent-encodes the unreserved subset needed for a Zig dev version pin
/// (`0.17.0-dev.261+3d1fb4fac`) when used as a URL query value. The literal
/// `+` would otherwise be decoded as a space by the server, so we encode it
/// as `%2B`. All RFC 3986 unreserved characters and the dev-pin separators
/// `.` and `-` are passed through; anything else is percent-encoded.
fn percent_encode_query_value(input: []const u8, output_buffer: []u8) ![]const u8 {
    assert(input.len > 0);
    assert(output_buffer.len >= input.len * 3);

    var write_index: usize = 0;
    for (input) |byte| {
        const passthrough = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (passthrough) {
            output_buffer[write_index] = byte;
            write_index += 1;
        } else {
            const hex_digits = "0123456789ABCDEF";
            output_buffer[write_index] = '%';
            output_buffer[write_index + 1] = hex_digits[(byte >> 4) & 0x0f];
            output_buffer[write_index + 2] = hex_digits[byte & 0x0f];
            write_index += 3;
        }
    }
    assert(write_index >= input.len);
    assert(write_index <= output_buffer.len);
    return output_buffer[0..write_index];
}

/// Translates the user-facing `master` alias into the concrete Zig dev
/// version currently published in `index.json`. Pinned dev pins are copied
/// through verbatim. The returned slice points into `output_buffer`.
fn resolve_master_zig_version(
    ctx: *context.CliContext,
    version: []const u8,
    output_buffer: *[limits.version_string_length_maximum]u8,
) ![]const u8 {
    assert(version.len > 0);
    assert(util_tool.is_master_like_version(version));

    if (util_tool.is_dev_version(version)) {
        assert(version.len <= output_buffer.len);
        @memcpy(output_buffer[0..version.len], version);
        return output_buffer[0..version.len];
    }

    assert(util_tool.eql_str(version, "master"));
    const res = try http_client.HttpClient.fetch(ctx, metadata.zig_url, .{});
    assert(res.len > 0);

    const resolved = try meta.Zig.get_master_version_string(res, output_buffer[0..]) orelse {
        log.err("Zig index.json has no `master` entry; cannot resolve ZLS master build.", .{});
        return error.UnsupportedVersion;
    };
    if (!util_tool.is_dev_version(resolved)) {
        log.err("Zig master entry version '{s}' is not a dev pin.", .{resolved});
        return error.UnsupportedVersion;
    }
    return resolved;
}

/// Fetches and parses the ZLS `select-version` payload for a master/dev
/// install. The endpoint requires a concrete Zig dev version as the
/// `zig_version` query parameter (the literal `master` is rejected with HTTP
/// 400), so the literal `master` alias is first resolved against Zig's
/// `index.json` to its current dev pin. Pinned dev versions are passed
/// through unchanged.
fn fetch_zls_master_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zls.MasterVersionData {
    assert(platform_str.len > 0);
    assert(version.len > 0);
    assert(util_tool.is_master_like_version(version));

    var resolved_buffer: [limits.version_string_length_maximum]u8 = undefined;
    const resolved_zig_version = try resolve_master_zig_version(ctx, version, &resolved_buffer);
    assert(resolved_zig_version.len > 0);
    assert(util_tool.is_dev_version(resolved_zig_version));

    var encoded_version_buffer: [limits.version_string_length_maximum * 3]u8 = undefined;
    const encoded_zig_version = try percent_encode_query_value(
        resolved_zig_version,
        encoded_version_buffer[0..],
    );

    var url_buffer = try ctx.scratch(.path);
    defer url_buffer.release();
    const url = try url_buffer.set(try std.fmt.bufPrint(
        url_buffer.slice(),
        "{s}?zig_version={s}&compatibility=only-runtime",
        .{ metadata.zls_select_version_url_base, encoded_zig_version },
    ));
    assert(url.len > 0);
    assert(url.len <= limits.url_length_maximum);

    const uri = std.Uri.parse(url) catch |err| {
        log.err("Invalid ZLS select-version URL '{s}': {s}", .{ url, @errorName(err) });
        return error.InvalidMetadataUrl;
    };

    const res = try http_client.HttpClient.fetch(ctx, uri, .{});
    assert(res.len > 0);

    const version_data = try meta.Zls.get_master_version_data(res, platform_str) orelse {
        log.err("Unsupported ZLS master build for Zig '{s}' on platform '{s}'. The ZLS " ++
            "select-version endpoint did not return an entry for this combination.", .{
            version,
            platform_str,
        });
        return error.UnsupportedVersion;
    };

    assert(version_data.version().len > 0);
    assert(version_data.tarball().len > 0);
    assert(version_data.size > 0);

    return version_data;
}
