const std = @import("std");
const cli_spec = @import("spec.zig");

const assert = std.debug.assert;

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    DuplicateOption,
    MissingOptionValueSeparator,
    EmptyOptionValue,
    MissingRequiredArgument,
    EmptyArgument,
    UnexpectedArguments,
    TrailingOption,
    InvalidFlagValue,
    Overflow,
};

fn is_option_terminator(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--");
}

fn is_prefixed_option(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

fn flag_name(comptime field_name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "--";
        var index: usize = 0;
        while (std.mem.indexOfScalar(u8, field_name[index..], '_')) |underscore_index| {
            result = result ++ field_name[index..][0..underscore_index] ++ "-";
            index += underscore_index + 1;
        }
        return result ++ field_name[index..];
    }
}

fn split_attached_value(flag: []const u8, arg: []const u8) ParseError![]const u8 {
    assert(flag.len >= 3);
    assert(std.mem.startsWith(u8, arg, flag));

    const suffix = arg[flag.len..];
    if (suffix.len == 0) return error.MissingOptionValueSeparator;
    if (suffix[0] != '=') return error.MissingOptionValueSeparator;
    if (suffix.len == 1) return error.EmptyOptionValue;
    return suffix[1..];
}

fn positional_start(comptime Args: type) usize {
    comptime {
        const fields = std.meta.fields(Args);
        for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, "--")) {
                assert(field.type == void);
                return index + 1;
            }
        }
        return fields.len;
    }
}

fn assign_default_positionals(comptime Args: type, result: *Args, parsed_count: usize) ParseError!void {
    const fields = comptime std.meta.fields(Args);
    const positional_first = comptime positional_start(Args);
    inline for (fields, 0..) |field, index| {
        if (index >= positional_first and index - positional_first >= parsed_count) {
            switch (@typeInfo(field.type)) {
                .optional => @field(result, field.name) = null,
                else => return error.MissingRequiredArgument,
            }
        }
    }
}

fn parse_value(comptime T: type, value: []const u8) ParseError!T {
    if (value.len == 0) return error.EmptyArgument;
    return switch (@typeInfo(T)) {
        .bool => error.UnknownFlag,
        .optional => |optional| try parse_value(optional.child, value),
        else => {
            if (T == []const u8) return value;
            if (@typeInfo(T) == .@"enum") {
                return std.meta.stringToEnum(T, value) orelse error.UnknownFlag;
            }
            if (@typeInfo(T) == .int) {
                comptime assert(@typeInfo(T).int.signedness == .unsigned);
                return std.fmt.parseUnsigned(T, value, 10) catch |err| switch (err) {
                    error.InvalidCharacter => error.InvalidFlagValue,
                    error.Overflow => error.Overflow,
                };
            }
            if (@hasDecl(T, "parse_flag_value")) {
                const parse_flag_value: fn ([]const u8) ParseError!T = T.parse_flag_value;
                return parse_flag_value(value) catch |err| switch (err) {
                    error.InvalidFlagValue => error.InvalidFlagValue,
                    error.Overflow => error.Overflow,
                    else => error.InvalidFlagValue,
                };
            }
            @compileError("unsupported CLI value type: " ++ @typeName(T));
        },
    };
}

fn parse_named(comptime Args: type, result: *Args, counts: anytype, arg: []const u8) ParseError!bool {
    const fields = comptime std.meta.fields(Args);
    const positional_first = comptime positional_start(Args);
    inline for (fields, 0..) |field, index| {
        if (comptime index < positional_first and !std.mem.eql(u8, field.name, "--")) {
            const flag = comptime flag_name(field.name);
            if (std.mem.startsWith(u8, arg, flag)) {
                @field(counts, field.name) += 1;
                if (@field(counts, field.name) > 1) return error.DuplicateOption;

                switch (@typeInfo(field.type)) {
                    .bool => {
                        if (!std.mem.eql(u8, arg, flag)) return error.MissingOptionValueSeparator;
                        @field(result, field.name) = true;
                    },
                    .optional => {
                        const value = try split_attached_value(flag, arg);
                        @field(result, field.name) = try parse_value(field.type, value);
                    },
                    else => {
                        const value = try split_attached_value(flag, arg);
                        @field(result, field.name) = try parse_value(field.type, value);
                    },
                }
                return true;
            }
        }
    }
    return false;
}

fn is_known_named(comptime Args: type, arg: []const u8) bool {
    const fields = comptime std.meta.fields(Args);
    const positional_first = comptime positional_start(Args);
    inline for (fields, 0..) |field, index| {
        if (comptime index < positional_first and !std.mem.eql(u8, field.name, "--")) {
            const flag = comptime flag_name(field.name);
            if (std.mem.eql(u8, arg, flag) or std.mem.startsWith(u8, arg, flag ++ "=")) return true;
        }
    }
    return false;
}

fn parse_args(comptime Args: type, args: []const []const u8) ParseError!Args {
    if (Args == void) {
        if (args.len > 0 and !(args.len == 1 and is_option_terminator(args[0]))) {
            return error.UnexpectedArguments;
        }
        return {};
    }

    comptime assert(@typeInfo(Args) == .@"struct");

    var result: Args = std.mem.zeroes(Args);

    var counts: std.enums.EnumFieldStruct(std.meta.FieldEnum(Args), u8, 0) = .{};
    var positional_count: usize = 0;
    var after_terminator = false;
    var extended_start: ?usize = null;

    for (args, 0..) |arg, arg_index| {
        if (!after_terminator and is_option_terminator(arg)) {
            after_terminator = true;
            const fields = comptime std.meta.fields(Args);
            const positional_first = comptime positional_start(Args);
            const positional_len = comptime fields.len - positional_first;
            if (positional_len == 1 and fields[positional_first].type == []const []const u8) {
                extended_start = arg_index + 1;
                break;
            }
            continue;
        }

        if (!after_terminator and is_prefixed_option(arg)) {
            if (positional_count > 0) {
                if (is_known_named(Args, arg)) return error.TrailingOption;
                return error.UnknownFlag;
            }
            if (try parse_named(Args, &result, &counts, arg)) continue;
            return error.UnknownFlag;
        }

        const fields = comptime std.meta.fields(Args);
        const positional_first = comptime positional_start(Args);
        const positional_len = comptime fields.len - positional_first;
        if (positional_count >= positional_len) return error.UnexpectedArguments;

        if (positional_len == 0) return error.UnexpectedArguments;
        if (positional_len == 1 and fields[positional_first].type == []const []const u8) {
            return error.UnexpectedArguments;
        }
        switch (positional_count) {
            inline 0...positional_len - 1 => |index| {
                const field = fields[positional_first + index];
                @field(result, field.name) = try parse_value(field.type, arg);
            },
            else => unreachable,
        }
        positional_count += 1;
    }

    const fields = comptime std.meta.fields(Args);
    const positional_first = comptime positional_start(Args);
    const positional_len = comptime fields.len - positional_first;
    if (positional_len == 1 and fields[positional_first].type == []const []const u8) {
        const field = fields[positional_first];
        if (extended_start) |start| {
            @field(result, field.name) = args[start..];
            positional_count = 1;
        } else {
            return error.MissingRequiredArgument;
        }
    }

    try assign_default_positionals(Args, &result, positional_count);
    return result;
}

fn union_payload(comptime Commands: type, comptime tag: std.meta.Tag(Commands)) type {
    const name = @tagName(tag);
    inline for (@typeInfo(Commands).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    unreachable;
}

pub fn parseCommand(comptime Commands: type, command_name: []const u8, args: []const []const u8) ParseError!Commands {
    comptime assert(@typeInfo(Commands) == .@"union");

    const UnionTag = std.meta.Tag(Commands);
    const union_tag = if (cli_spec.Command.parse(command_name)) |command|
        std.meta.stringToEnum(UnionTag, @tagName(command)) orelse return error.UnknownCommand
    else
        std.meta.stringToEnum(UnionTag, command_name) orelse return error.UnknownCommand;
    return switch (union_tag) {
        inline else => |tag| blk: {
            const field_name = @tagName(tag);
            const FieldType = union_payload(Commands, tag);
            break :blk @unionInit(Commands, field_name, try parse_args(FieldType, args));
        },
    };
}

test "typed parser handles flags and positionals" {
    const parsed = try parseCommand(cli_spec.CLIArgs, "install", &.{ "--zls", "0.16.0" });
    try std.testing.expect(parsed.install.zls);
    try std.testing.expectEqualStrings("0.16.0", parsed.install.version);
}

test "typed parser enforces attached values" {
    try std.testing.expectError(error.MissingOptionValueSeparator, parseCommand(cli_spec.CLIArgs, "env", &.{"--shell"}));
    const parsed = try parseCommand(cli_spec.CLIArgs, "env", &.{"--shell=zsh"});
    try std.testing.expectEqualStrings("zsh", parsed.env.shell.?);
}

test "typed parser supports ints enums custom values and extended args" {
    const Mode = enum { fast, safe };
    const Custom = struct {
        value: []const u8,

        pub fn parse_flag_value(value: []const u8) ParseError!@This() {
            if (!std.mem.eql(u8, value, "ok")) return error.InvalidFlagValue;
            return .{ .value = value };
        }
    };
    const Commands = union(enum) {
        demo: struct {
            count: u8,
            mode: Mode,
            custom: Custom,
            @"--": void,
            rest: []const []const u8,
        },
    };

    const parsed = try parseCommand(Commands, "demo", &.{
        "--count=7",
        "--mode=fast",
        "--custom=ok",
        "--",
        "-not-a-flag",
        "tail",
    });
    try std.testing.expectEqual(@as(u8, 7), parsed.demo.count);
    try std.testing.expectEqual(Mode.fast, parsed.demo.mode);
    try std.testing.expectEqualStrings("ok", parsed.demo.custom.value);
    try std.testing.expectEqual(@as(usize, 2), parsed.demo.rest.len);
    try std.testing.expectEqualStrings("-not-a-flag", parsed.demo.rest[0]);
}
