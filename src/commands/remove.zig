const std = @import("std");
const context = @import("../Context.zig");
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
}
