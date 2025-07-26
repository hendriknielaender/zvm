/// Raw command-line arguments as parsed from argv
/// This union ensures type safety at compile time - each command has exactly the fields it needs
pub const CLIArgs = union(enum) {
    pub const List = struct {
        /// List all available versions including unreleased/master
        list_all: bool = false,
        /// Show available mirrors
        show_mirrors: bool = false,
        /// Enable debug output
        debug: bool = false,
    };

    pub const Install = struct {
        /// Install as system-wide version
        system: bool = false,
        /// Use specific mirror index
        mirror: ?u32 = null,
        /// Show available mirrors
        show_mirrors: bool = false,
        /// Enable debug output
        debug: bool = false,
        /// Version to install (master, latest, or specific version)
        positional: struct {
            version: []const u8 = &[_]u8{},
        },
    };

    pub const Use = struct {
        /// Set as system-wide version
        system: bool = false,
        /// Enable debug output
        debug: bool = false,
        /// Version to use
        positional: struct {
            version: []const u8 = &[_]u8{},
        },
    };

    pub const Remove = struct {
        /// Enable debug output
        debug: bool = false,
        /// Version to remove
        positional: struct {
            version: []const u8 = &[_]u8{},
        },
    };

    pub const Clean = struct {
        /// Enable debug output
        debug: bool = false,
    };

    pub const Version = struct {
        /// Show verbose version info
        verbose: bool = false,
    };

    pub const Help = struct {};

    pub const Completions = struct {
        /// Shell type (bash, zsh, fish, powershell)
        positional: struct {
            shell: ?[]const u8 = null,
        },
    };

    // Command variants
    list: List,
    install: Install,
    use: Use,
    remove: Remove,
    clean: Clean,
    version: Version,
    help: Help,
    completions: Completions,

    // Aliases (handled in the parser)
    // ls -> list
    // i -> install
    // u -> use
    // rm -> remove

    /// Help text for the CLI
    pub const help_text =
        \\zvm - Zig Version Manager
        \\
        \\Usage:
        \\  zvm <command> [options]
        \\
        \\Commands:
        \\  list, ls              List installed Zig versions
        \\  install, i <version>  Install a Zig version
        \\  use, u <version>      Set active Zig version
        \\  remove, rm <version>  Remove an installed Zig version
        \\  clean                 Remove all installed versions except current
        \\  version               Show zvm version
        \\  help                  Show this help message
        \\  completions [shell]   Generate shell completions
        \\
        \\Install Options:
        \\  <version>            Version to install (master, latest, or x.y.z)
        \\  --system             Install as system-wide version
        \\  --mirror=<index>     Use specific mirror
        \\  --show-mirrors       Show available mirrors
        \\
        \\List Options:
        \\  --list-all           Show all available versions
        \\  --show-mirrors       Show available mirrors
        \\
        \\Use Options:
        \\  --system             Set as system-wide version
        \\
        \\Global Options:
        \\  --debug              Enable debug output
        \\  --help, -h           Show help for a command
        \\
        \\Examples:
        \\  zvm install master              Install latest master build
        \\  zvm install 0.11.0              Install specific version
        \\  zvm use 0.11.0                  Switch to version 0.11.0
        \\  zvm list                        List installed versions
        \\  zvm list --list-all             List all available versions
        \\  zvm install 0.11.0 --system     Install system-wide
        \\
        \\Environment Variables:
        \\  ZVM_HOME             Override default zvm directory (~/.zm)
        \\  ZVM_MIRROR           Set default mirror index
        \\
    ;
};
