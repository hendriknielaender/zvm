const diagnostics = @import("output/diagnostics.zig");
const emitter = @import("output/emitter.zig");
const exit_code = @import("output/exit_code.zig");
const json = @import("output/json.zig");
const mode = @import("output/mode.zig");

pub const ColorMode = mode.ColorMode;
pub const ExitCode = exit_code.ExitCode;
pub const JsonArrayFieldName = json.JsonArrayFieldName;
pub const JsonField = json.JsonField;
pub const JsonPayload = json.JsonPayload;
pub const MessageLevel = emitter.MessageLevel;
pub const OutputConfig = mode.OutputConfig;
pub const OutputMode = mode.OutputMode;
pub const VerboseLevel = diagnostics.VerboseLevel;

pub const debug_enabled = diagnostics.debug_enabled;
pub const emit = emitter.emit;
pub const emit_json = emitter.emit_json;
pub const exit_with = emitter.exit_with;
pub const is_global_initialized = emitter.is_global_initialized;
pub const output_mode = emitter.output_mode;
pub const resolve_color_mode = mode.resolve_color_mode;
pub const set_mode = emitter.set_mode;
pub const set_verbose_level = diagnostics.set_verbose_level;
pub const stderr_is_terminal = mode.stderr_is_terminal;
pub const stdout_is_terminal = mode.stdout_is_terminal;
pub const trace = diagnostics.trace;
