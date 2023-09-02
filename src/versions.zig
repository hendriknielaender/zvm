const std = @import("std");

const GitHubReleaseResponse = struct {
    tag_name: ?[]const u8,
};

pub fn list(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    const url = "https://api.github.com/repos/ziglang/zig/releases";
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

    // Read the response body 256kb buffer allocation
    var buffer: [262144]u8 = undefined; // 256 * 1024 = 262kb
    const read_len = try req.readAll(buffer[0..]);

    // Parse the JSON data into parsed_data
    const parsed_data = try std.json.parseFromSlice([]GitHubReleaseResponse, allocator, buffer[0..read_len], .{ .ignore_unknown_fields = true });
    const releases = parsed_data.value;

    var tagNames = std.ArrayList([]const u8).init(allocator);

    for (releases) |release| {
        if (release.tag_name) |tag| {
            try tagNames.append(tag);
        }
    }

    return tagNames;
}
