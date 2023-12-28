const std = @import("std");
const crypto = @import("std").crypto;
const testing = std.testing;
const mem = std.mem;

pub fn verifyHash(computedHash: [32]u8, actualHashString: []const u8) bool {
    if (actualHashString.len != 64) return false; // SHA256 hash should be 64 hex characters

    var actualHashBytes: [32]u8 = undefined;
    var i: usize = 0;

    for (actualHashString) |char| {
        const byte = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return false, // Invalid character in hash string
        };

        if (i % 2 == 0) {
            actualHashBytes[i / 2] = byte << 4;
        } else {
            actualHashBytes[i / 2] |= byte;
        }

        i += 1;
    }

    return std.mem.eql(u8, computedHash[0..], actualHashBytes[0..]);
}

test "verifyHash basic test" {
    const sample_hash: [32]u8 = [_]u8{ 0x33, 0x9a, 0x89, 0xdc, 0x08, 0x73, 0x6b, 0x84, 0xc4, 0x75, 0x2b, 0x3d, 0xed, 0xdc, 0x0f, 0x2c, 0x71, 0xb5, 0x0b, 0x66, 0xa2, 0x68, 0x5f, 0x26, 0x77, 0x9c, 0xbb, 0xac, 0x46, 0x11, 0x1b, 0x68 };

    var sample_hash_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&sample_hash_hex, "{}", .{std.fmt.fmtSliceHexLower(sample_hash[0..])}) catch unreachable;

    try testing.expect(verifyHash(sample_hash, &sample_hash_hex));
    try testing.expect(!verifyHash(sample_hash, "incorrect_hash"));
}
