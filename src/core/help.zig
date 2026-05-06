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
    \\    --plain             Tabular output for shell pipelines (no headers, no color)
    \\    --quiet             Suppress non-error output
    \\    --verbose           Show debug output on stderr
    \\    --trace             Show trace output with HTTP details and file paths
    \\    --no-color          Disable colored output
    \\    --color             Force colored output
    \\    --yes               Skip confirmation prompts for destructive operations
    \\    --no-input          Refuse to prompt; non-interactive runs fail fast
    \\    --help, -h          Show this help message
    \\    --version           Show version information
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
    \\    upgrade                 Upgrade zvm to the latest released version
    \\    help [command]          Show help
    \\    version                 Show ZVM version
    \\
    \\COMMAND OPTIONS:
    \\    --zls                   For install/remove/use/list-remote, manage ZLS instead
    \\    --all                   For list/clean, include Zig and ZLS versions
    \\    --shell=<shell>         For env, specify shell type
    \\
    \\ENVIRONMENT VARIABLES:
    \\    ZVM_HOME                          Override the zvm install/data directory
    \\    ZVM_DEBUG                         Legacy alias for --verbose (debug level).
    \\                                      Prefer the flag; the env var is kept for
    \\                                      backward compatibility with existing scripts.
    \\    NO_COLOR                          Disable colored output when set to any value
    \\    ZVM_DOWNLOAD_TIMEOUT_SECONDS      Per-mirror download timeout (default 1800,
    \\                                      range 5..86400). Connect target 10s,
    \\                                      idle target 30s; on timeout zvm falls
    \\                                      through to the next mirror in list-mirrors.
    \\
    \\EXAMPLES:
    \\    zvm -h
    \\    zvm --json list
    \\    zvm list --help
    \\    zvm help install
    \\    zvm env --shell=zsh
    \\    zvm --version
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
    \\    zvm install 0.16.0
    \\    zvm i master
    \\    zvm install --zls 0.16.0
    \\
;

const remove_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] remove [--zls] <version>
    \\    zvm [GLOBAL_OPTIONS] rm [--zls] <version>
    \\
    \\DESCRIPTION:
    \\    Remove an installed Zig or ZLS release. Removing the active version
    \\    requires a y/N confirmation unless --yes is passed. Removing
    \\    an inactive version proceeds without a prompt.
    \\
    \\OPTIONS:
    \\    --zls                   Remove ZLS instead of Zig
    \\
    \\GLOBAL OPTIONS USED:
    \\    --yes                   Skip the confirmation prompt
    \\    --no-input              Fail instead of prompting (use with --yes for automation)
    \\
    \\EXAMPLES:
    \\    zvm remove 0.16.0
    \\    zvm --yes rm 0.16.0
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
    \\    zvm use 0.16.0
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
    \\    Remove cached download artifacts. Use --all to also remove every
    \\    non-current installed Zig and ZLS version. --all always prompts
    \\    with a count of versions to delete unless --yes is passed.
    \\
    \\OPTIONS:
    \\    --all                   Remove every non-current installed version
    \\
    \\GLOBAL OPTIONS USED:
    \\    --yes                   Skip the confirmation prompt for --all
    \\    --no-input              Fail instead of prompting (use with --yes for automation)
    \\
    \\EXAMPLES:
    \\    zvm clean
    \\    zvm clean --all
    \\    zvm --yes clean --all
    \\
;

const env_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] env [--shell=<shell>]
    \\
    \\DESCRIPTION:
    \\    Print shell setup instructions.
    \\
    \\OPTIONS:
    \\    --shell=<shell>         Explicit shell type: bash, zsh, fish, powershell
    \\
    \\EXAMPLES:
    \\    zvm env
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
    \\
    \\DESCRIPTION:
    \\    Print the ZVM version.
    \\
    \\EXAMPLES:
    \\    zvm version
    \\    zvm --version
    \\
;

const upgrade_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] upgrade
    \\
    \\DESCRIPTION:
    \\    Download and install the latest stable release of zvm,
    \\    replacing the currently installed binary in place.
    \\
    \\EXAMPLES:
    \\    zvm upgrade
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
        .upgrade => "upgrade",
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
        .upgrade => upgrade_help_text,
    };
}

pub fn emit_help(
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

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.HelpCommand,
    progress_node: std.Progress.Node,
) !void {
    try emit_help(ctx, command, progress_node);
}

pub fn progress_items(command: validation.ValidatedCommand.HelpCommand) u16 {
    _ = command;
    return 0;
}

test "help command executes without error" {
    const output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .never_use_color,
    };
    _ = try util_output.init_global(output_config);

    const command = validation.ValidatedCommand.HelpCommand{ .topic = .general };
    const progress_node = std.Progress.start(std.testing.io, .{ .root_name = "test" });
    defer progress_node.end();

    var mock_ctx: context.CliContext = undefined;

    try emit_help(&mock_ctx, command, progress_node);
}
