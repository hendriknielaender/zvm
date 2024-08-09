const std = @import("std");
const data = @import("data.zig");
const tool = @import("tool.zig");
const hash = @import("hash.zig");

/// http get
pub fn http_get(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {

    // create a http client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // we ceate a buffer to store the http response
    var buf: [2048]u8 = undefined;

    // try open a request
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    // send request and wait response
    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const res = try req.reader().readAllAlloc(allocator, 256 * 1024);
    return res;
}

/// download the url
/// and verify hashsum (if exist)
pub fn download(
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
) !std.fs.File {

    // whether verify hashsum
    const if_hash = shasum != null;

    // allocator
    const allocator = data.get_allocator();

    // this file store the downloaded src
    const zvm_path = try data.get_zvm_path_segment(allocator, "store");
    defer allocator.free(zvm_path);

    var store = try std.fs.cwd().makeOpenPath(zvm_path, .{});
    defer store.close();

    // if file exist
    // and provide shasum
    // then calculate hash and verify, return the file if eql
    // otherwise delete this file
    if (tool.does_path_exist2(store, file_name)) {
        if (if_hash) {
            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            const file = try store.openFile(file_name, .{});
            var buffer: [512]u8 = undefined;
            while (true) {
                const byte_nums = try file.read(&buffer);
                if (byte_nums == 0)
                    break;

                sha256.update(buffer[0..byte_nums]);
            }
            var result = std.mem.zeroes([32]u8);
            sha256.final(&result);

            if (hash.verify_hash(result, shasum.?)) {
                try file.seekTo(0);
                return file;
            }
        }
        try store.deleteFile(file_name);
    }

    // http client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buffer: [10240]u8 = undefined; // 1024b

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();

    try req.send();
    try req.wait();

    // ensure req successfully
    if (req.response.status != .ok)
        return error.DownFailed;

    // Compare file sizes
    if (size) |ss| {
        const total_size: usize = @intCast(req.response.content_length orelse 0);
        if (ss != total_size)
            return error.IncorrectSize;
    }

    // create a new file
    const new_file = try store.createFile(file_name, .{
        .read = true,
    });

    // whether enable hashsum
    var sha256 = if (if_hash) std.crypto.hash.sha2.Sha256.init(.{}) else undefined;

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

        if (!hash.verify_hash(result, shasum.?))
            return error.HashMismatch;
    }

    try new_file.seekTo(0);

    return new_file;
}
