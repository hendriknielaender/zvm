const std = @import("std");
const Target = std.Target;
const testing = std.testing;

pub fn detect(os: Target.Os.Tag, arch: Target.Cpu.Arch) ![]const u8 {
    switch (os) {
        .linux => switch (arch) {
            .x86_64 => return "x86_64-linux",
            .aarch64 => return "aarch64-linux",
            .arm => return "armv7a-linux",
            .riscv64 => return "riscv64-linux",
            .powerpc64le => return "powerpc64le-linux",
            .powerpc => return "powerpc-linux",
            //.i386 => return "x86-linux",
            else => return error.UnsupportedSystem,
        },
        .macos => switch (arch) {
            .x86_64 => return "x86_64-macos",
            .aarch64 => return "aarch64-macos",
            else => return error.UnsupportedSystem,
        },
        .windows => switch (arch) {
            .x86_64 => return "x86_64-windows",
            .aarch64 => return "aarch64-windows",
            //.i386 => return "x86-windows",
            else => return error.UnsupportedSystem,
        },
        else => return error.UnsupportedSystem,
    }
}

// Unit Test
test "detect() Test" {
    {
        const result = try detect(Target.Os.Tag.linux, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("x86_64-linux", result);
    }
    // Test for aarch64-linux
    {
        const result = try detect(Target.Os.Tag.linux, Target.Cpu.Arch.aarch64);
        try testing.expectEqualStrings("aarch64-linux", result);
    }

    // Test for x86_64-macos
    {
        const result = try detect(Target.Os.Tag.macos, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("x86_64-macos", result);
    }

    // Test for x86_64-windows
    {
        const result = try detect(Target.Os.Tag.windows, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("x86_64-windows", result);
    }
}
