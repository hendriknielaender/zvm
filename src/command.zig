const std = @import("std");
const versions = @import("versions.zig");
const install = @import("install.zig");
const alias = @import("alias.zig");
const tools = @import("tools.zig");

const options = @import("options");

pub const Command = enum {
    List,
    Install,
    Use,
    Default,
    Version,
    Help,
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
        Command.Version => {
            try getVersion();
        },
        Command.Help => {
            try displayHelp();
        },
        Command.Unknown => {
            try handleUnknown();
        },
    }
}

fn handleList() !void {
    const allocator = tools.getAllocator();
    var version_list = try versions.VersionList.init(allocator);
    defer version_list.deinit();

    for (version_list.slice()) |version| {
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

fn getVersion() !void {
    std.debug.print("zvm {}\n", .{options.zvm_version});
}

fn displayHelp() !void {
    const help_message =
        \\Usage:
        \\    zvm <command> [args]
        \\
        \\Commands:
        \\    ls, list       List the versions of Zig available to zvm.
        \\    i, install     Install the specified version of Zig.
        \\    use            Use the specified version of Zig.
        \\    --version      Display the currently active Zig version.
        \\    --default      Set a specified Zig version as the default for new shells.
        \\    --help         Display this help message.
        \\
        \\Example:
        \\    zvm install 0.8.0  Install Zig version 0.8.0.
        \\    zvm use 0.8.0      Switch to using Zig version 0.8.0.
        \\
        \\For additional information and contributions, please visit the GitHub repository.
    ;

    std.debug.print(help_message, .{});
}

fn handleUnknown() !void {
    std.debug.print("Unknown command. Use 'zvm --help' for usage information.\n", .{});
}
