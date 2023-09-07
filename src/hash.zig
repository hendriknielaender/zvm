const std = @import("std");
const crypto = @import("std").crypto;

pub fn computeSHA256(buffer: []const u8) [32]u8 {
    var sha256 = crypto.hash.sha2.Sha256.init(.{});
    sha256.update(buffer);
    var hash_result: [32]u8 = undefined;
    sha256.final(&hash_result);
    return hash_result;
}

pub fn verifyHash(computedHash: [32]u8, expectedHash: []const u8) bool {
    return std.mem.eql(u8, &computedHash, expectedHash);
}
