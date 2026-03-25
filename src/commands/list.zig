const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const util_data = @import("../util/data.zig");
const validation = @import("../cli/validation.zig");
const limits = @import("../memory/limits.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    var zig_versions: [limits.limits.versions_maximum][]const u8 = undefined;
    var zig_storage: [limits.limits.versions_maximum][limits.limits.version_string_length_maximum]u8 =
        undefined;
    const zig_count = try collect_versions(ctx, .zig, &zig_versions, &zig_storage);

    if (!command.show_all) {
        try emit_zig_versions(zig_versions[0..zig_count], zig_count);
        return;
    }

    var zls_versions: [limits.limits.versions_maximum][]const u8 = undefined;
    var zls_storage: [limits.limits.versions_maximum][limits.limits.version_string_length_maximum]u8 =
        undefined;
    const zls_count = try collect_versions(ctx, .zls, &zls_versions, &zls_storage);
    try emit_all_versions(zig_versions[0..zig_count], zls_versions[0..zls_count]);
}

fn collect_versions(
    ctx: *context.CliContext,
    tool: validation.ToolType,
    versions: *[limits.limits.versions_maximum][]const u8,
    storage: *[limits.limits.versions_maximum][limits.limits.version_string_length_maximum]u8,
) !usize {
    var versions_path_buffer = try ctx.acquire_path_buffer();
    defer versions_path_buffer.reset();

    const versions_path = switch (tool) {
        .zig => try util_data.get_zvm_zig_version(versions_path_buffer),
        .zls => try util_data.get_zvm_zls_version(versions_path_buffer),
    };
    var versions_dir = std.fs.openDirAbsolute(versions_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer versions_dir.close();

    var version_count: usize = 0;
    var iterator = versions_dir.iterate();

    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        if (version_count >= versions.len) break;

        if (entry.name.len > storage[version_count].len) return error.NameTooLong;

        @memcpy(storage[version_count][0..entry.name.len], entry.name);
        versions[version_count] = storage[version_count][0..entry.name.len];
        version_count += 1;
    }

    std.mem.sortUnstable([]const u8, versions[0..version_count], {}, order_versions);
    return version_count;
}

fn order_versions(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn emit_zig_versions(versions: []const []const u8, version_count: usize) !void {
    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        util_output.json_array("installed", versions);
        return;
    }

    if (version_count == 0) {
        util_output.warn("No Zig versions installed.", .{});
        return;
    }

    util_output.info("Installed Zig versions:", .{});
    for (versions) |version| {
        util_output.info("  {s}", .{version});
    }
}

fn emit_all_versions(zig_versions: []const []const u8, zls_versions: []const []const u8) !void {
    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "zig", .value = .{ .array_strings = zig_versions } },
            .{ .key = "zls", .value = .{ .array_strings = zls_versions } },
        };
        util_output.json_object(&fields);
        return;
    }

    if (zig_versions.len == 0 and zls_versions.len == 0) {
        util_output.warn("No Zig or ZLS versions installed.", .{});
        return;
    }

    if (zig_versions.len > 0) {
        util_output.info("Installed Zig versions:", .{});
        for (zig_versions) |version| {
            util_output.info("  {s}", .{version});
        }
    }

    if (zls_versions.len > 0) {
        if (zig_versions.len > 0) {
            util_output.print_text("\n");
        }

        util_output.info("Installed ZLS versions:", .{});
        for (zls_versions) |version| {
            util_output.info("  {s}", .{version});
        }
    }
}
