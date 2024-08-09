const std = @import("std");
const util_data = @import("util/data.zig");
const command = @import("command.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // this will detect the memory whether leak
    defer if (gpa.deinit() == .leak) @panic("memory leaked!");

    // init some useful data
    try util_data.data_init(gpa.allocator());
    // deinit some data
    defer util_data.data_deinit();

    // get allocator
    const allocator = util_data.get_allocator();

    // get and free args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // try handle alias
    try command.handle_alias(args);

    // parse the args and handle command
    try command.handle_command(args);
}
