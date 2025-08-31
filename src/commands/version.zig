const std = @import("std");
const context = @import("../context.zig");
const util_output = @import("../util/output.zig");
const util_data = @import("../util/data.zig");
const validation = @import("../validation.zig");
const options = @import("options");

pub fn execute(
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
            .{ .key = "version", .value = .{ .string = options.version } },
        };
        util_output.json_object(&fields);
    } else {
        util_output.info("{s}", .{util_data.zvm_logo});
        util_output.info("zvm {s}", .{options.version});
    }
}

const testing = std.testing;

test "version command executes without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .never_use_color,
    };
    _ = try util_output.init_global(output_config);

    const command = validation.ValidatedCommand.VersionCommand{};
    const progress_node = std.Progress.start(.{ .root_name = "test" });
    defer progress_node.end();

    var mock_ctx: context.CliContext = undefined;

    try execute(&mock_ctx, command, progress_node);
}

test "version command fields" {
    const command = validation.ValidatedCommand.VersionCommand{};
    _ = command;
}
