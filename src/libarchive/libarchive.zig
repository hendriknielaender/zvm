const std = @import("std");
const lib = @import("../libarchive/libarchive-bindings.zig");

const ArchiveError = error{
    FailedToOpenArchive,
    FailedToSetSupport,
    FailedToReadHeader,
    FailedToExtract,
    NullArchivePointer,
};

pub fn extractTarXZ(archivePath: []const u8) !void {
    const archive_reader = lib.archive_read_new();
    if (lib.archive_error_string(archive_reader) != null) {
        return ArchiveError.NullArchivePointer;
    }
    defer _ = lib.archive_read_free(archive_reader);

    // Add support for xz compression and tar format
    try setSupport(archive_reader);

    const file = try std.fs.openFileAbsolute(archivePath, .{});
    defer file.close();

    try openArchiveReaderWithFileDescriptor(archive_reader, file.handle);

    try extractArchiveEntries(archive_reader);
}

fn setSupport(archive_reader: *lib.struct_archive) !void {
    if (lib.archive_read_support_filter_xz(archive_reader) != lib.ARCHIVE_OK) {
        return ArchiveError.FailedToSetSupport;
    }
    if (lib.archive_read_support_format_tar(archive_reader) != lib.ARCHIVE_OK) {
        return ArchiveError.FailedToSetSupport;
    }
}

fn openArchiveReaderWithFileDescriptor(archive_reader: *lib.struct_archive, file_handle: anytype) !void {
    if (lib.archive_read_open_fd(archive_reader, file_handle, 10240) != lib.ARCHIVE_OK) {
        const err_msg = lib.archive_error_string(archive_reader);
        std.debug.print("LibArchive Error: {s}\n", .{err_msg});
        return ArchiveError.FailedToOpenArchive;
    }
}

fn extractArchiveEntries(archive_reader: *lib.struct_archive) !void {
    var entry: *lib.struct_archive_entry = undefined;
    while (true) {
        const result = lib.archive_read_next_header(archive_reader, &entry);
        if (result == lib.ARCHIVE_EOF) {
            break;
        } else if (result != lib.ARCHIVE_OK) {
            return ArchiveError.FailedToReadHeader;
        }

        if (lib.archive_read_extract(archive_reader, entry, lib.ARCHIVE_EXTRACT_TIME | lib.ARCHIVE_EXTRACT_PERM | lib.ARCHIVE_EXTRACT_ACL | lib.ARCHIVE_EXTRACT_FFLAGS) != lib.ARCHIVE_OK) {
            return ArchiveError.FailedToExtract;
        }
    }
}
