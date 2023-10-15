const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("std").crypto;
const architecture = @import("architecture.zig");
const progress = @import("progress.zig");
const alias = @import("alias.zig");
const lib = @import("libarchive/libarchive.zig");

const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

fn getZvmPathSegment(segment: []const u8) ![]u8 {
    const user_home = std.os.getenv("HOME") orelse ".";
    return std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ user_home, ".zvm", segment });
}

pub fn content(allocator: std.mem.Allocator, version: []const u8, url: []const u8) !?[32]u8 {
    const uri = std.Uri.parse(url) catch unreachable;
    const version_folder_name = try std.fmt.allocPrint(allocator, "versions/{s}", .{version});
    defer allocator.free(version_folder_name);

    const version_folder_path = try getZvmPathSegment(version_folder_name);
    defer allocator.free(version_folder_path);

    if (checkExistingVersion(version_folder_path)) {
        std.debug.print("→ Version {s} is already installed.\n", .{version});
        std.debug.print("Do you want to reinstall? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{});

        if (!confirmUserChoice()) {
            // Ask if the version should be set as the default
            std.debug.print("Do you want to set version {s} as the default? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{version});
            if (confirmUserChoice()) {
                try alias.setZigVersion(version);
                std.debug.print("Version {s} has been set as the default.\n", .{version});
                return null;
            } else {
                std.debug.print("Aborting...\n", .{});
                return null;
            }
        }

        try std.fs.cwd().deleteTree(version_folder_path);
    } else {
        std.debug.print("→ Version {s} is not installed. Beginning download...\n", .{version});
    }

    const version_path = try getZvmPathSegment("versions");
    defer allocator.free(version_path);

    const computedHash = try downloadAndExtract(allocator, uri, version_path, version);

    try alias.setZigVersion(version);

    return computedHash;
}

fn checkExistingVersion(version_path: []const u8) bool {
    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    _ = std.fs.cwd().openDir(version_path, openDirOptions) catch return false;
    return true;
}

fn confirmUserChoice() bool {
    var buffer: [4]u8 = undefined;
    _ = std.io.getStdIn().read(buffer[0..]) catch return false;

    return std.ascii.toLower(buffer[0]) == 'y';
}

fn downloadAndExtract(allocator: std.mem.Allocator, uri: std.Uri, version_path: []const u8, version: []const u8) !?[32]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{ .allocator = allocator }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);

    var zvm_dir = try openOrCreateZvmDir();
    defer zvm_dir.close();

    const platform = try architecture.detect(allocator, architecture.DetectParams{ .os = builtin.os.tag, .arch = builtin.cpu.arch, .reverse = false }) orelse unreachable;
    defer allocator.free(platform);
    std.debug.print("→ Downloading Zig version {s} for platform {s}...\n", .{ version, platform });

    const file_name = try std.mem.concat(allocator, u8, &[_][]const u8{ "zig-", platform, "-", version, ".", archive_ext });

    defer allocator.free(file_name);

    const totalSize = req.response.content_length orelse 0;
    var downloadedBytes: usize = 0;

    const file_stream = try zvm_dir.createFile(file_name, .{});
    defer file_stream.close();

    var sha256 = crypto.sha256.Sha256.init();

    while (true) {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try req.reader().read(buffer[0..]);
        if (bytes_read == 0) break;

        downloadedBytes += bytes_read;
        progress.print(downloadedBytes, totalSize);

        sha256.update(buffer[0..bytes_read]);

        try file_stream.writeAll(buffer[0..bytes_read]);
    }

    const file_path = try zvm_dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    _ = try lib.extractTarXZ(file_path);
    // TODO: use std.tar.pipeToFileSystem() in the future, currently very slow

    // libarchive can't set dest path so it extracts to cwd
    // rename here moves the extracted folder to the correct path
    // (cwd)/zig-linux-x86_64-0.11.0 -> ~/zvm/versions/0.11.0
    const fx = try std.fmt.allocPrint(allocator, "zig-{s}-{s}", .{ platform, version });
    defer allocator.free(fx);

    const lastp = try std.fs.path.join(allocator, &.{ version_path, version });
    defer allocator.free(lastp);

    std.fs.makeDirAbsolute(version_path) catch {};

    std.debug.print("Renaming '{s}' to '{s}'\n", .{ fx, lastp });

    if (std.fs.cwd().rename(fx, lastp)) |_| {
        std.debug.print("✓ Successfully renamed {s} to {s}.\n", .{ fx, lastp });
    } else |err| {
        std.debug.print("✗ Error: Failed to rename {s} to {s}. Reason: {any}\n", .{ fx, lastp, err });
        return null;
    }

    return sha256.final();
}

fn openOrCreateZvmDir() !std.fs.Dir {
    const zvm_path = try getZvmPathSegment("");
    defer std.heap.page_allocator.free(zvm_path);

    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    const potentialDir = std.fs.cwd().openDir(zvm_path, openDirOptions);

    if (potentialDir) |dir| {
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("→ Directory not found. Creating: {s}...\n", .{zvm_path});

            if (std.fs.cwd().makeDir(zvm_path)) |_| {
                std.debug.print("✓ Directory created successfully: {s}\n", .{zvm_path});
            } else |errMakeDir| {
                std.debug.print("✗ Error: Failed to create directory. Reason: {}\n", .{errMakeDir});
            }

            return std.fs.cwd().openDir(zvm_path, openDirOptions);
        },
        else => |e| {
            std.debug.print("Unexpected error when checking directory: {}\n", .{e});
            return e;
        },
    }
}
