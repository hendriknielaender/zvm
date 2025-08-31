const std = @import("std");
const limits = @import("../memory/limits.zig");

const io_buffer_size_bytes = limits.limits.io_buffer_size_maximum;
const max_message_length_bytes = 2048;
const max_json_object_fields = 16;

comptime {
    std.debug.assert(io_buffer_size_bytes >= 1024);
    std.debug.assert(max_message_length_bytes >= 256);
    std.debug.assert(max_message_length_bytes <= io_buffer_size_bytes);
    std.debug.assert(max_json_object_fields >= 4);
    std.debug.assert(max_json_object_fields <= 32);
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

    comptime {
        std.debug.assert(@intFromEnum(ExitCode.success) == 0);
        std.debug.assert(@intFromEnum(ExitCode.resource_exhausted) < 16);
        std.debug.assert(@intFromEnum(ExitCode.resource_exhausted) >= @intFromEnum(ExitCode.success));
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

            // Default to invalid arguments for parsing/validation errors
            else => .invalid_arguments,
        };
    }
};

/// Output modes that determine formatting and destination
pub const OutputMode = enum {
    human_readable,
    machine_json,
    silent_errors_only,

    comptime {
        const mode_count = @typeInfo(OutputMode).@"enum".fields.len;
        std.debug.assert(mode_count == 3);
        std.debug.assert(mode_count >= 2);
        std.debug.assert(mode_count <= 8);
    }
};

/// Color mode for terminal output
pub const ColorMode = enum {
    never_use_color,
    always_use_color,

    pub fn should_use_color(self: ColorMode) bool {
        return switch (self) {
            .never_use_color => false,
            .always_use_color => true,
        };
    }

    comptime {
        std.debug.assert(@typeInfo(ColorMode).@"enum".fields.len == 2);
    }
};

/// Configuration for output behavior
pub const OutputConfig = struct {
    mode: OutputMode,
    color: ColorMode,

    pub fn validate(self: OutputConfig) void {
        // Positive assertions
        std.debug.assert(self.mode == .human_readable or
            self.mode == .machine_json or
            self.mode == .silent_errors_only);
        std.debug.assert(self.color == .never_use_color or
            self.color == .always_use_color);

        // Negative assertions - invalid combinations
        if (self.mode == .machine_json) {
            std.debug.assert(self.color == .never_use_color); // JSON never uses colors
        }
    }

    comptime {
        const config_size = @sizeOf(OutputConfig);
        std.debug.assert(config_size <= 16); // Keep config small
        std.debug.assert(config_size >= 2); // Must contain meaningful data
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
        std.debug.assert(@typeInfo(MessageLevel).@"enum".fields.len == 5);
        // Assert string lengths are reasonable
        std.debug.assert(MessageLevel.success.to_string().len <= 16);
        std.debug.assert(MessageLevel.error_fatal.to_string().len <= 16);
    }
};

/// Centralized output management
pub const OutputEmitter = struct {
    config: OutputConfig,
    stdout_buffer: [io_buffer_size_bytes]u8,
    stderr_buffer: [io_buffer_size_bytes]u8,
    message_buffer: [max_message_length_bytes]u8,

    pub fn init(config: OutputConfig) OutputEmitter {
        config.validate(); // Assert valid configuration

        return OutputEmitter{
            .config = config,
            .stdout_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .stderr_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .message_buffer = std.mem.zeroes([max_message_length_bytes]u8),
        };
    }

    /// Emit success message to appropriate stream
    pub fn emit_success(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(message.len < 1024); // Reasonable message length

        self.emit_message(.success, message, args);
    }

    /// Emit informational message
    pub fn emit_info(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(message.len < 4096);

        self.emit_message(.info, message, args);
    }

    /// Emit warning message to stderr
    pub fn emit_warning(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(message.len < 1024);

        self.emit_message(.warning, message, args);
    }

    /// Emit recoverable error to stderr
    pub fn emit_error(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        std.debug.assert(message.len > 0);
        std.debug.assert(message.len < 1024);

        self.emit_message(.error_recoverable, message, args);
    }

    /// Emit fatal error and terminate program
    pub fn emit_fatal(self: *OutputEmitter, exit_code: ExitCode, comptime message: []const u8, args: anytype) noreturn {
        std.debug.assert(message.len > 0);
        std.debug.assert(message.len < 1024);
        std.debug.assert(exit_code != .success); // Fatal errors never succeed

        self.emit_message(.error_fatal, message, args);
        std.process.exit(@intFromEnum(exit_code));
    }

    /// Emit JSON array of strings
    pub fn emit_json_array(self: *OutputEmitter, comptime field_name: []const u8, items: []const []const u8) void {
        std.debug.assert(field_name.len > 0);
        std.debug.assert(field_name.len < 64);
        std.debug.assert(items.len <= limits.limits.versions_maximum);

        if (self.config.mode != .machine_json) return;

        var stream = std.io.fixedBufferStream(&self.stdout_buffer);
        const writer = stream.writer();

        // Write JSON array with explicit error handling
        writer.writeAll("{\"") catch return;
        writer.writeAll(field_name) catch return;
        writer.writeAll("\":[") catch return;

        for (items, 0..) |item, index| {
            std.debug.assert(item.len > 0);
            std.debug.assert(item.len < 256); // Reasonable item length

            if (index > 0) {
                writer.writeAll(",") catch return;
            }
            writer.writeAll("\"") catch return;
            writer.writeAll(item) catch return;
            writer.writeAll("\"") catch return;
        }

        writer.writeAll("]}\n") catch return;

        // Flush to stdout
        self.flush_stdout_buffer(stream.getWritten());
    }

    /// Emit JSON key-value pairs
    pub fn emit_json_object(self: *OutputEmitter, fields: []const JsonField) void {
        std.debug.assert(fields.len > 0);
        std.debug.assert(fields.len <= max_json_object_fields);

        if (self.config.mode != .machine_json) return;

        var stream = std.io.fixedBufferStream(&self.stdout_buffer);
        const writer = stream.writer();

        writer.writeAll("{") catch return;

        for (fields, 0..) |field, index| {
            std.debug.assert(field.key.len > 0);
            std.debug.assert(field.key.len < 64);

            if (index > 0) {
                writer.writeAll(",") catch return;
            }

            writer.writeAll("\"") catch return;
            writer.writeAll(field.key) catch return;
            writer.writeAll("\":") catch return;

            switch (field.value) {
                .string => |s| {
                    if (s) |str| {
                        std.debug.assert(str.len < 256);
                        writer.writeAll("\"") catch return;
                        writer.writeAll(str) catch return;
                        writer.writeAll("\"") catch return;
                    } else {
                        writer.writeAll("null") catch return;
                    }
                },
                .number => |n| {
                    var buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
                    writer.writeAll(num_str) catch return;
                },
            }
        }

        writer.writeAll("}\n") catch return;

        self.flush_stdout_buffer(stream.getWritten());
    }

    // Private implementation methods

    /// Core message emission logic
    fn emit_message(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        switch (self.config.mode) {
            .silent_errors_only => {
                // Only emit errors in silent mode
                if (level == .error_recoverable or level == .error_fatal) {
                    self.emit_to_stderr_plain(message, args);
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

        if (self.config.color.should_use_color()) {
            const color_code = get_color_code(level);
            self.write_colored_to_stderr(color_code, formatted);
        } else {
            self.write_plain_to_stderr(formatted);
        }
    }

    /// Emit plain message to stderr
    fn emit_to_stderr_plain(self: *OutputEmitter, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);
        self.write_plain_to_stderr(formatted);
    }

    /// Emit JSON structured message
    fn emit_json_message(self: *OutputEmitter, level: MessageLevel, comptime message: []const u8, args: anytype) void {
        const formatted = self.format_message(message, args);

        var stream = std.io.fixedBufferStream(&self.stdout_buffer);
        const writer = stream.writer();

        writer.writeAll("{\"level\":\"") catch return;
        writer.writeAll(level.to_string()) catch return;
        writer.writeAll("\",\"message\":\"") catch return;
        writer.writeAll(formatted) catch return;
        writer.writeAll("\"}\n") catch return;

        self.flush_stdout_buffer(stream.getWritten());
    }

    /// Format message with arguments into fixed buffer
    fn format_message(self: *OutputEmitter, comptime message: []const u8, args: anytype) []const u8 {
        const result = std.fmt.bufPrint(&self.message_buffer, message, args) catch blk: {
            // Fallback to original message if formatting fails
            const len = @min(message.len, self.message_buffer.len - 1);
            @memcpy(self.message_buffer[0..len], message[0..len]);
            break :blk self.message_buffer[0..len];
        };

        std.debug.assert(result.len <= self.message_buffer.len);
        std.debug.assert(@intFromPtr(result.ptr) >= @intFromPtr(&self.message_buffer[0]));
        std.debug.assert(@intFromPtr(result.ptr) < @intFromPtr(&self.message_buffer[0]) + self.message_buffer.len);

        return result;
    }

    /// Write colored text to stdout
    fn write_colored_to_stdout(self: *OutputEmitter, color_code: []const u8, text: []const u8) void {
        var stream = std.io.fixedBufferStream(&self.stdout_buffer);
        const writer = stream.writer();

        writer.writeAll(color_code) catch return;
        writer.writeAll(text) catch return;
        writer.writeAll("\x1b[0m") catch return; // Reset color

        self.flush_stdout_buffer(stream.getWritten());
    }

    /// Write colored text to stderr
    fn write_colored_to_stderr(self: *OutputEmitter, color_code: []const u8, text: []const u8) void {
        var stream = std.io.fixedBufferStream(&self.stderr_buffer);
        const writer = stream.writer();

        writer.writeAll(color_code) catch return;
        writer.writeAll(text) catch return;
        writer.writeAll("\x1b[0m") catch return; // Reset color

        self.flush_stderr_buffer(stream.getWritten());
    }

    /// Write plain text to stdout
    fn write_plain_to_stdout(self: *OutputEmitter, text: []const u8) void {
        var stream = std.io.fixedBufferStream(&self.stdout_buffer);
        const writer = stream.writer();

        writer.writeAll(text) catch return;

        self.flush_stdout_buffer(stream.getWritten());
    }

    /// Write plain text to stderr
    fn write_plain_to_stderr(self: *OutputEmitter, text: []const u8) void {
        var stream = std.io.fixedBufferStream(&self.stderr_buffer);
        const writer = stream.writer();

        writer.writeAll(text) catch return;

        self.flush_stderr_buffer(stream.getWritten());
    }

    /// Flush stdout buffer to system
    fn flush_stdout_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self; // Buffer is not used after writing
        std.debug.assert(content.len <= io_buffer_size_bytes);

        const stdout = std.fs.File.stdout();
        stdout.writeAll(content) catch return;
    }

    /// Flush stderr buffer to system
    fn flush_stderr_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self; // Buffer is not used after writing
        std.debug.assert(content.len <= io_buffer_size_bytes);

        const stderr = std.fs.File.stderr();
        stderr.writeAll(content) catch return;
    }

    comptime {
        const emitter_size = @sizeOf(OutputEmitter);
        std.debug.assert(emitter_size >= 1024); // Must contain buffers
        std.debug.assert(emitter_size <= 32 * 1024); // Not too large
    }
};

/// JSON field for structured output
pub const JsonField = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: ?[]const u8, // null represents JSON null
        number: i64,
    };

    comptime {
        std.debug.assert(@sizeOf(JsonField) <= 64); // Keep reasonably small
        std.debug.assert(@alignOf(JsonField) >= 1); // Must be aligned
    }
};

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

comptime {
    for (@typeInfo(MessageLevel).@"enum".fields) |field| {
        const level: MessageLevel = @enumFromInt(field.value);
        const color = get_color_code(level);
        std.debug.assert(color.len >= 4); // Minimum ANSI sequence
        std.debug.assert(color.len <= 8); // Maximum reasonable length
    }
}

/// Global output emitter instance
var global_emitter: ?*OutputEmitter = null;

/// Initialize global output emitter with configuration
pub fn init_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter != null) {
        std.debug.panic("Output emitter already initialized - multiple initialization is not allowed", .{});
    }

    // Allocate on heap since this lives for entire program duration
    const emitter = try std.heap.page_allocator.create(OutputEmitter);
    emitter.* = OutputEmitter.init(config);

    global_emitter = emitter;

    std.debug.assert(global_emitter == emitter);
    return emitter;
}

/// Update global output emitter configuration
pub fn update_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter) |emitter| {
        emitter.* = OutputEmitter.init(config);
        return emitter;
    } else {
        return init_global(config);
    }
}

/// Get global output emitter instance
pub fn get_global() *OutputEmitter {
    return global_emitter orelse std.debug.panic("Output emitter not initialized - call init_global() first", .{});
}

pub fn success(comptime message: []const u8, args: anytype) void {
    get_global().emit_success(message, args);
}

pub fn info(comptime message: []const u8, args: anytype) void {
    get_global().emit_info(message, args);
}

pub fn warn(comptime message: []const u8, args: anytype) void {
    get_global().emit_warning(message, args);
}

pub fn err(comptime message: []const u8, args: anytype) void {
    get_global().emit_error(message, args);
}

pub fn fatal(exit_code: ExitCode, comptime message: []const u8, args: anytype) noreturn {
    get_global().emit_fatal(exit_code, message, args);
}

pub fn json_array(comptime field_name: []const u8, items: []const []const u8) void {
    get_global().emit_json_array(field_name, items);
}

pub fn json_object(fields: []const JsonField) void {
    get_global().emit_json_object(fields);
}
