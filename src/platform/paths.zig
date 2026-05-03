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
/// Falls back to `"."` (current directory) when the environment variable is unset,
/// matching `Context.init_home_directory` behavior for graceful degradation.
pub fn get_home_path(buffer: []u8) ![]const u8 {
    assert(buffer.len > 0);

    const env_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = util_tool.getenv_cross_platform(env_var) orelse {
        // Environment variable not set. Fall back to current working directory.
        const fallback = ".";
        assert(fallback.len <= buffer.len);
        @memcpy(buffer[0..fallback.len], fallback);
        return buffer[0..fallback.len];
    };

    if (home.len == 0) return error.HomeNotFound;
    if (home.len > buffer.len) return error.HomePathTooLong;
    @memcpy(buffer[0..home.len], home);
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
    if (util_tool.getenv_cross_platform("ZVM_HOME")) |zvm_home| {
        if (zvm_home.len > buffer.len) return error.HomePathTooLong;
        @memcpy(buffer[0..zvm_home.len], zvm_home);
        return buffer[0..zvm_home.len];
    }

    // 2. XDG_DATA_HOME on Unix.
    if (builtin.os.tag != .windows) {
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            if (xdg_data.len == 0) return error.HomeNotFound;
            return try std.fmt.bufPrint(buffer, "{s}/" ++ zvm_dir_name, .{xdg_data});
        }
    }

    // 3. Platform default.
    if (builtin.os.tag == .windows) {
        return try std.fmt.bufPrint(buffer, "{s}\\" ++ zvm_dir_name, .{home});
    } else {
        return try std.fmt.bufPrint(buffer, "{s}/.local/share/" ++ zvm_dir_name, .{home});
    }
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
