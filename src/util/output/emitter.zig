const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const exit_code = @import("exit_code.zig");
const json = @import("json.zig");
const limits = @import("../../memory/limits.zig");
const mode = @import("mode.zig");
const assert = std.debug.assert;

const ColorMode = mode.ColorMode;
const ExitCode = exit_code.ExitCode;
const JsonArrayFieldName = json.JsonArrayFieldName;
const JsonField = json.JsonField;
const JsonPayload = json.JsonPayload;
const OutputConfig = mode.OutputConfig;
const OutputMode = mode.OutputMode;

const io_buffer_size_bytes = limits.limits.io_buffer_size_maximum;
const max_json_object_fields = 16;
const max_message_length_bytes = 2048;

comptime {
    assert(io_buffer_size_bytes >= 1024);
    assert(max_message_length_bytes >= 256);
    assert(max_message_length_bytes <= io_buffer_size_bytes);
    assert(max_message_length_bytes + 16 <= io_buffer_size_bytes);
    assert(max_json_object_fields >= 4);
    assert(max_json_object_fields <= 32);
}

pub const MessageLevel = enum {
    success,
    info,
    warning,
    error_recoverable,
    error_fatal,

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
        assert(MessageLevel.success.to_string().len <= 16);
        assert(MessageLevel.error_fatal.to_string().len <= 16);
    }
};

const OutputEmitter = struct {
    config: OutputConfig,
    stdout_buffer: [io_buffer_size_bytes]u8,
    stderr_buffer: [io_buffer_size_bytes]u8,
    message_buffer: [max_message_length_bytes]u8,

    fn init(config: OutputConfig) OutputEmitter {
        config.validate();

        return .{
            .config = config,
            .stdout_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .stderr_buffer = std.mem.zeroes([io_buffer_size_bytes]u8),
            .message_buffer = std.mem.zeroes([max_message_length_bytes]u8),
        };
    }

    fn emit_message(
        self: *OutputEmitter,
        level: MessageLevel,
        comptime message: []const u8,
        args: anytype,
    ) void {
        switch (self.config.mode) {
            .silent_errors_only => {
                if (level == .error_recoverable or level == .error_fatal) {
                    self.emit_to_stderr_plain(level, message, args);
                }
            },
            .plain => {
                if (level == .warning or
                    level == .error_recoverable or
                    level == .error_fatal)
                {
                    self.emit_to_stderr_plain(level, message, args);
                }
            },
            .machine_json => self.emit_json_message(level, message, args),
            .human_readable => {
                if (level == .warning or
                    level == .error_recoverable or
                    level == .error_fatal)
                {
                    self.emit_to_stderr_colored(level, message, args);
                } else {
                    self.emit_to_stdout_colored(level, message, args);
                }
            },
        }
    }

    fn emit_fatal(
        self: *OutputEmitter,
        code: ExitCode,
        comptime message: []const u8,
        args: anytype,
    ) noreturn {
        assert(code != .success);
        self.emit_message(.error_fatal, message, args);
        std.process.exit(@intFromEnum(code));
    }

    fn emit_json_array(
        self: *OutputEmitter,
        comptime field_name: JsonArrayFieldName,
        items: []const []const u8,
    ) void {
        const field_name_text = comptime field_name.text();
        assert(field_name_text.len > 0);
        assert(field_name_text.len < 64);
        assert(items.len <= limits.limits.versions_maximum);

        if (self.config.mode != .machine_json) return;

        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll("{\"") catch return;
        writer.writeAll(field_name_text) catch return;
        writer.writeAll("\":[") catch return;

        for (items, 0..) |item, index| {
            assert(item.len > 0);
            assert(item.len < 256);

            if (index > 0) writer.writeAll(",") catch return;
            json.write_json_string(writer, item) catch return;
        }

        writer.writeAll("]}\n") catch return;
        self.flush_stdout_buffer(writer_state.buffered());
    }

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

            if (index > 0) writer.writeAll(",") catch return;
            json.write_json_string(writer, field.key) catch return;
            writer.writeAll(":") catch return;
            self.emit_json_object_value(writer, field.value);
        }

        writer.writeAll("}\n") catch return;
        self.flush_stdout_buffer(writer_state.buffered());
    }

    fn emit_json_object_value(
        self: *OutputEmitter,
        writer: *std.Io.Writer,
        value: JsonField.Value,
    ) void {
        _ = self;
        switch (value) {
            .string => |string| {
                if (string) |text| {
                    assert(text.len <= io_buffer_size_bytes);
                    json.write_json_string(writer, text) catch return;
                } else {
                    writer.writeAll("null") catch return;
                }
            },
            .number => |number| {
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return;
                writer.writeAll(text) catch return;
            },
            .boolean => |value_bool| {
                if (value_bool) {
                    writer.writeAll("true") catch return;
                } else {
                    writer.writeAll("false") catch return;
                }
            },
            .array_strings => |items| json.write_json_string_array(writer, items) catch return,
        }
    }

    fn emit_text(self: *OutputEmitter, text: []const u8) void {
        assert(text.len > 0);
        assert(text.len <= io_buffer_size_bytes);

        switch (self.config.mode) {
            .silent_errors_only => return,
            .human_readable, .plain => self.write_plain_to_stdout(text),
            .machine_json => {
                const fields = [_]JsonField{
                    .{ .key = "text", .value = .{ .string = text } },
                };
                self.emit_json_object(&fields);
            },
        }
    }

    fn emit_to_stdout_colored(
        self: *OutputEmitter,
        level: MessageLevel,
        comptime message: []const u8,
        args: anytype,
    ) void {
        const formatted = self.format_message(message, args);

        if (self.config.color.should_use_color()) {
            self.write_colored_to_stdout(get_color_code(level), formatted);
        } else {
            self.write_plain_to_stdout(formatted);
        }
    }

    fn emit_to_stderr_colored(
        self: *OutputEmitter,
        level: MessageLevel,
        comptime message: []const u8,
        args: anytype,
    ) void {
        const formatted = self.format_message(message, args);
        const tag = stderr_level_tag(level);

        if (self.config.color.should_use_color()) {
            self.write_colored_to_stderr(get_color_code(level), tag, formatted);
        } else {
            self.write_plain_to_stderr(tag, formatted);
        }
    }

    fn emit_to_stderr_plain(
        self: *OutputEmitter,
        level: MessageLevel,
        comptime message: []const u8,
        args: anytype,
    ) void {
        self.write_plain_to_stderr(stderr_level_tag(level), self.format_message(message, args));
    }

    fn emit_json_message(
        self: *OutputEmitter,
        level: MessageLevel,
        comptime message: []const u8,
        args: anytype,
    ) void {
        const formatted = self.format_message(message, args);

        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll("{\"level\":") catch return;
        json.write_json_string(writer, level.to_string()) catch return;
        writer.writeAll(",\"message\":") catch return;
        json.write_json_string(writer, formatted) catch return;
        writer.writeAll("}\n") catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    fn format_message(
        self: *OutputEmitter,
        comptime message: []const u8,
        args: anytype,
    ) []const u8 {
        const result = std.fmt.bufPrint(&self.message_buffer, message, args) catch blk: {
            const length = @min(message.len, self.message_buffer.len - 1);
            @memcpy(self.message_buffer[0..length], message[0..length]);
            break :blk self.message_buffer[0..length];
        };

        assert(result.len <= self.message_buffer.len);
        assert(@intFromPtr(result.ptr) >= @intFromPtr(&self.message_buffer[0]));
        assert(@intFromPtr(result.ptr) < @intFromPtr(&self.message_buffer[0]) +
            self.message_buffer.len);
        return result;
    }

    fn write_colored_to_stdout(
        self: *OutputEmitter,
        color_code: []const u8,
        text: []const u8,
    ) void {
        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll(color_code) catch return;
        writer.writeAll(text) catch return;
        writer.writeAll("\x1b[0m") catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

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
        writer.writeAll("\x1b[0m") catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stderr_buffer(writer_state.buffered());
    }

    fn write_plain_to_stdout(self: *OutputEmitter, text: []const u8) void {
        var writer_state: std.Io.Writer = .fixed(&self.stdout_buffer);
        const writer: *std.Io.Writer = &writer_state;

        writer.writeAll(text) catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stdout_buffer(writer_state.buffered());
    }

    fn write_plain_to_stderr(self: *OutputEmitter, tag: []const u8, text: []const u8) void {
        assert(tag.len <= 16);

        var writer_state: std.Io.Writer = .fixed(&self.stderr_buffer);
        const writer: *std.Io.Writer = &writer_state;

        if (tag.len > 0) writer.writeAll(tag) catch return;
        writer.writeAll(text) catch return;
        if (!has_trailing_newline(text)) writer.writeByte('\n') catch return;

        self.flush_stderr_buffer(writer_state.buffered());
    }

    fn flush_stdout_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self;
        assert(content.len <= io_buffer_size_bytes);
        std.Io.File.stdout().writeStreamingAll(
            std.Io.Threaded.global_single_threaded.io(),
            content,
        ) catch return;
    }

    fn flush_stderr_buffer(self: *OutputEmitter, content: []const u8) void {
        _ = self;
        assert(content.len <= io_buffer_size_bytes);
        std.Io.File.stderr().writeStreamingAll(
            std.Io.Threaded.global_single_threaded.io(),
            content,
        ) catch return;
    }

    comptime {
        const emitter_size = @sizeOf(OutputEmitter);
        assert(emitter_size >= 1024);
        assert(emitter_size <= 32 * 1024);
    }
};

fn has_trailing_newline(text: []const u8) bool {
    assert(text.len > 0);
    return text[text.len - 1] == '\n';
}

fn stderr_level_tag(level: MessageLevel) []const u8 {
    if (!diagnostics.debug_enabled()) return "";
    return switch (level) {
        .warning => "[warn] ",
        .error_recoverable => "[error] ",
        .error_fatal => "[fatal] ",
        .success, .info => "",
    };
}

comptime {
    assert("[warn] ".len <= 16);
    assert("[error] ".len <= 16);
    assert("[fatal] ".len <= 16);
}

fn get_color_code(level: MessageLevel) []const u8 {
    return switch (level) {
        .success => "\x1b[32m",
        .info => "\x1b[37m",
        .warning => "\x1b[33m",
        .error_recoverable => "\x1b[31m",
        .error_fatal => "\x1b[91m",
    };
}

comptime {
    for (@typeInfo(MessageLevel).@"enum".fields) |field| {
        const level: MessageLevel = @enumFromInt(field.value);
        const color = get_color_code(level);
        assert(color.len >= 4);
        assert(color.len <= 8);
    }
}

var global_emitter_storage: OutputEmitter = OutputEmitter.init(.{
    .mode = .human_readable,
    .color = .never_use_color,
});
var global_emitter_initialized: bool = false;
var global_emitter: ?*OutputEmitter = null;

fn init_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter != null) {
        std.debug.panic(
            "Output emitter already initialized - multiple initialization is not allowed",
            .{},
        );
    }

    global_emitter_storage = OutputEmitter.init(config);
    global_emitter_initialized = true;
    const emitter = &global_emitter_storage;
    global_emitter = emitter;

    assert(global_emitter_initialized);
    assert(global_emitter == emitter);
    return emitter;
}

fn update_global(config: OutputConfig) !*OutputEmitter {
    config.validate();

    if (global_emitter) |emitter| {
        emitter.* = OutputEmitter.init(config);
        return emitter;
    }

    return init_global(config);
}

fn get_global() *OutputEmitter {
    return global_emitter orelse std.debug.panic(
        "Output emitter not initialized - call init_global() first",
        .{},
    );
}

pub fn is_global_initialized() bool {
    return global_emitter_initialized;
}

pub fn output_mode() OutputMode {
    return get_global().config.mode;
}

pub fn set_mode(config: OutputConfig) !void {
    _ = try update_global(config);
}

pub fn emit(level: MessageLevel, comptime message: []const u8, args: anytype) void {
    get_global().emit_message(level, message, args);
}

pub fn emit_json(payload: JsonPayload) void {
    switch (payload) {
        .object => |fields| get_global().emit_json_object(fields),
        .string_array => |array| switch (array.field_name) {
            .installed => get_global().emit_json_array(.installed, array.items),
            .mirrors => get_global().emit_json_array(.mirrors, array.items),
        },
        .text => |text| get_global().emit_text(text),
    }
}

pub fn exit_with(code: ExitCode, comptime message: []const u8, args: anytype) noreturn {
    assert(code != .success);
    get_global().emit_fatal(code, message, args);
}

test "stderr_level_tag: empty when verbose is none" {
    const testing = std.testing;

    diagnostics.set_verbose_level(.none);
    try testing.expectEqualStrings("", stderr_level_tag(.warning));
    try testing.expectEqualStrings("", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("", stderr_level_tag(.error_fatal));
}

test "stderr_level_tag: labels appear at debug level and above" {
    const testing = std.testing;

    diagnostics.set_verbose_level(.debug);
    try testing.expectEqualStrings("[warn] ", stderr_level_tag(.warning));
    try testing.expectEqualStrings("[error] ", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("[fatal] ", stderr_level_tag(.error_fatal));

    diagnostics.set_verbose_level(.trace);
    try testing.expectEqualStrings("[warn] ", stderr_level_tag(.warning));
    try testing.expectEqualStrings("[error] ", stderr_level_tag(.error_recoverable));
    try testing.expectEqualStrings("[fatal] ", stderr_level_tag(.error_fatal));
}

test "stderr_level_tag: success and info never get a label" {
    const testing = std.testing;

    diagnostics.set_verbose_level(.trace);
    try testing.expectEqualStrings("", stderr_level_tag(.success));
    try testing.expectEqualStrings("", stderr_level_tag(.info));
}
