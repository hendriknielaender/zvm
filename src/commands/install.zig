const std = @import("std");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const install = @import("../core/install.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.InstallCommand,
    progress_node: std.Progress.Node,
) !void {
    const version_str = command.get_version();
    try install.install(ctx, version_str, command.tool == .zls, progress_node);
}
