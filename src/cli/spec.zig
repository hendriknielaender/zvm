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

pub const command_specs = [_]CommandSpec{
    .{ .name = "install", .alias = "i", .description = "Install a Zig or ZLS version" },
    .{ .name = "remove", .alias = "rm", .description = "Remove an installed Zig or ZLS version" },
    .{ .name = "use", .alias = "u", .description = "Switch to a Zig or ZLS version" },
    .{ .name = "list", .alias = "ls", .description = "List installed Zig versions" },
    .{ .name = "list-remote", .description = "List available Zig or ZLS versions" },
    .{ .name = "list-mirrors", .description = "List configured download mirrors" },
    .{ .name = "clean", .description = "Remove cached artifacts and unused versions" },
    .{ .name = "env", .description = "Print shell setup instructions" },
    .{ .name = "completions", .description = "Generate shell completion scripts" },
    .{ .name = "version", .description = "Show zvm version" },
    .{ .name = "help", .description = "Show help" },
    .{ .name = "upgrade", .description = "Upgrade zvm" },
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

test "command option suggestions are stable command option names" {
    const list_suggestions = option_suggestions("list").?;
    try std.testing.expectEqual(@as(usize, 1), list_suggestions.len);
    try std.testing.expectEqualStrings("--all", list_suggestions[0]);

    const install_suggestions = option_suggestions("install").?;
    try std.testing.expectEqual(@as(usize, 1), install_suggestions.len);
    try std.testing.expectEqualStrings("--zls", install_suggestions[0]);

    try std.testing.expect(option_suggestions("help") == null);
}
