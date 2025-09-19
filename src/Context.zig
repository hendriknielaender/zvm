const std = @import("std");
const builtin = @import("builtin");
const limits = @import("memory/limits.zig");
const object_pools = @import("memory/object_pools.zig");
const static_memory = @import("memory/static_memory.zig");
const util_tool = @import("util/tool.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.context);

/// Cross-platform environment variable getter
/// Global application context containing all pre-allocated resources.
pub const CliContext = struct {
    /// Pre-allocated object pools.
    pools: object_pools.ObjectPools,

    /// Home directory buffer.
    home_dir_buffer: [limits.limits.home_dir_length_maximum]u8 = [_]u8{0} ** limits.limits.home_dir_length_maximum,
    home_dir_length: u32 = 0,

    /// Command line arguments (references into process_buffer).
    arguments_count: u32 = 0,

    /// Static memory system for any remaining allocations.
    static_mem: static_memory.StaticMemory,

    /// JSON parsing allocator - separate from static allocator to allow JSON parsing
    /// even after static allocator is locked.
    json_fba: std.heap.FixedBufferAllocator,

    /// Singleton instance - set during initialization.
    var instance: ?*CliContext = null;

    /// Initialize the context with all memory allocated upfront.
    pub fn init(
        context_storage: *CliContext,
        static_buffer: []u8,
        arguments: []const []const u8,
    ) !*CliContext {
        // context_storage is a pointer, not optional - can't be null in Zig
        assert(static_buffer.len > 0);
        assert(static_buffer.len == static_memory.StaticMemory.calculate_memory_size());
        assert(arguments.len > 0);
        assert(arguments.len <= limits.limits.arguments_maximum);

        if (instance != null) {
            log.err("CliContext already initialized: multiple initialization attempts are not allowed", .{});
            return error.AlreadyInitialized;
        }

        // Initialize core systems
        try init_core_systems(context_storage, static_buffer);

        // Copy command line arguments
        try copy_args(context_storage, arguments);

        // Initialize home directory
        try init_home_directory(context_storage);

        instance = context_storage;

        // Final postconditions
        assert(instance == context_storage);
        assert(context_storage.arguments_count > 0);
        assert(context_storage.home_dir_length > 0);

        return context_storage;
    }

    /// Initialize core systems (memory and pools)
    fn init_core_systems(context_storage: *CliContext, static_buffer: []u8) !void {
        assert(static_buffer.len > 0);
        assert(static_buffer.len == static_memory.StaticMemory.calculate_memory_size());

        // Initialize static memory system
        context_storage.static_mem = static_memory.StaticMemory.init(static_buffer);

        // Initialize object pools (no allocation needed)
        context_storage.pools = object_pools.ObjectPools.init();

        // Initialize JSON allocator with the pre-allocated JSON buffer
        const json_buffer = context_storage.pools.get_json_buffer();
        context_storage.json_fba = std.heap.FixedBufferAllocator.init(json_buffer);
    }

    /// Copy command line arguments into pre-allocated buffer
    fn copy_args(context_storage: *CliContext, arguments: []const []const u8) !void {
        assert(arguments.len > 0);
        assert(arguments.len <= limits.limits.arguments_maximum);

        const process_buffer = context_storage.pools.get_process_buffer();
        // process_buffer is a pointer, not optional - no need for null check

        var storage_offset: u32 = 0;
        var arguments_count: u32 = 0;

        for (arguments) |argument| {
            assert(argument.len > 0);
            assert(arguments_count < limits.limits.arguments_maximum);

            if (arguments_count >= limits.limits.arguments_maximum) break;

            const argument_length = argument.len;
            if (storage_offset + argument_length > process_buffer.arguments_storage.len) break;

            const old_offset = storage_offset;
            @memcpy(process_buffer.arguments_storage[storage_offset .. storage_offset + argument_length], argument);
            process_buffer.arguments[arguments_count] = process_buffer.arguments_storage[storage_offset .. storage_offset + argument_length];
            storage_offset += @intCast(argument_length);
            arguments_count += 1;

            assert(storage_offset == old_offset + argument_length);
            assert(process_buffer.arguments[arguments_count - 1].len == argument.len);
        }

        process_buffer.arguments_count = arguments_count;
        context_storage.arguments_count = arguments_count;

        assert(context_storage.arguments_count == arguments_count);
    }

    /// Initialize home directory
    fn init_home_directory(context_storage: *CliContext) !void {
        // Get home directory
        const home = blk: {
            if (builtin.os.tag == .windows) {
                // On Windows, we need to use the allocator since we're converting from UTF-16
                break :blk std.process.getEnvVarOwned(context_storage.static_mem.allocator(), "USERPROFILE") catch "./";
            } else {
                // On POSIX, use getenv which doesn't allocate, then copy to our buffer
                const home_env = util_tool.getenv_cross_platform("HOME") orelse "./";
                const allocated = context_storage.static_mem.allocator().dupe(u8, home_env) catch "./";
                break :blk allocated;
            }
        };

        // Validate home directory
        assert(home.len > 0);
        assert(home.len <= limits.limits.home_dir_length_maximum);

        // Copy home directory into our buffer
        if (home.len > context_storage.home_dir_buffer.len) {
            log.err("Home directory path too long: got {d} bytes, maximum is {d} bytes. Path: '{s}'", .{
                home.len,
                context_storage.home_dir_buffer.len,
                home,
            });
            return error.HomeDirectoryTooLong;
        }
        @memcpy(context_storage.home_dir_buffer[0..home.len], home);
        context_storage.home_dir_length = @intCast(home.len);

        assert(context_storage.home_dir_length == home.len);
        assert(context_storage.home_dir_length <= context_storage.home_dir_buffer.len);
    }

    pub fn get() !*CliContext {
        const context_instance = instance orelse {
            log.err("CliContext not initialized: call CliContext.init() before get()", .{});
            return error.NotInitialized;
        };
        assert(context_instance.home_dir_length > 0);
        assert(context_instance.home_dir_length <= limits.limits.home_dir_length_maximum);
        return context_instance;
    }

    /// Get home directory.
    pub fn get_home_dir(self: *const CliContext) []const u8 {
        assert(self.home_dir_length > 0);
        assert(self.home_dir_length <= self.home_dir_buffer.len);

        const result = self.home_dir_buffer[0..self.home_dir_length];

        assert(result.len == self.home_dir_length);
        return result;
    }

    /// Get command line arguments.
    pub fn get_args(self: *CliContext) [][]const u8 {
        assert(self.arguments_count > 0);
        assert(self.arguments_count <= limits.limits.arguments_maximum);

        const process_buffer = self.pools.get_process_buffer();
        // process_buffer is a pointer, not optional - no need for null check

        const result = process_buffer.arguments[0..self.arguments_count];

        assert(result.len == self.arguments_count);
        return result;
    }

    /// Get a path buffer from the pool.
    pub fn acquire_path_buffer(self: *CliContext) !*object_pools.PathBuffer {
        return self.pools.acquire_path_buffer();
    }

    /// Get an HTTP operation from the pool.
    pub fn acquire_http_operation(self: *CliContext) !*object_pools.HttpOperation {
        return self.pools.acquire_http_operation();
    }

    /// Get an extract operation from the pool.
    pub fn acquire_extract_operation(self: *CliContext) !*object_pools.ExtractOperation {
        return self.pools.acquire_extract_operation();
    }

    /// Get a version entry from the pool.
    pub fn acquire_version_entry(self: *CliContext) !*object_pools.VersionEntry {
        return self.pools.acquire_version_entry();
    }

    /// Build a ZVM path using a path buffer.
    pub fn build_zvm_path(self: *CliContext, segment: []const u8) ![]const u8 {
        assert(segment.len > 0);
        assert(segment.len < limits.limits.path_length_maximum / 2); // Leave room for home dir

        var buffer = try self.acquire_path_buffer();
        defer buffer.reset();

        // buffer is a pointer, not optional - no need for null check

        var fixed_buffer_stream = std.Io.fixedBufferStream(buffer.slice());
        const home_dir = self.get_home_dir();
        assert(home_dir.len > 0);

        // Follow XDG Base Directory specification
        if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
            try fixed_buffer_stream.writer().print("{s}/.zm/{s}", .{ xdg_data, segment });
        } else {
            // Use XDG default: $HOME/.local/share/.zm
            try fixed_buffer_stream.writer().print("{s}/.local/share/.zm/{s}", .{ home_dir, segment });
        }

        const result = try buffer.set(fixed_buffer_stream.getWritten());

        assert(result.len > 0);
        assert(result.len <= limits.limits.path_length_maximum);

        return result;
    }

    /// Get the JSON parse buffer.
    pub fn get_json_buffer(self: *CliContext) []u8 {
        const buffer = self.pools.get_json_buffer();
        assert(buffer.len > 0);
        assert(buffer.len == limits.limits.json_parse_size_maximum);
        return buffer;
    }

    /// Get a JSON allocator that uses the pre-allocated JSON buffer.
    /// This allocator is separate from the static allocator to allow JSON parsing
    /// to work correctly even after the static allocator is locked.
    pub fn get_json_allocator(self: *CliContext) std.mem.Allocator {
        return self.json_fba.allocator();
    }

    /// Get a ZON allocator
    pub fn get_zon_allocator(self: *CliContext) std.mem.Allocator {
        return self.static_mem.allocator();
    }

    /// Get the process buffer.
    pub fn get_process_buffer(self: *CliContext) *object_pools.ProcessBuffer {
        return self.pools.get_process_buffer();
    }

    /// Get the static allocator for any remaining needs.
    /// Note: This should be used sparingly as we prefer pre-allocated pools.
    pub fn get_allocator(self: *CliContext) std.mem.Allocator {
        // Verify static memory is initialized
        assert(self.static_mem.buffer.len > 0);
        return self.static_mem.allocator();
    }

    /// Get memory usage statistics.
    pub fn get_memory_usage(self: *const CliContext) static_memory.StaticMemory.MemoryUsage {
        const usage = self.static_mem.get_usage();
        assert(usage.used <= usage.total);
        assert(usage.available == usage.total - usage.used);
        return usage;
    }

    /// Get pool usage statistics.
    pub fn get_pool_stats(self: *const CliContext) object_pools.ObjectPools.PoolStats {
        return self.pools.get_stats();
    }

    /// Print debug information about resource usage.
    pub fn print_debug_info(self: *const CliContext) !void {
        const mem_usage = self.get_memory_usage();
        const pool_stats = self.get_pool_stats();

        var buffer: [limits.limits.io_buffer_size_maximum]u8 = undefined;
        var stderr_writer = std.fs.File.Writer.init(std.fs.File.stderr(), &buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print("\n=== ZVM Resource Usage ===\n", .{});
        try stderr.print("{any}\n", .{mem_usage});
        try stderr.print("{any}\n", .{pool_stats});
        try stderr.print("========================\n\n", .{});
        try stderr.flush();
    }

    /// Reset all pools (useful for tests).
    pub fn reset(self: *CliContext) void {
        self.pools.reset();
        self.static_mem.reset();
        self.arguments_count = 0;
        self.home_dir_length = 0;
        instance = null;

        assert(self.arguments_count == 0);
        assert(self.home_dir_length == 0);
        assert(instance == null);
    }
};
