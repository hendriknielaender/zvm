const std = @import("std");
const context = @import("../Context.zig");
const util_color = @import("../util/color.zig");
const util_data = @import("../util/data.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");
const detect_version = @import("../core/detect_version.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CleanCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var color = util_color.Color.RuntimeStyle.init();

    var store_buffer = try ctx.acquire_path_buffer();
    defer store_buffer.reset();

    const store_path = try util_data.get_zvm_store(store_buffer);

    const fs = std.fs.cwd();
    var store_dir = fs.openDir(store_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer store_dir.close();

    var iterator = store_dir.iterate();
    var files_removed: usize = 0;
    var bytes_freed: u64 = 0;

    while (try iterator.next()) |entry| {
        if (entry.kind == .directory) continue;

        if (entry.kind == .file) {
            const file = try store_dir.openFile(entry.name, .{});
            const file_info = try file.stat();
            const file_size = file_info.size;
            file.close();

            try store_dir.deleteFile(entry.name);

            files_removed += 1;
            bytes_freed += file_size;
        }
    }

    if (files_removed > 0) {
        const mb_freed = @as(f64, @floatFromInt(bytes_freed)) / (1024.0 * 1024.0);
        try color.bold().green().print(
            "Cleaned up {d} old download artifact(s), freed {d:.2} MB.\n",
            .{ files_removed, mb_freed },
        );
    } else {
        try color.bold().cyan().print("No old download artifacts found to clean.\n", .{});
    }

    if (command.remove_all) {
        var versions_removed: usize = 0;
        try color.bold().yellow().print("\nCleaning unused versions...\n", .{});

        var current_zig_version_buffer: [limits.limits.version_string_length_maximum]u8 = undefined;
        const current_zig_version = detect_version.find_default_version_in_buffer(
            ctx,
            &current_zig_version_buffer,
        ) catch null;

        var current_zls_version_storage: [limits.limits.version_string_length_maximum]u8 = undefined;
        var current_zls_version: ?[]const u8 = null;
        {
            var zls_current_buffer = try ctx.acquire_path_buffer();
            defer zls_current_buffer.reset();

            var output_buffer: [limits.limits.temp_buffer_size]u8 = undefined;
            const detected_zls_version = util_data.get_current_version(
                zls_current_buffer,
                &output_buffer,
                true,
            ) catch |err| switch (err) {
                error.EmptyVersion, error.FailedToReadVersion, error.FileNotFound => null,
                else => return err,
            };

            if (detected_zls_version) |version| {
                const trimmed = std.mem.trim(u8, version, " \t\n\r");
                if (trimmed.len > 0 and trimmed.len <= current_zls_version_storage.len) {
                    @memcpy(current_zls_version_storage[0..trimmed.len], trimmed);
                    current_zls_version = current_zls_version_storage[0..trimmed.len];
                }
            }
        }

        var zig_versions_buffer = try ctx.acquire_path_buffer();
        defer zig_versions_buffer.reset();
        const zig_versions_path = try util_data.get_zvm_zig_version(zig_versions_buffer);

        const zig_versions_dir = std.fs.openDirAbsolute(zig_versions_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (zig_versions_dir) |zig_dir_value| {
            var zig_dir = zig_dir_value;
            defer zig_dir.close();

            var zig_iterator = zig_dir.iterate();
            while (try zig_iterator.next()) |entry| {
                if (entry.kind != .directory) continue;

                const is_current = if (current_zig_version) |version|
                    std.mem.eql(u8, entry.name, version)
                else
                    false;

                if (is_current) {
                    try color.cyan().print("  Keeping zig/{s} (current)\n", .{entry.name});
                    continue;
                }

                try color.red().print("  Removing zig/{s}\n", .{entry.name});
                try zig_dir.deleteTree(entry.name);
                versions_removed += 1;
            }
        }

        var zls_versions_buffer = try ctx.acquire_path_buffer();
        defer zls_versions_buffer.reset();
        const zls_versions_path = try util_data.get_zvm_zls_version(zls_versions_buffer);

        const zls_versions_dir = std.fs.openDirAbsolute(zls_versions_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (zls_versions_dir) |zls_dir_value| {
            var zls_dir = zls_dir_value;
            defer zls_dir.close();

            var zls_iterator = zls_dir.iterate();
            while (try zls_iterator.next()) |entry| {
                if (entry.kind != .directory) continue;

                const is_current = if (current_zls_version) |version|
                    std.mem.eql(u8, entry.name, version)
                else
                    false;

                if (is_current) {
                    try color.cyan().print("  Keeping zls/{s} (current)\n", .{entry.name});
                    continue;
                }

                try color.red().print("  Removing zls/{s}\n", .{entry.name});
                try zls_dir.deleteTree(entry.name);
                versions_removed += 1;
            }
        }

        if (versions_removed > 0) {
            try color.bold().green().print("\nRemoved {d} unused version(s).\n", .{versions_removed});
        } else {
            try color.bold().cyan().print("\nNo unused versions found.\n", .{});
        }
    }
}
