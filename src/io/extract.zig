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
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.fs.Dir,
    file: std.fs.File,
    file_type: enum { tarxz, zip, tar_gz },
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    switch (file_type) {
        .zip => try extract_zip_dir_static(extract_op, out_dir, file, root_node),
        .tarxz => try extract_tarxz_to_dir(extract_op, out_dir, file, is_zls, root_node),
        .tar_gz => try extract_targz_to_dir(out_dir, file, is_zls, root_node),
    }
}

/// Extract tar.xz to dir
fn extract_tarxz_to_dir(
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.fs.Dir,
    file: std.fs.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    root_node.setEstimatedTotalItems(0);
    try extract_tarxz_with_system_tar(extract_op, out_dir, file, is_zls);
    root_node.setCompletedItems(1);
}

fn extract_tarxz_with_system_tar(
    extract_op: *object_pools.ExtractOperation,
    out_dir: std.fs.Dir,
    file: std.fs.File,
    is_zls: bool,
) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var archive_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const archive_path = try std.os.getFdPath(file.handle, &archive_path_buffer);

    var out_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try out_dir.realpath(".", &out_path_buffer);

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

    var process_fba = std.heap.FixedBufferAllocator.init(extract_op.slice());
    var child = std.process.Child.init(&argv, process_fba.allocator());
    child.expand_arg0 = .no_expand;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.TarExtractionFailed;
        },
        else => return error.TarExtractionFailed,
    }
}

/// Extract tar.gz to dir
fn extract_targz_to_dir(
    out_dir: std.fs.Dir,
    file: std.fs.File,
    is_zls: bool,
    root_node: std.Progress.Node,
) !void {
    // Create a File.Reader with buffer
    var reader_buffer: [limits.limits.file_read_buffer_size]u8 = undefined;
    var file_reader = file.reader(&reader_buffer);

    var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &.{});

    // Start extraction with an indeterminate progress indicator
    root_node.setEstimatedTotalItems(0);

    try tar.pipeToFileSystem(
        out_dir,
        &decompress.reader,
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
        log.warn("Failed to delete temporary directory: {}", .{err});
    };

    try std.fs.makeDirAbsolute(tmp_path);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer tmp_dir.close();

    // Note: zip extraction still needs page allocator internally.
    // Create a File.Reader for the zip file
    var reader_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&reader_buffer);
    try std.zip.extract(tmp_dir, &file_reader, .{});

    // Use pre-allocated buffer for output path.
    const out_path_buffer = &extract_op.out_path_buffer;
    const realpath_result = try out_dir.realpath(".", out_path_buffer.slice());
    const out_path = try out_path_buffer.set(realpath_result);

    // Use temporary buffers for copying directories.
    // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
    var source_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    // SAFETY: PathBuffer.data is initialized before first use via copy_dir_static
    var dest_buffer: object_pools.PathBuffer = .{ .data = undefined, .used = 0 };
    try tool.copy_dir_static(tmp_path, out_path, &source_buffer, &dest_buffer);
}
