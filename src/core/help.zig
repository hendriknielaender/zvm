const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");
const cli_spec = @import("../cli/spec.zig");
const assert = std.debug.assert;

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
    \\    list-mirrors            List community download mirrors
    \\    clean                   Remove unused Zig versions
    \\    env                     Print shell setup instructions
    \\    completions [shell]     Generate shell completion scripts
    \\    self update             Update zvm itself (alias: zvm upgrade)
    \\    self uninstall          Remove zvm itself and all of its artefacts
    \\    help [command]          Show help
    \\    version                 Show ZVM version
    \\
    \\COMMAND OPTIONS:
    \\    --zls                   For install/remove/use/list-remote, manage ZLS instead
    \\    --all                   For list/clean, include Zig and ZLS versions
    \\    --shell=<shell>         For env, specify shell type
    \\    --dry-run               For self uninstall, list artefacts without deleting them
    \\    --no-modify-path        For self uninstall, leave shell profiles alone
    \\
    \\ENVIRONMENT VARIABLES:
    \\    ZVM_HOME                          Override the zvm install/data directory
    \\    ZVM_DEBUG                         Legacy alias for --verbose (debug level).
    \\                                      Prefer the flag; the env var is kept for
    \\                                      backward compatibility with existing scripts.
    \\    NO_COLOR                          Disable colored output when set to any value
    \\    ZVM_MIRROR                        Prefer a community mirror index from
    \\                                      list-mirrors. The live list may change;
    \\                                      remaining mirrors are still shuffled.
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
    \\    Fetch and show the Zig community download mirrors.
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
    \\    zvm [GLOBAL_OPTIONS] self update
    \\    zvm [GLOBAL_OPTIONS] upgrade
    \\
    \\DESCRIPTION:
    \\    Download and install the latest stable release of zvm,
    \\    replacing the currently installed binary in place.
    \\
    \\    Only zvm's own installation is updated: the running binary must be
    \\    exactly $ZVM_HOME/bin/zvm. A zvm installed by a package manager is
    \\    refused, before any download, so that manager stays in charge of it.
    \\
    \\    'zvm upgrade' is the original spelling and keeps working; new
    \\    scripts should prefer 'zvm self update', which groups it with the
    \\    other operations on the zvm installation itself.
    \\
    \\EXAMPLES:
    \\    zvm self update
    \\    zvm upgrade
    \\
;

const self_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] self <VERB> [VERB_OPTIONS]
    \\
    \\DESCRIPTION:
    \\    Operations on the zvm installation itself, kept apart from the
    \\    commands that manage Zig and ZLS versions.
    \\
    \\    Why a namespace: most version managers spell 'remove a managed
    \\    version' as 'uninstall <version>'. In zvm that is 'zvm remove
    \\    <version>', so a bare 'zvm uninstall' would be read as removing a
    \\    Zig version while it removed zvm. The target is in the command.
    \\
    \\VERBS:
    \\    update                  Update zvm to the latest released version
    \\    uninstall               Remove zvm itself and all of its artefacts
    \\
    \\EXAMPLES:
    \\    zvm self update
    \\    zvm self uninstall --dry-run
    \\    zvm self uninstall
    \\    zvm self uninstall --help
    \\
;

const uninstall_help_text =
    \\USAGE:
    \\    zvm [GLOBAL_OPTIONS] self uninstall [--dry-run] [--no-modify-path]
    \\
    \\DESCRIPTION:
    \\    Remove zvm itself: everything zvm created under the data root
    \\    (installed Zig and ZLS versions, download store, shims, current
    \\    links), the config directory, the zvm binary, and the PATH line zvm
    \\    asked you to add to your shell profile. This is the counterpart to
    \\    the install script, not to 'zvm remove', which deletes a single
    \\    managed version.
    \\
    \\    Always prompts unless --yes is passed. The prompt lists every file
    \\    that will be deleted or edited first.
    \\
    \\    Only the entries zvm created are deleted, and the data root itself
    \\    is removed only once it is empty. $ZVM_HOME may point at a directory
    \\    shared with other software, so anything zvm did not write is left in
    \\    place and reported. The config directory is never emptied: zvm writes
    \\    nothing into it, so it goes only if it is already empty.
    \\
    \\    Shell profiles are rewritten through a temporary file and an atomic
    \\    rename, keeping file permissions, and only lines naming zvm's bin
    \\    directory are dropped. Pass --no-modify-path to be told which files
    \\    to edit instead. --json changes the shape of the output, never what
    \\    the command does.
    \\
    \\    The binary is deleted last, so an interrupted uninstall always leaves
    \\    a working zvm behind to finish the job. On Windows the running binary
    \\    cannot delete itself and the PATH entry lives in the registry; both
    \\    are reported for manual removal.
    \\
    \\    Only zvm's own installation is removable: the running binary must be
    \\    exactly $ZVM_HOME/bin/zvm, where the installers put it. A zvm found
    \\    anywhere else belongs to whoever placed it there, so uninstall
    \\    refuses and names the path it expected.
    \\
    \\OPTIONS:
    \\    --dry-run               List the artefacts without changing anything
    \\    --no-modify-path        Do not edit shell profiles; report them instead
    \\
    \\GLOBAL OPTIONS USED:
    \\    --yes                   Skip the confirmation prompt (required with --json)
    \\    --no-input              Fail instead of prompting (use with --yes for automation)
    \\
    \\EXAMPLES:
    \\    zvm self uninstall --dry-run
    \\    zvm self uninstall
    \\    zvm --yes self uninstall
    \\    zvm --yes self uninstall --no-modify-path
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
        .uninstall => "uninstall",
        .self => "self",
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
        .uninstall => uninstall_help_text,
        .self => self_help_text,
    };
}

pub fn emit_help(command: validation.ValidatedCommand.HelpCommand) void {
    const text = topic_text(command.topic);
    assert(text.len > 0);

    if (util_output.output_mode() == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "topic", .value = .{ .string = topic_name(command.topic) } },
            .{ .key = "text", .value = .{ .string = text } },
        };
        util_output.emit_json(.{ .object = &fields });
        return;
    }

    util_output.emit_json(.{ .text = text });
}

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.HelpCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = progress_node;
    emit_help(command);
}

pub fn progress_items(command: validation.ValidatedCommand.HelpCommand) u16 {
    _ = command;
    return 0;
}

test "every help topic resolves to usable text" {
    inline for (@typeInfo(validation.HelpTopic).@"enum".fields) |field| {
        const topic: validation.HelpTopic = @enumFromInt(field.value);
        try std.testing.expect(topic_name(topic).len > 0);
        try std.testing.expect(std.mem.indexOf(u8, topic_text(topic), "USAGE:") != null);
    }
}

test "general help includes every primary command from cli spec" {
    for (cli_spec.primary_command_names) |command_name| {
        try std.testing.expect(std.mem.indexOf(u8, general_help_text, command_name) != null);
    }
}

test "self topic documents every self verb" {
    const topic = try validation.HelpTopic.parse(cli_spec.self_command_name);
    try std.testing.expectEqual(validation.HelpTopic.self, topic);

    for (cli_spec.self_verbs) |verb| {
        try std.testing.expect(std.mem.indexOf(u8, self_help_text, verb.name) != null);
    }
}

test "general help advertises the self namespace, not bare uninstall" {
    // A bare `zvm uninstall` is refused as ambiguous, so it must never be
    // presented as a command anyone should type.
    try std.testing.expect(std.mem.indexOf(u8, general_help_text, "self uninstall") != null);
    try std.testing.expect(std.mem.indexOf(u8, general_help_text, "\n    uninstall") == null);
}

test "help topics map every command in cli spec" {
    for (cli_spec.command_specs) |command_spec| {
        const topic = try validation.HelpTopic.parse(command_spec.name);
        try std.testing.expectEqualStrings(command_spec.name, topic_name(topic));
        try std.testing.expect(std.mem.indexOf(u8, topic_text(topic), command_spec.name) != null);
        if (command_spec.alias) |alias| {
            try std.testing.expectEqual(topic, try validation.HelpTopic.parse(alias));
        }
    }
}
