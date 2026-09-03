const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../memory/limits.zig");
const util_tool = @import("../util/tool.zig");
const assert = std.debug.assert;

/// The directory name used for ZVM data storage.
/// This is the only place where `.zm` appears as a constant.
/// Every other module resolves paths through `get_zvm_root`.
pub const zvm_dir_name = ".zm";

/// File name of the zvm executable itself.
pub const zvm_binary_name = if (builtin.os.tag == .windows) "zvm.exe" else "zvm";

/// The one directory both installers put on PATH: `<root>/bin`. It holds the
/// zvm binary and the zig/zls shims, so a single PATH entry covers all three.
pub const zvm_bin_dir_name = "bin";

/// Build `<root>/bin`.
pub fn get_self_bin_dir(buffer: []u8, root: []const u8) ![]const u8 {
    assert(buffer.len > 0);
    assert(root.len > 0);

    const result = try std.fmt.bufPrint(
        buffer,
        "{s}{c}" ++ zvm_bin_dir_name,
        .{ root, std.fs.path.sep },
    );

    assert(result.len > root.len);
    assert(std.mem.endsWith(u8, result, zvm_bin_dir_name));
    return result;
}

/// The one path zvm installs itself to: `<root>/bin/zvm`. This is the same
/// directory the shims live in and the only directory the installers put on
/// PATH, so a zvm found anywhere else was placed there by something other
/// than zvm's own installer.
pub fn get_self_install_path(buffer: []u8, root: []const u8) ![]const u8 {
    assert(buffer.len > 0);
    assert(root.len > 0);

    const result = try std.fmt.bufPrint(
        buffer,
        "{s}{c}" ++ zvm_bin_dir_name ++ "{c}" ++ zvm_binary_name,
        .{ root, std.fs.path.sep, std.fs.path.sep },
    );

    assert(result.len > root.len);
    assert(std.mem.endsWith(u8, result, zvm_binary_name));
    return result;
}

/// Whether `character` separates path components on this platform.
pub fn is_path_separator(character: u8) bool {
    if (character == '/') return true;
    return builtin.os.tag == .windows and character == '\\';
}

/// Compare two paths for equality. Windows file names are case-insensitive,
/// so `C:\Users\me\.zm` and `c:\users\me\.zm` name the same directory.
pub fn path_equal(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

/// Whether `child` sits strictly below `parent`. The separator check keeps
/// `/home/user/.zmx` from counting as a child of `/home/user/.zm`.
pub fn path_is_within(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0 or child.len <= parent.len) return false;
    if (!path_equal(parent, child[0..parent.len])) return false;
    return is_path_separator(child[parent.len]);
}

/// Whether `binary` is the installation zvm manages, i.e. the one its own
/// installer created. Mirrors rustup's `NotSelfInstalled` test: a binary
/// somewhere else belongs to whoever put it there — a package manager, a
/// distro, or a hand-built copy — and zvm must not rewrite or delete it.
///
/// Compares real paths. `std.process.executablePath` resolves symlinks while
/// `ZVM_HOME` is whatever the operator typed, so `/var/x` and `/private/var/x`
/// name one file on macOS but differ byte for byte. A path that cannot be
/// resolved is not ours: refusing is the safe answer for a destructive
/// command.
///
/// Resolving both sides is necessary but not sufficient. `<root>/bin/zvm` may
/// itself be a symlink to a binary outside the root, in which case both sides
/// resolve to that outside path and compare equal while the running binary
/// does not live under the root at all — leaving `self uninstall` pointed at a
/// tree it is not part of. The containment check closes that: what the caller
/// needs to know is that the running binary *is* `<root>/bin/zvm`, not merely
/// that it names the same file.
pub fn binary_is_self_installed(io: std.Io, binary: []const u8, root: []const u8) bool {
    assert(binary.len > 0);
    assert(root.len > 0);

    var expected_storage: [max_path_bytes]u8 = undefined;
    const expected = get_self_install_path(&expected_storage, root) catch return false;

    var expected_real_storage: [max_path_bytes]u8 = undefined;
    const expected_real = resolve_real_path(io, expected, &expected_real_storage) orelse return false;

    var binary_real_storage: [max_path_bytes]u8 = undefined;
    const binary_real = resolve_real_path(io, binary, &binary_real_storage) orelse return false;

    if (!path_equal(binary_real, expected_real)) return false;

    var root_real_storage: [max_path_bytes]u8 = undefined;
    const root_real = resolve_real_path(io, root, &root_real_storage) orelse return false;

    assert(root_real.len > 0);
    assert(binary_real.len > 0);
    return path_is_within(root_real, binary_real);
}

fn resolve_real_path(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    const length = std.Io.Dir.realPathFileAbsolute(io, path, buffer) catch return null;
    return buffer[0..length];
}

/// Bound for a locally built path.
const max_path_bytes = limits.path_length_maximum;

test "binary_is_self_installed accepts only the install location" {
    if (builtin.os.tag == .windows) return;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/bin/zvm", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/bin/zig", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/zvm", .data = "x" });
    try tmp.dir.createDirPath(io, "brew/Cellar/zvm/1.2.0/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "brew/Cellar/zvm/1.2.0/bin/zvm", .data = "x" });

    var root_storage: [max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPathFile(io, "root", &root_storage);
    const root = root_storage[0..root_length];

    var probe_storage: [max_path_bytes]u8 = undefined;

    const installed_length = try tmp.dir.realPathFile(io, "root/bin/zvm", &probe_storage);
    try std.testing.expect(binary_is_self_installed(io, probe_storage[0..installed_length], root));

    // Everything else belongs to whoever put it there.
    const brew_length = try tmp.dir.realPathFile(io, "brew/Cellar/zvm/1.2.0/bin/zvm", &probe_storage);
    try std.testing.expect(!binary_is_self_installed(io, probe_storage[0..brew_length], root));

    const shim_length = try tmp.dir.realPathFile(io, "root/bin/zig", &probe_storage);
    try std.testing.expect(!binary_is_self_installed(io, probe_storage[0..shim_length], root));

    const stray_length = try tmp.dir.realPathFile(io, "root/zvm", &probe_storage);
    try std.testing.expect(!binary_is_self_installed(io, probe_storage[0..stray_length], root));
}

test "binary_is_self_installed compares real paths, not spelling" {
    if (builtin.os.tag == .windows) return;

    // `executablePath` resolves symlinks and `ZVM_HOME` does not, so an
    // unnormalised root must still match the installed binary.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/bin/zvm", .data = "x" });

    var root_storage: [max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPathFile(io, "root", &root_storage);

    var noisy_storage: [max_path_bytes]u8 = undefined;
    const noisy_root = try std.fmt.bufPrint(
        &noisy_storage,
        "{s}//./",
        .{root_storage[0..root_length]},
    );

    var binary_storage: [max_path_bytes]u8 = undefined;
    const binary_length = try tmp.dir.realPathFile(io, "root/bin/zvm", &binary_storage);

    try std.testing.expect(
        binary_is_self_installed(io, binary_storage[0..binary_length], noisy_root),
    );
}

test "binary_is_self_installed rejects a symlinked install location" {
    if (builtin.os.tag == .windows) return;

    // `<root>/bin/zvm` pointing outside the root makes both sides resolve to
    // the same file while the running binary lives elsewhere. Accepting it
    // would aim `self uninstall` at a root the binary is not part of, and the
    // removal step asserts the opposite.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/bin");
    try tmp.dir.createDirPath(io, "opt/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "opt/bin/zvm", .data = "x" });

    var outside_storage: [max_path_bytes]u8 = undefined;
    const outside_length = try tmp.dir.realPathFile(io, "opt/bin/zvm", &outside_storage);
    const outside = outside_storage[0..outside_length];

    try tmp.dir.symLink(io, outside, "root/bin/zvm", .{});

    var root_storage: [max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPathFile(io, "root", &root_storage);
    const root = root_storage[0..root_length];

    try std.testing.expect(!binary_is_self_installed(io, outside, root));
}

test "get_self_install_path builds root/bin/zvm" {
    if (builtin.os.tag == .windows) return;

    var buffer: [max_path_bytes]u8 = undefined;
    const result = try get_self_install_path(&buffer, "/home/u/.zm");
    try std.testing.expectEqualStrings("/home/u/.zm/bin/zvm", result);

    const bin_dir = try get_self_bin_dir(&buffer, "/home/u/.zm");
    try std.testing.expectEqualStrings("/home/u/.zm/bin", bin_dir);
}

test "path_is_within requires a separator boundary" {
    try std.testing.expect(path_is_within("/home/u/.zm", "/home/u/.zm/bin/zvm"));
    try std.testing.expect(!path_is_within("/home/u/.zm", "/home/u/.zmx/bin"));
    try std.testing.expect(!path_is_within("/home/u/.zm", "/home/u/.zm"));
    try std.testing.expect(!path_is_within("/home/u/.zm", "/home/u"));
    try std.testing.expect(!path_is_within("", "/home/u"));
}

/// Get the user's home directory path.
/// Uses `USERPROFILE` on Windows, `HOME` on Unix.
/// Falls back to `"."` (current directory) when the environment variable is unset.
/// The fallback keeps zvm runnable in minimal environments (containers, CI sandboxes,
/// init scripts) where `HOME` may legitimately be absent. An empty environment variable
/// is treated as misconfiguration and returns `error.HomeNotFound`.
pub fn get_home_path(buffer: []u8) ![]const u8 {
    assert(buffer.len > 0);

    const env_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = util_tool.getenv_cross_platform(env_var) orelse {
        const fallback = ".";
        assert(fallback.len > 0);
        assert(fallback.len <= buffer.len);
        @memcpy(buffer[0..fallback.len], fallback);
        assert(buffer[0] == '.');
        return buffer[0..fallback.len];
    };

    if (home.len == 0) return error.HomeNotFound;
    if (home.len > buffer.len) return error.HomePathTooLong;
    @memcpy(buffer[0..home.len], home);

    assert(home.len > 0);
    assert(home.len <= buffer.len);
    return buffer[0..home.len];
}

/// Get the ZVM root directory using the canonical resolution order:
///
///   1. `ZVM_HOME` environment variable (cross-platform override)
///   2. `XDG_DATA_HOME` + `.zm` (Unix XDG Base Directory specification)
///   3. Platform default:
///      - Windows: `{USERPROFILE}\.zm`
///      - Unix:    `{HOME}/.local/share/.zm`
///
/// Callers must provide a buffer large enough for the resolved path.
pub fn get_zvm_root(buffer: []u8, home: []const u8) ![]const u8 {
    assert(buffer.len > 0);
    assert(home.len > 0);

    // 1. ZVM_HOME takes priority on all platforms.
    // An empty value is rejected: an exported-but-empty variable is misconfiguration,
    // not opt-out. Callers should unset the variable to use the platform default.
    if (util_tool.getenv_cross_platform("ZVM_HOME")) |zvm_home| {
        if (zvm_home.len == 0) return error.HomeNotFound;
        if (zvm_home.len > buffer.len) return error.HomePathTooLong;
        @memcpy(buffer[0..zvm_home.len], zvm_home);

        assert(zvm_home.len > 0);
        assert(zvm_home.len <= buffer.len);
        return buffer[0..zvm_home.len];
    }

    // 2. XDG_DATA_HOME on Unix.
    if (builtin.os.tag != .windows) {
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            if (xdg_data.len == 0) return error.HomeNotFound;
            const result = try std.fmt.bufPrint(buffer, "{s}/" ++ zvm_dir_name, .{xdg_data});
            assert(result.len > xdg_data.len);
            assert(std.mem.endsWith(u8, result, "/" ++ zvm_dir_name));
            return result;
        }
    }

    // 3. Platform default.
    const result = if (builtin.os.tag == .windows)
        try std.fmt.bufPrint(buffer, "{s}\\" ++ zvm_dir_name, .{home})
    else
        try std.fmt.bufPrint(buffer, "{s}/.local/share/" ++ zvm_dir_name, .{home});

    assert(result.len > home.len);
    assert(std.mem.endsWith(u8, result, zvm_dir_name));
    return result;
}

/// Get the ZVM configuration directory using the canonical resolution order:
///
///   1. `ZVM_CONFIG_HOME` environment variable (cross-platform escape hatch)
///   2. `XDG_CONFIG_HOME` + `.zm` (Unix XDG Base Directory specification)
///   3. Platform default:
///      - Windows: `%APPDATA%\.zm`
///      - Unix:    `{HOME}/.config/.zm`
///
/// Callers must provide a buffer large enough for the resolved path.
pub fn get_zvm_config_dir(buffer: []u8, home: []const u8) ![]const u8 {
    assert(buffer.len > 0);
    assert(home.len > 0);

    // ZVM_CONFIG_HOME is deliberately separate from ZVM_HOME. Operators may
    // want tool binaries on fast local storage while keeping config synced.
    if (util_tool.getenv_cross_platform("ZVM_CONFIG_HOME")) |zvm_config_home| {
        if (zvm_config_home.len == 0) return error.HomeNotFound;
        if (zvm_config_home.len > buffer.len) return error.HomePathTooLong;
        @memcpy(buffer[0..zvm_config_home.len], zvm_config_home);

        assert(zvm_config_home.len > 0);
        assert(zvm_config_home.len <= buffer.len);
        return buffer[0..zvm_config_home.len];
    }

    if (builtin.os.tag == .windows) {
        if (util_tool.getenv_cross_platform("APPDATA")) |appdata| {
            if (appdata.len == 0) return error.HomeNotFound;
            const result = try std.fmt.bufPrint(buffer, "{s}\\" ++ zvm_dir_name, .{appdata});
            assert(result.len > appdata.len);
            assert(std.mem.endsWith(u8, result, "\\" ++ zvm_dir_name));
            return result;
        }
    } else {
        if (util_tool.getenv_cross_platform("XDG_CONFIG_HOME")) |xdg_config| {
            if (xdg_config.len == 0) return error.HomeNotFound;
            const result = try std.fmt.bufPrint(buffer, "{s}/" ++ zvm_dir_name, .{xdg_config});
            assert(result.len > xdg_config.len);
            assert(std.mem.endsWith(u8, result, "/" ++ zvm_dir_name));
            return result;
        }
    }

    const result = if (builtin.os.tag == .windows)
        try std.fmt.bufPrint(buffer, "{s}\\" ++ zvm_dir_name, .{home})
    else
        try std.fmt.bufPrint(buffer, "{s}/.config/" ++ zvm_dir_name, .{home});

    assert(result.len > home.len);
    assert(std.mem.endsWith(u8, result, zvm_dir_name));
    return result;
}

test "get_home_path returns HOME on Unix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var buffer: [512]u8 = undefined;
    const result = get_home_path(&buffer) catch return error.SkipZigTest;
    try std.testing.expect(result.len > 0);
}

test "get_zvm_root returns XDG_DATA_HOME/.zm when set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const xdg_data = util_tool.getenv_cross_platform("XDG_DATA_HOME");
    if (xdg_data == null) return error.SkipZigTest;
    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_root(&buffer, home);
    try std.testing.expect(result.len > 0);
}

test "get_zvm_root returns fallback when XDG not set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Skip if XDG_DATA_HOME is already set (test wants unset behavior).
    if (util_tool.getenv_cross_platform("XDG_DATA_HOME") != null) return error.SkipZigTest;

    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_root(&buffer, home);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, result, "/.zm"));
}

test "get_zvm_root respects ZVM_HOME override" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (util_tool.getenv_cross_platform("ZVM_HOME") == null) return error.SkipZigTest;

    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_root(&buffer, home);
    const zvm_home = util_tool.getenv_cross_platform("ZVM_HOME").?;
    try std.testing.expectEqualStrings(zvm_home, result);
}

test "get_zvm_config_dir returns XDG_CONFIG_HOME/.zm when set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const xdg_config = util_tool.getenv_cross_platform("XDG_CONFIG_HOME");
    if (xdg_config == null) return error.SkipZigTest;

    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_config_dir(&buffer, home);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, result, xdg_config.?));
}

test "get_zvm_config_dir returns Unix fallback when XDG not set" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (util_tool.getenv_cross_platform("XDG_CONFIG_HOME") != null) return error.SkipZigTest;
    if (util_tool.getenv_cross_platform("ZVM_CONFIG_HOME") != null) return error.SkipZigTest;

    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_config_dir(&buffer, home);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, result, "/.config/.zm"));
}

test "get_zvm_config_dir respects ZVM_CONFIG_HOME override" {
    if (util_tool.getenv_cross_platform("ZVM_CONFIG_HOME") == null) return error.SkipZigTest;

    var buffer: [512]u8 = undefined;
    var home_buf: [256]u8 = undefined;
    const home = try get_home_path(&home_buf);
    const result = try get_zvm_config_dir(&buffer, home);
    const zvm_config_home = util_tool.getenv_cross_platform("ZVM_CONFIG_HOME").?;

    try std.testing.expectEqualStrings(zvm_config_home, result);
}

test "get_zvm_root rejects oversized ZVM_HOME" {
    if (util_tool.getenv_cross_platform("ZVM_HOME") == null) return error.SkipZigTest;
    const zvm_home = util_tool.getenv_cross_platform("ZVM_HOME").?;
    if (zvm_home.len == 0) return error.SkipZigTest;

    // Buffer one byte smaller than the ZVM_HOME value forces HomePathTooLong.
    const undersized_len = zvm_home.len - 1;
    const buffer = try std.testing.allocator.alloc(u8, undersized_len);
    defer std.testing.allocator.free(buffer);

    const home = "/tmp";
    const err = get_zvm_root(buffer, home);
    try std.testing.expectError(error.HomePathTooLong, err);
}

test "get_home_path falls back to '.' when HOME is unset" {
    // This test only runs in environments where HOME/USERPROFILE is genuinely unset.
    const env_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (util_tool.getenv_cross_platform(env_var) != null) return error.SkipZigTest;

    var buffer: [16]u8 = undefined;
    const result = try get_home_path(&buffer);
    try std.testing.expectEqualStrings(".", result);
}
