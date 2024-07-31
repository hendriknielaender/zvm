const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const versions = @import("versions.zig");
const install = @import("install.zig");
const alias = @import("alias.zig");
const tools = @import("tools.zig");

// Command types
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
    subcmd: ?[]const u8 = null,
    param: ?[]const u8 = null,
};

const CommandOption = struct {
    short_handle: ?[]const u8,
    handle: []const u8,
    cmd: Command,
    subcmd: ?[]const u8 = null,
};

// Available commands
const command_opts = [_]CommandOption{
    .{ .short_handle = "ls", .handle = "list", .cmd = Command.List },
    .{ .short_handle = "i", .handle = "install", .cmd = Command.Install },
    .{ .short_handle = null, .handle = "use", .cmd = Command.Use },
    .{ .short_handle = null, .handle = "--version", .cmd = Command.Version },
    .{ .short_handle = null, .handle = "--help", .cmd = Command.Help },
    .{ .short_handle = null, .handle = "--default", .cmd = Command.Default },
};

/// Parse and handle commands
pub fn handle_command(params: []const []const u8) !void {
    if (builtin.os.tag != .windows) {
        if (std.mem.eql(u8, std.fs.path.basename(params[0]), "zig"))
            try handle_alias(params);
    }

    const command: CommandData = blk: {
        if (params.len < 2) break :blk CommandData{};

        const args = params[1..];

        // for (args, 0..) |arg, index| {
        const arg = args[0];
        for (command_opts) |opt| {
            const is_eql_short_handle = if (opt.short_handle) |short_handle|
                std.mem.eql(u8, arg, short_handle)
            else
                false;

            const is_eql_handle = std.mem.eql(u8, arg, opt.handle);

            if (!is_eql_short_handle and !is_eql_handle)
                continue;

            const subcmd = if (args.len > 2) args[1] else null;
            const param = kk: {
                if (subcmd != null) {
                    break :kk args[2];
                }

                if (args.len > 1)
                    break :kk args[1];

                break :kk null;
            };

            // const next_param = if (index + 1 < args.len) args[index + 1] else null;
            // const is_version = if (next_param) |np| std.ascii.isDigit(np[0]) else false;

            break :blk CommandData{
                .cmd = opt.cmd,
                .subcmd = subcmd,
                .param = param,
            };
        }
        // }
        break :blk CommandData{};
    };

    switch (command.cmd) {
        .List => try handle_list(command.param),
        .Install => try install_version(command.subcmd, command.param),
        .Use => try use_version(command.param),
        .Default => try set_default(),
        .Version => try get_version(),
        .Help => try display_help(),
        .Unknown => try handle_unknown(),
    }
}

fn handle_alias(params: []const []const u8) !void {
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

fn handle_list(_: ?[]const u8) !void {
    // TODO:
    const allocator = tools.get_allocator();
    var version_list = try versions.VersionList.init(allocator, .zig);
    defer version_list.deinit();

    for (version_list.slice()) |version| {
        std.debug.print("{s}\n", .{version});
    }
}

fn install_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    if (subcmd) |scmd| {
        if (std.mem.eql(u8, scmd, "zig")) {
            if (param) |version| {
                try install.from_version(version);
            } else {
                std.debug.print("Please specify a version to install using 'install zig <version>'.\n", .{});
            }
        } else if (std.mem.eql(u8, scmd, "zls")) {
            // Handle ZLS installation if supported
            std.debug.print("[Unsupported] install zls\n", .{});
        } else {
            std.debug.print("Unknown subcommand '{s}'. Use 'install zig <version>' or 'install zls <version>'.\n", .{scmd});
        }
    } else if (param) |version| {
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
