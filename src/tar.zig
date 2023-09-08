const std = @import("std");
const assert = std.debug.assert;
const progress = @import("progress.zig");

const Options = struct {
    strip_components: u8,
    mode_mode: ModeMode,

    const ModeMode = enum {
        ignore,
        executable_bit_only,
    };
};

pub const Header = struct {
    bytes: *const [512]u8,

    pub const FileType = enum(u8) {
        normal = '0',
        hard_link = '1',
        symbolic_link = '2',
        character_special = '3',
        block_special = '4',
        directory = '5',
        fifo = '6',
        contiguous = '7',
        global_extended_header = 'g',
        extended_header = 'x',
        _,
    };

    pub fn fileSize(header: Header) !u64 {
        const raw = header.bytes[124..][0..12];
        const ltrimmed = std.mem.trimLeft(u8, raw, "0");
        const rtrimmed = std.mem.trimRight(u8, ltrimmed, " \x00");
        if (rtrimmed.len == 0) return 0;
        return std.fmt.parseInt(u64, rtrimmed, 8);
    }

    pub fn is_ustar(header: Header) bool {
        return std.mem.eql(u8, header.bytes[257..][0..6], "ustar\x00");
    }

    /// Includes prefix concatenated, if any.
    /// Return value may point into Header buffer, or might point into the
    /// argument buffer.
    /// TODO: check against "../" and other nefarious things
    pub fn fullFileName(header: Header, buffer: *[255]u8) ![]const u8 {
        const n = name(header);
        if (!is_ustar(header))
            return n;
        const p = prefix(header);
        if (p.len == 0)
            return n;
        @memcpy(buffer[0..p.len], p);
        buffer[p.len] = '/';
        @memcpy(buffer[p.len + 1 ..][0..n.len], n);
        return buffer[0 .. p.len + 1 + n.len];
    }

    pub fn name(header: Header) []const u8 {
        return str(header, 0, 0 + 100);
    }

    pub fn prefix(header: Header) []const u8 {
        return str(header, 345, 345 + 155);
    }

    pub fn fileType(header: Header) FileType {
        const result = @as(FileType, @enumFromInt(header.bytes[156]));
        return if (result == @as(FileType, @enumFromInt(0))) .normal else result;
    }

    fn str(header: Header, start: usize, end: usize) []const u8 {
        var i: usize = start;
        while (i < end) : (i += 1) {
            if (header.bytes[i] == 0) break;
        }
        return header.bytes[start..i];
    }
};

pub fn pipeToFileSystemWithProgress(dir: std.fs.Dir, reader: anytype, options: Options, totalSize: usize) !void {
    var file_name_buffer: [255]u8 = undefined;
    var buffer: [512 * 8]u8 = undefined;
    var start: usize = 0;
    var end: usize = 0;
    var totalBytesExtracted: usize = 0;

    header: while (true) {
        if (buffer.len - start < 1024) {
            const dest_end = end - start;
            @memcpy(buffer[0..dest_end], buffer[start..end]);
            end = dest_end;
            start = 0;
        }

        const ask_header = @min(buffer.len - end, 1024 -| (end - start));
        end += try reader.readAtLeast(buffer[end..], ask_header);
        totalBytesExtracted += end - start;
        progress.print(totalBytesExtracted, totalSize);

        const header: Header = .{ .bytes = buffer[start..][0..512] };
        start += 512;
        const file_size = try header.fileSize();
        const rounded_file_size = std.mem.alignForward(u64, file_size, 512);
        const pad_len = @as(usize, @intCast(rounded_file_size - file_size));
        const unstripped_file_name = try header.fullFileName(&file_name_buffer);

        switch (header.fileType()) {
            .directory => {
                const file_name = try stripComponents(unstripped_file_name, options.strip_components);
                if (file_name.len != 0) {
                    try dir.makePath(file_name);
                }
            },
            .normal => {
                const file_name = try stripComponents(unstripped_file_name, options.strip_components);

                if (std.fs.path.dirname(file_name)) |dir_name| {
                    try dir.makePath(dir_name);
                }
                var file = try dir.createFile(file_name, .{});
                defer file.close();

                var file_off: usize = 0;
                while (true) {
                    if (buffer.len - start < 1024) {
                        const dest_end = end - start;
                        @memcpy(buffer[0..dest_end], buffer[start..end]);
                        end = dest_end;
                        start = 0;
                    }

                    const ask = @as(usize, @intCast(@min(
                        buffer.len - end,
                        rounded_file_size + 512 - file_off -| (end - start),
                    )));
                    end += try reader.readAtLeast(buffer[end..], ask);
                    totalBytesExtracted += end - start;
                    progress.print(totalBytesExtracted, totalSize);

                    const slice = buffer[start..@as(usize, @intCast(@min(file_size - file_off + start, end)))];
                    try file.writeAll(slice);
                    file_off += slice.len;
                    start += slice.len;
                    if (file_off >= file_size) {
                        start += pad_len;
                        assert(start <= end);
                        continue :header;
                    }
                }
            },
            .global_extended_header, .extended_header => {
                if (start + rounded_file_size > end) return error.TarHeadersTooBig;
                start = @as(usize, @intCast(start + rounded_file_size));
            },
            .hard_link => return error.TarUnsupportedFileType,
            .symbolic_link => return error.TarUnsupportedFileType,
            else => return error.TarUnsupportedFileType,
        }
    }
}

fn stripComponents(path: []const u8, count: u32) ![]const u8 {
    var i: usize = 0;
    var c = count;
    while (c > 0) : (c -= 1) {
        if (std.mem.indexOfScalarPos(u8, path, i, '/')) |pos| {
            i = pos + 1;
        } else {
            return error.TarComponentsOutsideStrippedPrefix;
        }
    }
    return path[i..];
}

test stripComponents {
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings("a/b/c", try stripComponents("a/b/c", 0));
    try expectEqualStrings("b/c", try stripComponents("a/b/c", 1));
    try expectEqualStrings("c", try stripComponents("a/b/c", 2));
}
