const std = @import("std");
const limits = @import("../../memory/limits.zig");
const object_pools = @import("../../memory.zig");
const scanner_mod = @import("scanner.zig");
const util_tool = @import("../../util/tool.zig");
const assert = std.debug.assert;

const TokenScanner = scanner_mod.TokenScanner;

pub const Zig = struct {
    pub const VersionData = struct {
        version_buffer: [limits.limits.version_string_length_maximum]u8 =
            std.mem.zeroes([limits.limits.version_string_length_maximum]u8),
        version_len: u32 = 0,
        date_buffer: [32]u8 = std.mem.zeroes([32]u8),
        date_len: u32 = 0,
        tarball_buffer: [limits.limits.url_length_maximum]u8 =
            std.mem.zeroes([limits.limits.url_length_maximum]u8),
        tarball_len: u32 = 0,
        shasum: [64]u8 = std.mem.zeroes([64]u8),
        size: u64 = 0,

        pub fn init(target: *VersionData, requested_version: []const u8) !void {
            assert(requested_version.len > 0);
            target.* = .{};
            _ = try scanner_mod.copy_into_buffer(
                target.version_buffer[0..],
                requested_version,
            );
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
        assert(raw.len > 0);
        assert(version.len > 0);
        assert(version.len <= limits.limits.version_string_length_maximum);
        assert(platform_str.len > 0);

        const is_dev = util_tool.is_dev_version(version);
        const lookup_key: []const u8 = if (is_dev) "master" else version;
        assert(lookup_key.len > 0);

        var scanner: TokenScanner = undefined;
        try scanner.init(raw);
        defer scanner.deinit();

        try scanner.expect_object_begin();
        const entries_max: u32 = 4096;
        var entries_seen: u32 = 0;
        while (entries_seen < entries_max) : (entries_seen += 1) {
            switch (try scanner.peek_token_type()) {
                .object_end => {
                    try scanner.expect_object_end();
                    return null;
                },
                .string => {
                    var key_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const key = try scanner.next_string(key_buffer[0..]);
                    if (!util_tool.eql_str(key, lookup_key)) {
                        try scanner.skip_value();
                        continue;
                    }

                    const data = try parse_version_entry(&scanner, version, platform_str) orelse
                        return null;
                    if (is_dev) {
                        if (!util_tool.eql_str(data.version(), version)) return null;
                    }
                    return data;
                },
                else => return error.UnexpectedToken,
            }
        }
        return error.IndexEntryLimitExceeded;
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
                    var key_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
                    const key = try scanner.next_string(key_buffer[0..]);
                    if (version_count < version_entries.len) {
                        try version_entries[version_count].set_name(key);
                        version_count += 1;
                    }
                    try scanner.skip_value();
                },
                else => return error.UnexpectedToken,
            }
        }
    }
};

fn parse_version_entry(
    scanner: *TokenScanner,
    version: []const u8,
    platform_str: []const u8,
) !?Zig.VersionData {
    var version_data: Zig.VersionData = .{};
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
                    const date = try scanner.next_string(version_data.date_buffer[0..]);
                    version_data.date_len = @intCast(date.len);
                } else if (util_tool.eql_str(key, "version")) {
                    const parsed = try scanner.next_string(version_data.version_buffer[0..]);
                    version_data.version_len = @intCast(parsed.len);
                } else if (util_tool.eql_str(key, platform_str)) {
                    try parse_platform_entry(
                        scanner,
                        &version_data,
                        &has_tarball,
                        &has_shasum,
                        &has_size,
                    );
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

fn parse_platform_entry(
    scanner: *TokenScanner,
    version_data: *Zig.VersionData,
    has_tarball: *bool,
    has_shasum: *bool,
    has_size: *bool,
) !void {
    try scanner.expect_object_begin();
    while (true) {
        switch (try scanner.peek_token_type()) {
            .object_end => break,
            .string => {
                var key_buffer: [limits.limits.path_length_maximum]u8 = undefined;
                const key = try scanner.next_string(key_buffer[0..]);
                if (util_tool.eql_str(key, "tarball")) {
                    has_tarball.* = true;
                    const tarball = try scanner.next_string(version_data.tarball_buffer[0..]);
                    version_data.tarball_len = @intCast(tarball.len);
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

test "zig metadata parser resolves dev versions via the master entry" {
    const raw =
        \\{
        \\  "master": {
        \\    "version": "0.16.0-dev.2973+06b85a4fd",
        \\    "date": "2026-04-22",
        \\    "aarch64-macos": {
        \\      "tarball": "https://example.com/dev-2973.tar.xz",
        \\      "shasum": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        \\      "size": "12345"
        \\    }
        \\  }
        \\}
    ;

    const version_data = try Zig.get_version_data(
        raw,
        "0.16.0-dev.2973+06b85a4fd",
        "aarch64-macos",
    ) orelse return error.ExpectedVersionData;

    try std.testing.expectEqualStrings("0.16.0-dev.2973+06b85a4fd", version_data.version());
    try std.testing.expectEqualStrings(
        "https://example.com/dev-2973.tar.xz",
        version_data.tarball(),
    );
}

test "zig metadata parser rejects stale dev version when master has moved on" {
    const raw =
        \\{
        \\  "master": {
        \\    "version": "0.16.0-dev.3000+aaaaaaaaa",
        \\    "date": "2026-05-01",
        \\    "aarch64-macos": {
        \\      "tarball": "https://example.com/dev-3000.tar.xz",
        \\      "shasum": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        \\      "size": "12345"
        \\    }
        \\  }
        \\}
    ;

    const version_data = try Zig.get_version_data(
        raw,
        "0.16.0-dev.2973+06b85a4fd",
        "aarch64-macos",
    );
    try std.testing.expect(version_data == null);
}

test "zig metadata parser returns null for minimal missing platform data" {
    const raw =
        \\{
        \\  "0.13.0": {
        \\    "date": "2024-06-07"
        \\  }
        \\}
    ;

    const version_data = try Zig.get_version_data(raw, "0.13.0", "aarch64-macos");
    try std.testing.expect(version_data == null);
}

test "zig metadata parser rejects malformed top-level array" {
    const raw = "[]";
    try std.testing.expectError(
        error.UnexpectedToken,
        Zig.get_version_data(raw, "0.13.0", "aarch64-macos"),
    );
}
