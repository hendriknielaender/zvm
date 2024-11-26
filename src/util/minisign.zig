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
const debug = std.debug;

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

    pub fn deinit(self: *Signature, allocator: *std.mem.Allocator) void {
        allocator.free(self.trusted_comment);
    }

    pub fn get_algorithm(self: Signature) !Algorithm {
        const signature_algorithm = self.signature_algorithm;
        const prehashed = if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x64) false else if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x44) true else return error.UnsupportedAlgorithm;
        return if (prehashed) .Prehash else .Legacy;
    }

    pub fn decode(allocator: *std.mem.Allocator, lines: []const u8) !Signature {
        var tokenizer = mem.tokenizeScalar(u8, lines, '\n');

        // Skip untrusted comment lines
        var line: []const u8 = undefined;
        while (true) {
            line = tokenizer.next() orelse {
                debug.print("No more lines to read. Invalid encoding.\n", .{});
                return Error.invalid_encoding;
            };
            const trimmed_line = mem.trim(u8, line, " \t\r\n");
            debug.print("Read line: '{s}'\n", .{trimmed_line});

            if (!mem.startsWith(u8, trimmed_line, "untrusted comment:")) {
                break;
            }
            debug.print("Skipping untrusted comment line.\n", .{});
            // Optionally, store or process the untrusted comment if needed
        }

        // Now 'line' should be the Base64 encoded signature
        const sig_line_trimmed = mem.trim(u8, line, " \t\r\n");
        debug.print("Signature line (trimmed): '{s}'\n", .{sig_line_trimmed});
        debug.print("Signature line length: {d}\n", .{sig_line_trimmed.len});

        var sig_bin: [74]u8 = undefined;
        try base64.standard.Decoder.decode(&sig_bin, sig_line_trimmed);

        debug.print("Signature binary length: {d}\n", .{sig_bin.len});

        // Decode trusted comment
        const comment_line = tokenizer.next() orelse {
            debug.print("Expected trusted comment line but none found.\n", .{});
            return Error.invalid_encoding;
        };
        const comment_line_trimmed = mem.trim(u8, comment_line, " \t\r\n");
        debug.print("Trusted comment line (trimmed): '{s}'\n", .{comment_line_trimmed});

        const trusted_comment_prefix = "trusted comment: ";
        if (!mem.startsWith(u8, comment_line_trimmed, trusted_comment_prefix)) {
            debug.print("Trusted comment line does not start with the expected prefix.\n", .{});
            return Error.invalid_encoding;
        }
        const trusted_comment_slice = comment_line_trimmed[trusted_comment_prefix.len..];
        // Allocate a copy of the trusted_comment
        const trusted_comment = try allocator.alloc(u8, trusted_comment_slice.len);
        mem.copyForwards(u8, trusted_comment, trusted_comment_slice);

        debug.print("Trusted comment: '{s}'\n", .{trusted_comment});

        // Decode global signature
        const global_sig_line = tokenizer.next() orelse {
            debug.print("Expected global signature line but none found.\n", .{});
            return Error.invalid_encoding;
        };
        const global_sig_line_trimmed = mem.trim(u8, global_sig_line, " \t\r\n");
        debug.print("Global signature line (trimmed): '{s}'\n", .{global_sig_line_trimmed});
        debug.print("Global signature line length: {d}\n", .{global_sig_line_trimmed.len});

        var global_sig_bin: [64]u8 = undefined;
        try base64.standard.Decoder.decode(&global_sig_bin, global_sig_line_trimmed);

        debug.print("Global signature binary length: {d}\n", .{global_sig_bin.len});

        return Signature{
            .signature_algorithm = sig_bin[0..2].*,
            .key_id = sig_bin[2..10].*,
            .signature = sig_bin[10..74].*,
            .trusted_comment = trusted_comment,
            .global_signature = global_sig_bin,
        };
    }

    pub fn from_file(allocator: *std.mem.Allocator, path: []const u8) !Signature {
        debug.print("Loading signature from file: {s}\n", .{path});
        const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        const sig_str = try file.readToEndAlloc(allocator.*, 4096);
        // Do not free sig_str here since we're slicing into it in decode
        // defer allocator.free(sig_str); // Remove this line

        debug.print("Signature file content:\n{s}\n", .{sig_str});

        const signature = try decode(allocator, sig_str);
        // Now that we've copied the necessary data, we can free sig_str
        allocator.free(sig_str);

        return signature;
    }
};

// PublicKey Structure
pub const PublicKey = struct {
    signature_algorithm: [2]u8 = "Ed".*,
    key_id: [8]u8,
    key: [32]u8,

    pub fn decode(str: []const u8) !PublicKey {
        const trimmed_str = std.mem.trim(u8, str, " \t\r\n");
        std.debug.print("Public key string (trimmed): '{s}'\n", .{trimmed_str});
        std.debug.print("Public key string length: {d}\n", .{trimmed_str.len});

        if (trimmed_str.len != 56) { // Base64 for 42-byte key
            std.debug.print("Error: Public key string length is {d}, expected 56.\n", .{trimmed_str.len});
            return Error.public_key_format_error;
        }

        var bin: [42]u8 = undefined;
        try base64.standard.Decoder.decode(&bin, trimmed_str);
        std.debug.print("Decoded public key binary length: {d}\n", .{bin.len});

        const signature_algorithm = bin[0..2];
        std.debug.print("Signature algorithm bytes: {x}\n", .{signature_algorithm});

        if (bin[0] != 0x45 or (bin[1] != 0x64 and bin[1] != 0x44)) {
            std.debug.print("Unsupported signature algorithm: {x}\n", .{signature_algorithm});
            return Error.unsupported_algorithm;
        }

        const key_id = bin[2..10];
        std.debug.print("Key ID: {x}\n", .{key_id});

        const public_key = bin[10..42];
        std.debug.print("Public key bytes: {x}\n", .{public_key});

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

    pub fn finalize(self: *Verifier, allocator: *std.mem.Allocator) !void {
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

        // Verify Global Signature
        const global_data = try self.build_global_signature_data(allocator);
        defer allocator.free(global_data);

        try Ed25519.Signature.fromBytes(self.signature.global_signature).verify(global_data, public_key);
    }

    fn build_global_signature_data(self: *Verifier, allocator: *std.mem.Allocator) ![]const u8 {
        const signature_len = self.signature.signature.len;
        const trusted_comment_len = self.signature.trusted_comment.len;

        var global_data = try allocator.alloc(u8, signature_len + trusted_comment_len);

        std.mem.copyForwards(u8, global_data[0..signature_len], self.signature.signature[0..]);
        std.mem.copyForwards(u8, global_data[signature_len..], self.signature.trusted_comment[0..]);

        return global_data[0 .. signature_len + trusted_comment_len];
    }
};

// Verification Function
pub fn verify(
    allocator: *std.mem.Allocator,
    signature_path: []const u8,
    public_key_str: []const u8,
    file_path: []const u8,
) !void {
    debug.print("Starting verification process.\n", .{});
    debug.print("Signature path: {s}\n", .{signature_path});
    debug.print("Public key string: {s}\n", .{public_key_str});
    debug.print("File path: {s}\n", .{file_path});

    // Load Signature
    var signature = try Signature.from_file(allocator, signature_path);
    defer signature.deinit(allocator); // Ensure we free the allocated memory
    debug.print("Loaded signature successfully.\n", .{});

    // Load Public Key from String
    const public_key = try PublicKey.decode(public_key_str);
    debug.print("Loaded public key successfully.\n", .{});

    // Initialize Verifier
    debug.print("Initializing verifier.\n", .{});
    var verifier = try Verifier.init(public_key, signature);

    // Open File to Verify
    debug.print("Opening file to verify: {s}\n", .{file_path});
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
    debug.print("Finalizing verification.\n", .{});
    try verifier.finalize(allocator);
    debug.print("Verification succeeded.\n", .{});
}
