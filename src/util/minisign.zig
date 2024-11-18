const std = @import("std");
const base64 = std.base64;
const crypto = std.crypto;
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const Endian = std.builtin.Endian;
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

    pub fn get_algorithm(self: Signature) !Algorithm {
        const signature_algorithm = self.signature_algorithm;
        const prehashed = if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x64) false else if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x44) true else return error.UnsupportedAlgorithm;
        return if (prehashed) .Prehash else .Legacy;
    }

    pub fn decode(_: *std.mem.Allocator, lines: []const u8) !Signature {
        var tokenizer = mem.tokenizeScalar(u8, lines, '\n');

        // Decode first line: signature_algorithm + key_id + signature
        const sig_line = tokenizer.next() orelse return Error.invalid_encoding;
        var sig_bin: [74]u8 = undefined;
        try base64.standard.Decoder.decode(&sig_bin, sig_line);

        // Decode trusted comment
        const trusted_comment_prefix = "trusted comment: ";
        const comment_line = tokenizer.next() orelse return Error.invalid_encoding;
        if (!mem.startsWith(u8, comment_line, trusted_comment_prefix)) {
            return error.invalid_encoding;
        }
        const trusted_comment = comment_line[trusted_comment_prefix.len..];

        // Decode global signature
        const global_sig_line = tokenizer.next() orelse return Error.invalid_encoding;
        var global_sig_bin: [64]u8 = undefined;
        try base64.standard.Decoder.decode(&global_sig_bin, global_sig_line);

        return Signature{
            .signature_algorithm = sig_bin[0..2].*,
            .key_id = sig_bin[2..10].*,
            .signature = sig_bin[10..74].*,
            .trusted_comment = trusted_comment,
            .global_signature = global_sig_bin,
        };
    }

    pub fn from_file(allocator: *std.mem.Allocator, path: []const u8) !Signature {
        const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const sig_str = try file.readToEndAlloc(allocator.*, 4096);
        defer allocator.free(sig_str);

        return decode(allocator, sig_str);
    }
};

// PublicKey Structure
pub const PublicKey = struct {
    signature_algorithm: [2]u8 = "Ed".*,
    key_id: [8]u8,
    key: [32]u8,

    pub fn decode(str: []const u8) !PublicKey {
        if (str.len != 44) { // Base64 for 32-byte key
            return error.public_key_format_error;
        }

        var bin: [42]u8 = undefined;
        try base64.standard.Decoder.decode(&bin, str);
        const signature_algorithm = bin[0..2];
        if (bin[0] != 0x45 or (bin[1] != 0x64 and bin[1] != 0x44)) {
            return error.unsupported_algorithm;
        }

        return PublicKey{
            .signature_algorithm = signature_algorithm.*,
            .key_id = bin[2..10].*,
            .key = bin[10..42].*,
        };
    }

    pub fn from_file(allocator: *std.mem.Allocator, path: []const u8) !PublicKey {
        const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const pk_str = try file.readToEndAlloc(allocator.*, 4096);
        defer allocator.free(pk_str);

        const trimmed_pk = mem.trim(u8, pk_str, " \t\r\n");
        return decode(trimmed_pk);
    }
};

// Verifier Structure
pub const Verifier = struct {
    public_key: PublicKey,
    signature: Signature,
    hasher: union(Algorithm) {
        Prehash: Blake2b512,
        Legacy: Ed25519.Verifier,
    },

    pub fn init(public_key: PublicKey, signature: Signature) !Verifier {
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

    pub fn finalize(self: *Verifier) !void {
        const public_key = try Ed25519.PublicKey.fromBytes(self.public_key.key);
        switch (self.hasher) {
            .Prehash => |*prehash| {
                var digest: [64]u8 = undefined;
                prehash.final(&digest);
                try Ed25519.Signature.fromBytes(self.signature.signature).verify(&digest, public_key);
            },
            .Legacy => |*legacy| {
                try legacy.verify();
            },
        }

        // Verify Global Signature
        var global_data: [128]u8 = undefined;
        mem.copyForwards(u8, global_data[0..64], &self.signature.signature);
        mem.copyForwards(u8, global_data[64..128], self.signature.trusted_comment);
        try Ed25519.Signature.fromBytes(self.signature.global_signature).verify(&global_data, public_key);
    }
};

// Verification Function
pub fn verify(
    allocator: *std.mem.Allocator,
    signature_path: []const u8,
    public_key_path: []const u8,
    file_path: []const u8,
) !void {
    // Load Signature
    const signature = try Signature.from_file(allocator, signature_path);
    defer allocator.free(signature.trusted_comment);

    // Load Public Key
    const public_key = try PublicKey.from_file(allocator, public_key_path);

    // Initialize Verifier
    var verifier = try Verifier.init(public_key, signature);

    // Open File to Verify
    const file = try fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file.close();

    // Read and Update Verifier with File Data
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        verifier.update(buffer[0..bytes_read]);
    }

    // Finalize Verification
    try verifier.finalize();
}
