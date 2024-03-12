const std = @import("std");

pub const DetectParams = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    reverse: bool = false,
};

fn osToString(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => null,
    };
}

fn archToString(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .riscv64 => "riscv64",
        .powerpc64le => "powerpc64le",
        .powerpc => "powerpc",
        else => null,
    };
}

pub fn detect(allocator: std.mem.Allocator, params: DetectParams) !?[]u8 {
    const osStr = osToString(params.os) orelse return error.UnsupportedSystem;
    const archStr = archToString(params.arch) orelse return error.UnsupportedSystem;

    const len = osStr.len + archStr.len + 1; // +1 for the '-'

    const result = try allocator.alloc(u8, len);

    if (params.reverse) {
        @memcpy(result[0..archStr.len], archStr);
        result[archStr.len] = '-';
        @memcpy(result[archStr.len + 1 ..], osStr);
    } else {
        @memcpy(result[0..osStr.len], osStr);
        result[osStr.len] = '-';
        @memcpy(result[osStr.len + 1 ..], archStr);
    }

    return result;
}

test "detect() Test" {
    const allocator = std.testing.allocator;

    {
        const result = try detect(allocator, DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
        defer allocator.free(result);
        try std.testing.expectEqualStrings("linux-x86_64", result);
    }

    {
        const result = try detect(allocator, DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.aarch64, .reverse = true }) orelse unreachable;
        defer allocator.free(result);
        try std.testing.expectEqualStrings("aarch64-linux", result);
    }

    {
        const result = try detect(allocator, DetectParams{ .os = std.Target.Os.Tag.macos, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
        defer allocator.free(result);
        try std.testing.expectEqualStrings("macos-x86_64", result);
    }

    {
        const result = try detect(allocator, DetectParams{ .os = std.Target.Os.Tag.windows, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
        defer allocator.free(result);
        try std.testing.expectEqualStrings("windows-x86_64", result);
    }
}
