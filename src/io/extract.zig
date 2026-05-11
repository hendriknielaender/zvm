//! This file is used to decompress the file
const std = @import("std");
const data = @import("../util/data.zig");
const tool = @import("../util/tool.zig");
const object_pools = @import("../memory.zig");
const limits = @import("../memory/limits.zig");
const signals = @import("../platform/signals.zig");
const builtin = @import("builtin");
const log = std.log.scoped(.extract);
const assert = std.debug.assert;

const tar = std.tar;

/// Extract file to out_dir using static allocation.
/// archive_path is the on-disk path to the tarball, used by the tarxz path.
/// file is used by the tar_gz and zip paths for streaming decompression.
pub const ExtractFileType = enum { tarxz, zip, tar_gz };

pub fn extract_static(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    file_type: ExtractFileType,
    is_zls: bool,
    root_node: std.Progress.Node,
    archive_path: []const u8,
) !void {
    try signals.check();
    switch (file_type) {
        .zip => try extract_zip_dir_static(io, extract_op, out_dir, file, is_zls, root_node),
        .tarxz => try extract_tarxz_to_dir(io, extract_op, out_dir, archive_path, is_zls, root_node),
        .tar_gz => try extract_targz_to_dir(io, out_dir, file, is_zls, root_node),
    }
}

/// Extract tar.xz to dir using the system tar binary.
/// The tarball must already be on disk at archive_path.
fn extract_tarxz_to_dir(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    archive_path: []const u8,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    root_node.setEstimatedTotalItems(0);
    try signals.check();
    try extract_tarxz_with_system_tar(io, extract_op, out_dir, archive_path, is_zls);
    try signals.check();
    root_node.setCompletedItems(1);
}

fn extract_tarxz_with_system_tar(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    archive_path: []const u8,
    is_zls: bool,
) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    assert(archive_path.len > 0);
    try signals.check();

    var out_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path_len = try out_dir.realPath(io, &out_path_buffer);
    const out_path = out_path_buffer[0..out_path_len];

    const strip_components = if (is_zls) "0" else "1";
    const argv = [_][]const u8{
        "tar",
        "-xJf",
        archive_path,
        "-C",
        out_path,
        "--strip-components",
        strip_components,
    };

    _ = extract_op;
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .expand_arg0 = .no_expand,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    try signals.check();
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.TarExtractionFailed;
        },
        else => return error.TarExtractionFailed,
    }
}

/// Extract tar.gz to dir
fn extract_targz_to_dir(
    io: std.Io,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    try signals.check();
    // Create a File.Reader with buffer
    var reader_buffer: [limits.limits.file_read_buffer_size]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);

    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &.{});

    // Start extraction with an indeterminate progress indicator
    root_node.setEstimatedTotalItems(0);

    try tar.extract(
        io,
        out_dir,
        &decompress.reader,
        .{ .mode_mode = .executable_bit_only, .strip_components = if (is_zls) 0 else 1 },
    );

    try signals.check();
    root_node.setCompletedItems(1);
}

/// Extract zip to directory using static allocation.
fn extract_zip_dir_static(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    is_zls: bool,
    _: std.Progress.Node,
) !void {
    try signals.check();
    // Use pre-allocated path buffers from extract operation.
    const tmp_path_buffer = &extract_op.tmp_path_buffer;
    const tmp_path = try data.get_zvm_path_segment(tmp_path_buffer, "tmpdir");
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch |err| {
        log.warn("Failed to delete temporary directory: {}", .{err});
    };

    try std.Io.Dir.createDirAbsolute(io, tmp_path, .default_dir);
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, tmp_path, .{ .iterate = true });
    defer tmp_dir.close(io);

    // Note: zip extraction still needs page allocator internally.
    // Create a File.Reader for the zip file
    var reader_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);
    try std.zip.extract(tmp_dir, &file_reader, .{});
    try signals.check();

    // Use pre-allocated buffer for output path.
    const out_path_buffer = &extract_op.out_path_buffer;
    const out_path_len = try out_dir.realPath(io, out_path_buffer.slice());
    const out_path = try out_path_buffer.set(out_path_buffer.slice()[0..out_path_len]);

    const copy_source = if (is_zls) tmp_path else try strip_single_dir(io, tmp_dir, tmp_path, extract_op);

    // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
    var source_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    var dest_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    try tool.copy_dir_static(io, copy_source, out_path, &source_buffer, &dest_buffer);
    try signals.check();
}

fn strip_single_dir(
    io: std.Io,
    tmp_dir: std.Io.Dir,
    tmp_path: []const u8,
    extract_op: *object_pools.ExtractOperation,
) ![]const u8 {
    var iter = tmp_dir.iterate();
    const entry = (try iter.next(io)) orelse return error.EmptyArchive;
    if (entry.kind != .directory) return tmp_path;
    if (try iter.next(io) != null) return tmp_path;

    const buffer = &extract_op.tmp_path_buffer;
    const stripped_path = try std.fmt.bufPrint(extract_op.slice(), "{s}/{s}", .{ tmp_path, entry.name });
    return try buffer.set(stripped_path);
}
