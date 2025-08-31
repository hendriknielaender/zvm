//! This file is used to splice os and architecture into the correct file name
const std = @import("std");
const object_pools = @import("../memory/object_pools.zig");
const context = @import("../Context.zig");

pub const DetectParams = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    reverse: bool = false,
    is_master: bool = false,
};

fn os_to_string(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => null,
    };
}

fn arch_to_string(arch: std.Target.Cpu.Arch) ?[]const u8 {
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

fn arch_to_string_master(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm", // Master uses "arm" instead of "armv7a"
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
    const os_str = (comptime os_to_string(params.os)) orelse {
        @compileError("Unsupported operating system: " ++ @tagName(params.os) ++ ". Supported: windows, linux, macos");
    };

    const arch_str = if (params.is_master)
        (comptime arch_to_string_master(params.arch)) orelse {
            @compileError("Unsupported architecture for master builds: " ++ @tagName(params.arch) ++ ". Supported: x86_64, aarch64, arm, riscv64, powerpc64le, powerpc");
        }
    else
        (comptime arch_to_string(params.arch)) orelse {
            @compileError("Unsupported architecture: " ++ @tagName(params.arch) ++ ". Supported: x86_64, aarch64, armv7a, riscv64, powerpc64le, powerpc");
        };

    if (params.reverse)
        return arch_str ++ "-" ++ os_str;

    return os_str ++ "-" ++ arch_str;
}

/// Runtime version of platform_str using static allocation.
pub fn platform_str_static(buffer: *object_pools.PathBuffer, params: DetectParams) !?[]const u8 {
    const os_str = os_to_string(params.os) orelse {
        std.log.err("Unsupported operating system: {s}. Supported: windows, linux, macos", .{@tagName(params.os)});
        return error.UnsupportedSystem;
    };

    const arch_str = if (params.is_master)
        arch_to_string_master(params.arch) orelse {
            std.log.err("Unsupported architecture for master builds: {s}. Supported: x86_64, aarch64, arm, riscv64, powerpc64le, powerpc", .{@tagName(params.arch)});
            return error.UnsupportedSystem;
        }
    else
        arch_to_string(params.arch) orelse {
            std.log.err("Unsupported architecture: {s}. Supported: x86_64, aarch64, armv7a, riscv64, powerpc64le, powerpc", .{@tagName(params.arch)});
            return error.UnsupportedSystem;
        };

    var fbs = std.io.fixedBufferStream(buffer.slice());
    if (params.reverse) {
        try fbs.writer().print("{s}-{s}", .{ arch_str, os_str });
    } else {
        try fbs.writer().print("{s}-{s}", .{ os_str, arch_str });
    }

    return try buffer.set(fbs.getWritten());
}

/// Platform string for ZLS using static allocation.
pub fn platform_str_for_zls(ctx: *context.CliContext) !?[]const u8 {
    var buffer = try ctx.acquire_path_buffer();
    defer buffer.reset();

    const params = DetectParams{
        .os = @import("builtin").os.tag,
        .arch = @import("builtin").cpu.arch,
        .reverse = true, // ZLS uses arch-os format
        .is_master = false,
    };

    return try platform_str_static(buffer, params);
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
