const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const util_color = @import("../util/color.zig");
const validation = @import("../cli/validation.zig");
const config = @import("../metadata.zig");
const http_client = @import("../io/http_client.zig");
const meta = @import("../core/meta.zig");
const object_pools = @import("../memory/object_pools.zig");
const limits = @import("../memory/limits.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListRemoteCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var color = util_color.Color.RuntimeStyle.init();

    const meta_url = if (command.tool == .zls) config.zls_url else config.zig_url;
    const res = try http_client.HttpClient.fetch(ctx, meta_url, .{});

    var version_entries_storage: [limits.limits.versions_maximum]*object_pools.VersionEntry = undefined;
    const max_entries = 100;
    var entries_count: usize = 0;

    while (entries_count < max_entries) : (entries_count += 1) {
        version_entries_storage[entries_count] = try ctx.acquire_version_entry();
    }

    defer {
        for (version_entries_storage[0..entries_count]) |entry| {
            entry.reset();
        }
    }

    const version_count = if (command.tool == .zls) blk: {
        var zls_meta = try meta.Zls.init(res, ctx.get_json_allocator());
        defer zls_meta.deinit();
        break :blk try zls_meta.get_version_list(version_entries_storage[0..entries_count]);
    } else blk: {
        var zig_meta = try meta.Zig.init(res, ctx.get_json_allocator());
        defer zig_meta.deinit();
        break :blk try zig_meta.get_version_list(version_entries_storage[0..entries_count]);
    };

    if (command.tool == .zls) {
        try color.bold().white().print("Available ZLS versions:\n", .{});
    } else {
        try color.bold().white().print("Available Zig versions:\n", .{});
    }

    for (version_entries_storage[0..version_count]) |entry| {
        const version = entry.get_name();
        try color.green().print("  {s}\n", .{version});
    }
}
