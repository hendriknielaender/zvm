const std = @import("std");
const assert = std.debug.assert;

pub const Command = enum {
    install,
    remove,
    use,
    list,
    list_remote,
    list_mirrors,
    clean,
    env,
    completions,
    version,
    help,
    upgrade,
    uninstall,

    pub fn parse(name: []const u8) ?Command {
        inline for (command_specs, 0..) |command_spec, index| {
            const command: Command = @enumFromInt(index);
            if (std.mem.eql(u8, name, command_spec.name)) return command;
            if (command_spec.alias) |alias| {
                if (std.mem.eql(u8, name, alias)) return command;
            }
        }
        return null;
    }

    pub fn spec(self: Command) CommandSpec {
        return command_specs[@intFromEnum(self)];
    }
};

pub const CommandSpec = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    description: []const u8,
    /// Reachable only through the `self` namespace. Hidden commands stay
    /// parseable — help topics and option validation resolve through the
    /// same specs — but are kept out of help listings and completions so
    /// the surface advertises exactly one spelling per operation.
    hidden: bool = false,
};

/// The `self` namespace groups operations on the zvm installation itself.
///
/// Why a namespace: every other version manager spells "remove a managed
/// version" as `uninstall <version>` (nvm, pyenv, asdf, fnm, volta, mise).
/// A top-level `zvm uninstall` would read as that to most operators while
/// deleting zvm instead. `zvm self <verb>` states the target in the command,
/// following rustup, uv, and rye.
pub const self_command_name = "self";

pub const SelfVerb = struct {
    name: []const u8,
    /// Accepted alternate spelling. Not advertised, so the surface stays
    /// unambiguous while long-standing muscle memory keeps working.
    alias: ?[]const u8 = null,
    /// Command this verb resolves to. `zvm self <verb>` and the flat
    /// spelling share one implementation and one argument parser.
    command: Command,
    description: []const u8,
};

pub const self_verbs = [_]SelfVerb{
    .{
        .name = "update",
        .alias = "upgrade",
        .command = .upgrade,
        .description = "Update zvm to the latest released version",
    },
    .{
        .name = "uninstall",
        .command = .uninstall,
        .description = "Remove zvm itself and all of its artefacts",
    },
};

/// Resolve a `self` verb to the command it runs.
pub fn parse_self_verb(name: []const u8) ?Command {
    assert(name.len > 0);

    for (self_verbs) |verb| {
        if (std.mem.eql(u8, name, verb.name)) return verb.command;
        if (verb.alias) |alias| {
            if (std.mem.eql(u8, name, alias)) return verb.command;
        }
    }
    return null;
}

/// How a resolvable command name may actually be typed.
///
/// A hidden command parses but is not a spelling the operator may use: bare
/// `uninstall` resolves only to a refusal. Diagnostics that name a command —
/// "did you mean" above all — have to offer the form that works, or they send
/// the operator straight into the next error.
pub fn surface_spelling(name: []const u8) []const u8 {
    assert(name.len > 0);

    inline for (self_verbs) |verb| {
        const verb_spec = comptime verb.command.spec();
        if (comptime verb_spec.hidden) {
            if (std.mem.eql(u8, name, verb_spec.name)) {
                return self_command_name ++ " " ++ verb.name;
            }
        }
    }
    return name;
}

pub const CLIArgs = union(enum) {
    install: VersionToolArgs,
    remove: VersionToolArgs,
    use: VersionToolArgs,
    list: ListArgs,
    list_remote: ListRemoteArgs,
    list_mirrors: void,
    clean: CleanArgs,
    env: EnvArgs,
    completions: CompletionsArgs,
    version: void,
    help: HelpArgs,
    upgrade: void,
    uninstall: UninstallArgs,
};

pub const VersionToolArgs = struct {
    zls: bool = false,
    @"--": void,
    version: []const u8,
};

pub const ListArgs = struct {
    all: bool = false,
};

pub const ListRemoteArgs = struct {
    zls: bool = false,
};

pub const CleanArgs = struct {
    all: bool = false,
};

pub const UninstallArgs = struct {
    dry_run: bool = false,
    no_modify_path: bool = false,
};

pub const EnvArgs = struct {
    shell: ?[]const u8 = null,
};

pub const CompletionsArgs = struct {
    @"--": void,
    shell: ?[]const u8 = null,
};

pub const HelpArgs = struct {
    @"--": void,
    topic: ?[]const u8 = null,
};

pub const command_specs = [_]CommandSpec{
    .{ .name = "install", .alias = "i", .description = "Install a Zig or ZLS version" },
    .{ .name = "remove", .alias = "rm", .description = "Remove an installed Zig or ZLS version" },
    .{ .name = "use", .alias = "u", .description = "Switch to a Zig or ZLS version" },
    .{ .name = "list", .alias = "ls", .description = "List installed Zig versions" },
    .{ .name = "list-remote", .description = "List available Zig or ZLS versions" },
    .{ .name = "list-mirrors", .description = "List community download mirrors" },
    .{ .name = "clean", .description = "Remove cached artifacts and unused versions" },
    .{ .name = "env", .description = "Print shell setup instructions" },
    .{ .name = "completions", .description = "Generate shell completion scripts" },
    .{ .name = "version", .description = "Show zvm version" },
    .{ .name = "help", .description = "Show help" },
    .{ .name = "upgrade", .description = "Upgrade zvm (alias for 'zvm self update')" },
    .{
        .name = "uninstall",
        .description = "Remove zvm itself and all of its artefacts",
        .hidden = true,
    },
};

pub const global_option_names = [_][]const u8{
    "--json",
    "--plain",
    "--quiet",
    "--color",
    "--no-color",
    "--yes",
    "--verbose",
    "--trace",
    "--no-input",
    "--help",
    "-h",
    "--version",
};

pub const shell_names = [_][]const u8{
    "bash",
    "zsh",
    "fish",
    "powershell",
};

/// Every name a user may type as the first word, including aliases, hidden
/// commands, and the `self` namespace. Used for "did you mean" suggestions,
/// so it must cover spellings that resolve to something — even the hidden
/// ones, whose diagnostics point at the supported form.
const command_names_count = blk: {
    // +1 for the `self` namespace, which is not a CommandSpec.
    var count: usize = 1;
    for (command_specs) |command_spec| {
        count += 1;
        if (command_spec.alias != null) count += 1;
    }
    break :blk count;
};

fn build_command_names() [command_names_count][]const u8 {
    comptime {
        var names: [command_names_count][]const u8 = undefined;
        var index: usize = 0;
        for (command_specs) |command_spec| {
            names[index] = command_spec.name;
            index += 1;
            if (command_spec.alias) |alias| {
                names[index] = alias;
                index += 1;
            }
        }
        names[index] = self_command_name;
        index += 1;
        assert(index == command_names_count);
        return names;
    }
}

/// Advertised top-level commands: what help and completions list. Hidden
/// commands are excluded; the `self` namespace stands in for them.
const primary_command_count = blk: {
    var count: usize = 1; // `self`
    for (command_specs) |command_spec| {
        if (!command_spec.hidden) count += 1;
    }
    break :blk count;
};

fn build_primary_command_names() [primary_command_count][]const u8 {
    comptime {
        var names: [primary_command_count][]const u8 = undefined;
        var index: usize = 0;
        for (command_specs) |command_spec| {
            if (command_spec.hidden) continue;
            names[index] = command_spec.name;
            index += 1;
        }
        names[index] = self_command_name;
        index += 1;
        assert(index == primary_command_count);
        return names;
    }
}

fn build_self_verb_words() []const u8 {
    comptime {
        var words: []const u8 = "";
        for (self_verbs, 0..) |verb, index| {
            if (index > 0) words = words ++ " ";
            words = words ++ verb.name;
        }
        return words;
    }
}

fn build_self_verb_names() [self_verbs.len][]const u8 {
    comptime {
        var names: [self_verbs.len][]const u8 = undefined;
        for (self_verbs, 0..) |verb, index| {
            names[index] = verb.name;
        }
        return names;
    }
}

/// The `self` verbs as a diagnostic lists them, one indented line each and
/// derived from `self_verbs`. Adding a verb updates the message; the previous
/// hand-written version indexed `self_verbs[0]` and `self_verbs[1]` and would
/// have kept printing two of however many there were.
fn build_self_verb_usage() []const u8 {
    comptime {
        var name_width: usize = 0;
        for (self_verbs) |verb| name_width = @max(name_width, verb.name.len);

        var text: []const u8 = "";
        for (self_verbs) |verb| {
            var padding: []const u8 = "";
            for (verb.name.len..name_width) |_| padding = padding ++ " ";
            text = text ++ "\n  zvm " ++ self_command_name ++ " " ++
                verb.name ++ padding ++ "    " ++ verb.description;
        }
        return text;
    }
}

pub const command_names = build_command_names();
pub const primary_command_names = build_primary_command_names();
pub const primary_command_words = build_primary_command_words();
pub const shell_words = build_shell_words();
pub const self_verb_names = build_self_verb_names();
pub const self_verb_words = build_self_verb_words();
pub const self_verb_usage = build_self_verb_usage();

fn build_primary_command_words() []const u8 {
    comptime {
        var words: []const u8 = "";
        for (primary_command_names, 0..) |name, index| {
            if (index > 0) words = words ++ " ";
            words = words ++ name;
        }
        return words;
    }
}

fn build_shell_words() []const u8 {
    comptime {
        var words: []const u8 = "";
        for (shell_names, 0..) |name, index| {
            if (index > 0) words = words ++ " ";
            words = words ++ name;
        }
        return words;
    }
}

pub fn valid_option(command_name: []const u8, arg: []const u8) bool {
    const command = Command.parse(command_name) orelse return false;
    return switch (command) {
        inline else => |tag| valid_option_for(command_args_type(tag), arg),
    };
}

pub fn option_suggestions(command_name: []const u8) ?[]const []const u8 {
    const command = Command.parse(command_name) orelse return null;
    return switch (command) {
        inline else => |tag| option_suggestions_for(command_args_type(tag)),
    };
}

fn command_args_type(comptime command: Command) type {
    comptime {
        const command_name = @tagName(command);
        for (@typeInfo(CLIArgs).@"union".fields) |field| {
            if (std.mem.eql(u8, field.name, command_name)) return field.type;
        }
        unreachable;
    }
}

fn flag_name(comptime field_name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "--";
        var index: usize = 0;
        while (std.mem.indexOfScalar(u8, field_name[index..], '_')) |underscore_index| {
            result = result ++ field_name[index..][0..underscore_index] ++ "-";
            index += underscore_index + 1;
        }
        return result ++ field_name[index..];
    }
}

fn named_end(comptime Args: type) usize {
    comptime {
        if (Args == void) return 0;
        const fields = std.meta.fields(Args);
        for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, "--")) return index;
        }
        return fields.len;
    }
}

fn option_display(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime {
        const flag = flag_name(field.name);
        return switch (@typeInfo(field.type)) {
            .bool => flag,
            .optional => flag ++ "=<" ++ field.name ++ ">",
            else => flag ++ "=<" ++ field.name ++ ">",
        };
    }
}

fn valid_option_for(comptime Args: type, arg: []const u8) bool {
    if (comptime Args == void) return false;

    inline for (comptime std.meta.fields(Args)[0..named_end(Args)]) |field| {
        const flag = comptime flag_name(field.name);
        switch (@typeInfo(field.type)) {
            .bool => if (std.mem.eql(u8, arg, flag)) return true,
            else => {
                if (std.mem.eql(u8, arg, flag)) return true;
                if (std.mem.startsWith(u8, arg, flag) and
                    arg.len > flag.len and
                    arg[flag.len] == '=') return true;
            },
        }
    }
    return false;
}

fn named_option_count(comptime Args: type) usize {
    comptime {
        if (Args == void) return 0;
        return named_end(Args);
    }
}

fn option_suggestions_for(comptime Args: type) ?[]const []const u8 {
    const count = comptime named_option_count(Args);
    if (comptime count == 0) return null;
    return &OptionSuggestions(Args).values;
}

fn OptionSuggestions(comptime Args: type) type {
    return struct {
        const values = build_option_suggestions(Args);
    };
}

fn build_option_suggestions(comptime Args: type) [named_option_count(Args)][]const u8 {
    comptime {
        var suggestions: [named_option_count(Args)][]const u8 = undefined;
        for (std.meta.fields(Args)[0..named_end(Args)], 0..) |field, index| {
            suggestions[index] = option_display(field);
        }
        return suggestions;
    }
}

comptime {
    std.debug.assert(command_specs.len == @typeInfo(Command).@"enum".fields.len);
    for (std.meta.fields(Command), 0..) |field, index| {
        std.debug.assert(std.mem.eql(u8, field.name, @tagName(@as(Command, @enumFromInt(index)))));
    }
}

test "command name arrays are derived from command specs" {
    var primary_index: usize = 0;
    var name_index: usize = 0;
    for (command_specs) |command_spec| {
        if (!command_spec.hidden) {
            try std.testing.expectEqualStrings(
                command_spec.name,
                primary_command_names[primary_index],
            );
            primary_index += 1;
        }

        try std.testing.expectEqualStrings(command_spec.name, command_names[name_index]);
        name_index += 1;
        if (command_spec.alias) |alias| {
            try std.testing.expectEqualStrings(alias, command_names[name_index]);
            name_index += 1;
        }
    }

    // Both arrays end with the `self` namespace, which has no CommandSpec.
    try std.testing.expectEqualStrings(self_command_name, primary_command_names[primary_index]);
    try std.testing.expectEqualStrings(self_command_name, command_names[name_index]);
    try std.testing.expectEqual(primary_command_names.len, primary_index + 1);
    try std.testing.expectEqual(command_names.len, name_index + 1);
}

test "hidden commands stay parseable but are not advertised" {
    // `uninstall` still resolves so its help topic and option validation
    // work, but the surface only advertises `zvm self uninstall`.
    try std.testing.expectEqual(Command.uninstall, Command.parse("uninstall").?);
    try std.testing.expect(Command.uninstall.spec().hidden);

    for (primary_command_names) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "uninstall"));
    }
}

test "self verbs resolve to the commands they run" {
    try std.testing.expectEqual(Command.uninstall, parse_self_verb("uninstall").?);
    try std.testing.expectEqual(Command.upgrade, parse_self_verb("update").?);
    // `upgrade` is accepted but not advertised, so `zvm upgrade` muscle
    // memory keeps working inside the namespace too.
    try std.testing.expectEqual(Command.upgrade, parse_self_verb("upgrade").?);
    try std.testing.expect(parse_self_verb("nonsense") == null);
}

test "every self verb resolves to a real command spec" {
    for (self_verbs) |verb| {
        try std.testing.expect(verb.name.len > 0);
        try std.testing.expect(verb.description.len > 0);
        try std.testing.expect(verb.command.spec().name.len > 0);
    }
    try std.testing.expectEqualStrings("update uninstall", self_verb_words);
}

test "valued command options require attached syntax" {
    try std.testing.expect(valid_option("env", "--shell"));
    try std.testing.expect(valid_option("env", "--shell=zsh"));
    try std.testing.expect(!valid_option("env", "--shell:zsh"));
    try std.testing.expect(!valid_option("env", "--shellzsh"));
}

test "command option suggestions are stable command option names" {
    const list_suggestions = option_suggestions("list").?;
    try std.testing.expectEqual(@as(usize, 1), list_suggestions.len);
    try std.testing.expectEqualStrings("--all", list_suggestions[0]);

    const install_suggestions = option_suggestions("install").?;
    try std.testing.expectEqual(@as(usize, 1), install_suggestions.len);
    try std.testing.expectEqualStrings("--zls", install_suggestions[0]);

    try std.testing.expect(option_suggestions("help") == null);
}
