const std = @import("std");
const context = @import("../Context.zig");
const metadata = @import("../metadata.zig");
const http_client = @import("../io/http_client.zig");
const community_mirrors = @import("community_mirrors.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const assert = std.debug.assert;

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListMirrorsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = command;
    _ = progress_node;

    const mirror_uri = std.Uri.parse(metadata.zig_community_mirrors_url) catch unreachable;
    const mirror_list = try http_client.HttpClient.fetch(ctx, mirror_uri, .{});
    var mirrors = community_mirrors.UrlList.init();
    try community_mirrors.parse_list(mirror_list, &mirrors);

    var mirror_urls_buffer: [community_mirrors.max][]const u8 = undefined;
    const mirror_urls = mirrors.slice(&mirror_urls_buffer);

    if (util_output.output_mode() == .machine_json) {
        util_output.emit_json(.{ .string_array = .{ .field_name = .mirrors, .items = mirror_urls } });
        return;
    }

    if (util_output.output_mode() == .plain) {
        var line_buffer: [512]u8 = undefined;
        for (mirror_urls, 0..) |url, index| {
            assert(index < 1024);
            assert(url.len > 0);
            const line = std.fmt.bufPrint(
                &line_buffer,
                "{d}\t{s}",
                .{ index, url },
            ) catch continue;
            util_output.emit_json(.{ .text = line });
        }
        return;
    }

    util_output.emit(.info, "Available community download mirrors:\n", .{});
    for (mirror_urls, 0..) |url, index| {
        util_output.emit(.info, "  {d}: {s}\n", .{ index, url });
    }
    util_output.emit(.info, "Usage: ZVM_MIRROR=<index> zvm install <version>\n", .{});
    util_output.emit(.info, "Example: ZVM_MIRROR=1 zvm install master\n", .{});
}

pub fn progress_items(command: validation.ValidatedCommand.ListMirrorsCommand) u16 {
    _ = command;
    return 0;
}
