const std = @import("std");
const builtin = @import("builtin");

const CrossTargetInfo = struct {
    crossTarget: std.zig.CrossTarget,
    name: []const u8,
};
// Semantic version of your application
const version = std.SemanticVersion{ .major = 0, .minor = 4, .patch = 3 };

const min_zig_string = "0.13.0";

const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint("Your Zig version v{} does not meet the minimum build requirement of v{}", .{ current_zig, min_zig }));
    }
    break :blk std.Build;
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Add a global option for versioning
    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", b.option(std.log.Level, "log_level", "The Log Level to be used.") orelse .info);
    options.addOption(std.SemanticVersion, "zvm_version", version);

    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    const exe_options_module = options.createModule();
    exe.root_module.addImport("options", exe_options_module);

    b.installArtifact(exe);

    const release = b.step("release", "make an upstream binary release");
    const release_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .riscv64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        },
        .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
        },
        .{
            .cpu_arch = .x86,
            .os_tag = .windows,
        },
    };

    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        const rel_exe = b.addExecutable(.{
            .name = "zvm",
            .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
            .target = resolved_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });

        const rel_exe_options_module = options.createModule();
        rel_exe.root_module.addImport("options", rel_exe_options_module);

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name,
        });

        release.dependOn(&install.step);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "src/main.zig" } },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    // Additional build steps for different configurations or tasks
    // Add here as needed (e.g., documentation generation, code linting)
}
