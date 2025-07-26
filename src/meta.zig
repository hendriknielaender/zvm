//! This file is used to parse the json information of zig and zls
//! The json of zig comes from the official website
//! The json of zls comes from the official github api
//! We can get version list and version data
const std = @import("std");
const config = @import("config.zig");
const util_tool = @import("util/tool.zig");
const object_pools = @import("object_pools.zig");
const limits = @import("limits.zig");

const json = std.json;
const Allocator = std.mem.Allocator;
const jsonValue = std.json.Parsed(std.json.Value);

pub const Zig = struct {
    data: jsonValue,

    /// version data for zig
    pub const VersionData = struct {
        version: []const u8,
        date: []const u8,
        tarball: []const u8,
        shasum: [64]u8,
        size: usize,

        pub fn deinit(self: VersionData, allocator: Allocator) void {
            allocator.free(self.version);
            allocator.free(self.date);
            allocator.free(self.tarball);
        }
    };

    // init the zig data
    pub fn init(raw: []const u8, allocator: Allocator) !Zig {
        const data =
            try json.parseFromSlice(std.json.Value, allocator, raw, .{});

        return Zig{ .data = data };
    }

    // deinit the zig data
    pub fn deinit(self: *Zig) void {
        self.data.deinit();
    }

    pub fn get_version_data(
        self: *Zig,
        version: []const u8,
        platform_str: []const u8,
        allocator: Allocator,
    ) !?VersionData {
        // root node
        var it = self.data.value.object.iterator();

        while (it.next()) |entry| {
            if (!util_tool.eql_str(entry.key_ptr.*, version))
                continue;

            const now_version = entry.value_ptr;
            var version_info = now_version.object.iterator();

            // Initialize all fields to safe defaults
            // SAFETY: All undefined fields are either set below or the function returns null if they're not set
            var result: VersionData = .{
                .version = undefined,
                .date = undefined,
                .tarball = undefined,
                .shasum = undefined,
                .size = 0,
            };

            // Track which fields have been set
            var is_set_version = false;
            var is_set_date = false;
            var is_set_tarball = false;
            var is_set_shasum = false;
            var is_set_size = false;

            // traverse versions
            while (version_info.next()) |version_info_entry| {
                const version_info_key = version_info_entry.key_ptr.*;
                const version_info_entry_val = version_info_entry.value_ptr;

                // get version
                // only for "master" it will have "version" field
                if (util_tool.eql_str(version_info_key, "version")) {
                    result.version = try allocator.dupe(u8, version_info_entry_val.string);
                    is_set_version = true;
                } else
                // get date
                if (util_tool.eql_str(version_info_key, "date")) {
                    result.date = try allocator.dupe(
                        u8,
                        version_info_entry_val.string,
                    );
                    is_set_date = true;
                } else
                // skip the useless entry
                if (util_tool.eql_str(version_info_key, platform_str)) {
                    var platform_info = version_info_entry_val.object.iterator();

                    while (platform_info.next()) |playform_info_entry| {
                        const platform_info_entry_key = playform_info_entry.key_ptr.*;
                        const playform_info_entry_val = playform_info_entry.value_ptr;

                        // get tarball
                        if (util_tool.eql_str(platform_info_entry_key, "tarball")) {
                            result.tarball = try allocator.dupe(u8, playform_info_entry_val.string);
                            is_set_tarball = true;
                        } else
                        // get shasum
                        if (util_tool.eql_str(platform_info_entry_key, "shasum")) {
                            result.shasum = playform_info_entry_val.string[0..64].*;
                            is_set_shasum = true;
                        } else
                        // get size
                        if (util_tool.eql_str(platform_info_entry_key, "size")) {
                            const size = try std.fmt.parseUnsigned(
                                usize,
                                playform_info_entry_val.string,
                                10,
                            );
                            result.size = size;
                            is_set_size = true;
                        }
                    }
                }
            }

            if (!is_set_version)
                result.version = try allocator.dupe(u8, version);

            // Ensure all required fields are set before returning
            if (!is_set_tarball) {
                return null;
            }
            if (!is_set_shasum) {
                return null;
            }
            if (!is_set_size) {
                return null;
            }
            if (!is_set_date) {
                return null;
            }

            return result;
        }
        return null;
    }

    /// Return the version list without allocation.
    /// Caller provides a version entries array to fill.
    pub fn get_version_list(
        self: *Zig,
        version_entries: []object_pools.VersionEntry,
    ) ![][]const u8 {
        const root = self.data.value;
        var version_list: [limits.limits.versions_maximum][]const u8 = undefined;
        var version_count: usize = 0;
        var iterate = root.object.iterator();

        while (iterate.next()) |entry| {
            if (version_count >= version_entries.len) break;

            const key_ptr = entry.key_ptr;
            const key = key_ptr.*;

            // Store version name in the provided entry.
            try version_entries[version_count].set_name(key);
            version_list[version_count] = version_entries[version_count].get_name();
            version_count += 1;
        }

        return version_list[0..version_count];
    }
};

pub const Zls = struct {
    data: jsonValue,

    /// version data for zig
    pub const VersionData = struct {
        version: []const u8,
        id: usize,
        tarball: []const u8,
        size: usize,

        pub fn deinit(self: VersionData, allocator: Allocator) void {
            allocator.free(self.version);
            allocator.free(self.tarball);
        }
    };

    // init the zig data
    pub fn init(raw: []const u8, allocator: Allocator) !Zls {
        const data =
            try json.parseFromSlice(std.json.Value, allocator, raw, .{});

        return Zls{ .data = data };
    }

    // deinit the zig data
    pub fn deinit(self: *Zls) void {
        self.data.deinit();
    }

    pub fn get_version_data(
        self: *Zls,
        version: []const u8,
        platform_str: []const u8,
        allocator: Allocator,
    ) !?VersionData {
        const file_name = try std.fmt.allocPrint(
            allocator,
            "zls-{s}.{s}",
            .{ platform_str, config.archive_ext },
        );
        for (self.data.value.array.items) |item| {
            const item_obj = item.object;

            const tag = item_obj.get("tag_name") orelse continue;
            if (!util_tool.eql_str(version, tag.string)) continue;

            const assets = item_obj.get("assets") orelse continue;
            for (assets.array.items) |asset| {
                const asset_obj = asset.object;

                const name = asset_obj.get("name") orelse continue;
                if (!util_tool.eql_str(file_name, name.string)) continue;

                const tarball = asset_obj.get("browser_download_url") orelse return null;
                const id = asset_obj.get("id") orelse return null;
                const size = asset_obj.get("size") orelse return null;

                return VersionData{
                    .version = try allocator.dupe(u8, version),
                    .id = @intCast(id.integer),
                    .tarball = try allocator.dupe(u8, tarball.string),
                    .size = @intCast(size.integer),
                };
            }
            break;
        }
        return null;
    }

    /// Return the version list without allocation.
    /// Caller provides a version entries array to fill.
    pub fn get_version_list(
        self: *Zls,
        version_entries: []object_pools.VersionEntry,
    ) ![][]const u8 {
        var version_list: [limits.limits.versions_maximum][]const u8 = undefined;
        var version_count: usize = 0;

        for (self.data.value.array.items) |item| {
            if (version_count >= version_entries.len) break;

            const tag = item.object.get("tag_name") orelse continue;

            // Store version name in the provided entry.
            try version_entries[version_count].set_name(tag.string);
            version_list[version_count] = version_entries[version_count].get_name();
            version_count += 1;
        }

        return version_list[0..version_count];
    }
};
