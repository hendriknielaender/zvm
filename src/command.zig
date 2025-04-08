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
    Clean,
    Version,
    Help,
    Completions,
    Unknown,
};

const CommandData = struct {
    cmd: Command = .Unknown,
    subcmd: ?[]const u8 = null,
    param: ?[]const u8 = null,
    system: bool = false,
    mirror: ?usize = null,
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
    .{ .short_handle = null, .handle = "clean", .cmd = Command.Clean },
    .{ .short_handle = "-v", .handle = "--version", .cmd = Command.Version },
    .{ .short_handle = null, .handle = "--help", .cmd = Command.Help },
    .{ .short_handle = null, .handle = "completions", .cmd = .Completions },
};

/// Parse and handle commands
/// Parse and handle commands
pub fn handle_command(params: []const []const u8, root_node: std.Progress.Node) !void {
    var command = CommandData{};
    var show_mirrors = false;

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

        // Check ALL command arguments for flags, regardless of position
        for (args) |arg| {
            // Check for specific flags
            if (std.mem.eql(u8, arg, "--system")) {
                command.system = true;

                // Clear this arg if it was set as subcmd or param
                if (command.subcmd != null and std.mem.eql(u8, command.subcmd.?, arg)) {
                    command.subcmd = null;
                }
                if (command.param != null and std.mem.eql(u8, command.param.?, arg)) {
                    command.param = null;
                }
            } else if (std.mem.eql(u8, arg, "--mirror")) {
                show_mirrors = true;

                // Clear this arg if it was set as subcmd or param
                if (command.subcmd != null and std.mem.eql(u8, command.subcmd.?, arg)) {
                    command.subcmd = null;
                }
                if (command.param != null and std.mem.eql(u8, command.param.?, arg)) {
                    command.param = null;
                }
            } else if (std.mem.startsWith(u8, arg, "--mirror=")) {
                const mirror_value = arg["--mirror=".len..];
                const mirror_index = std.fmt.parseInt(usize, mirror_value, 10) catch |err| {
                    std.log.err("Invalid mirror index: {s}", .{mirror_value});
                    return err;
                };
                command.mirror = mirror_index;

                // Clear this arg if it was set as subcmd or param
                if (command.subcmd != null and std.mem.eql(u8, command.subcmd.?, arg)) {
                    command.subcmd = null;
                }
                if (command.param != null and std.mem.eql(u8, command.param.?, arg)) {
                    command.param = null;
                }
            }
        }

        // Set the preferred mirror if specified with a value
        if (command.mirror) |mirror_index| {
            if (mirror_index >= config.zig_mirrors.len) {
                std.log.warn("Mirror index {d} out of range (0-{d}), using default sources", .{ mirror_index, config.zig_mirrors.len - 1 });
            } else {
                config.preferred_mirror = mirror_index;
            }
        }
    }

    // Dispatch based on command
    switch (command.cmd) {
        .List => try handle_list(command.subcmd, command.param, command.system, show_mirrors),
        .Install => try install_version(command.subcmd, command.param, root_node),
        .Use => try use_version(command.subcmd, command.param),
        .Remove => try remove_version(command.subcmd, command.param),
        .Clean => try clean_store(),
        .Version => try get_version(),
        .Help => try display_help(),
        .Completions => try handle_completions(params),
        .Unknown => try handle_unknown(),
    }
}

fn handle_list(subcmd: ?[]const u8, param: ?[]const u8, system: bool, show_mirrors: bool) !void {
    const allocator = util_data.get_allocator();
    var color = try util_color.Color.RuntimeStyle.init(allocator);
    defer color.deinit();

    // If mirror flag is present without a value, list all mirrors
    if (show_mirrors) {
        try color.bold().cyan().print("Available mirrors:\n", .{});
        try color.print("{s}", .{list_mirrors()});
        return;
    }

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

/// handle alias, now only support zig
pub fn handle_alias(params: []const []const u8) !void {
    if (builtin.os.tag == .windows) return;

    // SAFETY: Value is set immediately after declaration before any reads
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

    try std.fs.accessAbsolute(current_path, .{});

    new_params[0] = current_path;
    return std.process.execv(allocator, new_params);
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
    // SAFETY: Initialized before use in the next statement
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
    var color = try util_color.Color.RuntimeStyle.init(allocator);
    defer color.deinit();

    if (subcmd) |scmd| {
        if (util_tool.eql_str(scmd, "zig")) {
            if (param) |version| {
                try install.install(version, false, root_node);
            } else {
                try color.bold().print("No version specified, installing latest Zig...\n", .{});
                const latest_version = try get_latest_version(allocator, false);
                defer allocator.free(latest_version);
                try install.install(latest_version, false, root_node);
            }
        } else if (util_tool.eql_str(scmd, "zls")) {
            if (param) |version| {
                try install.install(version, true, root_node);
            } else {
                try color.bold().print("No version specified, installing latest zls...\n", .{});
                const latest_version = try get_latest_version(allocator, true);
                defer allocator.free(latest_version);
                try install.install(latest_version, true, root_node);
            }
        } else {
            try color.bold().red().printErr(
                "Unknown subcommand '{s}'. Use 'zvm install zig <version>' or 'zvm install zls <version>'.\n",
                .{scmd},
            );
            return;
        }
    } else {
        if (param) |version| {
            try install.install(version, false, root_node);
        } else {
            try color.bold().print("No version specified, installing latest Zig...\n", .{});
            const latest_version = try get_latest_version(allocator, false);
            defer allocator.free(latest_version);
            try install.install(latest_version, false, root_node);
        }
    }
}

fn use_version(subcmd: ?[]const u8, param: ?[]const u8) !void {
    const allocator = util_data.get_allocator();

    if (subcmd) |scmd| {
        // SAFETY: Value is set immediately after declaration based on string comparison
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
        // SAFETY: Value is set immediately after declaration based on string comparison
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

/// Handle the `clean` command
fn clean_store() !void {
    var allocator = util_data.get_allocator();
    var color = try util_color.Color.RuntimeStyle.init(allocator);
    defer color.deinit();

    // Path to the store directory
    const store_path = try util_data.get_zvm_path_segment(allocator, "store");
    defer allocator.free(store_path);

    const fs = std.fs.cwd();
    var store_dir = try fs.openDir(store_path, .{});
    defer store_dir.close();

    var it = store_dir.iterate();
    var files_removed: usize = 0;
    var bytes_freed: u64 = 0;

    while (true) {
        const entry = try it.next() orelse break;

        // Get file size before deletion
        const file_path = try std.fs.path.join(allocator, &.{ store_path, entry.name });
        defer allocator.free(file_path);

        const file = try fs.openFile(file_path, .{});
        const file_info = try file.stat();
        const file_size = file_info.size;
        file.close();

        // Delete the file
        try store_dir.deleteFile(entry.name);

        files_removed += 1;
        bytes_freed += file_size;
    }

    if (files_removed > 0) {
        try color.bold().green().print(
            "Cleaned up {d} old download artifact(s).\n",
            .{files_removed},
        );
    } else {
        try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
    }
}

fn get_version() !void {
    comptime var color = util_color.Color.ComptimeStyle.init();

    try color.print(util_data.zvm_logo);

    const version_message = color.fmt(options.version ++ "\n");
    try color.print(version_message);
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
        "    rm, remove     Remove the specified version of Zig or zls.\n" ++
        "    clean          Remove old download artifacts from the store.\n" ++
        "    -v, --version  Display the current version of zvm.\n" ++
        "    --help         Show this help message.\n\n" ++
        examples_title ++
        "\n    zvm ls                  List all available remote Zig versions.\n" ++
        "    zvm ls --system         List all locally installed Zig versions.\n" ++
        "    zvm ls zls --system     List all locally installed zls versions.\n" ++
        "    zvm ls --mirror         List all available mirrors for downloading Zig.\n" ++
        "    zvm install --mirror=0  Install Zig using the first mirror in the list.\n" ++
        "    zvm install 0.14.0      Install Zig and zls version 0.14.0.\n" ++
        "    zvm use zig 0.14.0      Switch to using Zig version 0.14.0.\n" ++
        "    zvm remove zig 0.14.0   Remove Zig version 0.14.0.\n" ++
        "    zvm clean               Remove old download artifacts.\n\n" ++
        additional_info_title ++
        "\n    For additional information and contributions, please visit https://github.com/hendriknielaender/zvm\n\n";

    try color.print(help_message);
}

fn handle_completions(params: []const []const u8) !void {
    if (params.len < 3) {
        std.debug.print("Usage: zvm completions [zsh|bash]\n", .{});
        return;
    }

    const shell = params[2];

    if (std.mem.eql(u8, shell, "zsh")) {
        try handle_completions_zsh();
    } else if (std.mem.eql(u8, shell, "bash")) {
        try handle_completions_bash();
    } else {
        std.debug.print("Unsupported shell: {s}\n", .{shell});
        std.debug.print("Usage: zvm completions [zsh|bash]\n", .{});
    }
}

fn list_mirrors() []const u8 {
    comptime var color = util_color.Color.ComptimeStyle.init();
    comptime var mirrors_text: []const u8 = "";

    inline for (config.zig_mirrors, 0..) |mirror, i| {
        const mirror_url = mirror[0];
        const mirror_maintainer = mirror[1];

        const index_line = std.fmt.comptimePrint("    {d}: {s}\n", .{ i, mirror_url });
        const maintainer_line = std.fmt.comptimePrint("       Maintained by: {s}\n", .{mirror_maintainer});

        mirrors_text = mirrors_text ++ color.fmt(index_line) ++ color.fmt(maintainer_line);
    }

    return mirrors_text;
}

fn handle_completions_zsh() !void {
    const zsh_script =
        \\#compdef zvm
        \\
        \\# ZVM top-level commands (example)
        \\local -a _zvm_commands
        \\_zvm_commands=(
        \\  'ls:List local or remote versions'
        \\  'install:Install a version of Zig or zls'
        \\  'use:Switch to a local version of Zig or zls'
        \\  'remove:Remove a local version of Zig or zls'
        \\  'clean:Remove old artifacts'
        \\  '--version:Show zvm version'
        \\  '--help:Show help message'
        \\  'completions:Generate completion script'
        \\)
        \\
        \\_arguments \
        \\  '1: :->cmds' \
        \\  '*:: :->args'
        \\
        \\case $state in
        \\  cmds)
        \\    _describe -t commands "zvm command" _zvm_commands
        \\  ;;
        \\  args)
        \\    # Subcommand-specific completions if needed
        \\  ;;
        \\esac
    ;

    const out = std.io.getStdOut().writer();
    try out.print("{s}\n", .{zsh_script});
}

fn handle_completions_bash() !void {
    const bash_script =
        \\#!/usr/bin/env bash
        \\# zvm Bash completion
        \\
        \\_zvm_completions() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    local commands="ls install use remove clean --version --help completions"
        \\
        \\    if [[ $cword -eq 1 ]]; then
        \\        COMPREPLY=( $( compgen -W "$commands" -- "$cur" ) )
        \\    else
        \\        # Add subcommand-specific logic here
        \\        case "$prev" in
        \\            install)
        \\                # e.g. list remote versions
        \\                ;;
        \\            use)
        \\                # e.g. list local versions
        \\                ;;
        \\            remove)
        \\                # e.g. remove local versions
        \\                ;;
        \\        esac
        \\    fi
        \\}
        \\
        \\complete -F _zvm_completions zvm
    ;

    const out = std.io.getStdOut().writer();
    try out.print("{s}\n", .{bash_script});
}

fn handle_unknown() !void {
    comptime var color = util_color.Color.ComptimeStyle.init();
    try color.bold().red().print("Unknown command. Use 'zvm --help' for usage information.\n");
}

fn get_latest_version(allocator: std.mem.Allocator, is_zls: bool) ![]const u8 {
    if (is_zls) {
        const res = try util_http.http_get(allocator, config.zls_url);
        defer allocator.free(res);

        var zls_meta = try meta.Zls.init(res, allocator);
        defer zls_meta.deinit();

        const version_list = try zls_meta.get_version_list(allocator);
        defer util_tool.free_str_array(version_list, allocator);

        if (version_list.len == 0) {
            return error.NoVersions;
        }
        return try allocator.dupe(u8, version_list[0]);
    } else {
        const res = try util_http.http_get(allocator, config.zig_url);
        defer allocator.free(res);

        var zig_meta = try meta.Zig.init(res, allocator);
        defer zig_meta.deinit();

        const version_list = try zig_meta.get_version_list(allocator);
        defer util_tool.free_str_array(version_list, allocator);

        if (version_list.len == 0) {
            return error.NoVersions;
        }
        return try allocator.dupe(u8, version_list[0]);
    }
}
