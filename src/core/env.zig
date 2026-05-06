const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const validation = @import("../cli/validation.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const paths = @import("../platform/paths.zig");
const limits = @import("../memory/limits.zig");

const assert = std.debug.assert;

/// Shell families recognised when emitting `zvm env` text. We dispatch on
/// this enum rather than on substring matches against the shell name —
/// e.g. "powershell" contains the substring "sh", which previously caused
/// PowerShell to be misclassified as a POSIX shell.
const ShellKind = enum {
    bash,
    zsh,
    fish,
    sh,
    powershell,
    cmd,

    fn display_name(kind: ShellKind) []const u8 {
        return switch (kind) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .sh => "sh",
            .powershell => "powershell",
            .cmd => "cmd",
        };
    }
};

pub fn emit_env(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.EnvCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var zvm_bin_buffer: [limits.limits.path_length_maximum]u8 = undefined;
    const zvm_bin_path = try build_zvm_bin_path(ctx, &zvm_bin_buffer);
    assert(zvm_bin_path.len > 0);

    var zvm_config_buffer: [limits.limits.path_length_maximum]u8 = undefined;
    const zvm_config_dir = try build_zvm_config_dir(ctx, &zvm_config_buffer);
    assert(zvm_config_dir.len > 0);

    const shell_kind = detect_shell_kind(command.shell);
    const shell_name = shell_kind.display_name();
    assert(shell_name.len > 0);

    var text_buffer: [limits.limits.io_buffer_size_maximum]u8 = undefined;
    const text = try build_env_text(shell_kind, zvm_bin_path, zvm_config_dir, &text_buffer);
    assert(text.len > 0);

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "shell", .value = .{ .string = shell_name } },
            .{ .key = "config_dir", .value = .{ .string = zvm_config_dir } },
            .{ .key = "text", .value = .{ .string = text } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.print_text(text);
}

fn build_zvm_bin_path(ctx: *context.CliContext, buffer: []u8) ![]const u8 {
    assert(buffer.len > 0);
    const home_dir = ctx.get_home_dir();
    // Resolve zvm_root into a separate stack buffer to avoid aliasing with the output buffer.
    var zvm_root_buf: [limits.limits.path_length_maximum]u8 = undefined;
    const zvm_root = try paths.get_zvm_root(&zvm_root_buf, home_dir);
    return try std.fmt.bufPrint(buffer, "{s}/bin", .{zvm_root});
}

fn build_zvm_config_dir(ctx: *context.CliContext, buffer: []u8) ![]const u8 {
    assert(buffer.len > 0);
    const home_dir = ctx.get_home_dir();
    return try paths.get_zvm_config_dir(buffer, home_dir);
}

fn detect_shell_kind(shell: ?validation.ShellType) ShellKind {
    if (shell) |explicit| {
        return switch (explicit) {
            .bash => .bash,
            .zsh => .zsh,
            .fish => .fish,
            .powershell => .powershell,
        };
    }

    if (builtin.os.tag == .windows) {
        return detect_windows_shell_kind();
    }

    if (util_tool.getenv_cross_platform("SHELL")) |shell_path| {
        const basename = std.fs.path.basename(shell_path);
        return classify_shell_basename(basename);
    }

    return .bash;
}

fn classify_shell_basename(basename: []const u8) ShellKind {
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    if (std.mem.eql(u8, basename, "fish")) return .fish;
    if (std.mem.eql(u8, basename, "sh")) return .sh;
    if (std.mem.eql(u8, basename, "powershell")) return .powershell;
    if (std.mem.eql(u8, basename, "powershell.exe")) return .powershell;
    if (std.mem.eql(u8, basename, "pwsh")) return .powershell;
    if (std.mem.eql(u8, basename, "pwsh.exe")) return .powershell;
    if (std.mem.eql(u8, basename, "cmd")) return .cmd;
    if (std.mem.eql(u8, basename, "cmd.exe")) return .cmd;
    return .bash;
}

fn detect_windows_shell_kind() ShellKind {
    if (builtin.os.tag != .windows) return .bash;

    if (util_tool.getenv_cross_platform("PSModulePath") != null) return .powershell;

    if (util_tool.getenv_cross_platform("COMSPEC")) |comspec| {
        const basename = std.fs.path.basename(comspec);
        return classify_shell_basename(basename);
    }

    return .cmd;
}

fn build_env_text(
    shell_kind: ShellKind,
    zvm_bin_path: []const u8,
    zvm_config_dir: []const u8,
    buffer: []u8,
) ![]const u8 {
    assert(zvm_bin_path.len > 0);
    assert(zvm_config_dir.len > 0);
    assert(buffer.len > 0);

    var writer_state: std.Io.Writer = .fixed(buffer);
    const writer: *std.Io.Writer = &writer_state;

    switch (shell_kind) {
        .fish => {
            try writer.print("# Add this to your ~/.config/fish/config.fish:\n", .{});
            try writer.print("# zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("set -gx PATH {s} $PATH\n", .{zvm_bin_path});
        },
        .zsh => {
            try writer.print("# Add this to your ~/.zshrc:\n", .{});
            try writer.print("# zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
        },
        .bash => {
            try writer.print("# Add this to your ~/.bashrc:\n", .{});
            try writer.print("# zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
        },
        .sh => {
            try writer.print("# Add this to your shell configuration:\n", .{});
            try writer.print("# zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("export PATH=\"{s}:$PATH\"\n", .{zvm_bin_path});
        },
        .powershell => {
            try writer.print("# Add this to your PowerShell profile:\n", .{});
            try writer.print("# zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("$env:Path = \"{s};$env:Path\"\n", .{zvm_bin_path});
        },
        .cmd => {
            try writer.print("REM Add this to your environment variables:\n", .{});
            try writer.print("REM zvm config directory: {s}\n", .{zvm_config_dir});
            try writer.print("SET PATH={s};%PATH%\n", .{zvm_bin_path});
        },
    }

    const text = writer_state.buffered();
    assert(text.len > 0);
    return text;
}
