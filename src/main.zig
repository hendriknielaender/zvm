const std = @import("std");
const versions = @import("./versions.zig");

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

    const versionsList = try versions.list(allocator);
    defer versionsList.deinit();

    for (versionsList.items) |version| {
        std.debug.print("Available version: {s}\n", .{version});
    }

    installVersion();

    setDefault();

    const current = currentVersion();
    std.debug.print("Current version: {s}\n", .{current});
}
