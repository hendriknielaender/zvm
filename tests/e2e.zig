//! End-to-end test harness for the zvm binary.
//!
//! Drives the built `zvm` executable via subprocesses, asserts on exit
//! codes, stdout, and stderr. Runs in two modes:
//!
//!   - default (offline): exercises CLI surfaces that do not touch the
//!     network — version, help, list, env, completions, ZVM_HOME path
//!     handling, error reporting, alias auto-detection from
//!     `build.zig.zon`.
//!   - --online: additionally runs a full install/use/alias/remove cycle
//!     using a small Zig version. Reserved for the Linux CI job to keep
//!     other matrix legs fast and offline-friendly.
//!
//! Each test gets a fresh sandbox directory and isolated environment
//! (HOME, USERPROFILE, ZVM_HOME, XDG_DATA_HOME, XDG_CONFIG_HOME) so tests
//! cannot pollute the developer machine or each other.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Io = std.Io;

// 16 MiB harness arena. Sized for parent-environment cloning plus several
// captured stdout/stderr payloads simultaneously.
const arena_bytes: usize = 16 * 1024 * 1024;
var arena_buffer: [arena_bytes]u8 align(16) = undefined;

const sandbox_path_max: usize = 512;
const argv_max: usize = 16;
const stdio_limit_bytes: usize = 1 * 1024 * 1024;
const online_zig_version: []const u8 = "0.13.0";

const HarnessArgs = struct {
    zvm_bin: []const u8,
    online: bool,
};

/// Bundles the dependencies every test needs. Passing one *const Suite
/// instead of three separate parameters keeps call-site lines under the
/// 100-column hard limit and makes the test signature stable as the
/// harness grows.
const Suite = struct {
    gpa: std.mem.Allocator,
    process_init: std.process.Init,
    args: HarnessArgs,
};

const TestStats = struct {
    passed: u32 = 0,
    failed: u32 = 0,

    fn record(stats: *TestStats, name: []const u8, ok: bool) void {
        assert(name.len > 0);
        if (ok) {
            stats.passed += 1;
            std.debug.print("  pass  {s}\n", .{name});
        } else {
            stats.failed += 1;
            std.debug.print("  FAIL  {s}\n", .{name});
        }
    }
};

const Outcome = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(outcome: *Outcome, gpa: std.mem.Allocator) void {
        gpa.free(outcome.stdout);
        gpa.free(outcome.stderr);
    }
};

const TestFn = *const fn (suite: *const Suite, sandbox: []const u8) anyerror!void;

pub fn main(process_init: std.process.Init) !u8 {
    var fba = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const gpa = fba.allocator();

    const harness_args = try parse_harness_args(gpa, process_init);
    std.debug.print(
        "e2e: zvm-bin={s} online={}\n",
        .{ harness_args.zvm_bin, harness_args.online },
    );

    var sandbox_root_buffer: [sandbox_path_max]u8 = undefined;
    const sandbox_root = try create_sandbox_root(process_init, &sandbox_root_buffer);
    defer Io.Dir.cwd().deleteTree(process_init.io, sandbox_root) catch |err|
        std.debug.print("warning: failed to delete sandbox root {s}: {s}\n", .{ sandbox_root, @errorName(err) });

    const suite: Suite = .{
        .gpa = gpa,
        .process_init = process_init,
        .args = harness_args,
    };
    var stats: TestStats = .{};

    try run_offline_suite(&suite, sandbox_root, &stats);
    if (harness_args.online) {
        try run_online_suite(&suite, sandbox_root, &stats);
    }

    std.debug.print(
        "\ne2e: {d} passed, {d} failed\n",
        .{ stats.passed, stats.failed },
    );
    assert(stats.passed + stats.failed > 0);
    return if (stats.failed == 0) 0 else 1;
}

fn parse_harness_args(
    gpa: std.mem.Allocator,
    process_init: std.process.Init,
) !HarnessArgs {
    var iterator = try process_init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();

    // Skip argv[0].
    _ = iterator.next() orelse return error.MissingProgramName;

    var zvm_bin: ?[]const u8 = null;
    var online: bool = false;

    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--zvm-bin")) {
            const value = iterator.next() orelse return error.MissingZvmBinValue;
            zvm_bin = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, argument, "--online")) {
            online = true;
        } else {
            std.debug.print("e2e: unknown argument: {s}\n", .{argument});
            return error.UnknownArgument;
        }
    }

    const bin_raw = zvm_bin orelse return error.MissingZvmBin;
    assert(bin_raw.len > 0);

    // Resolve to an absolute path immediately. Tests run subprocesses
    // with cwd set to a sandbox directory, where a relative path under
    // .zig-cache would no longer resolve.
    const bin_absolute = try absolute_path(gpa, process_init.io, bin_raw);
    assert(std.fs.path.isAbsolute(bin_absolute));
    return .{ .zvm_bin = bin_absolute, .online = online };
}

fn absolute_path(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    assert(path.len > 0);

    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);

    var cwd_buffer: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];
    assert(cwd.len > 0);

    const joined = try std.fs.path.join(gpa, &.{ cwd, path });
    assert(std.fs.path.isAbsolute(joined));
    return joined;
}

fn create_sandbox_root(process_init: std.process.Init, buffer: []u8) ![]const u8 {
    assert(buffer.len > 64);

    const tmp = pick_temp_dir(process_init);
    var seed_buffer: [8]u8 = undefined;
    process_init.io.random(&seed_buffer);
    const seed: u64 = std.mem.readInt(u64, &seed_buffer, .little);

    const path = try std.fmt.bufPrint(buffer, "{s}{c}zvm-e2e-{x}", .{
        tmp,
        std.fs.path.sep,
        seed,
    });
    try Io.Dir.cwd().createDirPath(process_init.io, path);
    assert(path.len > tmp.len);
    return path;
}

fn pick_temp_dir(process_init: std.process.Init) []const u8 {
    const env_map = process_init.environ_map;
    if (builtin.os.tag == .windows) {
        return env_map.get("TEMP") orelse "C:\\Temp";
    }
    return env_map.get("TMPDIR") orelse "/tmp";
}

fn run_zvm(
    suite: *const Suite,
    sandbox: []const u8,
    cwd_path: []const u8,
    arguments: []const []const u8,
) !Outcome {
    assert(arguments.len > 0);
    assert(arguments.len < argv_max);
    assert(sandbox.len > 0);

    var argv_storage: [argv_max][]const u8 = undefined;
    argv_storage[0] = suite.args.zvm_bin;
    for (arguments, 0..) |argument, i| {
        argv_storage[i + 1] = argument;
    }
    const argv = argv_storage[0 .. arguments.len + 1];

    var env_map = try clone_parent_env(suite);
    defer env_map.deinit();
    try apply_sandbox_overrides(&env_map, sandbox);

    const result = try std.process.run(suite.gpa, suite.process_init.io, .{
        .argv = argv,
        .environ_map = &env_map,
        .cwd = .{ .path = cwd_path },
        .stdout_limit = .limited(stdio_limit_bytes),
        .stderr_limit = .limited(stdio_limit_bytes),
    });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{ .exit = exit_code, .stdout = result.stdout, .stderr = result.stderr };
}

fn clone_parent_env(suite: *const Suite) !std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(suite.gpa);
    errdefer env_map.deinit();

    const parent = suite.process_init.environ_map;
    const parent_keys = parent.keys();
    const parent_values = parent.values();
    assert(parent_keys.len == parent_values.len);
    for (parent_keys, parent_values) |key, value| {
        try env_map.put(key, value);
    }
    return env_map;
}

fn apply_sandbox_overrides(
    env_map: *std.process.Environ.Map,
    sandbox: []const u8,
) !void {
    assert(sandbox.len > 0);

    // ZVM_HOME is the canonical override. We point it at `<sandbox>/.zm`
    // rather than the bare sandbox so the resolved root contains the
    // `.zm` segment that production code asserts on (see core/remove.zig).
    var zvm_home_buffer: [sandbox_path_max]u8 = undefined;
    const zvm_home = try std.fmt.bufPrint(
        &zvm_home_buffer,
        "{s}{c}.zm",
        .{ sandbox, std.fs.path.sep },
    );
    try env_map.put("ZVM_HOME", zvm_home);

    // HOME / USERPROFILE protect the get_home_path fallback path.
    // XDG_DATA_HOME is removed so the resolved root is unambiguously
    // ZVM_HOME on every platform.
    try env_map.put("HOME", sandbox);
    try env_map.put("USERPROFILE", sandbox);
    var appdata_buffer: [sandbox_path_max]u8 = undefined;
    const appdata = try std.fmt.bufPrint(
        &appdata_buffer,
        "{s}{c}AppData{c}Roaming",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep },
    );
    try env_map.put("APPDATA", appdata);
    _ = env_map.array_hash_map.swapRemove("XDG_DATA_HOME");
    _ = env_map.array_hash_map.swapRemove("XDG_CONFIG_HOME");
    _ = env_map.array_hash_map.swapRemove("ZVM_CONFIG_HOME");
    // Disable colour codes so plain substring assertions on stdout work.
    try env_map.put("NO_COLOR", "1");
}

// ---------------------------------------------------------------------------
// Suite drivers
// ---------------------------------------------------------------------------

fn run_offline_suite(
    suite: *const Suite,
    sandbox_root: []const u8,
    stats: *TestStats,
) !void {
    std.debug.print("\n[offline tests]\n", .{});

    const cases = [_]struct { name: []const u8, run: TestFn }{
        .{ .name = "version exits 0", .run = test_version },
        .{ .name = "help exits 0", .run = test_help },
        .{ .name = "list with empty sandbox", .run = test_list_empty },
        .{ .name = "env bash output", .run = test_env_bash },
        .{ .name = "env zsh output", .run = test_env_zsh },
        .{ .name = "env fish output", .run = test_env_fish },
        .{ .name = "env powershell output", .run = test_env_powershell },
        .{ .name = "completions bash", .run = test_completions_bash },
        .{ .name = "completions zsh", .run = test_completions_zsh },
        .{ .name = "completions fish", .run = test_completions_fish },
        .{ .name = "completions powershell", .run = test_completions_powershell },
        .{ .name = "invalid command exits non-zero", .run = test_invalid_command },
        .{ .name = "unknown command suggests correction", .run = test_unknown_command_suggests },
        .{ .name = "global flag suggests correction", .run = test_unknown_command_flag_suggests },
        .{ .name = "flag suggests correction", .run = test_unknown_subcommand_flag_suggests },
        .{ .name = "command alias resolves without suggestion", .run = test_alias_no_suggestion },
        .{ .name = "install missing version exits non-zero", .run = test_install_missing_arg },
        .{ .name = "install bogus version exits non-zero", .run = test_install_bogus_version },
        .{ .name = "remove non-installed is idempotent", .run = test_remove_missing },
        .{ .name = "ZVM_HOME override appears in env", .run = test_zvm_home_override },
        .{ .name = "auto-detect parses build.zig.zon", .run = test_auto_detect_parses_zon },
        .{ .name = "list-remote stderr has no ANSI escapes when not a TTY", .run = test_list_remote_no_ansi },
    };

    for (cases) |case| {
        try run_case(suite, sandbox_root, stats, case.name, case.run);
    }
}

fn run_case(
    suite: *const Suite,
    sandbox_root: []const u8,
    stats: *TestStats,
    name: []const u8,
    test_fn: TestFn,
) !void {
    var sandbox_buffer: [sandbox_path_max]u8 = undefined;
    const sandbox = try fresh_sandbox(suite.process_init.io, sandbox_root, name, &sandbox_buffer);
    defer Io.Dir.cwd().deleteTree(suite.process_init.io, sandbox) catch |err|
        std.debug.print("warning: failed to delete sandbox {s}: {s}\n", .{ sandbox, @errorName(err) });

    test_fn(suite, sandbox) catch |err| {
        std.debug.print("    error: {s}\n", .{@errorName(err)});
        stats.record(name, false);
        return;
    };
    stats.record(name, true);
}

fn fresh_sandbox(
    io: Io,
    root: []const u8,
    name: []const u8,
    buffer: []u8,
) ![]const u8 {
    assert(root.len > 0);
    assert(name.len > 0);

    // Map spaces in the test name to a directory-friendly form.
    var slug_buffer: [64]u8 = undefined;
    const slug_len = @min(name.len, slug_buffer.len);
    for (name[0..slug_len], 0..) |c, i| {
        slug_buffer[i] = if (c == ' ') '_' else c;
    }

    const path = try std.fmt.bufPrint(buffer, "{s}{c}{s}", .{
        root,
        std.fs.path.sep,
        slug_buffer[0..slug_len],
    });
    try Io.Dir.cwd().createDirPath(io, path);
    // Pre-create the resolved ZVM_HOME (`<sandbox>/.zm`) so commands that
    // read the root before writing — list, env — don't trip on a missing
    // directory.
    var zvm_home_buffer: [sandbox_path_max]u8 = undefined;
    const zvm_home = try std.fmt.bufPrint(
        &zvm_home_buffer,
        "{s}{c}.zm",
        .{ path, std.fs.path.sep },
    );
    try Io.Dir.cwd().createDirPath(io, zvm_home);
    return path;
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

fn assert_exit_zero(outcome: Outcome, label: []const u8) !void {
    if (outcome.exit != 0) {
        std.debug.print(
            "    {s}: expected exit 0, got {d}\n      stdout: {s}\n      stderr: {s}\n",
            .{ label, outcome.exit, outcome.stdout, outcome.stderr },
        );
        return error.UnexpectedNonZeroExit;
    }
}

fn assert_exit_non_zero(outcome: Outcome, label: []const u8) !void {
    if (outcome.exit == 0) {
        std.debug.print(
            "    {s}: expected non-zero exit, got 0\n      stdout: {s}\n",
            .{ label, outcome.stdout },
        );
        return error.UnexpectedZeroExit;
    }
}

fn assert_contains(haystack: []const u8, needle: []const u8, label: []const u8) !void {
    assert(needle.len > 0);
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print(
            "    {s}: expected to contain '{s}'\n      actual: {s}\n",
            .{ label, needle, haystack },
        );
        return error.ContentMissing;
    }
}

fn assert_not_contains(haystack: []const u8, needle: []const u8, label: []const u8) !void {
    assert(needle.len > 0);
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print(
            "    {s}: expected NOT to contain '{s}'\n      actual: {s}\n",
            .{ label, needle, haystack },
        );
        return error.ForbiddenContent;
    }
}

fn assert_env_config_dir(stdout: []const u8, sandbox: []const u8, label: []const u8) !void {
    try assert_contains(stdout, "zvm config directory:", label);
    if (builtin.os.tag == .windows) {
        try assert_contains(stdout, sandbox, label);
        try assert_contains(stdout, "AppData", label);
        try assert_contains(stdout, "\\.zm", label);
    } else {
        try assert_contains(stdout, ".config/.zm", label);
    }
}

// ---------------------------------------------------------------------------
// Offline tests
// ---------------------------------------------------------------------------

fn test_version(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"version"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "version");
    try assert_contains(outcome.stdout, ".", "version stdout");
}

fn test_help(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"--help"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--help");
    try assert_contains(outcome.stdout, "zvm", "help stdout");
}

fn test_list_empty(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"list"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "list (empty sandbox)");
}

fn test_env_bash(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "env", "--shell=bash" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "env bash");
    try assert_contains(outcome.stdout, "export PATH=", "env bash export");
    try assert_contains(outcome.stdout, sandbox, "env bash sandbox path");
    try assert_env_config_dir(outcome.stdout, sandbox, "env bash config path");
}

fn test_env_zsh(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "env", "--shell=zsh" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "env zsh");
    try assert_contains(outcome.stdout, "export PATH=", "env zsh export");
    try assert_contains(outcome.stdout, ".zshrc", "env zsh hint");
}

fn test_env_fish(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "env", "--shell=fish" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "env fish");
    try assert_contains(outcome.stdout, "set -gx PATH", "env fish set -gx");
}

fn test_env_powershell(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "env", "--shell=powershell" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "env powershell");
    try assert_contains(outcome.stdout, "$env:Path", "env powershell $env:Path");
}

fn test_completions_bash(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "completions", "bash" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "completions bash");
    try assert_contains(outcome.stdout, "_zvm_completions", "bash completion function");
}

fn test_completions_zsh(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "completions", "zsh" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "completions zsh");
    try assert_contains(outcome.stdout, "#compdef zvm", "zsh compdef header");
}

fn test_completions_fish(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "completions", "fish" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "completions fish");
    try assert_contains(outcome.stdout, "complete -c zvm", "fish completion command");
}

fn test_completions_powershell(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "completions", "powershell" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "completions powershell");
    try assert_contains(outcome.stdout, "Register-ArgumentCompleter", "powershell registration");
}

fn test_invalid_command(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"this-is-not-a-real-command"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "invalid command");
}

fn test_unknown_command_suggests(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"installl"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "installl typo");
    try assert_contains(outcome.stderr, "unknown command 'installl'", "unknown command typo");
    try assert_contains(outcome.stderr, "Did you mean 'install'?", "unknown command suggestion");
}

fn test_unknown_command_flag_suggests(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "--jsom", "list" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "--jsom typo");
    try assert_contains(outcome.stderr, "unknown global option '--jsom'", "unknown flag echo");
    try assert_contains(outcome.stderr, "Did you mean '--json'?", "unknown flag suggestion");
}

fn test_unknown_subcommand_flag_suggests(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "list", "--al" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "list --al typo");
    try assert_contains(outcome.stderr, "unknown flag '--al' in list command", "flag echo");
    try assert_contains(outcome.stderr, "Did you mean '--all'?", "subcommand flag suggestion");
}

fn test_alias_no_suggestion(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "rm", "0.0.1" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "rm alias");
    try assert_not_contains(outcome.stderr, "Did you mean", "rm alias suggestion");
}

fn test_install_missing_arg(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"install"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "install missing arg");
}

fn test_install_bogus_version(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "install", "abc.def.ghi" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "install bogus version");
}

fn test_remove_missing(suite: *const Suite, sandbox: []const u8) !void {
    // Removing a version that isn't installed must not crash. The current
    // contract is silent success — running twice in a row should still
    // exit cleanly. Online tests cover the success-after-real-install path.
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "remove", "0.0.1" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "remove non-installed (idempotent)");

    var outcome_again = try run_zvm(suite, sandbox, sandbox, &.{ "remove", "0.0.1" });
    defer outcome_again.deinit(suite.gpa);
    try assert_exit_zero(outcome_again, "remove non-installed (second time)");
}

fn test_zvm_home_override(suite: *const Suite, sandbox: []const u8) !void {
    // env output must reflect the ZVM_HOME we passed in, not any default
    // .zm beneath the developer's real HOME.
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "env", "--shell=bash" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "env bash override");
    try assert_contains(outcome.stdout, sandbox, "env bash uses ZVM_HOME");
    try assert_env_config_dir(outcome.stdout, sandbox, "env bash config fallback");

    // The override resolves to `<sandbox>{sep}.zm`; zvm appends `/bin`
    // (forward slash regardless of platform). Check both pieces appear
    // so we know the resolved root really is our override and not a
    // default beneath the developer's real HOME.
    var bin_buffer: [sandbox_path_max]u8 = undefined;
    const expected_bin = try std.fmt.bufPrint(
        &bin_buffer,
        "{s}{c}.zm/bin",
        .{ sandbox, std.fs.path.sep },
    );
    try assert_contains(outcome.stdout, expected_bin, "env bash bin path matches override");
}

fn test_auto_detect_parses_zon(suite: *const Suite, sandbox: []const u8) !void {
    // Windows would need a real .exe stub for the fake zig binary;
    // skipping keeps Windows CI fast and unflaky.
    if (builtin.os.tag == .windows) return;

    try place_auto_detect_fixture(suite, sandbox);

    var alias_path_buffer: [sandbox_path_max]u8 = undefined;
    const alias_path = try std.fmt.bufPrint(
        &alias_path_buffer,
        "{s}{c}zig",
        .{ sandbox, std.fs.path.sep },
    );
    try Io.Dir.cwd().copyFile(
        suite.args.zvm_bin,
        .cwd(),
        alias_path,
        suite.process_init.io,
        .{ .replace = true, .permissions = .executable_file },
    );

    var argv = [_][]const u8{ alias_path, "version" };
    var env_map = try clone_parent_env(suite);
    defer env_map.deinit();
    try apply_sandbox_overrides(&env_map, sandbox);

    const result = try std.process.run(suite.gpa, suite.process_init.io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .cwd = .{ .path = sandbox },
        .stdout_limit = .limited(stdio_limit_bytes),
        .stderr_limit = .limited(stdio_limit_bytes),
    });
    defer suite.gpa.free(result.stdout);
    defer suite.gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
        std.debug.print(
            "    auto-detect: exit {d}\n      stdout: {s}\n      stderr: {s}\n",
            .{ exit_code, result.stdout, result.stderr },
        );
        return error.AutoDetectExecFailed;
    }
    // The fake zig prints a sentinel proving the alias resolved to our
    // pre-populated 0.13.0 binary rather than something else on PATH.
    try assert_contains(result.stdout, "fake-zig 0.13.0", "auto-detect fake zig output");
}

fn place_auto_detect_fixture(suite: *const Suite, sandbox: []const u8) !void {
    assert(sandbox.len > 0);

    const zon =
        \\.{
        \\    .name = .e2e_sample,
        \\    .version = "0.0.1",
        \\    .minimum_zig_version = "0.13.0",
        \\    .fingerprint = 0x0,
        \\    .paths = .{""},
        \\    .dependencies = .{},
        \\}
    ;
    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = "build.zig.zon",
        .data = zon,
    });

    // Pre-create a fake zig binary under the resolved ZVM_HOME root.
    // Without this, the alias would attempt auto-install, which needs the
    // network and triggers an unrelated assertion in the production code.
    try sandbox_dir.createDirPath(suite.process_init.io, ".zm/version/zig/0.13.0");
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = ".zm/version/zig/0.13.0/zig",
        .data =
        \\#!/bin/sh
        \\echo "fake-zig 0.13.0 cwd=$PWD argv=$*"
        ,
        .flags = .{ .permissions = .executable_file },
    });
}

fn test_list_remote_no_ansi(suite: *const Suite, sandbox: []const u8) !void {
    // list-remote is an offline command: it reads from the embedded cache
    // and never hits the network.
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"list-remote"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "list-remote");
    // When stderr is not a terminal (piped, as in this subprocess),
    // std.Progress must not emit ANSI cursor escapes.
    // Escapes begin with 0x1B followed by '['.
    try assert_not_contains(outcome.stderr, "\x1b[", "list-remote stderr ANSI escapes");
}

// ---------------------------------------------------------------------------
// Online tests (small Zig version download; Linux CI only by default).
// ---------------------------------------------------------------------------

fn run_online_suite(
    suite: *const Suite,
    sandbox_root: []const u8,
    stats: *TestStats,
) !void {
    std.debug.print("\n[online tests: zig {s}]\n", .{online_zig_version});

    // The online suite is one stateful flow rather than independent tests:
    // install → list → use → alias → remove. Sharing one sandbox keeps
    // the (slow) install download from running multiple times.
    var sandbox_buffer: [sandbox_path_max]u8 = undefined;
    const sandbox = try fresh_sandbox(
        suite.process_init.io,
        sandbox_root,
        "online_cycle",
        &sandbox_buffer,
    );
    defer Io.Dir.cwd().deleteTree(suite.process_init.io, sandbox) catch |err|
        std.debug.print("warning: failed to delete sandbox {s}: {s}\n", .{ sandbox, @errorName(err) });

    online_cycle(suite, sandbox) catch |err| {
        std.debug.print("    error: {s}\n", .{@errorName(err)});
        stats.record("install/use/alias/remove cycle", false);
        return;
    };
    stats.record("install/use/alias/remove cycle", true);
}

fn online_cycle(suite: *const Suite, sandbox: []const u8) !void {
    var install_outcome = try run_zvm(
        suite,
        sandbox,
        sandbox,
        &.{ "install", online_zig_version },
    );
    defer install_outcome.deinit(suite.gpa);
    try assert_exit_zero(install_outcome, "install");

    var list_outcome = try run_zvm(suite, sandbox, sandbox, &.{"list"});
    defer list_outcome.deinit(suite.gpa);
    try assert_exit_zero(list_outcome, "list after install");
    try assert_contains(list_outcome.stdout, online_zig_version, "list contains version");

    var use_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", online_zig_version });
    defer use_outcome.deinit(suite.gpa);
    try assert_exit_zero(use_outcome, "use");

    try alias_invokes_installed_zig(suite, sandbox);

    var remove_outcome = try run_zvm(
        suite,
        sandbox,
        sandbox,
        &.{ "--yes", "remove", online_zig_version },
    );
    defer remove_outcome.deinit(suite.gpa);
    try assert_exit_zero(remove_outcome, "remove");

    var list_after_remove = try run_zvm(suite, sandbox, sandbox, &.{"list"});
    defer list_after_remove.deinit(suite.gpa);
    try assert_exit_zero(list_after_remove, "list after remove");
    if (std.mem.indexOf(u8, list_after_remove.stdout, online_zig_version) != null) {
        std.debug.print(
            "    list still contains {s} after remove\n      stdout: {s}\n",
            .{ online_zig_version, list_after_remove.stdout },
        );
        return error.RemoveDidNotRemove;
    }
}

fn alias_invokes_installed_zig(suite: *const Suite, sandbox: []const u8) !void {
    const alias_basename = if (builtin.os.tag == .windows) "zig.exe" else "zig";
    var alias_path_buffer: [sandbox_path_max]u8 = undefined;
    const alias_path = try std.fmt.bufPrint(
        &alias_path_buffer,
        "{s}{c}{s}",
        .{ sandbox, std.fs.path.sep, alias_basename },
    );
    try Io.Dir.cwd().copyFile(
        suite.args.zvm_bin,
        .cwd(),
        alias_path,
        suite.process_init.io,
        .{ .replace = true, .permissions = .executable_file },
    );

    var argv = [_][]const u8{ alias_path, online_zig_version, "version" };
    var env_map = try clone_parent_env(suite);
    defer env_map.deinit();
    try apply_sandbox_overrides(&env_map, sandbox);

    const result = try std.process.run(suite.gpa, suite.process_init.io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .cwd = .{ .path = sandbox },
        .stdout_limit = .limited(stdio_limit_bytes),
        .stderr_limit = .limited(stdio_limit_bytes),
    });
    defer suite.gpa.free(result.stdout);
    defer suite.gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
        std.debug.print(
            "    alias zig {s} version: exit {d}\n      stdout: {s}\n      stderr: {s}\n",
            .{ online_zig_version, exit_code, result.stdout, result.stderr },
        );
        return error.AliasExecFailed;
    }
    if (std.mem.indexOf(u8, result.stdout, "0.13") == null) {
        std.debug.print(
            "    alias zig version stdout missing 0.13: {s}\n",
            .{result.stdout},
        );
        return error.AliasVersionMismatch;
    }
}
