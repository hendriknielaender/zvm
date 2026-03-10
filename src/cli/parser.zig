const std = @import("std");
const limits = @import("../memory/limits.zig");
const util_output = @import("../util/output.zig");
const raw_args = @import("raw_args.zig");
const validation = @import("validation.zig");
const assert = std.debug.assert;

const max_argument_count = limits.limits.arguments_maximum;
const max_version_string_length = limits.limits.version_string_length_maximum;
const max_command_name_length = 32;

comptime {
    assert(max_argument_count >= 4);
    assert(max_argument_count <= 64);
    assert(max_version_string_length >= 16);
    assert(max_version_string_length <= 256);
    assert(max_command_name_length >= 8);
    assert(max_command_name_length <= 64);
}

/// Global configuration affecting all commands
pub const GlobalConfig = struct {
    output_mode: util_output.OutputMode,
    color_mode: util_output.ColorMode,

    pub fn validate(self: GlobalConfig) void {
        // Positive assertions: what we expect
        assert(self.output_mode == .human_readable or
            self.output_mode == .machine_json or
            self.output_mode == .silent_errors_only);
        assert(self.color_mode == .never_use_color or
            self.color_mode == .always_use_color);

        // Negative assertions: invalid combinations
        if (self.output_mode == .machine_json) {
            assert(self.color_mode == .never_use_color);
        }
    }

    /// Default configuration for human users
    pub const default = GlobalConfig{
        .output_mode = .human_readable,
        .color_mode = .always_use_color,
    };

    comptime {
        assert(@sizeOf(GlobalConfig) <= 16);
        assert(@sizeOf(GlobalConfig) >= 2);
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
        assert(parsed_size >= @sizeOf(GlobalConfig) + @sizeOf(validation.ValidatedCommand));
        assert(parsed_size <= 512); // Keep reasonable
    }
};

/// Check if an argument is a global option
fn is_help_option(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn is_version_option(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

fn is_prefixed_option(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn is_short_option_cluster(arg: []const u8) bool {
    return arg.len >= 2 and arg[0] == '-' and arg[1] != '-';
}

fn is_long_option(arg: []const u8) bool {
    return arg.len >= 3 and arg[0] == '-' and arg[1] == '-';
}

const StandardCommand = enum {
    help,
    version,
};

fn apply_long_global_option(
    global_config: *GlobalConfig,
    standard_command: *?StandardCommand,
    arg: []const u8,
) !void {
    assert(arg.len >= 2);
    assert(arg[0] == '-');
    assert(arg[1] == '-');

    if (std.mem.eql(u8, arg, "--json")) {
        global_config.output_mode = .machine_json;
        global_config.color_mode = .never_use_color;
        return;
    }
    if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
        global_config.output_mode = .silent_errors_only;
        return;
    }
    if (std.mem.eql(u8, arg, "--color")) {
        global_config.color_mode = .always_use_color;
        return;
    }
    if (is_help_option(arg)) {
        standard_command.* = .help;
        return;
    }
    if (is_version_option(arg)) {
        standard_command.* = .version;
        return;
    }
    if (std.mem.eql(u8, arg, "--no-color")) {
        global_config.color_mode = .never_use_color;
        return;
    }

    return error.UnknownGlobalOption;
}

fn apply_short_global_option(
    global_config: *GlobalConfig,
    standard_command: *?StandardCommand,
    option: u8,
) !void {
    switch (option) {
        'q' => {
            global_config.output_mode = .silent_errors_only;
        },
        'h' => {
            standard_command.* = .help;
        },
        'V' => {
            standard_command.* = .version;
        },
        else => return error.UnknownGlobalShortOption,
    }
}

fn apply_short_global_options(
    global_config: *GlobalConfig,
    standard_command: *?StandardCommand,
    arg: []const u8,
) !void {
    assert(is_short_option_cluster(arg));

    for (arg[1..]) |option| {
        try apply_short_global_option(global_config, standard_command, option);
    }
}

fn command_help_topic(command_name: []const u8) ?validation.HelpTopic {
    return validation.HelpTopic.parse(command_name) catch null;
}

fn command_help_requested(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (is_help_option(arg)) return true;
    }
    return false;
}

const GlobalPrefix = struct {
    global_config: GlobalConfig,
    command_index: usize,
    standard_command: ?StandardCommand,
};

/// Parse global options only while they appear before the command name.
fn parse_global_prefix(arguments: []const []const u8) !GlobalPrefix {
    assert(arguments.len > 0);

    var global_config = GlobalConfig.default;
    var command_index: usize = 1;
    var standard_command: ?StandardCommand = null;

    while (command_index < arguments.len) {
        const arg = arguments[command_index];

        if (std.mem.eql(u8, arg, "--")) {
            command_index += 1;
            break;
        }
        if (!is_prefixed_option(arg)) {
            break;
        }
        if (is_short_option_cluster(arg)) {
            try apply_short_global_options(&global_config, &standard_command, arg);
        } else if (is_long_option(arg)) {
            try apply_long_global_option(&global_config, &standard_command, arg);
        } else {
            return error.UnknownGlobalOption;
        }
        command_index += 1;
    }

    return .{
        .global_config = global_config,
        .command_index = command_index,
        .standard_command = standard_command,
    };
}

fn find_invalid_global_option(arguments: []const []const u8) []const u8 {
    assert(arguments.len > 1);

    var global_config = GlobalConfig.default;
    var standard_command: ?StandardCommand = null;
    var index: usize = 1;

    while (index < arguments.len) : (index += 1) {
        const arg = arguments[index];

        if (std.mem.eql(u8, arg, "--")) break;
        if (!is_prefixed_option(arg)) break;

        if (is_short_option_cluster(arg)) {
            apply_short_global_options(&global_config, &standard_command, arg) catch return arg;
        } else if (is_long_option(arg)) {
            apply_long_global_option(&global_config, &standard_command, arg) catch return arg;
        } else {
            return arg;
        }
    }

    return arguments[1];
}

fn standard_command_to_validated_command(standard_command: StandardCommand) validation.ValidatedCommand {
    return switch (standard_command) {
        .help => .{ .help = .{} },
        .version => .{ .version = .{} },
    };
}

fn parse_raw_command_or_fatal(
    command_name: []const u8,
    remaining_args: []const []const u8,
) raw_args.RawArgs {
    return raw_args.parse_raw_args(command_name, remaining_args) catch |err| switch (err) {
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
        error.EmptyHelpTopic => {
            util_output.fatal(.invalid_arguments, "help topic cannot be empty", .{});
        },
        error.HelpTopicTooLong => {
            util_output.fatal(.invalid_arguments, "help topic too long (maximum: 32 characters)", .{});
        },
        error.TooManyArguments => {
            util_output.fatal(.invalid_arguments, "too many arguments for {s} command", .{command_name});
        },
    };
}

/// Parse command line arguments
pub fn parse_command_line(arguments: []const []const u8) !ParsedCommandLine {
    assert(arguments.len > 0); // Must have program name
    assert(arguments.len <= max_argument_count);

    // Validate all arguments are non-empty and reasonably sized
    for (arguments) |arg| {
        assert(arg.len > 0);
        assert(arg.len < 1024); // Reasonable argument length
    }

    const global_prefix = parse_global_prefix(arguments) catch |err| switch (err) {
        error.UnknownGlobalOption => {
            util_output.fatal(.invalid_arguments, "unknown global option: '{s}'", .{find_invalid_global_option(arguments)});
        },
        error.UnknownGlobalShortOption => {
            util_output.fatal(.invalid_arguments, "unknown short option in '{s}'", .{find_invalid_global_option(arguments)});
        },
    };

    if (global_prefix.standard_command) |standard_command| {
        const result = ParsedCommandLine{
            .global_config = global_prefix.global_config,
            .command = standard_command_to_validated_command(standard_command),
        };
        result.validate();
        return result;
    }

    // Must have at least program name and command
    if (global_prefix.command_index >= arguments.len) {
        return ParsedCommandLine{
            .global_config = global_prefix.global_config,
            .command = .{ .help = .{} },
        };
    }

    const command_name = arguments[global_prefix.command_index];
    assert(command_name.len > 0);
    assert(command_name.len <= max_command_name_length);

    const remaining_args = arguments[(global_prefix.command_index + 1)..];

    if (command_help_topic(command_name)) |topic| {
        if (command_help_requested(remaining_args)) {
            const result = ParsedCommandLine{
                .global_config = global_prefix.global_config,
                .command = .{ .help = .{ .topic = topic } },
            };
            result.validate();
            return result;
        }
    }

    // Stage 1: Parse raw arguments
    const raw_command = parse_raw_command_or_fatal(command_name, remaining_args);

    // Stage 2: Validate and transform
    const validated_command = validation.validate_command(raw_command) catch |err| switch (err) {
        // Validation errors are handled inside validation.zig with detailed messages
        else => return err,
    };

    const result = ParsedCommandLine{
        .global_config = global_prefix.global_config,
        .command = validated_command,
    };

    result.validate();
    return result;
}

comptime {
    assert(@sizeOf(ParsedCommandLine) <= 1024);
    assert(@sizeOf(validation.ValidatedCommand) <= 256);
}

test "global options stop at the command boundary" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--json", "list", "--quiet" });

    try testing.expectEqual(@as(usize, 2), parsed.command_index);
    try testing.expectEqual(@as(?StandardCommand, null), parsed.standard_command);
    try testing.expectEqual(util_output.OutputMode.machine_json, parsed.global_config.output_mode);
    try testing.expectEqual(util_output.ColorMode.never_use_color, parsed.global_config.color_mode);
}

test "global option parsing honors the double dash terminator" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--json", "--", "list" });

    try testing.expectEqual(@as(usize, 3), parsed.command_index);
    try testing.expectEqual(@as(?StandardCommand, null), parsed.standard_command);
    try testing.expectEqual(util_output.OutputMode.machine_json, parsed.global_config.output_mode);
    try testing.expectEqual(util_output.ColorMode.never_use_color, parsed.global_config.color_mode);
}

test "parse_command_line accepts standard short aliases" {
    const testing = std.testing;
    const help_parsed = try parse_command_line(&.{ "zvm", "-h" });
    const version_parsed = try parse_command_line(&.{ "zvm", "-V" });

    try testing.expect(std.meta.activeTag(help_parsed.command) == .help);
    try testing.expect(std.meta.activeTag(version_parsed.command) == .version);
}

test "clustered short global options are supported" {
    const testing = std.testing;
    const help_parsed = try parse_command_line(&.{ "zvm", "-qh" });
    const version_parsed = try parse_command_line(&.{ "zvm", "-qV" });

    try testing.expect(std.meta.activeTag(help_parsed.command) == .help);
    try testing.expectEqual(util_output.OutputMode.silent_errors_only, help_parsed.global_config.output_mode);

    try testing.expect(std.meta.activeTag(version_parsed.command) == .version);
    try testing.expectEqual(util_output.OutputMode.silent_errors_only, version_parsed.global_config.output_mode);
}

test "standard commands remain global regardless of prefix ordering" {
    const testing = std.testing;
    const help_parsed = try parse_command_line(&.{ "zvm", "-h", "-q" });
    const help_reversed = try parse_command_line(&.{ "zvm", "-q", "-h" });
    const version_parsed = try parse_command_line(&.{ "zvm", "--version", "--json" });
    const version_reversed = try parse_command_line(&.{ "zvm", "--json", "--version" });

    try testing.expect(std.meta.activeTag(help_parsed.command) == .help);
    try testing.expectEqual(util_output.OutputMode.silent_errors_only, help_parsed.global_config.output_mode);
    try testing.expect(std.meta.activeTag(help_reversed.command) == .help);
    try testing.expectEqual(util_output.OutputMode.silent_errors_only, help_reversed.global_config.output_mode);

    try testing.expect(std.meta.activeTag(version_parsed.command) == .version);
    try testing.expectEqual(util_output.OutputMode.machine_json, version_parsed.global_config.output_mode);
    try testing.expect(std.meta.activeTag(version_reversed.command) == .version);
    try testing.expectEqual(util_output.OutputMode.machine_json, version_reversed.global_config.output_mode);
}

test "parse_command_line accepts commands after the double dash terminator" {
    const testing = std.testing;
    const parsed = try parse_command_line(&.{ "zvm", "--", "list" });

    try testing.expect(std.meta.activeTag(parsed.command) == .list);
    try testing.expectEqual(util_output.OutputMode.human_readable, parsed.global_config.output_mode);
    try testing.expectEqual(util_output.ColorMode.always_use_color, parsed.global_config.color_mode);
}

test "parse_command_line routes command help to the matching topic" {
    const testing = std.testing;
    const parsed = try parse_command_line(&.{ "zvm", "ls", "--help" });

    try testing.expect(std.meta.activeTag(parsed.command) == .help);
    switch (parsed.command) {
        .help => |help| try testing.expectEqual(validation.HelpTopic.list, help.topic),
        else => return error.UnexpectedCommandType,
    }
}

test "parse_command_line accepts subcommand options before operands" {
    const testing = std.testing;
    const parsed = try parse_command_line(&.{ "zvm", "install", "--zls", "0.11.0" });

    try testing.expect(std.meta.activeTag(parsed.command) == .install);
    switch (parsed.command) {
        .install => |install| try testing.expectEqual(validation.ToolType.zls, install.tool),
        else => return error.UnexpectedCommandType,
    }
}

test "parse_global_prefix rejects unknown clustered short options" {
    const testing = std.testing;
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-qx" }));
}
