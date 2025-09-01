const std = @import("std");
const util_tool = @import("../util/tool.zig");
const Context = @import("../Context.zig");

const log = std.log.scoped(.detect_version);

pub const VersionSource = enum {
    command_line,
    build_zig_zon,
    current,
};

pub const SmartVersionResult = struct {
    version: []const u8,
    source: VersionSource,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const SmartVersionResult) void {
        if (self.source == .build_zig_zon) {
            self.allocator.free(self.version);
        }
    }
};

pub fn detect_version(ctx: *Context.CliContext, args: []const []const u8) !SmartVersionResult {
    if (args.len > 0 and is_version_string(args[0])) {
        return SmartVersionResult{
            .version = args[0],
            .source = .command_line,
            .allocator = ctx.get_allocator(),
        };
    }

    if (try find_build_zig_zon_version(ctx)) |version| {
        return SmartVersionResult{
            .version = version,
            .source = .build_zig_zon,
            .allocator = ctx.get_allocator(),
        };
    }

    // Check if user has set a default version with 'zvm use'
    if (try find_default_version(ctx)) |default_version| {
        if (!is_ci_environment()) {
            log.info("No build.zig.zon found. Using default version: {s}", .{default_version});
        }
        return SmartVersionResult{
            .version = default_version,
            .source = .current,
            .allocator = ctx.get_allocator(),
        };
    }

    if (!is_ci_environment()) {
        log.info("No build.zig.zon found. Defaulting to master version.", .{});
        log.info("Consider creating build.zig.zon with 'minimum_zig_version' field for reproducible builds.", .{});
    }

    // Default to master when no build.zig.zon found and no default set
    return SmartVersionResult{
        .version = "master",
        .source = .current,
        .allocator = ctx.get_allocator(),
    };
}

pub fn is_version_string(arg: []const u8) bool {
    if (util_tool.eql_str(arg, "master")) return true;
    if (util_tool.eql_str(arg, "latest")) return true;

    var parts = std.mem.splitSequence(u8, arg, ".");
    var part_count: u32 = 0;
    while (parts.next()) |part| {
        part_count += 1;
        if (part_count > 3) return false;

        if (part.len == 0) return false;
        for (part) |c| {
            if (!std.ascii.isDigit(c) and c != '-' and !std.ascii.isAlphabetic(c)) return false;
        }
    }

    return part_count >= 2;
}

fn find_build_zig_zon_version(ctx: *Context.CliContext) !?[]const u8 {
    var current_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_dir = std.process.getCwd(&current_dir_buf) catch return null;

    var search_dir: []const u8 = current_dir;
    while (true) {
        var path_buf = try ctx.acquire_path_buffer();
        defer path_buf.reset();

        var stream = std.io.fixedBufferStream(path_buf.slice());
        try stream.writer().print("{s}/build.zig.zon", .{search_dir});
        const build_zon_path = try path_buf.set(stream.getWritten());

        if (try parse_build_zig_zon(ctx, build_zon_path)) |version| {
            return version;
        }

        const parent = std.fs.path.dirname(search_dir) orelse break;
        if (util_tool.eql_str(parent, search_dir)) break;
        search_dir = parent;
    }

    return null;
}

fn parse_build_zig_zon(ctx: *Context.CliContext, path: []const u8) !?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const json_buffer = ctx.get_json_buffer();
    const bytes_read = file.readAll(json_buffer) catch return null;
    const content = json_buffer[0..bytes_read];

    const allocator = ctx.get_json_allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return try parse_build_zig_zon_manual(ctx, content);
    };
    defer parsed.deinit();

    if (parsed.value.object.get("minimum_zig_version")) |version_value| {
        if (version_value == .string) {
            const version = try ctx.get_allocator().dupe(u8, version_value.string);
            return version;
        }
    }

    return null;
}

pub fn parse_build_zig_zon_manual(ctx: *Context.CliContext, content: []const u8) !?[]const u8 {
    const needle = "minimum_zig_version";
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, pos, needle)) |found_pos| {
        pos = found_pos + needle.len;

        var i = pos;
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (i >= content.len or content[i] != '=') continue;
        i += 1;

        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (i >= content.len or content[i] != '"') continue;
        i += 1;

        const start = i;
        while (i < content.len and content[i] != '"') i += 1;
        if (i >= content.len) continue;

        const version_str = content[start..i];
        if (version_str.len > 0) {
            return try ctx.get_allocator().dupe(u8, version_str);
        }
    }

    return null;
}

pub fn adjust_arguments(version: []const u8, original_args: []const []const u8, adjusted_args: *std.ArrayList([]const u8)) !void {
    if (util_tool.eql_str(version, "current")) {
        try adjusted_args.appendSlice(original_args);
        return;
    }

    if (original_args.len > 0 and is_version_string(original_args[0])) {
        try adjusted_args.appendSlice(original_args[1..]);
    } else {
        try adjusted_args.appendSlice(original_args);
    }
}

pub fn adjust_arguments_to_buffer(version: []const u8, original_args: []const []const u8, buffer: [][]const u8, count: *usize) !void {
    count.* = 0;

    if (util_tool.eql_str(version, "current")) {
        for (original_args) |arg| {
            if (count.* >= buffer.len) return error.TooManyArguments;
            buffer[count.*] = arg;
            count.* += 1;
        }
        return;
    }

    const skip_first = original_args.len > 0 and is_version_string(original_args[0]);
    const start_idx = if (skip_first) @as(usize, 1) else @as(usize, 0);

    for (original_args[start_idx..]) |arg| {
        if (count.* >= buffer.len) return error.TooManyArguments;
        buffer[count.*] = arg;
        count.* += 1;
    }
}

pub fn ensure_version_available(ctx: *Context.CliContext, version: []const u8) !bool {
    if (util_tool.eql_str(version, "current")) return true;

    const version_path = try build_version_path(ctx, version);
    defer ctx.get_allocator().free(version_path);

    // Check if the directory exists first
    if (!util_tool.does_path_exist(version_path)) {
        return false;
    }

    // Check if the actual zig executable exists
    var zig_path_buffer = try ctx.acquire_path_buffer();
    defer zig_path_buffer.reset();

    var stream = std.io.fixedBufferStream(zig_path_buffer.slice());
    try stream.writer().print("{s}/zig", .{version_path});
    const zig_path = try zig_path_buffer.set(stream.getWritten());

    return util_tool.does_path_exist(zig_path);
}

pub fn auto_install_version(ctx: *Context.CliContext, version: []const u8) !void {
    if (util_tool.eql_str(version, "current")) return;

    const install = @import("install.zig");
    const progress = std.Progress.start(.{
        .root_name = "auto-install",
        .estimated_total_items = 5,
    });
    defer progress.end();

    try install.install(ctx, version, false, progress);
}

fn build_version_path(ctx: *Context.CliContext, version: []const u8) ![]const u8 {
    var buffer = try ctx.acquire_path_buffer();
    defer buffer.reset();

    var stream = std.io.fixedBufferStream(buffer.slice());
    const home_dir = ctx.get_home_dir();

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try stream.writer().print("{s}/.zm/version/zig/{s}", .{ xdg_data, version });
    } else {
        try stream.writer().print("{s}/.local/share/.zm/version/zig/{s}", .{ home_dir, version });
    }

    const path = try buffer.set(stream.getWritten());
    return try ctx.get_allocator().dupe(u8, path);
}

pub fn is_ci_environment() bool {
    const ci_vars = [_][]const u8{
        "CI",
        "GITHUB_ACTIONS",
        "JENKINS_URL",
        "TRAVIS",
        "CIRCLECI",
        "GITLAB_CI",
        "BUILDKITE",
        "TEAMCITY_VERSION",
        "TF_BUILD",
        "APPVEYOR",
        "CONTINUOUS_INTEGRATION",
    };

    for (ci_vars) |var_name| {
        if (util_tool.getenv_cross_platform(var_name)) |_| {
            return true;
        }
    }

    return false;
}

fn find_default_version(ctx: *Context.CliContext) !?[]const u8 {
    // Look for a default version config file
    var config_path_buffer = try ctx.acquire_path_buffer();
    defer config_path_buffer.reset();

    const home_dir = ctx.get_home_dir();
    var stream = std.io.fixedBufferStream(config_path_buffer.slice());

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try stream.writer().print("{s}/.zm/default_version", .{xdg_data});
    } else {
        try stream.writer().print("{s}/.local/share/.zm/default_version", .{home_dir});
    }

    const config_path = try config_path_buffer.set(stream.getWritten());

    const file = std.fs.cwd().openFile(config_path, .{}) catch return null;
    defer file.close();

    var version_buffer: [32]u8 = undefined;
    const bytes_read = file.readAll(&version_buffer) catch return null;
    if (bytes_read == 0) return null;

    // Trim whitespace
    const content = std.mem.trim(u8, version_buffer[0..bytes_read], " \t\n\r");
    if (content.len == 0) return null;

    return try ctx.get_allocator().dupe(u8, content);
}

fn log_version_suggestion() void {
    log.info("No build.zig.zon found. Consider creating one with 'minimum_zig_version' field, or specify version on command line (e.g., 'zig 0.13.0 build')", .{});
}

fn would_cause_infinite_loop(ctx: *Context.CliContext) !bool {
    // Check if current/zig symlink points to zvm binary (which would cause infinite loop)
    var current_zig_path_buffer = try ctx.acquire_path_buffer();
    defer current_zig_path_buffer.reset();

    var stream = std.io.fixedBufferStream(current_zig_path_buffer.slice());
    const home_dir = ctx.get_home_dir();

    if (util_tool.getenv_cross_platform("XDG_DATA_HOME")) |xdg_data| {
        try stream.writer().print("{s}/.zm/current/zig", .{xdg_data});
    } else {
        try stream.writer().print("{s}/.local/share/.zm/current/zig", .{home_dir});
    }

    const current_zig_path = try current_zig_path_buffer.set(stream.getWritten());

    // Check if symlink exists and where it points
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = std.fs.readLinkAbsolute(current_zig_path, &link_buffer) catch |err| switch (err) {
        error.FileNotFound => return true, // No default set
        else => return false, // Any other error means it's probably not a symlink to zvm
    };

    // Check if it points to zvm binary (indicates smart detection mode without default)
    return std.mem.endsWith(u8, link_target, "/zvm") or std.mem.endsWith(u8, link_target, "\\zvm");
}

// Tests
const testing = std.testing;

test "is_version_string - valid versions" {
    const valid_versions = [_][]const u8{
        "0.11.0",
        "0.12.1",
        "1.0.0",
        "master",
        "latest",
        "0.14.0-dev.3028+cdc9d65b0",
        "0.13.0",
        "0.15.1",
    };

    for (valid_versions) |version| {
        try testing.expect(is_version_string(version));
    }
}

test "is_version_string - invalid versions" {
    const invalid_versions = [_][]const u8{
        "build-exe",
        "run",
        "test",
        "version",
        "help",
        "myproject.zig",
        "",
        "0",
        "a.b.c",
        "0.11",
        "0.11.0.0.0",
    };

    for (invalid_versions) |version| {
        try testing.expect(!is_version_string(version));
    }
}

test "CI environment detection" {
    // Test the function executes without error
    // We can't reliably test the actual environment detection
    // since the test might be running in CI
    const result = is_ci_environment();
    _ = result; // Just verify it runs without error
}

test "adjust_arguments - with version prefix" {
    var adjusted_args = std.ArrayList([]const u8).init(testing.allocator);
    defer adjusted_args.deinit();

    const original_args = [_][]const u8{ "0.13.0", "build-exe", "main.zig" };
    const version = "0.13.0";

    try adjust_arguments(version, original_args[0..], &adjusted_args);

    try testing.expectEqual(@as(usize, 2), adjusted_args.items.len);
    try testing.expectEqualStrings("build-exe", adjusted_args.items[0]);
    try testing.expectEqualStrings("main.zig", adjusted_args.items[1]);
}

test "adjust_arguments - without version prefix" {
    var adjusted_args = std.ArrayList([]const u8).init(testing.allocator);
    defer adjusted_args.deinit();

    const original_args = [_][]const u8{ "build-exe", "main.zig" };
    const version = "0.13.0";

    try adjust_arguments(version, original_args[0..], &adjusted_args);

    try testing.expectEqual(@as(usize, 2), adjusted_args.items.len);
    try testing.expectEqualStrings("build-exe", adjusted_args.items[0]);
    try testing.expectEqualStrings("main.zig", adjusted_args.items[1]);
}

test "adjust_arguments - current version passthrough" {
    var adjusted_args = std.ArrayList([]const u8).init(testing.allocator);
    defer adjusted_args.deinit();

    const original_args = [_][]const u8{ "build-exe", "main.zig" };
    const version = "current";

    try adjust_arguments(version, original_args[0..], &adjusted_args);

    try testing.expectEqual(@as(usize, 2), adjusted_args.items.len);
    try testing.expectEqualStrings("build-exe", adjusted_args.items[0]);
    try testing.expectEqualStrings("main.zig", adjusted_args.items[1]);
}

test "parse_build_zig_zon_manual - valid format" {
    const zon_content =
        \\.{
        \\    .name = "myproject",
        \\    .version = "0.1.0", 
        \\    .minimum_zig_version = "0.13.0",
        \\    .dependencies = .{},
        \\}
    ;

    var mock_ctx = MockContext.init();
    defer mock_ctx.deinit();

    const result = try parse_build_zig_zon_manual(&mock_ctx, zon_content);

    if (result) |version| {
        defer mock_ctx.allocator.free(version);
        try testing.expectEqualStrings("0.13.0", version);
    } else {
        try testing.expect(false); // Should have found version
    }
}

test "parse_build_zig_zon_manual - missing version" {
    const zon_content =
        \\.{
        \\    .name = "myproject",
        \\    .version = "0.1.0",
        \\    .dependencies = .{},
        \\}
    ;

    var mock_ctx = MockContext.init();
    defer mock_ctx.deinit();

    const result = try parse_build_zig_zon_manual(&mock_ctx, zon_content);
    try testing.expectEqual(@as(?[]const u8, null), result);
}

// Mock context for testing
const MockContext = struct {
    allocator: std.mem.Allocator,

    fn init() MockContext {
        return MockContext{
            .allocator = testing.allocator,
        };
    }

    fn deinit(self: MockContext) void {
        _ = self;
    }

    fn get_allocator(self: *MockContext) std.mem.Allocator {
        return self.allocator;
    }

    fn get_json_allocator(self: *MockContext) std.mem.Allocator {
        return self.allocator;
    }

    fn get_json_buffer(self: *MockContext) []u8 {
        _ = self;
        const buffer: []u8 = testing.allocator.alloc(u8, 4096) catch @panic("Failed to allocate test buffer");
        return buffer;
    }

    fn acquire_path_buffer(self: *MockContext) !*MockPathBuffer {
        _ = self;
        const buffer = try testing.allocator.create(MockPathBuffer);
        buffer.* = MockPathBuffer.init();
        return buffer;
    }
};

const MockPathBuffer = struct {
    buffer: [4096]u8,
    used: usize,

    fn init() MockPathBuffer {
        return MockPathBuffer{
            .buffer = std.mem.zeroes([4096]u8),
            .used = 0,
        };
    }

    fn slice(self: *MockPathBuffer) []u8 {
        return self.buffer[0..];
    }

    fn set(self: *MockPathBuffer, content: []const u8) ![]const u8 {
        @memcpy(self.buffer[0..content.len], content);
        self.used = content.len;
        return self.buffer[0..content.len];
    }

    fn reset(self: *MockPathBuffer) void {
        self.used = 0;
        testing.allocator.destroy(self);
    }
};
