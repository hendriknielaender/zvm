const std = @import("std");
const builtin = @import("builtin");
const parser = @import("cli/parser.zig");
const Context = @import("Context.zig");
const memory_limits = @import("memory/limits.zig");
const memory_static = @import("memory/static_memory.zig");
const util_output = @import("util/output.zig");
const util_tool = @import("util/tool.zig");
const Config = @import("Config.zig");
const metadata = @import("metadata.zig");
const platform_exec = @import("platform/exec.zig");
const platform_paths = @import("platform/paths.zig");
const platform_env = @import("platform/env.zig");

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

var global_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 = undefined;
var global_context: Context.CliContext = undefined;
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
                std.log.err("Too many arguments: got {d}, maximum is {d}", .{
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
        std.log.err("No arguments provided to zvm", .{});
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

fn handle_alias(program_name: []const u8, remaining_arguments: []const []const u8) !void {
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
            std.log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
            return err;
        };
        const term = try process.wait();
        std.process.exit(term.Exited);
    } else {
        const argv: [*:null]?[*:0]const u8 = @ptrCast(&alias_buffers.exec_arguments_ptrs[0]);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        const result = std.posix.execveZ(argv[0].?, argv, envp);
        std.log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(result) });
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

fn get_zvm_home_path(alias_buffers: *AliasBuffers, home_slice: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        if (get_windows_env_var(arena.allocator(), "ZVM_HOME", &alias_buffers.zvm_home) catch null) |zvm_home| {
            return zvm_home;
        } else {
            var stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}\\.zm", .{home_slice});
            return stream.getWritten();
        }
    } else {
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            var stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}/.zm", .{xdg_data});
            return stream.getWritten();
        } else {
            var stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
            try stream.writer().print("{s}/.local/share/.zm", .{home_slice});
            return stream.getWritten();
        }
    }
}

fn build_tool_path(alias_buffers: *AliasBuffers, program_name: []const u8, zvm_home: []const u8) ![]const u8 {
    const tool_name = if (util_tool.eql_str(program_name, "zig")) "zig" else "zls";

    var stream = std.io.fixedBufferStream(&alias_buffers.tool_path);
    try stream.writer().print("{s}/current/{s}", .{ zvm_home, tool_name });
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
