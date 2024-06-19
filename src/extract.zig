const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

pub fn extract_tarxz_to_dir(allocator: std.mem.Allocator, outDir: std.fs.Dir, file: std.fs.File) !void {
    if (builtin.os.tag == .windows) {
        try extract_zip_dir(outDir, file);
    } else {
        var buffered_reader = std.io.bufferedReader(file.reader());
        var decompressed = try std.compress.xz.decompress(allocator, buffered_reader.reader());
        defer decompressed.deinit();
        try std.tar.pipeToFileSystem(outDir, decompressed.reader(), .{ .mode_mode = .executable_bit_only, .strip_components = 1 });
    }
}

pub fn extract_zip_dir(outDir: std.fs.Dir, file: std.fs.File) !void {
    var arena = std.heap.ArenaAllocator.init(tools.getAllocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const tmp_path = try tools.getZvmPathSegment(allocator, "tmpdir");
    defer std.fs.deleteDirAbsolute(tmp_path) catch unreachable;

    // make tmp dir
    try std.fs.makeDirAbsolute(tmp_path);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });

    try std.zip.extract(tmp_dir, file.seekableStream(), .{});

    var iterate = tmp_dir.iterate();

    var sub_dir = blk: {
        const entry = try iterate.next() orelse return error.NotFound;
        break :blk try tmp_dir.openDir(entry.name, .{
            .iterate = true,
        });
    };
    defer sub_dir.close();
    const sub_path = try sub_dir.realpathAlloc(allocator, "");
    defer std.fs.deleteDirAbsolute(sub_path) catch unreachable;

    var sub_iterate = sub_dir.iterate();

    while (try sub_iterate.next()) |entry| {
        try std.fs.rename(sub_dir, entry.name, outDir, entry.name);
    }
}
