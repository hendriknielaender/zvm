const std = @import("std");
const limits = @import("../memory/limits.zig");
const assert = std.debug.assert;

const max_version_string_length = limits.limits.version_string_length_maximum;
const max_shell_name_length = 32;

comptime {
    assert(max_version_string_length >= 16);
    assert(max_version_string_length <= 256);
    assert(max_shell_name_length >= 8);
    assert(max_shell_name_length <= 64);
}

/// Stage 1: Raw argument parsing with minimal validation
/// Performs only syntax parsing, no semantic validation or business rules
pub const RawArgs = union(enum) {
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

    /// Raw list command arguments
    pub const ListArgs = struct {
        show_all: bool = false,
    };

    /// Raw list-remote command arguments
    pub const ListRemoteArgs = struct {
        is_zls: bool = false,
    };

    /// Raw clean command arguments
    pub const CleanArgs = struct {
        remove_all: bool = false,
    };

    /// Raw env command arguments
    pub const EnvArgs = struct {
        shell_name: ?[max_shell_name_length]u8 = null,
        shell_length: u8 = 0,

        pub fn get_shell(self: *const EnvArgs) ?[]const u8 {
            if (self.shell_length == 0) return null;
            assert(self.shell_length <= max_shell_name_length);
            return self.shell_name.?[0..self.shell_length];
        }
    };

    /// Raw completions command arguments
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

    /// Raw version command arguments
    pub const VersionArgs = struct {};

    /// Raw help command arguments
    pub const HelpArgs = struct {};

    /// Raw list-mirrors command arguments
    pub const ListMirrorsArgs = struct {};
};

pub fn parse_raw_args(command_name: []const u8, args: []const []const u8) !RawArgs {
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
    if (std.mem.eql(u8, command_name, "version") or std.mem.eql(u8, command_name, "--version")) {
        return .{ .version = try parse_version_args(args) };
    }
    if (std.mem.eql(u8, command_name, "help") or std.mem.eql(u8, command_name, "--help")) {
        return .{ .help = try parse_help_args(args) };
    }
    if (std.mem.eql(u8, command_name, "list-mirrors")) {
        return .{ .list_mirrors = try parse_list_mirrors_args(args) };
    }

    return error.UnknownCommand;
}

fn parse_install_args(args: []const []const u8) !RawArgs.InstallArgs {
    assert(args.len <= limits.limits.arguments_maximum);

    if (args.len == 0) {
        return error.MissingVersionArgument;
    }

    const version_arg = args[0];
    assert(version_arg.len < 1024);

    if (version_arg.len == 0) {
        return error.EmptyVersionArgument;
    }
    if (version_arg.len >= max_version_string_length) {
        return error.VersionStringTooLong;
    }

    var install_args = RawArgs.InstallArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };
    assert(install_args.version_length > 0);
    assert(install_args.version_length < max_version_string_length);

    @memcpy(install_args.version[0..version_arg.len], version_arg);
    assert(install_args.version[0] != 0);

    for (args[1..]) |arg| {
        assert(arg.len > 0);

        if (std.mem.eql(u8, arg, "--zls")) {
            install_args.is_zls = true;
        } else {
            return error.UnknownFlag;
        }
    }

    const result_version = install_args.get_version();
    assert(result_version.len == version_arg.len);
    assert(std.mem.eql(u8, result_version, version_arg));
    return install_args;
}

fn parse_remove_args(args: []const []const u8) !RawArgs.RemoveArgs {
    if (args.len == 0) {
        return error.MissingVersionArgument;
    }

    const version_arg = args[0];
    if (version_arg.len == 0) {
        return error.EmptyVersionArgument;
    }
    if (version_arg.len >= max_version_string_length) {
        return error.VersionStringTooLong;
    }

    var remove_args = RawArgs.RemoveArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };

    @memcpy(remove_args.version[0..version_arg.len], version_arg);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            remove_args.is_zls = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return remove_args;
}

fn parse_use_args(args: []const []const u8) !RawArgs.UseArgs {
    if (args.len == 0) {
        return error.MissingVersionArgument;
    }

    const version_arg = args[0];
    if (version_arg.len == 0) {
        return error.EmptyVersionArgument;
    }
    if (version_arg.len >= max_version_string_length) {
        return error.VersionStringTooLong;
    }

    var use_args = RawArgs.UseArgs{
        .version = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };

    @memcpy(use_args.version[0..version_arg.len], version_arg);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            use_args.is_zls = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return use_args;
}

fn parse_list_args(args: []const []const u8) !RawArgs.ListArgs {
    var list_args = RawArgs.ListArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            list_args.show_all = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return list_args;
}

fn parse_list_remote_args(args: []const []const u8) !RawArgs.ListRemoteArgs {
    var list_remote_args = RawArgs.ListRemoteArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            list_remote_args.is_zls = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return list_remote_args;
}

fn parse_clean_args(args: []const []const u8) !RawArgs.CleanArgs {
    var clean_args = RawArgs.CleanArgs{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            clean_args.remove_all = true;
        } else {
            return error.UnknownFlag;
        }
    }

    return clean_args;
}

fn parse_env_args(args: []const []const u8) !RawArgs.EnvArgs {
    var env_args = RawArgs.EnvArgs{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shell") and i + 1 < args.len) {
            const shell_arg = args[i + 1];
            if (shell_arg.len == 0) {
                return error.EmptyShellArgument;
            }
            if (shell_arg.len > max_shell_name_length) {
                return error.ShellNameTooLong;
            }

            env_args.shell_name = std.mem.zeroes([max_shell_name_length]u8);
            @memcpy(env_args.shell_name.?[0..shell_arg.len], shell_arg);
            env_args.shell_length = @intCast(shell_arg.len);
            i += 1; // Skip the shell argument
        } else {
            return error.UnknownFlag;
        }
    }

    return env_args;
}

fn parse_completions_args(args: []const []const u8) !RawArgs.CompletionsArgs {
    assert(args.len <= limits.limits.arguments_maximum);

    var completions_args = RawArgs.CompletionsArgs{
        .shell = null,
        .shell_length = 0,
    };

    if (args.len > 0) {
        const shell_arg = args[0];
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

        if (args.len > 1) {
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

fn parse_version_args(args: []const []const u8) !RawArgs.VersionArgs {
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return RawArgs.VersionArgs{};
}

fn parse_help_args(args: []const []const u8) !RawArgs.HelpArgs {
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return RawArgs.HelpArgs{};
}

fn parse_list_mirrors_args(args: []const []const u8) !RawArgs.ListMirrorsArgs {
    if (args.len > 0) {
        return error.UnexpectedArguments;
    }
    return RawArgs.ListMirrorsArgs{};
}

comptime {
    assert(@sizeOf(RawArgs) <= 512);
    assert(@sizeOf(RawArgs) > 0);
    assert(@sizeOf(RawArgs.InstallArgs) <= 300);
    assert(@sizeOf(RawArgs.InstallArgs) > 0);
    assert(@sizeOf(RawArgs.RemoveArgs) <= 300);
    assert(@sizeOf(RawArgs.RemoveArgs) > 0);
    assert(@sizeOf(RawArgs.UseArgs) <= 300);
    assert(@sizeOf(RawArgs.UseArgs) > 0);
    assert(@sizeOf(RawArgs.CompletionsArgs) <= 64);
    assert(@sizeOf(RawArgs.CompletionsArgs) > 0);

    assert(@typeInfo(RawArgs).@"union".fields.len == 11);
    assert(max_version_string_length == limits.limits.version_string_length_maximum);
    assert(max_shell_name_length == 32);
    assert(max_version_string_length >= 16);
    assert(max_version_string_length <= 512);
}
