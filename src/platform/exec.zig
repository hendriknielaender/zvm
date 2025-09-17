const std = @import("std");
const builtin = @import("builtin");
const Errors = @import("../Errors.zig");
const limits = @import("../memory/limits.zig");
const log = std.log.scoped(.exec);

pub const ExecBuffers = struct {
    tool_path: [limits.limits.path_length_maximum]u8,
    exec_arguments_ptrs: [limits.limits.arguments_maximum + 1]?[*:0]const u8,
    exec_arguments_storage: [limits.limits.arguments_storage_size_maximum]u8,
    exec_arguments_count: u32 = 0,
};

pub fn build_tool_path(buffers: *ExecBuffers, program_name: []const u8, zvm_home: []const u8) ![]const u8 {
    const tool_name = if (std.mem.eql(u8, program_name, "zig")) "zig" else "zls";

    var stream = std.Io.fixedBufferStream(&buffers.tool_path);
    try stream.writer().print("{s}/current/{s}", .{ zvm_home, tool_name });
    return stream.getWritten();
}

pub fn build_exec_arguments(buffers: *ExecBuffers, tool_path: []const u8, remaining_arguments: []const []const u8) !void {
    var exec_arguments_count: u32 = 0;
    var storage_offset: u32 = 0;

    if (tool_path.len > buffers.exec_arguments_storage.len) {
        return Errors.ZvmError.ToolPathTooLong;
    }

    @memcpy(buffers.exec_arguments_storage[0..tool_path.len], tool_path);
    buffers.exec_arguments_storage[tool_path.len] = 0;
    buffers.exec_arguments_ptrs[0] = @ptrCast(&buffers.exec_arguments_storage[0]);
    exec_arguments_count = 1;
    storage_offset = @intCast(tool_path.len + 1);

    for (remaining_arguments) |argument| {
        if (exec_arguments_count >= buffers.exec_arguments_ptrs.len) {
            return Errors.ZvmError.TooManyExecArgs;
        }
        if (storage_offset + argument.len + 1 > buffers.exec_arguments_storage.len) {
            return Errors.ZvmError.ExecArgsStorageFull;
        }

        @memcpy(buffers.exec_arguments_storage[storage_offset .. storage_offset + argument.len], argument);
        buffers.exec_arguments_storage[storage_offset + argument.len] = 0;
        buffers.exec_arguments_ptrs[exec_arguments_count] = @ptrCast(&buffers.exec_arguments_storage[storage_offset]);
        storage_offset += @intCast(argument.len + 1);
        exec_arguments_count += 1;
    }

    buffers.exec_arguments_ptrs[exec_arguments_count] = null;
    buffers.exec_arguments_count = exec_arguments_count;
}

pub fn exec_tool(buffers: *ExecBuffers, tool_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        var argv_list: [limits.limits.arguments_maximum][]const u8 = undefined;
        var i: usize = 0;
        while (buffers.exec_arguments_ptrs[i]) |arg| : (i += 1) {
            argv_list[i] = std.mem.sliceTo(arg, 0);
        }
        const argv_slice = argv_list[0..i];

        var process = std.process.Child.init(argv_slice, std.heap.page_allocator);
        process.spawn() catch |err| {
            log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(err) });
            return err;
        };
        const term = try process.wait();
        std.process.exit(term.Exited);
    } else {
        const argv: [*:null]?[*:0]const u8 = @ptrCast(&buffers.exec_arguments_ptrs[0]);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

        const result = std.posix.execveZ(argv[0].?, argv, envp);
        log.err("Failed to execute {s}: {s}", .{ tool_path, @errorName(result) });
        return result;
    }
}
