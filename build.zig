const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");

const Build = std.Build;

// Version metadata is sourced from build.zig.zon so the manifest and the
// embedded `--version` string stay in sync automatically.
const semver = std.SemanticVersion.parse(zon.version) catch
    @panic("Invalid version in build.zig.zon");

comptime {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(zon.minimum_zig_version) catch
        @panic("Invalid minimum_zig_version in build.zig.zon");
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
    options.addOption([]const u8, "version", zon.version);

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

    // End-to-end harness. Builds the zvm binary and a separate driver
    // executable that spawns it as a subprocess to verify user-facing
    // workflows (version, list, env, completions, ZVM_HOME path handling,
    // alias dispatch). Pass `-Donline=true` to additionally exercise the
    // network-bound install/use/remove cycle against a small Zig version.
    const online = b.option(
        bool,
        "online",
        "Run online e2e tests (downloads a Zig version)",
    ) orelse false;

    const e2e_exe = b.addExecutable(.{
        .name = "zvm-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_e2e = b.addRunArtifact(e2e_exe);
    run_e2e.addArg("--zvm-bin");
    run_e2e.addFileArg(exe.getEmittedBin());
    if (online) run_e2e.addArg("--online");
    run_e2e.step.dependOn(b.getInstallStep());

    const e2e_step = b.step("e2e", "Run end-to-end tests against the built zvm binary");
    e2e_step.dependOn(&run_e2e.step);
}
