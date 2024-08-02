const std = @import("std");
const config = @import("config.zig");

const json = std.json;
const Allocator = std.mem.Allocator;
const jsonValue = std.json.Parsed(std.json.Value);

pub const Zig = struct {
    data: jsonValue,

    // init the zig data
    pub fn init(raw: []const u8, allocator: Allocator) !Zig {
        const data =
            try json.parseFromSlice(std.json.Value, allocator, raw, .{});

        return Zig{ .data = data };
    }

    // deinit the zig data
    pub fn deinit(self: *Zig) void {
        self.data.deinit();
    }

    /// return the version list
    pub fn get_version_list(self: *Zig, allocator: Allocator) ![][]const u8 {
        const root = self.data.value;

        var list = std.ArrayList([]const u8).init(allocator);
        var iterate = root.object.iterator();

        while (iterate.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const key = key_ptr.*;

            const key_copy = try allocator.dupe(u8, key);
            try list.append(key_copy);
        }

        return try list.toOwnedSlice();
    }
};

pub const Zls = struct {
    data: jsonValue,

    // init the zig data
    pub fn init(raw: []const u8, allocator: Allocator) !Zls {
        const data =
            try json.parseFromSlice(std.json.Value, allocator, raw, .{});

        return Zls{ .data = data };
    }

    // deinit the zig data
    pub fn deinit(self: *Zls) void {
        self.data.deinit();
    }

    /// return the version list
    pub fn get_version_list(self: *Zls, allocator: Allocator) ![][]const u8 {
        var zls_versions =
            self.data.value.object.get("versions") orelse
            return error.NotFoundZlsVersion;

        var list = std.ArrayList([]const u8).init(allocator);

        var iterate = zls_versions.object.iterator();
        while (iterate.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const key = key_ptr.*;

            const key_copy = try allocator.dupe(u8, key);
            try list.append(key_copy);
        }

        const slice = try list.toOwnedSlice();

        std.mem.reverse([]const u8, slice);
        return slice;
    }
};
