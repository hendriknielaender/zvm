// ! this file just store some config meta data
const std = @import("std");
const builtin = @import("builtin");

/// zig meta data url
pub const zig_meta_url: []const u8 = "https://ziglang.org/download/index.json";

/// Alternative mirrors for downloading Zig binaries
/// Format: [url, maintainer]
pub const zig_mirrors = [_][2][]const u8{
    [_][]const u8{ "https://pkg.machengine.org/zig", "slimsag <stephen@hexops.com>" },
    [_][]const u8{ "https://zigmirror.hryx.net/zig", "hryx <codroid@gmail.com>" },
    [_][]const u8{ "https://zig.linus.dev/zig", "linusg <mail@linusgroh.de>" },
    [_][]const u8{ "https://fs.liujiacai.net/zigbuilds", "jiacai2050 <hello@liujiacai.net>" },
    [_][]const u8{ "https://zigmirror.nesovic.dev/zig", "kaynetik <aleksandar@nesovic.dev>" },
    [_][]const u8{ "https://zig.nekos.space/zig", "0t4u <rattley@nekos.space>" },
};

pub var preferred_mirror: ?usize = null;

pub fn init_config() void {
    if (std.posix.getenv("ZVM_MIRROR")) |mirror_str| {
        if (std.fmt.parseInt(usize, mirror_str, 10)) |mirror_index| {
            if (mirror_index < zig_mirrors.len) {
                preferred_mirror = mirror_index;
                std.log.debug("Using mirror {d} from ZVM_MIRROR environment variable", .{mirror_index});
            } else {
                std.log.warn("Invalid ZVM_MIRROR value {d}, must be 0-{d}", .{ mirror_index, zig_mirrors.len - 1 });
            }
        } else |_| {
            std.log.warn("Invalid ZVM_MIRROR value '{s}', must be a number 0-{d}", .{ mirror_str, zig_mirrors.len - 1 });
        }
    }
}

/// zig minisign public key
pub const ZIG_MINISIGN_PUBLIC_KEY = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

/// zls meta data url
pub const zls_meta_url: []const u8 = "https://api.github.com/repos/zigtools/zls/releases";

/// parsed zig url
pub const zig_url = std.Uri.parse(zig_meta_url) catch @panic("Invalid zig_meta_url");
/// parsed zls url
pub const zls_url = std.Uri.parse(zls_meta_url) catch @panic("Invalid zls_meta_url");

/// zig file name
pub const zig_name = switch (builtin.os.tag) {
    .windows => "zig.exe",
    .linux, .macos => "zig",
    else => @compileError("Current platform not supported"),
};

/// zig file name
pub const zls_name = switch (builtin.os.tag) {
    .windows => "zls.exe",
    .linux, .macos => "zls",
    else => @compileError("Current platform not supported"),
};

/// zig archive_ext
pub const archive_ext = if (builtin.os.tag == .windows)
    "zip"
else
    "tar.xz";

/// zls_list_1 and zls_list_2 are path for zls version
/// because zls not have 0.12.1,
/// so when user install zls 0.12.1
/// zvm will automatically install 0.12.0
/// zls_list_1 is the list for mapping source
pub const zls_list_1 = [_][]const u8{
    "0.12.1",
};
/// zls_list_2 is the list for mapping result
pub const zls_list_2 = [_][]const u8{
    "0.12.0",
};

// ensure correct
comptime {
    if (zls_list_1.len != zls_list_2.len)
        @compileError("zls_list_1 length not equal to zls_list_2!");
}
