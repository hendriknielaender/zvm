const std = @import("std");
const Allocator = std.mem.Allocator;

const Archive = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

pub fn extractTarXZ(archivePath: []const u8) !void {
    var a = Archive.archive_read_new();
    var entry: ?*Archive.struct_archive_entry = null;

    //defer _ = Archive.archive_read_close(a);
    defer _ = Archive.archive_read_free(a);

    _ = Archive.archive_read_support_filter_xz(a);
    _ = Archive.archive_read_support_format_tar(a);

    var file = try std.fs.openFileAbsolute(archivePath, .{});
    defer file.close();

    if (Archive.archive_read_open_fd(a, file.handle, 10240) != Archive.ARCHIVE_OK) {
        const err_msg = Archive.archive_error_string(a);
        std.debug.print("LibArchive Error: {s}\n", .{err_msg});
        return error.FailedToOpenArchive;
    }

    while (Archive.archive_read_next_header(a, &entry) == Archive.ARCHIVE_OK) {
        _ = Archive.archive_read_extract(a, entry, Archive.ARCHIVE_EXTRACT_TIME | Archive.ARCHIVE_EXTRACT_PERM | Archive.ARCHIVE_EXTRACT_ACL | Archive.ARCHIVE_EXTRACT_FFLAGS);
    }
}
