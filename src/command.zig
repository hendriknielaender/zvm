const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const versions = @import("versions.zig");
const install = @import("install.zig");
const alias = @import("alias.zig");
const tools = @import("tools.zig");

// command species
pub const Command = enum {
    List,
    Install,
    Use,
    Default,
    Version,
    Help,
    Unknown,
};

const CommandData = struct {
    cmd: Command = .Unknown,
    param: ?[]const u8 = null,
};

const CommandOption = struct {
    short_handle: ?[]const u8,
    handle: []const u8,
    cmd: Command,
};

/// now all available commands
const command_opts = [_]CommandOption{
    .{ .short_handle = "ls", .handle = "list", .cmd = Command.List },
    .{ .short_handle = "i", .handle = "install", .cmd = Command.Install },
    .{ .short_handle = null, .handle = "use", .cmd = Command.Use },
    .{ .short_handle = null, .handle = "--version", .cmd = Command.Version },
    .{ .short_handle = null, .handle = "--help", .cmd = Command.Help },
    .{ .short_handle = null, .handle = "--default", .cmd = Command.Default },
};

/// parse command and handle commands
pub fn handleCommand(params: []const []const u8) !void {
    if (builtin.os.tag != .windows) {
        if (std.mem.eql(u8, std.fs.path.basename(params[0]), "zig"))
            try handleAlias(params);
    }

    // get command data, get the first command and its arg
    const command: CommandData = blk: {
        // when args len is less than 2, that mean no extra args!
        if (params.len < 2) break :blk CommandData{};

        const args = params[1..];

        for (args, 0..) |arg, index| {
            for (command_opts) |opt| {

                // whether eql short handle
                const is_eql_short_handle =
                    if (opt.short_handle) |short_handle|
                    std.mem.eql(u8, arg, short_handle)
                else
                    false;

                // whether eql handle
                const is_eql_handle = std.mem.eql(u8, arg, opt.handle);

                if (!is_eql_short_handle and !is_eql_handle)
                    continue;

                break :blk CommandData{
                    .cmd = opt.cmd,
                    .param = if (index + 1 < args.len) args[index + 1] else null,
                };
            }
        }
        break :blk CommandData{};
    };

    switch (command.cmd) {
        .List => try handle_list(),
        .Install => try install_version(command.param),
        .Use => try use_version(command.param),
        .Default => try set_default(),
        .Version => try get_version(),
        .Help => try display_help(),
        .Unknown => try handle_unknown(),
    }
}

fn handleAlias(params: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const new_params = try allocator.dupe([]const u8, params);

    const home = tools.get_home();
    const current_zig_path = try std.fs.path.join(allocator, &.{ home, ".zm", "current", "zig" });

    std.fs.accessAbsolute(current_zig_path, .{}) catch |err| {
        if (err == std.fs.Dir.AccessError.FileNotFound) {
            std.debug.print("Zig has not been installed yet, please install zig with zvm!\n", .{});
            std.process.exit(1);
        }
        return err;
    };

    new_params[0] = current_zig_path;
    return std.process.execv(allocator, new_params);
}

fn handle_list() !void {
    const allocator = tools.get_allocator();
    var version_list = try versions.VersionList.init(allocator);
    defer version_list.deinit();

    for (version_list.slice()) |version| {
        std.debug.print("{s}\n", .{version});
    }
}

fn install_version(params: ?[]const u8) !void {
    if (params) |version| {
        try install.from_version(version);
    } else {
        std.debug.print("Error: Please specify a version to install using 'install <version>'.\n", .{});
    }
}

fn use_version(params: ?[]const u8) !void {
    if (params) |version| {
        try alias.set_zig_version(version);
    } else {
        std.debug.print("Error: Please specify a version to use with 'use <version>'.\n", .{});
    }
}

fn set_default() !void {
    std.debug.print("Handling 'default' command.\n", .{});
    // Your default code here
}

fn get_version() !void {
    std.debug.print("zvm {}\n", .{options.zvm_version});
}

fn display_help() !void {
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
        \\
    ;

    std.debug.print(help_message, .{});
}

fn handle_unknown() !void {
    std.debug.print("Unknown command. Use 'zvm --help' for usage information.\n", .{});
}
