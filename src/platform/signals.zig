const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const exit_code_interrupted = 130;

var interrupt_requested = std.atomic.Value(bool).init(false);
var cleanup_running = std.atomic.Value(bool).init(false);
var blocking_wait_running = std.atomic.Value(bool).init(false);

pub fn install_handler() void {
    switch (builtin.os.tag) {
        .windows => install_handler_windows(),
        else => install_handler_posix(),
    }
}

pub fn requested() bool {
    return interrupt_requested.load(.acquire);
}

pub fn check() error{Interrupted}!void {
    if (requested()) return error.Interrupted;
}

pub fn begin_cleanup() void {
    cleanup_running.store(true, .release);
}

pub fn end_cleanup() void {
    cleanup_running.store(false, .release);
}

pub fn begin_blocking_wait() void {
    blocking_wait_running.store(true, .release);
    if (requested()) std.process.exit(exit_code_interrupted);
}

pub fn end_blocking_wait() void {
    blocking_wait_running.store(false, .release);
}

fn request_interrupt() void {
    const already_requested = interrupt_requested.swap(true, .acq_rel);
    if (already_requested or
        cleanup_running.load(.acquire) or
        blocking_wait_running.load(.acquire))
    {
        std.process.exit(exit_code_interrupted);
    }
}

fn install_handler_posix() void {
    if (builtin.os.tag == .windows) unreachable;

    const posix = std.posix;
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handle_sigint },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
}

fn handle_sigint(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
    request_interrupt();
}

fn install_handler_windows() void {
    if (builtin.os.tag != .windows) unreachable;

    const windows = std.os.windows;
    const ok = SetConsoleCtrlHandler(handle_windows_control, windows.BOOL.TRUE);
    assert(ok != .FALSE);
}

fn handle_windows_control(control_type: u32) callconv(.winapi) std.os.windows.BOOL {
    switch (control_type) {
        ctrl_c_event => {
            request_interrupt();
            return std.os.windows.BOOL.TRUE;
        },
        ctrl_break_event => {
            request_interrupt();
            return std.os.windows.BOOL.TRUE;
        },
        else => return std.os.windows.BOOL.FALSE,
    }
}

const ctrl_c_event: u32 = 0;
const ctrl_break_event: u32 = 1;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler_routine: ?*const fn (u32) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;
