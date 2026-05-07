const std = @import("std");
const limits = @import("../../memory/limits.zig");
const assert = std.debug.assert;

const io_buffer_size_bytes = limits.limits.io_buffer_size_maximum;
const max_message_length_bytes = 2048;

comptime {
    assert(io_buffer_size_bytes >= 1024);
    assert(max_message_length_bytes >= 256);
    assert(max_message_length_bytes <= io_buffer_size_bytes);
}

/// Verbosity level for diagnostic output. Set once at startup from the
/// `--verbose` / `--trace` global flag (or `ZVM_DEBUG` env var, for
/// backward compatibility) and read globally by `trace()` / `debug_enabled()`.
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

var verbose_level_global: VerboseLevel = .none;

pub fn set_verbose_level(level: VerboseLevel) void {
    assert(@intFromEnum(level) <= @intFromEnum(VerboseLevel.trace));
    verbose_level_global = level;
}

pub fn debug_enabled() bool {
    return verbose_level_global.at_least(.debug);
}

fn trace_enabled() bool {
    return verbose_level_global.at_least(.trace);
}

pub fn trace(comptime message: []const u8, args: anytype) void {
    if (!trace_enabled()) return;
    emit_diagnostic_line("trace: ", message, args);
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
