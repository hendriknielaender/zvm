const std = @import("std");
const crypto = @import("std").crypto;
const testing = std.testing;
const mem = std.mem;

pub fn computeSHA256(buffer: []const u8) [32]u8 {
    var sha256 = crypto.hash.sha2.Sha256.init(.{});
    sha256.update(buffer);
    var hash_result: [32]u8 = undefined;
    sha256.final(&hash_result);
    return hash_result;
}

pub fn verifyHash(computedHash: [32]u8, expectedHash: []const u8) bool {
    return mem.eql(u8, &computedHash, expectedHash);
}

test "computeSHA256 basic test" {
    const sample_data = "Hello, Zig!";
    const expected_hash_str = "2fb0af70aa67adcc5dc7a41a9e2c1edd34e9de0cf61dddfb4d931477ef99e08e";

    var expected_hash: [expected_hash_str.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(expected_hash[0..], expected_hash_str);

    const computed_hash = computeSHA256(sample_data);

    //std.debug.print("Computed: {s}\n", .{std.fmt.fmtSliceHexLower(computed_hash[0..])});
    //std.debug.print("Expected: {s}\n", .{expected_hash_str});

    try testing.expect(mem.eql(u8, &computed_hash, expected_hash[0..]));
}

test "verifyHash basic test" {
    const sample_hash_first: [16]u8 = [_]u8{ 0x33, 0x9a, 0x89, 0xdc, 0x08, 0x73, 0x6b, 0x84, 0xc4, 0x75, 0x2b, 0x3d, 0xed, 0xdc, 0x0f, 0x2c };
    const sample_hash_second: [16]u8 = [_]u8{ 0x71, 0xb5, 0x0b, 0x66, 0xa2, 0x68, 0x5f, 0x26, 0x77, 0x9c, 0xbb, 0xac, 0x46, 0x11, 0x1b, 0x68 };
    const sample_hash: [32]u8 = sample_hash_first ++ sample_hash_second;

    try testing.expect(verifyHash(sample_hash, &sample_hash));
    try testing.expect(!verifyHash(sample_hash, "incorrect_hash"));
}

test "computeSHA256 with empty data" {
    const empty_data = "";
    const expected_hash_first: [16]u8 = [_]u8{ 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24 };
    const expected_hash_second: [16]u8 = [_]u8{ 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55 };
    const expected_hash: [32]u8 = expected_hash_first ++ expected_hash_second;

    const computed_hash = computeSHA256(empty_data);
    try testing.expect(mem.eql(u8, &computed_hash, &expected_hash));
}
