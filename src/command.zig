const std = @import("std");

pub const Command = enum {
    List,
    Install,
    Use,
    Default,
    Unknown,
};

pub fn handleCommands(cmd: Command) !void {
    switch (cmd) {
        Command.List => {
            try handleList();
        },
        Command.Install => {
            try installVersion();
        },
        Command.Use => {
            try useVersion();
        },
        Command.Default => {
            try setDefault();
        },
        Command.Unknown => {
            try handleUnknown();
        },
    }
}

fn handleList() !void {
    std.debug.print("Handling 'list' command.\n", .{});
    // Your install code here
}

fn installVersion() !void {
    std.debug.print("Handling 'install' command.\n", .{});
    // Your install code here
}

fn useVersion() !void {
    std.debug.print("Handling 'use' command.\n", .{});
    // Your use code here
}

fn setDefault() !void {
    std.debug.print("Handling 'default' command.\n", .{});
    // Your default code here
}

fn handleUnknown() !void {
    std.debug.print("Unknown command. Use '--help' for usage information.\n", .{});
}
