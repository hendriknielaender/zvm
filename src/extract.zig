const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

pub fn extract_tarxz_to_dir(allocator: std.mem.Allocator, out_dir: std.fs.Dir, file: std.fs.File) !void {
    var buffered_reader = std.io.bufferedReader(file.reader());
    var decompressed = try std.compress.xz.decompress(allocator, buffered_reader.reader());
    defer decompressed.deinit();
    try std.tar.pipeToFileSystem(out_dir, decompressed.reader(), .{ .mode_mode = .executable_bit_only, .strip_components = 1 });
}

pub fn extract_zip_dir(out_dir: std.fs.Dir, file: std.fs.File) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();
    const tmp_path = try tools.get_zvm_path_segment(allocator, "tmpdir");
    defer std.fs.delete_dir_absolute(tmp_path) catch unreachable;

    try std.fs.make_dir_absolute(tmp_path);
    var tmp_dir = try std.fs.open_dir_absolute(tmp_path, .{ .iterate = true });

    try std.zip.extract(tmp_dir, file.seekable_stream(), .{});

    var iterate = tmp_dir.iterate();
    var sub_dir = blk: {
        const entry = try iterate.next() orelse return error.NotFound;
        break :blk try tmp_dir.open_dir(entry.name, .{ .iterate = true });
    };
    defer sub_dir.close();

    const sub_path = try sub_dir.realpath_alloc(allocator, "");
    defer std.fs.delete_dir_absolute(sub_path) catch unreachable;

    var sub_iterate = sub_dir.iterate();
    while (try sub_iterate.next()) |entry| {
        try std.fs.rename(sub_dir, entry.name, out_dir, entry.name);
    }
}
