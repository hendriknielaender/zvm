const std = @import("std");
const limits = @import("../../memory/limits.zig");
const assert = std.debug.assert;

const Token = std.json.Token;
const TokenType = std.json.TokenType;

const scanner_depth_max: usize = 16;
const scanner_stack_buffer_size: usize = 256;
const scanner_token_buffer_size: usize = limits.limits.url_length_maximum;

pub const TokenScanner = struct {
    scanner: std.json.Scanner,
    scanner_fba: std.heap.FixedBufferAllocator,
    token_fba: std.heap.FixedBufferAllocator,
    scanner_stack_buffer: [scanner_stack_buffer_size]u8,
    token_buffer: [scanner_token_buffer_size]u8,

    pub fn init(target: *TokenScanner, raw: []const u8) !void {
        assert(raw.len > 0);

        target.scanner_fba = std.heap.FixedBufferAllocator.init(&target.scanner_stack_buffer);
        target.token_fba = std.heap.FixedBufferAllocator.init(&target.token_buffer);
        target.scanner = std.json.Scanner.initCompleteInput(target.scanner_fba.allocator(), raw);
        try target.scanner.ensureTotalStackCapacity(scanner_depth_max);
    }

    pub fn deinit(self: *TokenScanner) void {
        self.scanner.deinit();
    }

    pub fn peek_token_type(self: *TokenScanner) !TokenType {
        return try self.scanner.peekNextTokenType();
    }

    pub fn expect_object_begin(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .object_begin => return,
            else => return error.UnexpectedToken,
        }
    }

    pub fn expect_object_end(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .object_end => return,
            else => return error.UnexpectedToken,
        }
    }

    pub fn expect_array_begin(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .array_begin => return,
            else => return error.UnexpectedToken,
        }
    }

    pub fn expect_array_end(self: *TokenScanner) !void {
        switch (try self.next_token()) {
            .array_end => return,
            else => return error.UnexpectedToken,
        }
    }

    pub fn next_string(self: *TokenScanner, buffer: []u8) ![]const u8 {
        switch (try self.next_token()) {
            .string => |value| return try copy_into_buffer(buffer, value),
            .allocated_string => |value| return try copy_into_buffer(buffer, value),
            else => return error.UnexpectedToken,
        }
    }

    pub fn next_u64(self: *TokenScanner) !u64 {
        switch (try self.next_token()) {
            .number => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .allocated_number => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .string => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            .allocated_string => |value| return try std.fmt.parseUnsigned(u64, value, 10),
            else => return error.UnexpectedToken,
        }
    }

    fn next_token(self: *TokenScanner) !Token {
        self.token_fba.reset();
        return try self.scanner.nextAllocMax(
            self.token_fba.allocator(),
            .alloc_if_needed,
            scanner_token_buffer_size,
        );
    }

    pub fn skip_value(self: *TokenScanner) !void {
        return try self.scanner.skipValue();
    }
};

pub fn skip_remaining_array(scanner: *TokenScanner) !void {
    while (true) {
        switch (try scanner.peek_token_type()) {
            .array_end => {
                try scanner.expect_array_end();
                return;
            },
            else => try scanner.skip_value(),
        }
    }
}

pub fn copy_into_buffer(target: []u8, source: []const u8) ![]const u8 {
    assert(target.len > 0);
    if (source.len > target.len) return error.BufferTooSmall;
    @memcpy(target[0..source.len], source);
    return target[0..source.len];
}
