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
const e2e_download_timeout_seconds: []const u8 = "60";

/// Mirrors `limits.io_buffer_size_maximum`. The harness drives the binary as
/// a subprocess and deliberately imports nothing from src, so the value is
/// restated here to keep the completion-script truncation guard honest.
const emitter_buffer_size_bytes: usize = 4096;

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
    return run_zvm_binary(suite, suite.args.zvm_bin, sandbox, cwd_path, arguments);
}

/// Run an arbitrary zvm binary. `uninstall` deletes the executable it runs
/// from, so those tests drive a sandbox-local copy instead of the shared
/// build artifact every other test depends on.
fn run_zvm_binary(
    suite: *const Suite,
    binary: []const u8,
    sandbox: []const u8,
    cwd_path: []const u8,
    arguments: []const []const u8,
) !Outcome {
    return run_zvm_with_env(suite, binary, sandbox, cwd_path, arguments, null);
}

/// One extra environment entry, applied after the sandbox overrides so a
/// test can reinstate a variable the harness deliberately clears.
const EnvOverride = struct {
    key: []const u8,
    value: []const u8,
};

fn run_zvm_with_env(
    suite: *const Suite,
    binary: []const u8,
    sandbox: []const u8,
    cwd_path: []const u8,
    arguments: []const []const u8,
    env_override: ?EnvOverride,
) !Outcome {
    assert(arguments.len > 0);
    assert(arguments.len < argv_max);
    assert(sandbox.len > 0);
    assert(binary.len > 0);

    var argv_storage: [argv_max][]const u8 = undefined;
    argv_storage[0] = binary;
    for (arguments, 0..) |argument, i| {
        argv_storage[i + 1] = argument;
    }
    const argv = argv_storage[0 .. arguments.len + 1];

    var env_map = try clone_parent_env(suite);
    defer env_map.deinit();
    try apply_sandbox_overrides(&env_map, sandbox);
    if (env_override) |override| {
        assert(override.key.len > 0);
        try env_map.put(override.key, override.value);
    }

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
    // Keep network-bound subprocesses below the CI job timeout. The
    // production default is intentionally generous, but the e2e harness must
    // fail with captured stdout/stderr instead of being killed by CI.
    try env_map.put("ZVM_DOWNLOAD_TIMEOUT_SECONDS", e2e_download_timeout_seconds);
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
        .{ .name = "install uses installed Zig before metadata", .run = test_install_uses_local_zig },
        .{ .name = "install uses installed ZLS before metadata", .run = test_install_uses_local_zls },
        .{ .name = "use refuses torn installation", .run = test_use_refuses_torn_install },
        .{ .name = "use backfills legacy manifest", .run = test_use_backfills_legacy_manifest },
        .{ .name = "clean sweeps staging leftovers", .run = test_clean_sweeps_staging },
        .{ .name = "remove non-installed is idempotent", .run = test_remove_missing },
        .{ .name = "remove active Zig", .run = test_remove_active_zig },
        .{ .name = "remove active ZLS", .run = test_remove_active_zls },
        .{ .name = "use creates shims", .run = test_use_creates_shims },
        .{ .name = "self uninstall dry-run keeps everything", .run = test_uninstall_dry_run },
        .{ .name = "self uninstall removes root and binary", .run = test_uninstall_removes_all },
        .{ .name = "self uninstall json requires yes", .run = test_uninstall_json_requires_yes },
        .{
            .name = "self uninstall json rewrites the profile too",
            .run = test_uninstall_json_rewrites_profile,
        },
        .{
            .name = "self uninstall keeps a shared prefix intact",
            .run = test_uninstall_keeps_unrelated_prefix_contents,
        },
        .{
            .name = "self uninstall keeps a non-empty config dir",
            .run = test_uninstall_keeps_nonempty_config,
        },
        .{
            .name = "self uninstall refuses a symlinked install",
            .run = test_uninstall_refuses_symlinked_install,
        },
        .{
            .name = "self uninstall reports an undeletable binary",
            .run = test_uninstall_reports_undeletable_binary,
        },
        .{
            .name = "self uninstall refuses a foreign binary",
            .run = test_uninstall_refuses_foreign_binary,
        },
        .{
            .name = "self update refuses a foreign binary",
            .run = test_update_refuses_foreign_binary,
        },
        .{ .name = "self uninstall rewrites shell profile", .run = test_uninstall_rewrites_profile },
        .{ .name = "self uninstall --no-modify-path", .run = test_uninstall_no_modify_path },
        .{ .name = "self uninstall rejects version", .run = test_uninstall_rejects_version },
        .{ .name = "self uninstall guards ZVM_HOME", .run = test_uninstall_guards_root_override },
        .{
            .name = "self uninstall guards ZVM_CONFIG_HOME",
            .run = test_uninstall_guards_config_override,
        },
        .{ .name = "bare uninstall is refused as ambiguous", .run = test_uninstall_is_ambiguous },
        .{ .name = "self without a verb is refused", .run = test_self_requires_verb },
        .{ .name = "self unknown verb suggests", .run = test_self_unknown_verb_suggests },
        .{ .name = "self help documents the namespace", .run = test_self_help },
        .{ .name = "ZVM_HOME override appears in env", .run = test_zvm_home_override },
        .{ .name = "auto-detect parses build.zig.zon", .run = test_auto_detect_parses_zon },
        .{ .name = "stderr has no ANSI escapes when not a TTY", .run = test_non_tty_stderr_no_ansi },
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

fn assert_path_exists(suite: *const Suite, path: []const u8, label: []const u8) !void {
    assert(path.len > 0);
    Io.Dir.cwd().access(suite.process_init.io, path, .{}) catch |err| {
        std.debug.print(
            "    {s}: expected path to exist: {s} ({s})\n",
            .{ label, path, @errorName(err) },
        );
        return error.PathMissing;
    };
}

fn assert_path_missing(suite: *const Suite, path: []const u8, label: []const u8) !void {
    assert(path.len > 0);
    Io.Dir.cwd().access(suite.process_init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.debug.print(
                "    {s}: failed to stat path {s}: {s}\n",
                .{ label, path, @errorName(err) },
            );
            return err;
        },
    };

    std.debug.print("    {s}: expected path to be missing: {s}\n", .{ label, path });
    return error.PathStillExists;
}

/// `assert_path_exists` for a path spelled relative to the sandbox, which is
/// how the uninstall cases name the trees they check.
fn assert_sandbox_path_exists(
    suite: *const Suite,
    sandbox: []const u8,
    relative: []const u8,
    label: []const u8,
) !void {
    var buffer: [sandbox_path_max]u8 = undefined;
    const path = try join_sandbox_path(&buffer, sandbox, relative);
    try assert_path_exists(suite, path, label);
}

fn assert_sandbox_path_missing(
    suite: *const Suite,
    sandbox: []const u8,
    relative: []const u8,
    label: []const u8,
) !void {
    var buffer: [sandbox_path_max]u8 = undefined;
    const path = try join_sandbox_path(&buffer, sandbox, relative);
    try assert_path_missing(suite, path, label);
}

fn join_sandbox_path(buffer: []u8, sandbox: []const u8, relative: []const u8) ![]const u8 {
    assert(sandbox.len > 0);
    assert(relative.len > 0);
    return std.fmt.bufPrint(buffer, "{s}{c}{s}", .{ sandbox, std.fs.path.sep, relative });
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
    try assert_contains(outcome.stdout, "'self' {", "powershell self verb block");

    // This is zvm's largest stdout payload and it outgrew the emitter's
    // 4 KiB buffer once `self` was added. A fixed-buffer writer drops such
    // a payload whole, so assert a marker past that boundary rather than
    // the header, which survives either way.
    const tail_marker = "'completions' {";
    const tail_offset = std.mem.indexOf(u8, outcome.stdout, tail_marker) orelse {
        std.debug.print("    powershell script is missing its final block\n", .{});
        return error.ContentMissing;
    };
    if (tail_offset <= emitter_buffer_size_bytes) {
        std.debug.print(
            "    powershell tail marker at {d} no longer guards the {d}-byte buffer\n",
            .{ tail_offset, emitter_buffer_size_bytes },
        );
        return error.GuardNoLongerMeaningful;
    }
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
    try assert_contains(outcome.stderr, "--al: unknown flag in list command", "flag echo");
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

fn test_install_uses_local_zig(suite: *const Suite, sandbox: []const u8) !void {
    const version = "0.13.0";
    try place_installed_version(suite, sandbox, "zig", version);

    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "install", version });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "install local Zig");
    try assert_contains(outcome.stdout, "Now using zig version 0.13.0", "install local Zig selected");
}

fn test_install_uses_local_zls(suite: *const Suite, sandbox: []const u8) !void {
    const version = "0.13.0";
    try place_installed_version(suite, sandbox, "zls", version);

    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "install", "--zls", version });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "install local ZLS");
    try assert_contains(outcome.stdout, "Now using zls version 0.13.0", "install local ZLS selected");
}

fn place_installed_version(
    suite: *const Suite,
    sandbox: []const u8,
    tool: []const u8,
    version: []const u8,
) !void {
    assert(sandbox.len > 0);
    assert(tool.len > 0);
    assert(version.len > 0);

    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);

    var version_path_buffer: [sandbox_path_max]u8 = undefined;
    const version_path = try std.fmt.bufPrint(
        &version_path_buffer,
        ".zm{c}version{c}{s}{c}{s}",
        .{ std.fs.path.sep, std.fs.path.sep, tool, std.fs.path.sep, version },
    );
    try sandbox_dir.createDirPath(suite.process_init.io, version_path);

    var manifest_path_buffer: [sandbox_path_max]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}{c}.zvm-version",
        .{ version_path, std.fs.path.sep },
    );
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = manifest_path,
        .data = version,
    });
}

fn test_use_refuses_torn_install(suite: *const Suite, sandbox: []const u8) !void {
    // A torn install: the directory exists but carries neither the
    // `.zvm-version` manifest nor the tool binary — the leftover shape of
    // an extraction that was killed partway.
    const version = "0.13.0";

    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);

    var version_path_buffer: [sandbox_path_max]u8 = undefined;
    const version_path = try std.fmt.bufPrint(
        &version_path_buffer,
        ".zm{c}version{c}zig{c}{s}",
        .{ std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, version },
    );
    try sandbox_dir.createDirPath(suite.process_init.io, version_path);

    var stray_path_buffer: [sandbox_path_max]u8 = undefined;
    const stray_path = try std.fmt.bufPrint(
        &stray_path_buffer,
        "{s}{c}LICENSE",
        .{ version_path, std.fs.path.sep },
    );
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = stray_path,
        .data = "partial extraction leftover",
    });

    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", version });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "use torn install");
    try assert_contains(outcome.stderr, "incompletely installed", "use torn install hint");
    try assert_contains(outcome.stderr, "zvm install 0.13.0", "use torn install repair hint");
}

fn test_use_backfills_legacy_manifest(suite: *const Suite, sandbox: []const u8) !void {
    // A pre-manifest-era install: the tool binary is present but the
    // `.zvm-version` completion record is not. `use` must verify the
    // binary and complete the record.
    const version = "0.13.0";
    const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);

    var version_path_buffer: [sandbox_path_max]u8 = undefined;
    const version_path = try std.fmt.bufPrint(
        &version_path_buffer,
        ".zm{c}version{c}zig{c}{s}",
        .{ std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, version },
    );
    try sandbox_dir.createDirPath(suite.process_init.io, version_path);

    var binary_path_buffer: [sandbox_path_max]u8 = undefined;
    const binary_path = try std.fmt.bufPrint(
        &binary_path_buffer,
        "{s}{c}{s}",
        .{ version_path, std.fs.path.sep, zig_name },
    );
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = binary_path,
        .data =
        \\#!/bin/sh
        \\echo "fake-zig 0.13.0"
        ,
        .flags = .{ .permissions = .executable_file },
    });

    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", version });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "use legacy install");

    var manifest_path_buffer: [sandbox_path_max]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(
        &manifest_path_buffer,
        "{s}{c}.zvm-version",
        .{ version_path, std.fs.path.sep },
    );
    var manifest_buffer: [64]u8 = undefined;
    const manifest = try sandbox_dir.readFile(
        suite.process_init.io,
        manifest_path,
        &manifest_buffer,
    );
    if (!std.mem.eql(u8, manifest, version)) {
        std.debug.print(
            "    use legacy install: manifest content '{s}' != '{s}'\n",
            .{ manifest, version },
        );
        return error.ManifestMismatch;
    }
}

fn test_clean_sweeps_staging(suite: *const Suite, sandbox: []const u8) !void {
    // Simulate an install killed mid-extraction: an unpublished staging
    // tree under the version root. It must stay invisible to `list` and
    // be removed by `clean`.
    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);

    var staged_path_buffer: [sandbox_path_max]u8 = undefined;
    const staged_path = try std.fmt.bufPrint(
        &staged_path_buffer,
        ".zm{c}version{c}zig{c}.staging{c}0.13.0-12345",
        .{ std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep },
    );
    try sandbox_dir.createDirPath(suite.process_init.io, staged_path);

    var stray_path_buffer: [sandbox_path_max]u8 = undefined;
    const stray_path = try std.fmt.bufPrint(
        &stray_path_buffer,
        "{s}{c}zig",
        .{ staged_path, std.fs.path.sep },
    );
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = stray_path,
        .data = "half-written binary",
    });

    var list_outcome = try run_zvm(suite, sandbox, sandbox, &.{"list"});
    defer list_outcome.deinit(suite.gpa);
    try assert_exit_zero(list_outcome, "list with staging present");
    try assert_not_contains(list_outcome.stdout, ".staging", "list hides staging");

    var clean_outcome = try run_zvm(suite, sandbox, sandbox, &.{"clean"});
    defer clean_outcome.deinit(suite.gpa);
    try assert_exit_zero(clean_outcome, "clean with staging present");

    var staging_root_buffer: [sandbox_path_max]u8 = undefined;
    const staging_root = try std.fmt.bufPrint(
        &staging_root_buffer,
        "{s}{c}.zm{c}version{c}zig{c}.staging",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep },
    );
    try assert_path_missing(suite, staging_root, "staging swept by clean");
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

fn test_remove_active_zig(suite: *const Suite, sandbox: []const u8) !void {
    const version = "0.13.0";
    try place_installed_version(suite, sandbox, "zig", version);

    var use_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", version });
    defer use_outcome.deinit(suite.gpa);
    try assert_exit_zero(use_outcome, "use Zig before remove");

    var remove_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "--yes", "remove", version });
    defer remove_outcome.deinit(suite.gpa);
    try assert_exit_zero(remove_outcome, "remove active Zig");

    var version_path_buffer: [sandbox_path_max]u8 = undefined;
    const version_path = try std.fmt.bufPrint(
        &version_path_buffer,
        "{s}{c}.zm{c}version{c}zig{c}{s}",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, version },
    );
    var current_path_buffer: [sandbox_path_max]u8 = undefined;
    const current_path = try std.fmt.bufPrint(
        &current_path_buffer,
        "{s}{c}.zm{c}current{c}zig",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep },
    );
    var default_path_buffer: [sandbox_path_max]u8 = undefined;
    const default_path = try std.fmt.bufPrint(
        &default_path_buffer,
        "{s}{c}.zm{c}default_version",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep },
    );
    const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
    var shim_path_buffer: [sandbox_path_max]u8 = undefined;
    const shim_path = try std.fmt.bufPrint(
        &shim_path_buffer,
        "{s}{c}.zm{c}bin{c}{s}",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, zig_name },
    );

    try assert_path_missing(suite, version_path, "active version dir");
    try assert_path_missing(suite, current_path, "active current link");
    try assert_path_missing(suite, default_path, "active default version");
    try assert_path_exists(suite, shim_path, "active shim");

    var argv = [_][]const u8{ shim_path, "version" };
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
    if (exit_code == 0) {
        std.debug.print("    shim after active remove unexpectedly exited 0\n", .{});
        return error.UnexpectedZeroExit;
    }
    try assert_contains(result.stderr, "No active Zig version selected", "no active shim");
    try assert_not_contains(result.stderr, "FileNotFound", "no active shim");
}

fn test_remove_active_zls(suite: *const Suite, sandbox: []const u8) !void {
    const version = "0.13.0";
    try place_installed_version(suite, sandbox, "zls", version);

    var use_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", "--zls", version });
    defer use_outcome.deinit(suite.gpa);
    try assert_exit_zero(use_outcome, "use ZLS before remove");

    var remove_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "--yes", "remove", "--zls", version });
    defer remove_outcome.deinit(suite.gpa);
    try assert_exit_zero(remove_outcome, "remove active ZLS");

    const zls_name = if (builtin.os.tag == .windows) "zls.exe" else "zls";
    var shim_path_buffer: [sandbox_path_max]u8 = undefined;
    const shim_path = try std.fmt.bufPrint(
        &shim_path_buffer,
        "{s}{c}.zm{c}bin{c}{s}",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, zls_name },
    );
    try assert_path_exists(suite, shim_path, "active ZLS shim");

    var argv = [_][]const u8{ shim_path, "version" };
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
    if (exit_code == 0) {
        std.debug.print("    shim after active remove unexpectedly exited 0\n", .{});
        return error.UnexpectedZeroExit;
    }
    try assert_contains(result.stderr, "No active zls version selected", "no active shim");
    try assert_contains(result.stderr, "zvm use --zls <version>", "no active shim");
    try assert_not_contains(result.stderr, "FileNotFound", "no active shim");
}

fn test_use_creates_shims(suite: *const Suite, sandbox: []const u8) !void {
    const version = "0.13.0";
    try place_installed_version(suite, sandbox, "zig", version);
    try place_installed_version(suite, sandbox, "zls", version);

    var zig_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", version });
    defer zig_outcome.deinit(suite.gpa);
    try assert_exit_zero(zig_outcome, "use Zig");

    var zls_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "use", "--zls", version });
    defer zls_outcome.deinit(suite.gpa);
    try assert_exit_zero(zls_outcome, "use ZLS");

    const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
    const zls_name = if (builtin.os.tag == .windows) "zls.exe" else "zls";

    var zig_path_buffer: [sandbox_path_max]u8 = undefined;
    const zig_path = try std.fmt.bufPrint(
        &zig_path_buffer,
        "{s}{c}.zm{c}bin{c}{s}",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, zig_name },
    );
    var zls_path_buffer: [sandbox_path_max]u8 = undefined;
    const zls_path = try std.fmt.bufPrint(
        &zls_path_buffer,
        "{s}{c}.zm{c}bin{c}{s}",
        .{ sandbox, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, zls_name },
    );

    try Io.Dir.cwd().access(suite.process_init.io, zig_path, .{});
    try Io.Dir.cwd().access(suite.process_init.io, zls_path, .{});
}

fn test_zvm_home_override(suite: *const Suite, sandbox: []const u8) !void {
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

/// Copy the built zvm into the sandbox and return its path. Uninstall
/// deletes the binary it runs from; the shared build artifact must survive
/// for the rest of the suite.
/// Place zvm where its installers put it: `<ZVM_HOME>/bin/zvm`. `self
/// uninstall` and `self update` refuse any other location, so tests that
/// exercise them have to install the way a user would.
fn place_sandbox_binary(
    suite: *const Suite,
    sandbox: []const u8,
    buffer: []u8,
) ![]const u8 {
    return place_binary_in(suite, sandbox, ".zm/bin", buffer);
}

/// Copy the built zvm into `<sandbox>/<relative_dir>` and return its path.
/// An empty `relative_dir` places it at the sandbox root.
fn place_binary_in(
    suite: *const Suite,
    sandbox: []const u8,
    relative_dir: []const u8,
    buffer: []u8,
) ![]const u8 {
    assert(sandbox.len > 0);

    const io = suite.process_init.io;
    const binary_name = if (builtin.os.tag == .windows) "zvm.exe" else "zvm";

    var dir_buffer: [sandbox_path_max]u8 = undefined;
    var dir_path = sandbox;
    if (relative_dir.len > 0) {
        dir_path = try std.fmt.bufPrint(
            &dir_buffer,
            "{s}{c}{s}",
            .{ sandbox, std.fs.path.sep, relative_dir },
        );
        var sandbox_dir = try Io.Dir.cwd().openDir(io, sandbox, .{});
        defer sandbox_dir.close(io);
        try sandbox_dir.createDirPath(io, relative_dir);
    }

    const binary_path = try std.fmt.bufPrint(
        buffer,
        "{s}{c}{s}",
        .{ dir_path, std.fs.path.sep, binary_name },
    );
    try Io.Dir.cwd().copyFile(
        suite.args.zvm_bin,
        .cwd(),
        binary_path,
        io,
        .{ .replace = true, .permissions = .executable_file },
    );
    return binary_path;
}

fn test_uninstall_dry_run(suite: *const Suite, sandbox: []const u8) !void {
    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "self", "uninstall", "--dry-run" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "self uninstall --dry-run");
    try assert_contains(outcome.stdout, "would remove", "dry-run wording");
    try assert_contains(outcome.stdout, ".zm", "dry-run lists data root");

    // A preview must not touch the file system.
    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}.zm", .{ sandbox, std.fs.path.sep });
    try assert_path_exists(suite, root, "dry-run keeps data root");
    try assert_path_exists(suite, binary, "dry-run keeps binary");
}

fn test_uninstall_removes_all(suite: *const Suite, sandbox: []const u8) !void {
    try place_installed_version(suite, sandbox, "zig", "0.13.0");
    try place_installed_version(suite, sandbox, "zls", "0.13.0");

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--yes", "self", "uninstall" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall");

    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}.zm", .{ sandbox, std.fs.path.sep });
    try assert_path_missing(suite, root, "uninstall removes data root");
    try assert_path_missing(suite, binary, "uninstall removes its own binary");
}

/// A zvm outside `<ZVM_HOME>/bin` was placed there by something else — a
/// package manager, a distro, a hand-built copy. Removing the data root
/// behind that owner's back would leave it believing zvm is installed, so
/// both self commands refuse.
fn assert_self_command_refuses_foreign_binary(
    suite: *const Suite,
    sandbox: []const u8,
    arguments: []const []const u8,
    label: []const u8,
) !void {
    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_binary_in(suite, sandbox, "Cellar/zvm/1.2.0/bin", &binary_buffer);

    var outcome = try run_zvm_binary(suite, binary, sandbox, sandbox, arguments);
    defer outcome.deinit(suite.gpa);

    try assert_exit_non_zero(outcome, label);
    try assert_contains(outcome.stderr, "is disabled for this zvm installation", "refusal explains");
    try assert_contains(outcome.stderr, "zvm installs to", "refusal names the expected path");
    try assert_path_exists(suite, binary, "foreign binary is kept");

    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}.zm", .{ sandbox, std.fs.path.sep });
    try assert_path_exists(suite, root, "refused command keeps the data root");
}

fn test_uninstall_refuses_foreign_binary(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    try assert_self_command_refuses_foreign_binary(
        suite,
        sandbox,
        &.{ "--yes", "self", "uninstall" },
        "self uninstall from outside the install location",
    );
}

fn test_update_refuses_foreign_binary(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    // Also proves the guard runs before any network access: the offline
    // suite would otherwise hang or fail on the release lookup.
    try assert_self_command_refuses_foreign_binary(
        suite,
        sandbox,
        &.{ "self", "update" },
        "self update from outside the install location",
    );
}

/// A profile with one zvm PATH line, one zvm comment, and two lines that must
/// survive — including `zvmtest`, which a naive "zvm" match would delete.
const profile_fixture =
    \\# my shell config
    \\alias zvmtest='echo keep me'
    \\# zvm config directory: /somewhere/.config/.zm
    \\export PATH="$HOME/.zm/bin:$PATH"
    \\export EDITOR=vim
    \\
;

fn place_profile(suite: *const Suite, sandbox: []const u8) !void {
    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);
    try sandbox_dir.writeFile(suite.process_init.io, .{
        .sub_path = ".zshrc",
        .data = profile_fixture,
    });
}

fn read_profile(suite: *const Suite, sandbox: []const u8) ![]u8 {
    var sandbox_dir = try Io.Dir.cwd().openDir(suite.process_init.io, sandbox, .{});
    defer sandbox_dir.close(suite.process_init.io);
    return sandbox_dir.readFileAlloc(
        suite.process_init.io,
        ".zshrc",
        suite.gpa,
        .limited(stdio_limit_bytes),
    );
}

fn test_uninstall_rewrites_profile(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    try place_profile(suite, sandbox);

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--yes", "self", "uninstall" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall rewriting a profile");

    const profile = try read_profile(suite, sandbox);
    defer suite.gpa.free(profile);

    // Only zvm's own lines go. Everything else, including a line that merely
    // contains "zvm", has to survive: this is a file zvm does not own.
    try assert_not_contains(profile, ".zm/bin", "zvm PATH line removed");
    try assert_not_contains(profile, "zvm config directory", "zvm comment removed");
    try assert_contains(profile, "alias zvmtest=", "unrelated zvm-ish line kept");
    try assert_contains(profile, "export EDITOR=vim", "unrelated line kept");
    try assert_contains(profile, "# my shell config", "leading comment kept");

    // The rewrite is a temp file plus a rename; the temp must not survive.
    var temp_buffer: [sandbox_path_max]u8 = undefined;
    const temp = try std.fmt.bufPrint(
        &temp_buffer,
        "{s}{c}.zshrc.zvm-uninstall",
        .{ sandbox, std.fs.path.sep },
    );
    try assert_path_missing(suite, temp, "profile temp file cleaned up");
}

fn test_uninstall_no_modify_path(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    try place_profile(suite, sandbox);

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--yes", "self", "uninstall", "--no-modify-path" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall --no-modify-path");
    // An outstanding action for the operator is a warning, and warnings go to
    // stderr so stdout stays clean for piped consumers.
    try assert_contains(outcome.stderr, "Manual step", "reports the profile instead");

    const profile = try read_profile(suite, sandbox);
    defer suite.gpa.free(profile);
    try std.testing.expectEqualStrings(profile_fixture, profile);
}

/// `--json` may change how a result is printed and nothing else. The profile
/// rewrite used to sit inside the human-readable branch, so a JSON uninstall
/// silently left the PATH line in place.
fn test_uninstall_json_rewrites_profile(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    try place_profile(suite, sandbox);

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--json", "--yes", "self", "uninstall" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--json --yes self uninstall");

    const profile = try read_profile(suite, sandbox);
    defer suite.gpa.free(profile);
    try assert_not_contains(profile, ".zm/bin", "json mode removes the PATH line too");
    try assert_contains(profile, "alias zvmtest=", "json mode keeps unrelated lines");

    // And says so, so automation is not left guessing which files moved.
    try assert_contains(outcome.stdout, "\"profiles_rewritten\":[", "json names the profiles");
    try assert_contains(outcome.stdout, ".zshrc", "json names the rewritten profile");
}

/// `ZVM_HOME` is taken verbatim, so the data root may be a prefix zvm shares
/// with other software — `~/.local` is the obvious one, since that is where
/// zvm used to install. Uninstall must take only what zvm created.
fn test_uninstall_keeps_unrelated_prefix_contents(
    suite: *const Suite,
    sandbox: []const u8,
) !void {
    if (builtin.os.tag == .windows) return;

    const io = suite.process_init.io;
    var sandbox_dir = try Io.Dir.cwd().openDir(io, sandbox, .{});
    defer sandbox_dir.close(io);

    // A prefix laid out the way `~/.local` or `/usr/local` is.
    try sandbox_dir.createDirPath(io, "prefix/bin");
    try sandbox_dir.createDirPath(io, "prefix/lib");
    try sandbox_dir.createDirPath(io, "prefix/share/doc");
    try sandbox_dir.createDirPath(io, "prefix/version/zig/0.13.0");
    try sandbox_dir.writeFile(io, .{ .sub_path = "prefix/lib/libother.so", .data = "x" });
    try sandbox_dir.writeFile(io, .{ .sub_path = "prefix/share/doc/other.txt", .data = "x" });
    try sandbox_dir.writeFile(io, .{ .sub_path = "prefix/bin/other-tool", .data = "x" });
    try sandbox_dir.writeFile(io, .{ .sub_path = "prefix/version/zig/0.13.0/marker", .data = "x" });

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_binary_in(suite, sandbox, "prefix/bin", &binary_buffer);

    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}prefix", .{ sandbox, std.fs.path.sep });

    var outcome = try run_zvm_with_env(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--yes", "self", "uninstall" },
        .{ .key = "ZVM_HOME", .value = root },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall with a shared prefix root");

    // What zvm created is gone.
    try assert_sandbox_path_missing(suite, sandbox, "prefix/version", "zvm versions removed");
    try assert_sandbox_path_missing(suite, sandbox, "prefix/bin/zvm", "zvm binary removed");

    // What zvm never created is untouched, including the root itself.
    try assert_sandbox_path_exists(suite, sandbox, "prefix", "shared prefix kept");
    try assert_sandbox_path_exists(suite, sandbox, "prefix/lib/libother.so", "foreign lib kept");
    try assert_sandbox_path_exists(suite, sandbox, "prefix/share/doc/other.txt", "foreign doc kept");
    try assert_sandbox_path_exists(suite, sandbox, "prefix/bin/other-tool", "foreign binary kept");

    try assert_contains(outcome.stdout, "Kept the directory", "report explains the kept root");
}

/// `<root>/bin/zvm` may be a symlink to a binary outside the root. Both paths
/// then resolve to one file while the running binary is not under the root at
/// all, which used to satisfy the guard and trip an assertion during removal.
fn test_uninstall_refuses_symlinked_install(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    const io = suite.process_init.io;
    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const outside = try place_binary_in(suite, sandbox, "opt/bin", &binary_buffer);

    var sandbox_dir = try Io.Dir.cwd().openDir(io, sandbox, .{});
    defer sandbox_dir.close(io);
    try sandbox_dir.createDirPath(io, ".zm/bin");
    try sandbox_dir.symLink(io, outside, ".zm/bin/zvm", .{});

    var outcome = try run_zvm_binary(suite, outside, sandbox, sandbox, &.{ "--yes", "self", "uninstall" });
    defer outcome.deinit(suite.gpa);

    try assert_exit_non_zero(outcome, "self uninstall through a symlinked install location");
    try assert_contains(outcome.stderr, "is disabled for this zvm installation", "refusal explains");
    try assert_sandbox_path_exists(suite, sandbox, ".zm/version", "refused uninstall keeps data");
}

/// zvm writes nothing into the config directory, so anything in it is the
/// operator's and `ZVM_CONFIG_HOME` is as free-form as `ZVM_HOME`.
fn test_uninstall_keeps_nonempty_config(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    const io = suite.process_init.io;
    var sandbox_dir = try Io.Dir.cwd().openDir(io, sandbox, .{});
    defer sandbox_dir.close(io);
    try sandbox_dir.createDirPath(io, ".config/.zm");
    try sandbox_dir.writeFile(io, .{ .sub_path = ".config/.zm/notes.txt", .data = "mine" });

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(suite, binary, sandbox, sandbox, &.{ "--yes", "self", "uninstall" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall with a non-empty config dir");

    try assert_sandbox_path_exists(suite, sandbox, ".config/.zm/notes.txt", "config file kept");
}

/// The branch Windows always takes: the running binary cannot be unlinked.
/// Reproduced on Unix by making its directory unwritable, which is the only
/// way this path gets exercised outside a Windows runner. What matters is that
/// the data still goes, the binary is reported rather than silently skipped,
/// and the root is kept because the binary is still inside it.
fn test_uninstall_reports_undeletable_binary(suite: *const Suite, sandbox: []const u8) !void {
    if (builtin.os.tag == .windows) return;

    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    const io = suite.process_init.io;
    var bin_dir = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(binary).?, .{});
    defer bin_dir.close(io);

    try bin_dir.setPermissions(io, @enumFromInt(0o555));
    // Restored before the harness tears the sandbox down, which needs to write.
    defer bin_dir.setPermissions(io, @enumFromInt(0o755)) catch {};

    var outcome = try run_zvm_binary(suite, binary, sandbox, sandbox, &.{ "--yes", "self", "uninstall" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "--yes self uninstall with an undeletable binary");

    try assert_contains(outcome.stderr, "Could not delete the running zvm binary", "binary reported");
    try assert_contains(outcome.stderr, "finish the steps above", "closing line asks for follow-up");

    // The root is kept because zvm is still in it, which is a different reason
    // from "it holds somebody else's files" and must not borrow that wording.
    try assert_contains(outcome.stderr, "the running binary is inside it", "root reason is right");
    try assert_not_contains(outcome.stdout, "zvm did not create", "not reported as a shared root");

    try assert_sandbox_path_missing(suite, sandbox, ".zm/version", "data removed anyway");
    try assert_path_exists(suite, binary, "undeletable binary kept");
}

fn test_uninstall_json_requires_yes(suite: *const Suite, sandbox: []const u8) !void {
    // JSON consumers cannot answer a prompt, so the destructive path must
    // refuse rather than silently proceed.
    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_sandbox_binary(suite, sandbox, &binary_buffer);

    var outcome = try run_zvm_binary(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--json", "self", "uninstall" },
    );
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "self uninstall --json without --yes");
    try assert_contains(outcome.stdout, "--yes", "json refusal mentions --yes");

    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}.zm", .{ sandbox, std.fs.path.sep });
    try assert_path_exists(suite, root, "refused uninstall keeps data root");
}

/// Both roots uninstall deletes recursively come from free-form environment
/// overrides. Pointing one at the home directory must be refused before
/// anything is unlinked, so a typo cannot erase a home directory.
///
/// The binary is installed at the location each case makes canonical, so the
/// install-location guard passes and these tests reach the guard they mean to
/// exercise.
fn assert_uninstall_refuses_override(
    suite: *const Suite,
    sandbox: []const u8,
    variable: []const u8,
    binary_dir: []const u8,
) !void {
    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    var binary_buffer: [sandbox_path_max]u8 = undefined;
    const binary = try place_binary_in(suite, sandbox, binary_dir, &binary_buffer);

    var outcome = try run_zvm_with_env(
        suite,
        binary,
        sandbox,
        sandbox,
        &.{ "--yes", "self", "uninstall" },
        .{ .key = variable, .value = sandbox },
    );
    defer outcome.deinit(suite.gpa);

    try assert_exit_non_zero(outcome, "self uninstall with override pointing at home");
    try assert_contains(outcome.stderr, "refusing to uninstall", "guard explains the refusal");
    try assert_contains(outcome.stderr, variable, "guard names the override");

    // The guard runs before any deletion, so the sandbox must be intact.
    try assert_path_exists(suite, sandbox, "refused uninstall keeps home directory");
    try assert_path_exists(suite, binary, "refused uninstall keeps the binary");
}

fn test_uninstall_guards_root_override(suite: *const Suite, sandbox: []const u8) !void {
    // ZVM_HOME=<sandbox> makes the root the home directory, so the canonical
    // binary location is <sandbox>/bin/zvm.
    try assert_uninstall_refuses_override(suite, sandbox, "ZVM_HOME", "bin");
}

fn test_uninstall_guards_config_override(suite: *const Suite, sandbox: []const u8) !void {
    // ZVM_HOME keeps its sandbox default here; only the config dir is bad.
    try assert_uninstall_refuses_override(suite, sandbox, "ZVM_CONFIG_HOME", ".zm/bin");
}

fn test_uninstall_rejects_version(suite: *const Suite, sandbox: []const u8) !void {
    // `self uninstall 0.13.0` is a confusion with `remove`; say so.
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "self", "uninstall", "0.13.0" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "self uninstall with version argument");
    try assert_contains(outcome.stderr, "zvm remove", "self uninstall points at remove");
}

fn test_uninstall_is_ambiguous(suite: *const Suite, sandbox: []const u8) !void {
    // Bare `uninstall` must never delete anything: in every other version
    // manager it removes a managed version, in zvm it would remove zvm.
    try place_installed_version(suite, sandbox, "zig", "0.13.0");

    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"uninstall"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "bare uninstall");
    try assert_contains(outcome.stderr, "ambiguous", "bare uninstall explains itself");
    try assert_contains(outcome.stderr, "zvm self uninstall", "points at self uninstall");
    try assert_contains(outcome.stderr, "zvm remove", "points at remove");

    var root_buffer: [sandbox_path_max]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "{s}{c}.zm", .{ sandbox, std.fs.path.sep });
    try assert_path_exists(suite, root, "refused uninstall keeps data root");
}

fn test_self_requires_verb(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"self"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "self without verb");
    try assert_contains(outcome.stderr, "zvm self update", "lists update verb");
    try assert_contains(outcome.stderr, "zvm self uninstall", "lists uninstall verb");
}

fn test_self_unknown_verb_suggests(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{ "self", "uninstal" });
    defer outcome.deinit(suite.gpa);
    try assert_exit_non_zero(outcome, "self with unknown verb");
    try assert_contains(outcome.stderr, "uninstall", "suggests the nearest verb");
}

fn test_self_help(suite: *const Suite, sandbox: []const u8) !void {
    var flag_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "self", "--help" });
    defer flag_outcome.deinit(suite.gpa);
    try assert_exit_zero(flag_outcome, "self --help");
    try assert_contains(flag_outcome.stdout, "self <VERB>", "self help shows usage");

    var topic_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "help", "self" });
    defer topic_outcome.deinit(suite.gpa);
    try assert_exit_zero(topic_outcome, "help self");
    try assert_contains(topic_outcome.stdout, "self <VERB>", "help self shows usage");

    // The verb's own help must reach the uninstall topic, not the namespace.
    var verb_outcome = try run_zvm(suite, sandbox, sandbox, &.{ "self", "uninstall", "--help" });
    defer verb_outcome.deinit(suite.gpa);
    try assert_exit_zero(verb_outcome, "self uninstall --help");
    try assert_contains(verb_outcome.stdout, "--dry-run", "uninstall help shows its flag");
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

fn test_non_tty_stderr_no_ansi(suite: *const Suite, sandbox: []const u8) !void {
    var outcome = try run_zvm(suite, sandbox, sandbox, &.{"list"});
    defer outcome.deinit(suite.gpa);
    try assert_exit_zero(outcome, "list");
    // When stderr is not a terminal (piped, as in this subprocess),
    // std.Progress must not emit ANSI cursor escapes.
    // Escapes begin with 0x1B followed by '['.
    try assert_not_contains(outcome.stderr, "\x1b[", "non-TTY stderr ANSI escapes");
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
