const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

pub fn setZigVersion(version: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const userHome = tools.getHome();

    const zigPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zm", "versions", version });
    defer allocator.free(zigPath);

    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zm", "current" });
    defer allocator.free(symlinkPath);

    const previousVersionPath = try getCurrentVersionSymlink(allocator, symlinkPath);
    defer allocator.free(previousVersionPath);

    try updateSymlink(zigPath, symlinkPath);
    verifyZigVersion(allocator, version) catch |err| switch (err) {
        error.WrongVersion => {
            std.debug.print("Failed to set Zig version {s}. Reverting to previous version.\n", .{version});
            try updateSymlink(previousVersionPath, symlinkPath);
            std.debug.print("Reverted to previous Zig version successfully.\n", .{});
        },
        else => return err,
    };
}

fn getCurrentVersionSymlink(allocator: std.mem.Allocator, symlinkPath: []const u8) ![]u8 {
    var buffer: [1000]u8 = undefined;

    if (doesFileExist(symlinkPath)) {
        const linkTarget = try std.fs.cwd().readLink(symlinkPath, &buffer);
        // Allocate memory to return a copy of the link target
        const linkTargetCopy = try allocator.dupe(u8, linkTarget);
        return linkTargetCopy;
    }
    // Return an empty string if no symlink exists
    return try allocator.dupe(u8, "");
}

fn updateSymlink(zigPath: []const u8, symlinkPath: []const u8) !void {
    if (builtin.os.tag == .windows) {
        if (std.fs.path.dirname(symlinkPath)) |dirname| {
            var parent_dir = try std.fs.openDirAbsolute(dirname, .{
                .iterate = true,
            });
            defer parent_dir.close();
            try parent_dir.deleteTree(std.fs.path.basename(symlinkPath));
        } else {
            @panic("sorry, dirname is not avaiable!");
        }
        if (doesDirExist(symlinkPath)) try std.fs.deleteDirAbsolute(symlinkPath);
        try copyDir(zigPath, symlinkPath);
    } else {
        if (doesFileExist(symlinkPath)) try std.fs.cwd().deleteFile(symlinkPath);
        std.posix.symlink(zigPath, symlinkPath) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try std.fs.cwd().deleteFile(symlinkPath);
                try std.posix.symlink(zigPath, symlinkPath);
            },
            else => return err,
        };
    }
}

fn copyDir(source_dir: []const u8, dest_dir: []const u8) !void {
    var source = try std.fs.openDirAbsolute(
        source_dir,
        .{ .iterate = true },
    );
    defer source.close();

    // try make dir
    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            tools.log.err("Failed to create directory: {s}", .{dest_dir});
            return err;
        },
    };

    var dest = try std.fs.openDirAbsolute(
        dest_dir,
        .{ .iterate = true },
    );
    defer dest.close();

    var iterate = source.iterate();
    const allocator = tools.getAllocator();
    while (try iterate.next()) |entry| {
        const entry_name = entry.name;

        const source_sub_path = try std.fs.path.join(
            allocator,
            &.{ source_dir, entry_name },
        );
        defer allocator.free(source_sub_path);

        const dest_sub_path = try std.fs.path.join(
            allocator,
            &.{ dest_dir, entry_name },
        );
        defer allocator.free(dest_sub_path);

        switch (entry.kind) {
            .directory => {
                try copyDir(source_sub_path, dest_sub_path);
            },
            .file => {
                try std.fs.copyFileAbsolute(source_sub_path, dest_sub_path, .{});
            },
            else => {},
        }
    }
}

fn doesDirExist(path: []const u8) bool {
    const result = blk: {
        _ = std.fs.openDirAbsolute(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            }
        };
        break :blk true;
    };
    return result;
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
        return error.WrongVersion;
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expectedVersion});
    }
}

fn retrieveZigVersion(allocator: std.mem.Allocator) ![]u8 {
    const userHome = tools.getHome();
    const symlinkPath = try std.fs.path.join(allocator, &[_][]const u8{ userHome, ".zm", "current" });
    defer allocator.free(symlinkPath);

    var childProcess = std.process.Child.init(&[_][]const u8{ "zig", "version" }, allocator);

    childProcess.stdin_behavior = .Close;
    childProcess.stdout_behavior = .Pipe;
    childProcess.stderr_behavior = .Close;

    try childProcess.spawn();

    if (childProcess.stdout) |stdout| {
        return try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
    }

    return error.FailedToReadVersion;
}
