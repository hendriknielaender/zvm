const std = @import("std");
const assert = std.debug.assert;

/// Exit codes with semantic meaning.
pub const ExitCode = enum(u8) {
    success = 0,
    invalid_arguments = 1,
    version_not_found = 2,
    network_error = 3,
    permission_error = 4,
    file_system_error = 5,
    already_exists = 6,
    corruption_detected = 7,
    resource_exhausted = 8,
    interrupted = 130,

    comptime {
        assert(@intFromEnum(ExitCode.success) == 0);
        assert(@intFromEnum(ExitCode.resource_exhausted) < 16);
        assert(@intFromEnum(ExitCode.resource_exhausted) >= @intFromEnum(ExitCode.success));
        assert(@intFromEnum(ExitCode.interrupted) == 130);
    }

    /// Convert error union types to semantic exit codes.
    pub fn from_error(error_value: anyerror) ExitCode {
        return switch (error_value) {
            error.FileNotFound, error.IsDir, error.NotDir => .file_system_error,
            error.PathAlreadyExists, error.AlreadyExists => .already_exists,
            error.AccessDenied, error.PermissionDenied => .permission_error,

            error.NetworkUnreachable,
            error.ConnectionRefused,
            error.Timeout,
            error.HostNotFound,
            => .network_error,

            error.OutOfMemory,
            error.NoSpaceLeft,
            error.SystemResources,
            => .resource_exhausted,

            error.InvalidData,
            error.HashMismatch,
            error.CorruptedData,
            => .corruption_detected,

            error.VersionNotFound, error.PackageNotFound => .version_not_found,
            error.Interrupted => .interrupted,
            else => .invalid_arguments,
        };
    }
};
