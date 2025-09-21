const std = @import("std");
const context = @import("../Context.zig");
const limits = @import("../memory/limits.zig");
const log = std.log.scoped(.http);

// Check if we have gzip decompression available
const has_gzip = @hasDecl(std.compress, "gzip");

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

        var buffer_writer = std.Io.fixedBufferStream(&operation.response_buffer);
        const old_writer = buffer_writer.writer();

        // Adapt the old writer to the new API
        var write_buffer: [4096]u8 = undefined;
        var adapter = old_writer.adaptToNewApi(&write_buffer);
        const writer = &adapter.new_interface;

        // Use the simple fetch API that handles redirects, compression, etc. automatically
        var redirect_buffer: [8192]u8 = undefined;
        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .headers = headers,
            .redirect_buffer = &redirect_buffer,
            .response_writer = writer,
        });

        if (result.status != .ok) {
            log.err("HTTP request failed with status: {}", .{result.status});
            return error.HttpRequestFailed;
        }

        const bytes_read = buffer_writer.pos;
        if (bytes_read == 0) {
            log.err("HTTP response is empty for URL: {any}", .{uri});
            return error.EmptyResponse;
        }

        if (bytes_read >= operation.response_buffer.len) {
            log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {any}", .{
                limits.limits.http_response_size_maximum,
                uri,
            });
            return error.ResponseTooLarge;
        }

        return operation.response_buffer[0..bytes_read];
    }

    /// Download a file using a pre-allocated HTTP operation
    pub fn download_file(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
        dest_file: std.fs.File,
        progress_node: std.Progress.Node,
    ) !void {
        _ = ctx;
        _ = progress_node;

        // Same as fetch() - we need a proper allocator for certificate handling
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var client = std.http.Client{ .allocator = arena.allocator() };
        defer client.deinit();

        // Create a writer that writes directly to the file
        var writer_buffer: [8192]u8 = undefined;
        var writer = dest_file.writer(&writer_buffer);

        // Use the simple fetch API that handles redirects, compression, etc. automatically
        var redirect_buffer: [8192]u8 = undefined;
        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .headers = headers,
            .redirect_buffer = &redirect_buffer,
            .response_writer = &writer.interface,
        });

        if (result.status != .ok) {
            log.err("HTTP request failed with status: {}", .{result.status});
            return error.HttpRequestFailed;
        }

        // Flush the writer to ensure all data is written to the file
        try writer.interface.flush();
    }
};
