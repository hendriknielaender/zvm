const std = @import("std");
const context = @import("../Context.zig");
const util_data = @import("../util/data.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");
const remove = @import("remove.zig");
const detect_version = @import("detect_version.zig");
const confirm = @import("../util/confirm.zig");
const assert = std.debug.assert;

pub fn remove_installed(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.RemoveCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;
    assert(command.version_raw_length > 0);

    const version_str = command.get_version();
    const is_zls = command.tool == .zls;
    const json_mode = util_output.output_mode() == .machine_json;

    const removing_active = is_active_version(ctx, version_str, is_zls);

    if (!ctx.assume_yes and removing_active) {
        if (json_mode) {
            util_output.exit_with(
                .invalid_arguments,
                "removing the active {s} version requires --yes in --json mode",
                .{command.tool.to_string()},
            );
        }

        var prompt_buffer: [128]u8 = undefined;
        const prompt = std.fmt.bufPrint(
            &prompt_buffer,
            "Remove active {s} version {s}?",
            .{ command.tool.to_string(), version_str },
        ) catch unreachable;

        const confirmed = confirm.confirm_destructive(ctx.io, prompt, true, ctx.no_input) catch |err| switch (err) {
            error.RequiresConfirmation => util_output.exit_with(
                .invalid_arguments,
                "removing the active {s} version requires --yes (stdin is not a terminal or --no-input was set)",
                .{command.tool.to_string()},
            ),
            error.StdinReadFailed => util_output.exit_with(
                .invalid_arguments,
                "failed to read confirmation from stdin",
                .{},
            ),
        };
        if (!confirmed) {
            util_output.emit(.info, "Aborted: {s} version {s} not removed.", .{ command.tool.to_string(), version_str });
            return;
        }
    }

    try remove.remove(ctx, version_str, is_zls, false);

    if (json_mode) {
        const fields = [_]util_output.JsonField{
            .{ .key = "tool", .value = .{ .string = command.tool.to_string() } },
            .{ .key = "version", .value = .{ .string = version_str } },
            .{ .key = "status", .value = .{ .string = "removed" } },
        };
        util_output.emit_json(.{ .object = &fields });
        return;
    }

    util_output.emit(.success, "Removed {s} version {s}", .{ command.tool.to_string(), version_str });
}

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.RemoveCommand,
    progress_node: std.Progress.Node,
) !void {
    try remove_installed(ctx, command, progress_node);
}

pub fn progress_items(command: validation.ValidatedCommand.RemoveCommand) u16 {
    _ = command;
    return 2;
}

/// Decide whether removing `version_str` would tear down the active install.
/// Why: removing an inactive version is low risk and shouldn't prompt; only
/// the active install changes the user's PATH-resolved tool out from under them.
fn is_active_version(ctx: *context.CliContext, version_str: []const u8, is_zls: bool) bool {
    assert(version_str.len > 0);
    assert(version_str.len <= limits.limits.version_string_length_maximum);

    if (!is_zls) {
        var default_version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
        const default_version = detect_version.find_default_version_in_buffer(
            ctx,
            &default_version_buffer,
        ) catch null;
        if (default_version) |value| {
            if (util_tool.eql_str(value, version_str)) return true;
        }
    }

    var path_buffer = ctx.scratch_path() catch return false;
    defer path_buffer.release();

    var output_buffer: [limits.limits.temp_buffer_size]u8 = undefined;
    const current = util_data.get_current_version(path_buffer, &output_buffer, is_zls) catch return false;
    return util_tool.eql_str(current, version_str);
}
