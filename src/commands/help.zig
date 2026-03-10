const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");

const general_help_text =
    \\ZVM - Zig Version Manager
    \\
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] <COMMAND> [COMMAND_OPTIONS]
    \\    zvm [GLOBAL_OPTIONS] -- <COMMAND> [COMMAND_OPTIONS]
    \\    Global options must appear before <COMMAND>.
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
    \\    install, i [--zls] <version>    Install a specific Zig or ZLS version
    \\    remove, rm [--zls] <version>    Remove an installed Zig or ZLS version
    \\    use, u [--zls] <version>        Switch to a specific Zig or ZLS version
    \\    list, ls                List installed Zig versions
    \\    list-remote             List available Zig versions
    \\    list-mirrors            List available download mirrors
    \\    clean                   Remove unused Zig versions
    \\    env                     Print shell setup instructions
    \\    completions [shell]     Generate shell completion scripts
    \\    help [command]          Show help
    \\    version                 Show ZVM version
    \\
    \\COMMAND OPTIONS:
    \\    --zls                   For install/remove/use/list-remote, manage ZLS instead
    \\    --all                   For list/clean, include Zig and ZLS versions
    \\    --shell <shell>         For env, specify shell type
    \\
    \\EXAMPLES:
    \\    zvm -h
    \\    zvm --json list
    \\    zvm list --help
    \\    zvm help install
    \\    zvm env --shell=zsh
    \\    zvm -V
    \\
;

const install_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] install [--zls] <version>
    \\    zvm [GLOBAL_OPTIONS] i [--zls] <version>
    \\
    \\DESCRIPTION:
    \\    Install a Zig or ZLS release. Use 'master' for development builds.
    \\
    \\OPTIONS:
    \\    --zls                   Install ZLS instead of Zig
    \\
    \\EXAMPLES:
    \\    zvm install 0.15.1
    \\    zvm i master
    \\    zvm install --zls 0.15.1
    \\
;

const remove_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] remove [--zls] <version>
    \\    zvm [GLOBAL_OPTIONS] rm [--zls] <version>
    \\
    \\DESCRIPTION:
    \\    Remove an installed Zig or ZLS release.
    \\
    \\OPTIONS:
    \\    --zls                   Remove ZLS instead of Zig
    \\
    \\EXAMPLES:
    \\    zvm remove 0.15.1
    \\    zvm rm --zls master
    \\
;

const use_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] use [--zls] <version>
    \\    zvm [GLOBAL_OPTIONS] u [--zls] <version>
    \\
    \\DESCRIPTION:
    \\    Switch the current Zig or ZLS version.
    \\
    \\OPTIONS:
    \\    --zls                   Select ZLS instead of Zig
    \\
    \\EXAMPLES:
    \\    zvm use 0.15.1
    \\    zvm u --zls master
    \\
;

const list_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] list [--all]
    \\    zvm [GLOBAL_OPTIONS] ls [--all]
    \\
    \\DESCRIPTION:
    \\    List installed Zig versions. Use --all to include installed ZLS versions too.
    \\
    \\OPTIONS:
    \\    --all                   Include installed ZLS versions too
    \\
    \\EXAMPLES:
    \\    zvm list
    \\    zvm ls --all
    \\
;

const list_remote_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] list-remote [--zls]
    \\
    \\DESCRIPTION:
    \\    List versions available for download.
    \\
    \\OPTIONS:
    \\    --zls                   List ZLS releases instead of Zig releases
    \\
    \\EXAMPLES:
    \\    zvm list-remote
    \\    zvm list-remote --zls
    \\
;

const list_mirrors_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] list-mirrors
    \\
    \\DESCRIPTION:
    \\    Show the configured download mirrors.
    \\
    \\EXAMPLES:
    \\    zvm list-mirrors
    \\
;

const clean_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] clean [--all]
    \\
    \\DESCRIPTION:
    \\    Remove cached or unused versions. Use --all to remove everything not current.
    \\
    \\OPTIONS:
    \\    --all                   Remove every non-current installed version
    \\
    \\EXAMPLES:
    \\    zvm clean
    \\    zvm clean --all
    \\
;

const env_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] env [--shell <shell>]
    \\    zvm [GLOBAL_OPTIONS] env [--shell=<shell>]
    \\
    \\DESCRIPTION:
    \\    Print shell setup instructions.
    \\
    \\OPTIONS:
    \\    --shell <shell>         Explicit shell type: bash, zsh, fish, powershell
    \\    --shell=<shell>         Equivalent attached-value form
    \\
    \\EXAMPLES:
    \\    zvm env
    \\    zvm env --shell zsh
    \\    zvm env --shell=zsh
    \\
;

const completions_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] completions [shell]
    \\
    \\DESCRIPTION:
    \\    Generate shell completion scripts.
    \\
    \\EXAMPLES:
    \\    zvm completions
    \\    zvm completions bash
    \\
;

const version_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] version
    \\    zvm [GLOBAL_OPTIONS] --version
    \\    zvm [GLOBAL_OPTIONS] -V
    \\
    \\DESCRIPTION:
    \\    Print the ZVM version.
    \\
    \\EXAMPLES:
    \\    zvm version
    \\    zvm --version
    \\    zvm -V
    \\
;

const help_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] help [command]
    \\    zvm <command> --help
    \\
    \\DESCRIPTION:
    \\    Show general help or command-specific help.
    \\
    \\EXAMPLES:
    \\    zvm help
    \\    zvm help install
    \\    zvm list --help
    \\
;

fn topic_name(topic: validation.HelpTopic) []const u8 {
    return switch (topic) {
        .general => "general",
        .install => "install",
        .remove => "remove",
        .use => "use",
        .list => "list",
        .list_remote => "list-remote",
        .list_mirrors => "list-mirrors",
        .clean => "clean",
        .env => "env",
        .completions => "completions",
        .version => "version",
        .help => "help",
    };
}

fn topic_text(topic: validation.HelpTopic) []const u8 {
    return switch (topic) {
        .general => general_help_text,
        .install => install_help_text,
        .remove => remove_help_text,
        .use => use_help_text,
        .list => list_help_text,
        .list_remote => list_remote_help_text,
        .list_mirrors => list_mirrors_help_text,
        .clean => clean_help_text,
        .env => env_help_text,
        .completions => completions_help_text,
        .version => version_help_text,
        .help => help_help_text,
    };
}

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.HelpCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = progress_node;

    const emitter = util_output.get_global();
    const text = topic_text(command.topic);

    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "topic", .value = .{ .string = topic_name(command.topic) } },
            .{ .key = "text", .value = .{ .string = text } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.print_text(text);
}

test "help command executes without error" {
    const output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .never_use_color,
    };
    _ = try util_output.init_global(output_config);

    const command = validation.ValidatedCommand.HelpCommand{ .topic = .general };
    const progress_node = std.Progress.start(.{ .root_name = "test" });
    defer progress_node.end();

    var mock_ctx: context.CliContext = undefined;

    try execute(&mock_ctx, command, progress_node);
}
