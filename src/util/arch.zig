//! This file is used to splice os and architecture into the correct file name
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

/// get platform str
///
/// in offical zig json
/// use "arch-platform" as key
/// use "platform-arch" as file name
///
/// for performance, we treat this function as comptime-func
pub fn platform_str(comptime params: DetectParams) !?[]const u8 {
    const os_str = (comptime osToString(params.os)) orelse
        return error.UnsupportedSystem;

    const arch_str = (comptime archToString(params.arch)) orelse
        return error.UnsupportedSystem;

    if (params.reverse)
        return arch_str ++ "-" ++ os_str;

    return os_str ++ "-" ++ arch_str;
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
}
