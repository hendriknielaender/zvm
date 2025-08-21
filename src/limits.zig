const std = @import("std");

/// Static compile-time limits for the entire application.
/// These define the maximum capacity for every resource in the system.
/// All limits are compile-time constants to enable true static allocation.
pub const limits = struct {
    /// Maximum number of command line arguments.
    pub const arguments_maximum: u32 = 32;

    /// Maximum total size of all argument strings combined.
    pub const arguments_storage_size_maximum: u32 = 8192; // 8KB total for all args.

    /// Maximum number of concurrent HTTP operations.
    pub const http_operations_maximum: u32 = 2; // ZVM rarely needs concurrent downloads.

    /// Maximum size of a single HTTP response.
    pub const http_response_size_maximum: u32 = 1024 * 1024; // 1MB - matches JSON parse size

    /// Maximum size for HTTP client internal buffers (headers, TLS, etc).
    pub const http_internal_buffer_maximum: u32 = 256 * 1024; // 256KB for HTTP internals.

    /// Maximum number of HTTP headers.
    pub const http_headers_maximum: u32 = 64;

    /// Maximum size of a single HTTP header.
    pub const http_header_size_maximum: u32 = 4096;

    /// Maximum number of certificates in the system bundle.
    /// macOS has ~170 certificates, we allocate for 256 to be safe.
    pub const certificates_maximum: u32 = 256;

    /// Maximum size of a single certificate (most are 1-2KB).
    pub const certificate_size_maximum: u32 = 4096;

    /// Maximum size for certificate bundle operations.
    /// This covers parsing the keychain and temporary buffers.
    pub const certificate_bundle_buffer_maximum: u32 = 512 * 1024;

    /// Maximum number of versions that can be listed.
    pub const versions_maximum: u32 = 256; // More than enough for available versions.

    /// Maximum length of a file path.
    pub const path_length_maximum: u32 = 512; // Reasonable path length.

    /// Maximum number of path buffers.
    pub const path_buffers_maximum: u32 = 8; // For concurrent path operations.

    /// Maximum size of JSON to parse.
    /// GitHub API responses for releases can be 150KB+ when decompressed
    pub const json_parse_size_maximum: u32 = 1024 * 1024; // 1MB - enough for GitHub API responses

    /// Maximum number of extract operations.
    pub const extract_operations_maximum: u32 = 8;

    /// Maximum size of extract buffer.
    pub const extract_buffer_size_maximum: u32 = 64 * 1024; // 64KB.

    /// Maximum process output buffer.
    pub const process_output_size_maximum: u32 = 4096;

    /// Maximum URL length.
    pub const url_length_maximum: u32 = 2048;

    /// Maximum version string length.
    pub const version_string_length_maximum: u32 = 64;

    /// Maximum home directory path length.
    pub const home_dir_length_maximum: u32 = 256;

    /// Maximum number of directory entries we can process.
    pub const dir_entries_maximum: u32 = 1024;

    /// Maximum size for temporary string formatting.
    pub const format_buffer_size_maximum: u32 = 4096;

    /// Maximum size for file operations buffer.
    pub const file_buffer_size_maximum: u32 = 64 * 1024; // 64KB.

    /// Maximum shell type string length.
    pub const shell_type_length_maximum: u32 = 32;

    /// Maximum environment variable value length.
    pub const env_var_length_maximum: u32 = 512;

    /// Maximum length for minisign trusted comments.
    pub const trusted_comment_length_maximum: u32 = 256;

    /// Maximum size for JSON responses.
    pub const json_response_size_maximum: u32 = 512 * 1024;

    /// Maximum size for stdout/stderr I/O buffers.
    pub const io_buffer_size_maximum: u32 = 4096;

    /// Transfer buffer size for HTTP operations (chunked encoding, etc.)
    pub const http_transfer_buffer_size: u32 = 64;

    /// Write buffer size for file operations
    pub const file_write_buffer_size: u32 = 8192;

    /// Read buffer size for general file operations
    pub const file_read_buffer_size: u32 = 8192;

    /// Small buffer size for temporary operations
    pub const temp_buffer_size: u32 = 512;

    /// Medium buffer size for text processing
    pub const text_buffer_size: u32 = 1024;

    /// Redirect buffer size for HTTP redirects
    pub const http_redirect_buffer_size: u32 = 2048;

    /// Signature buffer size for minisign operations
    pub const signature_buffer_size: u32 = 4096;
};

comptime {
    // Compile-time assertions to validate our limits.
    // Ensure args storage can hold at least one max-length arg per allowed arg.
    std.debug.assert(limits.arguments_storage_size_maximum >= limits.arguments_maximum * 32);

    // Ensure path length is reasonable.
    std.debug.assert(limits.path_length_maximum >= 256);
    std.debug.assert(limits.path_length_maximum <= 4096);

    // Ensure HTTP response can fit JSON data.
    std.debug.assert(limits.http_response_size_maximum >= limits.json_parse_size_maximum);

    // Ensure version string can hold semantic version plus metadata.
    std.debug.assert(limits.version_string_length_maximum >= 32);

    // Ensure we have enough path buffers for concurrent operations.
    std.debug.assert(limits.path_buffers_maximum >= 4);

    // Ensure extract buffer is large enough for reasonable operations.
    std.debug.assert(limits.extract_buffer_size_maximum >= 16 * 1024);

    // Ensure process output buffer is reasonable.
    std.debug.assert(limits.process_output_size_maximum >= 1024);
    std.debug.assert(limits.process_output_size_maximum <= 16 * 1024);
}
