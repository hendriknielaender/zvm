const std = @import("std");
const data = @import("data.zig");
const tool = @import("tool.zig");
const hash = @import("hash.zig");
const context = @import("../context.zig");
const object_pools = @import("../object_pools.zig");
const limits = @import("../limits.zig");

/// HTTP get using static allocation.
pub fn http_get_static(http_op: *object_pools.HttpOperation, uri: std.Uri) ![]const u8 {
    // Note: HTTP client still needs an allocator for internal operations.
    // This is one of the few places where dynamic allocation is unavoidable.
    const allocator = std.heap.page_allocator;

    // Create a HTTP client.
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Use pre-allocated buffer for server headers.
    var header_buffer: [2048]u8 = undefined;

    // Try open a request.
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();

    // Send request and wait response.
    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    // Read into pre-allocated response buffer.
    const response_buffer = http_op.response_slice();
    var read_total: usize = 0;

    while (read_total < response_buffer.len) {
        const bytes_read = try req.reader().read(response_buffer[read_total..]);
        if (bytes_read == 0) break;
        read_total += bytes_read;
    }

    // Check if response was too large.
    var dummy: [1]u8 = undefined;
    if (try req.reader().read(&dummy) > 0) {
        return error.ResponseTooLarge;
    }

    return response_buffer[0..read_total];
}

/// Download the url and verify hashsum (if exist) using static allocation.
pub fn download_static(
    ctx: *context.CliContext,
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
    progress_node: std.Progress.Node,
) !std.fs.File {
    // Get store directory
    var store = try open_store_directory(ctx);
    defer store.close();

    // Check if file exists and is valid
    if (try check_existing_file(store, file_name, shasum, progress_node)) |file| {
        return file;
    }

    // Download the file
    return try download_file(store, uri, file_name, shasum, size, progress_node);
}

/// Open the store directory for downloads
fn open_store_directory(ctx: *context.CliContext) !std.fs.Dir {
    var store_path_buffer = try ctx.acquire_path_buffer();
    defer store_path_buffer.reset();
    const zvm_path = try data.get_zvm_path_segment(store_path_buffer, "store");
    return try std.fs.cwd().makeOpenPath(zvm_path, .{});
}

/// Check if file already exists and verify its hash
fn check_existing_file(
    store: std.fs.Dir,
    file_name: []const u8,
    shasum: ?[64]u8,
    progress_node: std.Progress.Node,
) !?std.fs.File {
    if (!tool.does_path_exist2(store, file_name)) {
        return null;
    }

    if (shasum) |expected_hash| {
        const file = try store.openFile(file_name, .{});
        defer file.close();

        const file_hash = try calculate_file_hash(file);

        if (hash.verify_hash(file_hash, expected_hash)) {
            try file.seekTo(0);
            progress_node.end();
            return file;
        }
    }

    try store.deleteFile(file_name);
    return null;
}

/// Calculate SHA256 hash of a file
fn calculate_file_hash(file: std.fs.File) ![32]u8 {
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [512]u8 = undefined;

    while (true) {
        const byte_nums = try file.read(&buffer);
        if (byte_nums == 0) break;
        sha256.update(buffer[0..byte_nums]);
    }

    var result = std.mem.zeroes([32]u8);
    sha256.final(&result);
    return result;
}

/// Download file from URI
fn download_file(
    store: std.fs.Dir,
    uri: std.Uri,
    file_name: []const u8,
    shasum: ?[64]u8,
    size: ?usize,
    progress_node: std.Progress.Node,
) !std.fs.File {
    // Note: HTTP client still needs an allocator.
    const allocator = std.heap.page_allocator;

    // Make HTTP request
    var response = try make_http_request(allocator, uri);
    defer response.deinit();

    // Validate response
    try validate_response(&response.req, size);

    // Set up progress reporting
    const total_size: usize = @intCast(response.req.response.content_length orelse 0);
    progress_node.setEstimatedTotalItems(total_size);

    // Download to file
    const file = try store.createFile(file_name, .{});
    errdefer file.close();

    const final_hash = try download_and_hash(&response.req, file, progress_node);

    // Verify hash if provided
    if (shasum) |expected_hash| {
        if (!hash.verify_hash(final_hash, expected_hash)) {
            try store.deleteFile(file_name);
            return error.HashMismatch;
        }
    }

    // Rewind file for reading
    try file.seekTo(0);
    progress_node.end();
    return file;
}

/// HTTP response wrapper for cleanup
const HttpResponse = struct {
    client: std.http.Client,
    req: std.http.Client.Request,

    fn deinit(self: *HttpResponse) void {
        self.req.deinit();
        self.client.deinit();
    }
};

/// Make HTTP GET request
fn make_http_request(allocator: std.mem.Allocator, uri: std.Uri) !HttpResponse {
    var client = std.http.Client{ .allocator = allocator };
    errdefer client.deinit();

    var header_buffer: [10240]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    errdefer req.deinit();

    try req.send();
    try req.wait();

    return HttpResponse{ .client = client, .req = req };
}

/// Validate HTTP response
fn validate_response(req: *std.http.Client.Request, expected_size: ?usize) !void {
    if (req.response.status != .ok) {
        return error.DownFailed;
    }

    if (expected_size) |size| {
        const actual_size: usize = @intCast(req.response.content_length orelse 0);
        if (size != actual_size) {
            return error.IncorrectSize;
        }
    }
}

/// Download content and calculate hash
fn download_and_hash(
    req: *std.http.Client.Request,
    file: std.fs.File,
    progress_node: std.Progress.Node,
) ![32]u8 {
    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    var download_buffer: [64 * 1024]u8 = undefined;
    var bytes_down: usize = 0;

    while (true) {
        const byte_read = try req.reader().read(&download_buffer);
        if (byte_read == 0) break;

        try file.writeAll(download_buffer[0..byte_read]);
        sha256.update(download_buffer[0..byte_read]);
        bytes_down += byte_read;
        progress_node.setCompletedItems(bytes_down);
    }

    var result = std.mem.zeroes([32]u8);
    sha256.final(&result);
    return result;
}
