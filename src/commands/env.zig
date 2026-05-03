const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const paths = @import("../platform/paths.zig");
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
    const home_dir = ctx.get_home_dir();
    // Resolve zvm_root into a separate stack buffer to avoid aliasing with the output buffer.
    var zvm_root_buf: [limits.limits.path_length_maximum]u8 = undefined;
    const zvm_root = try paths.get_zvm_root(&zvm_root_buf, home_dir);
    return try std.fmt.bufPrint(buffer, "{s}/bin", .{zvm_root});
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
    var writer_state: std.Io.Writer = .fixed(buffer);
    const writer: *std.Io.Writer = &writer_state;

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

    return writer_state.buffered();
}

fn get_windows_env_var(comptime var_name: []const u8, buffer: []u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const value = util_tool.getenv_cross_platform(var_name) orelse return null;
    if (value.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}
