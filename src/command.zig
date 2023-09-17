const std = @import("std");
const versions = @import("versions.zig");
const install = @import("install.zig");
const alias = @import("alias.zig");

pub const Command = enum {
    List,
    Install,
    Use,
    Default,
    Unknown,
};

pub fn handleCommands(cmd: Command, params: ?[]const u8) !void {
    switch (cmd) {
        Command.List => {
            try handleList();
        },
        Command.Install => {
            try installVersion(params);
        },
        Command.Use => {
            try useVersion(params);
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
    var allocator = std.heap.page_allocator;
    const versionsList = try versions.list(allocator);
    defer versionsList.deinit();
    for (versionsList.items) |version| {
        std.debug.print("{s}\n", .{version});
    }
}

fn installVersion(params: ?[]const u8) !void {
    if (params) |version| {
        try install.fromVersion(version);
    } else {
        std.debug.print("Error: Please specify a version to install using 'install <version>'.\n", .{});
    }
}

fn useVersion(params: ?[]const u8) !void {
    if (params) |version| {
        try alias.setZigVersion(version);
    } else {
        std.debug.print("Error: Please specify a version to use with 'use <version>'.\n", .{});
    }
}

fn setDefault() !void {
    std.debug.print("Handling 'default' command.\n", .{});
    // Your default code here
}

fn handleUnknown() !void {
    std.debug.print("Unknown command. Use '--help' for usage information.\n", .{});
}
