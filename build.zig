const std = @import("std");
const CrossTargetInfo = struct {
    crossTarget: std.zig.CrossTarget,
    name: []const u8,
};
// Semantic version of your application
const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 2 };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Add a global option for versioning
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "zvm_version", version);

    const crossTargets = [_]CrossTargetInfo{
        CrossTargetInfo{ .crossTarget = std.zig.CrossTarget{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .musl }, .name = "zvm_macos-x86_64-musl" },
        CrossTargetInfo{ .crossTarget = std.zig.CrossTarget{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "zvm_linux-x86_64-musl" },
        // Add more targets as necessary
    };

    // Function to create executables for each target
    for (crossTargets) |targetInfo| {
        const exe = b.addExecutable(.{
            .name = targetInfo.name,
            .root_source_file = .{ .path = "src/main.zig" },
            .target = targetInfo.crossTarget,
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
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const target = b.standardTargetOptions(.{});
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
