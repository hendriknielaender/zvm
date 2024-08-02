const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const download = @import("download.zig");
const architecture = @import("architecture.zig");
const tools = @import("tools.zig");
const meta = @import("meta.zig");
const Allocator = std.mem.Allocator;
const io = std.io;
const json = std.json;
const fs = std.fs;
const crypto = std.crypto;
const os = std.os;

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

const Error = error{
    HttpError,
    UnsupportedVersion,
    JSONParsingFailed,
    MissingExpectedFields,
    FileError,
    HashMismatch,
    ContentMissing,
};

/// Try to install the specified version of zig
pub fn from_version(version: []const u8) !void {
    const allocator = tools.get_allocator();

    const platform_str = try architecture.platform_str(architecture.DetectParams{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // get version data
    const version_data: ?meta.Zig.VersionData = blk: {
        const res = try tools.http_get(allocator, config.zig_url);
        defer allocator.free(res);

        var zig_meta = try meta.Zig.init(res, allocator);
        defer zig_meta.deinit();

        break :blk try zig_meta.get_version_data(version, platform_str, allocator);
    };

    if (version_data) |data| {
        defer data.deinit(allocator);
        std.debug.print("Install {s}\n", .{data.version});

        const computed_hash = try download.content(allocator, data.version, data.tarball);
        if (computed_hash) |shasum| {
            if (!tools.verify_hash(shasum, data.shasum)) {
                return error.HashMismatch;
            }
        }
    } else {
        return Error.UnsupportedVersion;
    }
}
