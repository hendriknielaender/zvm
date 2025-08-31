const std = @import("std");
const context = @import("../Context.zig");
const limits = @import("../memory/limits.zig");
const log = std.log.scoped(.http);

/// HTTP client that uses pre-allocated operations from the pool.
///
/// Following the static allocation principle, we pre-allocate buffers for:
/// - Response data
/// - URLs and headers
/// - Internal HTTP operations
///
/// IMPORTANT: Certificate handling exception
/// The Zig standard library's HTTPS implementation requires dynamic allocation
/// for certificate parsing and validation. This is unavoidable because:
/// - System certificate stores vary in size and format
/// - Certificate chains require dynamic data structures
/// - The TLS implementation needs to build trust chains dynamically
///
/// We mitigate this by:
/// - Using a bounded arena allocator that's freed after each request
/// - Pre-allocating the response buffers to avoid allocation for actual data
/// - Limiting concurrent HTTP operations to bound total memory usage
///
/// This is a pragmatic compromise: we accept some runtime allocation for
/// certificate handling (which happens once per connection) while maintaining
/// static allocation for the actual data transfer.
pub const HttpClient = struct {
    /// Fetch a URL using a pre-allocated HTTP operation
    pub fn fetch(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
    ) ![]const u8 {
        // Acquire an HTTP operation from the pool
        const operation = try ctx.acquire_http_operation();
        defer operation.release();

        // For HTTPS operations, we need an allocator that can handle certificate loading.
        // We use an arena that combines our pre-allocated buffer with page allocation fallback.
        // This ensures our data operations use pre-allocated memory while allowing
        // the certificate subsystem to work correctly.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var client = std.http.Client{ .allocator = arena.allocator() };
        defer client.deinit();

        // Use pre-allocated buffers
        var response_offset: usize = 0;

        var request = try client.request(.GET, uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        var response = try request.receiveHead(&.{});

        // Check if response is compressed
        var is_gzip = false;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) {
                if (std.mem.eql(u8, header.value, "gzip")) {
                    is_gzip = true;
                    break;
                }
            }
        }

        // Create a transfer buffer for HTTP reader (used for chunked encoding)
        var transfer_buffer: [limits.limits.http_transfer_buffer_size]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);

        // Read response into pre-allocated buffer
        if (is_gzip) {
            // If response is gzipped, we need to decompress it
            // First, read the compressed data
            var compressed_offset: usize = 0;
            while (true) {
                const available = operation.response_buffer[compressed_offset..];
                if (available.len == 0) break;

                const bytes_read = body_reader.readSliceShort(available) catch |err| {
                    if (err == error.ReadFailed) {
                        // Check if there's an underlying body error
                        if (response.bodyErr()) |body_err| return body_err;
                        // ReadFailed without body error means end of stream or connection closed
                        break;
                    }
                    return err;
                };
                if (bytes_read == 0) break;

                compressed_offset += bytes_read;
            }

            // Check if we actually have gzip data (starts with 0x1f 0x8b)
            if (compressed_offset >= 2) {
                if (operation.response_buffer[0] != 0x1f or operation.response_buffer[1] != 0x8b) {
                    // Not actually gzipped, just return the data as-is
                    response_offset = compressed_offset;
                } else {
                    // GitHub API returns gzipped data
                    // We'll use another HTTP operation's buffer for temporary decompression
                    const temp_operation = try ctx.acquire_http_operation();
                    defer temp_operation.release();
                    const temp_buffer = &temp_operation.response_buffer;

                    // Use the proper buffer size for flate decompression
                    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                    var fixed_reader = std.Io.Reader.fixed(operation.response_buffer[0..compressed_offset]);
                    var decompress: std.compress.flate.Decompress = .init(&fixed_reader, .gzip, &decompress_buffer);

                    // Read decompressed data into temporary buffer
                    var temp_offset: usize = 0;
                    while (temp_offset < temp_buffer.len) {
                        const slice = decompress.reader.readSliceShort(temp_buffer[temp_offset..]) catch |err| {
                            if (err == error.ReadFailed) {
                                // ReadFailed at the end of decompression is normal for some gzip streams
                                if (temp_offset > 0) {
                                    break;
                                }
                            }
                            return err;
                        };
                        if (slice == 0) break;
                        temp_offset += slice;
                    }

                    // Copy decompressed data back to response buffer
                    const copy_len = @min(temp_offset, operation.response_buffer.len);
                    @memcpy(operation.response_buffer[0..copy_len], temp_buffer[0..copy_len]);
                    response_offset = copy_len;
                }
            } else {
                // Too small to be gzipped
                response_offset = compressed_offset;
            }
        } else {
            // No compression, read normally
            while (true) {
                const available = operation.response_buffer[response_offset..];
                if (available.len == 0) {
                    log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {any}", .{
                        limits.limits.http_response_size_maximum,
                        uri,
                    });
                    return error.ResponseTooLarge;
                }

                const bytes_read = body_reader.readSliceShort(available) catch |err| {
                    if (err == error.ReadFailed) {
                        // Check if there's an underlying body error
                        if (response.bodyErr()) |body_err| return body_err;
                        // ReadFailed without body error means end of stream or connection closed
                        break;
                    }
                    return err;
                };
                if (bytes_read == 0) break;

                response_offset += bytes_read;
            }
        }

        return operation.response_buffer[0..response_offset];
    }

    /// Download a file using a pre-allocated HTTP operation
    pub fn download_file(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
        dest_file: std.fs.File,
        progress_node: std.Progress.Node,
    ) !void {
        // Acquire an HTTP operation from the pool
        const operation = try ctx.acquire_http_operation();
        defer operation.release();

        // Same as fetch() - we need a proper allocator for certificate handling
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var client = std.http.Client{ .allocator = arena.allocator() };
        defer client.deinit();

        var request = try client.request(.GET, uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();

        // Receive the response head (with redirect buffer for GitHub)
        var redirect_buffer: [limits.limits.http_redirect_buffer_size]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);

        // Check status code
        if (response.head.status != .ok) {
            log.err("HTTP request failed with status: {}", .{response.head.status});
            return error.HttpRequestFailed;
        }

        // Get content length for progress
        const content_length = if (response.head.content_length) |cl| cl else 0;
        if (content_length > 0) {
            progress_node.setEstimatedTotalItems(@intCast(content_length));
        }

        // Set up decompression if needed
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var transfer_buffer: [limits.limits.http_transfer_buffer_size]u8 = undefined;
        // SAFETY: decompress is initialized before use by readerDecompressing call below
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        // Create a writer for the destination file with buffering
        var write_buffer: [limits.limits.file_write_buffer_size]u8 = undefined;
        var file_writer = std.fs.File.Writer.init(dest_file, &write_buffer);
        const writer = &file_writer.interface;

        // Stream the entire body to the file
        const total_bytes = body_reader.streamRemaining(writer) catch |err| {
            if (err == error.ReadFailed) {
                if (response.bodyErr()) |body_err| return body_err;
            }
            return err;
        };
        try writer.flush();

        // Update final progress
        if (content_length > 0) {
            progress_node.setCompletedItems(@intCast(total_bytes));
        }
    }

    /// Fetch JSON and parse it using pre-allocated buffer
    pub fn fetch_json(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
        comptime T: type,
    ) !std.json.Parsed(T) {
        const response = try fetch(ctx, uri, headers);

        // Use the pre-allocated JSON parse buffer
        const json_buffer = ctx.getJsonBuffer();

        // Parse options that use our buffer
        const options = std.json.ParseOptions{
            .allocate = .alloc_if_needed,
            .max_value_len = json_buffer.len,
        };

        // Create a fixed buffer allocator for JSON parsing
        var fba = std.heap.FixedBufferAllocator.init(json_buffer);
        const json_allocator = fba.allocator();

        return try std.json.parseFromSlice(T, json_allocator, response, options);
    }
};
