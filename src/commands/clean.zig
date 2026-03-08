const std = @import("std");
const context = @import("../Context.zig");
const util_color = @import("../util/color.zig");
const util_data = @import("../util/data.zig");
const util_tool = @import("../util/tool.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");

const StoreCleanup = struct {
    files_removed: usize = 0,
    bytes_freed: u64 = 0,
};

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CleanCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var color = util_color.Color.RuntimeStyle.init();
    try clean_download_store(ctx, &color);

    if (!command.remove_all) return;
    try clean_installed_versions(ctx, &color);
}

fn clean_download_store(
    ctx: *context.CliContext,
    color: *util_color.Color.RuntimeStyle,
) !void {
    var store_buffer = try ctx.acquire_path_buffer();
    defer store_buffer.reset();

    const store_path = try util_data.get_zvm_store(store_buffer);
    var store_dir = std.fs.openDirAbsolute(store_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
            return;
        },
        else => return err,
    };
    defer store_dir.close();

    const cleanup = try remove_download_artifacts(&store_dir);
    if (cleanup.files_removed == 0) {
        try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
        return;
    }

    const mb_freed = @as(f64, @floatFromInt(cleanup.bytes_freed)) / (1024.0 * 1024.0);
    try color.bold().green().print(
        "Cleaned up {d} old download artifact(s), freed {d:.2} MB.\n",
        .{ cleanup.files_removed, mb_freed },
    );
}

fn remove_download_artifacts(store_dir: *std.fs.Dir) !StoreCleanup {
    var iterator = store_dir.iterate();
    var cleanup = StoreCleanup{};

    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        const file = try store_dir.openFile(entry.name, .{});
        const file_info = try file.stat();
        file.close();

        try store_dir.deleteFile(entry.name);
        cleanup.files_removed += 1;
        cleanup.bytes_freed += file_info.size;
    }

    return cleanup;
}

fn clean_installed_versions(
    ctx: *context.CliContext,
    color: *util_color.Color.RuntimeStyle,
) !void {
    var current_zig_storage: [limits.limits.version_string_length_maximum]u8 = undefined;
    var current_zls_storage: [limits.limits.version_string_length_maximum]u8 = undefined;

    const current_zig_version = try read_current_version(ctx, .zig, &current_zig_storage);
    const current_zls_version = try read_current_version(ctx, .zls, &current_zls_storage);

    try color.bold().yellow().print("\nCleaning unused versions...\n", .{});

    var versions_removed: usize = 0;
    versions_removed += try clean_versions_for_tool(ctx, color, .zig, current_zig_version);
    versions_removed += try clean_versions_for_tool(ctx, color, .zls, current_zls_version);

    if (versions_removed == 0) {
        try color.bold().cyan().print("\nNo unused versions found.\n", .{});
        return;
    }

    try color.bold().green().print("\nRemoved {d} unused version(s).\n", .{versions_removed});
}

fn read_current_version(
    ctx: *context.CliContext,
    tool: validation.ToolType,
    version_buffer: []u8,
) !?[]const u8 {
    var current_path_buffer = try ctx.acquire_path_buffer();
    defer current_path_buffer.reset();

    const current_path = switch (tool) {
        .zig => try util_data.get_zvm_current_zig(current_path_buffer),
        .zls => try util_data.get_zvm_current_zls(current_path_buffer),
    };
    if (!util_tool.does_path_exist(current_path)) return null;

    var output_buffer: [limits.limits.temp_buffer_size]u8 = undefined;
    const version_output = util_data.get_current_version(
        current_path_buffer,
        &output_buffer,
        tool == .zls,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const trimmed = std.mem.trim(u8, version_output, " \t\n\r");
    if (trimmed.len == 0) return null;
    if (trimmed.len > version_buffer.len) return error.BufferTooSmall;

    @memcpy(version_buffer[0..trimmed.len], trimmed);
    return version_buffer[0..trimmed.len];
}

fn clean_versions_for_tool(
    ctx: *context.CliContext,
    color: *util_color.Color.RuntimeStyle,
    tool: validation.ToolType,
    current_version: ?[]const u8,
) !usize {
    var versions_path_buffer = try ctx.acquire_path_buffer();
    defer versions_path_buffer.reset();

    const versions_path = switch (tool) {
        .zig => try util_data.get_zvm_zig_version(versions_path_buffer),
        .zls => try util_data.get_zvm_zls_version(versions_path_buffer),
    };
    var versions_dir = std.fs.openDirAbsolute(versions_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer versions_dir.close();

    var iterator = versions_dir.iterate();
    var versions_removed: usize = 0;

    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        if (current_version) |current| {
            if (std.mem.eql(u8, entry.name, current)) {
                try color.cyan().print("  Keeping {s} {s} (current)\n", .{
                    tool.to_string(),
                    entry.name,
                });
                continue;
            }
        }

        try color.red().print("  Removing {s} {s}\n", .{ tool.to_string(), entry.name });
        try versions_dir.deleteTree(entry.name);
        versions_removed += 1;
    }

    return versions_removed;
}

test "remove_download_artifacts deletes only files" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const artifact = try tmp_dir.dir.createFile("artifact.tar.xz", .{});
    try artifact.writeAll("artifact");
    artifact.close();

    try tmp_dir.dir.makeDir("versions");

    var dir = tmp_dir.dir;
    const cleanup = try remove_download_artifacts(&dir);

    try std.testing.expectEqual(@as(usize, 1), cleanup.files_removed);
    try std.testing.expectEqual(@as(u64, 8), cleanup.bytes_freed);
    try std.testing.expectError(error.FileNotFound, dir.access("artifact.tar.xz", .{}));
    try dir.access("versions", .{});
}
