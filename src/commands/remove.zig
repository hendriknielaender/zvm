const std = @import("std");
const context = @import("../context.zig");
const validation = @import("../validation.zig");
const limits = @import("../limits.zig");
const remove = @import("../remove.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.RemoveCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
    const version_str = try command.version.to_string(&version_buffer);
    try remove.remove(ctx, version_str, command.tool == .zls, false);
}
