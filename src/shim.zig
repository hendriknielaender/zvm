const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Context = @import("Context.zig");
const detect_version = @import("core/detect_version.zig");
const install = @import("core/install.zig");
const memory_limits = @import("memory/limits.zig");
const memory_static = @import("memory.zig");
const paths = @import("platform/paths.zig");
const util_tool = @import("util/tool.zig");

const log = std.log.scoped(.shim);

const ShimBuffers = struct {
    home: [memory_limits.limits.home_dir_length_maximum]u8,
    zvm_home: [memory_limits.limits.home_dir_length_maximum]u8,
    tool_path: [memory_limits.limits.path_length_maximum]u8,
    exec_arguments_ptrs: [memory_limits.limits.arguments_maximum + 1]?[*:0]const u8,
    exec_arguments_storage: [memory_limits.limits.arguments_storage_size_maximum]u8,
    process_scratch: [memory_limits.limits.process_scratch_size_maximum]u8,
    exec_arguments_count: u32 = 0,
};

const AutoInstallError = error{
    AlreadyCurrent,
    ContextInitFailed,
    InstallationFailed,
};

// The install path needs the full static arena; keep it out of the shim stack.
var alias_static_buffer: [memory_static.StaticMemory.calculate_memory_size()]u8 align(8) = undefined;

pub fn is_shim_name(program_basename: []const u8) bool {
    switch (builtin.os.tag) {
        .windows => return util_tool.eql_str(program_basename, "zig") or
            util_tool.eql_str(program_basename, "zig.exe") or
            util_tool.eql_str(program_basename, "zls") or
            util_tool.eql_str(program_basename, "zls.exe"),
        else => return util_tool.eql_str(program_basename, "zig") or
            util_tool.eql_str(program_basename, "zls"),
    }
}

fn exe_name(tool_name: []const u8) []const u8 {
    assert(util_tool.eql_str(tool_name, "zig") or util_tool.eql_str(tool_name, "zls"));

    switch (builtin.os.tag) {
        .windows => return if (util_tool.eql_str(tool_name, "zig")) "zig.exe" else "zls.exe",
        else => return tool_name,
    }
}

pub fn run(
    io: std.Io,
    program_name: []const u8,
    remaining_arguments: []const []const u8,
) !void {
    assert(is_shim_name(program_name));
    const tool_name = if (util_tool.eql_str(program_name, "zig") or util_tool.eql_str(program_name, "zig.exe")) "zig" else "zls";

    var version_buffer: [memory_limits.limits.version_string_length_maximum]u8 = undefined;
    const version = detect_version.detect_version_for_shim(
        io,
        remaining_arguments,
        &version_buffer,
    ) catch |err| switch (err) {
        error.OutOfMemory => @panic("out of memory in shim version detection"),
        else => {
            log.err("Failed to detect version: {s}", .{@errorName(err)});
            return run_current(io, tool_name, remaining_arguments);
        },
    };

    if (util_tool.eql_str(version, "current")) {
        return run_current(io, tool_name, remaining_arguments);
    }

    var adjusted_arguments_buffer: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    const adjusted_arguments = adjust_arguments(
        version,
        remaining_arguments,
        &adjusted_arguments_buffer,
    ) catch return error.TooManyArguments;

    if (try run_versioned_if_available(io, tool_name, version, adjusted_arguments)) {
        return;
    }

    if (util_tool.eql_str(tool_name, "zig")) {
        if (auto_install_version_gracefully(io, version)) {
            if (try run_versioned_if_available(io, tool_name, version, adjusted_arguments)) {
                return;
            }
        }
    }

    return run_current(io, tool_name, remaining_arguments);
}

fn run_current(io: std.Io, program_name: []const u8, arguments: []const []const u8) !void {
    var buffers: ShimBuffers = undefined;
    buffers.exec_arguments_count = 0;

    const home = try get_home_path(&buffers);
    const zvm_home = try get_zvm_home_path(&buffers, home);
    const tool_path = try build_tool_path(&buffers, program_name, zvm_home);
    try exec_tool(io, &buffers, tool_path, arguments);
}

fn run_versioned_if_available(
    io: std.Io,
    program_name: []const u8,
    version: []const u8,
    arguments: []const []const u8,
) !bool {
    var buffers: ShimBuffers = undefined;
    buffers.exec_arguments_count = 0;

    const home = try get_home_path(&buffers);
    const zvm_home = try get_zvm_home_path(&buffers, home);
    const tool_path = try build_versioned_tool_path(&buffers, program_name, zvm_home, version);
    if (!tool_path_exists(io, tool_path)) return false;

    try exec_tool(io, &buffers, tool_path, arguments);
    return true;
}

fn exec_tool(
    io: std.Io,
    buffers: *ShimBuffers,
    tool_path: []const u8,
    arguments: []const []const u8,
) !void {
    try build_exec_arguments(buffers, tool_path, arguments);

    var argv_list: [memory_limits.limits.arguments_maximum][]const u8 = undefined;
    const argv_slice = if (builtin.os.tag == .windows)
        build_exec_arguments_slice_windows(buffers, &argv_list)
    else
        build_exec_arguments_slice(buffers, &argv_list);

    const err = std.process.replace(io, .{ .argv = argv_slice });
    log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
    return err;
}

fn adjust_arguments(
    version: []const u8,
    original_arguments: []const []const u8,
    adjusted_arguments: *[memory_limits.limits.arguments_maximum][]const u8,
) ![]const []const u8 {
    assert(version.len > 0);

    const start_index: usize =
        if (original_arguments.len > 0 and detect_version.is_shim_version_argument(original_arguments[0]))
            1
        else
            0;

    var count: usize = 0;
    for (original_arguments[start_index..]) |argument| {
        if (count >= adjusted_arguments.len) return error.TooManyArguments;
        adjusted_arguments[count] = argument;
        count += 1;
    }

    return adjusted_arguments[0..count];
}

fn auto_install_version(io: std.Io, version: []const u8) AutoInstallError!void {
    assert(version.len > 0);
    assert(version.len < 64);

    if (util_tool.eql_str(version, "current")) return error.AlreadyCurrent;

    var context_storage: Context.CliContext = undefined;
    const install_args = &[_][]const u8{ "zvm", "install", version };

    const context = Context.CliContext.init_locked(
        &context_storage,
        &alias_static_buffer,
        install_args,
        io,
    ) catch return error.ContextInitFailed;

    const progress = std.Progress.start(io, .{
        .root_name = "auto-install",
        .estimated_total_items = 5,
    });
    defer progress.end();

    install.install(context, version, false, progress) catch return error.InstallationFailed;
}

fn auto_install_version_gracefully(io: std.Io, version: []const u8) bool {
    assert(version.len > 0);
    assert(version.len < 64);

    auto_install_version(io, version) catch return false;
    return true;
}

fn get_home_path(buffers: *ShimBuffers) ![]const u8 {
    const home = try paths.get_home_path(&buffers.home);
    assert(home.len > 0);
    assert(home.len <= buffers.home.len);
    return home;
}

fn get_zvm_home_path(buffers: *ShimBuffers, home: []const u8) ![]const u8 {
    const zvm_home = try paths.get_zvm_root(&buffers.zvm_home, home);
    assert(zvm_home.len > 0);
    assert(zvm_home.len <= buffers.zvm_home.len);
    return zvm_home;
}

fn build_tool_path(buffers: *ShimBuffers, tool_name: []const u8, zvm_home: []const u8) ![]const u8 {
    const binary_name = exe_name(tool_name);
    return try std.fmt.bufPrint(
        &buffers.tool_path,
        "{s}/current/{s}/{s}",
        .{ zvm_home, tool_name, binary_name },
    );
}

fn build_versioned_tool_path(
    buffers: *ShimBuffers,
    tool_name: []const u8,
    zvm_home: []const u8,
    version: []const u8,
) ![]const u8 {
    const binary_name = exe_name(tool_name);
    return try std.fmt.bufPrint(
        &buffers.tool_path,
        "{s}/version/{s}/{s}/{s}",
        .{ zvm_home, tool_name, version, binary_name },
    );
}

fn tool_path_exists(io: std.Io, tool_path: []const u8) bool {
    assert(tool_path.len > 0);

    std.Io.Dir.accessAbsolute(io, tool_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
    };
    return true;
}

fn build_exec_arguments(
    buffers: *ShimBuffers,
    tool_path: []const u8,
    remaining_arguments: []const []const u8,
) !void {
    if (tool_path.len > buffers.exec_arguments_storage.len) {
        return error.ToolPathTooLong;
    }

    @memcpy(buffers.exec_arguments_storage[0..tool_path.len], tool_path);
    buffers.exec_arguments_storage[tool_path.len] = 0;
    buffers.exec_arguments_ptrs[0] = @ptrCast(&buffers.exec_arguments_storage[0]);

    var exec_arguments_count: u32 = 1;
    var storage_offset: u32 = @intCast(tool_path.len + 1);

    for (remaining_arguments) |argument| {
        if (exec_arguments_count >= buffers.exec_arguments_ptrs.len) {
            return error.TooManyExecArgs;
        }
        if (storage_offset + argument.len + 1 > buffers.exec_arguments_storage.len) {
            return error.ExecArgsStorageFull;
        }

        @memcpy(
            buffers.exec_arguments_storage[storage_offset .. storage_offset + argument.len],
            argument,
        );
        buffers.exec_arguments_storage[storage_offset + argument.len] = 0;
        buffers.exec_arguments_ptrs[exec_arguments_count] =
            @ptrCast(&buffers.exec_arguments_storage[storage_offset]);
        storage_offset += @intCast(argument.len + 1);
        exec_arguments_count += 1;
    }

    buffers.exec_arguments_ptrs[exec_arguments_count] = null;
    buffers.exec_arguments_count = exec_arguments_count;
}

fn build_exec_arguments_slice(
    buffers: *const ShimBuffers,
    argv_list: *[memory_limits.limits.arguments_maximum][]const u8,
) []const []const u8 {
    assert(buffers.exec_arguments_count > 0);
    assert(buffers.exec_arguments_count < buffers.exec_arguments_ptrs.len);

    for (0..buffers.exec_arguments_count) |index| {
        const argument = buffers.exec_arguments_ptrs[index].?;
        argv_list[index] = std.mem.sliceTo(argument, 0);
    }

    return argv_list[0..buffers.exec_arguments_count];
}

fn build_exec_arguments_slice_windows(
    buffers: *const ShimBuffers,
    argv_list: *[memory_limits.limits.arguments_maximum][]const u8,
) []const []const u8 {
    var index: usize = 0;
    while (buffers.exec_arguments_ptrs[index]) |argument| : (index += 1) {
        argv_list[index] = std.mem.sliceTo(argument, 0);
    }
    return argv_list[0..index];
}

test "shim_names" {
    try std.testing.expect(is_shim_name("zig"));
    try std.testing.expect(is_shim_name("zls"));
    try std.testing.expect(!is_shim_name("zvm"));

    if (builtin.os.tag == .windows) {
        try std.testing.expect(is_shim_name("zig.exe"));
        try std.testing.expect(is_shim_name("zls.exe"));
        try std.testing.expect(!is_shim_name("zvm.exe"));
    }
}

test "build_tool_path points at the current tool binary" {
    var buffers: ShimBuffers = undefined;
    buffers.exec_arguments_count = 0;

    const zig_path = try build_tool_path(&buffers, "zig", "/tmp/.zm");
    const expected_zig = if (builtin.os.tag == .windows)
        "/tmp/.zm/current/zig/zig.exe"
    else
        "/tmp/.zm/current/zig/zig";
    try std.testing.expectEqualStrings(expected_zig, zig_path);

    const zls_path = try build_tool_path(&buffers, "zls", "/tmp/.zm");
    const expected_zls = if (builtin.os.tag == .windows)
        "/tmp/.zm/current/zls/zls.exe"
    else
        "/tmp/.zm/current/zls/zls";
    try std.testing.expectEqualStrings(expected_zls, zls_path);
}

test "build_versioned_tool_path points at the versioned tool binary" {
    var buffers: ShimBuffers = undefined;
    buffers.exec_arguments_count = 0;

    const zig_path = try build_versioned_tool_path(&buffers, "zig", "/tmp/.zm", "0.13.0");
    const expected_zig = if (builtin.os.tag == .windows)
        "/tmp/.zm/version/zig/0.13.0/zig.exe"
    else
        "/tmp/.zm/version/zig/0.13.0/zig";
    try std.testing.expectEqualStrings(expected_zig, zig_path);

    const zls_path = try build_versioned_tool_path(&buffers, "zls", "/tmp/.zm", "0.13.0");
    const expected_zls = if (builtin.os.tag == .windows)
        "/tmp/.zm/version/zls/0.13.0/zls.exe"
    else
        "/tmp/.zm/version/zls/0.13.0/zls";
    try std.testing.expectEqualStrings(expected_zls, zls_path);
}
