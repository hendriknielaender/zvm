const std = @import("std");
const limits = @import("../memory/limits.zig");
const edit_distance = @import("../util/edit_distance.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const cli_spec = @import("spec.zig");
const flags = @import("flags.zig");
const assert = std.debug.assert;
const max_version_string_length = limits.limits.version_string_length_maximum;
const max_shell_name_length = 32;
const max_help_topic_length = 32;

comptime {
    assert(max_version_string_length >= 16);
    assert(max_version_string_length <= 256);
    assert(max_shell_name_length >= 8);
    assert(max_shell_name_length <= 64);
    assert(max_help_topic_length >= 8);
    assert(max_help_topic_length <= 64);
}

fn validate_version_arg(version_arg: []const u8) !void {
    assert(version_arg.len < 1024);

    if (version_arg.len == 0) {
        return error.EmptyVersionArgument;
    }
    if (version_arg.len >= max_version_string_length) {
        return error.VersionStringTooLong;
    }
}

/// Command argument parsing with syntactic validation.
/// Kept private so argv syntax and semantic validation remain in one module.
const CommandArgs = union(enum) {
    install: InstallArgs,
    remove: RemoveArgs,
    use: UseArgs,
    list: ListArgs,
    list_remote: ListRemoteArgs,
    clean: CleanArgs,
    env: EnvArgs,
    completions: CompletionsArgs,
    version: VersionArgs,
    help: HelpArgs,
    list_mirrors: ListMirrorsArgs,
    upgrade: UpgradeArgs,

    pub const InstallArgs = struct {
        version: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const InstallArgs) []const u8 {
            assert(self.version_length > 0);
            assert(self.version_length <= max_version_string_length);
            assert(self.version_length <= self.version.len);

            const result = self.version[0..self.version_length];
            assert(result.len > 0);
            assert(result.len == self.version_length);
            return result;
        }
    };

    pub const RemoveArgs = struct {
        version: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const RemoveArgs) []const u8 {
            assert(self.version_length > 0);
            assert(self.version_length <= max_version_string_length);
            assert(self.version_length <= self.version.len);

            const result = self.version[0..self.version_length];
            assert(result.len > 0);
            assert(result.len == self.version_length);
            return result;
        }
    };

    pub const UseArgs = struct {
        version: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const UseArgs) []const u8 {
            assert(self.version_length > 0);
            assert(self.version_length <= max_version_string_length);
            assert(self.version_length <= self.version.len);

            const result = self.version[0..self.version_length];
            assert(result.len > 0);
            assert(result.len == self.version_length);
            return result;
        }
    };

    /// List command arguments
    pub const ListArgs = struct {
        show_all: bool = false,
    };

    /// List-remote command arguments
    pub const ListRemoteArgs = struct {
        is_zls: bool = false,
    };

    /// Clean command arguments
    pub const CleanArgs = struct {
        remove_all: bool = false,
    };

    /// Env command arguments
    pub const EnvArgs = struct {
        shell_name: ?[max_shell_name_length]u8 = null,
        shell_length: u8 = 0,

        pub fn get_shell(self: *const EnvArgs) ?[]const u8 {
            if (self.shell_length == 0) return null;
            assert(self.shell_length <= max_shell_name_length);
            return self.shell_name.?[0..self.shell_length];
        }
    };

    /// Completions command arguments
    pub const CompletionsArgs = struct {
        shell: ?[max_shell_name_length]u8,
        shell_length: u8,

        pub fn get_shell(self: *const CompletionsArgs) ?[]const u8 {
            assert(self.shell_length <= max_shell_name_length);

            if (self.shell_length == 0) {
                assert(self.shell == null);
                return null;
            }

            assert(self.shell != null);
            const result = self.shell.?[0..self.shell_length];
            assert(result.len > 0);
            assert(result.len == self.shell_length);
            return result;
        }
    };

    /// Version command arguments
    pub const VersionArgs = struct {};

    /// Help command arguments
    pub const HelpArgs = struct {
        topic: ?[max_help_topic_length]u8 = null,
        topic_length: u8 = 0,

        pub fn get_topic(self: *const HelpArgs) ?[]const u8 {
            if (self.topic_length == 0) return null;
            assert(self.topic != null);
            assert(self.topic_length <= max_help_topic_length);

            return self.topic.?[0..self.topic_length];
        }
    };

    /// List-mirrors command arguments
    pub const ListMirrorsArgs = struct {};

    /// Upgrade command arguments
    pub const UpgradeArgs = struct {};
};

fn parse_command_syntax(command_name: []const u8, args: []const []const u8) !CommandArgs {
    assert(command_name.len > 0);
    assert(command_name.len <= 32);
    assert(args.len <= limits.limits.arguments_maximum);

    for (args) |arg| {
        assert(arg.len < 1024);
    }

    const parsed = flags.parse_command(cli_spec.CLIArgs, command_name, args) catch |err| switch (err) {
        error.UnknownCommand => return error.UnknownCommand,
        error.UnknownFlag => return error.UnknownFlag,
        error.DuplicateOption => return error.DuplicateOption,
        error.MissingOptionValueSeparator => return error.MissingOptionValueSeparator,
        error.EmptyOptionValue => return error.EmptyOptionValue,
        error.MissingRequiredArgument => return missing_required_argument(command_name),
        error.EmptyArgument => return empty_positional_argument(command_name),
        error.UnexpectedArguments => return unexpected_arguments(command_name),
        error.TrailingOption => return error.TrailingOption,
        error.InvalidFlagValue => return error.UnknownFlag,
        error.Overflow => return error.UnknownFlag,
    };

    return switch (parsed) {
        .install => |install| .{ .install = try version_tool_args_to_install(install) },
        .remove => |remove| .{ .remove = try version_tool_args_to_remove(remove) },
        .use => |use| .{ .use = try version_tool_args_to_use(use) },
        .list => |list| .{ .list = .{ .show_all = list.all } },
        .list_remote => |list_remote| .{ .list_remote = .{ .is_zls = list_remote.zls } },
        .list_mirrors => .{ .list_mirrors = .{} },
        .clean => |clean| .{ .clean = .{ .remove_all = clean.all } },
        .env => |env| .{ .env = try env_args_from_cli(env) },
        .completions => |completions| .{ .completions = try completions_args_from_cli(completions) },
        .version => .{ .version = .{} },
        .help => |help| .{ .help = try help_args_from_cli(help) },
        .upgrade => .{ .upgrade = .{} },
    };
}

fn missing_required_argument(command_name: []const u8) anyerror {
    const command = cli_spec.Command.parse(command_name) orelse return error.UnknownCommand;
    return switch (command) {
        .install, .remove, .use => error.MissingVersionArgument,
        else => error.UnexpectedArguments,
    };
}

fn empty_positional_argument(command_name: []const u8) anyerror {
    const command = cli_spec.Command.parse(command_name) orelse return error.UnknownCommand;
    return switch (command) {
        .install, .remove, .use => error.EmptyVersionArgument,
        .completions => error.EmptyShellArgument,
        .help => error.EmptyHelpTopic,
        else => error.UnexpectedArguments,
    };
}

fn unexpected_arguments(command_name: []const u8) anyerror {
    const command = cli_spec.Command.parse(command_name) orelse return error.UnknownCommand;
    return switch (command) {
        .completions, .help => error.TooManyArguments,
        else => error.UnexpectedArguments,
    };
}

fn version_tool_args_to_install(args: cli_spec.VersionToolArgs) !CommandArgs.InstallArgs {
    try validate_version_arg(args.version);
    var result = CommandArgs.InstallArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(args.version.len),
        .is_zls = args.zls,
    };
    @memcpy(result.version[0..args.version.len], args.version);
    return result;
}

fn version_tool_args_to_remove(args: cli_spec.VersionToolArgs) !CommandArgs.RemoveArgs {
    try validate_version_arg(args.version);
    var result = CommandArgs.RemoveArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(args.version.len),
        .is_zls = args.zls,
    };
    @memcpy(result.version[0..args.version.len], args.version);
    return result;
}

fn version_tool_args_to_use(args: cli_spec.VersionToolArgs) !CommandArgs.UseArgs {
    try validate_version_arg(args.version);
    var result = CommandArgs.UseArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(args.version.len),
        .is_zls = args.zls,
    };
    @memcpy(result.version[0..args.version.len], args.version);
    return result;
}

fn env_args_from_cli(args: cli_spec.EnvArgs) !CommandArgs.EnvArgs {
    var result = CommandArgs.EnvArgs{};
    const shell = args.shell orelse return result;
    if (shell.len > max_shell_name_length) return error.ShellNameTooLong;
    result.shell_name = std.mem.zeroes([max_shell_name_length]u8);
    @memcpy(result.shell_name.?[0..shell.len], shell);
    result.shell_length = @intCast(shell.len);
    return result;
}

fn completions_args_from_cli(args: cli_spec.CompletionsArgs) !CommandArgs.CompletionsArgs {
    var result = CommandArgs.CompletionsArgs{
        .shell = null,
        .shell_length = 0,
    };
    const shell = args.shell orelse return result;
    if (shell.len > max_shell_name_length) return error.ShellNameTooLong;
    result.shell = std.mem.zeroes([max_shell_name_length]u8);
    @memcpy(result.shell.?[0..shell.len], shell);
    result.shell_length = @intCast(shell.len);
    return result;
}

fn help_args_from_cli(args: cli_spec.HelpArgs) !CommandArgs.HelpArgs {
    var result = CommandArgs.HelpArgs{};
    const topic = args.topic orelse return result;
    if (topic.len > max_help_topic_length) return error.HelpTopicTooLong;
    result.topic = std.mem.zeroes([max_help_topic_length]u8);
    @memcpy(result.topic.?[0..topic.len], topic);
    result.topic_length = @intCast(topic.len);
    return result;
}

comptime {
    assert(@sizeOf(CommandArgs) <= 512);
    assert(@sizeOf(CommandArgs) > 0);
    assert(@sizeOf(CommandArgs.InstallArgs) <= 300);
    assert(@sizeOf(CommandArgs.InstallArgs) > 0);
    assert(@sizeOf(CommandArgs.RemoveArgs) <= 300);
    assert(@sizeOf(CommandArgs.RemoveArgs) > 0);
    assert(@sizeOf(CommandArgs.UseArgs) <= 300);
    assert(@sizeOf(CommandArgs.UseArgs) > 0);
    assert(@sizeOf(CommandArgs.CompletionsArgs) <= 64);
    assert(@sizeOf(CommandArgs.CompletionsArgs) > 0);

    assert(@typeInfo(CommandArgs).@"union".fields.len == 12);
    assert(max_version_string_length == limits.limits.version_string_length_maximum);
    assert(max_shell_name_length == 32);
    assert(max_help_topic_length == 32);
    assert(max_version_string_length >= 16);
    assert(max_version_string_length <= 512);
}

pub const VersionSpec = union(enum) {
    master,
    specific: VersionNumbers,

    const VersionNumbers = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn format(self: VersionNumbers, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        }

        comptime {
            assert(@sizeOf(VersionNumbers) == 12);
            assert(@alignOf(VersionNumbers) == 4);
        }
    };

    const VersionSpec_Self = @This();

    pub fn parse(version_str: []const u8) !VersionSpec_Self {
        assert(version_str.len > 0);
        assert(version_str.len <= max_version_string_length);
        assert(version_str.len < 1024);

        if (std.mem.eql(u8, version_str, "master")) {
            return .master;
        }
        if (std.mem.eql(u8, version_str, "latest")) {
            return error.LatestNotSupported;
        }

        const core_end = std.mem.indexOfAny(u8, version_str, "-+") orelse version_str.len;
        const core_version = version_str[0..core_end];

        var parts = std.mem.splitScalar(u8, core_version, '.');
        const major_str = parts.next() orelse return error.InvalidVersionFormat;
        const minor_str = parts.next() orelse return error.InvalidVersionFormat;
        const patch_str = parts.next() orelse return error.InvalidVersionFormat;
        assert(major_str.len > 0);
        assert(minor_str.len > 0);
        assert(patch_str.len > 0);

        if (parts.next() != null) {
            return error.TooManyVersionParts;
        }

        const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidMajorVersion;
        const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidMinorVersion;
        const patch = std.fmt.parseInt(u32, patch_str, 10) catch return error.InvalidPatchVersion;

        if (major > 99) return error.MajorVersionTooLarge;
        if (minor > 99) return error.MinorVersionTooLarge;
        if (patch > 999) return error.PatchVersionTooLarge;

        // Validate pre-release/build suffixes when present.
        if (core_end < version_str.len) {
            _ = std.SemanticVersion.parse(version_str) catch return error.InvalidVersionFormat;
        }

        const result = VersionSpec_Self{
            .specific = .{
                .major = major,
                .minor = minor,
                .patch = patch,
            },
        };

        assert(result.specific.major == major);
        assert(result.specific.minor == minor);
        assert(result.specific.patch == patch);
        return result;
    }

    pub fn to_string(self: VersionSpec, buffer: []u8) ![]const u8 {
        assert(buffer.len >= limits.limits.version_string_length_maximum);

        return switch (self) {
            .master => "master",
            .specific => |spec| try std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ spec.major, spec.minor, spec.patch }),
        };
    }

    pub fn is_compatible_with_zls(self: VersionSpec) bool {
        return switch (self) {
            .master => true,
            .specific => |spec| {
                // ZLS compatibility rules: ZLS requires Zig >= 0.11.0
                if (spec.major == 0 and spec.minor < 11) return false;
                return true;
            },
        };
    }
};

/// Tool type enumeration for type safety
pub const ToolType = enum {
    zig,
    zls,

    pub fn from_bool(is_zls: bool) ToolType {
        return if (is_zls) .zls else .zig;
    }

    pub fn to_string(self: ToolType) []const u8 {
        return switch (self) {
            .zig => "zig",
            .zls => "zls",
        };
    }
};

pub const HelpTopic = enum {
    general,
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

    pub fn parse(topic_str: []const u8) !HelpTopic {
        assert(topic_str.len > 0);

        const command = cli_spec.Command.parse(topic_str) orelse return error.UnknownHelpTopic;
        return switch (command) {
            .install => .install,
            .remove => .remove,
            .use => .use,
            .list => .list,
            .list_remote => .list_remote,
            .list_mirrors => .list_mirrors,
            .clean => .clean,
            .env => .env,
            .completions => .completions,
            .version => .version,
            .help => .help,
            .upgrade => .upgrade,
        };
    }
};

/// Shell type with validation
pub const ShellType = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn parse(shell_str: []const u8) !ShellType {
        assert(shell_str.len > 0);

        if (std.mem.eql(u8, shell_str, "bash")) return .bash;
        if (std.mem.eql(u8, shell_str, "zsh")) return .zsh;
        if (std.mem.eql(u8, shell_str, "fish")) return .fish;
        if (std.mem.eql(u8, shell_str, "powershell")) return .powershell;
        return error.UnknownShell;
    }
};

fn fatal_unknown_help_topic(topic: []const u8) noreturn {
    if (edit_distance.nearest(topic, &cli_spec.command_names)) |suggestion| {
        util_output.exit_with(
            .invalid_arguments,
            "unknown help topic '{s}'\n\n  Did you mean '{s}'?",
            .{ topic, suggestion },
        );
    }
    util_output.exit_with(.invalid_arguments, "unknown help topic '{s}'", .{topic});
}

fn fatal_unknown_shell(shell: []const u8) noreturn {
    if (edit_distance.nearest(shell, &cli_spec.shell_names)) |suggestion| {
        util_output.exit_with(
            .invalid_arguments,
            "unknown shell type '{s}'\n\n  Did you mean '{s}'?",
            .{ shell, suggestion },
        );
    }
    util_output.exit_with(
        .invalid_arguments,
        "unknown shell type '{s}' (supported: bash, zsh, fish, powershell)",
        .{shell},
    );
}

pub const ValidatedCommand = union(enum) {
    install: InstallCommand,
    remove: RemoveCommand,
    use: UseCommand,
    list: ListCommand,
    list_remote: ListRemoteCommand,
    list_mirrors: ListMirrorsCommand,
    clean: CleanCommand,
    env: EnvCommand,
    completions: CompletionsCommand,
    version: VersionCommand,
    help: HelpCommand,
    upgrade: UpgradeCommand,

    /// Validated install command
    pub const InstallCommand = struct {
        version: VersionSpec,
        version_raw: [max_version_string_length]u8,
        version_raw_length: u8,
        tool: ToolType,

        pub fn get_version(self: *const InstallCommand) []const u8 {
            assert(self.version_raw_length > 0);
            assert(self.version_raw_length <= max_version_string_length);
            return self.version_raw[0..self.version_raw_length];
        }

        pub fn validate_business_rules(self: InstallCommand) !void {
            switch (self.tool) {
                .zls => {
                    if (!self.version.is_compatible_with_zls()) {
                        return error.IncompatibleZLSVersion;
                    }
                },
                .zig => {}, // No additional validation needed
            }
        }
    };

    /// Validated remove command
    pub const RemoveCommand = struct {
        version: VersionSpec,
        version_raw: [max_version_string_length]u8,
        version_raw_length: u8,
        tool: ToolType,

        pub fn get_version(self: *const RemoveCommand) []const u8 {
            assert(self.version_raw_length > 0);
            assert(self.version_raw_length <= max_version_string_length);
            return self.version_raw[0..self.version_raw_length];
        }
    };

    /// Validated use command
    pub const UseCommand = struct {
        version: VersionSpec,
        version_raw: [max_version_string_length]u8,
        version_raw_length: u8,
        tool: ToolType,

        pub fn get_version(self: *const UseCommand) []const u8 {
            assert(self.version_raw_length > 0);
            assert(self.version_raw_length <= max_version_string_length);
            return self.version_raw[0..self.version_raw_length];
        }

        pub fn validate_business_rules(self: UseCommand) !void {
            switch (self.tool) {
                .zls => {
                    if (!self.version.is_compatible_with_zls()) {
                        return error.IncompatibleZLSVersion;
                    }
                },
                .zig => {}, // No additional validation needed
            }
        }
    };

    /// Validated list command
    pub const ListCommand = struct {
        show_all: bool,
    };

    /// Validated list-remote command
    pub const ListRemoteCommand = struct {
        tool: ToolType,
    };

    /// Validated list-mirrors command
    pub const ListMirrorsCommand = struct {};

    /// Validated clean command
    pub const CleanCommand = struct {
        remove_all: bool,
    };

    /// Validated env command
    pub const EnvCommand = struct {
        shell: ?ShellType,
    };

    /// Validated completions command
    pub const CompletionsCommand = struct {
        shell: ShellType,
    };

    /// Validated version command
    pub const VersionCommand = struct {};

    /// Validated help command
    pub const HelpCommand = struct {
        topic: HelpTopic = .general,
    };

    /// Validated upgrade command
    pub const UpgradeCommand = struct {};
};

pub fn parse_command_args(command_name: []const u8, args: []const []const u8) !ValidatedCommand {
    const command_args = try parse_command_syntax(command_name, args);
    return validate_command_args(command_args);
}

fn validate_command_args(command_args: CommandArgs) !ValidatedCommand {
    return switch (command_args) {
        .install => |args| .{ .install = try validate_install(args) },
        .remove => |args| .{ .remove = try validate_remove(args) },
        .use => |args| .{ .use = try validate_use(args) },
        .list => |args| .{ .list = try validate_list(args) },
        .list_remote => |args| .{ .list_remote = try validate_list_remote(args) },
        .list_mirrors => |args| .{ .list_mirrors = try validate_list_mirrors(args) },
        .clean => |args| .{ .clean = try validate_clean(args) },
        .env => |args| .{ .env = try validate_env(args) },
        .completions => |args| .{ .completions = try validate_completions(args) },
        .version => |args| .{ .version = try validate_version(args) },
        .help => |args| .{ .help = try validate_help(args) },
        .upgrade => |args| .{ .upgrade = try validate_upgrade(args) },
    };
}

fn validate_upgrade(args: CommandArgs.UpgradeArgs) !ValidatedCommand.UpgradeCommand {
    _ = args;
    return ValidatedCommand.UpgradeCommand{};
}

fn validate_install(args: CommandArgs.InstallArgs) !ValidatedCommand.InstallCommand {
    const version_str = args.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.exit_with(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.exit_with(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.exit_with(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.exit_with(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
        },
    };

    var version_raw = std.mem.zeroes([max_version_string_length]u8);
    @memcpy(version_raw[0..version_str.len], version_str);

    const tool = ToolType.from_bool(args.is_zls);
    const install_cmd = ValidatedCommand.InstallCommand{
        .version = version_spec,
        .version_raw = version_raw,
        .version_raw_length = @intCast(version_str.len),
        .tool = tool,
    };

    // Apply business rule validation
    install_cmd.validate_business_rules() catch |err| switch (err) {
        error.IncompatibleZLSVersion => {
            util_output.exit_with(.invalid_arguments, "ZLS version '{s}' is incompatible (requires Zig >= 0.11.0)", .{version_str});
        },
    };

    return install_cmd;
}

fn validate_remove(args: CommandArgs.RemoveArgs) !ValidatedCommand.RemoveCommand {
    const version_str = args.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.exit_with(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.exit_with(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.exit_with(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.exit_with(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
        },
    };

    var version_raw = std.mem.zeroes([max_version_string_length]u8);
    @memcpy(version_raw[0..version_str.len], version_str);

    return ValidatedCommand.RemoveCommand{
        .version = version_spec,
        .version_raw = version_raw,
        .version_raw_length = @intCast(version_str.len),
        .tool = ToolType.from_bool(args.is_zls),
    };
}

fn validate_use(args: CommandArgs.UseArgs) !ValidatedCommand.UseCommand {
    const version_str = args.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.exit_with(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.exit_with(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.exit_with(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.exit_with(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.exit_with(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.exit_with(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
        },
    };

    var version_raw = std.mem.zeroes([max_version_string_length]u8);
    @memcpy(version_raw[0..version_str.len], version_str);

    const tool = ToolType.from_bool(args.is_zls);
    const use_cmd = ValidatedCommand.UseCommand{
        .version = version_spec,
        .version_raw = version_raw,
        .version_raw_length = @intCast(version_str.len),
        .tool = tool,
    };

    // Apply business rule validation
    use_cmd.validate_business_rules() catch |err| switch (err) {
        error.IncompatibleZLSVersion => {
            util_output.exit_with(.invalid_arguments, "ZLS version '{s}' is incompatible (requires Zig >= 0.11.0)", .{version_str});
        },
    };

    return use_cmd;
}

fn validate_list(args: CommandArgs.ListArgs) !ValidatedCommand.ListCommand {
    return ValidatedCommand.ListCommand{
        .show_all = args.show_all,
    };
}

fn validate_list_remote(args: CommandArgs.ListRemoteArgs) !ValidatedCommand.ListRemoteCommand {
    return ValidatedCommand.ListRemoteCommand{
        .tool = ToolType.from_bool(args.is_zls),
    };
}

fn validate_list_mirrors(args: CommandArgs.ListMirrorsArgs) !ValidatedCommand.ListMirrorsCommand {
    _ = args;
    return ValidatedCommand.ListMirrorsCommand{};
}

fn validate_clean(args: CommandArgs.CleanArgs) !ValidatedCommand.CleanCommand {
    return ValidatedCommand.CleanCommand{
        .remove_all = args.remove_all,
    };
}

fn validate_env(args: CommandArgs.EnvArgs) !ValidatedCommand.EnvCommand {
    const shell = if (args.get_shell()) |shell_str|
        ShellType.parse(shell_str) catch |err| switch (err) {
            error.UnknownShell => {
                fatal_unknown_shell(shell_str);
            },
        }
    else
        null;

    return ValidatedCommand.EnvCommand{
        .shell = shell,
    };
}

fn validate_completions(args: CommandArgs.CompletionsArgs) !ValidatedCommand.CompletionsCommand {
    const shell = if (args.get_shell()) |shell_str|
        ShellType.parse(shell_str) catch |err| switch (err) {
            error.UnknownShell => {
                fatal_unknown_shell(shell_str);
            },
        }
    else blk: {
        // Try to detect shell from environment if not provided
        break :blk detect_shell_from_environment() orelse {
            util_output.exit_with(.invalid_arguments, "completions command requires a shell argument or SHELL environment variable", .{});
        };
    };

    return ValidatedCommand.CompletionsCommand{
        .shell = shell,
    };
}

fn validate_version(args: CommandArgs.VersionArgs) !ValidatedCommand.VersionCommand {
    _ = args;
    return ValidatedCommand.VersionCommand{};
}

fn validate_help(args: CommandArgs.HelpArgs) !ValidatedCommand.HelpCommand {
    const topic = if (args.get_topic()) |topic_str|
        HelpTopic.parse(topic_str) catch |err| switch (err) {
            error.UnknownHelpTopic => {
                fatal_unknown_help_topic(topic_str);
            },
        }
    else
        .general;

    return ValidatedCommand.HelpCommand{
        .topic = topic,
    };
}

fn detect_shell_from_environment() ?ShellType {
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        return .powershell;
    }

    const getenv = util_tool.getenv_cross_platform;
    const shell_path = getenv("SHELL") orelse return null;
    assert(shell_path.len > 0);

    const shell_name = std.fs.path.basename(shell_path);
    assert(shell_name.len > 0);
    assert(shell_name.len <= shell_path.len);

    return ShellType.parse(shell_name) catch null;
}

comptime {
    assert(@sizeOf(ValidatedCommand) <= 256);
    assert(@sizeOf(ValidatedCommand) >= 16);
    assert(@sizeOf(VersionSpec) <= 16);
    assert(@sizeOf(VersionSpec) >= 4);
    assert(@sizeOf(ValidatedCommand.InstallCommand) <= 128);
    assert(@sizeOf(ValidatedCommand.InstallCommand) >= 16);
    assert(@sizeOf(ValidatedCommand.RemoveCommand) <= 128);
    assert(@sizeOf(ValidatedCommand.RemoveCommand) >= 16);
    assert(@sizeOf(ValidatedCommand.UseCommand) <= 128);
    assert(@sizeOf(ValidatedCommand.UseCommand) >= 16);

    assert(@typeInfo(ShellType).@"enum".fields.len == 4);
    assert(@typeInfo(ToolType).@"enum".fields.len == 2);
    assert(@typeInfo(VersionSpec).@"union".fields.len == 2);
}
