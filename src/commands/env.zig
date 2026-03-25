const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const limits = @import("../memory/limits.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.EnvCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var path_buffer = try ctx.acquire_path_buffer();
    defer path_buffer.reset();
    const zvm_bin_path = try build_zvm_bin_path(ctx, path_buffer.slice());

    var shell_buffer: [limits.limits.temp_buffer_size]u8 = undefined;
    const shell_name = try detect_shell_name(command.shell, &shell_buffer);

    var text_buffer: [limits.limits.io_buffer_size_maximum]u8 = undefined;
    const text = try build_env_text(shell_name, zvm_bin_path, &text_buffer);

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "shell", .value = .{ .string = shell_name } },
            .{ .key = "text", .value = .{ .string = text } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.print_text(text);
}

fn build_zvm_bin_path(ctx: *context.CliContext, buffer: []u8) ![]const u8 {
    var stream = std.Io.fixedBufferStream(buffer);
    const home_dir = ctx.get_home_dir();

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try stream.writer().print("{s}/.zm/bin", .{xdg_data});
    } else {
        try stream.writer().print("{s}/.local/share/.zm/bin", .{home_dir});
    }

    return stream.getWritten();
}

fn detect_shell_name(shell: ?validation.ShellType, buffer: []u8) ![]const u8 {
    if (shell) |explicit_shell| {
        return @tagName(explicit_shell);
    }

    if (builtin.os.tag == .windows) {
        return try detect_windows_shell(buffer);
    }

    if (util_tool.getenv_cross_platform("SHELL")) |shell_path| {
        return std.fs.path.basename(shell_path);
    }

    return "bash";
}

fn detect_windows_shell(buffer: []u8) ![]const u8 {
    const shell_path = try get_windows_env_var("COMSPEC", buffer);
    if (shell_path) |value| {
        const shell_name = std.fs.path.basename(value);

        if (std.mem.indexOf(u8, shell_name, "powershell") != null) return "powershell";
        if (std.mem.indexOf(u8, shell_name, "cmd") != null) return "cmd";
    }

    return "cmd";
}

fn build_env_text(shell_name: []const u8, zvm_bin_path: []const u8, buffer: []u8) ![]const u8 {
    var stream = std.Io.fixedBufferStream(buffer);
    const writer = stream.writer();

    if (std.mem.indexOf(u8, shell_name, "fish") != null) {
        try writer.print("# Add this to your ~/.config/fish/config.fish:\n", .{});
        try writer.print("set -gx PATH {s} $PATH\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "zsh") != null) {
        try writer.print("# Add this to your ~/.zshrc:\n", .{});
        try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "bash") != null) {
        try writer.print("# Add this to your ~/.bashrc:\n", .{});
        try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "sh") != null) {
        try writer.print("# Add this to your shell configuration:\n", .{});
        try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "powershell") != null) {
        try writer.print("# Add this to your PowerShell profile:\n", .{});
        try writer.print("$env:Path = \"{s};$env:Path\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "pwsh") != null) {
        try writer.print("# Add this to your PowerShell profile:\n", .{});
        try writer.print("$env:Path = \"{s};$env:Path\"\n", .{zvm_bin_path});
    } else if (std.mem.indexOf(u8, shell_name, "cmd") != null) {
        try writer.print("REM Add this to your environment variables:\n", .{});
        try writer.print("SET PATH={s};%PATH%\n", .{zvm_bin_path});
    } else {
        try writer.print("# Add this to your shell configuration:\n", .{});
        try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
    }

    return stream.getWritten();
}

fn get_windows_env_var(comptime var_name: []const u8, buffer: []u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const key_w = comptime std.unicode.wtf8ToWtf16LeStringLiteral(var_name);
    const result_w = std.process.getenvW(key_w) orelse return null;
    const result_len = std.unicode.wtf16LeToWtf8(buffer, result_w);
    if (result_len > buffer.len) return error.BufferTooSmall;
    return buffer[0..result_len];
}
