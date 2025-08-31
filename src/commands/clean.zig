const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const util_color = @import("../util/color.zig");
const util_data = @import("../util/data.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");

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
        var current_zig_buffer = try ctx.acquire_path_buffer();
        defer current_zig_buffer.reset();

        var current_zls_buffer = try ctx.acquire_path_buffer();
        defer current_zls_buffer.reset();

        const current_zig_path = try util_data.get_zvm_zig_version(current_zig_buffer);
        const current_zls_path = try util_data.get_zvm_zls_version(current_zls_buffer);

        var zig_version_entry = try ctx.acquire_version_entry();
        defer zig_version_entry.reset();

        var zls_version_entry = try ctx.acquire_version_entry();
        defer zls_version_entry.reset();

        const zig_file = std.fs.openFileAbsolute(current_zig_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const current_zig_version = if (zig_file) |f| blk: {
            defer f.close();
            const bytes_read = try f.read(zig_version_entry.name_buffer[0..]);
            zig_version_entry.name_length = @intCast(bytes_read);
            break :blk zig_version_entry.get_name();
        } else null;

        const zls_file = std.fs.openFileAbsolute(current_zls_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const current_zls_version = if (zls_file) |f| blk: {
            defer f.close();
            const bytes_read = try f.read(zls_version_entry.name_buffer[0..]);
            zls_version_entry.name_length = @intCast(bytes_read);
            break :blk zls_version_entry.get_name();
        } else null;

        const trimmed_zig_current = if (current_zig_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;
        const trimmed_zls_current = if (current_zls_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;

        iterator = store_dir.iterate();
        var versions_removed: usize = 0;

        try color.bold().yellow().print("\nCleaning unused versions...\n", .{});

        while (try iterator.next()) |entry| {
            if (entry.kind != .directory) continue;

            const is_current_zig = if (trimmed_zig_current) |czv| std.mem.eql(u8, entry.name, czv) else false;
            const is_current_zls = if (trimmed_zls_current) |czv| std.mem.eql(u8, entry.name, czv) else false;

            if (is_current_zig or is_current_zls) {
                const marker = if (is_current_zig and is_current_zls) "zig,zls" else if (is_current_zig) "zig" else "zls";
                try color.cyan().print("  Keeping {s} (current {s})\n", .{ entry.name, marker });
                continue;
            }

            try color.red().print("  Removing {s}\n", .{entry.name});
            try store_dir.deleteTree(entry.name);
            versions_removed += 1;
        }

        if (versions_removed > 0) {
            try color.bold().green().print("\nRemoved {d} unused version(s).\n", .{versions_removed});
        } else {
            try color.bold().cyan().print("\nNo unused versions found.\n", .{});
        }
    }
}
