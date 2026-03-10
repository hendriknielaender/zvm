const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");
const remove = @import("../core/remove.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.RemoveCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    const version_str = command.get_version();
    try remove.remove(ctx, version_str, command.tool == .zls, false);

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "tool", .value = .{ .string = command.tool.to_string() } },
            .{ .key = "version", .value = .{ .string = version_str } },
            .{ .key = "status", .value = .{ .string = "removed" } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.success("Removed {s} version {s}", .{ command.tool.to_string(), version_str });
}
