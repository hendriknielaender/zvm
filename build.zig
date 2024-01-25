const std = @import("std");
const builtin = @import("builtin");

const CrossTargetInfo = struct {
    crossTarget: std.zig.CrossTarget,
    name: []const u8,
};
// Semantic version of your application
const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 2 };

const min_zig_string = "0.12.0-dev.2341+92211135f";

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
    options.addOption(std.SemanticVersion, "zvm_version", version);

    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .version = version,
    });

    // Link dependencies and set include paths
    exe.linkLibC();

    exe.addIncludePath(.{ .path = "src/deps/libarchive/libarchive" });
    exe.addLibraryPath(.{ .path = "src/deps" });
    exe.addLibraryPath(.{ .path = "/usr/lib/x86_64-linux-gnu" });
    exe.addLibraryPath(.{ .path = "/usr/local/lib" });
    exe.linkSystemLibrary("archive"); // libarchive
    exe.linkSystemLibrary("lzma"); // liblzma

    exe.addOptions("options", options);

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
    };

    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        const rel_exe = b.addExecutable(.{
            .name = "zvm",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = resolved_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });

        rel_exe.linkLibC();

        rel_exe.addIncludePath(.{ .path = "src/deps/libarchive/libarchive" });
        rel_exe.addLibraryPath(.{ .path = "src/deps" });
        rel_exe.addLibraryPath(.{ .path = "/usr/lib/x86_64-linux-gnu" });
        rel_exe.addLibraryPath(.{ .path = "/usr/local/lib" });
        rel_exe.linkSystemLibrary("archive"); // libarchive
        rel_exe.linkSystemLibrary("lzma"); // liblzma

        rel_exe.addOptions("options", options);

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
        .root_source_file = .{ .path = "src/main.zig" },
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
