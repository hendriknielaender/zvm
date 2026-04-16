//! This file is used to decompress the file
const std = @import("std");
const data = @import("../util/data.zig");
const tool = @import("../util/tool.zig");
const object_pools = @import("../memory/object_pools.zig");
const limits = @import("../memory/limits.zig");
const builtin = @import("builtin");
const log = std.log.scoped(.extract);

const tar = std.tar;

/// Extract file to out_dir using static allocation.
pub fn extract_static(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    file_type: enum { tarxz, zip, tar_gz },
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    switch (file_type) {
        .zip => try extract_zip_dir_static(io, extract_op, out_dir, file, root_node),
        .tarxz => try extract_tarxz_to_dir(io, extract_op, out_dir, file, is_zls, root_node),
        .tar_gz => try extract_targz_to_dir(io, out_dir, file, is_zls, root_node),
    }
}

/// Extract tar.xz to dir
fn extract_tarxz_to_dir(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    root_node.setEstimatedTotalItems(0);
    try extract_tarxz_with_system_tar(io, extract_op, out_dir, file, is_zls);
    root_node.setCompletedItems(1);
}

fn extract_tarxz_with_system_tar(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    is_zls: bool,
) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var archive_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_path_buffer, "/dev/fd/{d}", .{file.handle});

    var out_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path_len = try out_dir.realPath(io, &out_path_buffer);
    const out_path = out_path_buffer[0..out_path_len];

    const strip_components = if (is_zls) "0" else "1";
    const tar_executable = "/usr/bin/tar";
    const argv = [_][]const u8{
        tar_executable,
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

    root_node.setCompletedItems(1);
}

/// Extract zip to directory using static allocation.
fn extract_zip_dir_static(
    io: std.Io,
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.Io.Dir,
    file: std.Io.File,
    _: std.Progress.Node,
) !void {
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

    // Use pre-allocated buffer for output path.
    const out_path_buffer = &extract_op.out_path_buffer;
    const out_path_len = try out_dir.realPath(io, out_path_buffer.slice());
    const out_path = try out_path_buffer.set(out_path_buffer.slice()[0..out_path_len]);

    // Use temporary buffers for copying directories.
    // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
    var source_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
    var dest_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    try tool.copy_dir_static(io, tmp_path, out_path, &source_buffer, &dest_buffer);
}
