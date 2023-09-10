const std = @import("std");
const Target = std.Target;
const testing = std.testing;

pub fn detect(os: Target.Os.Tag, arch: Target.Cpu.Arch) ![]const u8 {
    switch (os) {
        .linux => switch (arch) {
            .x86_64 => return "linux-x86_64",
            .aarch64 => return "linux-xaarch64",
            .arm => return "linux-xarmv7a",
            .riscv64 => return "linux-xriscv64",
            .powerpc64le => return "linux-xpowerpc64le",
            .powerpc => return "linux-xpowerpc",
            //.i386 => return "linux-xx86",
            else => return error.UnsupportedSystem,
        },
        .macos => switch (arch) {
            .x86_64 => return "macos-x86_64",
            .aarch64 => return "macos-xaarch64",
            else => return error.UnsupportedSystem,
        },
        .windows => switch (arch) {
            .x86_64 => return "windows-x86_64",
            .aarch64 => return "windows-aarch64",
            //.i386 => return "windows-x86",
            else => return error.UnsupportedSystem,
        },
        else => return error.UnsupportedSystem,
    }
}

// Unit Test
test "detect() Test" {
    {
        const result = try detect(Target.Os.Tag.linux, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("linux-x86_64", result);
    }
    // Test for aarch64-linux
    {
        const result = try detect(Target.Os.Tag.linux, Target.Cpu.Arch.aarch64);
        try testing.expectEqualStrings("linux-aarch64", result);
    }

    // Test for x86_64-macos
    {
        const result = try detect(Target.Os.Tag.macos, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("macos-x86_64", result);
    }

    // Test for x86_64-windows
    {
        const result = try detect(Target.Os.Tag.windows, Target.Cpu.Arch.x86_64);
        try testing.expectEqualStrings("windows-x86_64", result);
    }
}
