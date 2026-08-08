//! `zvm self uninstall`: remove the files zvm created, the config directory,
//! and the zvm binary. This is the counterpart to `install.sh` / `install.ps1`,
//! not to `zvm remove`, which only deletes one managed Zig or ZLS version.
//!
//! The command lives under the `self` namespace because `uninstall <version>`
//! is how nvm, pyenv, asdf, fnm, volta, and mise all spell "remove a managed
//! version" — a bare `zvm uninstall` would read as that while deleting zvm.
//! See `cli/spec.zig` for the namespace, and rustup/uv for the precedent.
//!
//! Design:
//!   - Artefacts are resolved once, up front, into caller-owned storage, and
//!     the shell profiles are scanned once alongside them. The plan the
//!     operator confirms and the paths we act on are the same slices, so the
//!     two can never diverge.
//!   - Uninstall deletes the entries it created, named explicitly in
//!     `root_entries` and `bin_entries`, and then removes the directories
//!     themselves only if they come out empty. It never deletes the data root
//!     wholesale: `ZVM_HOME` is a free-form operator override that may name a
//!     shared prefix such as `~/.local`, where everything else belongs to
//!     somebody else. Anything left behind is reported, which is also how a
//!     root entry that someone forgot to add to the list shows up.
//!   - Removal order is root contents, config, binary — the binary last. A
//!     crash mid-uninstall therefore always leaves a working `zvm` behind that
//!     can finish the job; the reverse order would strand the data with no
//!     tool to remove it.
//!   - Shell profiles are rewritten to drop the PATH line zvm asked for,
//!     through a temp file and an atomic rename so an interrupted run never
//!     leaves a half-written shell config. Only path-shaped references are
//!     deleted, and `--no-modify-path` hands the file back to its owner. The
//!     rewrite runs before the output mode is consulted: `--json` changes how
//!     the result is printed, never what the command does.
//!   - Windows user environment variables are reported, not edited: the PATH
//!     entry lives in the registry, not in a file zvm can name.
//!   - Only the installation zvm created is removable: the running binary
//!     must be exactly `<root>/bin/zvm`, the path both installers write to.
//!     A zvm found anywhere else belongs to whoever put it there — a package
//!     manager, a distro, a hand-built copy — and deleting its data behind
//!     that owner's back would leave it believing zvm is installed.
const std = @import("std");
const builtin = @import("builtin");
const context = @import("../Context.zig");
const confirm = @import("../util/confirm.zig");
const limits = @import("../memory/limits.zig");
const paths = @import("../platform/paths.zig");
const util_output = @import("../util/output.zig");
const util_tool = @import("../util/tool.zig");
const validation = @import("../cli/validation.zig");
const assert = std.debug.assert;

const log = std.log.scoped(.uninstall);

/// Every entry zvm creates directly under the data root, `bin` excepted.
///
/// Uninstall deletes exactly these. `ZVM_HOME` is taken verbatim, so the root
/// may be a directory zvm shares with other software — `~/.local` and
/// `/usr/local` are both plausible values — and "delete the root" would take
/// that software with it. Naming what we own keeps the blast radius equal to
/// what zvm actually wrote.
///
/// Adding a root entry elsewhere in the codebase means adding it here. The
/// omission is visible rather than silent: whatever is left keeps the root
/// alive, and the final report names it.
const root_entries = [_][]const u8{
    "cache", // Community mirror list, `core/community_mirrors.zig`.
    "current", // `current/zig` and `current/zls` links, `core/alias.zig`.
    "default_version", // A file, not a directory, `core/alias.zig`.
    "store", // Downloaded tarballs, `core/install.zig`.
    "tmpdir", // Extraction staging, `io/extract.zig`.
    "version", // Installed Zig and ZLS versions, `util/data.zig`.
};

/// Every entry zvm creates in `<root>/bin` other than the zvm binary: the
/// shims `core/alias.zig` writes. Scoped for the same reason as
/// `root_entries` — with `ZVM_HOME=/usr/local`, `<root>/bin` is `/usr/local/bin`.
const bin_entries = [_][]const u8{
    if (builtin.os.tag == .windows) "zig.exe" else "zig",
    if (builtin.os.tag == .windows) "zls.exe" else "zls",
};

/// Shell startup files scanned for leftover PATH entries. A fixed, explicit
/// list: zvm edits only files it named here.
const profile_candidates = [_][]const u8{
    ".bashrc",
    ".bash_profile",
    ".profile",
    ".zshrc",
    ".zprofile",
    ".zshenv",
    ".config/fish/config.fish",
};

/// Substrings that make a profile file worth opening. Deliberately broad —
/// missing a file here means leaving a stale PATH entry behind — while
/// `line_belongs_to_zvm` decides narrowly what may actually be deleted. The
/// resolved bin directory is checked separately because a custom `ZVM_HOME`
/// matches neither literal.
const profile_needles = [_][]const u8{
    "zvm",
    paths.zvm_dir_name ++ "/bin",
};

/// The literal `zvm env` prints and operators paste, as in
/// `export PATH="$HOME/.zm/bin:$PATH"`. Matched separately from the resolved
/// bin directory because a profile usually leaves `$HOME` unexpanded.
const profile_path_needle = paths.zvm_dir_name ++ "/bin";

/// The comment `zvm env` emits above the PATH line.
const profile_comment_needle = "# zvm config directory:";

/// Suffix for the sibling file a profile is filtered into before the rename.
/// A fixed name keeps the leftover discoverable if zvm dies mid-rewrite.
const profile_temp_suffix = ".zvm-uninstall";

/// Chunk size for the profile scan. Chunks overlap by `needle.len - 1`
/// bytes so a needle straddling a chunk boundary is still found.
const profile_scan_chunk_bytes: usize = 4096;

/// Longest needle the chunked scan can match without missing boundaries.
const profile_needle_length_maximum: usize = 256;

/// Longest entry in `profile_candidates`.
const profile_candidate_length_maximum: usize = blk: {
    var maximum: usize = 0;
    for (profile_candidates) |candidate| maximum = @max(maximum, candidate.len);
    break :blk maximum;
};

/// Bound for `<home>/<candidate>`. Much tighter than a general path: both
/// halves are bounded, so the machine-readable report can materialise every
/// profile path at once without a page-sized buffer each.
const profile_path_length_maximum: usize =
    limits.home_dir_length_maximum + 1 + profile_candidate_length_maximum;

comptime {
    assert(root_entries.len <= 16);
    assert(bin_entries.len <= 8);
    assert(profile_candidates.len <= 16);
    assert(profile_needles.len > 0);
    assert(profile_scan_chunk_bytes > profile_needle_length_maximum * 2);
    assert(profile_path_length_maximum <= limits.path_length_maximum);

    for (root_entries) |entry| {
        assert(entry.len > 0);
        // A root entry is one path component: `remove_root_entries` joins it
        // to the root and deletes the result recursively, so a `..` or a
        // nested path would reach outside what this list is meant to bound.
        assert(std.mem.indexOfScalar(u8, entry, '/') == null);
        assert(!std.mem.eql(u8, entry, paths.zvm_bin_dir_name));
    }
    for (bin_entries) |entry| {
        assert(entry.len > 0);
        assert(std.mem.indexOfScalar(u8, entry, '/') == null);
        // The binary is removed last, by name, and must not also be a shim.
        assert(!std.mem.eql(u8, entry, paths.zvm_binary_name));
    }
    for (profile_needles) |needle| {
        assert(needle.len > 0);
        assert(needle.len <= profile_needle_length_maximum);
    }
}

/// What happened to one artefact.
const Outcome = enum {
    /// Deleted by this run.
    removed,
    /// Nothing was there to delete.
    absent,
    /// zvm's own entries are gone but the directory itself was kept, because
    /// it still holds entries zvm did not create. Only the data root reaches
    /// this: it is the one artefact zvm may share with other software.
    cleared,
    /// Still on disk and the operator must remove it, as with a running
    /// Windows executable that cannot unlink itself.
    retained,

    fn to_string(self: Outcome) []const u8 {
        return switch (self) {
            .removed => "removed",
            .absent => "absent",
            .cleared => "cleared",
            .retained => "retained",
        };
    }
};

/// Backing storage for the resolved artefact paths. Owned by the caller so
/// the slices in `Artefacts` stay valid for the whole command.
const ArtefactStorage = struct {
    root: [limits.path_length_maximum]u8 = undefined,
    bin_dir: [limits.path_length_maximum]u8 = undefined,
    config: [limits.path_length_maximum]u8 = undefined,
    binary: [limits.path_length_maximum]u8 = undefined,
    /// Deliberately bounded to the home-directory limit rather than the path
    /// limit: `profile_path_length_maximum` is derived from it, so a home that
    /// does not fit here must fall back to its unresolved spelling instead of
    /// silently overflowing every profile path built from it.
    home: [limits.home_dir_length_maximum]u8 = undefined,
};

/// Every file-system artefact zvm owns, resolved once.
const Artefacts = struct {
    /// Data root: versions, download store, shims, current links.
    root: []const u8,
    /// `<root>/bin`, the one directory the installers put on PATH.
    bin_dir: []const u8,
    /// Config directory, or null when it is the root or lives inside it.
    config: ?[]const u8,
    /// The running zvm binary. Guaranteed to be `<root>/bin/zvm`, and to sit
    /// under `root`, once `guard_installation_is_ours` has passed.
    binary: []const u8,
    /// The operator's home directory, canonicalised. Shell profiles hang off
    /// it; resolved here so the safety guard and the profile scan agree.
    home: []const u8,
};

const Report = struct {
    root: Outcome = .absent,
    config: Outcome = .absent,
    binary: Outcome = .absent,
    /// Entries left in the data root when `root` is `.cleared`, so the report
    /// can say how much is being kept rather than only that some of it is.
    root_entries_kept: u16 = 0,
};

/// Why a plan is being printed. `--dry-run` prints and stops; the
/// confirmation prompt prints the same artefacts before asking.
const PlanPurpose = enum { preview, confirmation };

/// What happened to one shell profile.
const ProfileOutcome = enum {
    /// Planned, not yet acted on: this file names zvm's bin directory.
    would_edit,
    /// zvm's lines were removed and the file replaced atomically.
    rewritten,
    /// The file references zvm but zvm did not change it — `--no-modify-path`
    /// was given, or the rewrite could not be completed.
    needs_manual_edit,
};

/// The shell profiles that reference zvm, resolved once before anything is
/// deleted. Entries start as `.would_edit` and are updated in place when the
/// PATH step runs, so the plan and the result are one list rather than two
/// scans that could disagree.
const Profiles = struct {
    /// Indices into `profile_candidates`, ascending.
    candidates: [profile_candidates.len]u8 = undefined,
    outcomes: [profile_candidates.len]ProfileOutcome = undefined,
    count: u8 = 0,

    fn append(self: *Profiles, candidate_index: u8) void {
        assert(self.count < profile_candidates.len);
        assert(candidate_index < profile_candidates.len);

        self.candidates[self.count] = candidate_index;
        self.outcomes[self.count] = .would_edit;
        self.count += 1;

        assert(self.count <= profile_candidates.len);
    }

    fn candidate(self: *const Profiles, entry: u8) []const u8 {
        assert(entry < self.count);
        return profile_candidates[self.candidates[entry]];
    }

    fn any_needs_manual_edit(self: *const Profiles) bool {
        for (self.outcomes[0..self.count]) |outcome| {
            if (outcome == .needs_manual_edit) return true;
        }
        return false;
    }
};

/// Absolute profile paths, materialised only for the machine-readable report,
/// which needs them as one contiguous array. Every entry has exactly one
/// outcome, so both reported groups fit in a single arena.
const ProfilePathArena = struct {
    storage: [profile_candidates.len][profile_path_length_maximum]u8 = undefined,
    slices: [profile_candidates.len][]const u8 = undefined,
    used: u8 = 0,
};

pub fn uninstall(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.UninstallCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var storage: ArtefactStorage = .{};
    const artefacts = try resolve_artefacts(ctx, &storage);
    guard_installation_is_ours(ctx, artefacts);
    guard_artefacts_are_safe_to_delete(artefacts);

    // What the two guards together establish, restated where the destructive
    // work begins: a later reordering trips here rather than part-way through
    // a delete. `remove_artefacts` asserts the same containment independently.
    assert(artefacts.root.len > 0);
    assert(artefacts.binary.len > 0);
    assert(paths.path_is_within(artefacts.root, artefacts.binary));
    assert(!paths.path_equal(artefacts.root, artefacts.home));

    // Scanned before anything is deleted, for the same reason the artefact
    // paths are resolved up front: the operator confirms this list, so it has
    // to be the list that gets rewritten.
    var profiles = scan_profiles(ctx, artefacts);

    if (command.dry_run) {
        emit_plan(ctx, artefacts, &profiles, .preview, command.no_modify_path);
        return;
    }

    if (!ctx.assume_yes) {
        if (!try confirm_uninstall(ctx, artefacts, &profiles, command.no_modify_path)) {
            util_output.emit(.info, "Aborted: nothing was removed.", .{});
            return;
        }
    }

    const report = try remove_artefacts(ctx, artefacts);

    // Retracting the PATH entry is part of the uninstall, not part of printing
    // it, so it runs before the output mode is consulted. Deciding it inside
    // the human-readable branch would make `--json` quietly skip the edit.
    apply_profiles(ctx, artefacts, &profiles, command.no_modify_path);

    // Every scanned profile is resolved, so the report can never print a plan
    // entry as though it were a result.
    for (profiles.outcomes[0..profiles.count]) |outcome| assert(outcome != .would_edit);

    emit_report(artefacts, report, &profiles);
}

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.UninstallCommand,
    progress_node: std.Progress.Node,
) !void {
    try uninstall(ctx, command, progress_node);
}

pub fn progress_items(command: validation.ValidatedCommand.UninstallCommand) u16 {
    _ = command;
    return 0;
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// Resolve the data root, its bin directory, the config directory, the home
/// directory, and the running binary.
fn resolve_artefacts(ctx: *context.CliContext, storage: *ArtefactStorage) !Artefacts {
    const home_given = ctx.get_home_dir();
    assert(home_given.len > 0);

    const root = canonicalize(ctx.io, &storage.root, try paths.get_zvm_root(&storage.root, home_given));
    assert(root.len > 0);

    const bin_dir = try paths.get_self_bin_dir(&storage.bin_dir, root);
    assert(bin_dir.len > root.len);

    const config_resolved = canonicalize(
        ctx.io,
        &storage.config,
        try paths.get_zvm_config_dir(&storage.config, home_given),
    );
    // A config directory equal to or nested inside the root is handled with
    // the root; listing it twice would claim two removals for one tree.
    const config: ?[]const u8 = if (paths.path_equal(config_resolved, root) or
        paths.path_is_within(root, config_resolved))
        null
    else
        config_resolved;

    const binary_length = try std.process.executablePath(ctx.io, &storage.binary);
    const binary = storage.binary[0..binary_length];
    assert(binary.len > 0);

    // The artefact paths are canonical, so the home directory must be too:
    // comparing a resolved root against an unresolved `$HOME` would let a
    // symlinked home (every macOS `/var` path) walk straight past the guard.
    const home = canonicalize(ctx.io, &storage.home, home_given);
    assert(home.len > 0);
    // Holds because both the context's home and `storage.home` are bounded by
    // it, and it is what makes `build_profile_path` unable to overflow.
    assert(home.len <= limits.home_dir_length_maximum);

    return .{
        .root = root,
        .bin_dir = bin_dir,
        .config = config,
        .binary = binary,
        .home = home,
    };
}

/// Rewrite `path` inside `storage` as its real path.
///
/// Why: the running binary's path comes back from the OS fully resolved,
/// while `ZVM_HOME` is whatever the operator typed. On macOS `/var/x` and
/// `/private/var/x` are the same file, so without this every comparison
/// against the binary — the install-location guard, `path_is_within`, the
/// safety guard — would disagree about paths that name one directory.
///
/// Falls back to the given path when it does not resolve, which is the normal
/// case for a root that was never created.
fn canonicalize(io: std.Io, storage: []u8, path: []const u8) []const u8 {
    assert(path.len > 0);
    assert(storage.len > 0);

    var real_storage: [limits.path_length_maximum]u8 = undefined;
    const length = std.Io.Dir.realPathFileAbsolute(io, path, &real_storage) catch return path;
    if (length == 0 or length > storage.len) return path;

    // `path` may alias `storage`; `real_storage` never does, so the copy is
    // safe in either case.
    @memcpy(storage[0..length], real_storage[0..length]);
    return storage[0..length];
}

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

/// Refuse to uninstall an installation zvm did not create. Deleting the data
/// behind a package manager's back would leave it believing zvm is still
/// installed, so the whole command stops rather than half-removing an
/// installation only that manager can finish.
fn guard_installation_is_ours(ctx: *context.CliContext, artefacts: Artefacts) void {
    assert(artefacts.binary.len > 0);
    assert(artefacts.root.len > 0);

    if (paths.binary_is_self_installed(ctx.io, artefacts.binary, artefacts.root)) {
        // What the guard buys the removal step: the binary is inside the tree
        // being emptied, so `bin` can be held back until the binary is gone.
        assert(paths.path_is_within(artefacts.root, artefacts.binary));
        assert(paths.path_is_within(artefacts.bin_dir, artefacts.binary));
        return;
    }

    var expected_storage: [limits.path_length_maximum]u8 = undefined;
    const expected = paths.get_self_install_path(&expected_storage, artefacts.root) catch
        util_output.exit_with(
            .invalid_arguments,
            "refusing to uninstall: cannot resolve the zvm install path under '{s}'",
            .{artefacts.root},
        );

    util_output.exit_with(
        .invalid_arguments,
        "self-uninstall is disabled for this zvm installation:\n" ++
            "  running binary:  {s}\n" ++
            "  zvm installs to: {s}\n\n" ++
            "  zvm only removes an installation it created. If a package manager\n" ++
            "  installed this zvm, remove it with that manager, e.g. 'brew uninstall zvm'.",
        .{ artefacts.binary, expected },
    );
}

/// Guard every directory uninstall works inside. Both `ZVM_HOME` and
/// `ZVM_CONFIG_HOME` are free-form operator overrides, so each resolved path
/// gets the same check rather than trusting the root alone.
fn guard_artefacts_are_safe_to_delete(artefacts: Artefacts) void {
    assert(artefacts.home.len > 0);
    assert(artefacts.root.len > 0);

    guard_path_is_safe_to_delete(artefacts.home, "root", "ZVM_HOME", artefacts.root);
    if (artefacts.config) |config| {
        guard_path_is_safe_to_delete(artefacts.home, "config directory", "ZVM_CONFIG_HOME", config);
    }
}

/// Refuse to work inside a path that is, or contains, the operator's home
/// directory. Why: uninstall deletes named entries under the resolved path, so
/// a `ZVM_HOME=$HOME` typo would delete `~/version`, `~/store`, and `~/cache`
/// without this. It is a backstop, not the main defence — `root_entries` is —
/// but the two fail independently, which is the point.
fn guard_path_is_safe_to_delete(
    home: []const u8,
    label: []const u8,
    override: []const u8,
    path: []const u8,
) void {
    assert(home.len > 0);
    assert(label.len > 0);
    assert(override.len > 0);
    assert(path.len > 0);

    if (std.fs.path.dirname(path) == null) {
        util_output.exit_with(
            .invalid_arguments,
            "refusing to uninstall: zvm {s} '{s}' has no parent directory",
            .{ label, path },
        );
    }
    if (paths.path_equal(path, home)) {
        util_output.exit_with(
            .invalid_arguments,
            "refusing to uninstall: zvm {s} '{s}' is your home directory (check {s})",
            .{ label, path, override },
        );
    }
    if (paths.path_is_within(path, home)) {
        util_output.exit_with(
            .invalid_arguments,
            "refusing to uninstall: zvm {s} '{s}' contains your home directory (check {s})",
            .{ label, path, override },
        );
    }
}

/// Prompt before deleting anything. JSON consumers must pass --yes: there is
/// no way to answer a prompt on a machine-readable stream.
fn confirm_uninstall(
    ctx: *context.CliContext,
    artefacts: Artefacts,
    profiles: *const Profiles,
    no_modify_path: bool,
) !bool {
    assert(artefacts.root.len > 0);
    assert(profiles.count <= profile_candidates.len);

    if (util_output.output_mode() == .machine_json) {
        util_output.exit_with(
            .invalid_arguments,
            "uninstall requires --yes in --json mode",
            .{},
        );
    }

    emit_plan(ctx, artefacts, profiles, .confirmation, no_modify_path);

    return confirm.confirm_destructive(
        ctx.io,
        "Remove zvm and everything listed above?",
        true,
        ctx.no_input,
    ) catch |err| switch (err) {
        error.RequiresConfirmation => util_output.exit_with(
            .invalid_arguments,
            "uninstall requires --yes (stdin is not a terminal or --no-input was set)",
            .{},
        ),
        error.StdinReadFailed => util_output.exit_with(
            .invalid_arguments,
            "failed to read confirmation from stdin",
            .{},
        ),
    };
}

// ---------------------------------------------------------------------------
// Removal
// ---------------------------------------------------------------------------

/// Delete the artefacts, binary last so an interrupted run is resumable.
fn remove_artefacts(ctx: *context.CliContext, artefacts: Artefacts) !Report {
    assert(artefacts.root.len > 0);
    assert(paths.path_is_within(artefacts.root, artefacts.binary));

    var report = Report{};

    report.root = try remove_root_entries(ctx, artefacts);

    if (artefacts.config) |config| {
        assert(!paths.path_equal(config, artefacts.root));
        report.config = try remove_config(ctx, config);
    }

    report.binary = try remove_binary(ctx, artefacts.binary);

    // `bin` and the root can only come away once the binary inside them is
    // gone. A retained binary — the normal Windows outcome — means the root is
    // being kept because zvm is still in it, which is a different thing from
    // being kept because somebody else's files are.
    if (report.binary == .retained) {
        if (report.root == .cleared) report.root = .retained;
    } else {
        report.root = try finish_root(ctx, artefacts, &report.root_entries_kept);
    }

    assert(report.root != .cleared or report.root_entries_kept > 0);
    return report;
}

/// Delete the entries zvm creates under the data root, holding back `bin`,
/// which contains the binary that is still running.
fn remove_root_entries(ctx: *context.CliContext, artefacts: Artefacts) !Outcome {
    assert(artefacts.root.len > 0);
    assert(artefacts.bin_dir.len > artefacts.root.len);

    if (!util_tool.does_path_exist(ctx.io, artefacts.root)) return .absent;

    // Bounded by a comptime-fixed list, not by what happens to be on disk.
    for (root_entries) |entry| {
        var path_storage: [limits.path_length_maximum]u8 = undefined;
        const path = try join_path(&path_storage, artefacts.root, entry);
        _ = try delete_tree(ctx, path);
    }

    for (bin_entries) |entry| {
        var path_storage: [limits.path_length_maximum]u8 = undefined;
        const path = try join_path(&path_storage, artefacts.bin_dir, entry);
        _ = try delete_tree(ctx, path);
    }

    return .cleared;
}

/// Remove `<root>/bin` and then the root, each only if it is empty.
///
/// A non-empty root is the expected outcome whenever `ZVM_HOME` names a shared
/// prefix, and the expected outcome if zvm grew a root entry that nobody added
/// to `root_entries`. Both are reported rather than forced.
fn finish_root(ctx: *context.CliContext, artefacts: Artefacts, entries_kept: *u16) !Outcome {
    assert(artefacts.root.len > 0);
    assert(entries_kept.* == 0);

    if (!util_tool.does_path_exist(ctx.io, artefacts.root)) return .absent;

    remove_empty_dir(ctx, artefacts.bin_dir) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };

    remove_empty_dir(ctx, artefacts.root) catch |err| switch (err) {
        error.DirNotEmpty => {
            entries_kept.* = try count_entries(ctx, artefacts.root);
            assert(entries_kept.* > 0);
            return .cleared;
        },
        else => return err,
    };

    assert(!util_tool.does_path_exist(ctx.io, artefacts.root));
    return .removed;
}

fn remove_empty_dir(ctx: *context.CliContext, path: []const u8) !void {
    assert(path.len > 0);
    assert(std.fs.path.dirname(path) != null);

    std.Io.Dir.deleteDirAbsolute(ctx.io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

/// Count directory entries, saturating at the maximum a `u16` can report. The
/// number is used in a message, so an exact count past that point buys nothing.
fn count_entries(ctx: *context.CliContext, path: []const u8) !u16 {
    assert(path.len > 0);

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(ctx.io);

    var count: u16 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(ctx.io)) |_| {
        if (count == std.math.maxInt(u16)) break;
        count += 1;
    }
    return count;
}

/// Remove the config directory, but only when it is empty.
///
/// zvm writes nothing here today — `zvm env` reports the path and that is all —
/// so every file in it is the operator's, and `ZVM_CONFIG_HOME` is as free-form
/// as `ZVM_HOME`. Should zvm start writing config, the files it writes belong
/// on a named list like `root_entries` and get deleted here first.
fn remove_config(ctx: *context.CliContext, config: []const u8) !Outcome {
    assert(config.len > 0);
    assert(std.fs.path.dirname(config) != null);

    if (!util_tool.does_path_exist(ctx.io, config)) return .absent;

    remove_empty_dir(ctx, config) catch |err| switch (err) {
        error.DirNotEmpty => return .retained,
        else => return err,
    };

    return .removed;
}

fn remove_binary(ctx: *context.CliContext, binary: []const u8) !Outcome {
    assert(binary.len > 0);
    assert(std.fs.path.dirname(binary) != null);

    if (!util_tool.does_path_exist(ctx.io, binary)) return .absent;

    std.Io.Dir.deleteFileAbsolute(ctx.io, binary) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        // Windows refuses to unlink a running image, and a read-only install
        // directory denies access. Neither is fatal: the operator gets the
        // path and a one-line command instead of a failed uninstall.
        error.AccessDenied,
        error.PermissionDenied,
        error.FileBusy,
        error.ReadOnlyFileSystem,
        => {
            log.debug("could not delete {s}: {s}", .{ binary, @errorName(err) });
            return .retained;
        },
        else => return err,
    };

    assert(!util_tool.does_path_exist(ctx.io, binary));
    return .removed;
}

fn delete_tree(ctx: *context.CliContext, path: []const u8) !Outcome {
    assert(path.len > 0);
    assert(std.fs.path.dirname(path) != null);

    if (!util_tool.does_path_exist(ctx.io, path)) return .absent;

    try std.Io.Dir.cwd().deleteTree(ctx.io, path);

    assert(!util_tool.does_path_exist(ctx.io, path));
    return .removed;
}

/// Join one path component onto a directory.
fn join_path(storage: []u8, directory: []const u8, entry: []const u8) ![]const u8 {
    assert(directory.len > 0);
    assert(entry.len > 0);

    const result = try std.fmt.bufPrint(
        storage,
        "{s}{c}{s}",
        .{ directory, std.fs.path.sep, entry },
    );

    assert(result.len > directory.len);
    assert(std.mem.endsWith(u8, result, entry));
    return result;
}

// ---------------------------------------------------------------------------
// Shell profiles
// ---------------------------------------------------------------------------

/// Find the shell profiles that reference zvm. Reads only; nothing is edited
/// until `apply_profiles`.
fn scan_profiles(ctx: *context.CliContext, artefacts: Artefacts) Profiles {
    assert(artefacts.home.len > 0);
    assert(artefacts.bin_dir.len > 0);

    var profiles = Profiles{};
    if (builtin.os.tag == .windows) return profiles;

    for (profile_candidates, 0..) |candidate, index| {
        var path_storage: [profile_path_length_maximum]u8 = undefined;
        const profile = build_profile_path(&path_storage, artefacts.home, candidate) catch continue;

        if (!profile_mentions_zvm(ctx, profile, artefacts.bin_dir)) continue;
        profiles.append(@intCast(index));
    }

    assert(profiles.count <= profile_candidates.len);
    return profiles;
}

/// Rewrite the profiles found by `scan_profiles`, recording what happened.
fn apply_profiles(
    ctx: *context.CliContext,
    artefacts: Artefacts,
    profiles: *Profiles,
    no_modify_path: bool,
) void {
    assert(profiles.count <= profile_candidates.len);

    for (0..profiles.count) |entry| {
        const index: u8 = @intCast(entry);
        assert(profiles.outcomes[index] == .would_edit);

        // `--no-modify-path` hands the file back to its owner untouched.
        if (no_modify_path) {
            profiles.outcomes[index] = .needs_manual_edit;
            continue;
        }

        var path_storage: [profile_path_length_maximum]u8 = undefined;
        const profile = build_profile_path(
            &path_storage,
            artefacts.home,
            profiles.candidate(index),
        ) catch {
            profiles.outcomes[index] = .needs_manual_edit;
            continue;
        };

        profiles.outcomes[index] = rewrite_profile(ctx.io, profile, artefacts.bin_dir);
    }
}

fn build_profile_path(storage: []u8, home: []const u8, candidate: []const u8) ![]const u8 {
    assert(home.len > 0);
    assert(candidate.len > 0);

    // Always '/': the profile list is Unix-only, and `scan_profiles` returns
    // empty on Windows before this is ever reached.
    const result = try std.fmt.bufPrint(storage, "{s}/{s}", .{ home, candidate });

    assert(result.len > home.len);
    assert(std.mem.endsWith(u8, result, candidate));
    return result;
}

/// Rewrite `profile` without the lines zvm told the operator to add.
///
/// Filters into a sibling temp file and renames it over the original, so an
/// interrupted uninstall leaves either the old profile or the new one — never
/// a half-written shell config that breaks every terminal the operator opens.
fn rewrite_profile(io: std.Io, profile: []const u8, bin_dir: []const u8) ProfileOutcome {
    assert(profile.len > 0);
    assert(bin_dir.len > 0);

    var temp_storage: [limits.path_length_maximum]u8 = undefined;
    const temp_path = std.fmt.bufPrint(
        &temp_storage,
        "{s}{s}",
        .{ profile, profile_temp_suffix },
    ) catch return .needs_manual_edit;

    const removed = filter_profile_into(io, profile, temp_path, bin_dir) catch {
        discard_temp(io, temp_path);
        return .needs_manual_edit;
    };

    // Nothing matched the delete predicate even though the file mentions zvm:
    // leave it alone and let the operator look, rather than rewriting a file
    // for no reason.
    if (removed == 0) {
        discard_temp(io, temp_path);
        return .needs_manual_edit;
    }

    std.Io.Dir.renameAbsolute(temp_path, profile, io) catch {
        discard_temp(io, temp_path);
        return .needs_manual_edit;
    };
    return .rewritten;
}

fn discard_temp(io: std.Io, temp_path: []const u8) void {
    assert(temp_path.len > 0);
    std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
}

/// Copy `profile` into `temp_path`, dropping zvm's lines. Returns how many
/// lines were dropped.
fn filter_profile_into(
    io: std.Io,
    profile: []const u8,
    temp_path: []const u8,
    bin_dir: []const u8,
) !usize {
    assert(profile.len > 0);
    assert(temp_path.len > profile.len);
    assert(bin_dir.len > 0);

    const source = try std.Io.Dir.openFileAbsolute(io, profile, .{ .mode = .read_only });
    defer source.close(io);
    const source_stat = try source.stat(io);

    const destination = try std.Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true });
    defer destination.close(io);
    // A profile may hold secrets. Match the original's mode instead of
    // letting the process umask widen it.
    try destination.setPermissions(io, source_stat.permissions);

    var read_storage: [limits.file_read_buffer_size]u8 = undefined;
    var reader = source.reader(io, &read_storage);
    var write_storage: [limits.file_read_buffer_size]u8 = undefined;
    var writer = destination.writer(io, &write_storage);

    var removed: usize = 0;
    var wrote_any = false;
    var consumed: u64 = 0;
    // Bounded by the file: every iteration consumes a whole line, and a line
    // longer than the read buffer fails with StreamTooLong rather than looping.
    while (try reader.interface.takeDelimiter('\n')) |line| {
        consumed += line.len + 1;

        if (line_belongs_to_zvm(line, bin_dir)) {
            removed += 1;
            continue;
        }

        // The separator goes before each line after the first, so the final
        // newline is decided once, at the end, from the source.
        if (wrote_any) try writer.interface.writeByte('\n');
        try writer.interface.writeAll(line);
        wrote_any = true;
    }

    // `takeDelimiter` cannot say whether the last line was newline-terminated,
    // but the byte count can: it overshoots by exactly one when it was not.
    const source_ends_with_newline = consumed == source_stat.size;
    if (wrote_any and source_ends_with_newline) try writer.interface.writeByte('\n');

    try writer.interface.flush();
    return removed;
}

/// Whether a profile line is one zvm told the operator to add.
///
/// Deliberately narrower than `profile_needles`, which decides whether a file
/// is worth looking at. This function decides what gets deleted from a file
/// zvm does not own, so it matches only path-shaped references: a bare "zvm"
/// needle would also take out `alias zvmtest=...`.
fn line_belongs_to_zvm(line: []const u8, bin_dir: []const u8) bool {
    assert(bin_dir.len > 0);

    if (std.mem.indexOf(u8, line, bin_dir) != null) return true;
    if (std.mem.indexOf(u8, line, profile_path_needle) != null) return true;
    if (std.mem.indexOf(u8, line, profile_comment_needle) != null) return true;
    return false;
}

fn profile_mentions_zvm(ctx: *context.CliContext, profile: []const u8, bin_dir: []const u8) bool {
    assert(profile.len > 0);
    assert(bin_dir.len > 0);

    if (file_contains(ctx.io, profile, bin_dir)) return true;
    for (profile_needles) |needle| {
        if (file_contains(ctx.io, profile, needle)) return true;
    }
    return false;
}

/// Whether `path` contains `needle`, streamed through a fixed buffer.
///
/// Chunks retain a `needle.len - 1` byte tail so a needle spanning a chunk
/// boundary is still matched — a partial scan would report a clean profile
/// that still exports zvm on the PATH. A needle longer than the retained
/// tail allows is rejected rather than silently half-checked.
fn file_contains(io: std.Io, path: []const u8, needle: []const u8) bool {
    assert(path.len > 0);
    assert(needle.len > 0);

    if (needle.len > profile_needle_length_maximum) return false;

    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return false;
    defer file.close(io);

    var reader_storage: [limits.file_read_buffer_size]u8 = undefined;
    var reader = file.reader(io, &reader_storage);

    var scan_buffer: [profile_scan_chunk_bytes]u8 = undefined;
    var filled: usize = 0;
    // Bounded by the file size: every iteration either consumes input or
    // stops on a short read.
    while (true) {
        const read = reader.interface.readSliceShort(scan_buffer[filled..]) catch return false;
        if (read == 0) return false;
        filled += read;
        assert(filled <= scan_buffer.len);

        if (std.mem.indexOf(u8, scan_buffer[0..filled], needle) != null) return true;

        const tail = @min(filled, needle.len - 1);
        std.mem.copyForwards(u8, scan_buffer[0..tail], scan_buffer[filled - tail ..][0..tail]);
        filled = tail;
    }
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

/// Print what uninstall would do. Both purposes list the same artefacts from
/// the same resolved slices, so `--dry-run` and the confirmation prompt can
/// never describe different plans.
fn emit_plan(
    ctx: *context.CliContext,
    artefacts: Artefacts,
    profiles: *const Profiles,
    purpose: PlanPurpose,
    no_modify_path: bool,
) void {
    assert(artefacts.root.len > 0);

    if (purpose == .preview and util_output.output_mode() == .machine_json) {
        emit_json_plan(ctx, artefacts, profiles);
        return;
    }

    switch (purpose) {
        .preview => util_output.emit(.info, "zvm uninstall would remove:", .{}),
        .confirmation => util_output.emit(.info, "zvm uninstall will remove:", .{}),
    }

    emit_path_line(ctx, "data root", artefacts.root);
    if (artefacts.config) |config| emit_path_line(ctx, "config dir", config);
    emit_path_line(ctx, "zvm binary", artefacts.binary);

    // The plan lists the profiles too: editing a shell config is exactly what
    // an operator would want to see before answering.
    const marker: []const u8 = if (no_modify_path) "manual" else "edit  ";
    for (0..profiles.count) |entry| {
        var path_storage: [profile_path_length_maximum]u8 = undefined;
        const profile = build_profile_path(
            &path_storage,
            artefacts.home,
            profiles.candidate(@intCast(entry)),
        ) catch continue;
        util_output.emit(.info, "  {s}  {s:<10}  {s}", .{ marker, "PATH line", profile });
    }

    if (builtin.os.tag == .windows) emit_windows_path_notice(artefacts.bin_dir);

    // Only `--dry-run` ends here; the confirmation flow says it once, in the
    // final report, rather than twice around the prompt.
    if (purpose == .preview) emit_no_profile_hint(artefacts, profiles);
}

fn emit_path_line(ctx: *context.CliContext, label: []const u8, path: []const u8) void {
    assert(label.len > 0);
    assert(path.len > 0);

    const marker: []const u8 = if (util_tool.does_path_exist(ctx.io, path)) "delete" else "absent";
    util_output.emit(.info, "  {s}  {s:<10}  {s}", .{ marker, label, path });
}

/// Print the result. Takes no `no_modify_path`: whether a profile was edited
/// is already recorded in its outcome, and re-deriving it here is how the two
/// come to disagree.
fn emit_report(
    artefacts: Artefacts,
    report: Report,
    profiles: *const Profiles,
) void {
    assert(artefacts.root.len > 0);

    if (util_output.output_mode() == .machine_json) {
        emit_json_report(artefacts, report, profiles);
        return;
    }

    switch (report.root) {
        .removed => util_output.emit(.success, "Removed zvm data root: {s}", .{artefacts.root}),
        .absent => util_output.emit(.info, "zvm data root was already gone: {s}", .{artefacts.root}),
        .cleared => util_output.emit(
            .success,
            "Removed zvm's files from {s}\n" ++
                "  Kept the directory: it holds {d} entries zvm did not create.",
            .{ artefacts.root, report.root_entries_kept },
        ),
        .retained => util_output.emit(
            .warning,
            "zvm data root emptied but not deleted (the running binary is inside it): {s}",
            .{artefacts.root},
        ),
    }

    if (artefacts.config) |config| {
        switch (report.config) {
            .removed => util_output.emit(.success, "Removed zvm config directory: {s}", .{config}),
            .absent => util_output.emit(.info, "No zvm config directory at: {s}", .{config}),
            .cleared => unreachable, // Only the data root is ever cleared.
            .retained => util_output.emit(
                .info,
                "Kept {s}: zvm created nothing in it, so its contents are yours.",
                .{config},
            ),
        }
    }

    switch (report.binary) {
        .removed => util_output.emit(.success, "Removed zvm binary: {s}", .{artefacts.binary}),
        .absent => util_output.emit(.info, "zvm binary was already gone: {s}", .{artefacts.binary}),
        .cleared => unreachable, // Only the data root is ever cleared.
        .retained => util_output.emit(
            .warning,
            "Could not delete the running zvm binary: {s}\n" ++
                "  Delete it manually once this process exits.",
            .{artefacts.binary},
        ),
    }

    emit_profile_results(artefacts, profiles);
    if (builtin.os.tag == .windows) emit_windows_path_notice(artefacts.bin_dir);
    emit_no_profile_hint(artefacts, profiles);

    // The closing line must not claim a clean sweep when something we named is
    // still there for the operator to deal with. A kept data root or config
    // directory is not that: both are the correct outcome for a directory zvm
    // shares, and both were already reported above.
    const needs_operator = report.binary == .retained or
        profiles.any_needs_manual_edit() or
        builtin.os.tag == .windows;
    if (needs_operator) {
        util_output.emit(
            .warning,
            "zvm data has been removed; finish the steps above to remove the rest.",
            .{},
        );
        return;
    }

    util_output.emit(.success, "zvm has been uninstalled.", .{});
}

fn emit_profile_results(artefacts: Artefacts, profiles: *const Profiles) void {
    assert(artefacts.home.len > 0);
    assert(profiles.count <= profile_candidates.len);

    for (0..profiles.count) |entry| {
        const index: u8 = @intCast(entry);
        var path_storage: [profile_path_length_maximum]u8 = undefined;
        const profile = build_profile_path(
            &path_storage,
            artefacts.home,
            profiles.candidate(index),
        ) catch continue;

        switch (profiles.outcomes[index]) {
            .would_edit => unreachable, // `apply_profiles` resolves every entry.
            .rewritten => util_output.emit(
                .success,
                "Removed the zvm PATH line from {s}",
                .{profile},
            ),
            .needs_manual_edit => util_output.emit(
                .warning,
                "Manual step: remove the zvm PATH line from {s}",
                .{profile},
            ),
        }
    }
}

fn emit_no_profile_hint(artefacts: Artefacts, profiles: *const Profiles) void {
    assert(artefacts.bin_dir.len > 0);
    assert(profiles.count <= profile_candidates.len);

    if (profiles.count > 0) return;
    if (builtin.os.tag == .windows) return;

    util_output.emit(
        .info,
        "No shell profile references zvm. If your PATH still contains '{s}', remove it.",
        .{artefacts.bin_dir},
    );
}

/// Windows is reported, not edited: the PATH entry lives in the registry
/// rather than a file, and `zvm env --shell=powershell` never names a concrete
/// profile path to edit.
fn emit_windows_path_notice(bin_dir: []const u8) void {
    assert(bin_dir.len > 0);

    util_output.emit(
        .warning,
        "Manual step: remove '{s}' from your user PATH and unset ZVM_HOME:\n" ++
            "  [Environment]::SetEnvironmentVariable('ZVM_HOME', $null, 'User')",
        .{bin_dir},
    );
}

/// Materialise the absolute paths of every profile whose outcome is `want`,
/// appending into `arena` so both reported groups share one buffer.
fn collect_profile_paths(
    artefacts: Artefacts,
    profiles: *const Profiles,
    want: ProfileOutcome,
    arena: *ProfilePathArena,
) []const []const u8 {
    const start = arena.used;
    assert(start <= profile_candidates.len);

    for (0..profiles.count) |entry| {
        const index: u8 = @intCast(entry);
        if (profiles.outcomes[index] != want) continue;

        assert(arena.used < profile_candidates.len);
        const profile = build_profile_path(
            &arena.storage[arena.used],
            artefacts.home,
            profiles.candidate(index),
        ) catch continue;

        arena.slices[arena.used] = profile;
        arena.used += 1;
    }

    assert(arena.used >= start);
    return arena.slices[start..arena.used];
}

/// Machine-readable preview. Reports what is on disk rather than removal
/// statuses: a dry run removes nothing, and saying "removed" would be a lie
/// that automation could act on.
fn emit_json_plan(ctx: *context.CliContext, artefacts: Artefacts, profiles: *const Profiles) void {
    assert(artefacts.root.len > 0);
    assert(artefacts.binary.len > 0);

    const config_present = if (artefacts.config) |config|
        util_tool.does_path_exist(ctx.io, config)
    else
        false;

    var arena = ProfilePathArena{};
    const planned = collect_profile_paths(artefacts, profiles, .would_edit, &arena);

    const fields = [_]util_output.JsonField{
        .{ .key = "dry_run", .value = .{ .boolean = true } },
        .{ .key = "root", .value = .{ .string = artefacts.root } },
        .{ .key = "root_present", .value = .{
            .boolean = util_tool.does_path_exist(ctx.io, artefacts.root),
        } },
        .{ .key = "config", .value = .{ .string = artefacts.config } },
        .{ .key = "config_present", .value = .{ .boolean = config_present } },
        .{ .key = "binary", .value = .{ .string = artefacts.binary } },
        .{ .key = "binary_present", .value = .{
            .boolean = util_tool.does_path_exist(ctx.io, artefacts.binary),
        } },
        .{ .key = "bin_dir", .value = .{ .string = artefacts.bin_dir } },
        .{ .key = "profiles_to_edit", .value = .{ .array_strings = planned } },
    };
    util_output.emit_json(.{ .object = &fields });
}

fn emit_json_report(artefacts: Artefacts, report: Report, profiles: *const Profiles) void {
    assert(artefacts.root.len > 0);
    assert(report.root != .cleared or report.root_entries_kept > 0);

    var arena = ProfilePathArena{};
    const rewritten = collect_profile_paths(artefacts, profiles, .rewritten, &arena);
    const manual = collect_profile_paths(artefacts, profiles, .needs_manual_edit, &arena);

    const fields = [_]util_output.JsonField{
        .{ .key = "dry_run", .value = .{ .boolean = false } },
        .{ .key = "root", .value = .{ .string = artefacts.root } },
        .{ .key = "root_status", .value = .{ .string = report.root.to_string() } },
        .{ .key = "root_entries_kept", .value = .{ .number = report.root_entries_kept } },
        .{ .key = "config", .value = .{ .string = artefacts.config } },
        .{ .key = "config_status", .value = .{ .string = report.config.to_string() } },
        .{ .key = "binary", .value = .{ .string = artefacts.binary } },
        .{ .key = "binary_status", .value = .{ .string = report.binary.to_string() } },
        .{ .key = "bin_dir", .value = .{ .string = artefacts.bin_dir } },
        .{ .key = "profiles_rewritten", .value = .{ .array_strings = rewritten } },
        .{ .key = "profiles_manual", .value = .{ .array_strings = manual } },
        // Windows cannot edit the registry PATH entry from here, so automation
        // is told the entry is still the operator's to remove.
        .{ .key = "path_entry_manual", .value = .{
            .boolean = builtin.os.tag == .windows or profiles.any_needs_manual_edit(),
        } },
    };
    util_output.emit_json(.{ .object = &fields });
}

comptime {
    assert(@typeInfo(Outcome).@"enum".fields.len == 4);
    assert(@sizeOf(Report) <= 8);
    assert(@sizeOf(Profiles) <= 32);
}

test "root_entries covers every directory zvm creates under the root" {
    // The list is the whole safety story: an entry missing here survives the
    // uninstall. `util/data.zig` builds these paths with `get_zvm_path_segment`.
    const expected = [_][]const u8{
        "cache",
        "current",
        "default_version",
        "store",
        "tmpdir",
        "version",
    };
    try std.testing.expectEqual(expected.len, root_entries.len);
    for (expected, root_entries) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "line_belongs_to_zvm matches only path-shaped references" {
    const bin_dir = "/custom/root/bin";

    try std.testing.expect(line_belongs_to_zvm("export PATH=\"" ++ bin_dir ++ ":$PATH\"", bin_dir));
    try std.testing.expect(line_belongs_to_zvm("export PATH=\"$HOME/.zm/bin:$PATH\"", bin_dir));
    try std.testing.expect(line_belongs_to_zvm("set -gx PATH $HOME/.zm/bin $PATH", bin_dir));
    try std.testing.expect(line_belongs_to_zvm("# zvm config directory: /x/.config/.zm", bin_dir));

    // Negative space: lines that merely mention zvm are not ours to delete.
    try std.testing.expect(!line_belongs_to_zvm("alias zvmtest='echo hi'", bin_dir));
    try std.testing.expect(!line_belongs_to_zvm("# installed zvm last week", bin_dir));
    try std.testing.expect(!line_belongs_to_zvm("export PATH=\"/opt/bin:$PATH\"", bin_dir));
    try std.testing.expect(!line_belongs_to_zvm("", bin_dir));
}

test "Profiles records outcomes against the candidate list" {
    var profiles = Profiles{};
    try std.testing.expect(!profiles.any_needs_manual_edit());

    profiles.append(3);
    profiles.append(6);
    try std.testing.expectEqual(@as(u8, 2), profiles.count);
    try std.testing.expectEqualStrings(".zshrc", profiles.candidate(0));
    try std.testing.expectEqualStrings(".config/fish/config.fish", profiles.candidate(1));
    try std.testing.expect(!profiles.any_needs_manual_edit());

    profiles.outcomes[0] = .rewritten;
    profiles.outcomes[1] = .needs_manual_edit;
    try std.testing.expect(profiles.any_needs_manual_edit());
}

test "collect_profile_paths groups by outcome into one arena" {
    var profiles = Profiles{};
    profiles.append(0); // .bashrc
    profiles.append(3); // .zshrc
    profiles.append(6); // .config/fish/config.fish
    profiles.outcomes[0] = .rewritten;
    profiles.outcomes[1] = .needs_manual_edit;
    profiles.outcomes[2] = .rewritten;

    const artefacts = Artefacts{
        .root = "/home/u/.zm",
        .bin_dir = "/home/u/.zm/bin",
        .config = null,
        .binary = "/home/u/.zm/bin/zvm",
        .home = "/home/u",
    };

    var arena = ProfilePathArena{};
    const rewritten = collect_profile_paths(artefacts, &profiles, .rewritten, &arena);
    const manual = collect_profile_paths(artefacts, &profiles, .needs_manual_edit, &arena);

    try std.testing.expectEqual(@as(usize, 2), rewritten.len);
    try std.testing.expectEqualStrings("/home/u/.bashrc", rewritten[0]);
    try std.testing.expectEqualStrings("/home/u/.config/fish/config.fish", rewritten[1]);

    // The second group must not overwrite the first: both are emitted at once.
    try std.testing.expectEqual(@as(usize, 1), manual.len);
    try std.testing.expectEqualStrings("/home/u/.zshrc", manual[0]);
    try std.testing.expectEqualStrings("/home/u/.bashrc", rewritten[0]);
}

/// Round-trips a profile through the filter and returns the result, so the
/// newline bookkeeping is checked against real files rather than reasoning.
fn filter_profile_for_test(
    tmp: *std.testing.TmpDir,
    source_text: []const u8,
    output: []u8,
) ![]u8 {
    const io = std.testing.io;
    const bin_dir = "/custom/root/bin";

    try tmp.dir.writeFile(io, .{ .sub_path = "profile", .data = source_text });

    var source_storage: [limits.path_length_maximum]u8 = undefined;
    const source_length = try tmp.dir.realPathFile(io, "profile", &source_storage);
    const source = source_storage[0..source_length];

    var temp_storage: [limits.path_length_maximum]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_storage, "{s}.out", .{source});

    _ = try filter_profile_into(io, source, temp, bin_dir);

    const file = try std.Io.Dir.openFileAbsolute(io, temp, .{ .mode = .read_only });
    defer file.close(io);
    var reader_storage: [limits.file_read_buffer_size]u8 = undefined;
    var reader = file.reader(io, &reader_storage);
    const read = try reader.interface.readSliceShort(output);
    return output[0..read];
}

test "filter_profile_into drops zvm lines and preserves the trailing newline" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var output: [512]u8 = undefined;
    const result = try filter_profile_for_test(
        &tmp_dir,
        "# keep\nexport PATH=\"$HOME/.zm/bin:$PATH\"\nalias zvmtest='x'\n",
        &output,
    );
    try std.testing.expectEqualStrings("# keep\nalias zvmtest='x'\n", result);
}

test "filter_profile_into preserves a missing trailing newline" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // A profile that does not end in a newline must not gain one: rewriting
    // is supposed to remove zvm's lines and change nothing else.
    var output: [512]u8 = undefined;
    const result = try filter_profile_for_test(
        &tmp_dir,
        "export PATH=\"$HOME/.zm/bin:$PATH\"\nexport EDITOR=vim",
        &output,
    );
    try std.testing.expectEqualStrings("export EDITOR=vim", result);
}

test "filter_profile_into keeps blank lines and reports nothing to remove" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var output: [512]u8 = undefined;
    const result = try filter_profile_for_test(&tmp_dir, "a\n\nb\n", &output);
    try std.testing.expectEqualStrings("a\n\nb\n", result);
}

test "file_contains finds a needle spanning a chunk boundary" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = std.testing.io;

    const needle = "zvm";
    const filler_length = profile_scan_chunk_bytes - 1;
    const file = try tmp_dir.dir.createFile(io, "profile", .{});
    {
        defer file.close(io);
        var filler: [profile_scan_chunk_bytes]u8 = undefined;
        @memset(filler[0..filler_length], 'a');
        try file.writeStreamingAll(io, filler[0..filler_length]);
        try file.writeStreamingAll(io, needle);
    }

    var path_storage: [limits.path_length_maximum]u8 = undefined;
    const path_length = try tmp_dir.dir.realPathFile(io, "profile", &path_storage);
    const path = path_storage[0..path_length];

    try std.testing.expect(file_contains(io, path, needle));
    try std.testing.expect(!file_contains(io, path, "no-such-needle"));
}
