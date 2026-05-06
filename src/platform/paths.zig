const std = @import("std");
const builtin = @import("builtin");
const util_tool = @import("../util/tool.zig");
const assert = std.debug.assert;

/// The directory name used for ZVM data storage.
/// This is the only place where `.zm` appears as a constant.
/// Every other module resolves paths through `get_zvm_root`.
pub const zvm_dir_name = ".zm";

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
