// color.zig
const std = @import("std");
const limits = @import("../limits.zig");

pub const Color = struct {
    /// Compile-Time Style Struct
    pub const ComptimeStyle = struct {
        open: []const u8 = "",
        close: []const u8 = "",
        preset: bool = false,

        pub inline fn format(self: *ComptimeStyle, comptime text: []const u8) []const u8 {
            defer self.removeAll();
            return self.open ++ text ++ self.close;
        }

        pub inline fn print(self: *ComptimeStyle, comptime text: []const u8) !void {
            defer self.removeAll();
            const formatted_text = self.format(text);
            try std.io.getStdOut().writer().print("{s}", .{formatted_text});
        }

        pub inline fn printErr(self: *ComptimeStyle, comptime text: []const u8) !void {
            defer self.removeAll();
            const formatted_text = self.format(text);
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

    /// Runtime Style Struct - Now using static allocation!
    pub const RuntimeStyle = struct {
        /// Maximum style codes that can be applied.
        const max_style_codes = 16;
        /// Maximum length for style escape sequences.
        const style_buffer_size = 256;

        open_buffer: [style_buffer_size]u8 = undefined,
        open_len: u32 = 0,
        close_buffer: [style_buffer_size]u8 = undefined,
        close_len: u32 = 0,
        format_buffer: [limits.limits.format_buffer_size_maximum]u8 = undefined,

        /// Initializes a new RuntimeStyle instance.
        pub fn init() RuntimeStyle {
            return RuntimeStyle{};
        }

        /// Adds a style code to the Style instance.
        pub fn addStyle(self: *RuntimeStyle, style_code: []const u8) *RuntimeStyle {
            // Check if style code fits in open buffer
            const new_open_len = self.open_len + style_code.len;
            if (new_open_len > self.open_buffer.len) {
                // Style code doesn't fit, skip adding it
                return self;
            }

            // Add to open buffer
            @memcpy(self.open_buffer[self.open_len..new_open_len], style_code);
            self.open_len = @intCast(new_open_len);

            // Check if reset code fits in close buffer
            const reset_code = "\x1b[0m";
            const new_close_len = self.close_len + reset_code.len;
            if (new_close_len > self.close_buffer.len) {
                // Reset code doesn't fit, skip adding it
                return self;
            }

            // Add reset code to close buffer
            @memcpy(self.close_buffer[self.close_len..new_close_len], reset_code);
            self.close_len = @intCast(new_close_len);

            return self;
        }

        fn removeAll(self: *RuntimeStyle) void {
            self.open_len = 0;
            self.close_len = 0;
        }

        /// Returns the formatted text with styles applied.
        pub fn format(self: *RuntimeStyle, comptime format_string: []const u8, args: anytype) ![]u8 {
            defer self.removeAll();

            // Use a temporary buffer for initial formatting to avoid aliasing
            var temp_buffer: [1024]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&temp_buffer, format_string, args);

            // Calculate total size needed.
            const total_len = self.open_len + formatted.len + self.close_len;
            if (total_len > self.format_buffer.len) return error.BufferTooSmall;

            // Build the final string in format_buffer.
            var result_len: usize = 0;

            // Copy open codes.
            @memcpy(self.format_buffer[0..self.open_len], self.open_buffer[0..self.open_len]);
            result_len += self.open_len;

            // Copy formatted text.
            @memcpy(self.format_buffer[result_len .. result_len + formatted.len], formatted);
            result_len += formatted.len;

            // Copy close codes.
            @memcpy(self.format_buffer[result_len .. result_len + self.close_len], self.close_buffer[0..self.close_len]);
            result_len += self.close_len;

            return self.format_buffer[0..result_len];
        }

        /// Prints the formatted text to stdout.
        pub fn print(self: *RuntimeStyle, comptime format_string: []const u8, args: anytype) !void {
            const formatted_text = try self.format(format_string, args);
            try std.io.getStdOut().writer().print("{s}", .{formatted_text});
        }

        /// Prints the formatted text to stderr.
        pub fn printErr(self: *RuntimeStyle, comptime format_string: []const u8, args: anytype) !void {
            const formatted_text = try self.format(format_string, args);
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

        pub fn yellow(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[33m");
        }

        pub fn white(self: *RuntimeStyle) *RuntimeStyle {
            return self.addStyle("\x1b[37m");
        }
    };
};
