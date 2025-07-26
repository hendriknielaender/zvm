const std = @import("std");
const config = @import("limits.zig");

/// All memory is allocated upfront, no dynamic allocation after initialization.
pub const StaticMemory = struct {
    /// The single large buffer that holds all our memory.
    /// Size is calculated based on worst-case requirements.
    buffer: []u8,

    /// Fixed buffer allocator that manages our static buffer.
    fba: std.heap.FixedBufferAllocator,

    /// Calculate the total memory needed based on our static limits.
    pub fn calculate_memory_size() usize {
        var total: usize = 0;

        std.debug.assert(config.limits.path_buffers_maximum > 0);
        std.debug.assert(config.limits.path_length_maximum > 0);

        // Path buffers.
        const path_buffers_size = config.limits.path_buffers_maximum * config.limits.path_length_maximum;
        std.debug.assert(path_buffers_size > 0);
        total += path_buffers_size;

        // HTTP operations.
        const http_size = config.limits.http_operations_maximum * (
            config.limits.http_response_size_maximum + 
            config.limits.url_length_maximum + 
            config.limits.http_header_size_maximum
        );
        std.debug.assert(http_size > 0);
        total += http_size;

        // Version entries.
        const version_size = config.limits.versions_maximum * config.limits.version_string_length_maximum;
        std.debug.assert(version_size > 0);
        total += version_size;

        // Extract operations.
        const extract_size = config.limits.extract_operations_maximum * config.limits.extract_buffer_size_maximum;
        std.debug.assert(extract_size > 0);
        total += extract_size;

        // Process buffer.
        std.debug.assert(config.limits.process_output_size_maximum > 0);
        total += config.limits.process_output_size_maximum;
        const args_ptr_size = config.limits.arguments_maximum * @sizeOf([]const u8);
        std.debug.assert(args_ptr_size > 0);
        total += args_ptr_size; // Arg pointers.
        std.debug.assert(config.limits.arguments_storage_size_maximum > 0);
        total += config.limits.arguments_storage_size_maximum; // Arg strings.

        // JSON parse buffer.
        std.debug.assert(config.limits.json_parse_size_maximum > 0);
        total += config.limits.json_parse_size_maximum;

        // Miscellaneous buffers.
        std.debug.assert(config.limits.home_dir_length_maximum > 0);
        total += config.limits.home_dir_length_maximum;
        const dir_entries_size = config.limits.dir_entries_maximum * config.limits.path_length_maximum;
        std.debug.assert(dir_entries_size > 0);
        total += dir_entries_size;
        std.debug.assert(config.limits.format_buffer_size_maximum > 0);
        total += config.limits.format_buffer_size_maximum;
        std.debug.assert(config.limits.file_buffer_size_maximum > 0);
        total += config.limits.file_buffer_size_maximum;
        std.debug.assert(config.limits.shell_type_length_maximum > 0);
        total += config.limits.shell_type_length_maximum;
        const env_vars_size = config.limits.env_var_length_maximum * 4;
        std.debug.assert(env_vars_size > 0);
        total += env_vars_size; // Multiple env vars.

        // Add 10% overhead for alignment and other needs.
        const overhead = total / 10;
        std.debug.assert(overhead > 0);
        total = total + overhead;

        std.debug.assert(total > 0);
        std.debug.assert(total < 1024 * 1024 * 1024); // Less than 1GB

        return total;
    }

    /// Initialize the static memory system.
    /// This is called once at program start.
    pub fn init(backing_buffer: []u8) StaticMemory {
        std.debug.assert(backing_buffer.len > 0);
        std.debug.assert(backing_buffer.len == calculate_memory_size());
        std.debug.assert(@intFromPtr(backing_buffer.ptr) % 8 == 0); // 8-byte aligned

        const result = StaticMemory{
            .buffer = backing_buffer,
            .fba = std.heap.FixedBufferAllocator.init(backing_buffer),
        };

        std.debug.assert(result.buffer.len == backing_buffer.len);

        return result;
    }

    /// Get the allocator interface.
    pub fn allocator(self: *StaticMemory) std.mem.Allocator {
        std.debug.assert(self.buffer.len > 0);

        return self.fba.allocator();
    }

    /// Reset all allocations (useful for tests).
    pub fn reset(self: *StaticMemory) void {
        std.debug.assert(self.buffer.len > 0);

        const old_end_index = self.fba.end_index;
        self.fba.reset();

        std.debug.assert(self.fba.end_index == 0);
        if (old_end_index > 0) std.debug.assert(self.fba.end_index < old_end_index);
    }

    /// Get memory usage statistics.
    pub fn get_usage(self: *const StaticMemory) MemoryUsage {
        std.debug.assert(self.buffer.len > 0);
        std.debug.assert(self.fba.end_index <= self.buffer.len);

        const usage = MemoryUsage{
            .used = self.fba.end_index,
            .total = self.buffer.len,
            .available = self.buffer.len - self.fba.end_index,
        };

        std.debug.assert(usage.used <= usage.total);
        std.debug.assert(usage.available == usage.total - usage.used);
        std.debug.assert(usage.used + usage.available == usage.total);

        return usage;
    }

    pub const MemoryUsage = struct {
        used: usize,
        total: usize,
        available: usize,

        pub fn format(
            self: MemoryUsage,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            std.debug.assert(self.total > 0);
            std.debug.assert(self.used <= self.total);
            std.debug.assert(self.available == self.total - self.used);

            const used_mb = @as(f64, @floatFromInt(self.used)) / (1024.0 * 1024.0);
            const total_mb = @as(f64, @floatFromInt(self.total)) / (1024.0 * 1024.0);
            const percent = @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total)) * 100.0;

            // Validate calculations
            std.debug.assert(used_mb >= 0.0);
            std.debug.assert(total_mb > 0.0);
            std.debug.assert(percent >= 0.0);
            std.debug.assert(percent <= 100.0);

            try writer.print("Memory: {d:.2}MB / {d:.2}MB ({d:.1}%)", .{ used_mb, total_mb, percent });
        }
    };
};

comptime {
    // Compile-time validation of memory requirements.
    const required = StaticMemory.calculate_memory_size();
    const mb = required / (1024 * 1024);

    // Assert memory size relationships
    std.debug.assert(required > 0);
    std.debug.assert(required >= 1024 * 1024); // At least 1MB
    std.debug.assert(mb > 0);
    std.debug.assert(mb == required / (1024 * 1024));

    // Ensure we're not requiring too much memory.
    if (required > 100 * 1024 * 1024) {
        @compileError(std.fmt.comptimePrint(
            "Static memory requirement too large: {}MB. Review limits.",
            .{mb},
        ));
    }

    // Assert relationships between compile-time constants
    std.debug.assert(config.limits.path_length_maximum >= 256);
    std.debug.assert(config.limits.path_buffers_maximum >= 4);
    std.debug.assert(config.limits.http_operations_maximum >= 1);
    std.debug.assert(config.limits.json_parse_size_maximum >= 512 * 1024); // At least 512KB for JSON
}
