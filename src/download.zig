const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

const sha2 = std.crypto.hash.sha2;

/// download the url
/// and verify hashsum (if exist)
pub fn download(
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
) !std.fs.File {
    // whether verify hashsum
    const if_hash = shasum != null;

    // allocator
    const allocator = tools.get_allocator();

    // http client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buffer: [1024]u8 = undefined; // 1024b

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();

    try req.send();
    try req.wait();

    // ensure req successfully
    if (req.response.status != .ok)
        return error.DownFailed;

    // NOTE:
    // const total_size: usize = @intCast(req.response.content_length orelse 0);

    // this file store the downloaded src
    const zvm_path = try tools.get_zvm_path_segment(allocator, "store");
    defer allocator.free(zvm_path);

    var store = try std.fs.cwd().makeOpenPath(zvm_path, .{});
    defer store.close();

    // create a new file
    const new_file = try store.createFile(file_name, .{
        .read = true,
    });

    // whether enable hashsum
    var sha256 = if (if_hash) sha2.Sha256.init(.{}) else undefined;

    // the tmp buffer to store the receive data
    var buffer: [512]u8 = undefined;
    // get reader
    const reader = req.reader();
    while (true) {
        // the read byte number
        const byte_nums = try reader.read(&buffer);
        if (byte_nums == 0)
            break;
        if (if_hash)
            sha256.update(buffer[0..byte_nums]);
        // write to file
        try new_file.writeAll(buffer[0..byte_nums]);
    }

    // when calculate hashsum
    if (if_hash) {
        var result = std.mem.zeroes([32]u8);
        sha256.final(&result);

        if (!tools.verify_hash(result, shasum.?))
            return error.HashMismatch;
    }

    try new_file.seekTo(0);

    return new_file;
}
