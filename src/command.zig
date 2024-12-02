//! This file stores command line parsing and processing
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const install = @import("install.zig");
const alias = @import("alias.zig");
const remove = @import("remove.zig");

const meta = @import("meta.zig");
const config = @import("config.zig");
const util_data = @import("util/data.zig");
const util_tool = @import("util/tool.zig");
const util_http = @import("util/http.zig");
const util_color = @import("util/color.zig");

// Command types
pub const Command = enum {
    List,
    Install,
    Use,
    Remove,
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
    .{ .short_handle = "u", .handle = "use", .cmd = Command.Use },
    .{ .short_handle = "rm", .handle = "remove", .cmd = Command.Remove },
    .{ .short_handle = null, .handle = "--version", .cmd = Command.Version },
    .{ .short_handle = null, .handle = "--help", .cmd = Command.Help },
    // .{ .short_handle = null, .handle = "--default", .cmd = Command.Default },
};

/// Parse and handle commands
pub fn handle_command(params: []const []const u8, root_node: std.Progress.Node) !void {
    const command: CommandData = blk: {
        if (params.len < 2) break :blk CommandData{};

        const args = params[1..];

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

            break :blk CommandData{
                .cmd = opt.cmd,
                .subcmd = subcmd,
                .param = param,
            };
        }
        break :blk CommandData{};
    };

    switch (command.cmd) {
        .List => try handle_list(command.param),
        .Install => try install_version(command.subcmd, command.param, root_node),
        .Use => try use_version(command.subcmd, command.param),
        .Remove => try remove_version(command.subcmd, command.param),
        .Version => get_version(),
        .Help => display_help(),
        .Unknown => try handle_unknown(),
    }
}

/// handle alias, now only support zig
pub fn handle_alias(params: []const []const u8) !void {
    if (builtin.os.tag == .windows) return;

    var is_zls: bool = undefined;

    const basename = std.fs.path.basename(params[0]);
    if (util_tool.eql_str(basename, "zig")) {
        is_zls = false;
    } else if (util_tool.eql_str(basename, "zls")) {
        is_zls = true;
    } else return;

    var arena = std.heap.ArenaAllocator.init(util_data.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    const new_params = try allocator.dupe([]const u8, params);

    const current = try if (is_zls)
        util_data.get_zvm_current_zls(allocator)
    else
        util_data.get_zvm_current_zig(allocator);

    const current_path = try std.fs.path.join(
        allocator,
        &.{ current, if (is_zls) "zls" else "zig" },
    );

    std.fs.accessAbsolute(current_path, .{}) catch |err| {
        if (err == std.fs.Dir.AccessError.FileNotFound) {
            std.debug.print("{s} has not been installed yet, please install it fist!\n", .{if (is_zls) "zls" else "Zig"});
            std.process.exit(1);
        }
        return err;
    };

    new_params[0] = current_path;
    return std.process.execv(allocator, new_params);
}

fn handle_list(param: ?[]const u8) !void {
    const allocator = util_data.get_allocator();

    const version_list: [][]const u8 = blk: {
        if (param) |p| {
            // when zls
            if (util_tool.eql_str(p, "zls")) {
                const res = try util_http.http_get(allocator, config.zls_url);
                defer allocator.free(res);

                var zls_meta = try meta.Zls.init(res, allocator);
                defer zls_meta.deinit();

                const version_list = try zls_meta.get_version_list(allocator);
                break :blk version_list;
            } else
            // when not zig
            if (!util_tool.eql_str(p, "zig")) {
                std.debug.print("Error param, you can specify zig or zls\n", .{});
                return;
            }
        }

        // when param is null
        const res = try util_http.http_get(allocator, config.zig_url);
        defer allocator.free(res);

        var zig_meta = try meta.Zig.init(res, allocator);
        defer zig_meta.deinit();

        const version_list = try zig_meta.get_version_list(allocator);
        break :blk version_list;
    };

    defer util_tool.free_str_array(version_list, allocator);

    for (version_list) |version| {
        std.debug.print("{s}\n", .{version});
    }
}

fn install_version(subcmd: ?[]const u8, param: ?[]const u8, root_node: std.Progress.Node) !void {
    if (subcmd) |scmd| {
        var is_zls: bool = undefined;

        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            std.debug.print("Unknown subcommand '{s}'. Use 'install zig/zls <version>'.\n", .{scmd});
            return;
        }

        const version = param orelse {
            std.debug.print("Please specify a version to install: 'install zig/zls <version>'.\n", .{});
            return;
        };

        try install.install(version, is_zls, root_node);
    } else if (param) |version| {
        // set zig version
        try install.install(version, false, root_node);
    } else {
        std.debug.print("Please specify a version to install: 'install zig/zls <version>' or 'install <version>'.\n", .{});
    }
}

fn use_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    if (subcmd) |scmd| {
        var is_zls: bool = undefined;

        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            std.debug.print("Unknown subcommand '{s}'. Use 'use zig <version>' or 'use zls <version>'.\n", .{scmd});
            return;
        }

        const version = param orelse {
            std.debug.print("Please specify a version to use: 'use zig/zls <version>'.\n", .{});
            return;
        };

        try alias.set_version(version, is_zls);
    } else if (param) |version| {
        // set zig version
        try alias.set_version(version, false);
        // set zls version
        // try alias.set_version(version, true);
    } else {
        std.debug.print("Please specify a version to use: 'use zig/zls <version>' or 'use <version>'.\n", .{});
    }
}

fn remove_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    if (subcmd) |scmd| {
        var is_zls: bool = undefined;

        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            std.debug.print("Unknown subcommand '{s}'. Use 'remove zig <version>' or 'remove zls <version>'.\n", .{scmd});
            return;
        }

        const version = param orelse {
            std.debug.print("Please specify a version: 'remove zig <version>' or 'remove zls <version>'.\n", .{});
            return;
        };

        try remove.remove(version, is_zls);
    } else if (param) |version| {
        // remove zig version
        try remove.remove(version, false);
        // set zls version
        try remove.remove(version, true);
    } else {
        std.debug.print("Please specify a version to use: 'remove zig/zls <version>' or 'remove <version>'.\n", .{});
    }
}

fn set_default() !void {
    std.debug.print("Handling 'default' command.\n", .{});
    // Your default code here
}

fn get_version() void {
    comptime var color = util_color.Style.init();

    const version_message = color.cyan().fmt("zvm " ++ options.version ++ "\n");

    std.debug.print("{s}", .{version_message});
}

fn display_help() void {
    comptime var color = util_color.Style.init();

    const usage_title = color.bold().magenta().fmt("Usage:");
    const commands_title = color.bold().magenta().fmt("Commands:");
    const examples_title = color.bold().magenta().fmt("Examples:");
    const additional_info_title = color.bold().magenta().fmt("Additional Information:");

    const help_message =
        usage_title ++
        "\n    zvm <command> [args]\n\n" ++
        commands_title ++
        "\n    ls, list       List all available versions of Zig or zls.\n" ++
        "    i, install     Install the specified version of Zig or zls.\n" ++
        "    use            Use the specified version of Zig or zls.\n" ++
        "    remove         Remove the specified version of Zig or zls.\n" ++
        "    --version      Display the current version of zvm.\n" ++
        "    --help         Show this help message.\n\n" ++
        examples_title ++
        "\n    zvm install 0.12.0        Install Zig and zls version 0.12.0.\n" ++
        "    zvm install zig 0.12.0    Install Zig version 0.12.0.\n" ++
        "    zvm use 0.12.0            Switch to using Zig version 0.12.0.\n" ++
        "    zvm use zig 0.12.0        Switch to using Zig version 0.12.0.\n" ++
        "    zvm remove zig 0.12.0     Remove Zig version 0.12.0.\n\n" ++
        additional_info_title ++
        "\n    For additional information and contributions, please visit https://github.com/hendriknielaender/zvm\n\n";

    std.debug.print("{s}", .{help_message});
}

fn handle_unknown() !void {
    comptime var color = util_color.Style.init();
    const error_message = color.bold().red().fmt("Unknown command. Use 'zvm --help' for usage information.\n");
    try std.io.getStdErr().writer().print("{s}", .{error_message});
}
