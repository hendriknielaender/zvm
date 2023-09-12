const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture.zig");
const progress = @import("progress.zig");
const set = @import("set.zig");
const tarC = @import("c/tar.zig");

var gpa: std.mem.Allocator = undefined;

const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

pub fn content(allocator: std.mem.Allocator, version: []const u8, url: []const u8) !void {
    const uri = std.Uri.parse(url) catch unreachable;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    gpa = arena_allocator.allocator();

    // Generate the version folder path
    const user_home = std.os.getenv("HOME") orelse ".";
    const paths = &[_][]const u8{ user_home, ".zvm", "versions", version };
    const version_path = try std.fs.path.join(allocator, paths);

    // Check if the version folder exists
    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    const potentialDir = std.fs.cwd().openDir(version_path, openDirOptions);
    if (potentialDir) |_| {
        // Directory for the version exists, prompt user for reinstallation
        std.debug.print("Version {s} already exists. Do you want to reinstall it? (yes/no) ", .{version});

        var buffer: [4]u8 = undefined;
        _ = try std.io.getStdIn().read(buffer[0..]);
        if (std.mem.eql(u8, buffer[0..3], "yes")) {
            std.debug.print("Reinstalling version {s}...\n", .{version});
            try std.fs.cwd().deleteTree(version_path);
        } else {
            std.debug.print("Aborting...\n", .{});
            return;
        }
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                // Directory doesn't exist, proceed with download.
                std.debug.print("Version not found. Proceeding with download...\n", .{});
            },
            else => {
                std.debug.print("Error opening directory: {}\n", .{err});
                return err;
            },
        }
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{ .allocator = allocator }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);

    var zvm_dir = try openOrCreateZvmDir();
    defer zvm_dir.close();

    const platform = try architecture.detect(builtin.os.tag, builtin.cpu.arch);
    std.debug.print("Downloading: {s}", .{platform});
    const file_name = try std.mem.concat(allocator, u8, &[_][]const u8{ "zig-", platform, "-", version, ".", archive_ext });

    defer allocator.free(file_name);

    const totalSize = req.response.content_length orelse 0;
    var downloadedBytes: usize = 0;

    const file_stream = try zvm_dir.createFile(file_name, .{});
    defer file_stream.close();

    while (true) {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try req.reader().read(buffer[0..]);
        if (bytes_read == 0) break;

        downloadedBytes += bytes_read;
        progress.print(downloadedBytes, totalSize);
        try file_stream.writeAll(buffer[0..bytes_read]);
    }

    // Download and extract.
    const file_path = try zvm_dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    _ = try tarC.extractTarXZ(file_path);
    // TODO: use std.tar.pipeToFileSystem() in the future, currently very slow

    // libarchive can't set dest path so it extracts to cwd
    // rename here moves the extracted folder to the correct path
    // (cwd)/zig-linux-x86_64-0.11.0 -> ~/zvm/versions/0.11.0
    const fx = try std.fmt.allocPrint(allocator, "zig-{s}-{s}", .{ platform, version });
    defer allocator.free(fx);

    const _zvmver = try std.fs.path.join(allocator, &.{ user_home, ".zvm", "versions" });
    defer allocator.free(_zvmver);

    const lastp = try std.fs.path.join(allocator, &.{ _zvmver, version });
    defer allocator.free(lastp);

    // create .zvm/versions if it doesn't exist
    std.fs.makeDirAbsolute(_zvmver) catch {};

    std.debug.print("Renaming '{s}' to '{s}'\n", .{ fx, lastp });

    if (std.fs.cwd().rename(fx, lastp)) |_| {
        std.debug.print("Successfully renamed {s} to {s}\n", .{ fx, lastp });
    } else |err| {
        std.debug.print("Failed to rename {s} to {s}.\n \n Error: {any}\n", .{ fx, lastp, err });
    }

    try set.zigVersion(version);
}

fn openOrCreateZvmDir() !std.fs.Dir {
    const allocator = std.heap.page_allocator;
    const user_home = std.os.getenv("HOME") orelse ".";
    const paths = &[_][]const u8{ user_home, ".zvm" };
    const zvm_path = try std.fs.path.join(allocator, paths);

    std.debug.print("Trying to open or create path: {s}\n", .{zvm_path});

    defer allocator.free(zvm_path);

    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    const potentialDir = std.fs.cwd().openDir(zvm_path, openDirOptions);

    if (potentialDir) |dir| {
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Attempting to create directory: {s}\n", .{zvm_path});

            // Make directory
            if (std.fs.cwd().makeDir(zvm_path)) |_| {
                // Directory created successfully
                std.debug.print("Directory created successfully: {s}\n", .{zvm_path});
            } else |errMakeDir| {
                std.debug.print("Error creating directory: {}\n", .{errMakeDir});
            }

            // Try opening the created directory
            return std.fs.cwd().openDir(zvm_path, openDirOptions);
        },
        else => |e| {
            std.debug.print("Unexpected error when checking directory: {}\n", .{e});
            return e;
        },
    }
}
