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

/// Download the url and verify hashsum (if exist)
pub fn download(
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
    progress_node: std.Progress.Node,
) !std.fs.File {
    // Whether to verify hashsum
    const if_hash = shasum != null;
    const allocator = data.get_allocator();

    // Path to store the downloaded file
    const zvm_path = try data.get_zvm_path_segment(allocator, "store");
    defer allocator.free(zvm_path);

    var store = try std.fs.cwd().makeOpenPath(zvm_path, .{});
    defer store.close();

    // Check if the file already exists and verify its hash
    if (tool.does_path_exist2(store, file_name)) {
        if (if_hash) {
            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            const file = try store.openFile(file_name, .{});
            defer file.close();
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
                progress_node.end();
                return file;
            }
        }
        try store.deleteFile(file_name);
    }

    // HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buffer: [10240]u8 = undefined;

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();

    try req.send();
    try req.wait();

    // Ensure request was successful
    if (req.response.status != .ok)
        return error.DownFailed;

    // Compare file sizes
    const total_size: usize = @intCast(req.response.content_length orelse 0);
    if (size) |expected_size| {
        if (expected_size != total_size)
            return error.IncorrectSize;
    }

    // Set total items for progress reporting
    if (total_size != 0) {
        progress_node.setCompletedItems(total_size);
    }

    // Create a new file
    const new_file = try store.createFile(file_name, .{
        .read = true,
    });
    defer new_file.close();

    // SAFETY: Only used in conditional branch where if_hash is false, so never accessed
    var sha256 = if (if_hash) std.crypto.hash.sha2.Sha256.init(.{}) else undefined;

    // Buffer for reading data
    var buffer: [4096]u8 = undefined;
    const reader = req.reader();

    var bytes_downloaded: usize = 0;

    while (true) {
        // Read data from the response
        const byte_nums = try reader.read(&buffer);
        if (byte_nums == 0)
            break;

        if (if_hash)
            sha256.update(buffer[0..byte_nums]);

        // Write to file
        try new_file.writeAll(buffer[0..byte_nums]);

        // Update progress
        bytes_downloaded += byte_nums;
        if (total_size != 0) {
            progress_node.setCompletedItems(bytes_downloaded);
        }
    }

    // Verify hashsum if needed
    if (if_hash) {
        var result = std.mem.zeroes([32]u8);
        sha256.final(&result);

        if (!hash.verify_hash(result, shasum.?))
            return error.HashMismatch;
    }

    try new_file.seekTo(0);

    progress_node.end();

    // Re-open the file for reading
    return try store.openFile(file_name, .{});
}
