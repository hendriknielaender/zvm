const std = @import("std");
const base64 = std.base64;
const crypto = std.crypto;
const mem = std.mem;
const context = @import("../Context.zig");
const limits = @import("../memory/limits.zig");

const Ed25519 = crypto.sign.Ed25519;
const Blake2b512 = crypto.hash.blake2.Blake2b512;

// Error Definitions
const Error = error{
    invalid_encoding,
    unsupported_algorithm,
    key_id_mismatch,
    signature_verification_failed,
    file_read_error,
    public_key_format_error,
};

// Algorithm Enumeration
pub const Algorithm = enum {
    Prehash,
    Legacy,
};

// Signature Structure
pub const Signature = struct {
    signature_algorithm: [2]u8,
    key_id: [8]u8,
    signature: [64]u8,
    trusted_comment: []const u8,
    global_signature: [64]u8,
    // Storage for trusted comment in static allocation.
    trusted_comment_buffer: [limits.trusted_comment_length_maximum]u8 = [_]u8{0} ** limits.trusted_comment_length_maximum,
    trusted_comment_len: usize = 0,

    pub fn deinit(self: *Signature) void {
        _ = self;
    }

    pub fn fix_trusted_comment_slice(self: *Signature) void {
        self.trusted_comment = self.trusted_comment_buffer[0..self.trusted_comment_len];
    }

    pub fn get_algorithm(self: Signature) !Algorithm {
        const signature_algorithm = self.signature_algorithm;
        const prehashed = if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x64) false else if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x44) true else return error.UnsupportedAlgorithm;
        return if (prehashed) .Prehash else .Legacy;
    }

    pub fn trusted_comment_file_name(self: *const Signature) ?[]const u8 {
        const needle = "file:";
        var search_start: usize = 0;
        while (mem.indexOfPos(u8, self.trusted_comment, search_start, needle)) |pos| {
            const boundary_before = pos == 0 or std.ascii.isWhitespace(self.trusted_comment[pos - 1]);
            if (!boundary_before) {
                search_start = pos + 1;
                continue;
            }

            const value_start = pos + needle.len;
            if (value_start >= self.trusted_comment.len) return null;

            var value_end = value_start;
            while (value_end < self.trusted_comment.len and
                !std.ascii.isWhitespace(self.trusted_comment[value_end]))
            {
                value_end += 1;
            }
            if (value_end == value_start) return null;
            return self.trusted_comment[value_start..value_end];
        }
        return null;
    }

    pub fn decode(lines: []const u8) !Signature {
        var tokenizer = mem.tokenizeScalar(u8, lines, '\n');

        // SAFETY: line is immediately assigned in the loop before use
        var line: []const u8 = undefined;
        while (true) {
            line = tokenizer.next() orelse {
                return Error.invalid_encoding;
            };
            const trimmed_line = mem.trim(u8, line, " \t\r\n");

            if (!mem.startsWith(u8, trimmed_line, "untrusted comment:")) {
                break;
            }
        }

        const sig_line_trimmed = mem.trim(u8, line, " \t\r\n");

        var sig_bin: [74]u8 = undefined;
        try base64.standard.Decoder.decode(&sig_bin, sig_line_trimmed);

        const comment_line = tokenizer.next() orelse {
            return Error.invalid_encoding;
        };
        const comment_line_trimmed = mem.trim(u8, comment_line, " \t\r\n");

        const trusted_comment_prefix = "trusted comment: ";
        if (!mem.startsWith(u8, comment_line_trimmed, trusted_comment_prefix)) {
            return Error.invalid_encoding;
        }
        const trusted_comment_slice = comment_line_trimmed[trusted_comment_prefix.len..];
        if (trusted_comment_slice.len > limits.trusted_comment_length_maximum) {
            return error.TrustedCommentTooLong;
        }

        const global_sig_line = tokenizer.next() orelse {
            return Error.invalid_encoding;
        };
        const global_sig_line_trimmed = mem.trim(u8, global_sig_line, " \t\r\n");

        var global_sig_bin: [64]u8 = undefined;
        try base64.standard.Decoder.decode(&global_sig_bin, global_sig_line_trimmed);

        var sig = Signature{
            .signature_algorithm = sig_bin[0..2].*,
            .key_id = sig_bin[2..10].*,
            .signature = sig_bin[10..74].*,
            // SAFETY: trusted_comment will be set immediately after struct creation
            .trusted_comment = undefined,
            .global_signature = global_sig_bin,
        };

        @memcpy(sig.trusted_comment_buffer[0..trusted_comment_slice.len], trusted_comment_slice);
        sig.trusted_comment_len = trusted_comment_slice.len;
        sig.trusted_comment = sig.trusted_comment_buffer[0..sig.trusted_comment_len];

        return sig;
    }

    pub fn from_file_static(io: std.Io, buffer: []u8, path: []const u8) !Signature {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
        var file_reader = file.reader(io, &reader_buffer);
        const bytes_read = file_reader.interface.readSliceShort(buffer) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (bytes_read >= buffer.len) {
            return error.SignatureFileTooLarge;
        }

        const sig_str = buffer[0..bytes_read];
        return try decode(sig_str);
    }
};

// PublicKey Structure
pub const PublicKey = struct {
    signature_algorithm: [2]u8 = "Ed".*,
    key_id: [8]u8,
    key: [32]u8,

    pub fn decode(str: []const u8) !PublicKey {
        const trimmed_str = std.mem.trim(u8, str, " \t\r\n");

        if (trimmed_str.len != 56) { // Base64 for 42-byte key
            return Error.public_key_format_error;
        }

        var bin: [42]u8 = undefined;
        try base64.standard.Decoder.decode(&bin, trimmed_str);

        const signature_algorithm = bin[0..2];

        if (bin[0] != 0x45 or (bin[1] != 0x64 and bin[1] != 0x44)) {
            return Error.unsupported_algorithm;
        }

        const key_id = bin[2..10];
        const public_key = bin[10..42];

        return PublicKey{
            .signature_algorithm = signature_algorithm.*,
            .key_id = key_id.*,
            .key = public_key.*,
        };
    }
};

// Verifier Structure
pub const Verifier = struct {
    public_key: PublicKey,
    signature: *const Signature,
    hasher: union(Algorithm) {
        Prehash: Blake2b512,
        Legacy: Ed25519.Verifier,
    },

    pub fn init(public_key: PublicKey, signature: *const Signature) !Verifier {
        if (!mem.eql(u8, &public_key.key_id, &signature.key_id)) {
            return Error.key_id_mismatch;
        }

        const algorithm = try signature.get_algorithm();
        const ed25519_pk = try Ed25519.PublicKey.fromBytes(public_key.key);
        return Verifier{
            .public_key = public_key,
            .signature = signature,
            .hasher = switch (algorithm) {
                .Prehash => .{ .Prehash = Blake2b512.init(.{}) },
                .Legacy => .{ .Legacy = try Ed25519.Signature.fromBytes(signature.signature).verifier(ed25519_pk) },
            },
        };
    }

    pub fn update(self: *Verifier, data: []const u8) void {
        switch (self.hasher) {
            .Prehash => |*prehash| prehash.update(data),
            .Legacy => |*legacy| legacy.update(data),
        }
    }

    pub fn finalize_static(self: *Verifier, global_data_buffer: []u8) !void {
        const public_key = try Ed25519.PublicKey.fromBytes(self.public_key.key);
        switch (self.hasher) {
            .Prehash => |*prehash| {
                var digest: [64]u8 = undefined;
                prehash.final(&digest);
                try Ed25519.Signature.fromBytes(self.signature.signature).verify(digest[0..], public_key);
            },
            .Legacy => |*legacy| {
                try legacy.verify();
            },
        }

        const global_data = try self.build_global_signature_data_static(global_data_buffer);

        try Ed25519.Signature.fromBytes(self.signature.global_signature).verify(global_data, public_key);
    }

    fn build_global_signature_data_static(self: *Verifier, buffer: []u8) ![]const u8 {
        const signature_len = self.signature.signature.len;
        const trusted_comment_len = self.signature.trusted_comment.len;
        const total_len = signature_len + trusted_comment_len;

        if (total_len > buffer.len) {
            return error.GlobalSignatureDataTooLarge;
        }

        std.mem.copyForwards(u8, buffer[0..signature_len], self.signature.signature[0..]);
        std.mem.copyForwards(u8, buffer[signature_len..total_len], self.signature.trusted_comment[0..]);

        return buffer[0..total_len];
    }
};

// Verification Function using static allocation.
pub fn verify_static(
    ctx: *context.CliContext,
    signature_path: []const u8,
    public_key_str: []const u8,
    file_path: []const u8,
) !void {
    return verify_static_with_file(ctx, signature_path, public_key_str, file_path, null);
}

pub fn verify_static_with_file(
    ctx: *context.CliContext,
    signature_path: []const u8,
    public_key_str: []const u8,
    file_path: []const u8,
    expected_file_name: ?[]const u8,
) !void {
    var sig_buffer: [limits.signature_buffer_size]u8 = undefined;

    var signature = try Signature.from_file_static(ctx.io, &sig_buffer, signature_path);
    defer signature.deinit();

    signature.fix_trusted_comment_slice();

    const public_key = try PublicKey.decode(public_key_str);

    var verifier = try Verifier.init(public_key, &signature);

    const file = try std.Io.Dir.openFileAbsolute(ctx.io, file_path, .{ .mode = .read_only });
    defer file.close(ctx.io);

    var buffer: [limits.signature_buffer_size]u8 = undefined;
    var reader_buffer: [limits.io_buffer_size_maximum]u8 = undefined;
    var file_reader = file.reader(ctx.io, &reader_buffer);
    while (true) {
        const bytes_read = file_reader.interface.readSliceShort(&buffer) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (bytes_read == 0) break;
        verifier.update(buffer[0..bytes_read]);
    }

    var global_data_buffer: [limits.text_buffer_size]u8 = undefined;
    try verifier.finalize_static(&global_data_buffer);

    if (expected_file_name) |expected| {
        const actual = signature.trusted_comment_file_name() orelse
            return error.TrustedCommentMissingFile;
        if (!mem.eql(u8, actual, expected)) return error.TrustedCommentFileMismatch;
    }
}

test "trusted comment file field is parsed as one token" {
    var signature = Signature{
        .signature_algorithm = "Ed".*,
        .key_id = [_]u8{0} ** 8,
        .signature = [_]u8{0} ** 64,
        .trusted_comment = undefined,
        .global_signature = [_]u8{0} ** 64,
    };

    const comment = "timestamp:1710958613 file:zig-x86_64-linux-0.16.0.tar.xz hashed";
    @memcpy(signature.trusted_comment_buffer[0..comment.len], comment);
    signature.trusted_comment_len = comment.len;
    signature.fix_trusted_comment_slice();

    try std.testing.expectEqualStrings(
        "zig-x86_64-linux-0.16.0.tar.xz",
        signature.trusted_comment_file_name().?,
    );
}

test "trusted comment file field requires token boundary" {
    var signature = Signature{
        .signature_algorithm = "Ed".*,
        .key_id = [_]u8{0} ** 8,
        .signature = [_]u8{0} ** 64,
        .trusted_comment = undefined,
        .global_signature = [_]u8{0} ** 64,
    };

    const comment = "timestamp:1710958613 profile:ignored";
    @memcpy(signature.trusted_comment_buffer[0..comment.len], comment);
    signature.trusted_comment_len = comment.len;
    signature.fix_trusted_comment_slice();

    try std.testing.expect(signature.trusted_comment_file_name() == null);
}

test "verifier rejects mismatched key id before signature work" {
    const public_key = PublicKey{
        .key_id = [_]u8{0} ** 8,
        .key = [_]u8{0} ** 32,
    };
    var signature = Signature{
        .signature_algorithm = "Ed".*,
        .key_id = [_]u8{1} ** 8,
        .signature = [_]u8{0} ** 64,
        .trusted_comment = &.{},
        .global_signature = [_]u8{0} ** 64,
    };

    try std.testing.expectError(
        Error.key_id_mismatch,
        Verifier.init(public_key, &signature),
    );
}
