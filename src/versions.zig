const std = @import("std");

// TODO: The url should be stored in a separate config file
const url = "https://ziglang.org/download/index.json";

const uri = std.Uri.parse(url) catch unreachable;

pub const VersionList = struct {
    const List = std.ArrayList([]const u8);
    lists: List,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !VersionList {
        // Initialize HTTP client
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        // Read the response body with 256kb buffer allocation
        var buffer: [262144]u8 = undefined; // 256 * 1024 = 262kb

        // Make the HTTP request
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buffer });
        defer req.deinit();

        // send http request
        try req.send();

        // wait response
        try req.wait();

        // Check if request was successful
        if (req.response.status != .ok)
            return error.ListResponseNotOk;

        const len = try req.readAll(buffer[0..]);

        const json = try std.json.parseFromSlice(std.json.Value, allocator, buffer[0..len], .{});
        defer json.deinit();
        const root = json.value;

        // Initialize array list to hold versions
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

    pub fn slice(self: *VersionList) [][]const u8 {
        return self.lists.items;
    }

    pub fn deinit(self: *VersionList) void {
        defer self.lists.deinit();
        for (self.lists.items) |value| {
            self.allocator.free(value);
        }
    }
};
