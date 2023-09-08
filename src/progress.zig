// progress.zig
const std = @import("std");

const ProgressBarLength = 20;

pub fn printBar(current: usize, total: usize) void {
    const percentage = (current * 100) / total;
    const filledBlocks = (current * ProgressBarLength) / total;

    std.debug.print("[", .{});

    var i: usize = 0;
    while (i < filledBlocks) {
        std.debug.print("=", .{});
        i += 1;
    }
    while (i < ProgressBarLength) {
        std.debug.print(" ", .{});
        i += 1;
    }

    std.debug.print("] {d}%", .{percentage});
    std.debug.print("\r", .{}); // Move the cursor to the start of the line to overwrite the existing progress bar
}
