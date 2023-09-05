const std = @import("std");
const Command = @import("command.zig").Command;
const handleCommands = @import("command.zig").handleCommands;

const VERSION = "0.0.0";

const CommandData = struct {
    cmd: Command,
    params: ?[]const u8,
};

const CommandOption = struct {
    short_handle: ?[]const u8,
    handle: []const u8,
    cmd: Command,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.debug.print("Received args: {any}\n", .{args});

    const cmd_data = try parseArgs(args);
    try handleCommands(cmd_data.cmd, cmd_data.params);
}

fn parseArgs(args: []const []const u8) !CommandData {
    const options = getAvailableCommands();
    if (args.len < 2) return CommandData{ .cmd = Command.Unknown, .params = null };
    return findCommandInArgs(args[1..], options) orelse CommandData{ .cmd = Command.Unknown, .params = null };
}

fn getAvailableCommands() []const CommandOption {
    return &[_]CommandOption{
        CommandOption{ .short_handle = "ls", .handle = "list", .cmd = Command.List },
        CommandOption{ .short_handle = "i", .handle = "install", .cmd = Command.Install },
        CommandOption{ .short_handle = null, .handle = "--default", .cmd = Command.Default },
    };
}

fn findCommandInArgs(args: []const []const u8, options: []const CommandOption) ?CommandData {
    var i: usize = 0;
    for (args) |arg| {
        for (options) |option| {
            if ((option.short_handle != null and std.mem.eql(u8, arg, option.short_handle.?)) or
                std.mem.eql(u8, arg, option.handle))
            {
                const params = if (i + 1 < args.len) args[i + 1] else null;
                return CommandData{ .cmd = option.cmd, .params = params };
            }
        }
        i += 1; // Manually increment the index
    }
    return null;
}
