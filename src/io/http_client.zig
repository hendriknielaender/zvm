const std = @import("std");
const assert = std.debug.assert;
const context = @import("../Context.zig");
const limits = @import("../memory/limits.zig");
const util_tool = @import("../util/tool.zig");
const util_output = @import("../util/output.zig");
const signals = @import("../platform/signals.zig");
const log = std.log.scoped(.http);

/// Name of the environment variable that overrides the per-request total
/// timeout. Documented in `core/help.zig`.
pub const timeout_env_var_name = "ZVM_DOWNLOAD_TIMEOUT_SECONDS";

/// Default total timeout for one mirror attempt. Picked to be generous enough
/// for slow CI links on a 100MB tarball (~0.5 Mbit/s) but bounded so a stalled
/// mirror cannot hang `zvm install` indefinitely.
pub const timeout_total_default_seconds: u32 = 1800;

/// Lower bound for the total timeout. Anything smaller cannot reliably
/// complete a TLS handshake plus a small response.
pub const timeout_total_minimum_seconds: u32 = 5;

/// Upper bound for the total timeout (24h). Large enough for any plausible
/// link, small enough to bound clearly mistaken values.
pub const timeout_total_maximum_seconds: u32 = 24 * 60 * 60;

/// Connect-phase soft target. Documented for users; enforced indirectly via
/// the total timeout because std.http.Client does not expose connect hooks.
pub const timeout_connect_default_seconds: u32 = 10;

/// Idle/read soft target. Documented for users; enforced indirectly via the
/// total timeout because std.http.Client does not expose per-read hooks.
pub const timeout_idle_default_seconds: u32 = 30;

comptime {
    assert(timeout_total_default_seconds >= timeout_total_minimum_seconds);
    assert(timeout_total_default_seconds <= timeout_total_maximum_seconds);
    assert(timeout_connect_default_seconds < timeout_total_default_seconds);
    assert(timeout_idle_default_seconds < timeout_total_default_seconds);
}

/// Resolves the per-request total timeout, honoring `ZVM_DOWNLOAD_TIMEOUT_SECONDS`
/// when set to a value inside the documented bounds. Invalid values fall back
/// to the default with a warning, matching the "no surprise" convention used
/// elsewhere in zvm for env overrides.
pub fn read_total_timeout_seconds() u32 {
    const raw = util_tool.getenv_cross_platform(timeout_env_var_name) orelse
        return timeout_total_default_seconds;
    if (raw.len == 0) return timeout_total_default_seconds;

    const parsed = std.fmt.parseInt(u32, raw, 10) catch {
        log.warn("Invalid {s}={s}; using default {d}s", .{
            timeout_env_var_name,
            raw,
            timeout_total_default_seconds,
        });
        return timeout_total_default_seconds;
    };

    if (parsed < timeout_total_minimum_seconds or parsed > timeout_total_maximum_seconds) {
        log.warn("{s}={d} outside [{d},{d}]; using default {d}s", .{
            timeout_env_var_name,
            parsed,
            timeout_total_minimum_seconds,
            timeout_total_maximum_seconds,
            timeout_total_default_seconds,
        });
        return timeout_total_default_seconds;
    }

    assert(parsed >= timeout_total_minimum_seconds);
    assert(parsed <= timeout_total_maximum_seconds);
    return parsed;
}

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
    /// Fetch a URL using a pre-allocated HTTP operation. Bounded by the
    /// total timeout (see `read_total_timeout_seconds`); a stalled mirror
    /// returns `error.MirrorTimeout` instead of hanging.
    pub fn fetch(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
    ) ![]const u8 {
        const total_seconds = read_total_timeout_seconds();
        try signals.check();
        return run_with_timeout(FetchTask, FetchTask.run, .{
            .ctx = ctx,
            .uri = uri,
            .headers = headers,
        }, ctx.io, total_seconds, uri);
    }

    /// Download a file using a pre-allocated HTTP operation. Bounded by the
    /// total timeout; on timeout the partial file is left for the caller to
    /// clean up (existing install logic re-downloads on hash mismatch).
    pub fn download_file(
        ctx: *context.CliContext,
        uri: std.Uri,
        headers: std.http.Client.Request.Headers,
        dest_file: std.Io.File,
        progress_node: std.Progress.Node,
    ) !void {
        const total_seconds = read_total_timeout_seconds();
        try signals.check();
        _ = try run_with_timeout(DownloadTask, DownloadTask.run, .{
            .ctx = ctx,
            .uri = uri,
            .headers = headers,
            .dest_file = dest_file,
            .progress_node = progress_node,
        }, ctx.io, total_seconds, uri);
    }
};

/// Generic timeout wrapper. Spawns the long-running HTTP task concurrently
/// with a sleep task and returns whichever completes first; the loser is
/// canceled. On timeout we return `error.MirrorTimeout` so the install
/// fallback chain in `core/install.zig` proceeds to the next mirror.
fn run_with_timeout(
    comptime Task: type,
    comptime task_fn: anytype,
    task_args: Task,
    io: std.Io,
    total_seconds: u32,
    uri: std.Uri,
) anyerror!Task.Payload {
    assert(total_seconds >= timeout_total_minimum_seconds);
    assert(total_seconds <= timeout_total_maximum_seconds);

    const Outcome = union(enum) {
        completed: anyerror!Task.Payload,
        timed_out: void,
    };

    var select_buffer: [2]Outcome = undefined;
    // Race the network operation against a timer and cancel whichever arm loses.
    var select: std.Io.Select(Outcome) = .init(io, &select_buffer);

    select.concurrent(.completed, task_fn, .{task_args}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            log.debug("Concurrency unavailable; running without timeout for {any}", .{uri});
            return task_fn(task_args);
        },
    };

    select.concurrent(.timed_out, sleep_seconds, .{ io, total_seconds }) catch |err| switch (err) {
        // Fetch is already running concurrently; await it without a timer.
        // Single-threaded builds are the only realistic path here.
        error.ConcurrencyUnavailable => {
            log.debug("Timer concurrency unavailable; awaiting fetch without timeout for {any}", .{uri});
            const outcome = select.await() catch |await_err| switch (await_err) {
                error.Canceled => {
                    _ = select.cancel();
                    return error.Canceled;
                },
            };
            return switch (outcome) {
                .completed => |result| {
                    _ = select.cancel();
                    return result;
                },
                .timed_out => unreachable,
            };
        },
    };

    const winner = select.await() catch |err| switch (err) {
        error.Canceled => {
            _ = select.cancel();
            return error.Canceled;
        },
    };

    _ = select.cancel();

    switch (winner) {
        .completed => |result| return result,
        .timed_out => {
            log.warn("Mirror timed out after {d}s: {any}", .{ total_seconds, uri });
            return error.MirrorTimeout;
        },
    }
}

fn sleep_seconds(io: std.Io, seconds: u32) void {
    const duration: std.Io.Duration = .fromSeconds(@intCast(seconds));
    // A canceled timer is the losing Select arm, so no error is reported.
    std.Io.sleep(io, duration, .awake) catch return;
}

const FetchTask = struct {
    ctx: *context.CliContext,
    uri: std.Uri,
    headers: std.http.Client.Request.Headers,

    const Payload = []const u8;

    fn run(self: FetchTask) anyerror!Payload {
        try signals.check();
        var http_scratch = try self.ctx.scratch(.http);
        defer http_scratch.release();
        const operation = http_scratch.operation();

        var scratch_fba = std.heap.FixedBufferAllocator.init(operation.scratch_slice());
        var client = std.http.Client{
            .allocator = scratch_fba.allocator(),
            .io = self.ctx.io,
            .connection_pool = .{ .free_size = 0 },
            .read_buffer_size = limits.limits.http_read_buffer_size,
            .write_buffer_size = limits.limits.http_write_buffer_size,
        };
        defer client.deinit();

        var writer_state: std.Io.Writer = .fixed(&operation.response_buffer);
        const writer: *std.Io.Writer = &writer_state;

        // Trace the request before issuing it. Why pre-call: if the call
        // hangs, the trace line is the only signal an operator gets that
        // we even tried this URL.
        util_output.trace("GET {any}", .{self.uri});

        var redirect_buffer: [limits.limits.http_redirect_buffer_size]u8 = undefined;
        const result = safe_fetch(&client, .{
            .location = .{ .uri = self.uri },
            .method = .GET,
            .headers = self.headers,
            .redirect_buffer = &redirect_buffer,
            .decompress_buffer = operation.decompress_slice(),
            .response_writer = writer,
        }) catch |err| {
            if (signals.requested()) return error.Interrupted;
            return err;
        };
        try signals.check();
        try writer.flush();

        util_output.trace("response status={d} bytes={d}", .{
            @intFromEnum(result.status),
            writer_state.buffered().len,
        });

        if (result.status != .ok) {
            log.err("HTTP request failed with status: {}", .{result.status});
            return error.HttpRequestFailed;
        }

        const bytes_read = writer_state.buffered().len;
        if (bytes_read == 0) {
            log.err("HTTP response is empty for URL: {any}", .{self.uri});
            return error.EmptyResponse;
        }

        if (bytes_read >= operation.response_buffer.len) {
            log.err("HTTP response too large: exceeds maximum size of {d} bytes for URL: {any}", .{
                limits.limits.http_response_size_maximum,
                self.uri,
            });
            return error.ResponseTooLarge;
        }

        return operation.response_buffer[0..bytes_read];
    }
};

const DownloadTask = struct {
    ctx: *context.CliContext,
    uri: std.Uri,
    headers: std.http.Client.Request.Headers,
    dest_file: std.Io.File,
    progress_node: std.Progress.Node,

    const Payload = void;

    fn run(self: DownloadTask) anyerror!Payload {
        _ = self.progress_node;
        try signals.check();

        var http_scratch = try self.ctx.scratch(.http);
        defer http_scratch.release();
        const operation = http_scratch.operation();

        var scratch_fba = std.heap.FixedBufferAllocator.init(operation.scratch_slice());
        var client = std.http.Client{
            .allocator = scratch_fba.allocator(),
            .io = self.ctx.io,
            .connection_pool = .{ .free_size = 0 },
            .read_buffer_size = limits.limits.http_read_buffer_size,
            .write_buffer_size = limits.limits.http_write_buffer_size,
        };
        defer client.deinit();

        var writer_buffer: [8192]u8 = undefined;
        var writer = self.dest_file.writer(self.ctx.io, &writer_buffer);
        var interrupt_writer_buffer: [8192]u8 = undefined;
        var interrupt_writer = InterruptWriter.init(&writer.interface, &interrupt_writer_buffer);

        util_output.trace("GET {any} (download)", .{self.uri});

        var redirect_buffer: [limits.limits.http_redirect_buffer_size]u8 = undefined;
        const result = safe_fetch(&client, .{
            .location = .{ .uri = self.uri },
            .method = .GET,
            .headers = self.headers,
            .redirect_buffer = &redirect_buffer,
            .decompress_buffer = operation.decompress_slice(),
            .response_writer = &interrupt_writer.writer,
        }) catch |err| {
            if (signals.requested()) return error.Interrupted;
            return err;
        };

        util_output.trace("response status={d}", .{@intFromEnum(result.status)});

        if (result.status != .ok) {
            log.err("HTTP request failed with status: {}", .{result.status});
            return error.HttpRequestFailed;
        }

        interrupt_writer.writer.flush() catch |err| {
            if (signals.requested()) return error.Interrupted;
            return err;
        };
    }
};

fn safe_fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) anyerror!std.http.Client.FetchResult {
    const uri = switch (options.location) {
        .url => |url| try std.Uri.parse(url),
        .uri => |parsed| parsed,
    };
    const method: std.http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;
    const redirect_behavior: std.http.Client.Request.RedirectBehavior = options.redirect_behavior orelse
        if (options.payload == null) @enumFromInt(3) else .unhandled;

    var request = try std.http.Client.request(client, method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer request.deinit();

    if (options.payload) |payload| {
        request.transfer_encoding = .{ .content_length = payload.len };
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }

    const redirect_buffer: []u8 = if (redirect_behavior == .unhandled)
        &.{}
    else
        options.redirect_buffer orelse try client.allocator.alloc(u8, 8 * 1024);
    defer if (options.redirect_buffer == null and redirect_behavior != .unhandled) {
        client.allocator.free(redirect_buffer);
    };

    var response = try request.receiveHead(redirect_buffer);

    const response_writer = options.response_writer orelse {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
        return .{ .status = response.head.status };
    };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (options.decompress_buffer == null and response.head.content_encoding != .identity) {
        client.allocator.free(decompress_buffer);
    };

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |stream_err| return stream_err,
    };

    return .{ .status = response.head.status };
}

const InterruptWriter = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,

    fn init(out: *std.Io.Writer, buffer: []u8) InterruptWriter {
        assert(buffer.len > 0);
        return .{
            .out = out,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
            },
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *InterruptWriter = @alignCast(@fieldParentPtr("writer", writer));
        if (signals.requested()) return error.WriteFailed;
        const buffered = writer.buffered();
        const written_total = try self.out.writeSplatHeader(buffered, data, splat);
        if (written_total < writer.end) {
            const remaining = writer.buffer[written_total..writer.end];
            @memmove(writer.buffer[0..remaining.len], remaining);
            writer.end = remaining.len;
            if (signals.requested()) return error.WriteFailed;
            return 0;
        }

        const written = written_total - writer.end;
        writer.end = 0;
        if (signals.requested()) return error.WriteFailed;
        return written;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *InterruptWriter = @alignCast(@fieldParentPtr("writer", writer));
        if (signals.requested()) return error.WriteFailed;
        try self.out.writeAll(writer.buffered());
        writer.end = 0;
        try self.out.flush();
        if (signals.requested()) return error.WriteFailed;
    }
};

test "adapted fixed buffer writer flushes into the backing stream" {
    var response_buffer: [64]u8 = undefined;
    var writer_state: std.Io.Writer = .fixed(&response_buffer);
    const writer: *std.Io.Writer = &writer_state;

    try writer.writeAll("hello");
    try writer.flush();

    try std.testing.expectEqual(@as(usize, 5), writer_state.buffered().len);
    try std.testing.expectEqualStrings("hello", writer_state.buffered());
}

test "default total timeout is used when env var unset" {
    // The util_tool environment_map starts unset in tests, so this returns
    // the compile-time default and exercises the success path.
    const seconds = read_total_timeout_seconds();
    try std.testing.expectEqual(timeout_total_default_seconds, seconds);
}
