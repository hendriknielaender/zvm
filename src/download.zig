const std = @import("std");
const progress = @import("progress.zig");
const tar = @import("tar.zig");

var gpa: std.mem.Allocator = undefined;

pub fn content(allocator: std.mem.Allocator, url: []const u8) !void {
    const uri = std.Uri.parse(url) catch unreachable;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    gpa = arena_allocator.allocator();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{ .allocator = allocator }, .{});
    defer req.deinit();
    try req.start();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);

    const totalSize = req.response.content_length orelse 0;

    // Check what we have.
    var downloads = try openOrCreateZvmDir();
    defer downloads.close();

    std.log.info("Downloading: {s}", .{"x86"});
    downloads.makeDir(".tmp") catch |err| switch (err) {
        error.PathAlreadyExists => {
            try downloads.deleteTree(".tmp");
            try downloads.makeDir(".tmp");
        },
        else => return err,
    };

    const extract_dir = try downloads.openDir(".tmp", .{});
    // Use a buffered reader to work around a bug in the tls implementation.
    //var br = std.io.bufferedReaderSize(std.crypto.tls.max_ciphertext_record_len, req.reader());

    // Download and extract at the same time.
    var xz = try std.compress.xz.decompress(gpa, req.reader());
    defer xz.deinit();
    try tar.pipeToFileSystemWithProgress(extract_dir, xz.reader(), .{ .mode_mode = .ignore, .strip_components = 0 }, totalSize);
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    _ = try std.fmt.bufPrint(buffer[0..], ".tmp/{s}", .{"yoyo"});
}

fn openOrCreateZvmDir() !std.fs.Dir {
    const allocator = std.heap.page_allocator; // or another allocator you prefer
    const user_home = std.os.getenv("HOME") orelse ".";
    const paths = &[_][]const u8{ user_home, "zvm" };
    const zvm_path = try std.fs.path.join(allocator, paths);

    std.debug.print("Trying to open or create path: {s}\n", .{zvm_path});

    defer allocator.free(zvm_path);

    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    const potentialDir = std.fs.cwd().openDir(zvm_path, openDirOptions);

    if (potentialDir) |dir| {
        return dir;
    } else |err| switch (err) {
        error.BadPathName => {
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
