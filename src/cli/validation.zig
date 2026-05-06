const std = @import("std");
const limits = @import("../memory/limits.zig");
const edit_distance = @import("../util/edit_distance.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
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

fn is_option_terminator(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--");
}

fn is_prefixed_option(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn parse_attached_option_value(arg: []const u8, comptime option_name: []const u8) ![]const u8 {
    comptime {
        assert(option_name.len >= 3);
        assert(option_name[0] == '-');
        assert(option_name[1] == '-');
        assert(std.mem.indexOfScalar(u8, option_name, '=') == null);
    }
    assert(arg.len > 0);

    if (!std.mem.startsWith(u8, arg, option_name)) return error.UnknownFlag;

    const suffix = arg[option_name.len..];
    if (suffix.len == 0) return error.MissingOptionValueSeparator;
    if (suffix[0] != '=') return error.MissingOptionValueSeparator;
    if (suffix.len == 1) return error.EmptyOptionValue;
    return suffix[1..];
}

const VersionAndToolArgs = struct {
    version_arg: []const u8,
    is_zls: bool,
};

fn validate_version_arg(version_arg: []const u8) !void {
    assert(version_arg.len < 1024);

    if (version_arg.len == 0) {
        return error.EmptyVersionArgument;
    }
    if (version_arg.len >= max_version_string_length) {
        return error.VersionStringTooLong;
    }
}

fn parse_version_and_tool_args(args: []const []const u8) !VersionAndToolArgs {
    assert(args.len <= limits.limits.arguments_maximum);

    if (args.len == 0) {
        return error.MissingVersionArgument;
    }

    var is_zls = false;
    var version_arg: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        assert(arg.len < 1024);

        if (version_arg == null) {
            if (is_option_terminator(arg)) {
                i += 1;
                if (i >= args.len) {
                    return error.MissingVersionArgument;
                }
                if (i + 1 < args.len) {
                    return error.UnexpectedArguments;
                }

                version_arg = args[i];
                break;
            }
            if (std.mem.eql(u8, arg, "--zls")) {
                if (is_zls) return error.DuplicateOption;
                is_zls = true;
                continue;
            }
            if (is_prefixed_option(arg)) {
                return error.UnknownFlag;
            }

            version_arg = arg;
            continue;
        }

        if (std.mem.eql(u8, arg, "--zls")) {
            return error.TrailingOption;
        }
        if (is_option_terminator(arg)) {
            if (i + 1 < args.len) {
                return error.UnexpectedArguments;
            }
            break;
        }
        if (is_prefixed_option(arg)) {
            return error.UnknownFlag;
        }

        return error.UnexpectedArguments;
    }

    const parsed_version_arg = version_arg orelse return error.MissingVersionArgument;
    try validate_version_arg(parsed_version_arg);

    return .{
        .version_arg = parsed_version_arg,
        .is_zls = is_zls,
    };
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

    if (std.mem.eql(u8, command_name, "install") or std.mem.eql(u8, command_name, "i")) {
        return .{ .install = try parse_install_args(args) };
    }
    if (std.mem.eql(u8, command_name, "remove") or std.mem.eql(u8, command_name, "rm")) {
        return .{ .remove = try parse_remove_args(args) };
    }
    if (std.mem.eql(u8, command_name, "use") or std.mem.eql(u8, command_name, "u")) {
        return .{ .use = try parse_use_args(args) };
    }
    if (std.mem.eql(u8, command_name, "list") or std.mem.eql(u8, command_name, "ls")) {
        return .{ .list = try parse_list_args(args) };
    }
    if (std.mem.eql(u8, command_name, "list-remote")) {
        return .{ .list_remote = try parse_list_remote_args(args) };
    }
    if (std.mem.eql(u8, command_name, "clean")) {
        return .{ .clean = try parse_clean_args(args) };
    }
    if (std.mem.eql(u8, command_name, "env")) {
        return .{ .env = try parse_env_args(args) };
    }
    if (std.mem.eql(u8, command_name, "completions")) {
        return .{ .completions = try parse_completions_args(args) };
    }
    if (std.mem.eql(u8, command_name, "version")) {
        return .{ .version = try parse_version_args(args) };
    }
    if (std.mem.eql(u8, command_name, "help")) {
        return .{ .help = try parse_help_args(args) };
    }
    if (std.mem.eql(u8, command_name, "list-mirrors")) {
        return .{ .list_mirrors = try parse_list_mirrors_args(args) };
    }
    if (std.mem.eql(u8, command_name, "upgrade")) {
        return .{ .upgrade = try parse_upgrade_args(args) };
    }

    return error.UnknownCommand;
}

fn parse_install_args(args: []const []const u8) !CommandArgs.InstallArgs {
    const parsed_args = try parse_version_and_tool_args(args);
    const version_arg = parsed_args.version_arg;

    var install_args = CommandArgs.InstallArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = parsed_args.is_zls,
    };
    assert(install_args.version_length > 0);
    assert(install_args.version_length < max_version_string_length);

    @memcpy(install_args.version[0..version_arg.len], version_arg);
    assert(install_args.version[0] != 0);

    const result_version = install_args.get_version();
    assert(result_version.len == version_arg.len);
    assert(std.mem.eql(u8, result_version, version_arg));
    return install_args;
}

fn parse_remove_args(args: []const []const u8) !CommandArgs.RemoveArgs {
    const parsed_args = try parse_version_and_tool_args(args);
    const version_arg = parsed_args.version_arg;

    var remove_args = CommandArgs.RemoveArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = parsed_args.is_zls,
    };

    @memcpy(remove_args.version[0..version_arg.len], version_arg);

    return remove_args;
}

fn parse_use_args(args: []const []const u8) !CommandArgs.UseArgs {
    const parsed_args = try parse_version_and_tool_args(args);
    const version_arg = parsed_args.version_arg;

    var use_args = CommandArgs.UseArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = parsed_args.is_zls,
    };

    @memcpy(use_args.version[0..version_arg.len], version_arg);

    return use_args;
}

fn parse_list_args(args: []const []const u8) !CommandArgs.ListArgs {
    var list_args = CommandArgs.ListArgs{};

    for (args, 0..) |arg, index| {
        if (is_option_terminator(arg)) {
            if (index + 1 < args.len) {
                return error.UnexpectedArguments;
            }
            break;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (list_args.show_all) return error.DuplicateOption;
            list_args.show_all = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return list_args;
}

fn parse_list_remote_args(args: []const []const u8) !CommandArgs.ListRemoteArgs {
    var list_remote_args = CommandArgs.ListRemoteArgs{};

    for (args, 0..) |arg, index| {
        if (is_option_terminator(arg)) {
            if (index + 1 < args.len) {
                return error.UnexpectedArguments;
            }
            break;
        }
        if (std.mem.eql(u8, arg, "--zls")) {
            if (list_remote_args.is_zls) return error.DuplicateOption;
            list_remote_args.is_zls = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return list_remote_args;
}

fn parse_clean_args(args: []const []const u8) !CommandArgs.CleanArgs {
    var clean_args = CommandArgs.CleanArgs{};

    for (args, 0..) |arg, index| {
        if (is_option_terminator(arg)) {
            if (index + 1 < args.len) {
                return error.UnexpectedArguments;
            }
            break;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (clean_args.remove_all) return error.DuplicateOption;
            clean_args.remove_all = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return clean_args;
}

fn parse_env_args(args: []const []const u8) !CommandArgs.EnvArgs {
    var env_args = CommandArgs.EnvArgs{};

    var i: usize = 0;
    while (i < args.len) {
        if (is_option_terminator(args[i])) {
            if (i + 1 < args.len) {
                return error.UnexpectedArguments;
            }
            break;
        }
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--shell=")) {
            _ = try parse_attached_option_value(arg, "--shell");
        }

        const shell_arg = try parse_attached_option_value(arg, "--shell");
        if (env_args.shell_length != 0) return error.DuplicateOption;
        if (shell_arg.len > max_shell_name_length) {
            return error.ShellNameTooLong;
        }

        env_args.shell_name = std.mem.zeroes([max_shell_name_length]u8);
        @memcpy(env_args.shell_name.?[0..shell_arg.len], shell_arg);
        env_args.shell_length = @intCast(shell_arg.len);
        i += 1;
    }

    return env_args;
}

fn parse_completions_args(args: []const []const u8) !CommandArgs.CompletionsArgs {
    assert(args.len <= limits.limits.arguments_maximum);

    var completions_args = CommandArgs.CompletionsArgs{
        .shell = null,
        .shell_length = 0,
    };

    var shell_index: usize = 0;
    if (args.len > 0 and is_option_terminator(args[0])) {
        shell_index = 1;
    }

    if (shell_index < args.len) {
        const shell_arg = args[shell_index];
        assert(shell_arg.len < 1024);

        if (shell_arg.len == 0) {
            return error.EmptyShellArgument;
        }
        if (shell_arg.len > max_shell_name_length) {
            return error.ShellNameTooLong;
        }

        completions_args.shell = std.mem.zeroes([max_shell_name_length]u8);
        @memcpy(completions_args.shell.?[0..shell_arg.len], shell_arg);
        completions_args.shell_length = @intCast(shell_arg.len);
        assert(completions_args.shell_length > 0);
        assert(completions_args.shell_length == shell_arg.len);

        if (shell_index + 1 < args.len) {
            return error.TooManyArguments;
        }
    }

    const result_shell = completions_args.get_shell();
    if (completions_args.shell_length > 0) {
        assert(result_shell != null);
        assert(result_shell.?.len == completions_args.shell_length);
    } else {
        assert(result_shell == null);
    }

    return completions_args;
}

fn parse_version_args(args: []const []const u8) !CommandArgs.VersionArgs {
    if (args.len == 1 and is_option_terminator(args[0])) {
        return CommandArgs.VersionArgs{};
    }
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return CommandArgs.VersionArgs{};
}

fn parse_help_args(args: []const []const u8) !CommandArgs.HelpArgs {
    var help_args = CommandArgs.HelpArgs{};

    if (args.len == 0) return help_args;

    var topic_index: usize = 0;
    if (args.len >= 1 and is_option_terminator(args[0])) {
        if (args.len == 1) return help_args;
        topic_index = 1;
    }

    if (args.len != topic_index + 1) {
        return error.TooManyArguments;
    }

    const topic_arg = args[topic_index];
    if (std.mem.eql(u8, topic_arg, "--help") or std.mem.eql(u8, topic_arg, "-h")) {
        return help_args;
    }
    if (topic_arg.len == 0) {
        return error.EmptyHelpTopic;
    }
    if (topic_arg.len > max_help_topic_length) {
        return error.HelpTopicTooLong;
    }

    help_args.topic = std.mem.zeroes([max_help_topic_length]u8);
    @memcpy(help_args.topic.?[0..topic_arg.len], topic_arg);
    help_args.topic_length = @intCast(topic_arg.len);
    return help_args;
}

fn parse_list_mirrors_args(args: []const []const u8) !CommandArgs.ListMirrorsArgs {
    if (args.len == 1 and is_option_terminator(args[0])) {
        return CommandArgs.ListMirrorsArgs{};
    }
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return CommandArgs.ListMirrorsArgs{};
}

fn parse_upgrade_args(args: []const []const u8) !CommandArgs.UpgradeArgs {
    if (args.len == 1 and is_option_terminator(args[0])) {
        return CommandArgs.UpgradeArgs{};
    }
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return CommandArgs.UpgradeArgs{};
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

        if (std.mem.eql(u8, topic_str, "install") or std.mem.eql(u8, topic_str, "i")) return .install;
        if (std.mem.eql(u8, topic_str, "remove") or std.mem.eql(u8, topic_str, "rm")) return .remove;
        if (std.mem.eql(u8, topic_str, "use") or std.mem.eql(u8, topic_str, "u")) return .use;
        if (std.mem.eql(u8, topic_str, "list") or std.mem.eql(u8, topic_str, "ls")) return .list;
        if (std.mem.eql(u8, topic_str, "list-remote")) return .list_remote;
        if (std.mem.eql(u8, topic_str, "list-mirrors")) return .list_mirrors;
        if (std.mem.eql(u8, topic_str, "clean")) return .clean;
        if (std.mem.eql(u8, topic_str, "env")) return .env;
        if (std.mem.eql(u8, topic_str, "completions")) return .completions;
        if (std.mem.eql(u8, topic_str, "version")) return .version;
        if (std.mem.eql(u8, topic_str, "help")) return .help;
        if (std.mem.eql(u8, topic_str, "upgrade")) return .upgrade;

        return error.UnknownHelpTopic;
    }
};

const help_topic_names = [_][]const u8{
    "install",
    "i",
    "remove",
    "rm",
    "use",
    "u",
    "list",
    "ls",
    "list-remote",
    "list-mirrors",
    "clean",
    "env",
    "completions",
    "version",
    "help",
    "upgrade",
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
        if (std.mem.eql(u8, shell_str, "pwsh")) return .powershell; // PowerShell Core alias

        return error.UnknownShell;
    }
};

const shell_names = [_][]const u8{
    "bash",
    "zsh",
    "fish",
    "powershell",
    "pwsh",
};

fn fatal_unknown_help_topic(topic: []const u8) noreturn {
    if (edit_distance.nearest(topic, &help_topic_names)) |suggestion| {
        util_output.fatal(
            .invalid_arguments,
            "unknown help topic '{s}'\n\n  Did you mean '{s}'?",
            .{ topic, suggestion },
        );
    }
    util_output.fatal(.invalid_arguments, "unknown help topic '{s}'", .{topic});
}

fn fatal_unknown_shell(shell: []const u8) noreturn {
    if (edit_distance.nearest(shell, &shell_names)) |suggestion| {
        util_output.fatal(
            .invalid_arguments,
            "unknown shell type '{s}'\n\n  Did you mean '{s}'?",
            .{ shell, suggestion },
        );
    }
    util_output.fatal(
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
            util_output.fatal(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.fatal(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.fatal(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.fatal(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.fatal(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
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
            util_output.fatal(.invalid_arguments, "ZLS version '{s}' is incompatible (requires Zig >= 0.11.0)", .{version_str});
        },
    };

    return install_cmd;
}

fn validate_remove(args: CommandArgs.RemoveArgs) !ValidatedCommand.RemoveCommand {
    const version_str = args.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.fatal(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.fatal(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.fatal(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.fatal(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.fatal(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
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
            util_output.fatal(
                .invalid_arguments,
                "invalid version format: '{s}' (expected: x.y.z[-prerelease][+build] or 'master')",
                .{version_str},
            );
        },
        error.TooManyVersionParts => {
            util_output.fatal(
                .invalid_arguments,
                "too many version parts in '{s}' (expected core: x.y.z)",
                .{version_str},
            );
        },
        error.InvalidMajorVersion => {
            util_output.fatal(.invalid_arguments, "invalid major version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidMinorVersion => {
            util_output.fatal(.invalid_arguments, "invalid minor version in '{s}' (must be a number)", .{version_str});
        },
        error.InvalidPatchVersion => {
            util_output.fatal(.invalid_arguments, "invalid patch version in '{s}' (must be a number)", .{version_str});
        },
        error.MajorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "major version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.MinorVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "minor version too large in '{s}' (maximum: 99)", .{version_str});
        },
        error.PatchVersionTooLarge => {
            util_output.fatal(.invalid_arguments, "patch version too large in '{s}' (maximum: 999)", .{version_str});
        },
        error.LatestNotSupported => {
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.16.0'", .{});
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
            util_output.fatal(.invalid_arguments, "ZLS version '{s}' is incompatible (requires Zig >= 0.11.0)", .{version_str});
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
            util_output.fatal(.invalid_arguments, "completions command requires a shell argument or SHELL environment variable", .{});
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
