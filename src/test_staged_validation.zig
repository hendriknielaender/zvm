const std = @import("std");
const testing = std.testing;

// Import modules from same directory
const raw_args = @import("cli/raw_args.zig");
const validation = @import("cli/validation.zig");
const limits = @import("memory/limits.zig");

test "raw args parsing - install command" {
    const install_raw = try raw_args.parse_raw_args("install", &.{"0.11.0"});

    switch (install_raw) {
        .install => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(false, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - install command with zls flag" {
    const install_raw = try raw_args.parse_raw_args("install", &.{ "--zls", "0.11.0" });

    switch (install_raw) {
        .install => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(true, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - install command keeps after-version zls compatibility" {
    const install_raw = try raw_args.parse_raw_args("install", &.{ "0.11.0", "--zls" });

    switch (install_raw) {
        .install => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(true, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - use command with zls flag prefix" {
    const use_raw = try raw_args.parse_raw_args("use", &.{ "--zls", "0.11.0" });

    switch (use_raw) {
        .use => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(true, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - remove command with zls flag prefix" {
    const remove_raw = try raw_args.parse_raw_args("remove", &.{ "--zls", "0.11.0" });

    switch (remove_raw) {
        .remove => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(true, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - install command missing version" {
    const result = raw_args.parse_raw_args("install", &.{});
    try testing.expectError(error.MissingVersionArgument, result);
}

test "raw args parsing - install command empty version" {
    const result = raw_args.parse_raw_args("install", &.{""});
    try testing.expectError(error.EmptyVersionArgument, result);
}

test "raw args parsing - install command unknown flag" {
    const result = raw_args.parse_raw_args("install", &.{ "0.11.0", "--unknown" });
    try testing.expectError(error.UnknownFlag, result);
}

test "raw args parsing - install command unknown prefix flag" {
    const result = raw_args.parse_raw_args("install", &.{ "--unknown", "0.11.0" });
    try testing.expectError(error.UnknownFlag, result);
}

test "raw args parsing - command aliases" {
    const install_i = try raw_args.parse_raw_args("i", &.{"0.11.0"});
    const install_full = try raw_args.parse_raw_args("install", &.{"0.11.0"});

    // Both should be install commands
    try testing.expect(std.meta.activeTag(install_i) == .install);
    try testing.expect(std.meta.activeTag(install_full) == .install);

    const list_ls = try raw_args.parse_raw_args("ls", &.{});
    const list_full = try raw_args.parse_raw_args("list", &.{});

    // Both should be list commands
    try testing.expect(std.meta.activeTag(list_ls) == .list);
    try testing.expect(std.meta.activeTag(list_full) == .list);
}

test "raw args parsing - standard options are not commands" {
    try testing.expectError(error.UnknownCommand, raw_args.parse_raw_args("-h", &.{}));
    try testing.expectError(error.UnknownCommand, raw_args.parse_raw_args("-V", &.{}));
}

test "raw args parsing - help command accepts a topic" {
    const help_raw = try raw_args.parse_raw_args("help", &.{"list"});

    switch (help_raw) {
        .help => |cmd| try testing.expectEqualStrings("list", cmd.get_topic().?),
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - unknown command" {
    const result = raw_args.parse_raw_args("unknown-cmd", &.{});
    try testing.expectError(error.UnknownCommand, result);
}

test "raw args parsing - double dash before install version" {
    const install_raw = try raw_args.parse_raw_args("install", &.{ "--", "0.11.0" });

    switch (install_raw) {
        .install => |cmd| {
            try testing.expectEqualStrings("0.11.0", cmd.get_version());
            try testing.expectEqual(false, cmd.is_zls);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "raw args parsing - double dash stops install flags" {
    const result = raw_args.parse_raw_args("install", &.{ "0.11.0", "--", "--zls" });
    try testing.expectError(error.UnexpectedArguments, result);
}

test "raw args parsing - double dash stops list flags" {
    const result = raw_args.parse_raw_args("list", &.{ "--", "--all" });
    try testing.expectError(error.UnexpectedArguments, result);
}

test "version spec parsing - specific version" {
    const version = try validation.VersionSpec.parse("0.11.0");

    switch (version) {
        .specific => |spec| {
            try testing.expectEqual(@as(u32, 0), spec.major);
            try testing.expectEqual(@as(u32, 11), spec.minor);
            try testing.expectEqual(@as(u32, 0), spec.patch);
        },
        else => return error.UnexpectedVersionType,
    }
}

test "version spec parsing - master" {
    const version = try validation.VersionSpec.parse("master");
    try testing.expectEqual(validation.VersionSpec.master, version);
}

test "version spec parsing - latest not supported" {
    const result = validation.VersionSpec.parse("latest");
    try testing.expectError(error.LatestNotSupported, result);
}

test "version spec parsing - invalid format" {
    const result = validation.VersionSpec.parse("invalid");
    try testing.expectError(error.InvalidVersionFormat, result);
}

test "version spec parsing - too many parts" {
    const result = validation.VersionSpec.parse("1.2.3.4");
    try testing.expectError(error.TooManyVersionParts, result);
}

test "version spec parsing - semver prerelease with build metadata" {
    const version = try validation.VersionSpec.parse("0.16.0-dev.237+496313a1b");

    switch (version) {
        .specific => |spec| {
            try testing.expectEqual(@as(u32, 0), spec.major);
            try testing.expectEqual(@as(u32, 16), spec.minor);
            try testing.expectEqual(@as(u32, 0), spec.patch);
        },
        else => return error.UnexpectedVersionType,
    }
}

test "version spec parsing - invalid numbers" {
    try testing.expectError(error.InvalidMajorVersion, validation.VersionSpec.parse("abc.1.0"));
    try testing.expectError(error.InvalidMinorVersion, validation.VersionSpec.parse("1.abc.0"));
    try testing.expectError(error.InvalidPatchVersion, validation.VersionSpec.parse("1.0.abc"));
}

test "version spec parsing - bounds checking" {
    try testing.expectError(error.MajorVersionTooLarge, validation.VersionSpec.parse("100.0.0"));
    try testing.expectError(error.MinorVersionTooLarge, validation.VersionSpec.parse("0.100.0"));
    try testing.expectError(error.PatchVersionTooLarge, validation.VersionSpec.parse("0.0.1000"));
}

test "version spec creation" {
    const master: validation.VersionSpec = .master;
    try testing.expect(master == .master);

    // Latest is no longer supported, removed from enum

    const specific = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 11, .patch = 0 } };
    try testing.expect(std.meta.activeTag(specific) == .specific);
    switch (specific) {
        .specific => |s| {
            try testing.expectEqual(@as(u32, 0), s.major);
            try testing.expectEqual(@as(u32, 11), s.minor);
            try testing.expectEqual(@as(u32, 0), s.patch);
        },
        else => return error.UnexpectedTag,
    }
}

test "version spec ZLS compatibility" {
    const compatible_specific = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 11, .patch = 0 } };
    try testing.expect(compatible_specific.is_compatible_with_zls());

    const incompatible_specific = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 10, .patch = 0 } };
    try testing.expect(!incompatible_specific.is_compatible_with_zls());

    const master: validation.VersionSpec = .master;
    try testing.expect(master.is_compatible_with_zls());
    // Latest is no longer supported
}

test "tool type conversion" {
    try testing.expectEqual(validation.ToolType.zig, validation.ToolType.from_bool(false));
    try testing.expectEqual(validation.ToolType.zls, validation.ToolType.from_bool(true));

    try testing.expectEqualStrings("zig", validation.ToolType.zig.to_string());
    try testing.expectEqualStrings("zls", validation.ToolType.zls.to_string());
}

test "shell type parsing" {
    try testing.expectEqual(validation.ShellType.bash, try validation.ShellType.parse("bash"));
    try testing.expectEqual(validation.ShellType.zsh, try validation.ShellType.parse("zsh"));
    try testing.expectEqual(validation.ShellType.fish, try validation.ShellType.parse("fish"));
    try testing.expectEqual(validation.ShellType.powershell, try validation.ShellType.parse("powershell"));
    try testing.expectEqual(validation.ShellType.powershell, try validation.ShellType.parse("pwsh"));

    try testing.expectError(error.UnknownShell, validation.ShellType.parse("unknown"));
}

test "staged validation - install command" {
    const raw_install = try raw_args.parse_raw_args("install", &.{"0.11.0"});
    const validated = try validation.validate_command(raw_install);

    switch (validated) {
        .install => |cmd| {
            switch (cmd.version) {
                .specific => |spec| {
                    try testing.expectEqual(@as(u32, 0), spec.major);
                    try testing.expectEqual(@as(u32, 11), spec.minor);
                    try testing.expectEqual(@as(u32, 0), spec.patch);
                },
                else => return error.UnexpectedVersionType,
            }
            try testing.expectEqual(validation.ToolType.zig, cmd.tool);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "staged validation - install ZLS with compatibility check" {
    // Valid ZLS version
    const raw_install_valid = try raw_args.parse_raw_args("install", &.{ "--zls", "0.11.0" });
    const validated_valid = try validation.validate_command(raw_install_valid);

    switch (validated_valid) {
        .install => |cmd| {
            try testing.expectEqual(validation.ToolType.zls, cmd.tool);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "business rule validation - install command" {
    var version_raw = std.mem.zeroes([limits.limits.version_string_length_maximum]u8);
    @memcpy(version_raw[0..6], "0.11.0");

    const install_cmd = validation.ValidatedCommand.InstallCommand{
        .version = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 11, .patch = 0 } },
        .version_raw = version_raw,
        .version_raw_length = 6,
        .tool = .zls,
    };

    // Should pass - ZLS 0.11.0 is compatible
    try install_cmd.validate_business_rules();

    var incompatible_raw = std.mem.zeroes([limits.limits.version_string_length_maximum]u8);
    @memcpy(incompatible_raw[0..6], "0.10.0");

    const incompatible_cmd = validation.ValidatedCommand.InstallCommand{
        .version = validation.VersionSpec{ .specific = .{ .major = 0, .minor = 10, .patch = 0 } },
        .version_raw = incompatible_raw,
        .version_raw_length = 6,
        .tool = .zls,
    };

    // Should fail - ZLS 0.10.0 is incompatible
    try testing.expectError(error.IncompatibleZLSVersion, incompatible_cmd.validate_business_rules());
}

test "completions command with shell detection" {
    const raw_completions_with_shell = try raw_args.parse_raw_args("completions", &.{"bash"});
    const validated_with_shell = try validation.validate_command(raw_completions_with_shell);

    switch (validated_with_shell) {
        .completions => |cmd| {
            try testing.expectEqual(validation.ShellType.bash, cmd.shell);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "env command with shell option" {
    const raw_env = try raw_args.parse_raw_args("env", &.{ "--shell", "zsh" });
    const validated = try validation.validate_command(raw_env);

    switch (validated) {
        .env => |cmd| {
            try testing.expectEqual(@as(?validation.ShellType, .zsh), cmd.shell);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "env command with attached shell option" {
    const raw_env = try raw_args.parse_raw_args("env", &.{"--shell=zsh"});
    const validated = try validation.validate_command(raw_env);

    switch (validated) {
        .env => |cmd| {
            try testing.expectEqual(@as(?validation.ShellType, .zsh), cmd.shell);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "list-remote command with tool selection" {
    const raw_list_zig = try raw_args.parse_raw_args("list-remote", &.{});
    const validated_zig = try validation.validate_command(raw_list_zig);

    switch (validated_zig) {
        .list_remote => |cmd| {
            try testing.expectEqual(validation.ToolType.zig, cmd.tool);
        },
        else => return error.UnexpectedCommandType,
    }

    const raw_list_zls = try raw_args.parse_raw_args("list-remote", &.{"--zls"});
    const validated_zls = try validation.validate_command(raw_list_zls);

    switch (validated_zls) {
        .list_remote => |cmd| {
            try testing.expectEqual(validation.ToolType.zls, cmd.tool);
        },
        else => return error.UnexpectedCommandType,
    }
}

test "help command validates topic aliases" {
    const raw_help = try raw_args.parse_raw_args("help", &.{"ls"});
    const validated = try validation.validate_command(raw_help);

    switch (validated) {
        .help => |cmd| try testing.expectEqual(validation.HelpTopic.list, cmd.topic),
        else => return error.UnexpectedCommandType,
    }
}

test "memory bounds checking" {
    // Ensure struct sizes are within expected bounds
    try testing.expect(@sizeOf(raw_args.RawArgs) <= 512);
    try testing.expect(@sizeOf(validation.ValidatedCommand) <= 256);
    try testing.expect(@sizeOf(validation.VersionSpec) <= 16);
}
