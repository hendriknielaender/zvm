const std = @import("std");
const versions = @import("./versions.zig");
const Command = @import("command.zig").Command;
const handleCommands = @import("command.zig").handleCommands;

const VERSION = "0.0.0";

const CommandOption = struct {
    short_handle: ?[]const u8, // Short handle is optional
    handle: []const u8, // Long handle is mandatory
    cmd: Command,
};

fn parseArgs(args: []const []const u8) !Command {
    const options = [_]CommandOption{
        CommandOption{ .short_handle = "ls", .handle = "list", .cmd = Command.List },
        CommandOption{ .short_handle = "i", .handle = "install", .cmd = Command.Install },
        CommandOption{ .short_handle = null, .handle = "--default", .cmd = Command.Default }, // No short handle
    };

    for (args[1..]) |arg| {
        for (options) |option| {
            if (option.short_handle) |short_handle| {
                if (std.mem.eql(u8, arg, short_handle) or std.mem.eql(u8, arg, option.handle)) {
                    return option.cmd;
                }
            } else if (std.mem.eql(u8, arg, option.handle)) {
                return option.cmd;
            }
        }
    }
    return Command.Unknown;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd = try parseArgs(args);
    try handleCommands(cmd);
}
