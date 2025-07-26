//! This file is used to decompress the file
const std = @import("std");
const data = @import("data.zig");
const tool = @import("tool.zig");
const object_pools = @import("../object_pools.zig");

const xz = std.compress.xz;
const tar = std.tar;

/// Extract file to out_dir using static allocation.
pub fn extract_static(
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.fs.Dir,
    file: std.fs.File,
    file_type: enum { tarxz, zip, tarGz },
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    switch (file_type) {
        .zip => try extract_zip_dir_static(extract_op, out_dir, file, root_node),
        .tarxz => try extract_tarxz_to_dir(out_dir, file, is_zls, root_node),
        .tarGz => try extract_targz_to_dir(out_dir, file, is_zls, root_node),
    }
}

/// Extract tar.xz to dir
fn extract_tarxz_to_dir(
    out_dir: std.fs.Dir,
    file: std.fs.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    var buffered_reader = std.io.bufferedReader(file.reader());

    // Note: Decompression still needs dynamic allocation due to xz library requirements.
    // This is unavoidable for compressed data handling.
    var decompressed = try xz.decompress(std.heap.page_allocator, buffered_reader.reader());
    defer decompressed.deinit();

    // Start extraction with an indeterminate progress indicator
    root_node.setEstimatedTotalItems(0);

    try tar.pipeToFileSystem(
        out_dir,
        decompressed.reader(),
        .{ .mode_mode = .executable_bit_only, .strip_components = if (is_zls) 0 else 1 },
    );

    root_node.setCompletedItems(1);
}

/// Extract tar.gz to dir
fn extract_targz_to_dir(
    out_dir: std.fs.Dir,
    file: std.fs.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    var buffered_reader = std.io.bufferedReader(file.reader());

    // Note: Decompression still needs dynamic allocation internally.
    var decompressor = std.compress.gzip.decompressor(buffered_reader.reader());

    // Start extraction with an indeterminate progress indicator
    root_node.setEstimatedTotalItems(0);

    try tar.pipeToFileSystem(
        out_dir,
        decompressor.reader(),
        .{ .mode_mode = .executable_bit_only, .strip_components = if (is_zls) 0 else 1 },
    );

    root_node.setCompletedItems(1);
}

/// Extract zip to directory using static allocation.
fn extract_zip_dir_static(
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.fs.Dir,
    file: std.fs.File,
    _: std.Progress.Node,
) !void {
    // Use pre-allocated path buffers from extract operation.
    const tmp_path_buffer = &extract_op.tmp_path_buffer;
    const tmp_path = try data.get_zvm_path_segment(tmp_path_buffer, "tmpdir");
    defer std.fs.deleteTreeAbsolute(tmp_path) catch |err| {
        std.debug.print("Failed to delete temporary directory: {}\n", .{err});
    };

    try std.fs.makeDirAbsolute(tmp_path);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer tmp_dir.close();

    // Note: zip extraction still needs page allocator internally.
    try std.zip.extract(tmp_dir, file.seekableStream(), .{});

    // Use pre-allocated buffer for output path.
    const out_path_buffer = &extract_op.out_path_buffer;
    const realpath_result = try out_dir.realpath(".", out_path_buffer.slice());
    const out_path = try out_path_buffer.set(realpath_result);

    // Use temporary buffers for copying directories.
    var source_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    var dest_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    try tool.copy_dir_static(tmp_path, out_path, &source_buffer, &dest_buffer);
}
