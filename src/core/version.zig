const std = @import("std");
const build_options = @import("options");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.VersionCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = command;
    _ = progress_node;

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "name", .value = .{ .string = "zvm" } },
            .{ .key = "version", .value = .{ .string = build_options.version } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.info("zvm {s}\n", .{build_options.version});
}

pub fn progress_items(command: validation.ValidatedCommand.VersionCommand) u16 {
    _ = command;
    return 0;
}
