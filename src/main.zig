const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const context = @import("context.zig");
const limits = @import("limits.zig");
const static_memory = @import("static_memory.zig");
const util_data = @import("util/data.zig");
const util_output = @import("util/output.zig");
const alias = @import("alias.zig");
const options = @import("options");
const object_pools = @import("object_pools.zig");
const validation = @import("validation.zig");

// Command handlers.
const install = @import("install.zig");
const remove = @import("remove.zig");
const util_tool = @import("util/tool.zig");
const meta = @import("meta.zig");
const config = @import("config.zig");
const util_color = @import("util/color.zig");
const http_client = @import("http_client.zig");

// Modular commands.
const commands = struct {
    pub const help = @import("commands/help.zig");
    pub const version = @import("commands/version.zig");
    pub const list = @import("commands/list.zig");
    pub const list_remote = @import("commands/list_remote.zig");
    pub const list_mirrors = @import("commands/list_mirrors.zig");
    pub const current = @import("commands/current.zig");
    pub const install = @import("commands/install.zig");
    pub const remove = @import("commands/remove.zig");
    pub const use = @import("commands/use.zig");
    pub const clean = @import("commands/clean.zig");
    pub const env = @import("commands/env.zig");
    pub const completions = @import("commands/completions.zig");
};

// Cleaner access to limits
const io_buffer_size = limits.limits.io_buffer_size_maximum;

/// Global static memory buffer.
var global_static_buffer: [static_memory.StaticMemory.calculate_memory_size()]u8 = undefined;

/// Global context storage.
// SAFETY: global_context is initialized in main() before any usage
var global_context: context.CliContext = undefined;

/// Alias handling buffers - allocated on stack to ensure thread safety
/// Each invocation gets its own buffers, avoiding any race conditions.
const AliasBuffers = struct {
    home: [limits.limits.home_dir_length_maximum]u8,
    zvm_home: [limits.limits.home_dir_length_maximum]u8,
    tool_path: [limits.limits.path_length_maximum]u8,
    exec_arguments_ptrs: [limits.limits.arguments_maximum + 1]?[*:0]const u8,
    exec_arguments_storage: [limits.limits.arguments_storage_size_maximum]u8,
    exec_arguments_count: u32 = 0,
};

/// Helper to check if environment variable exists on Windows (Zig 0.15.1 compatible)
fn has_windows_env_var(var_name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = std.process.getEnvVarOwned(arena.allocator(), var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false, // Assume not found on any error
    };

    return result.len > 0;
}

/// Helper to get environment variable on Windows (Zig 0.15.1 compatible)
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
    // Collect command line arguments into a fixed buffer.
    var arguments_buffer: [limits.limits.arguments_maximum][]const u8 = undefined;
    var arguments_count: u32 = 0;

    std.debug.assert(arguments_buffer.len > 0);
    std.debug.assert(arguments_buffer.len == limits.limits.arguments_maximum);

    {
        var arguments_iterator = try std.process.argsWithAllocator(std.heap.page_allocator);
        defer arguments_iterator.deinit();

        while (arguments_iterator.next()) |argument| : (arguments_count += 1) {
            // Bounds check
            std.debug.assert(arguments_count <= arguments_buffer.len);
            if (arguments_count >= arguments_buffer.len) {
                std.log.err("Too many arguments: got {d}, maximum is {d}", .{
                    arguments_count + 1,
                    arguments_buffer.len,
                });
                return error.TooManyArguments;
            }

            // Validate argument
            std.debug.assert(argument.len > 0);
            arguments_buffer[arguments_count] = argument;

            std.debug.assert(arguments_buffer[arguments_count].ptr == argument.ptr);
            std.debug.assert(arguments_buffer[arguments_count].len == argument.len);
        }
    }

    // Validate arguments_count
    std.debug.assert(arguments_count <= arguments_buffer.len);

    const arguments = arguments_buffer[0..arguments_count];
    std.debug.assert(arguments.len == arguments_count);
    if (arguments.len == 0) {
        std.log.err("No arguments provided to zvm", .{});
        return error.NoArguments;
    }

    std.debug.assert(arguments.len > 0);

    const program_name = arguments[0];
    std.debug.assert(program_name.len > 0);

    const basename = std.fs.path.basename(program_name);
    std.debug.assert(basename.len > 0);
    std.debug.assert(basename.len <= program_name.len);

    // Initialize config (read environment variables, etc.)
    config.init_config();

    // Handle aliases before parsing commands.
    const is_alias = util_tool.eql_str(basename, "zig") or util_tool.eql_str(basename, "zls");
    if (is_alias) {
        try handle_alias(basename, arguments[1..]);
        unreachable; // handle_alias calls execve which never returns on success
    }

    // Initialize output emitter with defaults first so validation can use it
    const default_output_config = util_output.OutputConfig{
        .mode = .human_readable,
        .color = .always_use_color,
    };
    _ = try util_output.init_global(default_output_config);

    const parsed_command_line = cli.parse_command_line(arguments) catch |err| {
        util_output.fatal(util_output.ExitCode.from_error(err), "Failed to parse command line: {s}", .{@errorName(err)});
    };

    // Update output configuration with parsed values
    const final_output_config = util_output.OutputConfig{
        .mode = parsed_command_line.global_config.output_mode,
        .color = parsed_command_line.global_config.color_mode,
    };
    _ = try util_output.update_global(final_output_config);

    // Initialize our static memory context.
    std.debug.assert(global_static_buffer.len == static_memory.StaticMemory.calculate_memory_size());
    std.debug.assert(arguments.len > 0);

    const context_instance = try context.CliContext.init(
        &global_context,
        &global_static_buffer,
        arguments,
    );

    std.debug.assert(context_instance == &global_context);

    // Initialize progress reporting for long operations.
    const root_node = std.Progress.start(.{
        .root_name = "zvm",
        .estimated_total_items = get_progress_item_count(parsed_command_line.command),
    });

    // Execute the command.
    try execute_command(context_instance, parsed_command_line.command, root_node);

    // If ZVM_DEBUG environment variable is set, print resource usage
    const has_debug = if (builtin.os.tag == .windows) blk: {
        break :blk has_windows_env_var("ZVM_DEBUG");
    } else blk: {
        break :blk util_tool.getenv_cross_platform("ZVM_DEBUG") != null;
    };

    if (has_debug) {
        try context_instance.print_debug_info();
    }
}

fn handle_alias(program_name: []const u8, remaining_arguments: [][]const u8) !void {
    std.debug.assert(program_name.len > 0);
    std.debug.assert(remaining_arguments.len < limits.limits.arguments_maximum);
    std.debug.assert(util_tool.eql_str(program_name, "zig") or util_tool.eql_str(program_name, "zls"));

    // Use local alias buffers to avoid any potential thread safety issues
    // SAFETY: alias_buffers fields are populated before use by get_home_path and subsequent functions
    var alias_buffers: AliasBuffers = .{
        .home = undefined,
        .zvm_home = undefined,
        .tool_path = undefined,
        .exec_arguments_ptrs = undefined,
        .exec_arguments_storage = undefined,
        .exec_arguments_count = 0,
    };

    // Get home directory path
    const home_slice = try get_home_path(&alias_buffers);

    // Get ZVM home directory path
    const zvm_home = try get_zvm_home_path(&alias_buffers, home_slice);

    // Build tool executable path
    const tool_path = try build_tool_path(&alias_buffers, program_name, zvm_home);

    // Build execution arguments
    try build_exec_arguments(&alias_buffers, tool_path, remaining_arguments);

    // Platform-specific execution
    if (builtin.os.tag == .windows) {
        // On Windows, we need to spawn a new process
        // Convert the null-terminated array to a slice
        var argv_list: [limits.limits.arguments_maximum][]const u8 = undefined;
        var i: usize = 0;
        while (alias_buffers.exec_arguments_ptrs[i]) |arg| : (i += 1) {
            argv_list[i] = std.mem.sliceTo(arg, 0);
        }
        const argv_slice = argv_list[0..i];

        var process = std.process.Child.init(argv_slice, std.heap.page_allocator);
        process.spawn() catch |err| {
            std.log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
            return err;
        };
        const term = try process.wait();
        std.process.exit(term.Exited);
    } else {
        // Use the allocation-free execve from std.posix
        // This uses null-terminated strings directly, no allocation needed
        const argv: [*:null]?[*:0]const u8 = @ptrCast(&alias_buffers.exec_arguments_ptrs[0]);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        // This function never returns on success
        const result = std.posix.execveZ(argv[0].?, argv, envp);

        // If we get here, exec failed
        std.log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(result) });
        return result;
    }
}

/// Get the HOME environment variable and copy it to the static buffer
fn get_home_path(alias_buffers: *AliasBuffers) ![]const u8 {
    if (builtin.os.tag == .windows) {
        // On Windows, use std.process.getEnvVarOwned for proper environment variable access
        // This handles UTF-16/UTF-8 conversion internally
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const home = std.process.getEnvVarOwned(arena.allocator(), "USERPROFILE") catch |err| {
            switch (err) {
                error.EnvironmentVariableNotFound => {
                    std.log.err("USERPROFILE environment variable not set. Please set USERPROFILE to your home directory", .{});
                    return error.HomeNotFound;
                },
                else => {
                    std.log.err("Error reading USERPROFILE: {}", .{err});
                    return error.HomeNotFound;
                },
            }
        };

        if (home.len >= alias_buffers.home.len) {
            std.log.err("Home path too long for buffer", .{});
            return error.HomePathTooLong;
        }

        @memcpy(alias_buffers.home[0..home.len], home);
        return alias_buffers.home[0..home.len];
    } else {
        // Unix-like systems
        const home = util_tool.getenv_cross_platform("HOME") orelse {
            std.log.err("HOME environment variable not set. Please set HOME to your home directory", .{});
            return error.HomeNotFound;
        };

        if (home.len >= alias_buffers.home.len) {
            std.log.err("Home path too long for buffer", .{});
            return error.HomePathTooLong;
        }

        @memcpy(alias_buffers.home[0..home.len], home);
        return alias_buffers.home[0..home.len];
    }
}

/// Get the ZVM_HOME path, either from environment or default
fn get_zvm_home_path(alias_buffers: *AliasBuffers, home_slice: []const u8) ![]const u8 {
    std.debug.assert(home_slice.len > 0);
    std.debug.assert(home_slice.len <= alias_buffers.home.len);

    if (builtin.os.tag == .windows) {
        // On Windows, check for ZVM_HOME environment variable
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        if (get_windows_env_var(arena.allocator(), "ZVM_HOME", &alias_buffers.zvm_home) catch null) |zvm_home| {
            return zvm_home;
        } else {
            // No ZVM_HOME or error, use default
            var fixed_buffer_stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try fixed_buffer_stream.writer().print("{s}\\.zm", .{home_slice});
            return fixed_buffer_stream.getWritten();
        }
    } else {
        // On POSIX (Linux/macOS), follow XDG Base Directory specification
        // Priority order: XDG_DATA_HOME/.zm -> HOME/.local/share/.zm
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            // Use XDG_DATA_HOME/.zm if XDG_DATA_HOME is set
            var fixed_buffer_stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try fixed_buffer_stream.writer().print("{s}/.zm", .{xdg_data});
            return fixed_buffer_stream.getWritten();
        } else {
            // Use XDG default: $HOME/.local/share/.zm
            var fixed_buffer_stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try fixed_buffer_stream.writer().print("{s}/.local/share/.zm", .{home_slice});
            return fixed_buffer_stream.getWritten();
        }
    }
}

/// Build the tool executable path
fn build_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8) ![]const u8 {
    std.debug.assert(program_name.len > 0);
    std.debug.assert(zvm_home.len > 0);
    std.debug.assert(zvm_home.len <= alias_buffers.zvm_home.len);

    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";
    // Validate tool name
    std.debug.assert(std.mem.eql(u8, tool_name, "zig") or std.mem.eql(u8, tool_name, "zls"));

    var tool_path_fixed_buffer_stream = std.io.fixedBufferStream(&alias_buffers.tool_path);
    try tool_path_fixed_buffer_stream.writer().print("{s}/current/{s}", .{ zvm_home, tool_name });
    const tool_path = tool_path_fixed_buffer_stream.getWritten();

    std.debug.assert(tool_path.len > 0);
    std.debug.assert(tool_path.len <= alias_buffers.tool_path.len);

    return tool_path;
}

/// Build the execution arguments array
fn build_exec_arguments(alias_buffers: *AliasBuffers, tool_path: []const u8, remaining_arguments: [][]const u8) !void {
    std.debug.assert(tool_path.len > 0);
    std.debug.assert(tool_path.len <= alias_buffers.tool_path.len);
    std.debug.assert(remaining_arguments.len < limits.limits.arguments_maximum);

    var exec_arguments_count: u32 = 0;
    var storage_offset: u32 = 0;

    // First argument is the tool path.
    if (tool_path.len > alias_buffers.exec_arguments_storage.len) {
        std.log.err("Tool path too long: got {d} bytes, maximum is {d} bytes. Path: '{s}'", .{
            tool_path.len,
            alias_buffers.exec_arguments_storage.len,
            tool_path,
        });
        return error.ToolPathTooLong;
    }
    @memcpy(alias_buffers.exec_arguments_storage[0..tool_path.len], tool_path);
    alias_buffers.exec_arguments_storage[tool_path.len] = 0; // Null terminate
    alias_buffers.exec_arguments_ptrs[0] = @ptrCast(&alias_buffers.exec_arguments_storage[0]);
    exec_arguments_count = 1;
    storage_offset = @intCast(tool_path.len + 1); // +1 for null terminator

    // Copy remaining args.
    for (remaining_arguments) |argument| {
        std.debug.assert(argument.len > 0);
        std.debug.assert(exec_arguments_count < alias_buffers.exec_arguments_ptrs.len);
        std.debug.assert(storage_offset <= alias_buffers.exec_arguments_storage.len);

        if (exec_arguments_count >= alias_buffers.exec_arguments_ptrs.len) {
            std.log.err("Too many exec arguments: got {d}, maximum is {d}", .{
                exec_arguments_count + 1,
                alias_buffers.exec_arguments_ptrs.len,
            });
            return error.TooManyExecArgs;
        }
        if (storage_offset + argument.len + 1 > alias_buffers.exec_arguments_storage.len) { // +1 for null terminator
            std.log.err("Exec args storage full: need {d} more bytes, only {d} bytes available", .{
                argument.len + 1,
                alias_buffers.exec_arguments_storage.len - storage_offset,
            });
            return error.ExecArgsStorageFull;
        }

        const old_storage_offset = storage_offset;
        @memcpy(alias_buffers.exec_arguments_storage[storage_offset .. storage_offset + argument.len], argument);
        alias_buffers.exec_arguments_storage[storage_offset + argument.len] = 0; // Null terminate
        alias_buffers.exec_arguments_ptrs[exec_arguments_count] = @ptrCast(&alias_buffers.exec_arguments_storage[storage_offset]);
        storage_offset += @intCast(argument.len + 1); // +1 for null terminator
        exec_arguments_count += 1;

        std.debug.assert(storage_offset == old_storage_offset + argument.len + 1);
    }

    // Null terminate the array of pointers
    alias_buffers.exec_arguments_ptrs[exec_arguments_count] = null;
    alias_buffers.exec_arguments_count = exec_arguments_count;
}

fn get_progress_item_count(command: validation.ValidatedCommand) u16 {
    return switch (command) {
        .install => 5, // Download, verify, extract, symlink, cleanup
        .remove => 2, // Remove files, update symlinks
        .list => 1, // Read directory
        .use => 2, // Validate version, update symlinks
        .list_remote => 3, // Fetch metadata, parse, format
        .list_mirrors => 0, // No progress needed
        .help => 0, // No progress needed
        .version => 0, // No progress needed
        .clean => |opts| if (opts.remove_all) 10 else 5, // Variable based on scope
        .current => 1, // Read version files
        .env => 1, // Generate environment setup
        .completions => 1, // Generate completion script
    };
}

fn execute_command(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand,
    progress_node: std.Progress.Node,
) !void {
    switch (command) {
        .help => |opts| try commands.help.execute(ctx, opts, progress_node),
        .version => |opts| try commands.version.execute(ctx, opts, progress_node),
        .list => |opts| try commands.list.execute(ctx, opts, progress_node),
        .list_remote => |opts| try commands.list_remote.execute(ctx, opts, progress_node),
        .list_mirrors => |opts| try commands.list_mirrors.execute(ctx, opts, progress_node),
        .current => |opts| try commands.current.execute(ctx, opts, progress_node),
        .install => |opts| try commands.install.execute(ctx, opts, progress_node),
        .remove => |opts| try commands.remove.execute(ctx, opts, progress_node),
        .use => |opts| try commands.use.execute(ctx, opts, progress_node),
        .clean => |opts| try commands.clean.execute(ctx, opts, progress_node),
        .env => |opts| try commands.env.execute(ctx, opts, progress_node),
        .completions => |opts| try commands.completions.execute(ctx, opts, progress_node),
    }
}

comptime {
    // Compile-time assertions to validate our memory usage.
    const total_memory = static_memory.StaticMemory.calculate_memory_size();

    std.debug.assert(total_memory > 0);
    std.debug.assert(total_memory <= 100 * 1024 * 1024); // Max 100MB.

    // Assert relationships between compile-time constants
    std.debug.assert(limits.limits.arguments_maximum > 0);
    std.debug.assert(limits.limits.arguments_maximum <= 1000); // Reasonable upper bound
    std.debug.assert(limits.limits.home_dir_length_maximum >= 256); // Minimum path length
    std.debug.assert(limits.limits.path_length_maximum >= limits.limits.home_dir_length_maximum);

    // Memory requirement is validated at compile time.
    // Total requirement: 2MB (total_memory / (1024 * 1024)).
}
