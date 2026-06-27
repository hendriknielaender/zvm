const std = @import("std");
const metadata = @import("../metadata.zig");
const limits = @import("../memory/limits.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.community_mirrors);

pub const max = limits.limits.community_mirrors_maximum;

pub const UrlList = struct {
    urls: [max][limits.limits.url_length_maximum]u8,
    lengths: [max]u32,
    count: u32,

    pub fn init() UrlList {
        return .{
            .urls = undefined,
            .lengths = std.mem.zeroes([max]u32),
            .count = 0,
        };
    }

    pub fn append(self: *UrlList, url: []const u8) !void {
        assert(url.len > 0);
        assert(url.len <= limits.limits.url_length_maximum);

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

        var url_buffer: [limits.limits.url_length_maximum]u8 = undefined;
        @memcpy(url_buffer[0..a_len], self.urls[ai][0..a_len]);
        @memcpy(self.urls[ai][0..b_len], self.urls[bi][0..b_len]);
        @memcpy(self.urls[bi][0..a_len], url_buffer[0..a_len]);
        self.lengths[ai] = b_len;
        self.lengths[bi] = a_len;
    }
};

pub fn parse_list(mirror_list: []const u8, out: *UrlList) !void {
    assert(out.count == 0);

    if (mirror_list.len == 0) return error.EmptyMirrorList;
    if (mirror_list[mirror_list.len - 1] != '\n') return error.InvalidMirrorList;

    var line_start: usize = 0;
    var line_count: u32 = 0;
    while (line_start < mirror_list.len) {
        const newline_index = std.mem.indexOfScalarPos(u8, mirror_list, line_start, '\n') orelse
            unreachable;
        const mirror_url = mirror_list[line_start..newline_index];
        line_start = newline_index + 1;
        line_count += 1;

        try validate_mirror_url(mirror_url);

        if (out.count >= max) {
            log.warn("Ignoring community mirrors after first {d}", .{max});
            break;
        }
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
    assert(mirror_url.len < limits.limits.url_length_maximum / 2);
    assert(file_name.len > 0);
    assert(file_name.len < limits.limits.path_length_maximum);

    const uri_str = try buffer.set(
        if (mirror_url[mirror_url.len - 1] == '/')
            try std.fmt.bufPrint(buffer.slice(), "{s}{s}?{s}", .{ mirror_url, file_name, metadata.mirror_source_query })
        else
            try std.fmt.bufPrint(buffer.slice(), "{s}/{s}?{s}", .{ mirror_url, file_name, metadata.mirror_source_query }),
    );

    assert(uri_str.len > 0);
    assert(uri_str.len <= limits.limits.url_length_maximum);
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
    assert(uri_str.len <= limits.limits.url_length_maximum);
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

const TestBuffer = struct {
    data: [limits.limits.url_length_maximum]u8,
    used: u32,

    fn init() TestBuffer {
        return .{
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

        @memcpy(self.data[0..value.len], value);
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
