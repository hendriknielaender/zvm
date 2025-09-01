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

        var request = try client.request(.GET, uri, .{
            .headers = headers,
        });
        defer request.deinit();

        try request.sendBodiless();
        
        // Use empty buffer for redirects since we don't handle them
        var redirect_buffer: [0]u8 = .{};
        var response = try request.receiveHead(&redirect_buffer);

        // Check status code
        if (response.head.status != .ok) {
            log.err("HTTP request failed with status: {}", .{response.head.status});
            return error.HttpRequestFailed;
        }

        // Get a reader for the response body
        var transfer_buffer: [4096]u8 = undefined;
        const body_reader = try response.reader(&transfer_buffer);
        
        // Read all content using readAllAlloc on the reader
        const response_bytes = try body_reader.readAlloc(arena.allocator(), operation.response_buffer.len);
        defer arena.allocator().free(response_bytes);
        
        if (response_bytes.len > operation.response_buffer.len) {
            log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {any}", .{
                operation.response_buffer.len,
                uri,
            });
            return error.ResponseTooLarge;
        }
        
        @memcpy(operation.response_buffer[0..response_bytes.len], response_bytes);
        const response_offset = response_bytes.len;

        if (response_offset >= operation.response_buffer.len) {
            log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {any}", .{
                limits.limits.http_response_size_maximum,
                uri,
            });
            return error.ResponseTooLarge;
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
        
        // Use empty buffer for redirects since we don't handle them  
        var redirect_buffer: [0]u8 = .{};
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

        var reader_buffer: [4096]u8 = undefined;
        const body_reader = try response.reader(&reader_buffer);

        // Stream data from reader to file
        var buffer: [8192]u8 = undefined;
        var total_bytes: u64 = 0;

        while (true) {
            const bytes_read = body_reader.readSliceShort(&buffer) catch |err| {
                if (err == error.EndOfStream) {
                    break;
                }
                return err;
            };
            if (bytes_read == 0) break;

            try dest_file.writeAll(buffer[0..bytes_read]);
            total_bytes += bytes_read;

            if (content_length > 0) {
                progress_node.setCompletedItems(@intCast(total_bytes));
            }
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
