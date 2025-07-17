//! This file is used to splice os and architecture into the correct file name
const std = @import("std");

pub const DetectParams = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    reverse: bool = false,
    is_master: bool = false,
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

fn archToStringMaster(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",  // Master uses "arm" instead of "armv7a"
        .riscv64 => "riscv64",
        .powerpc64le => "powerpc64le",
        .powerpc => "powerpc",
        else => null,
    };
}

/// get platform str
///
/// in offical zig json
/// use "arch-platform" as key
/// use "platform-arch" as file name
///
/// for performance, we treat this function as comptime-func when possible
pub fn platform_str(comptime params: DetectParams) !?[]const u8 {
    const os_str = (comptime osToString(params.os)) orelse
        return error.UnsupportedSystem;

    const arch_str = if (params.is_master)
        (comptime archToStringMaster(params.arch)) orelse
            return error.UnsupportedSystem
    else
        (comptime archToString(params.arch)) orelse
            return error.UnsupportedSystem;

    if (params.reverse)
        return arch_str ++ "-" ++ os_str;

    return os_str ++ "-" ++ arch_str;
}

/// Runtime version of platform_str for when parameters are not known at compile time
pub fn platform_str_runtime(params: DetectParams, allocator: std.mem.Allocator) !?[]const u8 {
    const os_str = osToString(params.os) orelse
        return error.UnsupportedSystem;

    const arch_str = if (params.is_master)
        archToStringMaster(params.arch) orelse
            return error.UnsupportedSystem
    else
        archToString(params.arch) orelse
            return error.UnsupportedSystem;

    if (params.reverse) {
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch_str, os_str });
    }

    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_str, arch_str });
}

test "detect() Test" {
    const result_1 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
    try std.testing.expectEqualStrings("linux-x86_64", result_1);

    const result_2 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.aarch64, .reverse = true }) orelse unreachable;
    try std.testing.expectEqualStrings("aarch64-linux", result_2);

    const result_3 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.macos, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
    try std.testing.expectEqualStrings("macos-x86_64", result_3);

    const result_4 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.windows, .arch = std.Target.Cpu.Arch.x86_64 }) orelse unreachable;
    try std.testing.expectEqualStrings("windows-x86_64", result_4);

    // Test master version with ARM architecture
    const result_5 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.arm, .reverse = true, .is_master = true }) orelse unreachable;
    try std.testing.expectEqualStrings("arm-linux", result_5);

    // Test stable version with ARM architecture
    const result_6 = try platform_str(DetectParams{ .os = std.Target.Os.Tag.linux, .arch = std.Target.Cpu.Arch.arm, .reverse = false, .is_master = false }) orelse unreachable;
    try std.testing.expectEqualStrings("linux-armv7a", result_6);
}
