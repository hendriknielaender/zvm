const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("std").json;

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

const Error = error{
    HttpError,
    UnsupportedVersion,
    JSONParsingFailed,
    MissingExpectedFields,
};

fn fetchVersionData(allocator: Allocator, requested_version: []const u8) !?Version {
    const url = "https://ziglang.org/download/index.json";
    const uri = std.Uri.parse(url) catch unreachable;

    // Initialize HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Make the HTTP request
    var req = try client.request(.GET, uri, .{ .allocator = allocator }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    // Check if request was successful
    try std.testing.expect(req.response.status == .ok);

    // Read the response body with 256kb buffer allocation
    var buffer: [262144]u8 = undefined; // 256 * 1024 = 262kb
    const read_len = try req.readAll(buffer[0..]);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer[0..read_len], .{});
    defer parsed.deinit();
    const root = parsed.value;

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key_ptr = entry.key_ptr;
        const key = key_ptr.*;
        std.debug.print("requested_version: {any}\n", .{requested_version});
        std.debug.print("key: {s} requested_version: {s}\n", .{ key, requested_version });

        std.debug.print("eql {}\n", .{std.mem.eql(u8, key, requested_version)});
        if (std.mem.eql(u8, key, requested_version)) {
            // Found the requested version
            // Assuming the value associated with the version key is an object containing the fields we want
            const value_ptr = entry.value_ptr;
            const value = value_ptr.*;

            const version_data = value.object;

            std.debug.print("version_data:{}", .{version_data});
            // Extract fields and populate the Version struct
            return Version{
                .name = try allocator.dupe(u8, requested_version),
                .date = try allocator.dupe(u8, ""),
                .tarball = try allocator.dupe(u8, ""),
                .shasum = try allocator.dupe(u8, ""),
            };
        }
    }
    return null;
}

pub fn fromVersion(version: []const u8) !void {
    var allocator = std.heap.page_allocator;
    const version_data = try fetchVersionData(allocator, version);
    if (version_data) |data| {
        std.debug.print("Install {s}\n", .{data.name});
    } else {
        return Error.UnsupportedVersion;
    }
}
