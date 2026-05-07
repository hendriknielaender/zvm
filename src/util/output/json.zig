const std = @import("std");
const assert = std.debug.assert;

const json_hex_digits = "0123456789abcdef";

pub const JsonField = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: ?[]const u8,
        number: i64,
        boolean: bool,
        array_strings: []const []const u8,
    };

    comptime {
        assert(@sizeOf(JsonField) <= 64);
        assert(@alignOf(JsonField) >= 1);
    }
};

pub const JsonPayload = union(enum) {
    object: []const JsonField,
    string_array: StringArray,
    text: []const u8,

    pub const StringArray = struct {
        field_name: JsonArrayFieldName,
        items: []const []const u8,
    };
};

pub const JsonArrayFieldName = enum {
    installed,
    mirrors,

    pub fn text(self: JsonArrayFieldName) []const u8 {
        return @tagName(self);
    }
};

pub fn write_json_string(writer: anytype, text: []const u8) !void {
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

pub fn write_json_string_array(writer: anytype, items: []const []const u8) !void {
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
