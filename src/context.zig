const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");
const object_pools = @import("object_pools.zig");
const static_memory = @import("static_memory.zig");

/// Global application context containing all pre-allocated resources.
pub const CliContext = struct {
    /// Pre-allocated object pools.
    pools: object_pools.ObjectPools,

    /// Home directory buffer.
    home_dir_buffer: [limits.limits.home_dir_length_maximum]u8 = undefined,
    home_dir_length: u32 = 0,

    /// Command line arguments (references into process_buffer).
    arguments_count: u32 = 0,

    /// Static memory system for any remaining allocations.
    static_mem: static_memory.StaticMemory,

    /// Singleton instance - set during initialization.
    var instance: ?*CliContext = null;

    /// Initialize the context with all memory allocated upfront.
    pub fn init(
        context_storage: *CliContext,
        static_buffer: []u8,
        arguments: [][]const u8,
    ) !*CliContext {
        // context_storage is a pointer, not optional - can't be null in Zig
        std.debug.assert(static_buffer.len > 0);
        std.debug.assert(static_buffer.len == static_memory.StaticMemory.calculate_memory_size());
        std.debug.assert(arguments.len > 0);
        std.debug.assert(arguments.len <= limits.limits.arguments_maximum);

        if (instance != null) {
            std.log.err("CliContext already initialized: multiple initialization attempts are not allowed", .{});
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
        std.debug.assert(instance == context_storage);
        std.debug.assert(context_storage.arguments_count > 0);
        std.debug.assert(context_storage.home_dir_length > 0);

        return context_storage;
    }

    /// Initialize core systems (memory and pools)
    fn init_core_systems(context_storage: *CliContext, static_buffer: []u8) !void {
        std.debug.assert(static_buffer.len > 0);
        std.debug.assert(static_buffer.len == static_memory.StaticMemory.calculate_memory_size());

        // Initialize static memory system
        context_storage.static_mem = static_memory.StaticMemory.init(static_buffer);

        // Initialize object pools (no allocation needed)
        context_storage.pools = object_pools.ObjectPools.init();
    }

    /// Copy command line arguments into pre-allocated buffer
    fn copy_args(context_storage: *CliContext, arguments: [][]const u8) !void {
        std.debug.assert(arguments.len > 0);
        std.debug.assert(arguments.len <= limits.limits.arguments_maximum);

        const process_buffer = context_storage.pools.get_process_buffer();
        // process_buffer is a pointer, not optional - no need for null check

        var storage_offset: u32 = 0;
        var arguments_count: u32 = 0;

        for (arguments) |argument| {
            std.debug.assert(argument.len > 0);
            std.debug.assert(arguments_count < limits.limits.arguments_maximum);

            if (arguments_count >= limits.limits.arguments_maximum) break;

            const argument_length = argument.len;
            if (storage_offset + argument_length > process_buffer.arguments_storage.len) break;

            const old_offset = storage_offset;
            @memcpy(process_buffer.arguments_storage[storage_offset .. storage_offset + argument_length], argument);
            process_buffer.arguments[arguments_count] = process_buffer.arguments_storage[storage_offset .. storage_offset + argument_length];
            storage_offset += @intCast(argument_length);
            arguments_count += 1;

            std.debug.assert(storage_offset == old_offset + argument_length);
            std.debug.assert(process_buffer.arguments[arguments_count - 1].len == argument.len);
        }

        process_buffer.arguments_count = arguments_count;
        context_storage.arguments_count = arguments_count;

        std.debug.assert(context_storage.arguments_count == arguments_count);
    }

    /// Initialize home directory
    fn init_home_directory(context_storage: *CliContext) !void {
        // Get home directory
        const home = if (builtin.os.tag == .windows)
            std.process.getEnvVarOwned(context_storage.static_mem.allocator(), "USERPROFILE") catch "./"
        else
            std.posix.getenv("HOME") orelse "./";

        // Validate home directory
        std.debug.assert(home.len > 0);
        std.debug.assert(home.len <= limits.limits.home_dir_length_maximum);

        // Copy home directory into our buffer
        if (home.len > context_storage.home_dir_buffer.len) {
            std.log.err("Home directory path too long: got {d} bytes, maximum is {d} bytes. Path: '{s}'", .{
                home.len,
                context_storage.home_dir_buffer.len,
                home,
            });
            return error.HomeDirectoryTooLong;
        }
        @memcpy(context_storage.home_dir_buffer[0..home.len], home);
        context_storage.home_dir_length = @intCast(home.len);

        std.debug.assert(context_storage.home_dir_length == home.len);
        std.debug.assert(context_storage.home_dir_length <= context_storage.home_dir_buffer.len);
    }

    pub fn get() !*CliContext {
        const context_instance = instance orelse {
            std.log.err("CliContext not initialized: call CliContext.init() before get()", .{});
            return error.NotInitialized;
        };
        std.debug.assert(context_instance.home_dir_length > 0);
        std.debug.assert(context_instance.home_dir_length <= limits.limits.home_dir_length_maximum);
        return context_instance;
    }

    /// Get home directory.
    pub fn get_home_dir(self: *const CliContext) []const u8 {
        std.debug.assert(self.home_dir_length > 0);
        std.debug.assert(self.home_dir_length <= self.home_dir_buffer.len);

        const result = self.home_dir_buffer[0..self.home_dir_length];

        std.debug.assert(result.len == self.home_dir_length);
        return result;
    }

    /// Get command line arguments.
    pub fn get_args(self: *CliContext) [][]const u8 {
        std.debug.assert(self.arguments_count > 0);
        std.debug.assert(self.arguments_count <= limits.limits.arguments_maximum);

        const process_buffer = self.pools.get_process_buffer();
        // process_buffer is a pointer, not optional - no need for null check

        const result = process_buffer.arguments[0..self.arguments_count];

        std.debug.assert(result.len == self.arguments_count);
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
        std.debug.assert(segment.len > 0);
        std.debug.assert(segment.len < limits.limits.path_length_maximum / 2); // Leave room for home dir

        var buffer = try self.acquire_path_buffer();
        defer buffer.reset();

        // buffer is a pointer, not optional - no need for null check

        var fixed_buffer_stream = std.io.fixedBufferStream(buffer.slice());
        const home_dir = self.get_home_dir();
        std.debug.assert(home_dir.len > 0);

        try fixed_buffer_stream.writer().print("{s}/.zm/{s}", .{ home_dir, segment });
        const result = try buffer.set(fixed_buffer_stream.getWritten());

        std.debug.assert(result.len > 0);
        std.debug.assert(result.len <= limits.limits.path_length_maximum);

        return result;
    }

    /// Get the JSON parse buffer.
    pub fn get_json_buffer(self: *CliContext) []u8 {
        const buffer = self.pools.get_json_buffer();
        std.debug.assert(buffer.len > 0);
        std.debug.assert(buffer.len == limits.limits.json_parse_size_maximum);
        return buffer;
    }

    /// Get the process buffer.
    pub fn get_process_buffer(self: *CliContext) *object_pools.ProcessBuffer {
        return self.pools.get_process_buffer();
    }

    /// Get the static allocator for any remaining needs.
    /// Note: This should be used sparingly as we prefer pre-allocated pools.
    pub fn get_allocator(self: *CliContext) std.mem.Allocator {
        // Verify static memory is initialized
        std.debug.assert(self.static_mem.buffer.len > 0);
        return self.static_mem.allocator();
    }

    /// Get memory usage statistics.
    pub fn get_memory_usage(self: *const CliContext) static_memory.StaticMemory.MemoryUsage {
        const usage = self.static_mem.get_usage();
        std.debug.assert(usage.used <= usage.total);
        std.debug.assert(usage.available == usage.total - usage.used);
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
        
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n=== ZVM Resource Usage ===\n", .{});
        try stderr.print("{}\n", .{mem_usage});
        try stderr.print("{}\n", .{pool_stats});
        try stderr.print("========================\n\n", .{});
    }

    /// Reset all pools (useful for tests).
    pub fn reset(self: *CliContext) void {
        self.pools.reset();
        self.static_mem.reset();
        self.arguments_count = 0;
        self.home_dir_length = 0;
        instance = null;

        std.debug.assert(self.arguments_count == 0);
        std.debug.assert(self.home_dir_length == 0);
        std.debug.assert(instance == null);
    }
};
