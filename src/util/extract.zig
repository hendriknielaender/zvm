//! This file is used to decompress the file
const std = @import("std");
const data = @import("data.zig");
const tool = @import("tool.zig");

const xz = std.compress.xz;
const tar = std.tar;

/// Extract file to out_dir
pub fn extract(
    out_dir: std.fs.Dir,
    file: std.fs.File,
    file_type: enum { tarxz, zip },
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    switch (file_type) {
        .zip => try extract_zip_dir(out_dir, file, root_node),
        .tarxz => try extract_tarxz_to_dir(out_dir, file, is_zls, root_node),
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

    var decompressed = try xz.decompress(data.get_allocator(), buffered_reader.reader());
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

/// Extract zip to directory
fn extract_zip_dir(out_dir: std.fs.Dir, file: std.fs.File, _: std.Progress.Node) !void {
    var arena = std.heap.ArenaAllocator.init(data.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();
    // for decompressing zig, we need to make a temp directory
    const tmp_path = try data.get_zvm_path_segment(allocator, "tmpdir");
    defer std.fs.deleteTreeAbsolute(tmp_path) catch |err| {
        std.debug.print("Failed to delete temporary directory: {}\n", .{err});
    };

    try std.fs.makeDirAbsolute(tmp_path);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer tmp_dir.close();

    // extract zip
    try std.zip.extract(tmp_dir, file.seekableStream(), .{});

    const out_path = try out_dir.realpathAlloc(allocator, "");
    defer allocator.free(out_path);

    try tool.copy_dir(tmp_path, out_path);
}
