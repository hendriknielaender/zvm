const std = @import("std");
const limits = @import("memory/limits.zig");
const object_pools = @import("memory/object_pools.zig");
const static_memory = @import("memory/static_memory.zig");
const paths = @import("platform/paths.zig");
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

    /// Process-owned I/O implementation.
    io: std.Io,

    /// Global --yes flag: skip confirmation prompts for destructive operations.
    assume_yes: bool = false,

    /// Global --no-input flag: refuse to prompt; non-interactive runs fail fast.
    no_input: bool = false,

    /// Singleton instance - set during initialization.
    var instance: ?*CliContext = null;

    pub const PathScratch = struct {
        buffer: *object_pools.PathBuffer,
        released: bool = false,

        pub fn release(self: *PathScratch) void {
            assert(!self.released);
            self.buffer.reset();
            self.released = true;
        }

        pub fn slice(self: *const PathScratch) []u8 {
            assert(!self.released);
            return self.buffer.slice();
        }

        pub fn set(self: *const PathScratch, value: []const u8) ![]const u8 {
            assert(!self.released);
            return self.buffer.set(value);
        }

        pub fn used_slice(self: *const PathScratch) []const u8 {
            assert(!self.released);
            return self.buffer.used_slice();
        }

        pub fn print(
            self: *const PathScratch,
            comptime format: []const u8,
            args: anytype,
        ) ![]const u8 {
            assert(!self.released);
            return self.set(try std.fmt.bufPrint(self.slice(), format, args));
        }
    };

    pub const HttpScratch = struct {
        operation: *object_pools.HttpOperation,
        released: bool = false,

        pub fn release(self: *HttpScratch) void {
            assert(!self.released);
            self.operation.release();
            self.released = true;
        }
    };

    pub const ExtractScratch = struct {
        operation: *object_pools.ExtractOperation,
        released: bool = false,

        pub fn release(self: *ExtractScratch) void {
            assert(!self.released);
            self.operation.release();
            self.released = true;
        }
    };

    /// Initialize the context with all memory allocated upfront.
    pub fn init(
        context_storage: *CliContext,
        static_buffer: []u8,
        arguments: []const []const u8,
        io: std.Io,
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
        context_storage.io = io;

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

    /// Initialize a context and freeze startup allocation before runtime work.
    pub fn init_locked(
        context_storage: *CliContext,
        static_buffer: []u8,
        arguments: []const []const u8,
        io: std.Io,
    ) !*CliContext {
        const context = try init(context_storage, static_buffer, arguments, io);
        context.static_mem.lock();
        return context;
    }

    /// Initialize core systems (memory and pools)
    fn init_core_systems(context_storage: *CliContext, static_buffer: []u8) !void {
        assert(static_buffer.len > 0);
        assert(static_buffer.len == static_memory.StaticMemory.calculate_memory_size());

        // Initialize static memory system
        context_storage.static_mem = static_memory.StaticMemory.init(static_buffer);

        // Initialize object pools in place to avoid copying large scratch buffers on the stack.
        object_pools.ObjectPools.init(&context_storage.pools);
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

    /// Initialize home directory using the canonical path resolver.
    /// get_home_path falls back to "." when HOME/USERPROFILE is unset, so the
    /// only failure modes here are an empty env var or one exceeding the buffer.
    fn init_home_directory(context_storage: *CliContext) !void {
        const home = paths.get_home_path(&context_storage.home_dir_buffer) catch |err| {
            log.err("Failed to resolve home directory: {s}", .{@errorName(err)});
            return err;
        };

        assert(home.len > 0);
        assert(home.len <= context_storage.home_dir_buffer.len);
        assert(home.len <= limits.limits.home_dir_length_maximum);

        context_storage.home_dir_length = @intCast(home.len);

        assert(context_storage.home_dir_length == home.len);
        assert(context_storage.home_dir_length > 0);
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

    /// Get a scoped path scratch buffer from the static pool.
    pub fn scratch_path(self: *CliContext) !PathScratch {
        return .{ .buffer = try self.pools.acquire_path_buffer() };
    }

    /// Get a scoped HTTP scratch operation from the static pool.
    pub fn scratch_http(self: *CliContext) !HttpScratch {
        return .{ .operation = try self.pools.acquire_http_operation() };
    }

    /// Get a scoped extract scratch operation from the static pool.
    pub fn scratch_extract(self: *CliContext) !ExtractScratch {
        return .{ .operation = try self.pools.acquire_extract_operation() };
    }

    /// Get a version entry from the pool.
    pub fn acquire_version_entry(self: *CliContext) !*object_pools.VersionEntry {
        return self.pools.acquire_version_entry();
    }

    /// Build a ZVM path using a path buffer.
    /// Delegates to the canonical path resolver in platform/paths.zig.
    pub fn build_zvm_path(self: *CliContext, segment: []const u8) ![]const u8 {
        assert(segment.len > 0);
        assert(segment.len < limits.limits.path_length_maximum / 2);

        // Resolve zvm_root into a stack buffer to avoid aliasing with path_buffer.
        var zvm_root_buf: [limits.limits.path_length_maximum]u8 = undefined;
        const zvm_root = try paths.get_zvm_root(&zvm_root_buf, self.get_home_dir());

        var path_buffer = try self.scratch_path();
        defer path_buffer.release();

        const path = try path_buffer.print("{s}/{s}", .{ zvm_root, segment });

        assert(path.len > 0);
        assert(path.len <= limits.limits.path_length_maximum);

        return path;
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
        var stderr_writer = std.Io.File.stderr().writer(self.io, &buffer);
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
