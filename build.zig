const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;

const min_zig_string = "0.15.1";
const semver = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 3 };
const semver_string = "0.16.3";

// comptime detect the zig version
comptime {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch @panic("Invalid version string");
    if (current_zig.order(min_zig) == .lt) {
        const error_msg = std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        );
        @compileError(error_msg);
    }
}

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add a global option for versioning
    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", b.option(std.log.Level, "log_level", "The Log Level to be used.") orelse .info);
    options.addOption([]const u8, "version", semver_string);

    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .version = semver,
    });

    const exe_options_module = options.createModule();
    exe.root_module.addImport("options", exe_options_module);

    b.installArtifact(exe);

    // add run step
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    if (b.args) |args|
        run_exe.addArgs(args);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    const release = b.step("release", "make an upstream binary release");
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86, .os_tag = .linux },
        .{ .cpu_arch = .x86, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .riscv64, .os_tag = .linux },
        .{ .cpu_arch = .powerpc64le, .os_tag = .linux },
        .{ .cpu_arch = .arm, .os_tag = .linux },
        .{ .cpu_arch = .loongarch64, .os_tag = .linux },
    };

    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        const rel_exe = b.addExecutable(.{
            .name = "zvm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });

        const rel_exe_options_module = options.createModule();
        rel_exe.root_module.addImport("options", rel_exe_options_module);

        const file_name_ext = if (t.os.tag == .windows) ".exe" else "";

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}{s}", .{ @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name, file_name_ext });

        release.dependOn(&install.step);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Add staged validation tests
    const staged_validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_staged_validation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_staged_validation_tests = b.addRunArtifact(staged_validation_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_staged_validation_tests.step);
    // Additional build steps for different configurations or tasks
    // Add here as needed (e.g., documentation generation, code linting)
}
