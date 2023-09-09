// progress.zig
const std = @import("std");

const ProgressBarLength = 20;

pub fn print(current: usize, total: usize, offset_percentage: usize) void {
    const true_percentage = ((current * 100) / total) + offset_percentage;
    const filledBlocks = (true_percentage * ProgressBarLength) / 100;

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

    std.debug.print("] {d}%", .{true_percentage});
    std.debug.print("\r", .{}); // Move the cursor to the start of the line to overwrite the existing progress bar
}
