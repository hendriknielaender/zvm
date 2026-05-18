//! Confirmation prompts for destructive operations.
//!
//! Why: silently destroying installed versions or cached artifacts is hostile
//! to operators who fat-fingered a command. We prompt by default, and accept
//! --yes for automation. Non-TTY input is rejected up front because reading
//! /dev/null hangs forever in CI and mis-reads piped scripts.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const signals = @import("../platform/signals.zig");

const max_prompt_length_bytes = 256;
const max_response_length_bytes = 32;

comptime {
    assert(max_prompt_length_bytes >= 64);
    assert(max_prompt_length_bytes <= 1024);
    assert(max_response_length_bytes >= 8);
    assert(max_response_length_bytes <= 64);
}

pub const ConfirmError = error{
    /// stdin is not a terminal or --no-input was set; the caller must
    /// instruct the operator to pass --yes.
    RequiresConfirmation,
    /// stdin read failed; treat as a hard error so we never proceed by
    /// accident on a partial response.
    StdinReadFailed,
};

/// Detect whether stdin is connected to a terminal.
/// Why: prompting a non-TTY stdin (pipes, CI logs, scripts) either hangs
/// forever or mis-reads scripted input as confirmation.
pub fn stdin_is_terminal() bool {
    if (builtin.os.tag == .windows) {
        return is_windows_console_handle(std_windows_input_handle);
    }
    return is_posix_fd_terminal(std.posix.STDIN_FILENO);
}

fn is_posix_fd_terminal(fd: std.posix.fd_t) bool {
    assert(fd >= 0);
    // tcgetattr fails with ENOTTY when fd is not a terminal.
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

/// Windows STD_INPUT_HANDLE = (DWORD)-10, per winbase.h.
const std_windows_input_handle: std.os.windows.DWORD = @bitCast(@as(i32, -10));

extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: ?std.os.windows.HANDLE,
    lpMode: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn is_windows_console_handle(n_std_handle: std.os.windows.DWORD) bool {
    const handle = GetStdHandle(n_std_handle) orelse return false;
    assert(@intFromPtr(handle) != 0);
    if (@intFromPtr(handle) == @intFromPtr(std.os.windows.INVALID_HANDLE_VALUE)) return false;
    var mode: std.os.windows.DWORD = 0;
    return GetConsoleMode(handle, &mode) != .FALSE;
}

/// Prompt the operator to confirm a destructive action.
///
/// Returns true on yes, false on no. Returns RequiresConfirmation when stdin
/// is not a terminal or when no_input is set, so the caller can translate
/// that to a "use --yes to confirm" message and exit non-zero.
///
/// Why default_no: destructive defaults must be conservative — pressing
/// Enter on an unread prompt should never delete files.
pub fn confirm_destructive(
    io: std.Io,
    prompt: []const u8,
    default_no: bool,
    no_input: bool,
) ConfirmError!bool {
    assert(prompt.len > 0);
    assert(prompt.len <= max_prompt_length_bytes);

    if (no_input) return error.RequiresConfirmation;
    if (!stdin_is_terminal()) return error.RequiresConfirmation;

    // The prompt goes to stderr so stdout stays clean for piped consumers.
    var stderr_buffer: [max_prompt_length_bytes + 16]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const suffix: []const u8 = if (default_no) " [y/N]: " else " [Y/n]: ";
    stderr.writeAll(prompt) catch return error.StdinReadFailed;
    stderr.writeAll(suffix) catch return error.StdinReadFailed;
    stderr.flush() catch return error.StdinReadFailed;

    var read_buffer: [max_response_length_bytes]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buffer);

    signals.begin_blocking_wait();
    defer signals.end_blocking_wait();
    const line = stdin_reader.interface.takeDelimiter('\n') catch
        return error.StdinReadFailed;
    if (line == null) return !default_no == false; // EOF on TTY: treat as no.

    const response = std.mem.trim(u8, line.?, " \t\r");

    return interpret_response(response, default_no);
}

fn interpret_response(response: []const u8, default_no: bool) bool {
    assert(response.len <= max_response_length_bytes);

    if (response.len == 0) return !default_no;
    if (response.len == 1) {
        const ch = std.ascii.toLower(response[0]);
        if (ch == 'y') return true;
        if (ch == 'n') return false;
    }
    if (std.ascii.eqlIgnoreCase(response, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(response, "no")) return false;
    // Unknown input → take the safe default; for destructive actions that is no.
    return false;
}

test "interpret_response: empty defaults to default" {
    const testing = std.testing;
    try testing.expectEqual(false, interpret_response("", true));
    try testing.expectEqual(true, interpret_response("", false));
}

test "interpret_response: single letters" {
    const testing = std.testing;
    try testing.expectEqual(true, interpret_response("y", true));
    try testing.expectEqual(true, interpret_response("Y", true));
    try testing.expectEqual(false, interpret_response("n", false));
    try testing.expectEqual(false, interpret_response("N", false));
}

test "interpret_response: yes / no words" {
    const testing = std.testing;
    try testing.expectEqual(true, interpret_response("yes", true));
    try testing.expectEqual(true, interpret_response("YES", true));
    try testing.expectEqual(false, interpret_response("no", false));
    try testing.expectEqual(false, interpret_response("NO", false));
}

test "interpret_response: unknown input is treated as no" {
    const testing = std.testing;
    try testing.expectEqual(false, interpret_response("maybe", false));
    try testing.expectEqual(false, interpret_response("garbage", true));
}

comptime {
    assert(max_prompt_length_bytes < 1024);
    assert(max_response_length_bytes < max_prompt_length_bytes);
}
