const std = @import("std");
const config = @import("../../metadata.zig");
const limits = @import("../../memory/limits.zig");
const object_pools = @import("../../memory.zig");
const scanner_mod = @import("scanner.zig");
const util_tool = @import("../../util/tool.zig");
const assert = std.debug.assert;

const TokenScanner = scanner_mod.TokenScanner;

pub const Zls = struct {
    pub const VersionData = struct {
        version_buffer: [limits.limits.version_string_length_maximum]u8 =
            std.mem.zeroes([limits.limits.version_string_length_maximum]u8),
        version_len: u32 = 0,
        id: u64 = 0,
        tarball_buffer: [limits.limits.url_length_maximum]u8 =
            std.mem.zeroes([limits.limits.url_length_maximum]u8),
        tarball_len: u32 = 0,
        size: u64 = 0,

        pub fn init(target: *VersionData, version_text: []const u8) !void {
            assert(version_text.len > 0);
            target.* = .{};
            _ = try scanner_mod.copy_into_buffer(target.version_buffer[0..], version_text);
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
                    if (try parse_release(&scanner, version, asset_name)) |version_data| {
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
                    const tag_name = try parse_tag_name(&scanner, tag_buffer[0..]);
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

fn parse_release(
    scanner: *TokenScanner,
    version: []const u8,
    asset_name: []const u8,
) !?Zls.VersionData {
    var version_data: Zls.VersionData = .{};
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
                    asset_matches = try parse_assets(scanner, asset_name, &version_data);
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

fn parse_assets(
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
                if (try parse_asset(scanner, asset_name, version_data)) {
                    try scanner_mod.skip_remaining_array(scanner);
                    return true;
                }
            },
            else => return error.UnexpectedToken,
        }
    }
}

fn parse_asset(
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
                    const tarball = try scanner.next_string(version_data.tarball_buffer[0..]);
                    version_data.tarball_len = @intCast(tarball.len);
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

fn parse_tag_name(scanner: *TokenScanner, target_buffer: []u8) !?[]const u8 {
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

test "zls metadata parser returns null for minimal release without assets" {
    const raw =
        \\[
        \\  {
        \\    "tag_name": "0.13.0",
        \\    "assets": []
        \\  }
        \\]
    ;

    const version_data = try Zls.get_version_data(raw, "0.13.0", "aarch64-macos");
    try std.testing.expect(version_data == null);
}

test "zls metadata parser rejects malformed top-level object" {
    const raw = "{}";
    try std.testing.expectError(
        error.UnexpectedToken,
        Zls.get_version_data(raw, "0.13.0", "aarch64-macos"),
    );
}
