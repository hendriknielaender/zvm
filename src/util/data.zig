const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../memory/limits.zig");
const object_pools = @import("../memory.zig");
const paths = @import("../platform/paths.zig");
const assert = std.debug.assert;

pub const version_manifest_name = ".zvm-version";

/// State of an install directory, derived from its completion record.
pub const InstallState = enum {
    /// No directory at the install path.
    missing,
    /// Manifest present with matching content: the install was published
    /// completely.
    installed,
    /// No manifest, but the tool binary exists: the install predates the
    /// manifest era (zvm < 1.0). Callers may backfill the manifest.
    installed_legacy,
    /// Directory without manifest or tool binary: leftover of an
    /// interrupted extraction. Never valid to use; safe to delete.
    torn,
};

/// Classify the install directory at `install_path` for `version`.
/// The `.zvm-version` manifest is the completion record: it is written
/// into the staging tree immediately before the atomic publish rename,
/// so a directory carrying a matching manifest is a complete install.
pub fn classify_install(
    io: std.Io,
    install_path: []const u8,
    version: []const u8,
    is_zls: bool,
) !InstallState {
    assert(install_path.len > 0);
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    std.Io.Dir.accessAbsolute(io, install_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };

    // SAFETY: PathBuffer.data is initialized by build_manifest_path before use.
    var manifest_path_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    // Twice the version length: enough slack to detect oversized garbage
    // (a truncated read then fails the content comparison below).
    var manifest_content_buffer: [limits.version_string_length_maximum * 2]u8 = undefined;
    const manifest_version = read_version_manifest_absolute(
        io,
        &manifest_path_buffer,
        install_path,
        &manifest_content_buffer,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (tool_binary_exists(io, install_path, is_zls)) return .installed_legacy;
            return .torn;
        },
        // An empty manifest is an interrupted manifest write.
        error.EmptyVersion => return .torn,
        else => return err,
    };

    if (!std.mem.eql(u8, manifest_version, version)) return .torn;
    return .installed;
}

/// Whether the tool binary sits at the top of the install directory, where
/// every zvm-extracted archive places it. Only consulted for directories
/// without a manifest, to tell legacy installs apart from torn ones.
fn tool_binary_exists(io: std.Io, install_path: []const u8, is_zls: bool) bool {
    assert(install_path.len > 0);

    const binary_name = switch (builtin.os.tag) {
        .windows => if (is_zls) "zls.exe" else "zig.exe",
        else => if (is_zls) "zls" else "zig",
    };

    var binary_path_buffer: [limits.path_length_maximum]u8 = undefined;
    const binary_path = std.fmt.bufPrint(
        &binary_path_buffer,
        "{s}/{s}",
        .{ install_path, binary_name },
    ) catch return false;

    std.Io.Dir.accessAbsolute(io, binary_path, .{}) catch return false;
    return true;
}

/// Resolve the ZVM root directory into a stack buffer.
/// This is a private helper used by all path-builder functions
/// to avoid duplicating home and root resolution.
fn resolve_zvm_root(out_buffer: []u8) ![]const u8 {
    assert(out_buffer.len > 0);

    var home_buf: [limits.home_dir_length_maximum]u8 = undefined;
    const home = try paths.get_home_path(&home_buf);
    return try paths.get_zvm_root(out_buffer, home);
}

/// Get ZVM path segment relative to the ZVM root.
pub fn get_zvm_path_segment(buffer: anytype, segment: []const u8) ![]const u8 {
    assert(segment.len > 0);

    var zvm_root_buf: [limits.path_length_maximum]u8 = undefined;
    const zvm_root = try resolve_zvm_root(&zvm_root_buf);
    const result = try std.fmt.bufPrint(buffer.slice(), "{s}/{s}", .{ zvm_root, segment });
    return try buffer.set(result);
}

/// Get the ZVM current/zig directory path.
pub fn get_zvm_current_zig(buffer: anytype) ![]const u8 {
    return get_zvm_path_segment(buffer, "current/zig");
}

/// Get the ZVM current/zls directory path.
pub fn get_zvm_current_zls(buffer: anytype) ![]const u8 {
    return get_zvm_path_segment(buffer, "current/zls");
}

/// Get the ZVM store directory path.
pub fn get_zvm_store(buffer: anytype) ![]const u8 {
    return get_zvm_path_segment(buffer, "store");
}

/// Get the ZVM version/zig directory path.
pub fn get_zvm_zig_version(buffer: anytype) ![]const u8 {
    return get_zvm_path_segment(buffer, "version/zig");
}

/// Get the ZVM version/zls directory path.
pub fn get_zvm_zls_version(buffer: anytype) ![]const u8 {
    return get_zvm_path_segment(buffer, "version/zls");
}

pub fn write_version_manifest(io: std.Io, install_path: []const u8, version: []const u8) !void {
    assert(install_path.len > 0);
    assert(version.len > 0);
    assert(version.len <= limits.version_string_length_maximum);

    var manifest_path_buffer: [limits.path_length_maximum]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}/{s}",
        .{ install_path, version_manifest_name },
    );

    const manifest_file = try std.Io.Dir.cwd().createFile(io, manifest_path, .{});
    defer manifest_file.close(io);

    try manifest_file.writeStreamingAll(io, version);
    // The manifest is the completion record consulted by classify_install;
    // make it durable before the caller publishes the directory via rename,
    // so a power loss cannot publish a directory with an unwritten record.
    try manifest_file.sync(io);
}

fn build_manifest_path(
    path_buffer: anytype,
    install_path: []const u8,
) ![]const u8 {
    assert(install_path.len > 0);

    var manifest_path_storage: [limits.path_length_maximum]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_storage,
        "{s}/{s}",
        .{ install_path, version_manifest_name },
    );
    return try path_buffer.set(manifest_path);
}

pub fn read_version_manifest_absolute(
    io: std.Io,
    path_buffer: anytype,
    install_path: []const u8,
    output_buffer: []u8,
) ![]const u8 {
    assert(output_buffer.len > 0);

    const manifest_path = try build_manifest_path(path_buffer, install_path);
    const manifest_file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{ .mode = .read_only });
    defer manifest_file.close(io);

    var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
    var manifest_reader = manifest_file.reader(io, &reader_buffer);
    const bytes_read = try manifest_reader.interface.readSliceShort(output_buffer);
    if (bytes_read == 0) return error.EmptyVersion;

    const version = std.mem.trim(u8, output_buffer[0..bytes_read], " \t\r\n");
    if (version.len == 0) return error.EmptyVersion;
    return version;
}

/// Get the version from the manifest within the active installation.
pub fn get_current_version(
    io: std.Io,
    path_buffer: anytype,
    output_buffer: []u8,
    is_zls: bool,
) ![]const u8 {
    const base_path = if (is_zls)
        try get_zvm_current_zls(path_buffer)
    else
        try get_zvm_current_zig(path_buffer);

    return try read_version_manifest_absolute(io, path_buffer, base_path, output_buffer);
}

test "build_manifest_path handles aliased input and output buffers" {
    var path_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    const install_path = try path_buffer.set("/tmp/zvm/install");
    const manifest_path = try build_manifest_path(&path_buffer, install_path);

    try std.testing.expectEqualStrings(
        "/tmp/zvm/install/.zvm-version",
        manifest_path,
    );
}
