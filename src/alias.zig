const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

pub fn set_zig_version(version: []const u8) !void {
    const allocator = tools.get_allocator();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const user_home = tools.get_home();
    const zig_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ user_home, ".zm", "versions", version });
    const symlink_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ user_home, ".zm", "current" });

    try update_symlink(zig_path, symlink_path);
    try verify_zig_version(allocator, version);
}

fn update_symlink(zig_path: []const u8, symlink_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        if (std.fs.path.dirname(symlink_path)) |dirname| {
            var parent_dir = try std.fs.openDirAbsolute(dirname, .{ .iterate = true });
            defer parent_dir.close();
            try parent_dir.deleteTree(std.fs.path.basename(symlink_path));
        } else {
            @panic("dirname is not available!");
        }
        if (does_dir_exist(symlink_path)) try std.fs.deleteDirAbsolute(symlink_path);
        try copy_dir(zig_path, symlink_path);
    } else {
        if (does_file_exist(symlink_path)) try std.fs.cwd().deleteFile(symlink_path);
        std.posix.symlink(zig_path, symlink_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try std.fs.cwd().deleteFile(symlink_path);
                try std.posix.symlink(zig_path, symlink_path);
            },
            else => return err,
        };
    }
}

fn copy_dir(source_dir: []const u8, dest_dir: []const u8) !void {
    var source = try std.fs.openDirAbsolute(source_dir, .{ .iterate = true });
    defer source.close();

    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            tools.log.err("Failed to create directory: {s}", .{dest_dir});
            return err;
        },
    };

    var dest = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest.close();

    var iterate = source.iterate();
    const allocator = tools.get_allocator();
    while (try iterate.next()) |entry| {
        const entry_name = entry.name;

        const source_sub_path = try std.fs.path.join(allocator, &.{ source_dir, entry_name });
        defer allocator.free(source_sub_path);

        const dest_sub_path = try std.fs.path.join(allocator, &.{ dest_dir, entry_name });
        defer allocator.free(dest_sub_path);

        switch (entry.kind) {
            .directory => try copy_dir(source_sub_path, dest_sub_path),
            .file => try std.fs.copyFileAbsolute(source_sub_path, dest_sub_path, .{}),
            else => {},
        }
    }
}

fn does_dir_exist(path: []const u8) bool {
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

fn does_file_exist(path: []const u8) bool {
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

fn verify_zig_version(allocator: std.mem.Allocator, expected_version: []const u8) !void {
    const actual_version = try retrieve_zig_version(allocator);
    defer allocator.free(actual_version);

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        std.debug.print("Expected Zig version {s}, but currently using {s}. Please check.\n", .{ expected_version, actual_version });
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expected_version});
    }
}

fn retrieve_zig_version(allocator: std.mem.Allocator) ![]u8 {
    const user_home = tools.get_home();
    const symlink_path = try std.fs.path.join(allocator, &[_][]const u8{ user_home, ".zm", "current" });
    defer allocator.free(symlink_path);

    var child_process = std.process.Child.init(&[_][]const u8{ "zig", "version" }, allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        return try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
    }

    return error.FailedToReadVersion;
}
