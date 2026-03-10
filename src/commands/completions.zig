const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");

const zsh_script =
    \\#compdef zvm
    \\
    \\# ZVM top-level commands
    \\local -a _zvm_commands
    \\_zvm_commands=(
    \\  'list:List installed Zig versions'
    \\  'list-remote:List available Zig/ZLS versions for download'
    \\  'install:Install a version of Zig or ZLS'
    \\  'use:Switch to a specific Zig or ZLS version'
    \\  'remove:Remove an installed Zig or ZLS version'
    \\  'env:Show environment setup instructions'
    \\  'clean:Clean up old download artifacts'
    \\  'completions:Generate shell completion script'
    \\  'version:Show zvm version'
    \\  'help:Show help message'
    \\)
    \\
    \\_arguments \
    \\  '1: :->cmds' \
    \\  '*:: :->args'
    \\
    \\case $state in
    \\  cmds)
    \\    _describe -t commands "zvm command" _zvm_commands
    \\  ;;
    \\  args)
    \\    case $line[1] in
    \\      install|use|remove)
    \\        _arguments \
    \\          '1:version:' \
    \\          '--zls[Apply to ZLS instead of Zig]'
    \\        ;;
    \\      list)
    \\        _arguments \
    \\          '--all[List Zig and ZLS versions together]'
    \\        ;;
    \\      list-remote)
    \\        _arguments \
    \\          '--zls[List ZLS versions instead of Zig]'
    \\        ;;
    \\      clean)
    \\        _arguments \
    \\          '--all[Also remove unused versions]'
    \\        ;;
    \\      env)
    \\        _arguments \
    \\          '--shell[Specify shell]:shell:(bash zsh fish powershell)'
    \\        ;;
    \\      completions)
    \\        _arguments \
    \\          '1:shell:(bash zsh fish powershell)'
    \\        ;;
    \\    esac
    \\  ;;
    \\esac
;

const bash_script =
    \\#!/usr/bin/env bash
    \\# zvm Bash completion
    \\
    \\_zvm_completions() {
    \\    local cur prev words cword
    \\    _init_completion || return
    \\
    \\    local commands="list list-remote install use remove env clean completions version help"
    \\
    \\    if [[ $cword -eq 1 ]]; then
    \\        COMPREPLY=( $( compgen -W "$commands" -- "$cur" ) )
    \\    else
    \\        case "${words[1]}" in
    \\            install|use|remove)
    \\                if [[ $cur == -* ]]; then
    \\                    COMPREPLY=( $( compgen -W "--zls" -- "$cur" ) )
    \\                fi
    \\                ;;
    \\            list)
    \\                COMPREPLY=( $( compgen -W "--all" -- "$cur" ) )
    \\                ;;
    \\            list-remote)
    \\                COMPREPLY=( $( compgen -W "--zls" -- "$cur" ) )
    \\                ;;
    \\            clean)
    \\                COMPREPLY=( $( compgen -W "--all" -- "$cur" ) )
    \\                ;;
    \\            env)
    \\                if [[ $prev == "--shell" ]]; then
    \\                    COMPREPLY=( $( compgen -W "bash zsh fish powershell" -- "$cur" ) )
    \\                else
    \\                    COMPREPLY=( $( compgen -W "--shell" -- "$cur" ) )
    \\                fi
    \\                ;;
    \\            completions)
    \\                if [[ $cword -eq 2 ]]; then
    \\                    COMPREPLY=( $( compgen -W "bash zsh fish powershell" -- "$cur" ) )
    \\                fi
    \\                ;;
    \\        esac
    \\    fi
    \\}
    \\
    \\complete -F _zvm_completions zvm
;

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CompletionsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = progress_node;

    const shell_name = @tagName(command.shell);
    const script = switch (command.shell) {
        .zsh => zsh_script,
        .bash => bash_script,
        .fish => util_output.fatal(
            .invalid_arguments,
            "Fish shell completions are not implemented",
            .{},
        ),
        .powershell => util_output.fatal(
            .invalid_arguments,
            "PowerShell completions are not implemented",
            .{},
        ),
    };

    const emitter = util_output.get_global();
    if (emitter.config.mode == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "shell", .value = .{ .string = shell_name } },
            .{ .key = "script", .value = .{ .string = script } },
        };
        util_output.json_object(&fields);
        return;
    }

    util_output.print_text(script);
}
