const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const util_data = @import("../util/data.zig");
const util_extract = @import("../io/extract.zig");
const http_client = @import("../io/http_client.zig");
const core_install = @import("install.zig");
const limits = @import("../memory/limits.zig");
const options = @import("options");
const assert = std.debug.assert;

const log = std.log.scoped(.upgrade);

const release_repo_path = "hendriknielaender/zvm";
const release_api_url = "https://api.github.com/repos/" ++ release_repo_path ++ "/releases/latest";
const release_download_root = "https://github.com/" ++ release_repo_path ++ "/releases/download";
const upgrade_user_agent = "zvm-upgrade";

const tag_max_length: usize = 64;

comptime {
    assert(release_api_url.len < limits.limits.url_length_maximum);
    assert(release_download_root.len < limits.limits.url_length_maximum);
    assert(tag_max_length <= limits.limits.version_string_length_maximum);
}

pub fn upgrade(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.UpgradeCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = command;

    var tag_storage: [tag_max_length]u8 = undefined;
    const latest_tag = try fetch_latest_tag(ctx, &tag_storage, progress_node);

    if (!is_upgrade_needed(latest_tag, options.version)) {
        util_output.success(
            "zvm is already at the latest version (current: {s}, latest tag: {s}).",
            .{ options.version, latest_tag },
        );
        return;
    }

    util_output.info(
        "Upgrading zvm from {s} to {s}...",
        .{ options.version, latest_tag },
    );

    var platform_pool_buffer = try ctx.acquire_path_buffer();
    defer platform_pool_buffer.reset();
    const platform_str = try core_install.get_platform_string_into_buffer(false, platform_pool_buffer);

    var self_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const self_len = try std.process.executablePath(ctx.io, &self_storage);
    const self_path = self_storage[0..self_len];
    assert(self_path.len > 0);

    var archive_name_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const archive_name = try build_archive_name(&archive_name_storage, latest_tag, platform_str);
    const archive_uri = try build_archive_uri(latest_tag, platform_str);

    // download_file_with_verification owns the node lifetime — it ends the node on every
    // exit path (see core/install.zig). Do not add a defer here or the node ends twice.
    const download_node = progress_node.start("downloading zvm release", 0);
    const archive_file = try core_install.download_file_with_verification(
        ctx,
        archive_uri,
        archive_name,
        null,
        null,
        download_node,
    );
    defer archive_file.close(ctx.io);

    var extract_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const extract_path = try extract_release_archive(
        ctx,
        latest_tag,
        archive_file,
        archive_name,
        &extract_path_storage,
        progress_node,
    );

    var binary_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const new_binary_path = try build_extracted_binary_path(
        &binary_path_storage,
        extract_path,
        platform_str,
    );

    try replace_self_binary(ctx, self_path, new_binary_path);

    util_output.success("Upgraded zvm to {s}.", .{latest_tag});
}

/// Strip an optional `v`/`V` prefix that GitHub release tags conventionally carry.
fn strip_release_tag_prefix(tag: []const u8) []const u8 {
    assert(tag.len > 0);

    if (tag[0] == 'v' or tag[0] == 'V') return tag[1..];
    return tag;
}

/// Returns true only when the released tag is strictly newer than the current
/// build. Equal versions and older tags both refuse to upgrade — we never want
/// to silently downgrade a user who is on a dev build with a release-style
/// `options.version` string. Falls back to a refusal when either side fails to
/// parse, since downgrading a binary on bad input is unsafe.
fn is_upgrade_needed(tag: []const u8, current_version: []const u8) bool {
    assert(tag.len > 0);
    assert(current_version.len > 0);

    const tag_core = strip_release_tag_prefix(tag);
    if (tag_core.len == 0) return false;

    const tag_semver = std.SemanticVersion.parse(tag_core) catch return false;
    const current_semver = std.SemanticVersion.parse(current_version) catch return false;

    return tag_semver.order(current_semver) == .gt;
}

fn fetch_latest_tag(
    ctx: *context.CliContext,
    tag_buffer: *[tag_max_length]u8,
    progress_node: std.Progress.Node,
) ![]const u8 {
    const fetch_node = progress_node.start("fetching latest zvm release", 0);
    defer fetch_node.end();

    const api_uri = try std.Uri.parse(release_api_url);
    const headers = std.http.Client.Request.Headers{
        .user_agent = .{ .override = upgrade_user_agent },
    };
    const response = try http_client.HttpClient.fetch(ctx, api_uri, headers);
    assert(response.len > 0);

    return parse_release_tag(response, tag_buffer) orelse {
        log.err("Could not find tag_name in GitHub release response", .{});
        return error.MissingReleaseTag;
    };
}

fn parse_release_tag(content: []const u8, tag_buffer: *[tag_max_length]u8) ?[]const u8 {
    assert(content.len > 0);

    const key = "\"tag_name\"";
    const key_index = std.mem.indexOf(u8, content, key) orelse return null;

    var cursor = key_index + key.len;
    while (cursor < content.len and content[cursor] != ':') : (cursor += 1) {}
    if (cursor >= content.len) return null;
    cursor += 1;

    while (cursor < content.len and std.ascii.isWhitespace(content[cursor])) : (cursor += 1) {}
    if (cursor >= content.len or content[cursor] != '"') return null;
    cursor += 1;

    const value_start = cursor;
    while (cursor < content.len and content[cursor] != '"') : (cursor += 1) {}
    if (cursor >= content.len) return null;

    const value = content[value_start..cursor];
    if (value.len == 0 or value.len > tag_buffer.len) return null;

    @memcpy(tag_buffer[0..value.len], value);
    return tag_buffer[0..value.len];
}

fn release_archive_extension() []const u8 {
    return if (builtin.os.tag == .windows) "zip" else "tar.gz";
}

fn binary_basename_suffix() []const u8 {
    return if (builtin.os.tag == .windows) "-zvm.exe" else "-zvm";
}

fn build_archive_name(
    storage: *[limits.limits.path_length_maximum]u8,
    tag: []const u8,
    platform_str: []const u8,
) ![]const u8 {
    return try std.fmt.bufPrint(storage, "zvm-{s}-{s}.{s}", .{
        tag,
        platform_str,
        release_archive_extension(),
    });
}

fn build_archive_uri(tag: []const u8, platform_str: []const u8) !std.Uri {
    var url_buffer: [limits.limits.url_length_maximum]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/{s}/{s}-zvm.{s}", .{
        release_download_root,
        tag,
        platform_str,
        release_archive_extension(),
    });
    return try std.Uri.parse(url);
}

fn extract_release_archive(
    ctx: *context.CliContext,
    tag: []const u8,
    archive_file: std.Io.File,
    archive_name: []const u8,
    storage: *[limits.limits.path_length_maximum]u8,
    progress_node: std.Progress.Node,
) ![]const u8 {
    assert(tag.len > 0);

    var store_buffer = try ctx.acquire_path_buffer();
    defer store_buffer.reset();
    const store_path = try util_data.get_zvm_path_segment(store_buffer, "store");

    const extract_path = try std.fmt.bufPrint(storage, "{s}/zvm-upgrade-{s}", .{ store_path, tag });

    try std.Io.Dir.cwd().deleteTree(ctx.io, extract_path);
    try util_tool.try_create_path(ctx.io, extract_path);

    var extract_dir = try std.Io.Dir.openDirAbsolute(ctx.io, extract_path, .{});
    defer extract_dir.close(ctx.io);

    var archive_path_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_path_storage, "{s}/{s}", .{ store_path, archive_name });

    var extract_op = try ctx.acquire_extract_operation();
    defer extract_op.release();

    const extract_node = progress_node.start("extracting zvm release", 0);
    defer extract_node.end();

    const file_type: util_extract.ExtractFileType =
        if (builtin.os.tag == .windows) .zip else .tar_gz;
    // The release tarball is a flat archive with the binary at the root, so we pass
    // `is_zls=true` to keep `strip_components=0`. The name is a misnomer here; the flag
    // selects the strip behavior, not the tool.
    try util_extract.extract_static(
        ctx.io,
        extract_op,
        extract_dir,
        archive_file,
        file_type,
        true,
        extract_node,
        archive_path,
    );

    return extract_path;
}

fn build_extracted_binary_path(
    storage: *[limits.limits.path_length_maximum]u8,
    extract_path: []const u8,
    platform_str: []const u8,
) ![]const u8 {
    return try std.fmt.bufPrint(storage, "{s}/{s}{s}", .{
        extract_path,
        platform_str,
        binary_basename_suffix(),
    });
}

fn replace_self_binary(
    ctx: *context.CliContext,
    self_path: []const u8,
    new_binary_path: []const u8,
) !void {
    assert(self_path.len > 0);
    assert(new_binary_path.len > 0);

    if (builtin.os.tag != .windows) {
        try set_executable_bit(ctx, new_binary_path);
        try std.Io.Dir.renameAbsolute(new_binary_path, self_path, ctx.io);
        return;
    }

    try replace_self_binary_windows(ctx, self_path, new_binary_path);
}

/// Windows cannot rename over a running executable, so we swap in two steps:
/// move the running binary aside as `<self>.old`, then move the new binary into
/// place. If the second rename fails we roll the original back so the user is
/// never left without a working `zvm`.
fn replace_self_binary_windows(
    ctx: *context.CliContext,
    self_path: []const u8,
    new_binary_path: []const u8,
) !void {
    assert(self_path.len > 0);
    assert(new_binary_path.len > 0);
    assert(builtin.os.tag == .windows);

    var backup_storage: [limits.limits.path_length_maximum]u8 = undefined;
    const backup_path = try std.fmt.bufPrint(&backup_storage, "{s}.old", .{self_path});
    assert(backup_path.len > self_path.len);

    std.Io.Dir.deleteFileAbsolute(ctx.io, backup_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn(
            "Could not remove stale backup at {s}: {s}",
            .{ backup_path, @errorName(err) },
        ),
    };

    try std.Io.Dir.renameAbsolute(self_path, backup_path, ctx.io);

    std.Io.Dir.renameAbsolute(new_binary_path, self_path, ctx.io) catch |err| {
        std.Io.Dir.renameAbsolute(backup_path, self_path, ctx.io) catch |restore_err| {
            log.err(
                "Upgrade failed and rollback also failed. Original at {s}, new at {s}. Recover manually. Errors: {s} / {s}",
                .{ backup_path, new_binary_path, @errorName(err), @errorName(restore_err) },
            );
            return restore_err;
        };
        log.err("Upgrade failed; rolled back to previous binary: {s}", .{@errorName(err)});
        return err;
    };
}

fn set_executable_bit(ctx: *context.CliContext, path: []const u8) !void {
    assert(path.len > 0);

    const file = try std.Io.Dir.openFileAbsolute(ctx.io, path, .{ .mode = .read_only });
    defer file.close(ctx.io);
    try file.setPermissions(ctx.io, std.Io.File.Permissions.executable_file);
}

test "is_upgrade_needed only fires on a strictly newer release tag" {
    try std.testing.expect(is_upgrade_needed("v0.20.0", "0.19.0"));
    try std.testing.expect(is_upgrade_needed("0.19.1", "0.19.0"));
    try std.testing.expect(!is_upgrade_needed("v0.19.0", "0.19.0"));
    try std.testing.expect(!is_upgrade_needed("v0.18.0", "0.19.0"));
    try std.testing.expect(!is_upgrade_needed("v0.19.0-rc1", "0.19.0"));
}

test "is_upgrade_needed refuses to upgrade on unparsable input" {
    try std.testing.expect(!is_upgrade_needed("v", "0.19.0"));
    try std.testing.expect(!is_upgrade_needed("not-a-version", "0.19.0"));
    try std.testing.expect(!is_upgrade_needed("v0.19.0", "garbage"));
}

test "strip_release_tag_prefix removes a single leading v" {
    try std.testing.expectEqualStrings("0.19.0", strip_release_tag_prefix("v0.19.0"));
    try std.testing.expectEqualStrings("0.19.0", strip_release_tag_prefix("V0.19.0"));
    try std.testing.expectEqualStrings("0.19.0", strip_release_tag_prefix("0.19.0"));
}

test "parse_release_tag extracts the tag_name field" {
    const sample =
        \\{"name":"zvm 0.19.0","tag_name":"v0.19.0","draft":false}
    ;
    var buffer: [tag_max_length]u8 = undefined;
    const tag = parse_release_tag(sample, &buffer) orelse return error.MissingTag;
    try std.testing.expectEqualStrings("v0.19.0", tag);
}

test "parse_release_tag returns null when key is absent" {
    const sample = "{\"name\":\"no tag here\"}";
    var buffer: [tag_max_length]u8 = undefined;
    try std.testing.expect(parse_release_tag(sample, &buffer) == null);
}

test "parse_release_tag picks the value tied to the literal tag_name key" {
    // A body field that contains the literal string `"tag_name"` must not
    // shadow the real key. The parser walks linearly, so the first match wins;
    // ensure that match is the actual key, not a substring inside another
    // value preceding it.
    const sample =
        \\{"body":"see the tag_name field","tag_name":"v0.19.0"}
    ;
    var buffer: [tag_max_length]u8 = undefined;
    const tag = parse_release_tag(sample, &buffer) orelse return error.MissingTag;
    try std.testing.expectEqualStrings("v0.19.0", tag);
}
