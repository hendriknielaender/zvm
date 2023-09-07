const std = @import("std");
const DirOpenError = std.fs.Dir.OpenError;

pub fn extractTarball(filePath: []const u8, destDir: []const u8) !void {
    // Open the tarball file for reading
    const file = try std.fs.cwd().openFile(filePath, .{});
    defer file.close();

    const destDirectory = try createDestDir(destDir);

    const options = std.tar.Options{
        .mode_mode = .ignore, // use .ignore for now; update as needed
        .strip_components = 0, // Assuming you don't want to strip any path components; update as needed
    };

    try std.tar.pipeToFileSystem(destDirectory, file.reader(), options);
}

fn createDestDir(destDir: []const u8) !std.fs.Dir {
    if (try folderExists(destDir) == false) {
        try std.fs.cwd().makeDir(destDir);
    }

    return try std.fs.cwd().openDir(destDir, .{});
}

pub fn folderExists(path: []const u8) !bool {
    var folder = std.fs.cwd().openDir(path, .{}) catch |e| {
        switch (e) {
            DirOpenError.FileNotFound => return false,
            else => {
                std.log.debug("error: {s}", .{@errorName(e)});
                return true;
            },
        }
    };
    folder.close();

    return true;
}
