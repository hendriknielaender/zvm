const std = @import("std");

pub fn zigVersion(version: []const u8) !void {
    var allocator = std.heap.page_allocator;
    const user_home = std.os.getenv("HOME") orelse ".";

    const zigPath = try std.fs.path.join(allocator, &[_][]const u8{ user_home, ".zvm", "versions", version });
    defer allocator.free(zigPath);

    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ user_home, ".zvm", "current" });
    defer allocator.free(symlinkPath);

    // Handle symlink using the consolidated function
    try zigSymlink(zigPath, symlinkPath);

    // Verify the version
    try verifyZigVersion(allocator, version);
}

fn zigSymlink(zigPath: []const u8, symlinkPath: []const u8) !void {
    // Check if symlink exists
    const symlinkExists = blk: {
        _ = std.fs.cwd().openFile(symlinkPath, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            }
        };
        break :blk true;
    };

    if (symlinkExists) {
        try std.fs.cwd().deleteFile(symlinkPath);
    }

    // Create new symlink
    try std.os.symlink(zigPath, symlinkPath);
}

fn verifyZigVersion(allocator: std.mem.Allocator, version: []const u8) !void {
    const zigVersionResult = try getZigVersion(allocator);
    defer allocator.free(zigVersionResult);
    // Handle any errors from getZigVersion if necessary.

    if (std.mem.eql(u8, version, zigVersionResult)) {
        std.debug.print("Verified: Current Zig version is {s}\n", .{version});
    } else {
        std.debug.print("Verification failed! Expected version: {s}, but got: {s}\n", .{ version, zigVersionResult });
    }
}

fn getZigVersion(allocator: std.mem.Allocator) ![]u8 {
    const user_home = std.os.getenv("HOME") orelse ".";

    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ user_home, ".zvm", "current" });
    defer allocator.free(symlinkPath);
    var child_process = std.ChildProcess.init(&[_][]const u8{ "zig", "version" }, allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        return try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
    }

    return error.FailedToReadVersion;
}
