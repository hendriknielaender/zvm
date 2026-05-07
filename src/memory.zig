const std = @import("std");
const pools = @import("memory/object_pools.zig");
const static_memory = @import("memory/static_memory.zig");
const assert = std.debug.assert;

pub const ExtractOperation = pools.ExtractOperation;
pub const HttpOperation = pools.HttpOperation;
pub const ObjectPools = pools.ObjectPools;
pub const PathBuffer = pools.PathBuffer;
pub const ProcessBuffer = pools.ProcessBuffer;
pub const StaticMemory = static_memory.StaticMemory;
pub const VersionEntry = pools.VersionEntry;

pub const ScratchKind = enum {
    path,
    http,
    extract,
};

pub fn Scratch(comptime kind: ScratchKind) type {
    return struct {
        resource: Resource,
        released: bool = false,

        const ScratchGuard = @This();
        const Resource = switch (kind) {
            .path => *PathBuffer,
            .http => *HttpOperation,
            .extract => *ExtractOperation,
        };

        pub fn init(resource: Resource) ScratchGuard {
            return .{ .resource = resource };
        }

        pub fn release(self: *ScratchGuard) void {
            assert(!self.released);
            switch (kind) {
                .path => self.resource.reset(),
                .http => self.resource.release(),
                .extract => self.resource.release(),
            }
            self.released = true;
        }

        pub fn slice(self: *const ScratchGuard) []u8 {
            assert(kind == .path);
            assert(!self.released);
            return self.resource.slice();
        }

        pub fn set(self: *const ScratchGuard, value: []const u8) ![]const u8 {
            assert(kind == .path);
            assert(!self.released);
            return self.resource.set(value);
        }

        pub fn used_slice(self: *const ScratchGuard) []const u8 {
            assert(kind == .path);
            assert(!self.released);
            return self.resource.used_slice();
        }

        pub fn print(
            self: *const ScratchGuard,
            comptime format: []const u8,
            args: anytype,
        ) ![]const u8 {
            assert(kind == .path);
            assert(!self.released);
            return self.set(try std.fmt.bufPrint(self.slice(), format, args));
        }

        pub fn operation(self: *const ScratchGuard) Resource {
            assert(kind == .http or kind == .extract);
            assert(!self.released);
            return self.resource;
        }
    };
}

pub fn acquire_scratch(
    pools_store: *ObjectPools,
    comptime kind: ScratchKind,
) !Scratch(kind) {
    return switch (kind) {
        .path => Scratch(.path).init(try pools_store.acquire_path_buffer()),
        .http => Scratch(.http).init(try pools_store.acquire_http_operation()),
        .extract => Scratch(.extract).init(try pools_store.acquire_extract_operation()),
    };
}
