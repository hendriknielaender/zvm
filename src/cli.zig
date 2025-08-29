const std = @import("std");
const builtin = @import("builtin");
const flags = @import("flags.zig");
const cli_args = @import("cli_args.zig");
const limits = @import("limits.zig");

const CLIArgs = cli_args.CLIArgs;

/// Validated command data ready for execution
/// This is the second phase after parsing - all data is validated and normalized
pub const Command = union(enum) {
    pub const List = struct {
        list_all: bool,
        show_mirrors: bool,
        debug: bool,
    };

    pub const Install = struct {
        version: []const u8, // Changed to string for simplicity in static context.
        zls: bool,
    };

    pub const Use = struct {
        version: []const u8, // Changed to string for simplicity in static context.
        zls: bool,
    };

    pub const Remove = struct {
        version: []const u8, // Changed to string for simplicity in static context.
        zls: bool,
    };

    pub const Clean = struct {
        all: bool,
    };

    pub const VersionCmd = struct {
        verbose: bool,
    };

    pub const Help = struct {};

    pub const ListRemote = struct {
        zls: bool,
    };

    pub const Current = struct {};

    pub const Env = struct {
        shell: ?[]const u8,
    };

    pub const Completions = struct {
        shell: Shell,
    };

    // Validated command variants
    list: List,
    install: Install,
    use: Use,
    remove: Remove,
    clean: Clean,
    version: VersionCmd,
    help: Help,
    @"list-remote": ListRemote,
    current: Current,
    env: Env,
    completions: Completions,
};

/// Represents a validated version specification
pub const ZigVersion = union(enum) {
    master,
    latest,
    specific: struct {
        major: u32,
        minor: u32,
        patch: u32,
    },

    pub fn toString(self: ZigVersion, buf: []u8) ![]const u8 {
        std.debug.assert(buf.len >= 32); // "4294967295.4294967295.4294967295" worst case

        return switch (self) {
            .master => "master",
            .latest => "latest",
            .specific => |v| blk: {
                // Validate version components
                std.debug.assert(v.major < 1000); // Reasonable version bounds
                std.debug.assert(v.minor < 1000);
                std.debug.assert(v.patch < 10000);

                const result = try std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
                std.debug.assert(result.len <= buf.len);
                break :blk result;
            },
        };
    }

    pub fn parse(str: []const u8) !ZigVersion {
        std.debug.assert(str.len > 0);
        std.debug.assert(str.len < 100); // Reasonable version string length

        if (std.mem.eql(u8, str, "master")) {
            return .master;
        }
        if (std.mem.eql(u8, str, "latest")) {
            return .latest;
        }
        // Not a special version, parse as semantic version
        {
            // Parse semantic version
            var iter = std.mem.splitScalar(u8, str, '.');
            const major_str = iter.next() orelse {
                std.log.err("Invalid version '{s}': missing major version number. Expected format 'X.Y.Z'", .{str});
                return error.InvalidVersion;
            };
            const minor_str = iter.next() orelse {
                std.log.err("Invalid version '{s}': missing minor version number. Expected format 'X.Y.Z'", .{str});
                return error.InvalidVersion;
            };
            const patch_str = iter.next() orelse {
                std.log.err("Invalid version '{s}': missing patch version number. Expected format 'X.Y.Z'", .{str});
                return error.InvalidVersion;
            };

            // Validate format: exactly 3 parts
            if (iter.next() != null) {
                std.log.err("Invalid version '{s}': too many version components. Expected format 'X.Y.Z' with exactly 3 parts", .{str});
                return error.InvalidVersion;
            }

            // Validate each part is non-empty
            if (major_str.len == 0) {
                std.log.err("Invalid version '{s}': major version cannot be empty", .{str});
                return error.InvalidVersion;
            }
            if (minor_str.len == 0) {
                std.log.err("Invalid version '{s}': minor version cannot be empty", .{str});
                return error.InvalidVersion;
            }
            if (patch_str.len == 0) {
                std.log.err("Invalid version '{s}': patch version cannot be empty", .{str});
                return error.InvalidVersion;
            }

            return ZigVersion{
                .specific = .{
                    .major = std.fmt.parseInt(u32, major_str, 10) catch {
                        std.log.err("Invalid version '{s}': major version '{s}' is not a valid number", .{ str, major_str });
                        return error.InvalidVersion;
                    },
                    .minor = std.fmt.parseInt(u32, minor_str, 10) catch {
                        std.log.err("Invalid version '{s}': minor version '{s}' is not a valid number", .{ str, minor_str });
                        return error.InvalidVersion;
                    },
                    .patch = std.fmt.parseInt(u32, patch_str, 10) catch {
                        std.log.err("Invalid version '{s}': patch version '{s}' is not a valid number", .{ str, patch_str });
                        return error.InvalidVersion;
                    },
                },
            };
        }
    }
};

/// Supported shell types for completions
pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    /// Static map for efficient shell lookup
    pub const shell_map = std.StaticStringMap(Shell).initComptime(.{
        .{ "bash", .bash },
        .{ "zsh", .zsh },
        .{ "fish", .fish },
        .{ "powershell", .powershell },
    });

    pub fn parse(str: []const u8) !Shell {
        std.debug.assert(str.len > 0);
        std.debug.assert(str.len < 50); // Reasonable shell name length

        // Use static map for O(1) lookup
        return shell_map.get(str) orelse {
            std.log.err("Unknown shell '{s}'. Supported shells: bash, zsh, fish, powershell", .{str});
            return error.UnknownShell;
        };
    }
};

/// Command types for dispatch
pub const CommandType = enum {
    list,
    install,
    use,
    remove,
    clean,
    version,
    help,
    list_remote,
    current,
    env,
    completions,
};

/// Static map for efficient command lookup
pub const command_map = std.StaticStringMap(CommandType).initComptime(.{
    .{ "list", .list },
    .{ "install", .install },
    .{ "i", .install }, // Short alias for install
    .{ "use", .use },
    .{ "remove", .remove },
    .{ "clean", .clean },
    .{ "version", .version },
    .{ "help", .help },
    .{ "list-remote", .list_remote },
    .{ "current", .current },
    .{ "env", .env },
    .{ "completions", .completions },
    // Also support --help and --version as commands
    .{ "--help", .help },
    .{ "--version", .version },
});

/// Parse command line arguments into validated commands
pub fn parse_args(arguments_iteratorator: *std.process.ArgIterator) Command {
    const cli_args_parsed = flags.parse(arguments_iteratorator, CLIArgs);

    return switch (cli_args_parsed) {
        .list => |list| .{ .list = parse_args_list(list) },
        .install => |install| .{ .install = parse_args_install(install) },
        .use => |use| .{ .use = parse_args_use(use) },
        .remove => |remove| .{ .remove = parse_args_remove(remove) },
        .clean => |clean| .{ .clean = parse_args_clean(clean) },
        .version => |version| .{ .version = parse_args_version(version) },
        .help => |help| .{ .help = parse_args_help(help) },
        .completions => |completions| .{ .completions = parse_args_completions(completions) },
    };
}

/// Parse command line arguments from static array.
pub fn parse_args_static(args: [][]const u8) Command {
    std.debug.assert(args.len > 0); // At least program name
    std.debug.assert(args.len <= limits.limits.arguments_maximum);

    // Validate all args are non-empty
    for (args) |arg| {
        std.debug.assert(arg.len > 0);
    }

    // Simple manual parsing since we don't have an iterator.
    if (args.len < 2) {
        return .{ .help = .{} };
    }

    const command_str = args[1];
    // Command string must be valid
    std.debug.assert(command_str.len > 0);
    std.debug.assert(command_str.len < 100); // Reasonable command length

    // Use static map for O(1) command lookup
    const command_type = command_map.get(command_str) orelse {
        fatal("unknown command: '{s}'", .{command_str});
    };

    return switch (command_type) {
        .help => .{ .help = .{} },
        .version => .{ .version = .{ .verbose = false } },
        .list => .{ .list = .{ .list_all = false, .show_mirrors = false, .debug = false } },
        .list_remote => parse_list_remote_args(args),
        .current => .{ .current = .{} },
        .env => parse_env_args(args),
        .clean => parse_clean_args(args),
        .install => parse_install_args_static(args),
        .remove => parse_remove_args_static(args),
        .use => parse_use_args_static(args),
        .completions => unreachable, // Not handled in static parsing
    };
}

/// Parse list-remote command arguments
fn parse_list_remote_args(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "list-remote"));

    const zls = has_flag(args[2..], "--zls");
    return .{ .@"list-remote" = .{ .zls = zls } };
}

/// Parse env command arguments
fn parse_env_args(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "env"));

    const shell = get_flag_value(args[2..], "--shell");
    if (shell) |s| {
        // Validate shell argument
        std.debug.assert(s.len > 0);
        std.debug.assert(s.len < 50);
    }
    return .{ .env = .{ .shell = shell } };
}

/// Parse clean command arguments
fn parse_clean_args(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "clean"));

    const all = has_flag(args[2..], "--all");
    return .{ .clean = .{ .all = all } };
}

/// Parse install command arguments
fn parse_install_args_static(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "install") or std.mem.eql(u8, args[1], "i"));

    if (args.len < 3) {
        fatal("install requires a version argument", .{});
    }
    std.debug.assert(args.len >= 3);
    std.debug.assert(args[2].len > 0);

    const zls = has_flag(args[3..], "--zls");
    return .{ .install = .{ .version = args[2], .zls = zls } };
}

/// Parse remove command arguments
fn parse_remove_args_static(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "remove"));

    if (args.len < 3) {
        fatal("remove requires a version argument", .{});
    }

    const zls = has_flag(args[3..], "--zls");
    return .{ .remove = .{ .version = args[2], .zls = zls } };
}

/// Parse use command arguments
fn parse_use_args_static(args: [][]const u8) Command {
    std.debug.assert(args.len >= 2);
    std.debug.assert(std.mem.eql(u8, args[1], "use"));

    if (args.len < 3) {
        fatal("use requires a version argument", .{});
    }

    const zls = has_flag(args[3..], "--zls");
    return .{ .use = .{ .version = args[2], .zls = zls } };
}

/// Check if a flag exists in the arguments
fn has_flag(args: [][]const u8, flag: []const u8) bool {
    std.debug.assert(flag.len > 0);
    std.debug.assert(flag[0] == '-'); // Must be a flag

    for (args) |arg| {
        std.debug.assert(arg.len > 0);
        if (std.mem.eql(u8, arg, flag)) {
            return true;
        }
    }
    return false;
}

/// Get the value of a flag (e.g., --shell bash returns "bash")
fn get_flag_value(args: [][]const u8, flag: []const u8) ?[]const u8 {
    std.debug.assert(flag.len > 0);
    std.debug.assert(flag[0] == '-'); // Must be a flag

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        std.debug.assert(i < args.len); // Loop invariant
        if (std.mem.eql(u8, args[i], flag)) {
            // Check if there's a value after the flag
            if (i + 1 < args.len) {
                return args[i + 1];
            }
            // Flag found but no value after it
            return null;
        }
    }
    return null;
}

fn parse_args_list(list: CLIArgs.List) Command.List {
    return .{
        .list_all = list.list_all,
        .show_mirrors = list.show_mirrors,
        .debug = list.debug,
    };
}

fn parse_args_install(install: CLIArgs.Install) Command.Install {
    const version = ZigVersion.parse(install.positional.version) catch {
        fatal("invalid version: '{s}'", .{install.positional.version});
    };

    // Validate mirror index if provided
    if (install.mirror) |mirror_idx| {
        const max_mirrors = 10; // This should come from a config
        if (mirror_idx >= max_mirrors) {
            fatal("mirror index {d} is out of range (max: {d})", .{ mirror_idx, max_mirrors - 1 });
        }
    }

    return .{
        .version = version,
        .system_install = install.system,
        .mirror_index = install.mirror,
        .show_mirrors = install.show_mirrors,
        .debug = install.debug,
    };
}

fn parse_args_use(use: CLIArgs.Use) Command.Use {
    const version = ZigVersion.parse(use.positional.version) catch {
        fatal("invalid version: '{s}'", .{use.positional.version});
    };

    return .{
        .version = version,
        .system_wide = use.system,
        .debug = use.debug,
    };
}

fn parse_args_remove(remove: CLIArgs.Remove) Command.Remove {
    const version = ZigVersion.parse(remove.positional.version) catch {
        fatal("invalid version: '{s}'", .{remove.positional.version});
    };

    // Don't allow removing master builds
    if (version == .master) {
        fatal("cannot remove master version", .{});
    }

    return .{
        .version = version,
        .debug = remove.debug,
    };
}

fn parse_args_clean(clean: CLIArgs.Clean) Command.Clean {
    return .{
        .debug = clean.debug,
    };
}

fn parse_args_version(version: CLIArgs.Version) Command.VersionCmd {
    return .{
        .verbose = version.verbose,
    };
}

fn parse_args_help(help: CLIArgs.Help) Command.Help {
    _ = help;
    return .{};
}

fn parse_args_completions(completions: CLIArgs.Completions) Command.Completions {
    const shell_str = completions.positional.shell orelse
        detectShell() orelse
        fatal("could not detect shell, please specify: bash, zsh, fish, or powershell", .{});

    const shell = Shell.parse(shell_str) catch {
        fatal("unknown shell: '{s}' (supported: bash, zsh, fish, powershell)", .{shell_str});
    };

    return .{
        .shell = shell,
    };
}

fn detectShell() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return "powershell";
    }

    // Try to detect from SHELL environment variable without allocation.
    if (std.posix.getenv("SHELL")) |shell_path| {
        // Validate shell path
        std.debug.assert(shell_path.len > 0);
        std.debug.assert(shell_path.len < 1024); // Reasonable path length

        const shell_name = std.fs.path.basename(shell_path);
        std.debug.assert(shell_name.len > 0);
        std.debug.assert(shell_name.len <= shell_path.len);

        if (std.mem.indexOf(u8, shell_name, "bash") != null) {
            return "bash";
        }
        if (std.mem.indexOf(u8, shell_name, "zsh") != null) {
            return "zsh";
        }
        if (std.mem.indexOf(u8, shell_name, "fish") != null) {
            return "fish";
        }
    }

    return null;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    comptime {
        std.debug.assert(format.len > 0);
        std.debug.assert(format.len < 1000); // Reasonable error message length
    }

    std.debug.print("zvm: error: " ++ format ++ "\n", args);
    std.debug.print("Try 'zvm help' for more information.\n", .{});
    std.process.exit(1);
}
