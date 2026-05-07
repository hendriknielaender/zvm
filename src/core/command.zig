const std = @import("std");
const alias = @import("alias.zig");
const clean = @import("clean.zig");
const completions = @import("completions.zig");
const context = @import("../Context.zig");
const env = @import("env.zig");
const help = @import("help.zig");
const install = @import("install.zig");
const list = @import("list.zig");
const list_mirrors = @import("list_mirrors.zig");
const list_remote = @import("list_remote.zig");
const remove_installed = @import("remove_installed.zig");
const upgrade = @import("upgrade.zig");
const validation = @import("../cli/validation.zig");
const version = @import("version.zig");
const assert = std.debug.assert;

const Command = validation.ValidatedCommand;
const CommandTag = std.meta.Tag(Command);

const Dispatch = struct {
    tag: CommandTag,
    module: type,
};

const dispatch = [_]Dispatch{
    .{ .tag = .help, .module = help },
    .{ .tag = .version, .module = version },
    .{ .tag = .list, .module = list },
    .{ .tag = .list_remote, .module = list_remote },
    .{ .tag = .list_mirrors, .module = list_mirrors },
    .{ .tag = .install, .module = install },
    .{ .tag = .remove, .module = remove_installed },
    .{ .tag = .use, .module = alias },
    .{ .tag = .clean, .module = clean },
    .{ .tag = .env, .module = env },
    .{ .tag = .completions, .module = completions },
    .{ .tag = .upgrade, .module = upgrade },
};

comptime {
    assert(dispatch.len == @typeInfo(Command).@"union".fields.len);
}

pub fn progress_items(command: Command) u16 {
    return switch (command) {
        inline else => |args, tag| progress_items_for(tag, args),
    };
}

pub fn run(
    ctx: *context.CliContext,
    command: Command,
    progress_node: std.Progress.Node,
) !void {
    return switch (command) {
        inline else => |args, tag| run_for(tag, ctx, args, progress_node),
    };
}

fn progress_items_for(comptime tag: CommandTag, args: anytype) u16 {
    inline for (dispatch) |entry| {
        if (entry.tag == tag) {
            return entry.module.progress_items(args);
        }
    }
    @compileError("missing command progress handler for " ++ @tagName(tag));
}

fn run_for(
    comptime tag: CommandTag,
    ctx: *context.CliContext,
    args: anytype,
    progress_node: std.Progress.Node,
) !void {
    inline for (dispatch) |entry| {
        if (entry.tag == tag) {
            return entry.module.run(ctx, args, progress_node);
        }
    }
    @compileError("missing command run handler for " ++ @tagName(tag));
}
