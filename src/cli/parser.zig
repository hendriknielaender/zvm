const std = @import("std");
const limits = @import("../memory/limits.zig");
const edit_distance = @import("../util/edit_distance.zig");
const util_output = @import("../util/output.zig");
const validation = @import("validation.zig");
const cli_spec = @import("spec.zig");
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
    /// Skip confirmation prompts for destructive operations.
    assume_yes: bool,
    /// Refuse to prompt; non-interactive invocations should fail fast.
    no_input: bool,
    /// Verbosity level for diagnostic output. Set via `--verbose` or
    /// `--trace`. The legacy `ZVM_DEBUG` env var is honored separately in
    /// main.zig for backward compatibility.
    verbose: util_output.VerboseLevel,

    pub fn validate(self: GlobalConfig) void {
        // Positive assertions: what we expect
        assert(self.output_mode == .human_readable or
            self.output_mode == .machine_json or
            self.output_mode == .silent_errors_only or
            self.output_mode == .plain);
        assert(self.color_mode == .never_use_color or
            self.color_mode == .always_use_color or
            self.color_mode == .auto);

        // Negative assertions: invalid combinations
        if (self.output_mode == .machine_json) {
            assert(self.color_mode == .never_use_color);
        }
        if (self.output_mode == .plain) {
            assert(self.color_mode == .never_use_color);
        }
    }

    /// Default configuration defers color mode to environment/terminal detection.
    pub const default = GlobalConfig{
        .output_mode = .human_readable,
        .color_mode = .auto,
        .assume_yes = false,
        .no_input = false,
        .verbose = .none,
    };

    comptime {
        assert(@sizeOf(GlobalConfig) <= 24);
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
    return std.mem.eql(u8, arg, "--version");
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

/// Tracks which global option groups have already been set.
/// Why: silently accepting repeated or conflicting options (e.g.
/// --color --no-color) produces surprising behavior. Rejecting them
/// makes operator errors harder to commit.
const GlobalOptionTracker = struct {
    output_mode_set: bool = false,
    output_mode_arg: ?[]const u8 = null,
    color_mode_set: bool = false,
    color_mode_arg: ?[]const u8 = null,
    standard_command_set: bool = false,
    standard_command_arg: ?[]const u8 = null,
    assume_yes_set: bool = false,
    no_input_set: bool = false,
    verbose_set: bool = false,
    verbose_arg: ?[]const u8 = null,
};

fn duplicate_or_conflict(previous: ?[]const u8, current: []const u8) GlobalOptionError {
    if (previous) |previous_arg| {
        if (std.mem.eql(u8, previous_arg, current)) return error.DuplicateGlobalOption;
    }
    return error.ConflictingGlobalOption;
}

const GlobalOptionError = error{
    UnknownGlobalOption,
    UnknownGlobalShortOption,
    DuplicateGlobalOption,
    ConflictingGlobalOption,
};

fn apply_long_global_option(
    global_config: *GlobalConfig,
    standard_command: *?StandardCommand,
    tracker: *GlobalOptionTracker,
    arg: []const u8,
) GlobalOptionError!void {
    assert(arg.len >= 2);
    assert(arg[0] == '-');
    assert(arg[1] == '-');

    if (std.mem.eql(u8, arg, "--json")) {
        if (tracker.output_mode_set) return duplicate_or_conflict(tracker.output_mode_arg, arg);
        if (tracker.color_mode_set) return duplicate_or_conflict(tracker.color_mode_arg, arg);
        tracker.output_mode_set = true;
        tracker.output_mode_arg = arg;
        tracker.color_mode_set = true;
        tracker.color_mode_arg = arg;
        global_config.output_mode = .machine_json;
        global_config.color_mode = .never_use_color;
        return;
    }
    if (std.mem.eql(u8, arg, "--plain")) {
        // Plain mode is mutually exclusive with --json, --quiet, --color, --no-color.
        // Why: plain emits tab-separated records with color forced off; any other
        // output/color flag would create ambiguity for shell pipelines.
        if (tracker.output_mode_set) return duplicate_or_conflict(tracker.output_mode_arg, arg);
        if (tracker.color_mode_set) return duplicate_or_conflict(tracker.color_mode_arg, arg);
        tracker.output_mode_set = true;
        tracker.output_mode_arg = arg;
        tracker.color_mode_set = true;
        tracker.color_mode_arg = arg;
        global_config.output_mode = .plain;
        global_config.color_mode = .never_use_color;
        return;
    }
    if (std.mem.eql(u8, arg, "--quiet")) {
        if (tracker.output_mode_set) return duplicate_or_conflict(tracker.output_mode_arg, arg);
        tracker.output_mode_set = true;
        tracker.output_mode_arg = arg;
        global_config.output_mode = .silent_errors_only;
        return;
    }
    if (std.mem.eql(u8, arg, "--color")) {
        if (tracker.color_mode_set) return duplicate_or_conflict(tracker.color_mode_arg, arg);
        tracker.color_mode_set = true;
        tracker.color_mode_arg = arg;
        global_config.color_mode = .always_use_color;
        return;
    }
    if (std.mem.eql(u8, arg, "--no-color")) {
        if (tracker.color_mode_set) return duplicate_or_conflict(tracker.color_mode_arg, arg);
        tracker.color_mode_set = true;
        tracker.color_mode_arg = arg;
        global_config.color_mode = .never_use_color;
        return;
    }
    if (std.mem.eql(u8, arg, "--yes")) {
        if (tracker.assume_yes_set) return error.DuplicateGlobalOption;
        tracker.assume_yes_set = true;
        global_config.assume_yes = true;
        return;
    }
    if (std.mem.eql(u8, arg, "--verbose")) {
        if (tracker.verbose_set) return duplicate_or_conflict(tracker.verbose_arg, arg);
        tracker.verbose_set = true;
        tracker.verbose_arg = arg;
        global_config.verbose = .debug;
        return;
    }
    if (std.mem.eql(u8, arg, "--trace")) {
        if (tracker.verbose_set) return duplicate_or_conflict(tracker.verbose_arg, arg);
        tracker.verbose_set = true;
        tracker.verbose_arg = arg;
        global_config.verbose = .trace;
        return;
    }
    if (std.mem.eql(u8, arg, "--no-input")) {
        if (tracker.no_input_set) return error.DuplicateGlobalOption;
        tracker.no_input_set = true;
        global_config.no_input = true;
        return;
    }
    const is_help = is_help_option(arg);
    const is_version = is_version_option(arg);
    if (is_help or is_version) {
        if (tracker.standard_command_set) return error.DuplicateGlobalOption;
        tracker.standard_command_set = true;
        tracker.standard_command_arg = arg;
        assert(is_help != is_version); // Cannot be both help and version.
        standard_command.* = if (is_help) .help else .version;
        return;
    }

    return error.UnknownGlobalOption;
}

fn apply_short_global_option(
    standard_command: *?StandardCommand,
    tracker: *GlobalOptionTracker,
    option: u8,
) GlobalOptionError!void {
    switch (option) {
        'h' => {
            if (tracker.standard_command_set) return error.DuplicateGlobalOption;
            tracker.standard_command_set = true;
            standard_command.* = .help;
        },
        else => return error.UnknownGlobalShortOption,
    }
}

fn apply_short_global_options(
    standard_command: *?StandardCommand,
    tracker: *GlobalOptionTracker,
    arg: []const u8,
) GlobalOptionError!void {
    if (!std.mem.eql(u8, arg, "-h")) return error.UnknownGlobalShortOption;
    try apply_short_global_option(standard_command, tracker, 'h');
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

const GlobalPrefixFailure = struct {
    code: GlobalOptionError,
    arg: []const u8,
};

const GlobalPrefixDiagnostic = union(enum) {
    ok: GlobalPrefix,
    err: GlobalPrefixFailure,
};

/// Parse global options only while they appear before the command name.
fn parse_global_prefix_diagnostic(arguments: []const []const u8) GlobalPrefixDiagnostic {
    assert(arguments.len > 0);

    var global_config = GlobalConfig.default;
    var command_index: usize = 1;
    var standard_command: ?StandardCommand = null;
    var tracker = GlobalOptionTracker{};

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
            apply_short_global_options(&standard_command, &tracker, arg) catch |err| {
                return .{ .err = .{ .code = err, .arg = arg } };
            };
        } else if (is_long_option(arg)) {
            apply_long_global_option(&global_config, &standard_command, &tracker, arg) catch |err| {
                return .{ .err = .{ .code = err, .arg = arg } };
            };
        } else {
            return .{ .err = .{ .code = error.UnknownGlobalOption, .arg = arg } };
        }
        command_index += 1;
    }

    return .{ .ok = .{
        .global_config = global_config,
        .command_index = command_index,
        .standard_command = standard_command,
    } };
}

fn parse_global_prefix(arguments: []const []const u8) GlobalOptionError!GlobalPrefix {
    return switch (parse_global_prefix_diagnostic(arguments)) {
        .ok => |prefix| prefix,
        .err => |failure| failure.code,
    };
}

fn fatal_global_prefix_diagnostic(failure: GlobalPrefixFailure) noreturn {
    switch (failure.code) {
        error.UnknownGlobalOption => fatal_unknown_global_option(failure.arg),
        error.UnknownGlobalShortOption => {
            util_output.exit_with(.invalid_arguments, "unknown short option in '{s}'", .{failure.arg});
        },
        error.DuplicateGlobalOption => {
            util_output.exit_with(.invalid_arguments, "{s}: duplicate global option", .{failure.arg});
        },
        error.ConflictingGlobalOption => {
            util_output.exit_with(.invalid_arguments, "{s}: conflicting global option", .{failure.arg});
        },
    }
}

fn find_invalid_command_option(command_name: []const u8, args: []const []const u8) []const u8 {
    assert(command_name.len > 0);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (!is_prefixed_option(arg)) continue;
        if (command_option_valid(command_name, arg)) continue;
        return arg;
    }

    return args[0];
}

fn find_first_command_option(args: []const []const u8) []const u8 {
    assert(args.len > 0);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (is_prefixed_option(arg)) return arg;
    }

    return args[0];
}

fn find_trailing_command_option(args: []const []const u8) []const u8 {
    assert(args.len > 0);

    var parsed_positional = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (is_prefixed_option(arg)) {
            if (parsed_positional) return arg;
            continue;
        }
        parsed_positional = true;
    }

    return find_first_command_option(args);
}

fn option_display_name(arg: []const u8) []const u8 {
    assert(arg.len > 0);

    if (std.mem.indexOfScalar(u8, arg, '=')) |separator_index| {
        return arg[0..separator_index];
    }
    if (std.mem.eql(u8, arg, "--shell") or std.mem.startsWith(u8, arg, "--shell")) {
        return "--shell";
    }
    return arg;
}

fn command_option_valid(command_name: []const u8, arg: []const u8) bool {
    assert(command_name.len > 0);
    assert(arg.len > 0);

    return cli_spec.valid_option(command_name, arg);
}

fn command_option_suggestion(command_name: []const u8, flag: []const u8) ?[]const u8 {
    assert(command_name.len > 0);
    assert(flag.len > 0);

    const options = cli_spec.option_suggestions(command_name) orelse return null;
    return edit_distance.nearest(flag, options);
}

fn fatal_unknown_command(command_name: []const u8) noreturn {
    if (edit_distance.nearest(command_name, &cli_spec.command_names)) |suggestion| {
        util_output.exit_with(
            .invalid_arguments,
            "unknown command '{s}'\n\n  Did you mean '{s}'?",
            .{ command_name, suggestion },
        );
    }
    util_output.exit_with(.invalid_arguments, "unknown command '{s}'", .{command_name});
}

fn fatal_unknown_global_option(flag: []const u8) noreturn {
    if (edit_distance.nearest(flag, &cli_spec.global_option_names)) |suggestion| {
        util_output.exit_with(
            .invalid_arguments,
            "unknown global option '{s}'\n\n  Did you mean '{s}'?",
            .{ flag, suggestion },
        );
    }
    util_output.exit_with(.invalid_arguments, "unknown global option '{s}'", .{flag});
}

fn fatal_unknown_command_option(command_name: []const u8, flag: []const u8) noreturn {
    if (std.mem.eql(u8, command_name, "env") and std.mem.eql(u8, flag, "--shell")) {
        util_output.exit_with(
            .invalid_arguments,
            "{s}: expected value separator '='; use '--shell=<shell>' (for example, '--shell=zsh').",
            .{flag},
        );
    }
    if (command_option_suggestion(command_name, flag)) |suggestion| {
        util_output.exit_with(
            .invalid_arguments,
            "{s}: unknown flag in {s} command\n\n  Did you mean '{s}'?",
            .{ flag, command_name, suggestion },
        );
    }
    util_output.exit_with(.invalid_arguments, "{s}: unknown flag in {s} command", .{
        flag,
        command_name,
    });
}

fn standard_command_to_validated_command(standard_command: StandardCommand) validation.ValidatedCommand {
    return switch (standard_command) {
        .help => .{ .help = .{} },
        .version => .{ .version = .{} },
    };
}

fn parse_command_args_or_fatal(
    command_name: []const u8,
    remaining_args: []const []const u8,
) validation.ValidatedCommand {
    return validation.parse_command_args(command_name, remaining_args) catch |err| switch (err) {
        error.UnknownCommand => {
            fatal_unknown_command(command_name);
        },
        error.MissingVersionArgument => {
            util_output.exit_with(.invalid_arguments, "{s} command requires a version argument", .{command_name});
        },
        error.EmptyVersionArgument => {
            util_output.exit_with(.invalid_arguments, "{s} command version argument cannot be empty", .{command_name});
        },
        error.VersionStringTooLong => {
            util_output.exit_with(
                .invalid_arguments,
                "version string too long (maximum: {d} characters)",
                .{limits.limits.version_string_length_maximum},
            );
        },
        error.UnknownFlag => {
            const flag = find_invalid_command_option(command_name, remaining_args);
            fatal_unknown_command_option(command_name, flag);
        },
        error.UnexpectedArguments => {
            util_output.exit_with(.invalid_arguments, "{s} command does not accept arguments", .{command_name});
        },
        error.EmptyShellArgument => {
            util_output.exit_with(.invalid_arguments, "shell argument cannot be empty", .{});
        },
        error.EmptyOptionValue => {
            const flag = option_display_name(find_first_command_option(remaining_args));
            util_output.exit_with(.invalid_arguments, "{s}: argument requires a value", .{flag});
        },
        error.MissingOptionValueSeparator => {
            const flag = option_display_name(find_first_command_option(remaining_args));
            util_output.exit_with(
                .invalid_arguments,
                "{s}: expected value separator '='; use '{s}=<value>'",
                .{ flag, flag },
            );
        },
        error.TrailingOption => {
            const flag = find_trailing_command_option(remaining_args);
            util_output.exit_with(
                .invalid_arguments,
                "{s}: unexpected trailing option in {s} command; place options before positional arguments",
                .{ flag, command_name },
            );
        },
        error.ShellNameTooLong => {
            util_output.exit_with(.invalid_arguments, "shell name too long (maximum: 32 characters)", .{});
        },
        error.EmptyHelpTopic => {
            util_output.exit_with(.invalid_arguments, "help topic cannot be empty", .{});
        },
        error.HelpTopicTooLong => {
            util_output.exit_with(.invalid_arguments, "help topic too long (maximum: 32 characters)", .{});
        },
        error.TooManyArguments => {
            util_output.exit_with(.invalid_arguments, "too many arguments for {s} command", .{command_name});
        },
        error.DuplicateOption => {
            const flag = find_invalid_command_option(command_name, remaining_args);
            util_output.exit_with(.invalid_arguments, "{s}: duplicate option in {s} command", .{
                flag,
                command_name,
            });
        },
        else => {
            util_output.exit_with(.invalid_arguments, "failed to parse {s} command: {s}", .{
                command_name,
                @errorName(err),
            });
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

    const global_prefix = switch (parse_global_prefix_diagnostic(arguments)) {
        .ok => |prefix| prefix,
        .err => |failure| fatal_global_prefix_diagnostic(failure),
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

    const validated_command = parse_command_args_or_fatal(command_name, remaining_args);

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

test "parse_command_line accepts help short alias" {
    const testing = std.testing;
    const help_parsed = try parse_command_line(&.{ "zvm", "-h" });

    try testing.expect(std.meta.activeTag(help_parsed.command) == .help);
}

test "non-help short global options are rejected" {
    const testing = std.testing;
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-q" }));
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-v" }));
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-V" }));
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-qh" }));
}

test "standard commands remain global regardless of prefix ordering" {
    const testing = std.testing;
    const version_parsed = try parse_command_line(&.{ "zvm", "--version", "--json" });
    const version_reversed = try parse_command_line(&.{ "zvm", "--json", "--version" });
    const help_parsed = try parse_command_line(&.{ "zvm", "-h", "--quiet" });
    const help_reversed = try parse_command_line(&.{ "zvm", "--quiet", "-h" });

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
    try testing.expectEqual(util_output.ColorMode.auto, parsed.global_config.color_mode);
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

test "parse_global_prefix rejects duplicate --color" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--color", "--color" }));
}

test "parse_global_prefix rejects duplicate --no-color" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--no-color", "--no-color" }));
}

test "parse_global_prefix rejects conflicting --color and --no-color" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--color", "--no-color" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--no-color", "--color" }));
}

test "parse_global_prefix rejects duplicate --json" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--json", "--json" }));
}

test "parse_global_prefix rejects duplicate --quiet" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--quiet", "--quiet" }));
}

test "parse_global_prefix rejects --json --color conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--json", "--color" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--color", "--json" }));
}

test "parse_global_prefix rejects --json --no-color (both set never, still duplicate)" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--json", "--no-color" }));
}

test "parse_global_prefix rejects duplicate --help" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--help", "--help" }));
}

test "parse_global_prefix rejects duplicate --version" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--version", "--version" }));
}

test "parse_global_prefix rejects --help --version conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--help", "--version" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--version", "--help" }));
}

test "parse_global_prefix accepts --yes" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--yes", "remove" });
    try testing.expect(parsed.global_config.assume_yes);
    try testing.expect(!parsed.global_config.no_input);
}

test "parse_global_prefix accepts --no-input" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--no-input", "remove" });
    try testing.expect(parsed.global_config.no_input);
    try testing.expect(!parsed.global_config.assume_yes);
}

test "parse_global_prefix rejects duplicate --yes" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--yes", "--yes" }));
}

test "parse_global_prefix rejects duplicate --no-input" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--no-input", "--no-input" }));
}

test "parse_global_prefix rejects -y (only long options are accepted)" {
    const testing = std.testing;
    try testing.expectError(error.UnknownGlobalShortOption, parse_global_prefix(&.{ "zvm", "-y", "remove" }));
}

test "parse_global_prefix defaults verbose to none" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "list" });
    try testing.expectEqual(util_output.VerboseLevel.none, parsed.global_config.verbose);
}

test "parse_global_prefix promotes verbose with --verbose long flag" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--verbose", "list" });
    try testing.expectEqual(util_output.VerboseLevel.debug, parsed.global_config.verbose);
}

test "parse_global_prefix rejects duplicate --verbose" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--verbose", "--verbose", "list" }));
}

test "parse_global_prefix promotes to trace with --trace" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--trace", "list" });
    try testing.expectEqual(util_output.VerboseLevel.trace, parsed.global_config.verbose);
}

test "parse_global_prefix rejects --verbose --trace conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--verbose", "--trace", "list" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--trace", "--verbose", "list" }));
}

test "parse_global_prefix accepts --plain and forces never_use_color" {
    const testing = std.testing;
    const parsed = try parse_global_prefix(&.{ "zvm", "--plain", "list" });
    try testing.expectEqual(util_output.OutputMode.plain, parsed.global_config.output_mode);
    try testing.expectEqual(util_output.ColorMode.never_use_color, parsed.global_config.color_mode);
}

test "parse_global_prefix rejects duplicate --plain" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--plain", "--plain" }));
}

test "parse_global_prefix rejects --plain --json conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--plain", "--json" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--json", "--plain" }));
}

test "parse_global_prefix rejects --plain --quiet conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--plain", "--quiet" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--quiet", "--plain" }));
}

test "parse_global_prefix rejects --plain --color conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--plain", "--color" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--color", "--plain" }));
}

test "parse_global_prefix rejects --plain --no-color conflict" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--plain", "--no-color" }));
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "--no-color", "--plain" }));
}

test "parse_global_prefix rejects duplicate short standard commands" {
    const testing = std.testing;
    try testing.expectError(error.DuplicateGlobalOption, parse_global_prefix(&.{ "zvm", "-h", "-h" }));
}
