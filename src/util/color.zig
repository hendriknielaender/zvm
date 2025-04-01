// color.zig
const std = @import("std");

pub const Color = struct {
    /// Compile-Time Style Struct
    pub const ComptimeStyle = struct {
        open: []const u8 = "",
        close: []const u8 = "",
        preset: bool = false,

        pub inline fn fmt(self: *ComptimeStyle, comptime text: []const u8) []const u8 {
            defer self.removeAll();
            return self.open ++ text ++ self.close;
        }

        pub inline fn print(self: *ComptimeStyle, comptime text: []const u8) !void {
            defer self.removeAll();
            const formatted_text = self.fmt(text);
            try std.io.getStdOut().writer().print("{s}", .{formatted_text});
        }

        pub inline fn printErr(self: *ComptimeStyle, comptime text: []const u8) !void {
            defer self.removeAll();
            const formatted_text = self.fmt(text);
            try std.io.getStdErr().writer().print("{s}", .{formatted_text});
        }

        pub inline fn add(self: *ComptimeStyle, comptime style_code: []const u8) *ComptimeStyle {
            self.open = self.open ++ style_code;
            self.close = "\x1b[0m" ++ self.close;
            return self;
        }

        inline fn removeAll(self: *ComptimeStyle) void {
            if (self.preset) return;
            self.open = "";
            self.close = "";
        }

        // Style methods
        pub inline fn bold(self: *ComptimeStyle) *ComptimeStyle {
            return self.add("\x1b[1m");
        }

        pub inline fn red(self: *ComptimeStyle) *ComptimeStyle {
            return self.add("\x1b[31m");
        }

        pub inline fn green(self: *ComptimeStyle) *ComptimeStyle {
            return self.add("\x1b[32m");
        }

        pub inline fn magenta(self: *ComptimeStyle) *ComptimeStyle {
            return self.add("\x1b[35m");
        }

        pub inline fn cyan(self: *ComptimeStyle) *ComptimeStyle {
            return self.add("\x1b[36m");
        }

        /// Initializes a new ComptimeStyle instance.
        pub inline fn init() ComptimeStyle {
            return ComptimeStyle{};
        }
    };

    /// Runtime Style Struct
    pub const RuntimeStyle = struct {
        open: std.ArrayList(u8),
        close: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        /// Initializes a new RuntimeStyle instance.
        pub fn init(allocator: std.mem.Allocator) !RuntimeStyle {
            return RuntimeStyle{
                .open = std.ArrayList(u8).init(allocator),
                .close = std.ArrayList(u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *RuntimeStyle) void {
            self.open.deinit();
            self.close.deinit();
        }

        /// Adds a style code to the Style instance.
        pub fn addStyle(self: *RuntimeStyle, style_code: []const u8) *RuntimeStyle {
            // Ignore allocation errors for simplicity
            self.open.appendSlice(style_code) catch |err| {
                std.log.warn("Failed to append style code: {}", .{err});
            };
            // For correct closure, we need to append the corresponding reset code
            self.close.appendSlice("\x1b[0m") catch |err| {
                std.log.warn("Failed to append reset code: {}", .{err});
            };
            return self;
        }

        fn removeAll(self: *RuntimeStyle) void {
            self.open.clearAndFree();
            self.close.clearAndFree();
        }

        /// Returns the formatted text with styles applied.
        pub fn fmt(self: *RuntimeStyle, comptime format: []const u8, args: anytype) ![]u8 {
            defer self.removeAll();

            const formatted = try std.fmt.allocPrint(self.allocator, format, args);

            defer self.allocator.free(formatted);
            return std.mem.concat(self.allocator, u8, &.{ self.open.items, formatted, self.close.items });
        }

        /// Prints the formatted text to stdout.
        pub fn print(self: *RuntimeStyle, comptime format: []const u8, args: anytype) !void {
            defer self.removeAll();

            const formatted_text = try self.fmt(format, args);
            defer self.allocator.free(formatted_text);
            try std.io.getStdOut().writer().print("{s}", .{formatted_text});
        }

        /// Prints the formatted text to stderr.
        pub fn printErr(self: *RuntimeStyle, comptime format: []const u8, args: anytype) !void {
            defer self.removeAll();

            const formatted_text = try self.fmt(format, args);
            defer self.allocator.free(formatted_text);
            try std.io.getStdErr().writer().print("{s}", .{formatted_text});
        }

        // Style methods
        pub fn bold(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[1m");
        }

        pub fn red(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[31m");
        }

        pub fn green(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[32m");
        }

        pub fn magenta(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[35m");
        }

        pub fn cyan(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[36m");
        }

        /// Creates a preset RuntimeStyle.
        pub fn createPreset(self: *RuntimeStyle) !RuntimeStyle {
            defer self.removeAll();

            return RuntimeStyle{
                .open = try self.open.clone(self.allocator.*),
                .close = try self.close.clone(self.allocator.*),
                .allocator = self.allocator,
            };
        }
    };
};
