const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.HelpCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = command;
    _ = progress_node;

    util_output.info(
        \\ZVM - Zig Version Manager
        \\
        \\USAGE:
        \\    zvm [GLOBAL_OPTIONS] <COMMAND> [COMMAND_OPTIONS]
        \\
        \\GLOBAL OPTIONS:
        \\    --json              Output in JSON format (machine-readable)
        \\    --quiet, -q         Suppress non-error output
        \\    --no-color          Disable colored output
        \\    --color             Force colored output
        \\    --help, -h          Show this help message
        \\    --version, -V       Show version information
        \\
        \\COMMANDS:
        \\    install, i <version>    Install a specific Zig version
        \\    remove <version>        Remove an installed Zig version  
        \\    use <version>           Switch to a specific Zig version
        \\    list                    List installed Zig versions
        \\    list-remote             List available Zig versions
        \\    list-mirrors            List available download mirrors
        \\    clean                   Remove unused Zig versions
        \\    env                     Print shell setup instructions
        \\    completions [shell]     Generate shell completion script
        \\    help                    Show this help message
        \\    version                 Show ZVM version
        \\
        \\COMMAND OPTIONS:
        \\    --zls                   For install/remove/use commands, manage ZLS instead
        \\    --all                   For clean command, remove all versions  
        \\    --shell <shell>         For env command, specify shell type
        \\
        \\EXAMPLES:
        \\    zvm install 0.11.0           Install Zig version 0.11.0
        \\    zvm --json list              List installed versions in JSON format
        \\    zvm --quiet install master   Install master build silently
        \\    zvm use 0.11.0 --zls         Switch to ZLS version 0.11.0
        \\    zvm clean --all              Remove all unused versions
        \\
    , .{});
}

const testing = std.testing;

test "help command executes without error" {
    const output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .never_use_color,
    };
    _ = try util_output.init_global(output_config);

    const command = validation.ValidatedCommand.HelpCommand{};
    const progress_node = std.Progress.start(.{ .root_name = "test" });
    defer progress_node.end();

    var mock_ctx: context.CliContext = undefined;

    try execute(&mock_ctx, command, progress_node);
}
