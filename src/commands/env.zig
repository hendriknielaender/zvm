const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_tool = @import("../util/tool.zig");
const limits = @import("../memory/limits.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.EnvCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    const io_buffer_size = limits.limits.io_buffer_size_maximum;
    var buffer: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &buffer);
    const stdout = &stdout_writer.interface;

    var path_buffer = try ctx.acquire_path_buffer();
    defer path_buffer.reset();

    var fbs = std.io.fixedBufferStream(path_buffer.slice());
    const home_dir = ctx.get_home_dir();

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try fbs.writer().print("{s}/.zm/bin", .{xdg_data});
    } else {
        try fbs.writer().print("{s}/.local/share/.zm/bin", .{home_dir});
    }

    const zvm_bin_path = try path_buffer.set(fbs.getWritten());

    const shell_type = if (command.shell) |s| @tagName(s) else blk: {
        if (builtin.os.tag == .windows) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            var utf8_buffer: [limits.limits.temp_buffer_size]u8 = undefined;
            if (get_windows_env_var(arena.allocator(), "COMSPEC", &utf8_buffer) catch null) |shell_path| {
                const shell_name = std.fs.path.basename(shell_path);
                if (std.mem.indexOf(u8, shell_name, "powershell") != null) {
                    break :blk "powershell";
                } else if (std.mem.indexOf(u8, shell_name, "cmd") != null) {
                    break :blk "cmd";
                }
            }
            break :blk "cmd";
        } else {
            if (util_tool.getenv_cross_platform("SHELL")) |shell_path| {
                const shell_name = std.fs.path.basename(shell_path);
                break :blk shell_name;
            }
            break :blk "bash";
        }
    };

    if (std.mem.indexOf(u8, shell_type, "fish") != null) {
        try stdout.print("# Add this to your ~/.config/fish/config.fish:\n", .{});
        try stdout.print("set -gx PATH {s} $PATH\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "zsh") != null) {
        try stdout.print("# Add this to your ~/.zshrc:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "bash") != null) {
        try stdout.print("# Add this to your ~/.bashrc:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "sh") != null) {
        try stdout.print("# Add this to your shell configuration:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "powershell") != null or
        std.mem.indexOf(u8, shell_type, "pwsh") != null)
    {
        try stdout.print("# Add this to your PowerShell profile:\n", .{});
        try stdout.print("$env:Path = \"{s};$env:Path\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_type, "cmd") != null) {
        try stdout.print("REM Add this to your environment variables:\n", .{});
        try stdout.print("SET PATH={s};%PATH%\n", .{zvm_bin_path});
    } else {
        try stdout.print("# Add this to your shell configuration:\n", .{});
        try stdout.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    }
    try stdout.flush();
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
