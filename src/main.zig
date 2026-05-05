const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const parser = @import("cli/parser.zig");
const Context = @import("Context.zig");
const memory_limits = @import("memory/limits.zig");
const memory_static = @import("memory/static_memory.zig");
const util_output = @import("util/output.zig");
const util_tool = @import("util/tool.zig");
const paths = @import("platform/paths.zig");
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
    assert(memory_limits.limits.arguments_maximum > 0);
    assert(memory_limits.limits.arguments_maximum <= 1024);

    // Validate buffer sizes are sufficient
    assert(memory_limits.limits.home_dir_length_maximum >= 256);
    assert(memory_limits.limits.path_length_maximum >= 512);

    // Validate semantic version parsing works
    _ = std.SemanticVersion.parse("0.13.0") catch @compileError("Semantic version parsing failed");
}

const commands = struct {
    pub const help = @import("commands/help.zig");
    pub const version = @import("commands/version.zig");
    pub const list = @import("commands/list.zig");
    pub const list_remote = @import("commands/list_remote.zig");
    pub const list_mirrors = @import("commands/list_mirrors.zig");
    pub const install = @import("commands/install.zig");
    pub const remove = @import("commands/remove.zig");
    pub const use = @import("commands/use.zig");
    pub const clean = @import("commands/clean.zig");
    pub const env = @import("commands/env.zig");
    pub const completions = @import("commands/completions.zig");
    pub const upgrade = @import("commands/upgrade.zig");
};

const install = @import("core/install.zig");

// SAFETY: global_static_buffer is initialized before first use in main().
// StaticMemory requires at least 8-byte alignment for its fixed allocator state.
var global_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 align(8) = undefined;
// SAFETY: alias_static_buffer is used for alias handling to avoid conflicts with main context.
// It must meet the same alignment requirement as the primary static buffer.
var alias_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 align(8) = undefined;
// SAFETY: global_context is initialized in main() before being accessed
var global_context: Context.CliContext = undefined;

const AliasBuffers = struct {
    home: [memory_limits.limits.home_dir_length_maximum]u8,
    zvm_home: [memory_limits.limits.home_dir_length_maximum]u8,
    tool_path: [memory_limits.limits.path_length_maximum]u8,
    exec_arguments_ptrs: [memory_limits.limits.arguments_maximum + 1]?[*:0]const u8,
    exec_arguments_storage: [memory_limits.limits.arguments_storage_size_maximum]u8,
    process_scratch: [memory_limits.limits.process_scratch_size_maximum]u8,
    exec_arguments_count: u32 = 0,
};

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

    const config = util_output.get_global_config() orelse {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    };

    if (config.mode != .human_readable) return;
    if (message_level == .err) return;

    std.log.defaultLog(message_level, scope, format, args);
}

fn has_windows_env_var(comptime var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const value = util_tool.getenv_cross_platform(var_name) orelse return false;
    return value.len > 0;
}

fn append_argument_to_static_storage(
    arguments_buffer: *[memory_limits.limits.arguments_maximum][]const u8,
    arguments_storage: *[memory_limits.limits.arguments_storage_size_maximum]u8,
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

    var arguments_buffer: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    var arguments_storage: [memory_limits.limits.arguments_storage_size_maximum]u8 = undefined;
    var arguments_count: u32 = 0;
    var arguments_storage_offset: usize = 0;

    var arguments_iterator_storage: [memory_limits.limits.arguments_storage_size_maximum]u8 = undefined;
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
            &arguments_buffer,
            &arguments_storage,
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

    const arguments = arguments_buffer[0..arguments_count];
    if (arguments.len == 0) {
        log.err("No arguments provided to zvm", .{});
        return error.NoArguments;
    }

    const program_name = arguments[0];
    const basename = std.fs.path.basename(program_name);

    metadata.init_config();

    const is_alias = util_tool.eql_str(basename, "zig") or util_tool.eql_str(basename, "zls");
    if (is_alias) {
        try handle_alias(process_init.io, basename, arguments[1..]);
        unreachable;
    }

    // Inspect environment for color-mode resolution before any output is emitted.
    // Color must be resolved before the first emitter is created so that even
    // error messages during parsing respect the terminal and environment.
    const no_color_env = if (util_tool.getenv_cross_platform("NO_COLOR")) |val|
        val.len > 0
    else
        false;
    const term_is_dumb = if (util_tool.getenv_cross_platform("TERM")) |val|
        std.mem.eql(u8, val, "dumb")
    else
        false;
    const is_tty = util_output.stdout_is_terminal();
    const stderr_is_tty = util_output.stderr_is_terminal();

    const initial_color = util_output.resolve_color_mode(
        .auto,
        no_color_env,
        is_tty,
        term_is_dumb,
    );

    const default_output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = initial_color,
    };
    _ = try util_output.init_global(default_output_config);

    const parsed_command_line = parser.parse_command_line(arguments) catch |err| {
        util_output.fatal(util_output.ExitCode.from_error(err), "Failed to parse command line: {s}", .{@errorName(err)});
    };

    // Resolve final color mode from parsed flags (which may override environment).
    const final_color = util_output.resolve_color_mode(
        parsed_command_line.global_config.color_mode,
        no_color_env,
        is_tty,
        term_is_dumb,
    );

    const final_output_config = util_output.OutputConfig{
        .mode = parsed_command_line.global_config.output_mode,
        .color = final_color,
    };
    _ = try util_output.update_global(final_output_config);

    const context_instance = Context.CliContext.init(
        &global_context,
        &global_static_buffer,
        arguments,
        process_init.io,
    ) catch |err| {
        util_output.fatal(
            util_output.ExitCode.from_error(err),
            "Failed to initialize command context: {s}",
            .{@errorName(err)},
        );
    };
    // Freeze startup allocation before command execution begins.
    context_instance.static_mem.lock();

    const root_node = std.Progress.start(process_init.io, .{
        .root_name = "zvm",
        .estimated_total_items = get_progress_item_count(parsed_command_line.command),
        .disable_printing = final_output_config.mode != .human_readable or !stderr_is_tty,
    });

    execute_command(context_instance, parsed_command_line.command, root_node) catch |err| {
        root_node.end();
        util_output.fatal(
            util_output.ExitCode.from_error(err),
            "Command failed: {s}",
            .{@errorName(err)},
        );
    };

    root_node.end();

    const has_debug = if (builtin.os.tag == .windows) blk: {
        break :blk has_windows_env_var("ZVM_DEBUG");
    } else blk: {
        break :blk util_tool.getenv_cross_platform("ZVM_DEBUG") != null;
    };

    if (has_debug and final_output_config.mode == .human_readable) {
        try context_instance.print_debug_info();
    }
}

const AutoInstallError = error{
    AlreadyCurrent,
    ContextInitFailed,
    InstallationFailed,
};

pub fn auto_install_version(io: std.Io, version: []const u8) AutoInstallError!void {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    if (std.mem.eql(u8, version, "current")) return error.AlreadyCurrent;

    // Create a minimal context for installation
    // SAFETY: CliContext.init() initializes every field before the context is used.
    var install_context: Context.CliContext = undefined;
    var install_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 = undefined;

    // Pair assertion: Validate static buffer size
    assert(install_static_buffer.len > 0);
    assert(install_static_buffer.len <= 1024 * 1024); // 1MB max

    // Minimal arguments for context initialization
    const install_args = &[_][]const u8{ "zvm", "install", version };

    // Initialize context
    const ctx = Context.CliContext.init(
        &install_context,
        &install_static_buffer,
        install_args,
        io,
    ) catch return error.ContextInitFailed;

    // Pair assertion: Validate context initialization
    assert(ctx == &install_context);
    // Freeze startup allocation before runtime work begins.
    ctx.static_mem.lock();

    // Create a minimal progress node
    const progress_node = std.Progress.start(io, .{
        .root_name = "auto-install",
        .estimated_total_items = 5,
    });

    // Call install directly
    install.install(ctx, version, false, progress_node) catch return error.InstallationFailed;
}

fn handle_alias(io: std.Io, program_name: []const u8, remaining_arguments: []const []const u8) !void {
    var version_buffer: [memory_limits.limits.version_string_length_maximum]u8 = undefined;

    // Simple version detection without full context
    const version_result =
        detect_version_for_alias(io, remaining_arguments, &version_buffer) catch |err| switch (err) {
            error.OutOfMemory => {
                // OutOfMemory should kill process
                @panic("Out of memory in version detection");
            },
            else => {
                log.err("Failed to detect version: {s}", .{@errorName(err)});
                return handle_alias_fallback(io, program_name, remaining_arguments);
            },
        };

    // Check if the detected version is available
    const version_available = ensure_version_available(io, version_result) catch false;
    if (!version_available and !std.mem.eql(u8, version_result, "current")) {
        // Try to auto-install the missing version
        if (auto_install_version_gracefully(io, version_result)) {
            // Installation successful, proceed with the version
        } else {
            // Installation failed, fall back to current version
            return handle_alias_fallback(io, program_name, remaining_arguments);
        }
    }

    // If we're using current version or version is available, proceed with smart tool path
    if (std.mem.eql(u8, version_result, "current")) {
        return handle_alias_fallback(io, program_name, remaining_arguments);
    }

    // Build adjusted arguments (remove version if it was the first argument)
    var adjusted_args_buffer: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    var adjusted_args_count: usize = 0;

    const skip_first = remaining_arguments.len > 0 and is_version_string(remaining_arguments[0]);
    const start_idx = if (skip_first) @as(usize, 1) else @as(usize, 0);

    for (remaining_arguments[start_idx..]) |arg| {
        if (adjusted_args_count >= adjusted_args_buffer.len) return error.TooManyArguments;
        adjusted_args_buffer[adjusted_args_count] = arg;
        adjusted_args_count += 1;
    }

    const adjusted_args = adjusted_args_buffer[0..adjusted_args_count];

    // SAFETY: All undefined fields are initialized by subsequent function calls before use
    var alias_buffers: AliasBuffers = .{
        .home = undefined,
        .zvm_home = undefined,
        .tool_path = undefined,
        .exec_arguments_ptrs = undefined,
        .exec_arguments_storage = undefined,
        .process_scratch = undefined,
        .exec_arguments_count = 0,
    };

    const home_slice = try get_home_path(&alias_buffers);
    const zvm_home = try get_zvm_home_path(&alias_buffers, home_slice);
    const tool_path = try build_smart_tool_path(&alias_buffers, program_name, zvm_home, version_result);
    try build_exec_arguments(&alias_buffers, tool_path, adjusted_args);

    if (builtin.os.tag == .windows) {
        var argv_list: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
        var i: usize = 0;
        while (alias_buffers.exec_arguments_ptrs[i]) |arg| : (i += 1) {
            argv_list[i] = std.mem.sliceTo(arg, 0);
        }
        const argv_slice = argv_list[0..i];

        const err = std.process.replace(io, .{ .argv = argv_slice });
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
        return err;
    } else {
        var argv_list: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
        const argv_slice = build_exec_arguments_slice(&alias_buffers, &argv_list);

        const err = std.process.replace(io, .{ .argv = argv_slice });
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
        return err;
    }
}
fn detect_version_for_alias(io: std.Io, args: []const []const u8, version_buffer: []u8) ![]const u8 {
    assert(version_buffer.len > 0);

    if (args.len > 0 and is_version_string(args[0])) {
        return args[0];
    }

    // Try to find build.zig.zon and extract minimum_zig_version
    var current_dir_buf: [1024]u8 = undefined;
    const current_dir_len = std.process.currentPath(io, &current_dir_buf) catch return "current";
    const current_dir = current_dir_buf[0..current_dir_len];

    var search_dir: []const u8 = current_dir;
    while (true) {
        var path_buf: [2048]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/build.zig.zon", .{search_dir}) catch break;

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            const parent = std.fs.path.dirname(search_dir) orelse break;
            if (std.mem.eql(u8, parent, search_dir)) break;
            search_dir = parent;
            continue;
        };
        defer file.close(io);

        var content_buf: [8192]u8 = undefined;
        var reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &reader_buffer);
        const bytes_read = file_reader.interface.readSliceShort(&content_buf) catch break;
        if (bytes_read == 0) break;

        if (extract_minimum_zig_version_from_zon(
            content_buf[0..bytes_read],
            version_buffer,
        )) |version| {
            // Validate version using semantic version parsing
            if (validate_semantic_version(version)) {
                assert(version.len > 0);
                assert(version.len <= version_buffer.len);
                return version;
            }
            return "current";
        }

        const parent = std.fs.path.dirname(search_dir) orelse break;
        if (std.mem.eql(u8, parent, search_dir)) break;
        search_dir = parent;
    }

    return "current";
}

pub fn validate_semantic_version(version: []const u8) bool {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    if (std.mem.eql(u8, version, "master")) return true;
    if (std.mem.eql(u8, version, "current")) return true;

    // Use std.SemanticVersion for proper validation
    _ = std.SemanticVersion.parse(version) catch return false;
    return true;
}

pub fn extract_minimum_zig_version_from_zon(content: []const u8, version_buffer: []u8) ?[]const u8 {
    // Pair assertion: Validate input bounds
    assert(content.len > 0); // Don't process empty content
    assert(content.len <= 8192); // Reasonable upper bound for ZON

    const key = "minimum_zig_version";
    var index: usize = 0;

    while (index < content.len) : (index += 1) {
        if (index + key.len > content.len) {
            break;
        }

        if (!std.mem.eql(u8, content[index .. index + key.len], key)) {
            continue;
        }

        var cursor = index + key.len;
        while (cursor < content.len and std.ascii.isWhitespace(content[cursor])) : (cursor += 1) {}

        if (cursor >= content.len or content[cursor] != '=') {
            continue;
        }
        cursor += 1;

        while (cursor < content.len and std.ascii.isWhitespace(content[cursor])) : (cursor += 1) {}

        if (cursor >= content.len or content[cursor] != '"') {
            continue;
        }
        cursor += 1;

        const version_start = cursor;
        while (cursor < content.len and content[cursor] != '"') : (cursor += 1) {}

        if (cursor >= content.len) {
            continue;
        }

        const version = content[version_start..cursor];
        if (version.len == 0) {
            continue;
        }
        if (version.len > version_buffer.len) {
            continue;
        }

        @memcpy(version_buffer[0..version.len], version);
        return version_buffer[0..version.len];
    }

    return null;
}

test "detect_version_for_alias prefers explicit version argument" {
    var version_buffer: [memory_limits.limits.version_string_length_maximum]u8 = undefined;
    const arguments = &[_][]const u8{ "0.16.0", "build" };

    const detected = try detect_version_for_alias(std.testing.io, arguments, &version_buffer);
    try std.testing.expectEqualStrings("0.16.0", detected);
}

test "extract_minimum_zig_version_from_zon parses zon source without allocation" {
    const content =
        \\.{
        \\    .name = "sample",
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.14.1",
        \\    .dependencies = .{},
        \\}
    ;

    var version_buffer: [memory_limits.limits.version_string_length_maximum]u8 = undefined;
    const detected = extract_minimum_zig_version_from_zon(content, &version_buffer) orelse
        return error.ExpectedVersionInZon;

    try std.testing.expectEqualStrings("0.14.1", detected);
}

fn ensure_version_available(io: std.Io, version: []const u8) !bool {
    assert(version.len > 0);

    if (std.mem.eql(u8, version, "current")) return true;

    var home_buf: [memory_limits.limits.home_dir_length_maximum]u8 = undefined;
    const home = try paths.get_home_path(&home_buf);

    var zvm_root_buf: [memory_limits.limits.path_length_maximum]u8 = undefined;
    const zvm_root = try paths.get_zvm_root(&zvm_root_buf, home);

    var version_path_buf: [memory_limits.limits.path_length_maximum]u8 = undefined;
    const version_path = try std.fmt.bufPrint(
        &version_path_buf,
        "{s}/version/zig/{s}",
        .{ zvm_root, version },
    );

    var dir = std.Io.Dir.cwd().openDir(io, version_path, .{}) catch return false;
    defer dir.close(io);

    var zig_path_buf: [memory_limits.limits.path_length_maximum]u8 = undefined;
    const zig_path = try std.fmt.bufPrint(&zig_path_buf, "{s}/zig", .{version_path});
    dir.access(io, zig_path, .{}) catch return false;

    return true;
}

fn is_version_string(str: []const u8) bool {
    if (str.len == 0) return false;

    // Check for specific version patterns like "0.13.0", "0.12.0", etc.
    // Don't match command names like "version", "build", etc.
    if (std.mem.eql(u8, str, "version")) return false;
    if (std.mem.eql(u8, str, "build")) return false;
    if (std.mem.eql(u8, str, "test")) return false;
    if (std.mem.eql(u8, str, "run")) return false;
    if (std.mem.eql(u8, str, "help")) return false;

    // Check for semantic version pattern (X.Y.Z)
    var dot_count: usize = 0;
    var has_digit = false;
    for (str) |c| {
        if (c == '.') {
            dot_count += 1;
        } else if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if (c != '-' and c != 'm' and c != 'a' and c != 's' and c != 't' and c != 'e' and c != 'r') {
            // Only allow specific characters for versions like "master"
            return false;
        }
    }

    // Must have at least one digit and either dots or be "master"
    return has_digit and (dot_count > 0 or std.mem.eql(u8, str, "master"));
}

fn auto_install_version_gracefully(io: std.Io, version: []const u8) bool {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    // Use the existing auto_install_version function but handle errors gracefully
    auto_install_version(io, version) catch return false;
    return true;
}

fn handle_alias_fallback(io: std.Io, program_name: []const u8, remaining_arguments: []const []const u8) !void {
    // SAFETY: All undefined fields are initialized by subsequent function calls before use
    var alias_buffers: AliasBuffers = .{
        .home = undefined,
        .zvm_home = undefined,
        .tool_path = undefined,
        .exec_arguments_ptrs = undefined,
        .exec_arguments_storage = undefined,
        .process_scratch = undefined,
        .exec_arguments_count = 0,
    };

    const home_slice = try get_home_path(&alias_buffers);
    const zvm_home = try get_zvm_home_path(&alias_buffers, home_slice);
    const tool_path = try build_tool_path(&alias_buffers, program_name, zvm_home);
    try build_exec_arguments(&alias_buffers, tool_path, remaining_arguments);

    if (builtin.os.tag == .windows) {
        var argv_list: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
        var i: usize = 0;
        while (alias_buffers.exec_arguments_ptrs[i]) |arg| : (i += 1) {
            argv_list[i] = std.mem.sliceTo(arg, 0);
        }
        const argv_slice = argv_list[0..i];

        const err = std.process.replace(io, .{ .argv = argv_slice });
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
        return err;
    } else {
        var argv_list: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
        const argv_slice = build_exec_arguments_slice(&alias_buffers, &argv_list);

        const err = std.process.replace(io, .{ .argv = argv_slice });
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
        return err;
    }
}

fn get_home_path(alias_buffers: *AliasBuffers) ![]const u8 {
    const home = try paths.get_home_path(&alias_buffers.home);
    assert(home.len > 0);
    assert(home.len <= alias_buffers.home.len);
    return home;
}

fn get_zvm_home_path(alias_buffers: *AliasBuffers, home_slice: []const u8) ![]const u8 {
    const zvm_home = try paths.get_zvm_root(&alias_buffers.zvm_home, home_slice);
    assert(zvm_home.len > 0);
    assert(zvm_home.len <= alias_buffers.zvm_home.len);
    return zvm_home;
}

fn build_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8) ![]const u8 {
    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";

    return try std.fmt.bufPrint(&alias_buffers.tool_path, "{s}/current/{s}/{s}", .{ zvm_home, tool_name, tool_name });
}

fn build_smart_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8, version: []const u8) ![]const u8 {
    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";

    return if (util_tool.eql_str(version, "current"))
        try std.fmt.bufPrint(&alias_buffers.tool_path, "{s}/current/{s}/{s}", .{ zvm_home, tool_name, tool_name })
    else
        try std.fmt.bufPrint(&alias_buffers.tool_path, "{s}/version/{s}/{s}/{s}", .{ zvm_home, tool_name, version, tool_name });
}

fn build_exec_arguments(alias_buffers: *AliasBuffers, tool_path: []const u8, remaining_arguments: []const []const u8) !void {
    var exec_arguments_count: u32 = 0;
    var storage_offset: u32 = 0;

    if (tool_path.len > alias_buffers.exec_arguments_storage.len) {
        return error.ToolPathTooLong;
    }

    @memcpy(alias_buffers.exec_arguments_storage[0..tool_path.len], tool_path);
    alias_buffers.exec_arguments_storage[tool_path.len] = 0;
    alias_buffers.exec_arguments_ptrs[0] = @ptrCast(&alias_buffers.exec_arguments_storage[0]);
    exec_arguments_count = 1;
    storage_offset = @intCast(tool_path.len + 1);

    for (remaining_arguments) |argument| {
        if (exec_arguments_count >= alias_buffers.exec_arguments_ptrs.len) {
            return error.TooManyExecArgs;
        }
        if (storage_offset + argument.len + 1 > alias_buffers.exec_arguments_storage.len) {
            return error.ExecArgsStorageFull;
        }

        @memcpy(alias_buffers.exec_arguments_storage[storage_offset .. storage_offset + argument.len], argument);
        alias_buffers.exec_arguments_storage[storage_offset + argument.len] = 0;
        alias_buffers.exec_arguments_ptrs[exec_arguments_count] = @ptrCast(&alias_buffers.exec_arguments_storage[storage_offset]);
        storage_offset += @intCast(argument.len + 1);
        exec_arguments_count += 1;
    }

    alias_buffers.exec_arguments_ptrs[exec_arguments_count] = null;
    alias_buffers.exec_arguments_count = exec_arguments_count;
}

fn build_exec_arguments_slice(
    alias_buffers: *const AliasBuffers,
    argv_list: *[memory_limits.limits.arguments_maximum][]const u8,
) []const []const u8 {
    assert(alias_buffers.exec_arguments_count > 0);
    assert(alias_buffers.exec_arguments_count < alias_buffers.exec_arguments_ptrs.len);

    for (0..alias_buffers.exec_arguments_count) |index| {
        const argument = alias_buffers.exec_arguments_ptrs[index].?;
        argv_list[index] = std.mem.sliceTo(argument, 0);
    }

    return argv_list[0..alias_buffers.exec_arguments_count];
}

fn get_progress_item_count(command: @import("cli/validation.zig").ValidatedCommand) u16 {
    return switch (command) {
        .install => 5,
        .remove => 2,
        .list => 1,
        .use => 2,
        .list_remote => 3,
        .list_mirrors => 0,
        .help => 0,
        .version => 0,
        .clean => |opts| if (opts.remove_all) 10 else 5,
        .env => 1,
        .completions => 1,
        .upgrade => 4,
    };
}

fn execute_command(
    ctx: *Context.CliContext,
    command: @import("cli/validation.zig").ValidatedCommand,
    progress_node: std.Progress.Node,
) !void {
    switch (command) {
        .help => |opts| try commands.help.execute(ctx, opts, progress_node),
        .version => |opts| try commands.version.execute(ctx, opts, progress_node),
        .list => |opts| try commands.list.execute(ctx, opts, progress_node),
        .list_remote => |opts| try commands.list_remote.execute(ctx, opts, progress_node),
        .list_mirrors => |opts| try commands.list_mirrors.execute(ctx, opts, progress_node),
        .install => |opts| try commands.install.execute(ctx, opts, progress_node),
        .remove => |opts| try commands.remove.execute(ctx, opts, progress_node),
        .use => |opts| try commands.use.execute(ctx, opts, progress_node),
        .clean => |opts| try commands.clean.execute(ctx, opts, progress_node),
        .env => |opts| try commands.env.execute(ctx, opts, progress_node),
        .completions => |opts| try commands.completions.execute(ctx, opts, progress_node),
        .upgrade => |opts| try commands.upgrade.execute(ctx, opts, progress_node),
    }
}

test "build_tool_path points at the current tool binary" {
    var alias_buffers: AliasBuffers = .{
        .home = undefined,
        .zvm_home = undefined,
        .tool_path = undefined,
        .exec_arguments_ptrs = undefined,
        .exec_arguments_storage = undefined,
        .process_scratch = undefined,
        .exec_arguments_count = 0,
    };

    const zig_path = try build_tool_path(&alias_buffers, "zig", "/tmp/.zm");
    try std.testing.expectEqualStrings("/tmp/.zm/current/zig/zig", zig_path);

    const zls_path = try build_tool_path(&alias_buffers, "zls", "/tmp/.zm");
    try std.testing.expectEqualStrings("/tmp/.zm/current/zls/zls", zls_path);
}
