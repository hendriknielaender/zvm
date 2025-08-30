const std = @import("std");

/// ByteSize represents a size value with a suffix (e.g., 10KiB, 5MiB)
pub const ByteSize = struct {
    value: u64,

    pub fn bytes(self: ByteSize) u64 {
        return self.value;
    }
};

/// Resolve command aliases to their full names
fn resolve_alias(cmd: []const u8) []const u8 {
    if (std.mem.eql(u8, cmd, "ls")) return "list";
    if (std.mem.eql(u8, cmd, "i")) return "install";
    if (std.mem.eql(u8, cmd, "u")) return "use";
    if (std.mem.eql(u8, cmd, "rm")) return "remove";
    if (std.mem.eql(u8, cmd, "-v")) return "version";
    return cmd;
}

/// Parse command line arguments into a tagged union
/// This is a simplified version that works with Zig 0.14.1
pub fn parse(arguments_iterator: *std.process.ArgIterator, comptime Union: type) Union {
    const type_info = @typeInfo(Union);
    const union_info = switch (type_info) {
        .@"union" => |u| u,
        else => @compileError("Expected a union type"),
    };

    // Skip the program name
    _ = arguments_iterator.next();

    // Get the command
    const command_str = arguments_iterator.next() orelse fatal("no command specified", .{});

    // Map aliases to full command names
    const resolved_command = resolve_alias(command_str);

    // Check for help flag first
    const is_help_long = std.mem.eql(u8, resolved_command, "--help");
    const is_help_short = std.mem.eql(u8, resolved_command, "-h");
    const is_help_cmd = std.mem.eql(u8, resolved_command, "help");

    if (is_help_long) {
        if (@hasField(Union, "help")) {
            return @unionInit(Union, "help", .{});
        }
        print_help(Union);
        std.process.exit(0);
    }
    if (is_help_short) {
        if (@hasField(Union, "help")) {
            return @unionInit(Union, "help", .{});
        }
        print_help(Union);
        std.process.exit(0);
    }
    if (is_help_cmd) {
        if (@hasField(Union, "help")) {
            return @unionInit(Union, "help", .{});
        }
        print_help(Union);
        std.process.exit(0);
    }

    // Check for version
    const is_version_long = std.mem.eql(u8, resolved_command, "--version");
    const is_version_cmd = std.mem.eql(u8, resolved_command, "version");
    const is_version_short = std.mem.eql(u8, resolved_command, "-v");

    if (is_version_long) {
        if (@hasField(Union, "version")) {
            return @unionInit(Union, "version", .{});
        }
    }
    if (is_version_cmd) {
        if (@hasField(Union, "version")) {
            return @unionInit(Union, "version", .{});
        }
    }
    if (is_version_short) {
        if (@hasField(Union, "version")) {
            // Parse version flags
            var verbose = false;
            while (arguments_iterator.next()) |arg| {
                if (std.mem.eql(u8, arg, "--verbose")) {
                    verbose = true;
                }
            }
            return @unionInit(Union, "version", .{ .verbose = verbose });
        }
    }

    // Match command to union tag
    inline for (union_info.fields) |field| {
        if (match_command(resolved_command, field.name)) {
            return parse_command(Union, field, arguments_iterator);
        }
    }

    fatal("unknown command: {s}", .{command_str});
}

fn match_command(input: []const u8, comptime field_name: []const u8) bool {
    // Direct match
    if (std.mem.eql(u8, input, field_name)) return true;

    // Match with underscores replaced by dashes
    const dash_name = comptime blk: {
        var buf: [field_name.len]u8 = undefined;
        for (field_name, 0..) |c, i| {
            buf[i] = if (c == '_') '-' else c;
        }
        break :blk buf;
    };
    return std.mem.eql(u8, input, &dash_name);
}

fn parse_command(
    comptime Union: type,
    comptime field: std.builtin.Type.UnionField,
    arguments_iterator: *std.process.ArgIterator,
) Union {
    const FieldType = field.type;

    // For empty structs (like Help)
    if (@sizeOf(FieldType) == 0) {
        return @unionInit(Union, field.name, .{});
    }

    // Parse the specific command's arguments
    // SAFETY: This undefined value is immediately initialized field-by-field in the following loop
    var result: FieldType = undefined;

    // Initialize fields with defaults
    inline for (std.meta.fields(FieldType)) |arg_field| {
        if (arg_field.default_value_ptr) |default_val| {
            @field(result, arg_field.name) = @as(*const arg_field.type, @ptrCast(@alignCast(default_val))).*;
        } else if (arg_field.type == bool) {
            @field(result, arg_field.name) = false;
        } else if (@typeInfo(arg_field.type) == .optional) {
            @field(result, arg_field.name) = null;
        } else if (@typeInfo(arg_field.type) == .@"struct") {
            // Initialize nested structs (like positional arguments)
            // SAFETY: This undefined value is immediately initialized field-by-field in the following loop
            var nested: arg_field.type = undefined;
            inline for (std.meta.fields(arg_field.type)) |nested_field| {
                if (@typeInfo(nested_field.type) == .optional) {
                    @field(nested, nested_field.name) = null;
                } else if (nested_field.default_value_ptr) |default_val| {
                    @field(nested, nested_field.name) = @as(*const nested_field.type, @ptrCast(@alignCast(default_val))).*;
                }
            }
            @field(result, arg_field.name) = nested;
        }
    }

    // Parse remaining arguments
    while (arguments_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            // Named argument
            const equals_idx = std.mem.indexOf(u8, arg, "=");
            const flag = if (equals_idx) |idx| arg[0..idx] else arg;
            const value = if (equals_idx) |idx| arg[idx + 1 ..] else null;

            // Try to match the flag
            var found = false;
            inline for (std.meta.fields(FieldType)) |arg_field| {
                if (arg_field.name.len > 0) {
                    if (arg_field.name[0] != '_') {
                        if (@typeInfo(arg_field.type) != .@"struct") {
                            const flag_name = "--" ++ arg_field.name;
                            const flag_name_dashes = compute_flag_name(arg_field.name);

                            if (std.mem.eql(u8, flag, flag_name)) {
                                found = true;
                                parse_field_value(FieldType, &result, arg_field.name, value, arguments_iterator);
                                break;
                            }
                            if (std.mem.eql(u8, flag, flag_name_dashes)) {
                                found = true;
                                parse_field_value(FieldType, &result, arg_field.name, value, arguments_iterator);
                                break;
                            }
                        }
                    }
                }
            }

            if (!found) {
                fatal("unknown flag: {s}", .{flag});
            }
        } else {
            // Positional argument
            if (@hasField(FieldType, "positional")) {
                var handled = false;
                const positional_ptr = &@field(result, "positional");
                inline for (std.meta.fields(@TypeOf(positional_ptr.*))) |pos_field| {
                    if (@typeInfo(pos_field.type) == .optional) {
                        if (@field(positional_ptr.*, pos_field.name) == null) {
                            @field(positional_ptr.*, pos_field.name) = arg;
                            handled = true;
                            break;
                        }
                    } else if (pos_field.type == []const u8) {
                        @field(positional_ptr.*, pos_field.name) = arg;
                        handled = true;
                        break;
                    }
                }
                if (!handled) {
                    fatal("too many positional arguments", .{});
                }
            } else {
                fatal("unexpected positional argument: {s}", .{arg});
            }
        }
    }

    // Validate required positional arguments
    if (@hasField(FieldType, "positional")) {
        inline for (std.meta.fields(@TypeOf(@field(result, "positional")))) |pos_field| {
            if (@typeInfo(pos_field.type) != .optional) {
                // Required field - check if it's set
                if (pos_field.type == []const u8) {
                    if (@field(@field(result, "positional"), pos_field.name).len == 0) {
                        fatal("missing required argument: {s}", .{pos_field.name});
                    }
                }
            }
        }
    }

    return @unionInit(Union, field.name, result);
}

fn compute_flag_name(comptime name: []const u8) *const [name.len + 2]u8 {
    const result = comptime blk: {
        var buf: [name.len + 2]u8 = undefined;
        buf[0] = '-';
        buf[1] = '-';
        for (name, 0..) |c, i| {
            buf[i + 2] = if (c == '_') '-' else c;
        }
        break :blk buf;
    };
    return &result;
}

fn parse_field_value(
    comptime T: type,
    result: *T,
    comptime field_name: []const u8,
    value: ?[]const u8,
    arguments_iterator: *std.process.ArgIterator,
) void {
    const field_type = @TypeOf(@field(result.*, field_name));

    if (field_type == bool) {
        @field(result, field_name) = true;
    } else if (@typeInfo(field_type) == .optional) {
        const child_type = @typeInfo(field_type).optional.child;

        const val = value orelse arguments_iterator.next() orelse
            fatal("flag --{s} requires a value", .{field_name});

        if (child_type == []const u8) {
            @field(result, field_name) = val;
        } else if (child_type == u32) {
            @field(result, field_name) = std.fmt.parseInt(u32, val, 10) catch
                fatal("invalid u32 value for --{s}: {s}", .{ field_name, val });
        } else if (child_type == u64) {
            @field(result, field_name) = std.fmt.parseInt(u64, val, 10) catch
                fatal("invalid u64 value for --{s}: {s}", .{ field_name, val });
        } else if (child_type == u128) {
            @field(result, field_name) = std.fmt.parseInt(u128, val, 10) catch
                fatal("invalid u128 value for --{s}: {s}", .{ field_name, val });
        } else if (child_type == u8) {
            @field(result, field_name) = std.fmt.parseInt(u8, val, 10) catch
                fatal("invalid u8 value for --{s}: {s}", .{ field_name, val });
        } else {
            @compileError("unsupported optional field type: " ++ @typeName(child_type));
        }
    } else if (field_type == []const u8) {
        const val = value orelse arguments_iterator.next() orelse
            fatal("flag --{s} requires a value", .{field_name});
        @field(result, field_name) = val;
    } else {
        @compileError("unsupported field type: " ++ @typeName(field_type));
    }
}

fn print_help(comptime Union: type) void {
    if (@hasDecl(Union, "help_text")) {
        std.debug.print("{s}\n", .{Union.help_text});
    } else {
        std.debug.print("Available commands:\n", .{});
        inline for (@typeInfo(Union).@"union".fields) |field| {
            std.debug.print("  {s}\n", .{field.name});
        }
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}
