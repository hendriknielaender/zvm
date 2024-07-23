const std = @import("std");
const crypto = std.crypto;
const testing = std.testing;
const mem = std.mem;

pub fn verify_hash(computed_hash: [32]u8, actual_hash_string: []const u8) bool {
    if (actual_hash_string.len != 64) return false; // SHA256 hash should be 64 hex characters

    var actual_hash_bytes: [32]u8 = undefined;
    var i: usize = 0;

    for (actual_hash_string) |char| {
        const byte = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return false, // Invalid character in hash string
        };

        if (i % 2 == 0) {
            actual_hash_bytes[i / 2] = byte << 4;
        } else {
            actual_hash_bytes[i / 2] |= byte;
        }

        i += 1;
    }

    return std.mem.eql(u8, computed_hash[0..], actual_hash_bytes[0..]);
}

test "verify_hash basic test" {
    const sample_hash: [32]u8 = [_]u8{ 0x33, 0x9a, 0x89, 0xdc, 0x08, 0x73, 0x6b, 0x84, 0xc4, 0x75, 0x2b, 0x3d, 0xed, 0xdc, 0x0f, 0x2c, 0x71, 0xb5, 0x0b, 0x66, 0xa2, 0x68, 0x5f, 0x26, 0x77, 0x9c, 0xbb, 0xac, 0x46, 0x11, 0x1b, 0x68 };

    var sample_hash_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&sample_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(sample_hash[0..])}) catch unreachable;

    try testing.expect(verify_hash(sample_hash, &sample_hash_hex));
    try testing.expect(!verify_hash(sample_hash, "incorrect_hash"));
}
