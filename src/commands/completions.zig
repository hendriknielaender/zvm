const std = @import("std");
const context = @import("../context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../validation.zig");
const limits = @import("../limits.zig");

pub fn execute(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CompletionsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = progress_node;

    switch (command.shell) {
        .zsh => try print_zsh_completions(),
        .bash => try print_bash_completions(),
        .fish => {
            util_output.err("Fish shell completions not yet implemented", .{});
            return error.NotImplemented;
        },
        .powershell => {
            util_output.err("PowerShell completions not yet implemented", .{});
            return error.NotImplemented;
        },
    }
}

fn print_zsh_completions() !void {
    const io_buffer_size = limits.limits.io_buffer_size_maximum;
    var buffer: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &buffer);
    const out = &stdout_writer.interface;

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
        \\  'current:Show current Zig and ZLS versions'
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

    try out.print("{s}\n", .{zsh_script});
    try out.flush();
}

fn print_bash_completions() !void {
    const io_buffer_size = limits.limits.io_buffer_size_maximum;
    var buffer: [io_buffer_size]u8 = undefined;
    var stdout_writer = std.fs.File.Writer.init(std.fs.File.stdout(), &buffer);
    const out = &stdout_writer.interface;

    const bash_script =
        \\#!/usr/bin/env bash
        \\# zvm Bash completion
        \\
        \\_zvm_completions() {
        \\    local cur prev words cword
        \\    _init_completion || return
        \\
        \\    local commands="list list-remote install use remove current env clean completions version help"
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

    try out.print("{s}\n", .{bash_script});
    try out.flush();
}
