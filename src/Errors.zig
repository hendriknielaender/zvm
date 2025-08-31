const std = @import("std");

pub const ZvmError = error{
    DownloadFailed,
    NetworkTimeout,
    InvalidResponse,
    InvalidVersion,
    InstallationFailed,
    ExtractionFailed,
    InvalidConfig,
    MissingHome,
    InsufficientPermissions,
    DiskSpaceExhausted,
    HomeNotFound,
    HomePathTooLong,
    ToolPathTooLong,
    TooManyExecArgs,
    ExecArgsStorageFull,
    NoArguments,
    TooManyArguments,
    UnknownCommand,
    MissingVersionArgument,
    EmptyVersionArgument,
    VersionStringTooLong,
    UnknownFlag,
    UnexpectedArguments,
    EmptyShellArgument,
    ShellNameTooLong,
    BufferTooSmall,
};

pub const ZvmResult = union(enum) {
    success: void,
    error_with_context: struct {
        err: ZvmError,
        context: []const u8,
    },

    pub fn is_success(self: ZvmResult) bool {
        return switch (self) {
            .success => true,
            .error_with_context => false,
        };
    }

    pub fn unwrap(self: ZvmResult) ZvmError!void {
        return switch (self) {
            .success => {},
            .error_with_context => |ctx| ctx.err,
        };
    }
};

pub fn success() ZvmResult {
    return ZvmResult{ .success = {} };
}

pub fn error_with_context(err: ZvmError, context: []const u8) ZvmResult {
    return ZvmResult{
        .error_with_context = .{
            .err = err,
            .context = context,
        },
    };
}
