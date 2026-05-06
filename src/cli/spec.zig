const std = @import("std");

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

    pub fn parse(name: []const u8) ?Command {
        inline for (command_specs) |command_spec| {
            if (std.mem.eql(u8, name, command_spec.name)) return command_spec.command;
            if (command_spec.alias) |alias| {
                if (std.mem.eql(u8, name, alias)) return command_spec.command;
            }
        }
        return null;
    }

    pub fn spec(self: Command) CommandSpec {
        inline for (command_specs) |command_spec| {
            if (command_spec.command == self) return command_spec;
        }
        unreachable;
    }
};

pub const Option = enum {
    zls,
    all,
    shell,
};

pub const OptionValue = enum {
    none,
    attached,
};

pub const OptionSpec = struct {
    option: Option,
    name: []const u8,
    display: []const u8,
    value: OptionValue,
};

pub const CommandSpec = struct {
    command: Command,
    name: []const u8,
    alias: ?[]const u8 = null,
    description: []const u8,
    options: []const OptionSpec = &.{},
};

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

pub const option_zls = OptionSpec{
    .option = .zls,
    .name = "--zls",
    .display = "--zls",
    .value = .none,
};

pub const option_all = OptionSpec{
    .option = .all,
    .name = "--all",
    .display = "--all",
    .value = .none,
};

pub const option_shell = OptionSpec{
    .option = .shell,
    .name = "--shell",
    .display = "--shell=<shell>",
    .value = .attached,
};

pub const version_tool_options = [_]OptionSpec{option_zls};
pub const list_options = [_]OptionSpec{option_all};
pub const env_options = [_]OptionSpec{option_shell};

pub const command_specs = [_]CommandSpec{
    .{ .command = .install, .name = "install", .alias = "i", .description = "Install a Zig or ZLS version", .options = &version_tool_options },
    .{ .command = .remove, .name = "remove", .alias = "rm", .description = "Remove an installed Zig or ZLS version", .options = &version_tool_options },
    .{ .command = .use, .name = "use", .alias = "u", .description = "Switch to a Zig or ZLS version", .options = &version_tool_options },
    .{ .command = .list, .name = "list", .alias = "ls", .description = "List installed Zig versions", .options = &list_options },
    .{ .command = .list_remote, .name = "list-remote", .description = "List available Zig or ZLS versions", .options = &version_tool_options },
    .{ .command = .list_mirrors, .name = "list-mirrors", .description = "List configured download mirrors" },
    .{ .command = .clean, .name = "clean", .description = "Remove cached artifacts and unused versions", .options = &list_options },
    .{ .command = .env, .name = "env", .description = "Print shell setup instructions", .options = &env_options },
    .{ .command = .completions, .name = "completions", .description = "Generate shell completion scripts" },
    .{ .command = .version, .name = "version", .description = "Show zvm version" },
    .{ .command = .help, .name = "help", .description = "Show help" },
    .{ .command = .upgrade, .name = "upgrade", .description = "Upgrade zvm" },
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

const command_names_count = blk: {
    var count: usize = 0;
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
        return names;
    }
}

fn build_primary_command_names() [command_specs.len][]const u8 {
    comptime {
        var names: [command_specs.len][]const u8 = undefined;
        for (command_specs, 0..) |command_spec, index| {
            names[index] = command_spec.name;
        }
        return names;
    }
}

pub const command_names = build_command_names();
pub const primary_command_names = build_primary_command_names();
pub const primary_command_words = build_primary_command_words();
pub const shell_words = build_shell_words();

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
    const command_spec = command.spec();
    for (command_spec.options) |option| {
        switch (option.value) {
            .none => if (std.mem.eql(u8, arg, option.name)) return true,
            .attached => {
                if (std.mem.eql(u8, arg, option.name)) return true;
                if (std.mem.startsWith(u8, arg, option.name) and
                    arg.len > option.name.len and
                    arg[option.name.len] == '=') return true;
            },
        }
    }
    return false;
}

pub fn option_suggestions(command_name: []const u8) ?[]const []const u8 {
    const command = Command.parse(command_name) orelse return null;
    const command_spec = command.spec();
    return switch (command_spec.options.len) {
        0 => null,
        1 => &.{command_spec.options[0].display},
        2 => &.{ command_spec.options[0].display, command_spec.options[1].display },
        else => unreachable,
    };
}

comptime {
    std.debug.assert(command_specs.len == @typeInfo(Command).@"enum".fields.len);
}

test "command name arrays are derived from command specs" {
    var primary_index: usize = 0;
    var name_index: usize = 0;
    for (command_specs) |command_spec| {
        try std.testing.expectEqualStrings(command_spec.name, primary_command_names[primary_index]);
        primary_index += 1;

        try std.testing.expectEqualStrings(command_spec.name, command_names[name_index]);
        name_index += 1;
        if (command_spec.alias) |alias| {
            try std.testing.expectEqualStrings(alias, command_names[name_index]);
            name_index += 1;
        }
    }
    try std.testing.expectEqual(primary_command_names.len, primary_index);
    try std.testing.expectEqual(command_names.len, name_index);
}

test "valued command options require attached syntax" {
    try std.testing.expect(valid_option("env", "--shell"));
    try std.testing.expect(valid_option("env", "--shell=zsh"));
    try std.testing.expect(!valid_option("env", "--shell:zsh"));
    try std.testing.expect(!valid_option("env", "--shellzsh"));
}
