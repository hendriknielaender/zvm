const std = @import("std");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");
const alias = @import("../core/alias.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.UseCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    const version_str = command.get_version();
    try alias.set_version(ctx, version_str, command.tool == .zls);
}

const testing = std.testing;

test "use command converts version to string correctly" {
    var version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;

    const master_version = validation.VersionSpec.master;
    const master_str = try master_version.to_string(&version_buffer);
    try testing.expectEqualStrings("master", master_str);

    const specific_version = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 15, .patch = 1 } };
    const specific_str = try specific_version.to_string(&version_buffer);
    try testing.expectEqualStrings("0.15.1", specific_str);
}

test "use command validates tool types" {
    const empty_version = std.mem.zeroes([limits.limits.version_string_length_maximum]u8);

    const zig_command = validation.ValidatedCommand.UseCommand{
        .version = validation.VersionSpec.master,
        .version_raw = empty_version,
        .version_raw_length = 1,
        .tool = .zig,
    };
    try testing.expectEqual(validation.ToolType.zig, zig_command.tool);

    const zls_command = validation.ValidatedCommand.UseCommand{
        .version = validation.VersionSpec.master,
        .version_raw = empty_version,
        .version_raw_length = 1,
        .tool = .zls,
    };
    try testing.expectEqual(validation.ToolType.zls, zls_command.tool);
}
