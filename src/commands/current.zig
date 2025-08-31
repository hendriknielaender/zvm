const std = @import("std");
const context = @import("../context.zig");
const util_output = @import("../util/output.zig");
const util_data = @import("../util/data.zig");
const validation = @import("../validation.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CurrentCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = command;
    _ = progress_node;

    const emitter = util_output.get_global();

    var zig_version_buffer = try ctx.acquire_path_buffer();
    defer zig_version_buffer.reset();

    var zls_version_buffer = try ctx.acquire_path_buffer();
    defer zls_version_buffer.reset();

    const zig_version_path = try util_data.get_zvm_zig_version(zig_version_buffer);
    const zls_version_path = try util_data.get_zvm_zls_version(zls_version_buffer);

    var zig_entry = try ctx.acquire_version_entry();
    defer zig_entry.reset();

    var zls_entry = try ctx.acquire_version_entry();
    defer zls_entry.reset();

    const zig_file = std.fs.openFileAbsolute(zig_version_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const zig_version = if (zig_file) |f| blk: {
        defer f.close();
        const bytes_read = try f.read(zig_entry.name_buffer[0..]);
        zig_entry.name_length = @intCast(bytes_read);
        break :blk zig_entry.get_name();
    } else null;

    const zls_file = std.fs.openFileAbsolute(zls_version_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const zls_version = if (zls_file) |f| blk: {
        defer f.close();
        const bytes_read = try f.read(zls_entry.name_buffer[0..]);
        zls_entry.name_length = @intCast(bytes_read);
        break :blk zls_entry.get_name();
    } else null;

    if (emitter.config.mode == .machine_json) {
        const zig_trimmed = if (zig_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;
        const zls_trimmed = if (zls_version) |v| std.mem.trim(u8, v, " \t\n\r") else null;

        const fields = [_]util_output.JsonField{
            .{ .key = "zig", .value = .{ .string = zig_trimmed } },
            .{ .key = "zls", .value = .{ .string = zls_trimmed } },
        };
        util_output.json_object(&fields);
    } else {
        if (zig_version) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\n\r");
            util_output.info("Zig version: {s}", .{trimmed});
        } else {
            util_output.info("Zig version: not set", .{});
        }

        if (zls_version) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\n\r");
            util_output.info("ZLS version: {s}", .{trimmed});
        } else {
            util_output.info("ZLS version: not set", .{});
        }
    }
}
