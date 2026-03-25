const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");
const config = @import("../metadata.zig");
const http_client = @import("../io/http_client.zig");
const meta = @import("../core/meta.zig");
const object_pools = @import("../memory/object_pools.zig");
const limits = @import("../memory/limits.zig");
const version_entries_max = 100;

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.ListRemoteCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = progress_node;

    const meta_url = if (command.tool == .zls) config.zls_url else config.zig_url;
    const response = try http_client.HttpClient.fetch(ctx, meta_url, .{});
    var version_entries_storage: [limits.limits.versions_maximum]*object_pools.VersionEntry = undefined;
    const version_count = try load_version_entries(
        ctx,
        command.tool,
        response,
        &version_entries_storage,
    );
    defer release_version_entries(version_entries_storage[0..version_entries_max]);

    var version_names: [limits.limits.versions_maximum][]const u8 = undefined;
    copy_version_names(version_entries_storage[0..version_count], &version_names);

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "tool", .value = .{ .string = command.tool.to_string() } },
            .{ .key = "available", .value = .{ .array_strings = version_names[0..version_count] } },
        };
        util_output.json_object(&fields);
        return;
    }

    if (command.tool == .zls) {
        util_output.info("Available ZLS versions:", .{});
    } else {
        util_output.info("Available Zig versions:", .{});
    }

    for (version_names[0..version_count]) |version| {
        util_output.info("  {s}", .{version});
    }
}

fn load_version_entries(
    ctx: *context.CliContext,
    tool: validation.ToolType,
    response: []const u8,
    version_entries_storage: *[limits.limits.versions_maximum]*object_pools.VersionEntry,
) !usize {
    var entries_count: usize = 0;
    errdefer release_version_entries(version_entries_storage[0..entries_count]);

    while (entries_count < version_entries_max) : (entries_count += 1) {
        version_entries_storage[entries_count] = try ctx.acquire_version_entry();
    }

    const version_count = if (tool == .zls)
        try meta.Zls.get_version_list(response, version_entries_storage[0..entries_count])
    else
        try meta.Zig.get_version_list(response, version_entries_storage[0..entries_count]);

    return version_count;
}

fn copy_version_names(
    version_entries: []const *object_pools.VersionEntry,
    version_names: *[limits.limits.versions_maximum][]const u8,
) void {
    for (version_entries, 0..) |entry, index| {
        version_names[index] = entry.get_name();
    }
}

fn release_version_entries(entries: []const *object_pools.VersionEntry) void {
    for (entries) |entry| {
        entry.reset();
    }
}
