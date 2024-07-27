//! For getting zig version info json from offical website
const std = @import("std");
const config = @import("config.zig");

const uri = std.Uri.parse(config.download_manifest_url) catch unreachable;

pub const VersionList = struct {
    // this type will store
    const List = std.ArrayList([]const u8);

    // store the version message
    lists: List,
    allocator: std.mem.Allocator,

    /// init the VersionList
    pub fn init(allocator: std.mem.Allocator) !VersionList {
        // create a http client
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // we ceate a buffer to store the http response
        var buffer: [262144]u8 = undefined; // 256 * 1024 = 262kb

        // try open a request
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buffer });
        defer req.deinit();

        // send request and wait response
        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.ListResponseNotOk;
        }

        const len = try req.readAll(buffer[0..]);

        // parse json
        const json = try std.json.parseFromSlice(std.json.Value, allocator, buffer[0..len], .{});
        defer json.deinit();
        const root = json.value;

        var lists = std.ArrayList([]const u8).init(allocator);

        var iterate = root.object.iterator();
        while (iterate.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const key = key_ptr.*;

            const key_copy = try allocator.dupe(u8, key);
            try lists.append(key_copy);
        }

        return VersionList{
            .lists = lists,
            .allocator = allocator,
        };
    }

    // get the slice items
    pub fn slice(self: *VersionList) [][]const u8 {
        return self.lists.items;
    }

    /// deinit will free memory
    pub fn deinit(self: *VersionList) void {
        defer self.lists.deinit();
        for (self.lists.items) |value| {
            self.allocator.free(value);
        }
    }
};
