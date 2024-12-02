// color.zig
const std = @import("std");

pub const Style = struct {
    open: []const u8 = "",
    close: []const u8 = "",
    preset: bool = false,

    /// Returns the formatted text.
    pub inline fn fmt(self: *Style, comptime text: []const u8) []const u8 {
        defer self.removeAll();
        return self.open ++ text ++ self.close;
    }

    /// Print the formatted text to stdout.
    pub inline fn printOut(self: *Style, comptime text: []const u8, args: anytype) !void {
        defer self.removeAll();
        return std.io.getStdOut().writer().print(self.fmt(text), args);
    }

    /// Applies a style code.
    pub inline fn add(self: *Style, comptime style_code: []const u8) *Style {
        self.open = self.open ++ style_code;
        self.close = "\x1b[0m" ++ self.close;
        return self;
    }

    inline fn removeAll(self: *Style) void {
        if (self.preset) return;
        self.open = "";
        self.close = "";
    }

    pub inline fn bold(self: *Style) *Style {
        return self.add("\x1b[1m");
    }

    pub inline fn magenta(self: *Style) *Style {
        return self.add("\x1b[35m");
    }

    pub inline fn red(self: *Style) *Style {
        return self.add("\x1b[31m");
    }

    pub inline fn green(self: *Style) *Style {
        return self.add("\x1b[32m");
    }

    pub inline fn cyan(self: *Style) *Style {
        return self.add("\x1b[36m");
    }

    /// Initializes a new Style instance for compile-time use.
    pub inline fn init() Style {
        return Style{};
    }
};
