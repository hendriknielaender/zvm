const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const parser = @import("cli/parser.zig");
const Context = @import("Context.zig");
const memory_limits = @import("memory/limits.zig");
const memory_static = @import("memory/static_memory.zig");
const util_output = @import("util/output.zig");
const util_tool = @import("util/tool.zig");
const Config = @import("config.zig");
const metadata = @import("metadata.zig");

const log = std.log.scoped(.zvm);

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
};

const detect_version = @import("core/detect_version.zig");
const install = @import("core/install.zig");

// SAFETY: global_static_buffer is initialized before first use in main()
var global_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 = undefined;
// SAFETY: alias_static_buffer is used for alias handling to avoid conflicts with main context
var alias_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 = undefined;
// SAFETY: global_context is initialized in main() before being accessed
var global_context: Context.CliContext = undefined;
// SAFETY: global_config is initialized in main() with Config.init() before being used
var global_config: Config = undefined;

const AliasBuffers = struct {
    home: [memory_limits.limits.home_dir_length_maximum]u8,
    zvm_home: [memory_limits.limits.home_dir_length_maximum]u8,
    tool_path: [memory_limits.limits.path_length_maximum]u8,
    exec_arguments_ptrs: [memory_limits.limits.arguments_maximum + 1]?[*:0]const u8,
    exec_arguments_storage: [memory_limits.limits.arguments_storage_size_maximum]u8,
    exec_arguments_count: u32 = 0,
};

fn has_windows_env_var(var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = std.process.getEnvVarOwned(arena.allocator(), var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };

    return result.len > 0;
}

fn get_windows_env_var(allocator: std.mem.Allocator, var_name: []const u8, buffer: []u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;

    const result = std.process.getEnvVarOwned(allocator, var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };

    if (result.len >= buffer.len) {
        return error.BufferTooSmall;
    }

    @memcpy(buffer[0..result.len], result);
    return buffer[0..result.len];
}

pub fn main() !void {
    var arguments_buffer: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    var arguments_count: u32 = 0;

    {
        var arguments_iterator = try std.process.argsWithAllocator(std.heap.page_allocator);
        defer arguments_iterator.deinit();

        while (arguments_iterator.next()) |argument| : (arguments_count += 1) {
            if (arguments_count >= arguments_buffer.len) {
                log.err("Too many arguments: got {d}, maximum is {d}", .{
                    arguments_count + 1,
                    arguments_buffer.len,
                });
                return error.TooManyArguments;
            }

            arguments_buffer[arguments_count] = argument;
        }
    }

    const arguments = arguments_buffer[0..arguments_count];
    if (arguments.len == 0) {
        log.err("No arguments provided to zvm", .{});
        return error.NoArguments;
    }

    const program_name = arguments[0];
    const basename = std.fs.path.basename(program_name);

    metadata.init_config();
    global_config = Config.init();

    const is_alias = util_tool.eql_str(basename, "zig") or util_tool.eql_str(basename, "zls");
    if (is_alias) {
        try handle_alias(basename, arguments[1..]);
        unreachable;
    }

    const default_output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .always_use_color,
    };
    _ = try util_output.init_global(default_output_config);

    const parsed_command_line = parser.parse_command_line(arguments) catch |err| {
        util_output.fatal(util_output.ExitCode.from_error(err), "Failed to parse command line: {s}", .{@errorName(err)});
    };

    const final_output_config = util_output.OutputConfig{
        .mode = parsed_command_line.global_config.output_mode,
        .color = parsed_command_line.global_config.color_mode,
    };
    _ = try util_output.update_global(final_output_config);

    const context_instance = try Context.CliContext.init(
        &global_context,
        &global_static_buffer,
        arguments,
    );

    const root_node = std.Progress.start(.{
        .root_name = "zvm",
        .estimated_total_items = get_progress_item_count(parsed_command_line.command),
    });

    try execute_command(context_instance, parsed_command_line.command, root_node);

    const has_debug = if (builtin.os.tag == .windows) blk: {
        break :blk has_windows_env_var("ZVM_DEBUG");
    } else blk: {
        break :blk util_tool.getenv_cross_platform("ZVM_DEBUG") != null;
    };

    if (has_debug) {
        try context_instance.print_debug_info();
    }
}

const AutoInstallError = error{
    AlreadyCurrent,
    ContextInitFailed,
    InstallationFailed,
};

pub fn auto_install_version(version: []const u8) AutoInstallError!void {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    if (std.mem.eql(u8, version, "current")) return error.AlreadyCurrent;

    // Create a minimal context for installation
    var install_context: Context.CliContext = undefined;
    var install_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 = undefined;

    // Pair assertion: Validate static buffer size
    assert(install_static_buffer.len > 0);
    assert(install_static_buffer.len <= 1024 * 1024); // 1MB max

    // Minimal arguments for context initialization
    const install_args = &[_][]const u8{ "zvm", "install", version };

    // Initialize context
    const ctx = Context.CliContext.init(&install_context, &install_static_buffer, install_args) catch return error.ContextInitFailed;

    // Pair assertion: Validate context initialization
    assert(ctx == &install_context);

    // Create a minimal progress node
    const progress_node = std.Progress.start(.{
        .root_name = "auto-install",
        .estimated_total_items = 5,
    });

    // Call install directly
    install.install(ctx, version, false, progress_node) catch return error.InstallationFailed;
}

fn handle_alias(program_name: []const u8, remaining_arguments: []const []const u8) !void {
    // Simple version detection without full context
    const version_result = detect_version_simple(remaining_arguments) catch |err| switch (err) {
        error.OutOfMemory => {
            // OutOfMemory should kill process
            @panic("Out of memory in version detection");
        },
        else => {
            log.err("Failed to detect version: {s}", .{@errorName(err)});
            return handle_alias_fallback(program_name, remaining_arguments);
        },
    };

    // Check if the detected version is available
    const version_available = ensure_version_available_simple(version_result) catch false;
    if (!version_available and !std.mem.eql(u8, version_result, "current")) {
        // Try to auto-install the missing version
        if (auto_install_version_simple(version_result)) {
            // Installation successful, proceed with the version
        } else {
            // Installation failed, fall back to current version
            return handle_alias_fallback(program_name, remaining_arguments);
        }
    }

    // If we're using current version or version is available, proceed with smart tool path
    if (std.mem.eql(u8, version_result, "current")) {
        return handle_alias_fallback(program_name, remaining_arguments);
    }

    // Build adjusted arguments (remove version if it was the first argument)
    var adjusted_args_buffer: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    var adjusted_args_count: usize = 0;

    const skip_first = remaining_arguments.len > 0 and is_version_string_simple(remaining_arguments[0]);
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

        var process = std.process.Child.init(argv_slice, std.heap.page_allocator);
        process.spawn() catch |err| {
            log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
            return err;
        };
        const term = try process.wait();
        std.process.exit(term.Exited);
    } else {
        const argv: [*:null]?[*:0]const u8 = @ptrCast(&alias_buffers.exec_arguments_ptrs[0]);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        const result = std.posix.execveZ(argv[0].?, argv, envp);
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(result) });
        return result;
    }
}
fn detect_version_simple(args: []const []const u8) ![]const u8 {
    _ = args; // Mark as used

    // Try to find build.zig.zon and extract minimum_zig_version
    var current_dir_buf: [1024]u8 = undefined;
    const current_dir = std.process.getCwd(&current_dir_buf) catch return "current";

    var search_dir: []const u8 = current_dir;
    while (true) {
        var path_buf: [2048]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/build.zig.zon", .{search_dir}) catch break;

        const file = std.fs.cwd().openFile(path, .{}) catch {
            const parent = std.fs.path.dirname(search_dir) orelse break;
            if (std.mem.eql(u8, parent, search_dir)) break;
            search_dir = parent;
            continue;
        };
        defer file.close();

        var content_buf: [8192]u8 = undefined;
        const bytes_read = file.readAll(&content_buf) catch break;
        if (bytes_read == 0) break;

        if (extractMinimumZigVersionFromJson(content_buf[0..bytes_read])) |version| {
            // Validate version using semantic version parsing
            if (validateSemanticVersion(version)) {
                // Store version in static buffer to avoid allocation issues
                var version_buf: [64]u8 = undefined;
                if (version.len <= version_buf.len) {
                    // Pair assertion: Validate copy bounds
                    assert(version.len > 0);
                    assert(version.len <= version_buf.len);

                    const copy_len = version.len;
                    @memcpy(version_buf[0..copy_len], version[0..copy_len]);
                    version_buf[copy_len] = 0;

                    // Pair assertion: Verify null termination
                    assert(version_buf[copy_len] == 0);
                    return version_buf[0..copy_len];
                }
            }
            return "current";
        }

        const parent = std.fs.path.dirname(search_dir) orelse break;
        if (std.mem.eql(u8, parent, search_dir)) break;
        search_dir = parent;
    }

    return "current";
}

pub fn validateSemanticVersion(version: []const u8) bool {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    if (std.mem.eql(u8, version, "master")) return true;
    if (std.mem.eql(u8, version, "current")) return true;

    // Use std.SemanticVersion for proper validation
    _ = std.SemanticVersion.parse(version) catch return false;
    return true;
}

pub fn extractMinimumZigVersionFromJson(content: []const u8) ?[]const u8 {
    // Pair assertion: Validate input bounds
    assert(content.len > 0); // Don't process empty content
    assert(content.len <= 8192); // Reasonable upper bound for JSON

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{}) catch return null;
    defer parsed.deinit();

    // Pair assertion: Verify JSON structure
    assert(parsed.value == .object); // Ensure we have an object

    if (parsed.value.object.get("minimum_zig_version")) |version| {
        if (version == .string) {
            // Pair assertion: Validate version format
            assert(version.string.len > 0);
            assert(version.string.len < 32); // Reasonable version length
            return version.string;
        }
    }

    return null;
}

fn ensure_version_available_simple(version: []const u8) !bool {
    if (std.mem.eql(u8, version, "current")) return true;

    // Get home directory
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

    // Build version path with separate buffers
    var version_path_buf: [1024]u8 = undefined;
    const version_path = std.fmt.bufPrint(&version_path_buf, "{s}/.local/share/.zm/version/zig/{s}", .{ home, version }) catch return false;

    // Check if directory exists
    var dir = std.fs.cwd().openDir(version_path, .{}) catch return false;
    defer dir.close();

    // Check if zig executable exists with separate buffer
    var zig_path_buf: [1024]u8 = undefined;
    const zig_path = std.fmt.bufPrint(&zig_path_buf, "{s}/zig", .{version_path}) catch return false;
    dir.access(zig_path, .{}) catch return false;

    return true;
}

fn is_version_string_simple(str: []const u8) bool {
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

fn auto_install_version_simple(version: []const u8) bool {
    // Pair assertion: Validate input bounds
    assert(version.len > 0);
    assert(version.len < 64); // Reasonable version length limit

    // Use the existing auto_install_version function but handle errors gracefully
    auto_install_version(version) catch return false;
    return true;
}

fn handle_alias_fallback(program_name: []const u8, remaining_arguments: []const []const u8) !void {
    // SAFETY: All undefined fields are initialized by subsequent function calls before use
    var alias_buffers: AliasBuffers = .{
        .home = undefined,
        .zvm_home = undefined,
        .tool_path = undefined,
        .exec_arguments_ptrs = undefined,
        .exec_arguments_storage = undefined,
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

        var process = std.process.Child.init(argv_slice, std.heap.page_allocator);
        process.spawn() catch |err| {
            log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
            return err;
        };
        const term = try process.wait();
        std.process.exit(term.Exited);
    } else {
        const argv: [*:null]?[*:0]const u8 = @ptrCast(&alias_buffers.exec_arguments_ptrs[0]);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        const result = std.posix.execveZ(argv[0].?, argv, envp);
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(result) });
        return result;
    }
}

fn get_home_path(alias_buffers: *AliasBuffers) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const home = std.process.getEnvVarOwned(arena.allocator(), "USERPROFILE") catch |err| {
            switch (err) {
                error.EnvironmentVariableNotFound => {
                    log.err("USERPROFILE environment variable not set. Please set USERPROFILE to your home directory", .{});
                    return error.HomeNotFound;
                },
                else => {
                    log.err("Error reading USERPROFILE: {}", .{err});
                    return error.HomeNotFound;
                },
            }
        };

        if (home.len >= alias_buffers.home.len) {
            log.err("Home path too long for buffer", .{});
            return error.HomePathTooLong;
        }

        @memcpy(alias_buffers.home[0..home.len], home);
        return alias_buffers.home[0..home.len];
    } else {
        const home = util_tool.getenv_cross_platform("HOME") orelse {
            log.err("HOME environment variable not set. Please set HOME to your home directory", .{});
            return error.HomeNotFound;
        };

        if (home.len >= alias_buffers.home.len) {
            log.err("Home path too long for buffer", .{});
            return error.HomePathTooLong;
        }

        @memcpy(alias_buffers.home[0..home.len], home);
        return alias_buffers.home[0..home.len];
    }
}

fn get_zvm_home_path(alias_buffers: *AliasBuffers, home_slice: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        if (get_windows_env_var(arena.allocator(), "ZVM_HOME", &alias_buffers.zvm_home) catch null) |zvm_home| {
            return zvm_home;
        } else {
            var stream = std.Io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}\\.zm", .{home_slice});
            return stream.getWritten();
        }
    } else {
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            var stream = std.Io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}/.zm", .{xdg_data});
            return stream.getWritten();
        } else {
            var stream = std.Io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}/.local/share/.zm", .{home_slice});
            return stream.getWritten();
        }
    }
}

fn build_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8) ![]const u8 {
    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";

    var stream = std.Io.fixedBufferStream(&alias_buffers.tool_path);
    try stream.writer().print("{s}/current/{s}", .{ zvm_home, tool_name });
    return stream.getWritten();
}

fn build_smart_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8, version: []const u8) ![]const u8 {
    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";

    var stream = std.Io.fixedBufferStream(&alias_buffers.tool_path);
    if (util_tool.eql_str(version, "current")) {
        try stream.writer().print("{s}/current/{s}", .{ zvm_home, tool_name });
    } else {
        const tool_prefix = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";
        try stream.writer().print("{s}/version/{s}/{s}/{s}", .{ zvm_home, tool_prefix, version, tool_name });
    }
    return stream.getWritten();
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
    }
}
