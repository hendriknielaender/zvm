const std = @import("std");
const context = @import("../Context.zig");
const metadata = @import("../metadata.zig");
const http_client = @import("../io/http_client.zig");
const limits = @import("../memory/limits.zig");
const util_data = @import("../util/data.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.community_mirrors);

pub const max = limits.community_mirrors_maximum;
const cache_dir_name = "cache";
const cache_file_name = "community-mirrors.txt";
const cache_ttl_nanoseconds: i96 = 24 * std.time.ns_per_hour;

const CacheFreshness = enum {
    fresh,
    stale_ok,
};

pub const UrlList = struct {
    urls: [max][limits.url_length_maximum]u8,
    lengths: [max]u32,
    count: u32,

    pub fn init() UrlList {
        return .{
            // SAFETY: entries are read only through get/slice after append writes bytes and length.
            .urls = undefined,
            .lengths = std.mem.zeroes([max]u32),
            .count = 0,
        };
    }

    pub fn append(self: *UrlList, url: []const u8) !void {
        assert(url.len > 0);
        assert(url.len <= limits.url_length_maximum);

        if (self.count >= max) return error.TooManyMirrors;

        const index: usize = @intCast(self.count);
        @memcpy(self.urls[index][0..url.len], url);
        self.lengths[index] = @intCast(url.len);
        self.count += 1;

        assert(self.count > 0);
        assert(self.count <= max);
    }

    pub fn get(self: *const UrlList, index: u32) []const u8 {
        assert(index < self.count);
        const index_usize: usize = @intCast(index);
        return self.urls[index_usize][0..self.lengths[index_usize]];
    }

    pub fn slice(self: *const UrlList, out: *[max][]const u8) []const []const u8 {
        assert(self.count <= max);

        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            const index_usize: usize = @intCast(index);
            out[index_usize] = self.get(index);
        }

        const count_usize: usize = @intCast(self.count);
        return out[0..count_usize];
    }

    pub fn order(self: *UrlList, io: std.Io, preferred_mirror: ?usize) void {
        if (self.count <= 1) return;

        if (preferred_mirror) |preferred| {
            if (preferred < self.count) {
                self.swap(0, @intCast(preferred));
                self.shuffle(io, 1, self.count);
                return;
            }
            log.warn("ZVM_MIRROR index {d} is out of range for {d} community mirrors", .{
                preferred,
                self.count,
            });
        }

        self.shuffle(io, 0, self.count);
    }

    fn shuffle(self: *UrlList, io: std.Io, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= self.count);

        const count = end - start;
        if (count <= 1) return;

        var seed: u64 = 0;
        io.random(std.mem.asBytes(&seed));
        if (seed == 0) seed = 0x99a4_1dd8_031f_e273;

        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var i = count - 1;
        while (i > 0) : (i -= 1) {
            const j = random.uintLessThan(u32, i + 1);
            self.swap(start + i, start + j);
        }
    }

    fn swap(self: *UrlList, a: u32, b: u32) void {
        assert(a < self.count);
        assert(b < self.count);
        if (a == b) return;

        const ai: usize = @intCast(a);
        const bi: usize = @intCast(b);
        const a_len = self.lengths[ai];
        const b_len = self.lengths[bi];

        var url_buffer: [limits.url_length_maximum]u8 = undefined;
        @memcpy(url_buffer[0..a_len], self.urls[ai][0..a_len]);
        @memcpy(self.urls[ai][0..b_len], self.urls[bi][0..b_len]);
        @memcpy(self.urls[bi][0..a_len], url_buffer[0..a_len]);
        self.lengths[ai] = b_len;
        self.lengths[bi] = a_len;
    }
};

pub fn load(ctx: *context.CliContext, out: *UrlList) !void {
    assert(out.count == 0);

    read_cache(ctx, out, .fresh) catch {
        out.* = UrlList.init();
    };
    if (out.count > 0) return;

    const mirror_uri = std.Uri.parse(metadata.zig_community_mirrors_url) catch
        @panic("invalid community mirror URL constant");
    const mirror_list = http_client.HttpClient.fetch(ctx, mirror_uri, .{}) catch |fetch_err| {
        log.warn("Unable to refresh community mirror list: {s}", .{@errorName(fetch_err)});
        out.* = UrlList.init();
        read_cache(ctx, out, .stale_ok) catch return fetch_err;
        return;
    };

    parse_list(mirror_list, out) catch |parse_err| {
        out.* = UrlList.init();
        read_cache(ctx, out, .stale_ok) catch return parse_err;
        return;
    };
    assert(out.count > 0);

    write_cache(ctx, mirror_list) catch |cache_err| {
        log.warn("Unable to cache community mirror list: {s}", .{@errorName(cache_err)});
    };
}

pub fn parse_list(mirror_list: []const u8, out: *UrlList) !void {
    assert(out.count == 0);

    if (mirror_list.len == 0) return error.EmptyMirrorList;
    if (mirror_list[mirror_list.len - 1] != '\n') return error.InvalidMirrorList;

    var line_start: usize = 0;
    var line_count: u32 = 0;
    while (line_start < mirror_list.len) {
        if (out.count >= max) {
            log.warn("Ignoring community mirrors after first {d}", .{max});
            break;
        }

        const newline_index = std.mem.indexOfScalarPos(u8, mirror_list, line_start, '\n') orelse
            unreachable;
        const mirror_url = mirror_list[line_start..newline_index];
        line_start = newline_index + 1;
        line_count += 1;

        try validate_mirror_url(mirror_url);
        try out.append(mirror_url);
    }

    if (line_count == 0) return error.EmptyMirrorList;
}

pub fn construct_tarball_url(
    buffer: anytype,
    mirror_url: []const u8,
    file_name: []const u8,
) ![]const u8 {
    assert(mirror_url.len > 0);
    assert(mirror_url.len < limits.url_length_maximum / 2);
    assert(file_name.len > 0);
    assert(file_name.len < limits.path_length_maximum);

    const uri_str = try buffer.set(
        if (mirror_url[mirror_url.len - 1] == '/')
            try std.fmt.bufPrint(buffer.slice(), "{s}{s}?{s}", .{ mirror_url, file_name, metadata.mirror_source_query })
        else
            try std.fmt.bufPrint(buffer.slice(), "{s}/{s}?{s}", .{ mirror_url, file_name, metadata.mirror_source_query }),
    );

    assert(uri_str.len > 0);
    assert(uri_str.len <= limits.url_length_maximum);
    return uri_str;
}

pub fn construct_signature_url(buffer: anytype, tarball_url: []const u8) ![]const u8 {
    assert(tarball_url.len > 0);

    const bare_url = without_query(tarball_url);
    const uri_str = try buffer.set(if (query_string(tarball_url)) |query_text|
        try std.fmt.bufPrint(buffer.slice(), "{s}.minisig?{s}", .{ bare_url, query_text })
    else
        try std.fmt.bufPrint(buffer.slice(), "{s}.minisig", .{bare_url}));

    assert(uri_str.len > 0);
    assert(uri_str.len <= limits.url_length_maximum);
    return uri_str;
}

pub fn basename(url: []const u8) []const u8 {
    assert(url.len > 0);
    return std.fs.path.basename(without_query(url));
}

fn validate_mirror_url(mirror_url: []const u8) !void {
    if (mirror_url.len == 0) return error.InvalidMirrorList;
    if (!std.mem.startsWith(u8, mirror_url, "https://")) return error.InvalidMirrorList;
    for (mirror_url) |byte| {
        if (byte < 0x21) return error.InvalidMirrorList;
        if (byte > 0x7e) return error.InvalidMirrorList;
    }
}

fn without_query(url: []const u8) []const u8 {
    assert(url.len > 0);
    const query_index = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..query_index];
}

fn query_string(url: []const u8) ?[]const u8 {
    assert(url.len > 0);
    const query_index = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    return url[query_index + 1 ..];
}

fn read_cache(
    ctx: *context.CliContext,
    out: *UrlList,
    freshness: CacheFreshness,
) !void {
    assert(out.count == 0);

    var cache_path_buffer = try ctx.scratch(.path);
    defer cache_path_buffer.release();
    const path = try cache_path(cache_path_buffer);

    const file = try std.Io.Dir.openFileAbsolute(ctx.io, path, .{ .mode = .read_only });
    defer file.close(ctx.io);

    const stat = try file.stat(ctx.io);
    if (freshness == .fresh) {
        if (!cache_is_fresh(ctx.io, stat.mtime)) return error.StaleMirrorCache;
    }
    if (stat.size == 0) return error.EmptyMirrorList;
    if (stat.size > limits.http_response_size_maximum) return error.MirrorCacheTooLarge;

    var http_scratch = try ctx.scratch(.http);
    defer http_scratch.release();
    const operation = http_scratch.operation();
    const buffer = operation.response_slice();
    assert(stat.size <= buffer.len);

    var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
    var file_reader = file.reader(ctx.io, &reader_buffer);
    var total_read: usize = 0;
    while (total_read < stat.size) {
        const bytes_read = try file_reader.interface.readSliceShort(buffer[total_read..]);
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }

    try parse_list(buffer[0..total_read], out);
}

fn write_cache(ctx: *context.CliContext, mirror_list: []const u8) !void {
    assert(mirror_list.len > 0);
    assert(mirror_list.len <= limits.http_response_size_maximum);

    var cache_dir_buffer = try ctx.scratch(.path);
    defer cache_dir_buffer.release();
    const cache_dir_path = try util_data.get_zvm_path_segment(cache_dir_buffer, cache_dir_name);
    var cache_dir = try std.Io.Dir.cwd().createDirPathOpen(ctx.io, cache_dir_path, .{});
    defer cache_dir.close(ctx.io);

    const cache_file = try cache_dir.createFile(ctx.io, cache_file_name, .{});
    defer cache_file.close(ctx.io);
    try cache_file.writeStreamingAll(ctx.io, mirror_list);
}

fn cache_path(buffer: anytype) ![]const u8 {
    var cache_dir_buffer: [limits.path_length_maximum]u8 = undefined;
    var static_cache_dir_buffer = StaticPathBuffer.init(&cache_dir_buffer);
    const cache_dir_path = try util_data.get_zvm_path_segment(
        &static_cache_dir_buffer,
        cache_dir_name,
    );

    return try buffer.set(try std.fmt.bufPrint(
        buffer.slice(),
        "{s}/{s}",
        .{ cache_dir_path, cache_file_name },
    ));
}

fn cache_is_fresh(io: std.Io, mtime: std.Io.Timestamp) bool {
    const now = std.Io.Clock.real.now(io);
    return cache_timestamp_is_fresh(now, mtime);
}

fn cache_timestamp_is_fresh(now: std.Io.Timestamp, mtime: std.Io.Timestamp) bool {
    if (mtime.nanoseconds >= now.nanoseconds) return true;
    return now.nanoseconds - mtime.nanoseconds <= cache_ttl_nanoseconds;
}

const StaticPathBuffer = struct {
    data: []u8,
    used: u32,

    fn init(data: []u8) StaticPathBuffer {
        assert(data.len > 0);
        return .{
            .data = data,
            .used = 0,
        };
    }

    pub fn slice(self: *StaticPathBuffer) []u8 {
        return self.data;
    }

    pub fn set(self: *StaticPathBuffer, value: []const u8) ![]const u8 {
        assert(value.len > 0);
        assert(value.len <= self.data.len);

        const value_start = @intFromPtr(value.ptr);
        const value_end = value_start + value.len;
        const buffer_start = @intFromPtr(self.data.ptr);
        const buffer_end = buffer_start + self.data.len;
        if (value_start < buffer_start or value_end > buffer_end) {
            @memcpy(self.data[0..value.len], value);
        }
        self.used = @intCast(value.len);

        assert(self.used == value.len);
        return self.data[0..self.used];
    }
};

const TestBuffer = struct {
    data: [limits.url_length_maximum]u8,
    used: u32,

    fn init() TestBuffer {
        return .{
            // SAFETY: tests read only the prefix initialized by set().
            .data = undefined,
            .used = 0,
        };
    }

    fn slice(self: *TestBuffer) []u8 {
        return self.data[0..];
    }

    fn set(self: *TestBuffer, value: []const u8) ![]const u8 {
        assert(value.len > 0);
        assert(value.len <= self.data.len);

        const value_start = @intFromPtr(value.ptr);
        const value_end = value_start + value.len;
        const buffer_start = @intFromPtr(&self.data[0]);
        const buffer_end = buffer_start + self.data.len;
        if (value_start < buffer_start or value_end > buffer_end) {
            @memcpy(self.data[0..value.len], value);
        }
        self.used = @intCast(value.len);

        assert(self.used == value.len);
        return self.data[0..self.used];
    }
};

test "parse list accepts HTTPS LF separated mirrors" {
    const mirrors =
        "https://mirror-a.example/zig\n" ++
        "https://mirror-b.example/zig\n";
    var list = UrlList.init();

    try parse_list(mirrors, &list);

    try std.testing.expectEqual(@as(u32, 2), list.count);
    try std.testing.expectEqualStrings("https://mirror-a.example/zig", list.get(0));
    try std.testing.expectEqualStrings("https://mirror-b.example/zig", list.get(1));
}

test "parse list rejects non HTTPS entry" {
    var list = UrlList.init();
    try std.testing.expectError(
        error.InvalidMirrorList,
        parse_list("http://mirror.example/zig\n", &list),
    );
}

test "parse list rejects missing trailing LF" {
    var list = UrlList.init();
    try std.testing.expectError(
        error.InvalidMirrorList,
        parse_list("https://mirror.example/zig", &list),
    );
}

test "cache freshness accepts daily ttl and future mtimes" {
    const now: std.Io.Timestamp = .{ .nanoseconds = 2 * cache_ttl_nanoseconds };
    const fresh: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - cache_ttl_nanoseconds };
    const stale: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - cache_ttl_nanoseconds - 1 };
    const future: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds + 1 };

    try std.testing.expect(cache_timestamp_is_fresh(now, fresh));
    try std.testing.expect(!cache_timestamp_is_fresh(now, stale));
    try std.testing.expect(cache_timestamp_is_fresh(now, future));
}

test "basename ignores mirror source query" {
    const url = "https://mirror.example/zig-x86_64-linux-0.16.0.tar.xz?source=zvm";
    try std.testing.expectEqualStrings("zig-x86_64-linux-0.16.0.tar.xz", basename(url));
}

test "signature URL preserves source query after minisig suffix" {
    var buffer = TestBuffer.init();

    const signature_url = try construct_signature_url(
        &buffer,
        "https://mirror.example/zig-x86_64-linux-0.16.0.tar.xz?source=zvm",
    );

    try std.testing.expectEqualStrings(
        "https://mirror.example/zig-x86_64-linux-0.16.0.tar.xz.minisig?source=zvm",
        signature_url,
    );
}

test "signature URL appends minisig without query" {
    var buffer = TestBuffer.init();

    const signature_url = try construct_signature_url(
        &buffer,
        "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz",
    );

    try std.testing.expectEqualStrings(
        "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz.minisig",
        signature_url,
    );
}
