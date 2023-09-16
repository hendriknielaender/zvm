const std = @import("std");

const ProgressBarLength = 20;

pub fn print(current: usize, total: usize) void {
    // Ensure bounds are not exceeded
    if (current > total) return;

    const percentage = (current * 100) / total;
    const filledBlocks = (percentage * ProgressBarLength) / 100;

    // Use a fixed-size buffer
    var output: [ProgressBarLength + 10]u8 = undefined;

    var output_slice: []u8 = output[0..];
    var writer = ArrayWriter{ .buf = output[0..], .index = 0 };

    writer.writeByte('[') catch unreachable;

    for (0..filledBlocks) |_| {
        writer.writeByte('=') catch unreachable;
    }

    for (filledBlocks..ProgressBarLength) |_| {
        writer.writeByte(' ') catch unreachable;
    }

    writer.print("] {d}%\r", .{percentage}) catch unreachable;
    std.debug.print("{s}\r", .{output_slice[0..writer.index]});
}

const ArrayWriter = struct {
    buf: []u8,
    index: usize,

    pub fn writeByte(self: *ArrayWriter, byte: u8) !void {
        if (self.index < self.buf.len) {
            self.buf[self.index] = byte;
            self.index += 1;
        } else {
            return error.NoSpaceLeft;
        }
    }

    pub fn print(self: *ArrayWriter, comptime format: []const u8, args: anytype) !void {
        const bytes_written = (try std.fmt.bufPrint(self.buf[self.index..], format, args)).len;
        self.index += bytes_written;
    }
};
