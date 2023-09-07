const std = @import("std");

pub fn content(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const uri = std.Uri.parse(url) catch unreachable;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{ .allocator = allocator }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);

    var download_content = std.ArrayList(u8).init(allocator);
    defer download_content.deinit();

    var buffer: [1024]u8 = undefined;
    while (true) {
        const read_len = try req.read(buffer[0..]);
        if (read_len == 0) break;
        try download_content.appendSlice(buffer[0..read_len]);
    }

    return download_content.toOwnedSlice();
}
