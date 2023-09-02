const std = @import("std");
const clap = @import("clap");
const versions = @import("./versions.zig");

const debug = std.debug;
const io = std.io;
const process = std.process;

const VERSION = "0.0.0";

const params = [_]clap.Param(clap.Help){
    clap.parseParam("-v, --verbose              Show headers & status code") catch unreachable,
    clap.parseParam("-c, --color                Turns on ANSI color") catch unreachable,
    clap.parseParam("-l, --list                 List all zig versions") catch unreachable,
    clap.parseParam("-i, --install <STR>        Installs zig version") catch unreachable,
    clap.parseParam("--use <ANSWER>             Use zig version") catch unreachable,
    clap.parseParam("--default <ANSWER>         Set default zig version") catch unreachable,
    clap.parseParam("--version                  Print the version and exit") catch unreachable,
    clap.parseParam("--help                     Display all flags & infos") catch unreachable,
};

fn installVersion() void {
    // Mockup: Just create a directory for the version.
}

fn useVersion() void {
    // Switch to the specified version for the current session
    // In practice, modify the PATH environment variable.
}

fn setDefault() void {
    // Mockup: Intentionally does nothing.
}

fn currentVersion() []const u8 {
    // Mockup: Intentionally does nothing.
    return "1.0.0";
}

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    installVersion();

    setDefault();

    const current = currentVersion();
    std.debug.print("Current version: {s}\n", .{current});

    // Declare our own parsers which are used to map the argument strings to other
    // types.
    const YesNo = enum { yes, no };
    const parsers = comptime .{
        .STR = clap.parsers.string,
        .FILE = clap.parsers.string,
        .INT = clap.parsers.int(usize, 10),
        .ANSWER = clap.parsers.enumeration(YesNo),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        debug.print("--help\n", .{});
    }

    // Check if --list or -ls flag is set
    if (res.args.list != 0) {
        const versionsList = try versions.list(allocator);
        defer versionsList.deinit();
        for (versionsList.items) |version| {
            std.debug.print("{s}\n", .{version});
        }
    }
}
