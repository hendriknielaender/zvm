// command.zig
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
    system: bool = false,
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
    .{ .short_handle = "-v", .handle = "--version", .cmd = Command.Version },
    .{ .short_handle = null, .handle = "--help", .cmd = Command.Help },
};

/// Parse and handle commands
pub fn handle_command(params: []const []const u8, root_node: std.Progress.Node) !void {
    var command = CommandData{};

    if (params.len < 2) {
        // No command passed
        command.cmd = .Unknown;
    } else {
        const args = params[1..];

        // Identify the main command first
        {
            var found_cmd: bool = false;
            const arg = args[0];

            for (command_opts) |opt| {
                const matches_short = if (opt.short_handle) |sh| std.mem.eql(u8, arg, sh) else false;
                const matches_full = std.mem.eql(u8, arg, opt.handle);
                if (matches_short or matches_full) {
                    command.cmd = opt.cmd;

                    // subcmd is the second arg if present
                    if (args.len > 1) command.subcmd = args[1];

                    // param is the third arg if present
                    if (args.len > 2) command.param = args[2];

                    found_cmd = true;
                    break;
                }
            }

            if (!found_cmd) {
                // Command not recognized
                command.cmd = .Unknown;
            }
        }

        // Check if --system flag is present in any of the args beyond the command:
        // e.g. `zvm ls --system`, `zvm list zig --system`
        // The flag can appear as either the subcmd or the param.
        var has_system_flag = false;
        if (command.subcmd) |scmd| {
            if (std.mem.eql(u8, scmd, "--system")) {
                has_system_flag = true;
                command.subcmd = null; // remove it as a subcmd since it's a flag
            }
        }
        // Check if we haven't found the system flag yet
        if (!has_system_flag) {
            // Now try to unwrap command.param
            if (command.param) |p| {
                if (std.mem.eql(u8, p, "--system")) {
                    has_system_flag = true;
                    command.param = null; // remove it as a param since it's a flag
                }
            }
        }

        command.system = has_system_flag;
    }

    // Dispatch based on command
    switch (command.cmd) {
        .List => try handle_list(command.subcmd, command.param, command.system),
        .Install => try install_version(command.subcmd, command.param, root_node),
        .Use => try use_version(command.subcmd, command.param),
        .Remove => try remove_version(command.subcmd, command.param),
        .Version => try get_version(),
        .Help => try display_help(),
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
    } else {
        return;
    }

    var arena = std.heap.ArenaAllocator.init(util_data.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();
    const new_params = try allocator.dupe([]const u8, params);

    const current_path = blk: {
        const current = if (is_zls)
            (util_data.get_zvm_current_zls(allocator) catch null)
        else
            (util_data.get_zvm_current_zig(allocator) catch null);

        if (current == null) {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "{s} has not been installed yet, please install it first!\n",
                .{if (is_zls) "zls" else "Zig"},
            );
            std.process.exit(1);
        }

        break :blk try std.fs.path.join(
            allocator,
            &.{ current.?, if (is_zls) "zls" else "zig" },
        );
    };

    std.fs.accessAbsolute(current_path, .{}) catch |err| {
        return err; // if not found or something else, just return
    };

    new_params[0] = current_path;
    return std.process.execv(allocator, new_params);
}

fn handle_list(subcmd: ?[]const u8, param: ?[]const u8, system: bool) !void {
    const allocator = util_data.get_allocator();
    var color = try util_color.Color.RuntimeStyle.init(allocator);
    defer color.deinit();

    var is_zls = false;
    var requested_param: []const u8 = "zig";
    if (subcmd) |scmd| {
        if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
            requested_param = "zls";
        } else if (!util_tool.eql_str(scmd, "zig")) {
            try color.bold().red().printErr(
                "Invalid parameter '{s}'. You can specify 'zig' or 'zls'.\n",
                .{scmd},
            );
            return;
        }
    } else if (param) |p| {
        // If param is "zig" or "zls" when no subcmd was given
        if (util_tool.eql_str(p, "zls")) {
            is_zls = true;
            requested_param = "zls";
        } else if (!util_tool.eql_str(p, "zig")) {
            try color.bold().red().printErr(
                "Invalid parameter '{s}'. You can specify 'zig' or 'zls'.\n",
                .{p},
            );
            return;
        }
    }

    // If system flag is set, list only local installed versions
    if (system) {
        try list_local_versions(is_zls, allocator, &color);
        return;
    }

    // Default behavior: fetch and show remote available versions
    try list_remote_versions(is_zls, allocator, &color);
}

/// Lists locally installed versions of either Zig or ZLS.
fn list_local_versions(is_zls: bool, allocator: std.mem.Allocator, color: *util_color.Color.RuntimeStyle) !void {
    // Tiger Style: minimal scope, explicit conditions.
    const version_path = if (is_zls)
        try util_data.get_zvm_zls_version(allocator)
    else
        try util_data.get_zvm_zig_version(allocator);

    defer allocator.free(version_path);

    // Open the directory and read entries
    const fs = std.fs.cwd();
    var dir = try fs.openDir(version_path, .{});
    defer dir.close();

    var it = dir.iterate();
    var current_version: ?[]const u8 = null;
    current_version = (if (is_zls)
        util_data.get_zvm_current_zls(allocator)
    else
        util_data.get_zvm_current_zig(allocator)) catch null;
    defer if (current_version) |cv| allocator.free(cv);

    var found_any = false;
    while (true) {
        const entry = try it.next() orelse break;
        if (entry.kind != .directory) continue;

        // Ignore '.' and '..' if they appear
        if (entry.name[0] == '.' and (entry.name.len == 1 or (entry.name.len == 2 and entry.name[1] == '.'))) {
            continue;
        }

        found_any = true;
        if (current_version != null and std.mem.eql(u8, entry.name, current_version.?)) {
            try color.bold().cyan().print("* {s}\n", .{entry.name});
        } else {
            try color.green().print("  {s}\n", .{entry.name});
        }
    }

    if (!found_any) {
        try color.bold().red().print("No local versions installed.\n", .{});
    }
}

/// Lists remote available versions from meta (default behavior)
fn list_remote_versions(is_zls: bool, allocator: std.mem.Allocator, color: *util_color.Color.RuntimeStyle) !void {
    var version_list: [][]const u8 = undefined;

    if (is_zls) {
        const res = try util_http.http_get(allocator, config.zls_url);
        defer allocator.free(res);

        var zls_meta = try meta.Zls.init(res, allocator);
        defer zls_meta.deinit();

        version_list = try zls_meta.get_version_list(allocator);
    } else {
        const res = try util_http.http_get(allocator, config.zig_url);
        defer allocator.free(res);

        var zig_meta = try meta.Zig.init(res, allocator);
        defer zig_meta.deinit();

        version_list = try zig_meta.get_version_list(allocator);
    }

    defer util_tool.free_str_array(version_list, allocator);

    var current_version: ?[]const u8 = null;
    current_version = (if (is_zls)
        util_data.get_zvm_current_zls(allocator)
    else
        util_data.get_zvm_current_zig(allocator)) catch null;

    defer if (current_version) |cv| allocator.free(cv);

    for (version_list) |version| {
        if (current_version != null and std.mem.eql(u8, version, current_version.?)) {
            try color.bold().cyan().print("* {s}\n", .{version});
        } else {
            try color.green().print("  {s}\n", .{version});
        }
    }
}

fn install_version(subcmd: ?[]const u8, param: ?[]const u8, root_node: std.Progress.Node) !void {
    const allocator = util_data.get_allocator();

    if (subcmd) |scmd| {
        var is_zls: bool = undefined;

        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Unknown subcommand '{s}'. Use 'install zig/zls <version>'.\n",
                .{scmd},
            );
            return;
        }

        const version = param orelse {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Please specify a version to install: 'install {s} <version>'.\n",
                .{scmd},
            );
            return;
        };

        try install.install(version, is_zls, root_node);
    } else if (param) |version| {
        // set zig version
        try install.install(version, false, root_node);
    } else {
        var color = try util_color.Color.RuntimeStyle.init(allocator);
        defer color.deinit();
        try color.bold().red().printErr(
            "Please specify a version to install: 'install zig/zls <version>' or 'install <version>'.\n",
            .{},
        );
    }
}

fn use_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    const allocator = util_data.get_allocator();

    if (subcmd) |scmd| {
        var is_zls: bool = undefined;
        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Unknown subcommand '{s}'. Use 'use zig <version>' or 'use zls <version>'.\n",
                .{scmd},
            );
            return;
        }

        const version = param orelse {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Please specify a version to use: 'use {s} <version>'.\n",
                .{scmd},
            );
            return;
        };

        try alias.set_version(version, is_zls);
    } else if (param) |version| {
        // set zig version
        try alias.set_version(version, false);
    } else {
        var color = try util_color.Color.RuntimeStyle.init(allocator);
        defer color.deinit();
        try color.bold().red().printErr(
            "Please specify a version to use: 'use zig/zls <version>' or 'use <version>'.\n",
            .{},
        );
    }
}

fn remove_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    const allocator = util_data.get_allocator();

    if (subcmd) |scmd| {
        var is_zls: bool = undefined;
        if (util_tool.eql_str(scmd, "zig")) {
            is_zls = false;
        } else if (util_tool.eql_str(scmd, "zls")) {
            is_zls = true;
        } else {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Unknown subcommand '{s}'. Use 'remove zig <version>' or 'remove zls <version>'.\n",
                .{scmd},
            );
            return;
        }

        const version = param orelse {
            var color = try util_color.Color.RuntimeStyle.init(allocator);
            defer color.deinit();
            try color.bold().red().printErr(
                "Please specify a version: 'remove {s} <version>'.\n",
                .{scmd},
            );
            return;
        };

        try remove.remove(version, is_zls);
    } else if (param) |version| {
        // remove zig version
        try remove.remove(version, false);
        // also try remove zls version if it matches
        try remove.remove(version, true);
    } else {
        var color = try util_color.Color.RuntimeStyle.init(allocator);
        defer color.deinit();
        try color.bold().red().printErr(
            "Please specify a version to remove: 'remove zig/zls <version>' or 'remove <version>'.\n",
            .{},
        );
    }
}

fn get_version() !void {
    comptime var color = util_color.Color.ComptimeStyle.init();
    const version_message = color.cyan().fmt("zvm " ++ options.version ++ "\n");
    try color.print("{s}", .{version_message});
}

fn display_help() !void {
    comptime var color = util_color.Color.ComptimeStyle.init();

    const usage_title = color.bold().magenta().fmt("Usage:");
    const commands_title = color.bold().magenta().fmt("Commands:");
    const examples_title = color.bold().magenta().fmt("Examples:");
    const additional_info_title = color.bold().magenta().fmt("Additional Information:");

    const help_message = usage_title ++
        "\n    zvm <command> [args]\n\n" ++
        commands_title ++
        "\n    ls, list       List all available versions (remote) or use --system for local.\n" ++
        "    i, install     Install the specified version of Zig or zls.\n" ++
        "    use            Use the specified version of Zig or zls.\n" ++
        "    remove         Remove the specified version of Zig or zls.\n" ++
        "    --version      Display the current version of zvm.\n" ++
        "    --help         Show this help message.\n\n" ++
        examples_title ++
        "\n    zvm ls                  List all available remote Zig versions.\n" ++
        "    zvm ls --system         List all locally installed Zig versions.\n" ++
        "    zvm ls zls --system     List all locally installed ZLS versions.\n" ++
        "    zvm install 0.12.0      Install Zig and zls version 0.12.0.\n" ++
        "    zvm use zig 0.12.0      Switch to using Zig version 0.12.0.\n" ++
        "    zvm remove zig 0.12.0   Remove Zig version 0.12.0.\n\n" ++
        additional_info_title ++
        "\n    For additional information and contributions, please visit https://github.com/hendriknielaender/zvm\n\n";

    try color.print("{s}", .{help_message});
}

fn handle_unknown() !void {
    comptime var color = util_color.Color.ComptimeStyle.init();
    try color.bold().red().print("Unknown command. Use 'zvm --help' for usage information.\n", .{});
}
