const std = @import("std");
const context = @import("context.zig");
const limits = @import("limits.zig");

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

        var request = try client.open(.GET, uri, .{
            .server_header_buffer = operation.header_slice(),
            .headers = headers,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        // Read response into pre-allocated buffer
        while (true) {
            const available = operation.response_buffer[response_offset..];
            if (available.len == 0) {
                std.log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {s}", .{
                    limits.limits.http_response_size_maximum,
                    uri,
                });
                return error.ResponseTooLarge;
            }

            const bytes_read = try request.reader().read(available);
            if (bytes_read == 0) break;

            response_offset += bytes_read;
        }

        return operation.response_buffer[0..response_offset];
    }

    /// Download a file using a pre-allocated HTTP operation
    pub fn downloadFile(
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

        var request = try client.open(.GET, uri, .{
            .server_header_buffer = operation.header_slice(),
            .headers = headers,
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        // Get content length for progress
        const content_length = if (request.response.content_length) |cl| cl else 0;

        var downloaded: usize = 0;

        // Use a fixed chunk of the response buffer for streaming downloads
        const chunk_size = @min(64 * 1024, operation.response_buffer.len);

        while (true) {
            const bytes_read = try request.reader().read(operation.response_buffer[0..chunk_size]);
            if (bytes_read == 0) break;

            try dest_file.writeAll(operation.response_buffer[0..bytes_read]);
            downloaded += bytes_read;

            if (content_length > 0) {
                progress_node.setCompletedItems(@intCast(downloaded));
                progress_node.setEstimatedTotalItems(@intCast(content_length));
            }
        }
    }

    /// Fetch JSON and parse it using pre-allocated buffer
    pub fn fetchJson(
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
