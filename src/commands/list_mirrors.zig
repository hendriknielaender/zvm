const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");
const config = @import("../metadata.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListMirrorsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = command;
    _ = progress_node;

    const emitter = util_output.get_global();

    if (emitter.config.mode == .machine_json) {
        const json_mirrors_count = config.zig_mirrors.len;
        var mirror_urls: [6][]const u8 = undefined;

        for (config.zig_mirrors, 0..) |mirror_info, index| {
            mirror_urls[index] = mirror_info[0];
        }

        util_output.json_array("mirrors", mirror_urls[0..json_mirrors_count]);
    } else {
        util_output.info("Available download mirrors:\n", .{});

        for (config.zig_mirrors, 0..) |mirror_info, index| {
            const url = mirror_info[0];
            const maintainer = mirror_info[1];
            util_output.info("  {d}: {s} ({s})\n", .{ index, url, maintainer });
        }

        util_output.info("Usage: ZVM_MIRROR=<index> zvm install <version>\n", .{});
        util_output.info("Example: ZVM_MIRROR=1 zvm install master\n", .{});
    }
}
