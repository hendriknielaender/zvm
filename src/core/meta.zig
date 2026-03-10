//! Zero-heap metadata parsing for Zig and ZLS release indexes.
const std = @import("std");
const config = @import("../metadata.zig");
const limits = @import("../memory/limits.zig");
const util_tool = @import("../util/tool.zig");
const object_pools = @import("../memory/object_pools.zig");
const assert = std.debug.assert;

const Token = std.json.Token;
const TokenType = std.json.TokenType;

const scanner_depth_max: usize = 16;
const scanner_stack_buffer_size: usize = 256;
const scanner_token_buffer_size: usize = limits.limits.url_length_maximum;

pub const Zig = struct {
    pub const VersionData = struct {
        version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined,
        version_len: u32 = 0,
        date_buffer: [32]u8 = undefined,
        date_len: u32 = 0,
        tarball_buffer: [limits.limits.url_length_maximum]u8 = undefined,
        tarball_len: u32 = 0,
        shasum: [64]u8 = undefined,
        size: u64 = 0,

        pub fn init(target: *VersionData, requested_version: []const u8) !void {
            assert(requested_version.len > 0);
            target.* = .{};
            _ = try copy_into_buffer(target.version_buffer[0..], requested_version);
            target.version_len = @intCast(requested_version.len);
        }

        pub fn version(self: *const VersionData) []const u8 {
            assert(self.version_len > 0);
            return self.version_buffer[0..self.version_len];
        }

        pub fn date(self: *const VersionData) []const u8 {
            assert(self.date_len > 0);
            return self.date_buffer[0..self.date_len];
        }

        pub fn tarball(self: *const VersionData) []const u8 {
            assert(self.tarball_len > 0);
            return self.tarball_buffer[0..self.tarball_len];
        }
    };

    pub fn get_version_data(
        raw: []const u8,
        version: []const u8,
        platform_str: []const u8,
    ) !?VersionData {
        var scanner: TokenScanner = undefined;
        try scanner.init(raw);
        defer scanner.deinit();

        try scanner.expect_object_begin();
        while (true) {
            switch (try scanner.peek_token_type()) {
                .object_end => {
                    try scanner.expect_object_end();
                    return null;
                },
                .string => {
                    var version_key_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const version_key = try scanner.next_string(version_key_buffer[0..]);
                    if (util_tool.eql_str(version_key, version)) {
                        return try parse_zig_version_entry(&scanner, version, platform_str);
                    }
                    try scanner.skip_value();
                },
                else => return error.UnexpectedToken,
            }
        }
    }

    pub fn get_version_list(
        raw: []const u8,
        version_entries: []*object_pools.VersionEntry,
    ) !usize {
        var scanner: TokenScanner = undefined;
        try scanner.init(raw);
        defer scanner.deinit();

        try scanner.expect_object_begin();
        var version_count: usize = 0;
        while (true) {
            switch (try scanner.peek_token_type()) {
                .object_end => {
                    try scanner.expect_object_end();
                    return version_count;
                },
                .string => {
                    var version_key_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const version_key = try scanner.next_string(version_key_buffer[0..]);
                    if (version_count < version_entries.len) {
                        try version_entries[version_count].set_name(version_key);
                        version_count += 1;
                    }
                    try scanner.skip_value();
                },
                else => return error.UnexpectedToken,
            }
        }
    }
};

pub const Zls = struct {
    pub const VersionData = struct {
        version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined,
        version_len: u32 = 0,
        id: u64 = 0,
        tarball_buffer: [limits.limits.url_length_maximum]u8 = undefined,
        tarball_len: u32 = 0,
        size: u64 = 0,

        pub fn init(target: *VersionData, version_text: []const u8) !void {
            assert(version_text.len > 0);
            target.* = .{};
            _ = try copy_into_buffer(target.version_buffer[0..], version_text);
            target.version_len = @intCast(version_text.len);
        }

        pub fn version(self: *const VersionData) []const u8 {
            assert(self.version_len > 0);
            return self.version_buffer[0..self.version_len];
        }

        pub fn tarball(self: *const VersionData) []const u8 {
            assert(self.tarball_len > 0);
            return self.tarball_buffer[0..self.tarball_len];
        }
    };

    pub fn get_version_data(
        raw: []const u8,
        version: []const u8,
        platform_str: []const u8,
    ) !?VersionData {
        var asset_name_buffer: [limits.limits.path_length_maximum]u8 = undefined;
        const asset_name = try std.fmt.bufPrint(
            &asset_name_buffer,
            "zls-{s}.{s}",
            .{ platform_str, config.archive_ext },
        );

        var scanner: TokenScanner = undefined;
        try scanner.init(raw);
        defer scanner.deinit();

        try scanner.expect_array_begin();
        while (true) {
            switch (try scanner.peek_token_type()) {
                .array_end => {
                    try scanner.expect_array_end();
                    return null;
                },
                .object_begin => {
                    if (try parse_zls_release(&scanner, version, asset_name)) |version_data| {
                        return version_data;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
    }

    pub fn get_version_list(
        raw: []const u8,
        version_entries: []*object_pools.VersionEntry,
    ) !usize {
        var scanner: TokenScanner = undefined;
        try scanner.init(raw);
        defer scanner.deinit();

        try scanner.expect_array_begin();
        var version_count: usize = 0;
        while (true) {
            switch (try scanner.peek_token_type()) {
                .array_end => {
                    try scanner.expect_array_end();
                    return version_count;
                },
                .object_begin => {
                    var tag_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const tag_name = try parse_zls_tag_name(&scanner, tag_buffer[0..]);
                    if (tag_name) |tag| {
                        if (version_count < version_entries.len) {
                            try version_entries[version_count].set_name(tag);
                            version_count += 1;
                        }
                    }
                },
                else => return error.UnexpectedToken,
            }
        }
    }
};

const TokenScanner = struct {
    scanner: std.json.Scanner,
    scanner_fba: std.heap.FixedBufferAllocator,
    token_fba: std.heap.FixedBufferAllocator,
    scanner_stack_buffer: [scanner_stack_buffer_size]u8,
    token_buffer: [scanner_token_buffer_size]u8,

    fn init(target: *TokenScanner, raw: []const u8) !void {
        assert(raw.len > 0);

        target.scanner_stack_buffer = undefined;
        target.token_buffer = undefined;
        target.scanner_fba = std.heap.FixedBufferAllocator.init(&target.scanner_stack_buffer);
        target.token_fba = std.heap.FixedBufferAllocator.init(&target.token_buffer);
        target.scanner = std.json.Scanner.initCompleteInput(target.scanner_fba.allocator(), raw);
        try target.scanner.ensureTotalStackCapacity(scanner_depth_max);
    }

    fn deinit(self: *TokenScanner) void {
        self.scanner.deinit();
    }

    fn peek_token_type(self: *TokenScanner) !TokenType {
        return try self.scanner.peekNextTokenType();
    }

    fn expect_object_begin(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .object_begin => return,
            else => return error.UnexpectedToken,
        }
    }

    fn expect_object_end(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .object_end => return,
            else => return error.UnexpectedToken,
        }
    }

    fn expect_array_begin(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .array_begin => return,
            else => return error.UnexpectedToken,
        }
    }

    fn expect_array_end(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .array_end => return,
            else => return error.UnexpectedToken,
        }
    }

    fn next_string(self: *TokenScanner, buffer: []u8) ![]const u8 {
        switch (try self.next_token()) {
            .string => |value| return try copy_into_buffer(buffer, value),
            .allocated_string => |value| return try copy_into_buffer(buffer, value),
            else => return error.UnexpectedToken,
        }
    }

    fn next_u64(self: *TokenScanner) !u64 {
        switch (try self.next_token()) {
            .number => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .allocated_number => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .string => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .allocated_string => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            else => return error.UnexpectedToken,
        }
    }

    fn next_token(self: *TokenScanner) !Token {
        self.token_fba.reset();
        return try self.scanner.nextAllocMax(
            self.token_fba.allocator(),
            .alloc_if_needed,
            scanner_token_buffer_size,
        );
    }

    fn skip_value(self: *TokenScanner) !void {
        return try self.scanner.skipValue();
    }
};

fn parse_zig_version_entry(
    scanner: *TokenScanner,
    version: []const u8,
    platform_str: []const u8,
) !?Zig.VersionData {
    var version_data: Zig.VersionData = undefined;
    try Zig.VersionData.init(&version_data, version);

    try scanner.expect_object_begin();
    var has_date = false;
    var has_tarball = false;
    var has_shasum = false;
    var has_size = false;
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "date")) {
                    has_date = true;
                    version_data.date_len = @intCast((try scanner.next_string(version_data.date_buffer[0..])).len);
                } else if (util_tool.eql_str(key, "version")) {
                    version_data.version_len = @intCast((try scanner.next_string(version_data.version_buffer[0..])).len);
                } else if (util_tool.eql_str(key, platform_str)) {
                    const found = try parse_zig_platform_entry(scanner, &version_data, &has_tarball, &has_shasum, &has_size);
                    assert(found);
                } else {
                    try scanner.skip_value();
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try scanner.expect_object_end();

    if (!has_date) return null;
    if (!has_tarball) return null;
    if (!has_shasum) return null;
    if (!has_size) return null;
    return version_data;
}

fn parse_zig_platform_entry(
    scanner: *TokenScanner,
    version_data: *Zig.VersionData,
    has_tarball: *bool,
    has_shasum: *bool,
    has_size: *bool,
) !bool {
    try scanner.expect_object_begin();
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "tarball")) {
                    has_tarball.* = true;
                    version_data.tarball_len = @intCast((try scanner.next_string(version_data.tarball_buffer[0..])).len);
                } else if (util_tool.eql_str(key, "shasum")) {
                    const shasum = try scanner.next_string(version_data.shasum[0..]);
                    if (shasum.len != version_data.shasum.len) return error.InvalidData;
                    has_shasum.* = true;
                } else if (util_tool.eql_str(key, "size")) {
                    version_data.size = try scanner.next_u64();
                    has_size.* = true;
                } else {
                    try scanner.skip_value();
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try scanner.expect_object_end();
    return true;
}

fn parse_zls_release(
    scanner: *TokenScanner,
    version: []const u8,
    asset_name: []const u8,
) !?Zls.VersionData {
    var version_data: Zls.VersionData = undefined;
    try Zls.VersionData.init(&version_data, version);

    try scanner.expect_object_begin();
    var release_matches = false;
    var asset_matches = false;
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "tag_name")) {
                    var tag_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const tag_name = try scanner.next_string(tag_buffer[0..]);
                    release_matches = util_tool.eql_str(version, tag_name);
                } else if (util_tool.eql_str(key, "assets")) {
                    asset_matches = try parse_zls_assets(scanner, asset_name, &version_data);
                } else {
                    try scanner.skip_value();
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try scanner.expect_object_end();

    if (!release_matches) return null;
    if (!asset_matches) return null;
    return version_data;
}

fn parse_zls_assets(
    scanner: *TokenScanner,
    asset_name: []const u8,
    version_data: *Zls.VersionData,
) !bool {
    try scanner.expect_array_begin();
    while (true) {
        switch (try scanner.peek_token_type()) {
            .array_end => {
                try scanner.expect_array_end();
                return false;
            },
            .object_begin => {
                if (try parse_zls_asset(scanner, asset_name, version_data)) {
                    try skip_remaining_array(scanner);
                    return true;
                }
            },
            else => return error.UnexpectedToken,
        }
    }
}

fn parse_zls_asset(
    scanner: *TokenScanner,
    asset_name: []const u8,
    version_data: *Zls.VersionData,
) !bool {
    try scanner.expect_object_begin();
    var name_matches = false;
    var has_id = false;
    var has_tarball = false;
    var has_size = false;
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "name")) {
                    var name_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                    const name = try scanner.next_string(name_buffer[0..]);
                    name_matches = util_tool.eql_str(asset_name, name);
                } else if (util_tool.eql_str(key, "browser_download_url")) {
                    version_data.tarball_len = @intCast((try scanner.next_string(version_data.tarball_buffer[0..])).len);
                    has_tarball = true;
                } else if (util_tool.eql_str(key, "id")) {
                    version_data.id = try scanner.next_u64();
                    has_id = true;
                } else if (util_tool.eql_str(key, "size")) {
                    version_data.size = try scanner.next_u64();
                    has_size = true;
                } else {
                    try scanner.skip_value();
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try scanner.expect_object_end();

    if (!name_matches) return false;
    if (!has_id) return false;
    if (!has_tarball) return false;
    if (!has_size) return false;
    return true;
}

fn parse_zls_tag_name(scanner: *TokenScanner, target_buffer: []u8) !?[]const u8 {
    try scanner.expect_object_begin();
    var tag_name: ?[]const u8 = null;
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "tag_name")) {
                    tag_name = try scanner.next_string(target_buffer);
                } else {
                    try scanner.skip_value();
                }
            },
            else => return error.UnexpectedToken,
        }
    }
    try scanner.expect_object_end();
    return tag_name;
}

fn skip_remaining_array(scanner: *TokenScanner) !void {
    while (true) {
        switch (try scanner.peek_token_type()) {
            .array_end => {
                try scanner.expect_array_end();
                return;
            },
            else => try scanner.skip_value(),
        }
    }
}

fn copy_into_buffer(target: []u8, source: []const u8) ![]const u8 {
    assert(target.len > 0);
    if (source.len > target.len) return error.BufferTooSmall;
    @memcpy(target[0..source.len], source);
    return target[0..source.len];
}

test "zig metadata parser extracts a version entry without heap allocation" {
    const raw =
        \\{
        \\  "0.13.0": {
        \\    "date": "2024-06-07",
        \\    "aarch64-macos": {
        \\      "tarball": "https://ziglang.org/download/0.13.0/zig-aarch64-macos-0.13.0.tar.xz",
        \\      "shasum": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        \\      "size": "12345"
        \\    }
        \\  }
        \\}
    ;

    const version_data = try Zig.get_version_data(raw, "0.13.0", "aarch64-macos") orelse {
        return error.ExpectedVersionData;
    };

    try std.testing.expectEqualStrings("0.13.0", version_data.version());
    try std.testing.expectEqualStrings("2024-06-07", version_data.date());
    try std.testing.expectEqualStrings(
        "https://ziglang.org/download/0.13.0/zig-aarch64-macos-0.13.0.tar.xz",
        version_data.tarball(),
    );
    try std.testing.expectEqual(@as(u64, 12345), version_data.size);
}

test "zls metadata parser handles assets before tag names" {
    const raw =
        \\[
        \\  {
        \\    "assets": [
        \\      {
        \\        "name": "zls-aarch64-macos.tar.xz",
        \\        "browser_download_url": "https://example.com/zls-aarch64-macos.tar.xz",
        \\        "id": 42,
        \\        "size": 2048
        \\      }
        \\    ],
        \\    "tag_name": "0.13.0"
        \\  }
        \\]
    ;

    const version_data = try Zls.get_version_data(raw, "0.13.0", "aarch64-macos") orelse {
        return error.ExpectedVersionData;
    };

    try std.testing.expectEqualStrings("0.13.0", version_data.version());
    try std.testing.expectEqualStrings(
        "https://example.com/zls-aarch64-macos.tar.xz",
        version_data.tarball(),
    );
    try std.testing.expectEqual(@as(u64, 42), version_data.id);
    try std.testing.expectEqual(@as(u64, 2048), version_data.size);
}
