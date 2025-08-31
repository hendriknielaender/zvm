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
    _ = command.show_all;
    _ = progress_node;

    const emitter = util_output.get_global();

    var zig_versions_buffer = try ctx.acquire_path_buffer();
    defer zig_versions_buffer.reset();

    const zig_versions_path = try util_data.get_zvm_zig_version(zig_versions_buffer);

    var zig_dir = std.fs.openDirAbsolute(zig_versions_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (emitter.config.mode == .machine_json) {
                    util_output.json_array("installed", &[_][]const u8{});
                } else {
                    util_output.warn("No Zig versions installed.", .{});
                }
                return;
            },
            else => return err,
        }
    };
    defer zig_dir.close();

    var versions: [limits.limits.versions_maximum][]const u8 = undefined;
    var version_count: usize = 0;
    var iterator = zig_dir.iterate();

    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        if (entry.name[0] == '.') continue;

        if (version_count < versions.len) {
            versions[version_count] = entry.name;
            version_count += 1;
        }
    }

    if (emitter.config.mode == .machine_json) {
        util_output.json_array("installed", versions[0..version_count]);
    } else {
        if (version_count == 0) {
            util_output.warn("No Zig versions installed.", .{});
        } else {
            util_output.info("Installed Zig versions:", .{});
            for (versions[0..version_count]) |version| {
                util_output.info("  {s}", .{version});
            }
        }
    }
}
