const std = @import("std");
const assert = std.debug.assert;
const context = @import("../Context.zig");
const limits = @import("../memory/limits.zig");
const util_tool = @import("../util/tool.zig");
const log = std.log.scoped(.http);

/// Name of the environment variable that overrides the per-request total
/// timeout. Documented in `commands/help.zig`.
pub const timeout_env_var_name = "ZVM_DOWNLOAD_TIMEOUT_SECONDS";

/// Default total timeout for one mirror attempt. Picked to be generous enough
/// for slow links on a 100MB tarball (~1.5 Mbit/s) but bounded so a stalled
/// mirror cannot hang `zvm install` indefinitely.
pub const timeout_total_default_seconds: u32 = 600;

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
) Task.Result {
    assert(total_seconds >= timeout_total_minimum_seconds);
    assert(total_seconds <= timeout_total_maximum_seconds);

    const Outcome = union(enum) {
        completed: Task.Result,
        timed_out: void,
    };

    var select_buffer: [2]Outcome = undefined;
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
                error.Canceled => return error.Canceled,
            };
            return switch (outcome) {
                .completed => |result| result,
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
    std.Io.sleep(io, duration, .awake) catch return;
}

const FetchTask = struct {
    ctx: *context.CliContext,
    uri: std.Uri,
    headers: std.http.Client.Request.Headers,

    const Result = anyerror![]const u8;

    fn run(self: FetchTask) Result {
        const operation = try self.ctx.acquire_http_operation();
        defer operation.release();

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

        var redirect_buffer: [limits.limits.http_redirect_buffer_size]u8 = undefined;
        const result = try client.fetch(.{
            .location = .{ .uri = self.uri },
            .method = .GET,
            .headers = self.headers,
            .redirect_buffer = &redirect_buffer,
            .decompress_buffer = operation.decompress_slice(),
            .response_writer = writer,
        });
        try writer.flush();

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

    const Result = anyerror!void;

    fn run(self: DownloadTask) Result {
        _ = self.progress_node;

        const operation = try self.ctx.acquire_http_operation();
        defer operation.release();

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

        var redirect_buffer: [limits.limits.http_redirect_buffer_size]u8 = undefined;
        const result = try client.fetch(.{
            .location = .{ .uri = self.uri },
            .method = .GET,
            .headers = self.headers,
            .redirect_buffer = &redirect_buffer,
            .decompress_buffer = operation.decompress_slice(),
            .response_writer = &writer.interface,
        });

        if (result.status != .ok) {
            log.err("HTTP request failed with status: {}", .{result.status});
            return error.HttpRequestFailed;
        }

        try writer.interface.flush();
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
