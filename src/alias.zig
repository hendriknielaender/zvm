const std = @import("std");

pub fn setZigVersion(version: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const userHome = getUserHome();

    const zigPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zvm", "versions", version });
    defer allocator.free(zigPath);

    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zvm", "current" });
    defer allocator.free(symlinkPath);

    try updateSymlink(zigPath, symlinkPath);
    try verifyZigVersion(allocator, version);
}

fn getUserHome() []const u8 {
    return std.os.getenv("HOME") orelse ".";
}

fn updateSymlink(zigPath: []const u8, symlinkPath: []const u8) !void {
    if (doesFileExist(symlinkPath)) try std.fs.cwd().deleteFile(symlinkPath);
    try std.os.symlink(zigPath, symlinkPath);
}

fn doesFileExist(path: []const u8) bool {
    const result = blk: {
        _ = std.fs.cwd().openFile(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            }
        };
        break :blk true;
    };
    return result;
}

fn verifyZigVersion(allocator: std.mem.Allocator, expectedVersion: []const u8) !void {
    const actualVersion = try retrieveZigVersion(allocator);
    defer allocator.free(actualVersion);

    if (!std.mem.eql(u8, expectedVersion, actualVersion)) {
        std.debug.print("Expected Zig version {s}, but currently using {s}. Please check.\n", .{ expectedVersion, actualVersion });
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expectedVersion});
    }
}

fn retrieveZigVersion(allocator: std.mem.Allocator) ![]u8 {
    const userHome = getUserHome();
    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zvm", "current" });
    defer allocator.free(symlinkPath);

    var childProcess = std.ChildProcess.init(&[_][]const u8{ "zig", "version" }, allocator);

    childProcess.stdin_behavior = .Close;
    childProcess.stdout_behavior = .Pipe;
    childProcess.stderr_behavior = .Close;

    try childProcess.spawn();

    if (childProcess.stdout) |stdout| {
        return try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
    }

    return error.FailedToReadVersion;
}
