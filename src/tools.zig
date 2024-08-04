//! this file just contains util function
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

const testing = std.testing;

/// Initialize the data.
pub fn data_init(tmp_allocator: std.mem.Allocator) !void {
    config.allocator = tmp_allocator;
    config.home_dir = if (builtin.os.tag == .windows)
        try std.process.getEnvVarOwned(config.allocator, "USERPROFILE")
    else
        std.posix.getenv("HOME") orelse ".";

    // config.progress_root = std.Progress.start(.{ .root_name = "zvm" });
}

/// Deinitialize the data.
pub fn data_deinit() void {
    if (builtin.os.tag == .windows)
        config.allocator.free(config.home_dir);

    // config.progress_root.end();
}

/// new progress node
pub fn new_progress_node(name: []const u8, estimated_total_items: usize) std.Progress.Node {
    return config.progress_root.start(name, estimated_total_items);
}

/// Get home directory.
pub fn get_home() []const u8 {
    return config.home_dir;
}

/// Get the allocator.
pub fn get_allocator() std.mem.Allocator {
    return config.allocator;
}

/// Get zvm path segment
pub fn get_zvm_path_segment(tmp_allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    return std.fs.path.join(
        tmp_allocator,
        &[_][]const u8{ get_home(), ".zm", segment },
    );
}

/// Free str array
pub fn free_str_array(str_arr: []const []const u8, allocator: std.mem.Allocator) void {
    for (str_arr) |str|
        allocator.free(str);

    allocator.free(str_arr);
}

/// For verifying hash
pub fn verify_hash(computed_hash: [32]u8, actual_hash_string: [64]u8) bool {
    // if (actual_hash_string.len != 64) return false; // SHA256 hash should be 64 hex characters

    var actual_hash_bytes: [32]u8 = undefined;
    var i: usize = 0;

    for (actual_hash_string) |char| {
        const byte = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return false, // Invalid character in hash string
        };

        if (i % 2 == 0) {
            actual_hash_bytes[i / 2] = byte << 4;
        } else {
            actual_hash_bytes[i / 2] |= byte;
        }

        i += 1;
    }

    return std.mem.eql(u8, computed_hash[0..], actual_hash_bytes[0..]);
}

test "verify_hash basic test" {
    const sample_hash: [32]u8 = [_]u8{ 0x33, 0x9a, 0x89, 0xdc, 0x08, 0x73, 0x6b, 0x84, 0xc4, 0x75, 0x2b, 0x3d, 0xed, 0xdc, 0x0f, 0x2c, 0x71, 0xb5, 0x0b, 0x66, 0xa2, 0x68, 0x5f, 0x26, 0x77, 0x9c, 0xbb, 0xac, 0x46, 0x11, 0x1b, 0x68 };

    var sample_hash_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&sample_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(sample_hash[0..])}) catch unreachable;

    try testing.expect(verify_hash(sample_hash, &sample_hash_hex));
    try testing.expect(!verify_hash(sample_hash, "incorrect_hash"));
}

/// http get
pub fn http_get(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {

    // create a http client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // we ceate a buffer to store the http response
    var buf: [1024]u8 = undefined; // 256 * 1024 = 262kb

    // try open a request
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    // send request and wait response
    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.ListResponseNotOk;
    }

    const res = try req.reader().readAllAlloc(allocator, 256 * 1024);
    return res;
}

/// eql str
pub fn eql_str(str1: []const u8, str2: []const u8) bool {
    return std.mem.eql(u8, str1, str2);
}

/// try to create path
pub fn try_create_path(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err|
        if (err != error.PathAlreadyExists) return err;
}

/// try to get zig version
pub fn get_zig_version(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = get_home();
    const current_zig_path = try std.fs.path.join(allocator, &.{ home_dir, ".zm", "current", config.zig_name });
    defer allocator.free(current_zig_path);

    // here we must use the absolute path, we can not just use "zig"
    // because child process will use environment variable
    var child_process = std.process.Child.init(&[_][]const u8{ current_zig_path, "version" }, allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        const version = try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
        return version;
    }

    return error.FailedToReadVersion;
}

// check dir exist
pub fn does_path_exist(version_path: []const u8) bool {
    std.fs.accessAbsolute(version_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

/// Nested copy dir
/// only copy dir and file, no including link
pub fn copy_dir(source_dir: []const u8, dest_dir: []const u8) !void {
    var source = try std.fs.openDirAbsolute(source_dir, .{ .iterate = true });
    defer source.close();

    std.fs.makeDirAbsolute(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists)
            return err;
    };

    var dest = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest.close();

    var iterate = source.iterate();
    const allocator = get_allocator();
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
