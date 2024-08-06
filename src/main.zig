const std = @import("std");
const tools = @import("tools.zig");
const command = @import("command.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will detect the memory whether leak
    defer if (gpa.deinit() == .leak) @panic("memory leaked!");

    // init some useful data
    try tools.data_init(gpa.allocator());
    // deinit some data
    defer tools.data_deinit();

    // get allocator
    const allocator = tools.get_allocator();

    // get and free args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // try handle alias
    try command.handle_alias(args);

    // parse the args and handle command
    try command.handle_command(args);
}
