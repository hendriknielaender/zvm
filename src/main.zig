const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const parser = @import("cli/parser.zig");
const validation = @import("cli/validation.zig");
const Context = @import("Context.zig");
const memory_limits = @import("memory/limits.zig");
const memory_static = @import("memory.zig");
const util_output = @import("util/output.zig");
const util_tool = @import("util/tool.zig");
const signals = @import("platform/signals.zig");
const metadata = @import("metadata.zig");
const build_options = @import("options");

const log = std.log.scoped(.zvm);
const build_log_level: std.log.Level = @enumFromInt(@intFromEnum(build_options.log_level));

pub const std_options: std.Options = .{
    .log_level = build_log_level,
    .logFn = log_message,
};

// Compile-time assertions for design assumptions
comptime {
    // Validate memory limits are reasonable
    assert(memory_limits.arguments_maximum > 0);
    assert(memory_limits.arguments_maximum <= 1024);

    // Validate buffer sizes are sufficient
    assert(memory_limits.home_dir_length_maximum >= 256);
    assert(memory_limits.path_length_maximum >= 512);

    // Validate semantic version parsing works
    _ = std.SemanticVersion.parse("0.13.0") catch @compileError("Semantic version parsing failed");
}

const command_runner = @import("core/command.zig");
const shim = @import("shim.zig");

// SAFETY: global_static_buffer is initialized before first use in main().
// StaticMemory requires at least 8-byte alignment for its fixed allocator state.
var global_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 align(8) = undefined;
// SAFETY: global_context is initialized in main() before being accessed
var global_context: Context.CliContext = undefined;

fn log_message(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!util_output.is_global_initialized()) {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    }

    if (util_output.output_mode() != .human_readable) return;
    if (message_level == .err) return;

    std.log.defaultLog(message_level, scope, format, args);
}

fn has_windows_env_var(comptime var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const value = util_tool.getenv_cross_platform(var_name) orelse return false;
    return value.len > 0;
}

fn append_argument_to_static_storage(
    arguments_buffer: *[memory_limits.arguments_maximum][]const u8,
    arguments_storage: *[memory_limits.arguments_storage_size_maximum]u8,
    arguments_count: u32,
    arguments_storage_offset: *usize,
    argument: []const u8,
) !void {
    assert(arguments_count < arguments_buffer.len);

    const argument_start = arguments_storage_offset.*;
    const argument_end = argument_start + argument.len;
    if (argument_end > arguments_storage.len) {
        return error.ArgumentStorageFull;
    }

    @memcpy(arguments_storage[argument_start..argument_end], argument);
    arguments_buffer[arguments_count] = arguments_storage[argument_start..argument_end];
    arguments_storage_offset.* = argument_end;

    assert(arguments_storage_offset.* == argument_start + argument.len);
}

pub fn main(process_init: std.process.Init) !void {
    util_tool.set_environment_map(process_init.environ_map);
    signals.install_handler();

    var arguments_buffer: [memory_limits.arguments_maximum][]const u8 = undefined;
    var arguments_storage: [memory_limits.arguments_storage_size_maximum]u8 = undefined;
    const arguments_count = try collect_arguments(
        process_init,
        &arguments_buffer,
        &arguments_storage,
    );

    const arguments = arguments_buffer[0..arguments_count];
    if (arguments.len == 0) {
        log.err("No arguments provided to zvm", .{});
        return error.NoArguments;
    }

    const program_name = arguments[0];
    const basename = std.fs.path.basename(program_name);

    metadata.init_config();

    const color_environment = inspect_color_environment();
    try apply_initial_output_config(color_environment);

    if (shim.is_shim_name(basename)) {
        try shim.run(process_init.io, basename, arguments[1..]);
        unreachable;
    }

    // Pre-scan for verbose flags so parse-error fatals respect --verbose.
    // Why: parser.parse_command_line emits its own fatals (unknown option,
    // duplicate, etc.). If verbose is only applied after that returns, the
    // operator who passed `--verbose --bogus` would not get the [fatal]
    // tag they explicitly asked for. The full parse still owns the
    // authoritative value; this only widens the window where it applies.
    util_output.set_verbose_level(prescan_verbose_level(arguments));

    const parsed_command_line = parser.parse_command_line(arguments) catch |err| {
        util_output.exit_with(util_output.ExitCode.from_error(err), "Failed to parse command line: {s}", .{@errorName(err)});
    };

    const final_output_config = try apply_final_output_config(
        color_environment,
        parsed_command_line.global_config,
    );

    const context_instance = init_context_or_exit(
        arguments,
        process_init.io,
        parsed_command_line.global_config,
    );
    const progress_item_count = get_progress_item_count(parsed_command_line.command);
    const root_node = std.Progress.start(process_init.io, .{
        .root_name = "zvm",
        .estimated_total_items = progress_item_count,
        .disable_printing = progress_item_count == 0 or
            final_output_config.mode != .human_readable or
            !color_environment.stderr_is_tty,
    });

    execute_command_or_exit(context_instance, parsed_command_line.command, root_node);
    root_node.end();

    if (util_output.debug_enabled() and final_output_config.mode == .human_readable) {
        try context_instance.print_debug_info();
    }
}

/// Copy process arguments into caller-owned static storage and return the
/// argument count. The caller owns the buffers because the returned slices
/// in `arguments_buffer` reference `arguments_storage`, which must outlive
/// this function.
fn collect_arguments(
    process_init: std.process.Init,
    arguments_buffer: *[memory_limits.arguments_maximum][]const u8,
    arguments_storage: *[memory_limits.arguments_storage_size_maximum]u8,
) !u32 {
    var arguments_count: u32 = 0;
    var arguments_storage_offset: usize = 0;

    var arguments_iterator_storage: [memory_limits.arguments_storage_size_maximum]u8 = undefined;
    var arguments_iterator_fba = std.heap.FixedBufferAllocator.init(&arguments_iterator_storage);
    var arguments_iterator = try process_init.minimal.args.iterateAllocator(arguments_iterator_fba.allocator());
    defer arguments_iterator.deinit();

    while (arguments_iterator.next()) |argument| : (arguments_count += 1) {
        if (arguments_count >= arguments_buffer.len) {
            log.err("Too many arguments: got {d}, maximum is {d}", .{
                arguments_count + 1,
                arguments_buffer.len,
            });
            return error.TooManyArguments;
        }

        append_argument_to_static_storage(
            arguments_buffer,
            arguments_storage,
            arguments_count,
            &arguments_storage_offset,
            argument,
        ) catch |err| switch (err) {
            error.ArgumentStorageFull => {
                log.err(
                    "Arguments exceed static storage: need at least {d} bytes, maximum is {d}",
                    .{ arguments_storage_offset + argument.len, arguments_storage.len },
                );
                return err;
            },
        };
    }

    assert(arguments_count <= arguments_buffer.len);
    return arguments_count;
}

/// Environment facts that drive color-mode resolution, captured once so the
/// initial (pre-parse) and final (post-parse) resolutions agree.
const ColorEnvironment = struct {
    no_color: bool,
    term_is_dumb: bool,
    stdout_is_tty: bool,
    stderr_is_tty: bool,
};

fn inspect_color_environment() ColorEnvironment {
    const no_color = if (util_tool.getenv_cross_platform("NO_COLOR")) |val|
        val.len > 0
    else
        false;
    const term_is_dumb = if (util_tool.getenv_cross_platform("TERM")) |val|
        std.mem.eql(u8, val, "dumb")
    else
        false;

    return .{
        .no_color = no_color,
        .term_is_dumb = term_is_dumb,
        .stdout_is_tty = util_output.stdout_is_terminal(),
        .stderr_is_tty = util_output.stderr_is_terminal(),
    };
}

/// Apply a provisional output configuration before any output is emitted.
/// Color must be resolved before the first emitter is created so that even
/// error messages during parsing respect the terminal and environment.
fn apply_initial_output_config(color_environment: ColorEnvironment) !void {
    const initial_color = util_output.resolve_color_mode(
        .auto,
        color_environment.no_color,
        color_environment.stdout_is_tty,
        color_environment.term_is_dumb,
    );

    try util_output.set_mode(.{
        .mode = .human_readable,
        .color = initial_color,
    });
}

/// Apply the authoritative output configuration from parsed global flags
/// (which may override the environment) and return it. Verbose level:
/// explicit --verbose wins; otherwise honor the legacy ZVM_DEBUG env var as
/// a single-step debug equivalence. Why env-var fallback: long-standing
/// scripts and CI configs depend on it — silently dropping support would
/// surprise operators on upgrade.
fn apply_final_output_config(
    color_environment: ColorEnvironment,
    global_config: parser.GlobalConfig,
) !util_output.OutputConfig {
    const final_color = util_output.resolve_color_mode(
        global_config.color_mode,
        color_environment.no_color,
        color_environment.stdout_is_tty,
        color_environment.term_is_dumb,
    );

    const final_output_config = util_output.OutputConfig{
        .mode = global_config.output_mode,
        .color = final_color,
    };
    try util_output.set_mode(final_output_config);

    const verbose_from_env: util_output.VerboseLevel =
        if (read_zvm_debug_env()) .debug else .none;
    const verbose_from_flag = global_config.verbose;
    const verbose_effective: util_output.VerboseLevel =
        if (@intFromEnum(verbose_from_flag) >= @intFromEnum(verbose_from_env))
            verbose_from_flag
        else
            verbose_from_env;
    util_output.set_verbose_level(verbose_effective);

    return final_output_config;
}

/// Best-effort scan for `--verbose` / `--trace` before the
/// authoritative parse runs. Stops at the first non-option (the command),
/// at `--`, or at end of args. Why bounded: verbose is a global option,
/// so anything after the command name belongs to the subcommand and
/// should not influence global verbosity. ZVM_DEBUG is not consulted
/// here — that env var is folded in only after the full parse so the
/// flag-vs-env precedence rule lives in exactly one place.
fn prescan_verbose_level(arguments: []const []const u8) util_output.VerboseLevel {
    assert(arguments.len > 0);

    var level: util_output.VerboseLevel = .none;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const arg = arguments[index];
        assert(arg.len > 0);

        if (std.mem.eql(u8, arg, "--")) break;
        if (arg.len < 2 or arg[0] != '-') break;

        if (std.mem.eql(u8, arg, "--verbose")) {
            level = .debug;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace")) {
            level = .trace;
            continue;
        }
    }
    return level;
}

/// Read the legacy `ZVM_DEBUG` env var. Any non-empty value enables
/// debug-equivalent output; matches the documented behavior shown in
/// `zvm help`. Trace level is only reachable through `--trace` to keep the
/// env-var path strictly backward-compatible.
fn read_zvm_debug_env() bool {
    if (builtin.os.tag == .windows) {
        return has_windows_env_var("ZVM_DEBUG");
    }
    const value = util_tool.getenv_cross_platform("ZVM_DEBUG") orelse return false;
    return value.len > 0;
}

fn get_progress_item_count(command: validation.ValidatedCommand) u16 {
    return command_runner.progress_items(command);
}

/// Initialize the global command context, exiting with a diagnostic on
/// failure. Applies the parsed global flags that live on the context.
fn init_context_or_exit(
    arguments: []const []const u8,
    io: std.Io,
    global_config: parser.GlobalConfig,
) *Context.CliContext {
    const context_instance = Context.CliContext.init_locked(
        &global_context,
        &global_static_buffer,
        arguments,
        io,
    ) catch |err| {
        util_output.exit_with(
            util_output.ExitCode.from_error(err),
            "Failed to initialize command context: {s}",
            .{@errorName(err)},
        );
    };
    context_instance.assume_yes = global_config.assume_yes;
    context_instance.no_input = global_config.no_input;
    return context_instance;
}

/// Run the command, exiting with a diagnostic and the mapped exit code on
/// failure. Interruption exits immediately without the failure banner.
fn execute_command_or_exit(
    ctx: *Context.CliContext,
    command: validation.ValidatedCommand,
    progress_node: std.Progress.Node,
) void {
    command_runner.run(ctx, command, progress_node) catch |err| {
        progress_node.end();
        if (err == error.Interrupted) {
            std.process.exit(@intFromEnum(util_output.ExitCode.interrupted));
        }
        // Surface a debugging hint only when verbose is off — otherwise the
        // operator already has the trace lines and a second nudge is noise.
        if (!util_output.debug_enabled()) {
            util_output.emit(.error_recoverable, "Re-run with --verbose for debug output, or --trace for trace output.", .{});
        }
        util_output.exit_with(
            util_output.ExitCode.from_error(err),
            "Command failed: {s}",
            .{@errorName(err)},
        );
    };
}
