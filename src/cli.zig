const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");
const util_output = @import("util/output.zig");
const raw_args = @import("raw_args.zig");
const validation = @import("validation.zig");
const util_tool = @import("util/tool.zig");

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

/// Complete parsed command line
pub const ParsedCommandLine = struct {
    global_config: GlobalConfig,
    command: validation.ValidatedCommand,

    pub fn validate(self: *const ParsedCommandLine) void {
        self.global_config.validate();
        // ValidatedCommand has its own validation built-in
    }

    comptime {
        const parsed_size = @sizeOf(ParsedCommandLine);
        std.debug.assert(parsed_size >= @sizeOf(GlobalConfig) + @sizeOf(validation.ValidatedCommand));
        std.debug.assert(parsed_size <= 512); // Keep reasonable
    }
};

/// Parse command line arguments
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

    // Stage 1: Parse raw arguments
    const raw_command = raw_args.parse_raw_args(command_name, remaining_args) catch |err| switch (err) {
        error.UnknownCommand => {
            util_output.fatal(.invalid_arguments, "Unknown command: '{s}'", .{command_name});
        },
        error.MissingVersionArgument => {
            util_output.fatal(.invalid_arguments, "{s} command requires a version argument", .{command_name});
        },
        error.EmptyVersionArgument => {
            util_output.fatal(.invalid_arguments, "{s} command version argument cannot be empty", .{command_name});
        },
        error.VersionStringTooLong => {
            util_output.fatal(
                .invalid_arguments,
                "version string too long (maximum: {d} characters)",
                .{limits.limits.version_string_length_maximum},
            );
        },
        error.UnknownFlag => {
            util_output.fatal(.invalid_arguments, "unknown flag in {s} command", .{command_name});
        },
        error.UnexpectedArguments => {
            util_output.fatal(.invalid_arguments, "{s} command does not accept arguments", .{command_name});
        },
        error.EmptyShellArgument => {
            util_output.fatal(.invalid_arguments, "shell argument cannot be empty", .{});
        },
        error.ShellNameTooLong => {
            util_output.fatal(.invalid_arguments, "shell name too long (maximum: 32 characters)", .{});
        },
        error.TooManyArguments => {
            util_output.fatal(.invalid_arguments, "too many arguments for {s} command", .{command_name});
        },
    };

    // Stage 2: Validate and transform
    const validated_command = validation.validate_command(raw_command) catch |err| switch (err) {
        // Validation errors are handled inside validation.zig with detailed messages
        else => return err,
    };

    const result = ParsedCommandLine{
        .global_config = global_config,
        .command = validated_command,
    };

    result.validate();
    return result;
}

comptime {
    std.debug.assert(@sizeOf(ParsedCommandLine) <= 1024);
    std.debug.assert(@sizeOf(validation.ValidatedCommand) <= 64);
}
