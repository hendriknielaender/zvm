const std = @import("std");
const assert = std.debug.assert;

const name_length_max = 64;

comptime {
    assert(name_length_max >= 32);
    assert(name_length_max <= 128);
}

pub fn threshold(name: []const u8) u8 {
    assert(name.len > 0);
    assert(name.len <= name_length_max);

    if (name.len <= 4) return 2;
    return 3;
}

pub fn distance_with_max(source: []const u8, target: []const u8, distance_max: u8) ?u8 {
    assert(source.len > 0);
    assert(target.len > 0);
    assert(target.len <= name_length_max);
    assert(distance_max <= 3);

    if (source.len > target.len + distance_max) return null;
    if (target.len > source.len + distance_max) return null;

    var previous: [name_length_max + 1]u16 = undefined;
    var current: [name_length_max + 1]u16 = undefined;

    var column: usize = 0;
    while (column <= target.len) : (column += 1) {
        previous[column] = @intCast(column);
    }

    for (source, 0..) |source_byte, source_index| {
        current[0] = @intCast(@min(source_index + 1, name_length_max + 1));
        var row_min = current[0];

        column = 1;
        while (column <= target.len) : (column += 1) {
            const cost: u16 = if (source_byte == target[column - 1]) 0 else 1;
            const deletion = previous[column] + 1;
            const insertion = current[column - 1] + 1;
            const substitution = previous[column - 1] + cost;
            current[column] = @min(@min(deletion, insertion), substitution);
            row_min = @min(row_min, current[column]);
        }

        if (row_min > distance_max) return null;
        @memcpy(previous[0 .. target.len + 1], current[0 .. target.len + 1]);
    }

    if (previous[target.len] <= distance_max) return @intCast(previous[target.len]);
    return null;
}

pub fn nearest(source: []const u8, candidates: []const []const u8) ?[]const u8 {
    assert(source.len > 0);
    assert(candidates.len > 0);

    var best_candidate: ?[]const u8 = null;
    var best_distance: u8 = 255;

    for (candidates) |candidate| {
        assert(candidate.len > 0);
        assert(candidate.len <= name_length_max);

        const distance_max = threshold(candidate);
        const distance = distance_with_max(source, candidate, distance_max) orelse continue;
        if (distance < best_distance) {
            best_candidate = candidate;
            best_distance = distance;
        }
    }

    return best_candidate;
}

test "edit distance finds short typo within threshold" {
    const testing = std.testing;

    try testing.expectEqual(@as(?u8, 0), distance_with_max("rm", "rm", 2));
    try testing.expectEqual(@as(?u8, 1), distance_with_max("jsom", "json", 2));
    try testing.expectEqual(@as(?u8, 1), distance_with_max("--jsom", "--json", 3));
    try testing.expectEqual(@as(?u8, 1), distance_with_max("installl", "install", 3));
    try testing.expectEqual(@as(?u8, null), distance_with_max("zzz", "install", 3));
}
