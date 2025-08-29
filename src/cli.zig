const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");
const util_output = @import("util/output.zig");

/// Cross-platform environment variable getter
fn getenv_cross_platform(var_name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, env vars need special handling due to WTF-16 encoding
        // For optional env vars, just return null
        return null;
    } else {
        return std.posix.getenv(var_name);
    }
}

const max_argument_count = limits.limits.arguments_maximum;
const max_version_string_length = limits.limits.version_string_length_maximum;
const max_command_name_length = 32;

comptime {
    std.debug.assert(max_argument_count >= 4);
    std.debug.assert(max_argument_count <= 64);
    std.debug.assert(max_version_string_length >= 16);
    std.debug.assert(max_version_string_length <= 256);
    std.debug.assert(max_command_name_length >= 8);
    std.debug.assert(max_command_name_length <= 64);
}

/// Global configuration affecting all commands
pub const GlobalConfig = struct {
    output_mode: util_output.OutputMode,
    color_mode: util_output.ColorMode,

    pub fn validate(self: GlobalConfig) void {
        // Positive assertions: what we expect
        std.debug.assert(self.output_mode == .human_readable or
            self.output_mode == .machine_json or
            self.output_mode == .silent_errors_only);
        std.debug.assert(self.color_mode == .never_use_color or
            self.color_mode == .always_use_color);

        // Negative assertions: invalid combinations
        if (self.output_mode == .machine_json) {
            std.debug.assert(self.color_mode == .never_use_color);
        }
    }

    /// Default configuration for human users
    pub const default = GlobalConfig{
        .output_mode = .human_readable,
        .color_mode = .always_use_color,
    };

    comptime {
        std.debug.assert(@sizeOf(GlobalConfig) <= 16);
        std.debug.assert(@sizeOf(GlobalConfig) >= 2);
    }
};

/// Validated command ready for execution
pub const Command = union(enum) {
    install: InstallCommand,
    remove: RemoveCommand,
    use: UseCommand,
    list: ListCommand,
    list_remote: ListRemoteCommand,
    current: CurrentCommand,
    clean: CleanCommand,
    env: EnvCommand,
    completions: CompletionsCommand,
    version: VersionCommand,
    help: HelpCommand,

    /// Install command parameters
    pub const InstallCommand = struct {
        version_string: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const InstallCommand) []const u8 {
            std.debug.assert(self.version_length > 0);
            std.debug.assert(self.version_length <= max_version_string_length);
            return self.version_string[0..self.version_length];
        }

        comptime {
            std.debug.assert(@sizeOf(InstallCommand) >= max_version_string_length);
            std.debug.assert(@sizeOf(InstallCommand) <= max_version_string_length + 16);
        }
    };

    /// Remove command parameters
    pub const RemoveCommand = struct {
        version_string: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const RemoveCommand) []const u8 {
            std.debug.assert(self.version_length > 0);
            std.debug.assert(self.version_length <= max_version_string_length);
            return self.version_string[0..self.version_length];
        }
    };

    /// Use command parameters
    pub const UseCommand = struct {
        version_string: [max_version_string_length]u8,
        version_length: u8,
        is_zls: bool,

        pub fn get_version(self: *const UseCommand) []const u8 {
            std.debug.assert(self.version_length > 0);
            std.debug.assert(self.version_length <= max_version_string_length);
            return self.version_string[0..self.version_length];
        }
    };

    /// List command parameters
    pub const ListCommand = struct {
        show_all: bool,
    };

    /// List remote command parameters
    pub const ListRemoteCommand = struct {
        is_zls: bool,
    };

    /// Current version command (no parameters)
    pub const CurrentCommand = struct {};

    /// Clean command parameters
    pub const CleanCommand = struct {
        remove_all: bool,
    };

    /// Environment setup command parameters
    pub const EnvCommand = struct {
        shell_name: ?[32]u8, // Fixed size shell name buffer
        shell_length: u8,

        pub fn get_shell(self: *const EnvCommand) ?[]const u8 {
            if (self.shell_length == 0) return null;
            std.debug.assert(self.shell_length <= 32);
            return self.shell_name.?[0..self.shell_length];
        }
    };

    /// Completions command parameters
    pub const CompletionsCommand = struct {
        shell_type: ShellType,
    };

    /// Version command (no parameters)
    pub const VersionCommand = struct {};

    /// Help command (no parameters)
    pub const HelpCommand = struct {};

    /// Shell types for completions and environment
    pub const ShellType = enum {
        bash,
        zsh,
        fish,
        powershell,

        pub fn from_string(shell_name: []const u8) !ShellType {
            std.debug.assert(shell_name.len > 0);
            std.debug.assert(shell_name.len < 32);

            if (std.mem.eql(u8, shell_name, "bash")) return .bash;
            if (std.mem.eql(u8, shell_name, "zsh")) return .zsh;
            if (std.mem.eql(u8, shell_name, "fish")) return .fish;
            if (std.mem.eql(u8, shell_name, "powershell")) return .powershell;
            if (std.mem.eql(u8, shell_name, "pwsh")) return .powershell; // PowerShell Core alias

            return error.UnknownShell;
        }

        comptime {
            std.debug.assert(@typeInfo(ShellType).@"enum".fields.len == 4);
        }
    };

    comptime {
        const command_size = @sizeOf(Command);
        std.debug.assert(command_size >= max_version_string_length);
        std.debug.assert(command_size <= max_version_string_length + 64);
    }
};

/// Complete parsed command line
pub const ParsedCommandLine = struct {
    global_config: GlobalConfig,
    command: Command,

    pub fn validate(self: *const ParsedCommandLine) void {
        self.global_config.validate();

        // Command-specific validation
        switch (self.command) {
            .install => |cmd| {
                std.debug.assert(cmd.version_length > 0);
                std.debug.assert(cmd.version_length <= max_version_string_length);
            },
            .remove => |cmd| {
                std.debug.assert(cmd.version_length > 0);
                std.debug.assert(cmd.version_length <= max_version_string_length);
            },
            .use => |cmd| {
                std.debug.assert(cmd.version_length > 0);
                std.debug.assert(cmd.version_length <= max_version_string_length);
            },
            else => {}, // Other commands have no additional validation
        }
    }

    comptime {
        const parsed_size = @sizeOf(ParsedCommandLine);
        std.debug.assert(parsed_size >= @sizeOf(GlobalConfig) + @sizeOf(Command));
        std.debug.assert(parsed_size <= 512); // Keep reasonable
    }
};

/// Parse command line arguments with strict validation
pub fn parse_command_line(arguments: []const []const u8) !ParsedCommandLine {
    std.debug.assert(arguments.len > 0); // Must have program name
    std.debug.assert(arguments.len <= max_argument_count);

    // Validate all arguments are non-empty and reasonably sized
    for (arguments) |arg| {
        std.debug.assert(arg.len > 0);
        std.debug.assert(arg.len < 1024); // Reasonable argument length
    }

    var global_config = GlobalConfig.default;
    var arg_index: usize = 1; // Skip program name

    // Parse global flags first
    while (arg_index < arguments.len) {
        const arg = arguments[arg_index];

        if (std.mem.eql(u8, arg, "--json")) {
            global_config.output_mode = .machine_json;
            global_config.color_mode = .never_use_color; // JSON never uses color
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            global_config.output_mode = .silent_errors_only;
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--color")) {
            global_config.color_mode = .always_use_color;
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            global_config.color_mode = .never_use_color;
            arg_index += 1;
        } else {
            // Not a global flag, must be command
            break;
        }
    }

    // Must have a command
    if (arg_index >= arguments.len) {
        return ParsedCommandLine{
            .global_config = global_config,
            .command = .{ .help = .{} },
        };
    }

    const command_name = arguments[arg_index];
    std.debug.assert(command_name.len > 0);
    std.debug.assert(command_name.len <= max_command_name_length);

    arg_index += 1; // Move past command name
    const remaining_args = arguments[arg_index..];

    // Parse command
    const command = try parse_command(command_name, remaining_args);

    const result = ParsedCommandLine{
        .global_config = global_config,
        .command = command,
    };

    result.validate();
    return result;
}

/// Parse specific command with its arguments
fn parse_command(command_name: []const u8, args: []const []const u8) !Command {
    std.debug.assert(command_name.len > 0);
    std.debug.assert(command_name.len <= max_command_name_length);
    std.debug.assert(args.len <= max_argument_count);

    if (std.mem.eql(u8, command_name, "install") or std.mem.eql(u8, command_name, "i")) {
        return parse_install_command(args);
    }
    if (std.mem.eql(u8, command_name, "remove") or std.mem.eql(u8, command_name, "rm")) {
        return parse_remove_command(args);
    }
    if (std.mem.eql(u8, command_name, "use") or std.mem.eql(u8, command_name, "u")) {
        return parse_use_command(args);
    }
    if (std.mem.eql(u8, command_name, "list") or std.mem.eql(u8, command_name, "ls")) {
        return parse_list_command(args);
    }
    if (std.mem.eql(u8, command_name, "list-remote")) {
        return parse_list_remote_command(args);
    }
    if (std.mem.eql(u8, command_name, "current")) {
        return parse_current_command(args);
    }
    if (std.mem.eql(u8, command_name, "clean")) {
        return parse_clean_command(args);
    }
    if (std.mem.eql(u8, command_name, "env")) {
        return parse_env_command(args);
    }
    if (std.mem.eql(u8, command_name, "completions")) {
        return parse_completions_command(args);
    }
    if (std.mem.eql(u8, command_name, "version") or std.mem.eql(u8, command_name, "--version")) {
        return parse_version_command(args);
    }
    if (std.mem.eql(u8, command_name, "help") or std.mem.eql(u8, command_name, "--help")) {
        return parse_help_command(args);
    }

    // Unknown command
    util_output.fatal(.invalid_arguments, "Unknown command: '{s}'", .{command_name});
}

/// Parse install command arguments
fn parse_install_command(args: []const []const u8) !Command {
    if (args.len == 0) {
        util_output.fatal(.invalid_arguments, "install command requires a version argument", .{});
    }

    const version_arg = args[0];
    if (version_arg.len >= max_version_string_length) {
        util_output.fatal(.invalid_arguments, "version string too long: {d} >= {d}", .{ version_arg.len, max_version_string_length });
    }

    var install_cmd = Command.InstallCommand{
        .version_string = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };

    @memcpy(install_cmd.version_string[0..version_arg.len], version_arg);

    // Check for --zls flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            install_cmd.is_zls = true;
            break;
        }
    }

    return Command{ .install = install_cmd };
}

/// Parse remove command arguments
fn parse_remove_command(args: []const []const u8) !Command {
    if (args.len == 0) {
        util_output.fatal(.invalid_arguments, "remove command requires a version argument", .{});
    }

    const version_arg = args[0];
    if (version_arg.len >= max_version_string_length) {
        util_output.fatal(.invalid_arguments, "version string too long: {d} >= {d}", .{ version_arg.len, max_version_string_length });
    }

    var remove_cmd = Command.RemoveCommand{
        .version_string = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };

    @memcpy(remove_cmd.version_string[0..version_arg.len], version_arg);

    // Check for --zls flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            remove_cmd.is_zls = true;
            break;
        }
    }

    return Command{ .remove = remove_cmd };
}

/// Parse use command arguments
fn parse_use_command(args: []const []const u8) !Command {
    if (args.len == 0) {
        util_output.fatal(.invalid_arguments, "use command requires a version argument", .{});
    }

    const version_arg = args[0];
    if (version_arg.len >= max_version_string_length) {
        util_output.fatal(.invalid_arguments, "version string too long: {d} >= {d}", .{ version_arg.len, max_version_string_length });
    }

    var use_cmd = Command.UseCommand{
        .version_string = std.mem.zeroes([max_version_string_length]u8),
        .version_length = @intCast(version_arg.len),
        .is_zls = false,
    };

    @memcpy(use_cmd.version_string[0..version_arg.len], version_arg);

    // Check for --zls flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            use_cmd.is_zls = true;
            break;
        }
    }

    return Command{ .use = use_cmd };
}

/// Parse list command arguments
fn parse_list_command(args: []const []const u8) !Command {
    var list_cmd = Command.ListCommand{
        .show_all = false,
    };

    // Check for --all flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            list_cmd.show_all = true;
            break;
        }
    }

    return Command{ .list = list_cmd };
}

/// Parse list-remote command arguments
fn parse_list_remote_command(args: []const []const u8) !Command {
    var list_remote_cmd = Command.ListRemoteCommand{
        .is_zls = false,
    };

    // Check for --zls flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            list_remote_cmd.is_zls = true;
            break;
        }
    }

    return Command{ .list_remote = list_remote_cmd };
}

/// Parse current command arguments (no arguments expected)
fn parse_current_command(args: []const []const u8) !Command {
    _ = args; // No arguments expected
    return Command{ .current = .{} };
}

/// Parse clean command arguments
fn parse_clean_command(args: []const []const u8) !Command {
    var clean_cmd = Command.CleanCommand{
        .remove_all = false,
    };

    // Check for --all flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            clean_cmd.remove_all = true;
            break;
        }
    }

    return Command{ .clean = clean_cmd };
}

/// Parse env command arguments
fn parse_env_command(args: []const []const u8) !Command {
    var env_cmd = Command.EnvCommand{
        .shell_name = null,
        .shell_length = 0,
    };

    // Look for --shell argument
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--shell") and i + 1 < args.len) {
            const shell_arg = args[i + 1];
            if (shell_arg.len > 32) {
                util_output.fatal(.invalid_arguments, "shell name too long: {d} > 32", .{shell_arg.len});
            }

            env_cmd.shell_name = std.mem.zeroes([32]u8);
            @memcpy(env_cmd.shell_name.?[0..shell_arg.len], shell_arg);
            env_cmd.shell_length = @intCast(shell_arg.len);
            break;
        }
    }

    return Command{ .env = env_cmd };
}

/// Parse completions command arguments
fn parse_completions_command(args: []const []const u8) !Command {
    if (args.len == 0) {
        // Try to detect shell from environment
        const shell_type = detect_shell() orelse {
            util_output.fatal(.invalid_arguments, "completions command requires a shell argument or SHELL environment variable", .{});
        };

        return Command{ .completions = .{ .shell_type = shell_type } };
    }

    const shell_arg = args[0];
    const shell_type = Command.ShellType.from_string(shell_arg) catch {
        util_output.fatal(.invalid_arguments, "unknown shell type: '{s}' (supported: bash, zsh, fish, powershell)", .{shell_arg});
    };

    return Command{ .completions = .{ .shell_type = shell_type } };
}

/// Parse version command arguments (no arguments expected)
fn parse_version_command(args: []const []const u8) !Command {
    _ = args; // No arguments expected
    return Command{ .version = .{} };
}

/// Parse help command arguments (no arguments expected)
fn parse_help_command(args: []const []const u8) !Command {
    _ = args; // No arguments expected
    return Command{ .help = .{} };
}

/// Detect shell type from environment
fn detect_shell() ?Command.ShellType {
    if (builtin.os.tag == .windows) {
        return .powershell;
    }

    const shell_path = getenv_cross_platform("SHELL") orelse return null;
    const shell_name = std.fs.path.basename(shell_path);

    return Command.ShellType.from_string(shell_name) catch null;
}

comptime {
    std.debug.assert(@sizeOf(ParsedCommandLine) <= 1024);
    std.debug.assert(@sizeOf(Command) >= @sizeOf(Command.InstallCommand));

    // Assert all command types are reasonably sized
    std.debug.assert(@sizeOf(Command.InstallCommand) <= 512);
    std.debug.assert(@sizeOf(Command.RemoveCommand) <= 512);
    std.debug.assert(@sizeOf(Command.UseCommand) <= 512);
}
