const std = @import("std");
const cli = @import("cli.zig");
const raw_args = @import("raw_args.zig");
const limits = @import("limits.zig");
const util_output = @import("util/output.zig");

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
            std.debug.assert(@sizeOf(VersionNumbers) == 12);
            std.debug.assert(@alignOf(VersionNumbers) == 4);
        }
    };

    const VersionSpec_Self = @This();

    pub fn parse(version_str: []const u8) !VersionSpec_Self {
        std.debug.assert(version_str.len > 0);
        std.debug.assert(version_str.len <= limits.limits.version_string_length_maximum);
        std.debug.assert(version_str.len < 1024);

        if (std.mem.eql(u8, version_str, "master")) {
            return .master;
        }
        if (std.mem.eql(u8, version_str, "latest")) {
            return error.LatestNotSupported;
        }

        var parts = std.mem.splitScalar(u8, version_str, '.');
        const major_str = parts.next() orelse return error.InvalidVersionFormat;
        const minor_str = parts.next() orelse return error.InvalidVersionFormat;
        const patch_str = parts.next() orelse return error.InvalidVersionFormat;
        std.debug.assert(major_str.len > 0);
        std.debug.assert(minor_str.len > 0);
        std.debug.assert(patch_str.len > 0);

        if (parts.next() != null) {
            return error.TooManyVersionParts;
        }

        const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidMajorVersion;
        const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidMinorVersion;
        const patch = std.fmt.parseInt(u32, patch_str, 10) catch return error.InvalidPatchVersion;

        if (major > 99) return error.MajorVersionTooLarge;
        if (minor > 99) return error.MinorVersionTooLarge;
        if (patch > 999) return error.PatchVersionTooLarge;

        const result = VersionSpec_Self{
            .specific = .{
                .major = major,
                .minor = minor,
                .patch = patch,
            },
        };

        std.debug.assert(result.specific.major == major);
        std.debug.assert(result.specific.minor == minor);
        std.debug.assert(result.specific.patch == patch);
        return result;
    }

    pub fn to_string(self: VersionSpec, buffer: []u8) ![]const u8 {
        std.debug.assert(buffer.len >= limits.limits.version_string_length_maximum);

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

/// Shell type with validation
pub const ShellType = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn parse(shell_str: []const u8) !ShellType {
        std.debug.assert(shell_str.len > 0);

        if (std.mem.eql(u8, shell_str, "bash")) return .bash;
        if (std.mem.eql(u8, shell_str, "zsh")) return .zsh;
        if (std.mem.eql(u8, shell_str, "fish")) return .fish;
        if (std.mem.eql(u8, shell_str, "powershell")) return .powershell;
        if (std.mem.eql(u8, shell_str, "pwsh")) return .powershell; // PowerShell Core alias

        return error.UnknownShell;
    }
};

/// Stage 2: Validated command with business logic applied
pub const ValidatedCommand = union(enum) {
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

    /// Validated install command
    pub const InstallCommand = struct {
        version: VersionSpec,
        tool: ToolType,

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
        tool: ToolType,
    };

    /// Validated use command
    pub const UseCommand = struct {
        version: VersionSpec,
        tool: ToolType,

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

    /// Validated current command
    pub const CurrentCommand = struct {};

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
    pub const HelpCommand = struct {};
};

/// Transform raw arguments into validated command with semantic validation
pub fn validate_command(raw_command: raw_args.RawArgs) !ValidatedCommand {
    return switch (raw_command) {
        .install => |raw| .{ .install = try validate_install(raw) },
        .remove => |raw| .{ .remove = try validate_remove(raw) },
        .use => |raw| .{ .use = try validate_use(raw) },
        .list => |raw| .{ .list = try validate_list(raw) },
        .list_remote => |raw| .{ .list_remote = try validate_list_remote(raw) },
        .current => |raw| .{ .current = try validate_current(raw) },
        .clean => |raw| .{ .clean = try validate_clean(raw) },
        .env => |raw| .{ .env = try validate_env(raw) },
        .completions => |raw| .{ .completions = try validate_completions(raw) },
        .version => |raw| .{ .version = try validate_version(raw) },
        .help => |raw| .{ .help = try validate_help(raw) },
    };
}

fn validate_install(raw: raw_args.RawArgs.InstallArgs) !ValidatedCommand.InstallCommand {
    const version_str = raw.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.fatal(.invalid_arguments, "invalid version format: '{s}' (expected: x.y.z or 'master')", .{version_str});
        },
        error.TooManyVersionParts => {
            util_output.fatal(.invalid_arguments, "too many version parts in '{s}' (expected: x.y.z format)", .{version_str});
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
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.15.1'", .{});
        },
    };

    const tool = ToolType.from_bool(raw.is_zls);
    const install_cmd = ValidatedCommand.InstallCommand{
        .version = version_spec,
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

fn validate_remove(raw: raw_args.RawArgs.RemoveArgs) !ValidatedCommand.RemoveCommand {
    const version_str = raw.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.fatal(.invalid_arguments, "invalid version format: '{s}' (expected: x.y.z or 'master')", .{version_str});
        },
        error.TooManyVersionParts => {
            util_output.fatal(.invalid_arguments, "too many version parts in '{s}' (expected: x.y.z format)", .{version_str});
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
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.15.1'", .{});
        },
    };

    return ValidatedCommand.RemoveCommand{
        .version = version_spec,
        .tool = ToolType.from_bool(raw.is_zls),
    };
}

fn validate_use(raw: raw_args.RawArgs.UseArgs) !ValidatedCommand.UseCommand {
    const version_str = raw.get_version();
    const version_spec = VersionSpec.parse(version_str) catch |err| switch (err) {
        error.InvalidVersionFormat => {
            util_output.fatal(.invalid_arguments, "invalid version format: '{s}' (expected: x.y.z or 'master')", .{version_str});
        },
        error.TooManyVersionParts => {
            util_output.fatal(.invalid_arguments, "too many version parts in '{s}' (expected: x.y.z format)", .{version_str});
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
            util_output.fatal(.invalid_arguments, "'latest' is not supported. Use 'master' for the development version or a specific version like '0.15.1'", .{});
        },
    };

    const tool = ToolType.from_bool(raw.is_zls);
    const use_cmd = ValidatedCommand.UseCommand{
        .version = version_spec,
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

fn validate_list(raw: raw_args.RawArgs.ListArgs) !ValidatedCommand.ListCommand {
    return ValidatedCommand.ListCommand{
        .show_all = raw.show_all,
    };
}

fn validate_list_remote(raw: raw_args.RawArgs.ListRemoteArgs) !ValidatedCommand.ListRemoteCommand {
    return ValidatedCommand.ListRemoteCommand{
        .tool = ToolType.from_bool(raw.is_zls),
    };
}

fn validate_current(raw: raw_args.RawArgs.CurrentArgs) !ValidatedCommand.CurrentCommand {
    _ = raw;
    return ValidatedCommand.CurrentCommand{};
}

fn validate_clean(raw: raw_args.RawArgs.CleanArgs) !ValidatedCommand.CleanCommand {
    return ValidatedCommand.CleanCommand{
        .remove_all = raw.remove_all,
    };
}

fn validate_env(raw: raw_args.RawArgs.EnvArgs) !ValidatedCommand.EnvCommand {
    const shell = if (raw.get_shell()) |shell_str|
        ShellType.parse(shell_str) catch |err| switch (err) {
            error.UnknownShell => {
                util_output.fatal(.invalid_arguments, "unknown shell type: '{s}' (supported: bash, zsh, fish, powershell)", .{shell_str});
            },
        }
    else
        null;

    return ValidatedCommand.EnvCommand{
        .shell = shell,
    };
}

fn validate_completions(raw: raw_args.RawArgs.CompletionsArgs) !ValidatedCommand.CompletionsCommand {
    const shell = if (raw.get_shell()) |shell_str|
        ShellType.parse(shell_str) catch |err| switch (err) {
            error.UnknownShell => {
                util_output.fatal(.invalid_arguments, "unknown shell type: '{s}' (supported: bash, zsh, fish, powershell)", .{shell_str});
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

fn validate_version(raw: raw_args.RawArgs.VersionArgs) !ValidatedCommand.VersionCommand {
    _ = raw;
    return ValidatedCommand.VersionCommand{};
}

fn validate_help(raw: raw_args.RawArgs.HelpArgs) !ValidatedCommand.HelpCommand {
    _ = raw;
    return ValidatedCommand.HelpCommand{};
}

fn detect_shell_from_environment() ?ShellType {
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        return .powershell;
    }

    const getenv = @import("cli.zig").getenv_cross_platform;
    const shell_path = getenv("SHELL") orelse return null;
    std.debug.assert(shell_path.len > 0);

    const shell_name = std.fs.path.basename(shell_path);
    std.debug.assert(shell_name.len > 0);
    std.debug.assert(shell_name.len <= shell_path.len);

    return ShellType.parse(shell_name) catch null;
}

comptime {
    std.debug.assert(@sizeOf(ValidatedCommand) <= 64);
    std.debug.assert(@sizeOf(ValidatedCommand) >= 16);
    std.debug.assert(@sizeOf(VersionSpec) <= 16);
    std.debug.assert(@sizeOf(VersionSpec) >= 4);
    std.debug.assert(@sizeOf(ValidatedCommand.InstallCommand) <= 32);
    std.debug.assert(@sizeOf(ValidatedCommand.InstallCommand) >= 16);
    std.debug.assert(@sizeOf(ValidatedCommand.RemoveCommand) <= 32);
    std.debug.assert(@sizeOf(ValidatedCommand.RemoveCommand) >= 16);
    std.debug.assert(@sizeOf(ValidatedCommand.UseCommand) <= 32);
    std.debug.assert(@sizeOf(ValidatedCommand.UseCommand) >= 16);

    std.debug.assert(@typeInfo(ShellType).@"enum".fields.len == 4);
    std.debug.assert(@typeInfo(ToolType).@"enum".fields.len == 2);
    std.debug.assert(@typeInfo(VersionSpec).@"union".fields.len == 2);
}
