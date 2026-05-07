//! Zero-heap metadata parsing for Zig and ZLS release indexes.
const zig_parser = @import("meta/zig.zig");
const zls_parser = @import("meta/zls.zig");

pub const Zig = zig_parser.Zig;
pub const Zls = zls_parser.Zls;
