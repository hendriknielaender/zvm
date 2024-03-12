const std = @import("std");

pub fn extract_tarxz_to_dir(allocator: std.mem.Allocator, outDir: std.fs.Dir, file: std.fs.File) !void {
    var buffered_reader = std.io.bufferedReader(file.reader());
    var decompressed = try std.compress.xz.decompress(allocator, buffered_reader.reader());
    defer decompressed.deinit();
    try std.tar.pipeToFileSystem(outDir, decompressed.reader(), .{ .mode_mode = .ignore, .strip_components = 1 });
}
