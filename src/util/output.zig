const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../memory/limits.zig");
const assert = std.debug.assert;

const io_buffer_size_bytes = limits.limits.io_buffer_size_maximum;
const max_message_length_bytes = 2048;
const max_json_object_fields = 16;
const json_hex_digits = "0123456789abcdef";

comptime {
    assert(io_buffer_size_bytes >= 1024);
    assert(max_message_length_bytes >= 256);
    assert(max_message_length_bytes <= io_buffer_size_bytes);
    assert(max_message_length_bytes + 16 <= io_buffer_size_bytes);
    assert(max_json_object_fields >= 4);
    assert(max_json_object_fields <= 32);
}

/// Exit codes with semantic meaning
pub const ExitCode = enum(u8) {
    success = 0,
    invalid_arguments = 1,
    version_not_found = 2,
    network_error = 3,
    permission_error = 4,
    file_system_error = 5,
    already_exists = 6,
    corruption_detected = 7,
    resource_exhausted = 8,
    interrupted = 130,

    comptime {
        assert(@intFromEnum(ExitCode.success) == 0);
        assert(@intFromEnum(ExitCode.resource_exhausted) < 16);
        assert(@intFromEnum(ExitCode.resource_exhausted) >= @intFromEnum(ExitCode.success));
        assert(@intFromEnum(ExitCode.interrupted) == 130);
    }

    /// Convert error union types to semantic exit codes
    pub fn from_error(error_value: anyerror) ExitCode {
        return switch (error_value) {
            // File system errors
            error.FileNotFound, error.IsDir, error.NotDir => .file_system_error,
            error.PathAlreadyExists, error.AlreadyExists => .already_exists,
            error.AccessDenied, error.PermissionDenied => .permission_error,

            // Network errors
            error.NetworkUnreachable, error.ConnectionRefused, error.Timeout, error.HostNotFound => .network_error,

            // Resource errors
            error.OutOfMemory, error.NoSpaceLeft, error.SystemResources => .resource_exhausted,

            // Data integrity errors
            error.InvalidData, error.HashMismatch, error.CorruptedData => .corruption_detected,

            // Version/package not found
            error.VersionNotFound, error.PackageNotFound => .version_not_found,

            // User interrupts map to the conventional shell status 128 + SIGINT.
            error.Interrupted => .interrupted,

            // Default to invalid arguments for parsing/validation errors
            else => .invalid_arguments,
        };
    }
};

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

/// Verbosity level for diagnostic output. Set once at startup from the
/// `--verbose` / `--trace` global flag (or `ZVM_DEBUG` env var, for
/// backward compatibility) and read globally by `trace()` / `debug_enabled()`.
///
/// Why three levels: `none` is the operator default — keep stderr quiet.
/// `debug` mirrors the legacy `ZVM_DEBUG=1` behavior (resource summary).
/// `trace` adds per-operation detail (HTTP requests, file paths) for
/// reproducing bugs without recompiling.
pub const VerboseLevel = enum(u8) {
    none = 0,
    debug = 1,
    trace = 2,

    pub fn at_least(self: VerboseLevel, threshold: VerboseLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(threshold);
    }

    comptime {
        assert(@typeInfo(VerboseLevel).@"enum".fields.len == 3);
        assert(@intFromEnum(VerboseLevel.none) == 0);
        assert(@intFromEnum(VerboseLevel.trace) == 2);
        assert(@intFromEnum(VerboseLevel.debug) > @intFromEnum(VerboseLevel.none));
        assert(@intFromEnum(VerboseLevel.trace) > @intFromEnum(VerboseLevel.debug));
    }
};

/// Process-wide verbose level. Set once after CLI parsing completes; read
/// by trace/debug helpers and library code that wants to gate diagnostic
/// output. Default `.none` keeps non-verbose runs quiet on stderr.
var verbose_level_global: VerboseLevel = .none;

pub fn set_verbose_level(level: VerboseLevel) void {
    assert(@intFromEnum(level) <= @intFromEnum(VerboseLevel.trace));
    verbose_level_global = level;
}

fn get_verbose_level() VerboseLevel {
    return verbose_level_global;
}

pub fn debug_enabled() bool {
    return verbose_level_global.at_least(.debug);
}

fn trace_enabled() bool {
    return verbose_level_global.at_least(.trace);
}

/// Emit a trace line to stderr when `--trace` is active.
/// No-op otherwise. Why stderr: keeps stdout reserved for command output
/// so trace lines don't pollute pipelines (`zvm --plain --trace list | awk ...`).
pub fn trace(comptime message: []const u8, args: anytype) void {
    if (!trace_enabled()) return;
    emit_diagnostic_line("trace: ", message, args);
}

/// Emit a debug line to stderr when `--verbose` (or higher) is active.
fn debug(comptime message: []const u8, args: anytype) void {
    if (!debug_enabled()) return;
    emit_diagnostic_line("debug: ", message, args);
}

fn emit_diagnostic_line(
    comptime prefix: []const u8,
    comptime message: []const u8,
    args: anytype,
) void {
    assert(prefix.len > 0);
    assert(prefix.len < 16);
    assert(message.len > 0);
    assert(message.len < 1024);

    var line_buffer: [max_message_length_bytes]u8 = undefined;
    const formatted = std.fmt.bufPrint(&line_buffer, prefix ++ message ++ "\n", args) catch
        return;
    assert(formatted.len > 0);
    assert(formatted.len <= line_buffer.len);

    std.Io.File.stderr().writeStreamingAll(
        std.Io.Threaded.global_single_threaded.io(),
        formatted,
    ) catch return;
}

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

/// Resolve .auto to a concrete color mode using the standard precedence:
/// 1. Explicit --color / --no-color flags.
/// 2. NO_COLOR environment variable (any non-empty value).
/// 3. TERM=dumb.
/// 4. stdout is not a TTY.
/// 5. Otherwise, use color.
///
/// Precedence matters because explicit user intent must always override
/// automatic detection. Environment checks (NO_COLOR, TERM) are the
/// cross-tool standard; isatty is the last line of defense against
/// writing ANSI escape codes into files and pipes.
pub fn resolve_color_mode(
    flag: ColorMode,
    no_color_env_set: bool,
    is_terminal: bool,
    term_is_dumb: bool,
) ColorMode {
    // Pair assertion: flag is one of the three defined enum variants.
    assert(@intFromEnum(flag) < 3);

    if (flag == .always_use_color) return .always_use_color;
    if (flag == .never_use_color) return .never_use_color;

    if (no_color_env_set) return .never_use_color;
    if (term_is_dumb) return .never_use_color;
    if (!is_terminal) return .never_use_color;

    const result: ColorMode = .always_use_color;
    // Pair assertion: the resolved result is never .auto.
    assert(result != .auto);
    assert(@intFromEnum(result) < 2);
    return result;
}

/// Detect whether stdout is connected to a terminal.
/// Returns false when piped, redirected, or no console is attached.
/// Why: ANSI escape codes corrupt binary output; detecting the sink
/// avoids writing color sequences into files and pipes.
pub fn stdout_is_terminal() bool {
    if (builtin.os.tag == .windows) {
        return is_windows_console_handle(std_windows_output_handle);
    }
    return is_posix_fd_terminal(std.posix.STDOUT_FILENO);
}

/// Detect whether stderr is connected to a terminal.
/// Returns false when piped, redirected, or no console is attached.
/// Why: std.Progress writes ANSI cursor escapes to stderr; those
/// sequences corrupt output when stderr is piped to a file or `tee`.
pub fn stderr_is_terminal() bool {
    if (builtin.os.tag == .windows) {
        return is_windows_console_handle(std_windows_error_handle);
    }
    return is_posix_fd_terminal(std.posix.STDERR_FILENO);
}

fn is_posix_fd_terminal(fd: std.posix.fd_t) bool {
    assert(fd >= 0);
    // tcgetattr fails with ENOTTY when fd is not a terminal.
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

/// Windows standard device handles. Values from winbase.h:
/// STD_OUTPUT_HANDLE = (DWORD)-11, STD_ERROR_HANDLE = (DWORD)-12.
/// Why: Zig 0.16.0 removed the GetStdHandle / GetConsoleMode wrappers
/// from std.os.windows; we declare them directly against kernel32.dll.
const std_windows_output_handle: std.os.windows.DWORD = @bitCast(@as(i32, -11));
const std_windows_error_handle: std.os.windows.DWORD = @bitCast(@as(i32, -12));

comptime {
    // Pair assertion: the two standard-device handles must be distinct.
    assert(std_windows_output_handle != std_windows_error_handle);
}

extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: ?std.os.windows.HANDLE,
    lpMode: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

fn is_windows_console_handle(n_std_handle: std.os.windows.DWORD) bool {
    const handle = GetStdHandle(n_std_handle) orelse return false;
    // Pair assertion: the handle pointer must be non-null.
    assert(@intFromPtr(handle) != 0);
    if (@intFromPtr(handle) == @intFromPtr(std.os.windows.INVALID_HANDLE_VALUE)) return false;
    var mode: std.os.windows.DWORD = 0;
    const is_console = GetConsoleMode(handle, &mode) != .FALSE;
    if (is_console) {
        // Pair assertion: mode set by GetConsoleMode must be non-zero.
        assert(mode != 0);
    }
    return is_console;
}

/// Configuration for output behavior
pub const OutputConfig = struct {
    mode: OutputMode,
    color: ColorMode,

    pub fn validate(self: OutputConfig) void {
        // Positive assertions
        assert(self.mode == .human_readable or
            self.mode == .machine_json or
            self.mode == .silent_errors_only or
            self.mode == .plain);
        assert(self.color == .never_use_color or
            self.color == .always_use_color);

        // Negative assertion: .auto must be resolved before reaching OutputConfig.
        assert(self.color != .auto);

        // Negative assertions - invalid combinations
        if (self.mode == .machine_json) {
            assert(self.color == .never_use_color); // JSON never uses colors
        }
        if (self.mode == .plain) {
            assert(self.color == .never_use_color); // Plain mode never uses colors
        }
    }

    comptime {
        const config_size = @sizeOf(OutputConfig);
        assert(config_size <= 16); // Keep config small
        assert(config_size >= 2); // Must contain meaningful data
    }
};

/// Message levels for structured logging
pub const MessageLevel = enum {
    success,
    info,
    warning,
    error_recoverable,
    error_fatal,

    /// Convert to string for JSON output
    pub fn to_string(self: MessageLevel) []const u8 {
        return switch (self) {
            .success => "success",
            .info => "info",
            .warning => "warning",
            .error_recoverable => "error",
            .error_fatal => "fatal",
        };
    }

    comptime {
        assert(@typeInfo(MessageLevel).@"enum".fields.len == 5);
        // Assert string lengths are reasonable
        assert(MessageLevel.success.to_string().len <= 16);
        assert(MessageLevel.error_fatal.to_string().len <= 16);
    }
};

pub const JsonPayload = union(enum) {
    object: []const JsonField,
    string_array: StringArray,
    text: []const u8,

    pub const StringArray = struct {
        field_name: []const u8,
        items: []const []const u8,
    };
};

/// Centralized output management
const OutputEmitter = struct {
    config: OutputConfig,
    stdout_buffer: [io_buffer_size_bytes]u8,
    stderr_buffer: [io_buffer_size_bytes]u8,
    message_buffer: [max_message_length_bytes]u8,

    fn init(config: OutputConfig) OutputEmitter {
        config.validate(); // Assert valid configuration

        return OutputEmitter{
            .config = config,
            .stdout_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .stderr_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .message_buffer = std.mem.zeroes([max_message_length_bytes]u8),
        };
    }

    /// Emit success message to appropriate stream
    fn emit_success(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        assert(message.len > 0);
        assert(message.len < 1024); // Reasonable message length

        self.emit_message(.success, message, args);
    }

    /// Emit informational message
    fn emit_info(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        assert(message.len > 0);
        assert(message.len < 4096);

        self.emit_message(.info, message, args);
    }

    /// Emit warning message to stderr
    fn emit_warning(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        assert(message.len > 0);
        assert(message.len < 1024);

        self.emit_message(.warning, message, args);
    }

    /// Emit recoverable error to stderr
    fn emit_error(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        assert(message.len > 0);
        assert(message.len < 1024);

        self.emit_message(.error_recoverable, message, args);
    }

    /// Emit fatal error and terminate program
    fn emit_fatal(self: *OutputEmitter, exit_code: ExitCode, comptime message: []const u8, args: anytype) noreturn {
        assert(message.len > 0);
        assert(message.len < 1024);
        assert(exit_code != .success); // Fatal errors never succeed

        self.emit_message(.error_fatal, message, args);
        std.process.exit(@intFromEnum(exit_code));
    }

    /// Emit JSON array of strings
    fn emit_json_array(self: *OutputEmitter, field_name: []const u8, items: []const []const u8) void {
        assert(field_name.len > 0);
        assert(field_name.len < 64);
        assert(items.len <= limits.limits.versions_maximum);

        if (self.config.mode != .machine_json) return;

        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll("{\"") catch return;
        writer.writeAll(field_name) catch return;
        writer.writeAll("\":[") catch return;

        for (items, 0..) |item, index| {
            assert(item.len > 0);
            assert(item.len < 256); // Reasonable item length

            if (index > 0) {
                writer.writeAll(",") catch return;
            }
            write_json_string(writer, item) catch return;
        }

        writer.writeAll("]}\n") catch return;

        // Flush to stdout
        self.flush_stdout_buffer(writer_state.buffered());
    }

    /// Emit JSON key-value pairs
    fn emit_json_object(self: *OutputEmitter, fields: []const JsonField) void {
        assert(fields.len > 0);
        assert(fields.len <= max_json_object_fields);

        if (self.config.mode != .machine_json) return;

        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll("{") catch return;

        for (fields, 0..) |field, index| {
            assert(field.key.len > 0);
            assert(field.key.len < 64);

            if (index > 0) {
                writer.writeAll(",") catch return;
            }

            write_json_string(writer, field.key) catch return;
            writer.writeAll(":") catch return;

            switch (field.value) {
                .string => |s| {
                    if (s) |str| {
                        assert(str.len <= io_buffer_size_bytes);
                        write_json_string(writer, str) catch return;
                    } else {
                        writer.writeAll("null") catch return;
                    }
                },
                .number => |n| {
                    var buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
                    writer.writeAll(num_str) catch return;
                },
                .boolean => |value| {
                    if (value) {
                        writer.writeAll("true") catch return;
                    } else {
                        writer.writeAll("false") catch return;
                    }
                },
                .array_strings => |items| {
                    write_json_string_array(writer, items) catch return;
                },
            }
        }

        writer.writeAll("}\n") catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    fn emit_text(self: *OutputEmitter, text: []const u8) void {
        assert(text.len > 0);
        assert(text.len <= io_buffer_size_bytes);

        switch (self.config.mode) {
            .silent_errors_only => return,
            .human_readable => self.write_plain_to_stdout(text),
            .plain => self.write_plain_to_stdout(text),
            .machine_json => {
                const fields = [_]JsonField{
                    .{ .key = "text", .value = .{ .string = text } },
                };
                self.emit_json_object(&fields);
            },
        }
    }

    // Private implementation methods

    /// Core message emission logic
    fn emit_message(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        switch (self.config.mode) {
            .silent_errors_only => {
                // Only emit errors in silent mode
                if (level == .error_recoverable or level == .error_fatal) {
                    self.emit_to_stderr_plain(level, message, args);
                }
            },
            .plain => {
                // Plain mode: only diagnostics on stderr, no decoration on stdout.
                // Why: shell pipelines parse stdout; non-data lines must not appear there.
                if (level == .warning or level == .error_recoverable or level == .error_fatal) {
                    self.emit_to_stderr_plain(level, message, args);
                }
            },
            .machine_json => {
                self.emit_json_message(level, message, args);
            },
            .human_readable => {
                if (level == .warning or level == .error_recoverable or level == .error_fatal) {
                    self.emit_to_stderr_colored(level, message, args);
                } else {
                    self.emit_to_stdout_colored(level, message, args);
                }
            },
        }
    }

    /// Emit colored message to stdout
    fn emit_to_stdout_colored(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);

        if (self.config.color.should_use_color()) {
            const color_code = get_color_code(level);
            self.write_colored_to_stdout(color_code, formatted);
        } else {
            self.write_plain_to_stdout(formatted);
        }
    }

    /// Emit colored message to stderr
    fn emit_to_stderr_colored(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);
        const tag = stderr_level_tag(level);

        if (self.config.color.should_use_color()) {
            const color_code = get_color_code(level);
            self.write_colored_to_stderr(color_code, tag, formatted);
        } else {
            self.write_plain_to_stderr(tag, formatted);
        }
    }

    /// Emit plain message to stderr
    fn emit_to_stderr_plain(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);
        const tag = stderr_level_tag(level);
        self.write_plain_to_stderr(tag, formatted);
    }

    /// Emit JSON structured message
    fn emit_json_message(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);

        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll("{\"level\":") catch return;
        write_json_string(writer, level.to_string()) catch return;
        writer.writeAll(",\"message\":") catch return;
        write_json_string(writer, formatted) catch return;
        writer.writeAll("}\n") catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    /// Format message with arguments into fixed buffer
    fn format_message(self: *OutputEmitter, comptime message: []const u8, args: anytype) []const u8 {
        const result = std.fmt.bufPrint(&self.message_buffer, message, args) catch blk: {
            // Fallback to original message if formatting fails
            const len = @min(message.len, self.message_buffer.len - 1);
            @memcpy(self.message_buffer[0..len], message[0..len]);
            break :blk self.message_buffer[0..len];
        };

        assert(result.len <= self.message_buffer.len);
        assert(@intFromPtr(result.ptr) >= @intFromPtr(&self.message_buffer[0]));
        assert(@intFromPtr(result.ptr) < @intFromPtr(&self.message_buffer[0]) + self.message_buffer.len);

        return result;
    }

    fn has_trailing_newline(text: []const u8) bool {
        assert(text.len > 0);
        return text[text.len - 1] == '\n';
    }

    /// Write colored text to stdout
    fn write_colored_to_stdout(self: *OutputEmitter, color_code: []const u8, text: []const u8) void {
        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll(color_code) catch return;
        writer.writeAll(text) catch return;
        writer.writeAll("\x1b[0m") catch return; // Reset color
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    /// Write colored text to stderr.
    /// `tag` is an optional prefix (empty when verbose is off); placed
    /// inside the color span so the label inherits the level color.
    fn write_colored_to_stderr(
        self: *OutputEmitter,
        color_code: []const u8,
        tag: []const u8,
        text: []const u8,
    ) void {
        assert(tag.len <= 16);

        var writer_state: std.Io.Writer = .fixed(&self.stderr_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll(color_code) catch return;
        if (tag.len > 0) writer.writeAll(tag) catch return;
        writer.writeAll(text) catch return;
        writer.writeAll("\x1b[0m") catch return; // Reset color
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stderr_buffer(writer_state.buffered());
    }

    /// Write plain text to stdout
    fn write_plain_to_stdout(self: *OutputEmitter, text: []const u8) void {
        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll(text) catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    /// Write plain text to stderr.
    /// `tag` is an optional prefix (empty when verbose is off).
    fn write_plain_to_stderr(self: *OutputEmitter, tag: []const u8, text: []const u8) void {
        assert(tag.len <= 16);

        var writer_state: std.Io.Writer = .fixed(&self.stderr_buffer);
        const writer: *std.Io.Writer = &writer_state;

        if (tag.len > 0) writer.writeAll(tag) catch return;
        writer.writeAll(text) catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stderr_buffer(writer_state.buffered());
    }

    /// Flush stdout buffer to system
    fn flush_stdout_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self; // Buffer is not used after writing
        assert(content.len <= io_buffer_size_bytes);

        std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), content) catch return;
    }

    /// Flush stderr buffer to system
    fn flush_stderr_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self; // Buffer is not used after writing
        assert(content.len <= io_buffer_size_bytes);

        std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), content) catch return;
    }

    comptime {
        const emitter_size = @sizeOf(OutputEmitter);
        assert(emitter_size >= 1024); // Must contain buffers
        assert(emitter_size <= 32 * 1024); // Not too large
    }
};

/// JSON field for structured output
pub const JsonField = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: ?[]const u8, // null represents JSON null
        number: i64,
        boolean: bool,
        array_strings: []const []const u8,
    };

    comptime {
        assert(@sizeOf(JsonField) <= 64); // Keep reasonably small
        assert(@alignOf(JsonField) >= 1); // Must be aligned
    }
};

/// Stderr label prefix for diagnostic messages.
/// Why empty by default: the operator default is to rely on color alone
/// (red ≡ error, yellow ≡ warn). Labels add visual noise that's only
/// useful when reading logs without color, e.g. captured to a file. The
/// label appears only when `--verbose` (or higher) is active, so it's an
/// opt-in clarity aid for debugging — not a default decoration.
fn stderr_level_tag(level: MessageLevel) []const u8 {
    if (!debug_enabled()) return "";
    return switch (level) {
        .warning => "[warn] ",
        .error_recoverable => "[error] ",
        .error_fatal => "[fatal] ",
        // success/info do not write to stderr from emit_message; defensive empty.
        .success, .info => "",
    };
}

comptime {
    // Pair assertion: every tag fits the buffer slack used by callers.
    assert("[warn] ".len <= 16);
    assert("[error] ".len <= 16);
    assert("[fatal] ".len <= 16);
}

/// Get ANSI color code for message level
fn get_color_code(level: MessageLevel) []const u8 {
    return switch (level) {
        .success => "\x1b[32m", // Green
        .info => "\x1b[37m", // White
        .warning => "\x1b[33m", // Yellow
        .error_recoverable => "\x1b[31m", // Red
        .error_fatal => "\x1b[91m", // Bright red
    };
}

fn write_json_string(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');

    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try writer.writeAll("\\u00");
                    try writer.writeByte(json_hex_digits[byte >> 4]);
                    try writer.writeByte(json_hex_digits[byte & 0x0f]);
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }

    try writer.writeByte('"');
}

fn write_json_string_array(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');

    for (items, 0..) |item, index| {
        assert(item.len < 256);

        if (index > 0) {
            try writer.writeByte(',');
        }

        try write_json_string(writer, item);
    }

    try writer.writeByte(']');
}

comptime {
    for (@typeInfo(MessageLevel).@"enum".fields) |field| {
        const level: MessageLevel = @enumFromInt(field.value);
        const color = get_color_code(level);
        assert(color.len >= 4); // Minimum ANSI sequence
        assert(color.len <= 8); // Maximum reasonable length
    }
}

/// Global output emitter instance.
/// The color default is never_use_color — init_global() must be called
/// before any output to resolve the actual color mode.
var global_emitter_storage: OutputEmitter = OutputEmitter.init(.{
    .mode = .human_readable,
    .color = .never_use_color,
});
var global_emitter_initialized: bool = false;
var global_emitter: ?*OutputEmitter = null;

/// Initialize global output emitter with configuration
fn init_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter != null) {
        std.debug.panic("Output emitter already initialized - multiple initialization is not allowed", .{});
    }

    global_emitter_storage = OutputEmitter.init(config);
    global_emitter_initialized = true;
    const emitter = &global_emitter_storage;

    global_emitter = emitter;

    assert(global_emitter_initialized);
    assert(global_emitter == emitter);
    return emitter;
}

/// Update global output emitter configuration
fn update_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter) |emitter| {
        emitter.* = OutputEmitter.init(config);
        return emitter;
    } else {
        return init_global(config);
    }
}

/// Get global output emitter instance
fn get_global() *OutputEmitter {
    return global_emitter orelse std.debug.panic("Output emitter not initialized - call init_global() first", .{});
}

pub fn is_global_initialized() bool {
    return global_emitter_initialized;
}

fn get_global_config() ?OutputConfig {
    if (global_emitter) |emitter| {
        return emitter.config;
    }

    return null;
}

pub fn output_mode() OutputMode {
    return get_global().config.mode;
}

pub fn set_mode(config: OutputConfig) !void {
    _ = try update_global(config);
}

pub fn should_color() bool {
    const config = get_global_config() orelse return false;
    return config.color.should_use_color();
}

pub fn emit(level: MessageLevel, comptime message: []const u8, args: anytype) void {
    get_global().emit_message(level, message, args);
}

pub fn emit_json(payload: JsonPayload) void {
    switch (payload) {
        .object => |fields| get_global().emit_json_object(fields),
        .string_array => |array| get_global().emit_json_array(array.field_name, array.items),
        .text => |text| get_global().emit_text(text),
    }
}

pub fn exit_with(exit_code: ExitCode, comptime message: []const u8, args: anytype) noreturn {
    assert(exit_code != .success);
    get_global().emit_message(.error_fatal, message, args);
    std.process.exit(@intFromEnum(exit_code));
}

test "write_json_string escapes control characters" {
    const testing = std.testing;
    var buffer: [256]u8 = undefined;
    var writer_state: std.Io.Writer = .fixed(&buffer);
    const writer: *std.Io.Writer = &writer_state;

    try write_json_string(writer, "quote: \" newline: \n slash: \\");

    const expected = "\"quote: \\\" newline: \\n slash: \\\\\"";
    try testing.expectEqualStrings(expected, writer_state.buffered());
}

test "write_json_string_array escapes nested strings" {
    const testing = std.testing;
    var buffer: [256]u8 = undefined;
    var writer_state: std.Io.Writer = .fixed(&buffer);
    const writer: *std.Io.Writer = &writer_state;

    try write_json_string_array(writer, &.{ "a\"b", "c\\d" });

    const expected = "[\"a\\\"b\",\"c\\\\d\"]";
    try testing.expectEqualStrings(expected, writer_state.buffered());
}

// --- stderr_level_tag unit tests ---

test "stderr_level_tag: empty when verbose is none" {
    const testing = std.testing;
    const saved = verbose_level_global;
    defer verbose_level_global = saved;

    set_verbose_level(.none);
    try testing.expectEqualStrings("", stderr_level_tag(.warning));
    try testing.expectEqualStrings("", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("", stderr_level_tag(.error_fatal));
}

test "stderr_level_tag: labels appear at debug level and above" {
    const testing = std.testing;
    const saved = verbose_level_global;
    defer verbose_level_global = saved;

    set_verbose_level(.debug);
    try testing.expectEqualStrings("[warn] ", stderr_level_tag(.warning));
    try testing.expectEqualStrings("[error] ", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("[fatal] ", stderr_level_tag(.error_fatal));

    set_verbose_level(.trace);
    try testing.expectEqualStrings("[warn] ", stderr_level_tag(.warning));
    try testing.expectEqualStrings("[error] ", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("[fatal] ", stderr_level_tag(.error_fatal));
}

test "stderr_level_tag: success and info never get a label" {
    const testing = std.testing;
    const saved = verbose_level_global;
    defer verbose_level_global = saved;

    set_verbose_level(.trace);
    try testing.expectEqualStrings("", stderr_level_tag(.success));
    try testing.expectEqualStrings("", stderr_level_tag(.info));
}

// --- resolve_color_mode unit tests ---

test "resolve_color_mode: explicit always_use_color flag overrides everything" {
    const testing = std.testing;
    // Even with NO_COLOR, dumb term, no TTY — explicit flag wins.
    try testing.expectEqual(ColorMode.always_use_color, resolve_color_mode(.always_use_color, true, false, true));
    try testing.expectEqual(ColorMode.always_use_color, resolve_color_mode(.always_use_color, false, true, false));
}

test "resolve_color_mode: explicit never_use_color flag overrides everything" {
    const testing = std.testing;
    // Even with NO_COLOR unset, real terminal, TERM not dumb — explicit flag wins.
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.never_use_color, false, true, false));
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.never_use_color, true, false, true));
}

test "resolve_color_mode: auto with NO_COLOR set disables color" {
    const testing = std.testing;
    // NO_COLOR is set (any non-empty value) — color disabled.
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.auto, true, true, false));
}

test "resolve_color_mode: auto with TERM=dumb disables color" {
    const testing = std.testing;
    // TERM=dumb — color disabled.
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.auto, false, true, true));
}

test "resolve_color_mode: auto with stdout not a TTY disables color" {
    const testing = std.testing;
    // Piped/redirected output — color disabled.
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.auto, false, false, false));
}

test "resolve_color_mode: auto with all clear enables color" {
    const testing = std.testing;
    // No NO_COLOR, TERM is not dumb, stdout is a TTY — color enabled.
    try testing.expectEqual(ColorMode.always_use_color, resolve_color_mode(.auto, false, true, false));
}

test "resolve_color_mode: precedence: never flag wins over auto conditions" {
    const testing = std.testing;
    // never_use_color flag must override all auto-friendly conditions.
    try testing.expectEqual(ColorMode.never_use_color, resolve_color_mode(.never_use_color, false, true, false));
}

test "resolve_color_mode: precedence: always flag wins over auto conditions" {
    const testing = std.testing;
    // always_use_color flag must override all auto-unfriendly conditions.
    try testing.expectEqual(ColorMode.always_use_color, resolve_color_mode(.always_use_color, true, false, true));
}
