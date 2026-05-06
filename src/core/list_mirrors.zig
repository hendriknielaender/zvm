const std = @import("std");
const context = @import("../Context.zig");
const metadata = @import("../metadata.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const assert = std.debug.assert;

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListMirrorsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = command;
    _ = progress_node;
    if (util_output.output_mode() == .machine_json) {
        var mirror_urls: [metadata.zig_mirrors.len][]const u8 = undefined;
        for (metadata.zig_mirrors, 0..) |mirror_info, index| {
            mirror_urls[index] = mirror_info[0];
        }
        util_output.emit_json(.{ .string_array = .{ .field_name = .mirrors, .items = mirror_urls[0..metadata.zig_mirrors.len] } });
        return;
    }

    if (util_output.output_mode() == .plain) {
        var line_buffer: [512]u8 = undefined;
        for (metadata.zig_mirrors, 0..) |mirror_info, index| {
            assert(index < 1024);
            const url = mirror_info[0];
            const maintainer = mirror_info[1];
            assert(url.len > 0);
            assert(maintainer.len > 0);
            const line = std.fmt.bufPrint(
                &line_buffer,
                "{d}\t{s}\t{s}",
                .{ index, url, maintainer },
            ) catch continue;
            util_output.emit_json(.{ .text = line });
        }
        return;
    }

    util_output.emit(.info, "Available download mirrors:\n", .{});
    for (metadata.zig_mirrors, 0..) |mirror_info, index| {
        const url = mirror_info[0];
        const maintainer = mirror_info[1];
        util_output.emit(.info, "  {d}: {s} ({s})\n", .{ index, url, maintainer });
    }
    util_output.emit(.info, "Usage: ZVM_MIRROR=<index> zvm install <version>\n", .{});
    util_output.emit(.info, "Example: ZVM_MIRROR=1 zvm install master\n", .{});
}

pub fn progress_items(command: validation.ValidatedCommand.ListMirrorsCommand) u16 {
    _ = command;
    return 0;
}
