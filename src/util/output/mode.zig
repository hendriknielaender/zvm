const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Output modes that determine formatting and destination.
/// `plain` is for shell pipelines: tabular records, no headers, no color,
/// no progress. Why: human_readable decoration breaks `awk` / `grep`
/// parsing, while machine_json is overkill for one-shot scripts.
pub const OutputMode = enum {
    human_readable,
    machine_json,
    silent_errors_only,
    plain,

    comptime {
        const mode_count = @typeInfo(OutputMode).@"enum".fields.len;
        assert(mode_count == 4);
        assert(mode_count >= 2);
        assert(mode_count <= 8);
    }
};

/// Color mode for terminal output.
/// .auto defers the decision to environment and terminal inspection at startup.
pub const ColorMode = enum {
    never_use_color,
    always_use_color,
    auto,

    pub fn should_use_color(self: ColorMode) bool {
        return switch (self) {
            .never_use_color => false,
            .always_use_color => true,
            .auto => false,
        };
    }

    comptime {
        assert(@typeInfo(ColorMode).@"enum".fields.len == 3);
    }
};

pub const OutputConfig = struct {
    mode: OutputMode,
    color: ColorMode,

    pub fn validate(self: OutputConfig) void {
        assert(self.mode == .human_readable or
            self.mode == .machine_json or
            self.mode == .silent_errors_only or
            self.mode == .plain);
        assert(self.color == .never_use_color or
            self.color == .always_use_color);

        assert(self.color != .auto);

        if (self.mode == .machine_json) {
            assert(self.color == .never_use_color);
        }
        if (self.mode == .plain) {
            assert(self.color == .never_use_color);
        }
    }

    comptime {
        const config_size = @sizeOf(OutputConfig);
        assert(config_size <= 16);
        assert(config_size >= 2);
    }
};

pub fn resolve_color_mode(
    flag: ColorMode,
    no_color_env_set: bool,
    is_terminal: bool,
    term_is_dumb: bool,
) ColorMode {
    assert(@intFromEnum(flag) < 3);

    if (flag == .always_use_color) return .always_use_color;
    if (flag == .never_use_color) return .never_use_color;

    if (no_color_env_set) return .never_use_color;
    if (term_is_dumb) return .never_use_color;
    if (!is_terminal) return .never_use_color;

    const result: ColorMode = .always_use_color;
    assert(result != .auto);
    assert(@intFromEnum(result) < 2);
    return result;
}

pub fn stdout_is_terminal() bool {
    if (builtin.os.tag == .windows) {
        return is_windows_console_handle(std_windows_output_handle);
    }
    return is_posix_fd_terminal(std.posix.STDOUT_FILENO);
}

pub fn stderr_is_terminal() bool {
    if (builtin.os.tag == .windows) {
        return is_windows_console_handle(std_windows_error_handle);
    }
    return is_posix_fd_terminal(std.posix.STDERR_FILENO);
}

fn is_posix_fd_terminal(fd: std.posix.fd_t) bool {
    assert(fd >= 0);
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

const std_windows_output_handle: std.os.windows.DWORD = @bitCast(@as(i32, -11));
const std_windows_error_handle: std.os.windows.DWORD = @bitCast(@as(i32, -12));

comptime {
    assert(std_windows_output_handle != std_windows_error_handle);
}

extern "kernel32" fn GetStdHandle(
    nStdHandle: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: ?std.os.windows.HANDLE,
    lpMode: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn is_windows_console_handle(n_std_handle: std.os.windows.DWORD) bool {
    const handle = GetStdHandle(n_std_handle) orelse return false;
    assert(@intFromPtr(handle) != 0);
    if (@intFromPtr(handle) == @intFromPtr(std.os.windows.INVALID_HANDLE_VALUE)) return false;

    var mode: std.os.windows.DWORD = 0;
    const is_console = GetConsoleMode(handle, &mode) != .FALSE;
    if (is_console) {
        assert(mode != 0);
    }
    return is_console;
}

test "resolve_color_mode: explicit always_use_color flag overrides everything" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.always_use_color,
        resolve_color_mode(.always_use_color, true, false, true),
    );
    try testing.expectEqual(
        ColorMode.always_use_color,
        resolve_color_mode(.always_use_color, false, true, false),
    );
}

test "resolve_color_mode: explicit never_use_color flag overrides everything" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.never_use_color, false, true, false),
    );
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.never_use_color, true, false, true),
    );
}

test "resolve_color_mode: auto with NO_COLOR set disables color" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.auto, true, true, false),
    );
}

test "resolve_color_mode: auto with TERM=dumb disables color" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.auto, false, true, true),
    );
}

test "resolve_color_mode: auto with stdout not a TTY disables color" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.auto, false, false, false),
    );
}

test "resolve_color_mode: auto with all clear enables color" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.always_use_color,
        resolve_color_mode(.auto, false, true, false),
    );
}

test "resolve_color_mode: precedence: never flag wins over auto conditions" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.never_use_color,
        resolve_color_mode(.never_use_color, false, true, false),
    );
}

test "resolve_color_mode: precedence: always flag wins over auto conditions" {
    const testing = std.testing;
    try testing.expectEqual(
        ColorMode.always_use_color,
        resolve_color_mode(.always_use_color, true, false, true),
    );
}
