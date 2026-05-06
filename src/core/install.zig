const std = @import("std");
const builtin = @import("builtin");
const config = @import("../metadata.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const util_arch = @import("../util/arch.zig");
const util_data = @import("../util/data.zig");
const util_output = @import("../util/output.zig");
const util_extract = @import("../io/extract.zig");
const util_tool = @import("../util/tool.zig");
const http_client = @import("../io/http_client.zig");
const util_minimumisign = @import("../io/minisign.zig");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");
const signals = @import("../platform/signals.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.install);
const Progress = std.Progress;
const cleanup_timeout_seconds: u32 = 10;
const release_download_urls_max = config.zig_mirrors.len + 1;

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
    version_buffer: [limits.limits.version_string_length_maximum]u8,
    version_len: u32,
    download_urls_buffer: [release_download_urls_max][limits.limits.url_length_maximum]u8,
    download_urls_len: [release_download_urls_max]u32,
    download_urls_count: u32,
    hash: ?[64]u8,
    size: u64,
    signature_url_buffer: [limits.limits.url_length_maximum]u8,
    signature_url_len: u32,
    extract_path_buffer: [limits.limits.path_length_maximum]u8,
    extract_path_len: u32,

    fn init(self: *Release, kind: ReleaseKind) void {
        self.* = .{
            .kind = kind,
            .version_buffer = undefined,
            .version_len = 0,
            .download_urls_buffer = undefined,
            .download_urls_len = std.mem.zeroes([release_download_urls_max]u32),
            .download_urls_count = 0,
            .hash = null,
            .size = 0,
            .signature_url_buffer = undefined,
            .signature_url_len = 0,
            .extract_path_buffer = undefined,
            .extract_path_len = 0,
        };
    }

    fn version(self: *const Release) []const u8 {
        assert(self.version_len > 0);
        return self.version_buffer[0..self.version_len];
    }

    fn download_url(self: *const Release, index: u32) []const u8 {
        assert(index < self.download_urls_count);
        const index_usize: usize = @intCast(index);
        return self.download_urls_buffer[index_usize][0..self.download_urls_len[index_usize]];
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

        var path_buffer = try ctx.scratch_path();
        defer path_buffer.release();
        const install_path = try path_buffer.set(
            try std.fmt.bufPrint(path_buffer.slice(), "{s}/{s}", .{ version_root, version_text }),
        );
        try self.set_extract_path(install_path);
    }

    fn add_download_url(self: *Release, url: []const u8) !void {
        assert(url.len > 0);
        assert(url.len <= limits.limits.url_length_maximum);
        assert(self.download_urls_count < release_download_urls_max);

        const index: usize = @intCast(self.download_urls_count);
        @memcpy(self.download_urls_buffer[index][0..url.len], url);
        self.download_urls_len[index] = @intCast(url.len);
        self.download_urls_count += 1;
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
    var store_path_buffer = try ctx.scratch_path();
    defer store_path_buffer.release();
    const zvm_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");
    var store = try std.Io.Dir.cwd().createDirPathOpen(ctx.io, zvm_path, .{});
    defer store.close(ctx.io);

    if (util_tool.does_path_exist2(ctx.io, store, file_name)) {
        if (shasum) |expected_hash| {
            const file = try store.openFile(ctx.io, file_name, .{});
            defer file.close(ctx.io);

            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [limits.limits.temp_buffer_size]u8 = undefined;
            var reader_buffer: [limits.limits.io_buffer_size_maximum]u8 = undefined;
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
        var reader_buffer: [limits.limits.io_buffer_size_maximum]u8 = undefined;
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
    assert(version.len < 100); // Reasonable version length

    var release: Release = undefined;
    if (is_zls) {
        try resolve_zls_release(ctx, &release, version);
    } else {
        try resolve_zig_release(ctx, &release, version);
    }
    try install_release(ctx, &release, root_node);
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
    assert(version.len < 100);

    const is_master = util_tool.is_master_like_version(version);

    var platform_buffer = try ctx.scratch_path();
    defer platform_buffer.release();
    const platform_str = try get_platform_string_into_buffer(is_master, platform_buffer);
    const version_data = try fetch_version_data(ctx, platform_str, version);

    var version_root_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const version_root = try resolve_zig_version_root(ctx, &version_root_storage);

    release.init(.zig);
    try release.set_version(version_data.version());
    try release.set_extract_path_from_parts(ctx, version_root, release.version());
    release.hash = version_data.shasum;
    release.size = version_data.size;
    try resolve_zig_download_urls(ctx, release, version_data.tarball());

    var signature_url_buffer: [limits.limits.url_length_maximum]u8 = undefined;
    const signature_url = try std.fmt.bufPrint(&signature_url_buffer, "{s}.minisig", .{
        version_data.tarball(),
    });
    try release.set_signature_url(signature_url);

    assert(release.download_urls_count > 0);
    assert(release.signature_url() != null);
}

fn resolve_zls_release(
    ctx: *context.CliContext,
    release: *Release,
    version: []const u8,
) !void {
    assert(version.len > 0);
    assert(version.len < 100);

    var platform_str_buffer: [100]u8 = undefined;
    const platform_str_temp = try get_zls_platform_string(ctx);
    if (platform_str_temp.len <= platform_str_buffer.len) {
        @memcpy(platform_str_buffer[0..platform_str_temp.len], platform_str_temp);
    } else {
        return error.PlatformStringTooLong;
    }
    const platform_str = platform_str_buffer[0..platform_str_temp.len];

    const version_data = try fetch_zls_version_data(ctx, platform_str, version);

    var version_path_buffer = try ctx.scratch_path();
    defer version_path_buffer.release();
    const version_root = try util_data.get_zvm_zls_version(version_path_buffer);

    release.init(.zls);
    try release.set_version(version_data.version());
    try release.set_extract_path_from_parts(ctx, version_root, release.version());
    release.hash = null;
    release.size = version_data.size;
    try release.add_download_url(version_data.tarball());

    assert(release.download_urls_count == 1);
    assert(release.signature_url() == null);
}

fn install_release(
    ctx: *context.CliContext,
    release: *const Release,
    root_node: Progress.Node,
) !void {
    assert(release.version().len > 0);
    assert(release.download_urls_count > 0);
    assert(release.size > 0);
    assert(release.extract_path().len > 0);

    const extract_path = release.extract_path();
    if (util_tool.does_path_exist(ctx.io, extract_path)) {
        try alias.set_version(ctx, release.version(), release.is_zls());
        return;
    }

    errdefer |err| if (err == error.Interrupted) {
        cleanup_interrupted_install(ctx, extract_path);
    };

    var progress = InstallProgress.init(root_node);
    try signals.check();
    const tarball_file = try acquire_release(
        ctx,
        release,
        download_file_with_verification,
        &progress,
    );
    defer tarball_file.close(ctx.io);

    if (release.signature_url()) |signature_url| {
        try verify_release_signature(ctx, release, signature_url, &progress);
    }

    try stage_release(ctx, release, tarball_file, &progress);
    try signals.check();
    try util_data.write_version_manifest(extract_path, release.version());

    try alias.set_version(ctx, release.version(), release.is_zls());
}

fn resolve_zig_download_urls(
    ctx: *context.CliContext,
    release: *Release,
    official_url: []const u8,
) !void {
    assert(official_url.len > 0);
    assert(release.download_urls_count == 0);

    const file_name = std.fs.path.basename(official_url);
    assert(file_name.len > 0);
    assert(file_name.len <= official_url.len);

    if (config.preferred_mirror) |mirror_index| {
        if (mirror_index < config.zig_mirrors.len) {
            try release_add_mirror_url(ctx, release, mirror_index, file_name);
        } else {
            log.warn("Specified mirror index {d} is out of range (0-{d})", .{
                mirror_index,
                config.zig_mirrors.len - 1,
            });
        }
    }

    try release.add_download_url(official_url);

    for (config.zig_mirrors, 0..) |_, mirror_index| {
        if (config.preferred_mirror) |preferred_mirror| {
            if (mirror_index == preferred_mirror) continue;
        }
        try release_add_mirror_url(ctx, release, mirror_index, file_name);
    }
}

fn release_add_mirror_url(
    ctx: *context.CliContext,
    release: *Release,
    mirror_index: usize,
    file_name: []const u8,
) !void {
    assert(mirror_index < config.zig_mirrors.len);
    assert(file_name.len > 0);

    var mirror_uri_buffer = try ctx.scratch_path();
    defer mirror_uri_buffer.release();
    const mirror_url = config.zig_mirrors[mirror_index][0];
    const mirror_uri = try construct_mirror_url(mirror_uri_buffer, mirror_url, file_name);
    try release.add_download_url(mirror_uri);
}

fn acquire_release(
    ctx: *context.CliContext,
    release: *const Release,
    download_file: DownloadFile,
    progress: *InstallProgress,
) !std.Io.File {
    assert(release.download_urls_count > 0);
    assert(release.size > 0);

    const file_name = std.fs.path.basename(release.download_url(0));
    assert(file_name.len > 0);

    var index: u32 = 0;
    while (index < release.download_urls_count) : (index += 1) {
        const download_url = release.download_url(index);
        const uri = std.Uri.parse(download_url) catch |err| {
            log.warn("Invalid download URL {s}: {s}", .{ download_url, @errorName(err) });
            continue;
        };

        var node_name_buffer = try ctx.scratch_path();
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
        return file;
    }

    log.err("All download attempts failed for {s}", .{release.version()});
    return error.AllDownloadsFailed;
}

fn verify_release_signature(
    ctx: *context.CliContext,
    release: *const Release,
    signature_url: []const u8,
    progress: *InstallProgress,
) !void {
    assert(release.kind == .zig);
    assert(signature_url.len > 0);

    const tarball_url = release.download_url(0);
    const tarball_name = std.fs.path.basename(tarball_url);
    assert(tarball_name.len > 0);

    var sig_name_buffer = try ctx.scratch_path();
    defer sig_name_buffer.release();
    const signature_file_name = try sig_name_buffer.print("{s}.minisig", .{tarball_name});

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
    assert(release.extract_path().len > 0);

    var tarball_path_buffer = try ctx.scratch_path();
    defer tarball_path_buffer.release();
    const zvm_store_path = try util_data.get_zvm_path_segment(tarball_path_buffer, "store");
    const tarball_file_name = std.fs.path.basename(release.download_url(0));
    var tarball_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const tarball_path = try std.fmt.bufPrint(&tarball_path_storage, "{s}/{s}", .{
        zvm_store_path,
        tarball_file_name,
    });

    try extract_and_install(
        ctx,
        release.extract_path(),
        tarball_file,
        tarball_path,
        release.is_zls(),
        &progress.items_done,
        progress.root_node,
    );
}

fn resolve_zig_version_root(
    ctx: *context.CliContext,
    storage: *[limits.limits.path_length_maximum]u8,
) ![]const u8 {
    assert(storage.len > 0);

    var path_buffer = try ctx.scratch_path();
    defer path_buffer.release();
    const path = try util_data.get_zvm_zig_version(path_buffer);
    assert(path.len > 0);
    assert(path.len <= storage.len);
    @memcpy(storage[0..path.len], path);
    return storage[0..path.len];
}

fn cleanup_interrupted_install(ctx: *context.CliContext, extract_path: []const u8) void {
    assert(extract_path.len > 0);

    signals.begin_cleanup();
    defer signals.end_cleanup();

    var stderr_buffer: [128]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(ctx.io, &stderr_buffer);
    stderr_writer.interface.writeAll("\ninterrupted, cleaning up...\n") catch {};
    stderr_writer.interface.flush() catch {};

    cleanup_delete_tree_with_timeout(ctx, extract_path) catch |err| {
        log.warn("Interrupted cleanup failed for {s}: {s}", .{ extract_path, @errorName(err) });
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
            const outcome = select.await() catch |await_err| switch (await_err) {
                error.Canceled => return error.Canceled,
            };
            return switch (outcome) {
                .completed => |result| result,
                .timed_out => unreachable,
            };
        },
    };

    const winner = select.await() catch |err| switch (err) {
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
    assert(platform_str.len < 100);

    return platform_str;
}

fn fetch_version_data(
    ctx: *context.CliContext,
    platform_str: []const u8,
    version: []const u8,
) !meta.Zig.VersionData {
    assert(version.len > 0);
    assert(platform_str.len > 0);

    const res = try http_client.HttpClient.fetch(ctx, config.zig_url, .{});

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

    var store_path_buffer = try ctx.scratch_path();
    defer store_path_buffer.release();
    const zvm_store_path = try util_data.get_zvm_path_segment(store_path_buffer, "store");

    var tarball_path_buffer = try ctx.scratch_path();
    defer tarball_path_buffer.release();
    const tarball_path = try tarball_path_buffer.set(
        try std.fmt.bufPrint(tarball_path_buffer.slice(), "{s}/{s}", .{
            zvm_store_path,
            file_name,
        }),
    );

    var sig_path_buffer = try ctx.scratch_path();
    defer sig_path_buffer.release();
    const sig_path = try sig_path_buffer.set(
        try std.fmt.bufPrint(sig_path_buffer.slice(), "{s}/{s}", .{
            zvm_store_path,
            signature_file_name,
        }),
    );

    util_minimumisign.verify_static(
        ctx,
        sig_path,
        config.ZIG_MINISIGN_PUBLIC_KEY,
        tarball_path,
    ) catch |err| {
        util_output.fatal(.corruption_detected, "Failed to verify Zig signature: {s}", .{
            @errorName(err),
        });
    };
}

fn extract_and_install(
    ctx: *context.CliContext,
    extract_path: []const u8,
    tarball_file: std.Io.File,
    tarball_path: []const u8,
    is_zls: bool,
    items_done: *u32,
    root_node: Progress.Node,
) !void {
    assert(extract_path.len > 0);
    assert(tarball_path.len > 0);
    assert(items_done.* >= 0);

    const extract_node = root_node.start("extracting zig", 0);
    errdefer extract_node.end();
    try signals.check();

    if (util_tool.does_path_exist(ctx.io, extract_path)) {
        try std.Io.Dir.cwd().deleteTree(ctx.io, extract_path);
    }

    try util_tool.try_create_path(ctx.io, extract_path);
    var extract_dir = try std.Io.Dir.openDirAbsolute(ctx.io, extract_path, .{});
    defer extract_dir.close(ctx.io);

    var extract_op = try ctx.scratch_extract();
    defer extract_op.release();

    const file_type: util_extract.ExtractFileType = if (builtin.os.tag == .windows)
        .zip
    else
        .tarxz;

    util_extract.extract_static(
        ctx.io,
        extract_op.operation,
        extract_dir,
        tarball_file,
        file_type,
        is_zls,
        extract_node,
        tarball_path,
    ) catch |err| {
        log.err("Extraction failed with error: {s} for path: {s}", .{
            @errorName(err),
            extract_path,
        });

        try std.Io.Dir.cwd().deleteTree(ctx.io, extract_path);
        return err;
    };

    extract_node.end();
    items_done.* += 1;
    root_node.setCompletedItems(items_done.*);
}

fn construct_mirror_url(
    buffer: anytype,
    mirror_url: []const u8,
    file_name: []const u8,
) ![]const u8 {
    assert(mirror_url.len > 0);
    assert(mirror_url.len < limits.limits.url_length_maximum / 2);
    assert(file_name.len > 0);
    assert(file_name.len < limits.limits.path_length_maximum);

    const uri_str = try buffer.set(
        if (mirror_url[mirror_url.len - 1] == '/')
            try std.fmt.bufPrint(buffer.slice(), "{s}{s}", .{ mirror_url, file_name })
        else
            try std.fmt.bufPrint(buffer.slice(), "{s}/{s}", .{ mirror_url, file_name }),
    );

    assert(uri_str.len > 0);
    assert(uri_str.len <= limits.limits.url_length_maximum);

    return uri_str;
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
