const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn fixedBufferStream(buffer: []u8) FixedBufferStream {
    return .{
        .writer_state = .fixed(buffer),
    };
}

pub const FixedBufferStream = struct {
    writer_state: std.Io.Writer,

    pub fn writer(self: *FixedBufferStream) *std.Io.Writer {
        return &self.writer_state;
    }

    pub fn getWritten(self: *const FixedBufferStream) []u8 {
        return self.writer_state.buffered();
    }
};
