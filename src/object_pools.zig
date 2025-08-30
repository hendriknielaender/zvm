const std = @import("std");
const limits = @import("limits.zig");

/// Pre-allocated path buffer with static storage.
pub const PathBuffer = struct {
    data: [limits.limits.path_length_maximum]u8,
    used: u32 = 0,

    pub fn reset(self: *PathBuffer) void {
        self.used = 0;
    }

    pub fn set(self: *PathBuffer, path: []const u8) ![]const u8 {
        if (path.len > self.data.len) {
            std.log.err("Path too long: got {d} bytes, maximum is {d} bytes. Path starts with: '{s}...'", .{
                path.len,
                self.data.len,
                if (path.len > 50) path[0..50] else path,
            });
            return error.PathTooLong;
        }

        // Check if path is already in our buffer (avoid aliasing)
        const path_start = @intFromPtr(path.ptr);
        const path_end = path_start + path.len;
        const buffer_start = @intFromPtr(&self.data[0]);
        const buffer_end = buffer_start + self.data.len;

        if (path_start >= buffer_start and path_end <= buffer_end) {
            // Path is already in our buffer, just update the used length
            self.used = @intCast(path.len);
        } else {
            // Path is external, copy it
            @memcpy(self.data[0..path.len], path);
            self.used = @intCast(path.len);
        }

        return self.data[0..self.used];
    }

    pub fn slice(self: *PathBuffer) []u8 {
        return self.data[0..];
    }

    pub fn used_slice(self: *const PathBuffer) []const u8 {
        return self.data[0..self.used];
    }
};

/// Pre-allocated HTTP operation with static buffers.
/// Response data and headers use pre-allocated memory.
/// Certificate handling uses temporary allocation due to std library constraints.
pub const HttpOperation = struct {
    response_buffer: [limits.limits.http_response_size_maximum]u8,
    url_buffer: [limits.limits.url_length_maximum]u8,
    header_buffer: [limits.limits.http_header_size_maximum]u8,

    in_use: bool = false,

    pub fn acquire(self: *HttpOperation) !void {
        if (self.in_use) {
            std.log.err("HttpOperation already in use: cannot acquire an operation that hasn't been released", .{});
            return error.HttpOperationInUse;
        }
        self.in_use = true;
    }

    pub fn release(self: *HttpOperation) void {
        self.in_use = false;
    }

    pub fn response_slice(self: *HttpOperation) []u8 {
        return self.response_buffer[0..];
    }

    pub fn url_slice(self: *HttpOperation) []u8 {
        return self.url_buffer[0..];
    }

    pub fn header_slice(self: *HttpOperation) []u8 {
        return self.header_buffer[0..];
    }
};

/// Pre-allocated version entry with static name buffer.
pub const VersionEntry = struct {
    name_buffer: [limits.limits.version_string_length_maximum]u8,
    name_length: u8 = 0,
    metadata: VersionMetadata = .{},
    occupied: bool = false,

    pub const VersionMetadata = struct {
        date: [32]u8 = [_]u8{0} ** 32,
        date_length: u8 = 0,
        size: u64 = 0,
        shasum: [64]u8 = [_]u8{0} ** 64,
    };

    pub fn set_name(self: *VersionEntry, name: []const u8) !void {
        if (name.len > self.name_buffer.len) {
            std.log.err("Version name too long: got {d} bytes, maximum is {d} bytes. Name: '{s}'", .{
                name.len,
                self.name_buffer.len,
                name,
            });
            return error.NameTooLong;
        }
        @memcpy(self.name_buffer[0..name.len], name);
        self.name_length = @intCast(name.len);
        self.occupied = true;
    }

    pub fn get_name(self: *const VersionEntry) []const u8 {
        return self.name_buffer[0..self.name_length];
    }

    pub fn reset(self: *VersionEntry) void {
        self.name_length = 0;
        self.occupied = false;
        self.metadata = .{};
    }
};

/// Pre-allocated extract operation with static buffer.
pub const ExtractOperation = struct {
    buffer: [limits.limits.extract_buffer_size_maximum]u8,
    tmp_path_buffer: PathBuffer,
    out_path_buffer: PathBuffer,
    in_use: bool = false,

    pub fn acquire(self: *ExtractOperation) !void {
        if (self.in_use) {
            std.log.err("ExtractOperation already in use: cannot acquire an operation that hasn't been released", .{});
            return error.ExtractOperationInUse;
        }
        self.in_use = true;
    }

    pub fn release(self: *ExtractOperation) void {
        self.in_use = false;
    }

    pub fn slice(self: *ExtractOperation) []u8 {
        return self.buffer[0..];
    }
};

/// Pre-allocated process buffer with static storage.
pub const ProcessBuffer = struct {
    output: [limits.limits.process_output_size_maximum]u8,
    arguments: [limits.limits.arguments_maximum][]const u8,
    arguments_storage: [limits.limits.arguments_storage_size_maximum]u8,
    arguments_count: u32 = 0,

    pub fn reset(self: *ProcessBuffer) void {
        self.arguments_count = 0;
    }

    pub fn output_slice(self: *ProcessBuffer) []u8 {
        return self.output[0..];
    }

    pub fn arguments_slice(self: *ProcessBuffer) [][]const u8 {
        return self.arguments[0..self.arguments_count];
    }
};

/// All object pools for the application - completely static.
pub const ObjectPools = struct {
    path_buffers: [limits.limits.path_buffers_maximum]PathBuffer,
    http_operations: [limits.limits.http_operations_maximum]HttpOperation,
    version_entries: [limits.limits.versions_maximum]VersionEntry,
    extract_operations: [limits.limits.extract_operations_maximum]ExtractOperation,
    process_buffer: ProcessBuffer,
    json_parse_buffer: [limits.limits.json_parse_size_maximum]u8,

    /// Initialize object pools - no allocation needed!
    pub fn init() ObjectPools {
        return ObjectPools{
            // SAFETY: PathBuffer data arrays are initialized before first use by set() method
            .path_buffers = [_]PathBuffer{.{ .data = undefined, .used = 0 }} ** limits.limits.path_buffers_maximum,
            .http_operations = [_]HttpOperation{.{
                // SAFETY: HTTP buffers are initialized before first use by HTTP client
                .response_buffer = undefined,
                // SAFETY: HTTP buffers are initialized before first use by HTTP client
                .url_buffer = undefined,
                // SAFETY: HTTP buffers are initialized before first use by HTTP client
                .header_buffer = undefined,
                .in_use = false,
            }} ** limits.limits.http_operations_maximum,
            // SAFETY: VersionEntry name buffers are initialized before first use by set_name() method
            .version_entries = [_]VersionEntry{.{ .name_buffer = undefined, .name_length = 0, .metadata = .{}, .occupied = false }} ** limits.limits.versions_maximum,
            .extract_operations = [_]ExtractOperation{.{
                // SAFETY: Extract buffer is initialized before first use by extract operations
                .buffer = undefined,
                // SAFETY: PathBuffer data arrays are initialized before first use by set() method
                .tmp_path_buffer = .{ .data = undefined, .used = 0 },
                // SAFETY: PathBuffer data arrays are initialized before first use by set() method
                .out_path_buffer = .{ .data = undefined, .used = 0 },
                .in_use = false,
            }} ** limits.limits.extract_operations_maximum,
            .process_buffer = .{
                // SAFETY: Process buffers are initialized before first use by process operations
                .output = undefined,
                // SAFETY: Process buffers are initialized before first use by process operations
                .arguments = undefined,
                // SAFETY: Process buffers are initialized before first use by process operations
                .arguments_storage = undefined,
                .arguments_count = 0,
            },
            // SAFETY: JSON buffer is initialized before first use by JSON parsing operations
            .json_parse_buffer = undefined,
        };
    }

    pub fn acquire_path_buffer(self: *ObjectPools) !*PathBuffer {
        for (&self.path_buffers) |*pb| {
            if (pb.used == 0) {
                return pb;
            }
        }
        std.log.err("No PathBuffer available: all {d} path buffers are in use. Consider increasing path_buffers_maximum", .{
            limits.limits.path_buffers_maximum,
        });
        return error.NoPathBufferAvailable;
    }

    pub fn acquire_http_operation(self: *ObjectPools) !*HttpOperation {
        for (&self.http_operations) |*ho| {
            if (!ho.in_use) {
                try ho.acquire();
                return ho;
            }
        }
        std.log.err("No HttpOperation available: all {d} HTTP operations are in use. Consider increasing http_operations_maximum", .{
            limits.limits.http_operations_maximum,
        });
        return error.NoHttpOperationAvailable;
    }

    pub fn acquire_extract_operation(self: *ObjectPools) !*ExtractOperation {
        for (&self.extract_operations) |*eo| {
            if (!eo.in_use) {
                try eo.acquire();
                return eo;
            }
        }
        std.log.err("No ExtractOperation available: extract operation is already in use", .{});
        return error.NoExtractOperationAvailable;
    }

    pub fn acquire_version_entry(self: *ObjectPools) !*VersionEntry {
        for (&self.version_entries) |*ve| {
            if (!ve.occupied) {
                ve.occupied = true; // Mark as occupied when acquired
                return ve;
            }
        }
        std.log.err("No VersionEntry available: all {d} version entries are in use. Consider increasing versions_maximum", .{
            limits.limits.versions_maximum,
        });
        return error.NoVersionEntryAvailable;
    }

    pub fn get_json_buffer(self: *ObjectPools) []u8 {
        return &self.json_parse_buffer;
    }

    pub fn get_process_buffer(self: *ObjectPools) *ProcessBuffer {
        return &self.process_buffer;
    }

    /// Reset all pools (useful for tests).
    pub fn reset(self: *ObjectPools) void {
        for (&self.path_buffers) |*pb| {
            pb.reset();
        }
        for (&self.http_operations) |*ho| {
            ho.in_use = false;
        }
        for (&self.version_entries) |*ve| {
            ve.reset();
        }
        for (&self.extract_operations) |*eo| {
            eo.in_use = false;
        }
        self.process_buffer.reset();
    }

    /// Pool usage statistics for debugging and monitoring
    pub const PoolStats = struct {
        path_buffers: ResourceStats,
        http_operations: ResourceStats,
        version_entries: ResourceStats,
        extract_operations: ResourceStats,

        pub const ResourceStats = struct {
            total: u32,
            in_use: u32,
            available: u32,

            pub fn usage_percent(self: ResourceStats) f32 {
                if (self.total == 0) return 0.0;
                return @as(f32, @floatFromInt(self.in_use)) / @as(f32, @floatFromInt(self.total)) * 100.0;
            }
        };

        pub fn format(
            self: PoolStats,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("Pool Usage Statistics:\n", .{});
            try writer.print("  Path Buffers:    {d}/{d} ({d:.1}%)\n", .{
                self.path_buffers.in_use,
                self.path_buffers.total,
                self.path_buffers.usage_percent(),
            });
            try writer.print("  HTTP Operations: {d}/{d} ({d:.1}%)\n", .{
                self.http_operations.in_use,
                self.http_operations.total,
                self.http_operations.usage_percent(),
            });
            try writer.print("  Version Entries: {d}/{d} ({d:.1}%)\n", .{
                self.version_entries.in_use,
                self.version_entries.total,
                self.version_entries.usage_percent(),
            });
            try writer.print("  Extract Ops:     {d}/{d} ({d:.1}%)\n", .{
                self.extract_operations.in_use,
                self.extract_operations.total,
                self.extract_operations.usage_percent(),
            });
        }
    };

    /// Get current pool usage statistics
    pub fn get_stats(self: *const ObjectPools) PoolStats {
        // SAFETY: All fields are immediately initialized before return
        var stats: PoolStats = undefined;

        // Count path buffers
        var path_buffer_count: u32 = 0;
        for (self.path_buffers) |pb| {
            if (pb.used > 0) path_buffer_count += 1;
        }
        stats.path_buffers = .{
            .total = limits.limits.path_buffers_maximum,
            .in_use = path_buffer_count,
            .available = limits.limits.path_buffers_maximum - path_buffer_count,
        };

        // Count HTTP operations
        var http_count: u32 = 0;
        for (self.http_operations) |ho| {
            if (ho.in_use) http_count += 1;
        }
        stats.http_operations = .{
            .total = limits.limits.http_operations_maximum,
            .in_use = http_count,
            .available = limits.limits.http_operations_maximum - http_count,
        };

        // Count version entries
        var version_count: u32 = 0;
        for (self.version_entries) |ve| {
            if (ve.occupied) version_count += 1;
        }
        stats.version_entries = .{
            .total = limits.limits.versions_maximum,
            .in_use = version_count,
            .available = limits.limits.versions_maximum - version_count,
        };

        // Count extract operations
        var extract_count: u32 = 0;
        for (self.extract_operations) |eo| {
            if (eo.in_use) extract_count += 1;
        }
        stats.extract_operations = .{
            .total = limits.limits.extract_operations_maximum,
            .in_use = extract_count,
            .available = limits.limits.extract_operations_maximum - extract_count,
        };

        return stats;
    }
};
