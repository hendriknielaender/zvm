const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const context = @import("context.zig");
const limits = @import("limits.zig");
const static_memory = @import("static_memory.zig");
const util_data = @import("util/data.zig");
const alias = @import("alias.zig");
const options = @import("options");
const object_pools = @import("object_pools.zig");

// Command handlers.
const install = @import("install.zig");
const remove = @import("remove.zig");
const util_tool = @import("util/tool.zig");
const meta = @import("meta.zig");
const config = @import("config.zig");
const util_color = @import("util/color.zig");
const http_client = @import("http_client.zig");

/// Global static memory buffer.
var global_static_buffer: [static_memory.StaticMemory.calculate_memory_size()]u8 = undefined;

/// Global context storage.
var global_context: context.CliContext = undefined;

/// Alias handling buffers - allocated on stack to ensure thread safety
/// Each invocation gets its own buffers, avoiding any race conditions.
const AliasBuffers = struct {
    home: [limits.limits.home_dir_length_maximum]u8 = undefined,
    zvm_home: [limits.limits.home_dir_length_maximum]u8 = undefined,
    tool_path: [limits.limits.path_length_maximum]u8 = undefined,
    exec_arguments_ptrs: [limits.limits.arguments_maximum + 1]?[*:0]const u8 = undefined,
    exec_arguments_storage: [limits.limits.arguments_storage_size_maximum]u8 = undefined,
    exec_arguments_count: u32 = 0,
};

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

    // Handle aliases before parsing commands.
    const is_alias = util_tool.eql_str(basename, "zig") or util_tool.eql_str(basename, "zls");
    if (is_alias) {
        try handle_alias(basename, arguments[1..]);
        unreachable; // handle_alias calls execve which never returns on success
    }

    // Parse command line arguments.
    const command = cli.parse_args_static(arguments);

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
        .estimated_total_items = get_progress_item_count(command),
    });

    // Execute the command.
    try execute_command(context_instance, command, root_node);

    // If ZVM_DEBUG environment variable is set, print resource usage
    if (std.posix.getenv("ZVM_DEBUG")) |_| {
        try context_instance.print_debug_info();
    }
}

fn handle_alias(program_name: []const u8, remaining_arguments: [][]const u8) !void {
    std.debug.assert(program_name.len > 0);
    std.debug.assert(remaining_arguments.len < limits.limits.arguments_maximum);
    std.debug.assert(util_tool.eql_str(program_name, "zig") or util_tool.eql_str(program_name, "zls"));

    // Use local alias buffers to avoid any potential thread safety issues
    var alias_buffers: AliasBuffers = undefined;

    // Get home directory path
    const home_slice = try get_home_path(&alias_buffers);

    // Get ZVM home directory path
    const zvm_home = try get_zvm_home_path(&alias_buffers, home_slice);

    // Build tool executable path
    const tool_path = try build_tool_path(&alias_buffers, program_name, zvm_home);

    // Build execution arguments
    try build_exec_arguments(&alias_buffers, tool_path, remaining_arguments);

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

/// Get the HOME environment variable and copy it to the static buffer
fn get_home_path(alias_buffers: *AliasBuffers) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set. Please set HOME to your home directory", .{});
        return error.HomeNotFound;
    };
    // Validate home path
    std.debug.assert(home.len > 0);
    if (home.len > alias_buffers.home.len) {
        std.log.err("Home path too long: got {d} bytes, maximum is {d} bytes. Path: '{s}'", .{
            home.len,
            alias_buffers.home.len,
            home,
        });
        return error.HomePathTooLong;
    }

    @memcpy(alias_buffers.home[0..home.len], home);
    const home_slice = alias_buffers.home[0..home.len];

    std.debug.assert(home_slice.len == home.len);
    std.debug.assert(std.mem.eql(u8, home_slice, home));

    return home_slice;
}

/// Get the ZVM_HOME path, either from environment or default
fn get_zvm_home_path(alias_buffers: *AliasBuffers, home_slice: []const u8) ![]const u8 {
    std.debug.assert(home_slice.len > 0);
    std.debug.assert(home_slice.len <= alias_buffers.home.len);

    if (std.posix.getenv("ZVM_HOME")) |zh| {
        if (zh.len > alias_buffers.zvm_home.len) {
            std.log.err("ZVM_HOME path too long: got {d} bytes, maximum is {d} bytes. Path: '{s}'", .{
                zh.len,
                alias_buffers.zvm_home.len,
                zh,
            });
            return error.ZvmHomePathTooLong;
        }
        @memcpy(alias_buffers.zvm_home[0..zh.len], zh);
        return alias_buffers.zvm_home[0..zh.len];
    } else {
        // Build default path: $HOME/.zm
        var fixed_buffer_stream = std.io.fixedBufferStream(&alias_buffers.zvm_home);
        try fixed_buffer_stream.writer().print("{s}/.zm", .{home_slice});
        return fixed_buffer_stream.getWritten();
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

fn get_progress_item_count(command: cli.Command) u16 {
    // This function has no preconditions as it accepts any valid Command
    return switch (command) {
        .install => 5,
        .remove => 2,
        .list => 1,
        .use => 2,
        .@"list-remote" => 3,
        .help => 0,
        .version => 0,
        .clean => |opts| if (opts.all) 10 else 5,
        .current => 1,
        .env => 1,
        .completions => 1,
    };
}

fn execute_command(
    ctx: *context.CliContext,
    command: cli.Command,
    progress_node: std.Progress.Node,
) !void {
    // ctx is a pointer, not optional - no need for null check
    // We trust that ctx is the current instance

    switch (command) {
        .help => try print_help(),
        .version => try print_version(),
        .list => try list_installed_versions(ctx),
        .@"list-remote" => |opts| try list_remote_versions(ctx, opts.zls),
        .current => try show_current_version(ctx),
        .env => |opts| try print_env_setup(ctx, opts.shell),
        .clean => |opts| try clean_unused_versions(ctx, opts.all),
        .install => |opts| try install.install(ctx, opts.version, opts.zls, progress_node, false),
        .remove => |opts| try remove.remove(ctx, opts.version, opts.zls, false),
        .use => |opts| try alias.set_version(ctx, opts.version, opts.zls),
        .completions => |opts| try print_completions(ctx, opts.shell),
    }
}

fn print_help() !void {
    const stdout = std.io.getStdOut().writer();
    // No input parameters to validate, but ensure stdout is valid
    std.debug.assert(std.io.getStdOut().handle != 0);
    try stdout.print(
        \\ZVM - Zig Version Manager
        \\
        \\USAGE:
        \\  zvm <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\  install <version>    Install a specific Zig version
        \\  remove <version>     Remove an installed Zig version
        \\  use <version>        Switch to a specific Zig version
        \\  list                 List installed Zig versions
        \\  list-remote          List available Zig versions
        \\  current              Show current Zig version
        \\  clean                Remove unused Zig versions
        \\  env                  Print shell setup
        \\  help                 Show this help message
        \\  version              Show ZVM version
        \\
        \\OPTIONS:
        \\  --zls                For install/remove/use commands, manage ZLS instead
        \\  --all                For clean command, remove all versions
        \\  --shell <shell>      For env command, specify shell type
        \\
    , .{});
}

fn print_version() !void {
    const stdout = std.io.getStdOut().writer();
    // Ensure stdout is valid
    std.debug.assert(std.io.getStdOut().handle != 0);

    // Print the logo
    try stdout.print("{s}\n", .{util_data.zvm_logo});
    try stdout.print("zvm {s}\n", .{options.version});
}

fn list_installed_versions(ctx: *context.CliContext) !void {
    // Initialize color
    var color = util_color.Color.RuntimeStyle.init();

    // Get path buffer for zig versions directory
    var zig_versions_buffer = try ctx.acquire_path_buffer();
    defer zig_versions_buffer.reset();

    // Get the zig versions directory path
    const zig_versions_path = try util_data.get_zvm_zig_version(zig_versions_buffer);

    // Open the zig versions directory
    var zig_dir = std.fs.openDirAbsolute(zig_versions_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try color.bold().red().print("No Zig versions installed.\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer zig_dir.close();

    var found_any = false;
    var iterator = zig_dir.iterate();

    // Print header
    try color.bold().white().print("Installed Zig versions:\n", .{});

    // List all directories
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Skip hidden directories
        if (entry.name[0] == '.') continue;

        found_any = true;
        try color.green().print("  {s}\n", .{entry.name});
    }

    if (!found_any) {
        try color.bold().red().print("No Zig versions installed.\n", .{});
    }
}

fn list_remote_versions(ctx: *context.CliContext, is_zls: bool) !void {
    // Initialize color
    var color = util_color.Color.RuntimeStyle.init();

    // Fetch metadata
    const meta_url = if (is_zls) config.zls_url else config.zig_url;

    const res = try http_client.HttpClient.fetch(ctx, meta_url, .{});

    // Get version entries from pool
    var version_entries_ptrs: [limits.limits.versions_maximum]*object_pools.VersionEntry = undefined;
    for (&version_entries_ptrs) |*entry| {
        entry.* = try ctx.acquire_version_entry();
    }
    defer {
        for (version_entries_ptrs) |entry| {
            entry.reset();
        }
    }

    // Create a slice of the actual structs for get_version_list
    var version_entries: [limits.limits.versions_maximum]object_pools.VersionEntry = undefined;
    for (version_entries_ptrs, 0..) |ptr, i| {
        version_entries[i] = ptr.*;
    }

    // Parse metadata and get version list
    const versions = if (is_zls) blk: {
        var zls_meta = try meta.Zls.init(res, ctx.get_json_allocator());
        defer zls_meta.deinit();
        break :blk try zls_meta.get_version_list(&version_entries);
    } else blk: {
        var zig_meta = try meta.Zig.init(res, ctx.get_json_allocator());
        defer zig_meta.deinit();
        break :blk try zig_meta.get_version_list(&version_entries);
    };

    // Print header
    if (is_zls) {
        try color.bold().white().print("Available ZLS versions:\n", .{});
    } else {
        try color.bold().white().print("Available Zig versions:\n", .{});
    }

    // Print versions
    for (versions) |version| {
        try color.green().print("  {s}\n", .{version});
    }
}

fn show_current_version(ctx: *context.CliContext) !void {
    const stdout = std.io.getStdOut().writer();
    // Ensure stdout is valid
    std.debug.assert(std.io.getStdOut().handle != 0);

    // Get path buffers from pool
    var zig_version_buffer = try ctx.acquire_path_buffer();
    defer zig_version_buffer.reset();

    var zls_version_buffer = try ctx.acquire_path_buffer();
    defer zls_version_buffer.reset();

    // Get version file paths
    const zig_version_path = try util_data.get_zvm_zig_version(zig_version_buffer);
    const zls_version_path = try util_data.get_zvm_zls_version(zls_version_buffer);

    // Read versions using static buffers
    var zig_entry = try ctx.acquire_version_entry();
    defer zig_entry.reset();

    var zls_entry = try ctx.acquire_version_entry();
    defer zls_entry.reset();

    // Read Zig version
    const zig_file = std.fs.openFileAbsolute(zig_version_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const zig_version = if (zig_file) |f| blk: {
        defer f.close();
        const bytes_read = try f.read(zig_entry.name_buffer[0..]);
        zig_entry.name_length = @intCast(bytes_read);
        break :blk zig_entry.get_name();
    } else null;

    // Read ZLS version
    const zls_file = std.fs.openFileAbsolute(zls_version_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const zls_version = if (zls_file) |f| blk: {
        defer f.close();
        const bytes_read = try f.read(zls_entry.name_buffer[0..]);
        zls_entry.name_length = @intCast(bytes_read);
        break :blk zls_entry.get_name();
    } else null;

    // Print current versions
    if (zig_version) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\n\r");
        try stdout.print("Zig version: {s}\n", .{trimmed});
    } else {
        try stdout.print("Zig version: not set\n", .{});
    }

    if (zls_version) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\n\r");
        try stdout.print("ZLS version: {s}\n", .{trimmed});
    } else {
        try stdout.print("ZLS version: not set\n", .{});
    }
}

fn print_env_setup(ctx: *context.CliContext, shell: ?[]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    // Ensure stdout is valid
    std.debug.assert(std.io.getStdOut().handle != 0);

    // Get path buffer from pool
    var path_buffer = try ctx.acquire_path_buffer();
    defer path_buffer.reset();

    // Get ZVM bin path
    var fbs = std.io.fixedBufferStream(path_buffer.slice());
    try fbs.writer().print("{s}/.zm/bin", .{ctx.get_home_dir()});
    const zvm_bin_path = try path_buffer.set(fbs.getWritten());

    // Determine shell type
    const shell_type = if (shell) |s| s else blk: {
        if (std.posix.getenv("SHELL")) |shell_path| {
            const shell_name = std.fs.path.basename(shell_path);
            break :blk shell_name;
        }
        break :blk "bash"; // Default to bash
    };

    // Print environment setup based on shell
    if (std.mem.indexOf(u8, shell_type, "fish") != null) {
        // Fish shell
        try stdout.print("# Add this to your ~/.config/fish/config.fish:\n", .{});
        try stdout.print("set -gx PATH {s} $PATH\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "zsh") != null) {
        // Zsh shell
        try stdout.print("# Add this to your ~/.zshrc:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "bash") != null) {
        // Bash shell
        try stdout.print("# Add this to your ~/.bashrc:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "sh") != null) {
        // POSIX shell
        try stdout.print("# Add this to your shell configuration:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "powershell") != null or
        std.mem.indexOf(u8, shell_type, "pwsh") != null)
    {
        // PowerShell
        try stdout.print("# Add this to your PowerShell profile:\n", .{});
        try stdout.print("$env:Path = \"{s};$env:Path\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "cmd") != null) {
        // Windows CMD
        try stdout.print("REM Add this to your environment variables:\n", .{});
        try stdout.print("SET PATH={s};%PATH%\n", .{zvm_bin_path});
    } else {
        // Unknown shell, default to POSIX
        try stdout.print("# Add this to your shell configuration:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    }
}

fn clean_unused_versions(ctx: *context.CliContext, all: bool) !void {
    // Initialize color
    var color = util_color.Color.RuntimeStyle.init();

    // Get path buffer from pool
    var store_buffer = try ctx.acquire_path_buffer();
    defer store_buffer.reset();

    // Path to the store directory
    const store_path = try util_data.get_zvm_store(store_buffer);

    const fs = std.fs.cwd();
    var store_dir = fs.openDir(store_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer store_dir.close();

    var iterator = store_dir.iterate();
    var files_removed: usize = 0;
    var bytes_freed: u64 = 0;

    while (try iterator.next()) |entry| {
        // Skip directories (which are installed versions)
        if (entry.kind == .directory) continue;

        // Only clean files (download artifacts)
        if (entry.kind == .file) {
            // Get file size before deletion
            const file = try store_dir.openFile(entry.name, .{});
            const file_info = try file.stat();
            const file_size = file_info.size;
            file.close();

            // Delete the file
            try store_dir.deleteFile(entry.name);

            files_removed += 1;
            bytes_freed += file_size;
        }
    }

    if (files_removed > 0) {
        const mb_freed = @as(f64, @floatFromInt(bytes_freed)) / (1024.0 * 1024.0);
        try color.bold().green().print(
            "Cleaned up {d} old download artifact(s), freed {d:.2} MB.\n",
            .{ files_removed, mb_freed },
        );
    } else {
        try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
    }

    // If all flag is set, also remove unused versions
    if (all) {
        // Get current versions
        var current_zig_buffer = try ctx.acquire_path_buffer();
        defer current_zig_buffer.reset();

        var current_zls_buffer = try ctx.acquire_path_buffer();
        defer current_zls_buffer.reset();

        const current_zig_path = try util_data.get_zvm_zig_version(current_zig_buffer);
        const current_zls_path = try util_data.get_zvm_zls_version(current_zls_buffer);

        // Read current versions using static buffers
        var zig_version_entry = try ctx.acquire_version_entry();
        defer zig_version_entry.reset();

        var zls_version_entry = try ctx.acquire_version_entry();
        defer zls_version_entry.reset();

        const zig_file = std.fs.openFileAbsolute(current_zig_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const current_zig_version = if (zig_file) |f| blk: {
            defer f.close();
            const bytes_read = try f.read(zig_version_entry.name_buffer[0..]);
            zig_version_entry.name_length = @intCast(bytes_read);
            break :blk zig_version_entry.get_name();
        } else null;

        const zls_file = std.fs.openFileAbsolute(current_zls_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const current_zls_version = if (zls_file) |f| blk: {
            defer f.close();
            const bytes_read = try f.read(zls_version_entry.name_buffer[0..]);
            zls_version_entry.name_length = @intCast(bytes_read);
            break :blk zls_version_entry.get_name();
        } else null;

        const trimmed_zig_current = if (current_zig_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;
        const trimmed_zls_current = if (current_zls_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;

        // Reset iterator to go through directories
        iterator = store_dir.iterate();
        var versions_removed: usize = 0;

        try color.bold().yellow().print("\nCleaning unused versions...\n", .{});

        while (try iterator.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Skip current versions
            const is_current_zig = if (trimmed_zig_current) |czv| std.mem.eql(u8, entry.name, czv) else false;
            const is_current_zls = if (trimmed_zls_current) |czv| std.mem.eql(u8, entry.name, czv) else false;

            if (is_current_zig or is_current_zls) {
                const marker = if (is_current_zig and is_current_zls) "zig,zls" else if (is_current_zig) "zig" else "zls";
                try color.cyan().print("  Keeping {s} (current {s})\n", .{ entry.name, marker });
                continue;
            }

            // Remove the version directory
            try color.red().print("  Removing {s}\n", .{entry.name});
            try store_dir.deleteTree(entry.name);
            versions_removed += 1;
        }

        if (versions_removed > 0) {
            try color.bold().green().print("\nRemoved {d} unused version(s).\n", .{versions_removed});
        } else {
            try color.bold().cyan().print("\nNo unused versions found.\n", .{});
        }
    }
}

fn print_completions(ctx: *context.CliContext, shell: cli.Shell) !void {
    _ = ctx; // Not needed for completions

    switch (shell) {
        .zsh => try print_zsh_completions(),
        .bash => try print_bash_completions(),
        .fish => {
            std.log.err("Fish shell completions not yet implemented", .{});
            return error.NotImplemented;
        },
        .powershell => {
            std.log.err("PowerShell completions not yet implemented", .{});
            return error.NotImplemented;
        },
    }
}

fn print_zsh_completions() !void {
    const zsh_script =
        \\#compdef zvm
        \\
        \\# ZVM top-level commands
        \\local -a _zvm_commands
        \\_zvm_commands=(
        \\  'list:List installed Zig versions'
        \\  'list-remote:List available Zig/ZLS versions for download'
        \\  'install:Install a version of Zig or ZLS'
        \\  'use:Switch to a specific Zig or ZLS version'
        \\  'remove:Remove an installed Zig or ZLS version'
        \\  'current:Show current Zig and ZLS versions'
        \\  'env:Show environment setup instructions'
        \\  'clean:Clean up old download artifacts'
        \\  'completions:Generate shell completion script'
        \\  'version:Show zvm version'
        \\  'help:Show help message'
        \\)
        \\
        \\_arguments \
        \\  '1: :->cmds' \
        \\  '*:: :->args'
        \\
        \\case $state in
        \\  cmds)
        \\    _describe -t commands "zvm command" _zvm_commands
        \\  ;;
        \\  args)
        \\    case $line[1] in
        \\      install|use|remove)
        \\        _arguments \
        \\          '1:version:' \
        \\          '--zls[Apply to ZLS instead of Zig]'
        \\        ;;
        \\      list-remote)
        \\        _arguments \
        \\          '--zls[List ZLS versions instead of Zig]'
        \\        ;;
        \\      clean)
        \\        _arguments \
        \\          '--all[Also remove unused versions]'
        \\        ;;
        \\      env)
        \\        _arguments \
        \\          '--shell[Specify shell]:shell:(bash zsh fish powershell)'
        \\        ;;
        \\      completions)
        \\        _arguments \
        \\          '1:shell:(bash zsh fish powershell)'
        \\        ;;
        \\    esac
        \\  ;;
        \\esac
    ;

    const out = std.io.getStdOut().writer();
    try out.print("{s}\n", .{zsh_script});
}

fn print_bash_completions() !void {
    const bash_script =
        \\#!/usr/bin/env bash
        \\# zvm Bash completion
        \\
        \\_zvm_completions() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    local commands="list list-remote install use remove current env clean completions version help"
        \\
        \\    if [[ $cword -eq 1 ]]; then
        \\        COMPREPLY=( $( compgen -W "$commands" -- "$cur" ) )
        \\    else
        \\        case "${words[1]}" in
        \\            install|use|remove)
        \\                if [[ $cur == -* ]]; then
        \\                    COMPREPLY=( $( compgen -W "--zls" -- "$cur" ) )
        \\                fi
        \\                ;;
        \\            list-remote)
        \\                COMPREPLY=( $( compgen -W "--zls" -- "$cur" ) )
        \\                ;;
        \\            clean)
        \\                COMPREPLY=( $( compgen -W "--all" -- "$cur" ) )
        \\                ;;
        \\            env)
        \\                if [[ $prev == "--shell" ]]; then
        \\                    COMPREPLY=( $( compgen -W "bash zsh fish powershell" -- "$cur" ) )
        \\                else
        \\                    COMPREPLY=( $( compgen -W "--shell" -- "$cur" ) )
        \\                fi
        \\                ;;
        \\            completions)
        \\                if [[ $cword -eq 2 ]]; then
        \\                    COMPREPLY=( $( compgen -W "bash zsh fish powershell" -- "$cur" ) )
        \\                fi
        \\                ;;
        \\        esac
        \\    fi
        \\}
        \\
        \\complete -F _zvm_completions zvm
    ;

    const out = std.io.getStdOut().writer();
    try out.print("{s}\n", .{bash_script});
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
