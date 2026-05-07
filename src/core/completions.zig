const std = @import("std");
const context = @import("../Context.zig");
const util_output = @import("../util/output.zig");
const validation = @import("../cli/validation.zig");
const cli_spec = @import("../cli/spec.zig");

const assert = std.debug.assert;

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
    \\  'list-mirrors:List configured download mirrors'
    \\  'upgrade:Upgrade zvm'
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
    \\          '--shell=[Specify shell]:shell:(bash zsh fish powershell)'
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
    \\    local commands="
++ cli_spec.primary_command_words ++
    \\"
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
    \\                if [[ $cur == --shell=* ]]; then
    \\                    local shell_prefix="${cur#--shell=}"
    \\                    COMPREPLY=( $( compgen -P "--shell=" -W "
++ cli_spec.shell_words ++
    \\" -- "$shell_prefix" ) )
    \\                else
    \\                    COMPREPLY=( $( compgen -W "--shell=" -- "$cur" ) )
    \\                fi
    \\                ;;
    \\            completions)
    \\                if [[ $cword -eq 2 ]]; then
    \\                    COMPREPLY=( $( compgen -W "
++ cli_spec.shell_words ++
    \\" -- "$cur" ) )
    \\                fi
    \\                ;;
    \\        esac
    \\    fi
    \\}
    \\
    \\complete -F _zvm_completions zvm
;

const fish_script =
    \\# zvm Fish completion
    \\
    \\function __zvm_no_subcommand
    \\    set -l cmd (commandline -opc)
    \\    if test (count $cmd) -eq 1
    \\        return 0
    \\    end
    \\    return 1
    \\end
    \\
    \\function __zvm_using_command
    \\    set -l cmd (commandline -opc)
    \\    if test (count $cmd) -ge 2
    \\        if test $cmd[2] = $argv[1]
    \\            return 0
    \\        end
    \\    end
    \\    return 1
    \\end
    \\
    \\complete -c zvm -f
    \\
    \\# Top-level commands.
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'list' -d 'List installed Zig versions'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'list-remote' -d 'List available Zig/ZLS versions for download'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'install' -d 'Install a version of Zig or ZLS'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'use' -d 'Switch to a specific Zig or ZLS version'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'remove' -d 'Remove an installed Zig or ZLS version'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'env' -d 'Show environment setup instructions'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'clean' -d 'Clean up old download artifacts'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'completions' -d 'Generate shell completion script'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'list-mirrors' -d 'List configured download mirrors'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'upgrade' -d 'Upgrade zvm'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'version' -d 'Show zvm version'
    \\complete -c zvm -n '__zvm_no_subcommand' -a 'help' -d 'Show help message'
    \\
    \\# Per-subcommand flags.
    \\complete -c zvm -n '__zvm_using_command install' -l zls -d 'Apply to ZLS instead of Zig'
    \\complete -c zvm -n '__zvm_using_command use' -l zls -d 'Apply to ZLS instead of Zig'
    \\complete -c zvm -n '__zvm_using_command remove' -l zls -d 'Apply to ZLS instead of Zig'
    \\complete -c zvm -n '__zvm_using_command list' -l all -d 'List Zig and ZLS versions together'
    \\complete -c zvm -n '__zvm_using_command list-remote' -l zls -d 'List ZLS versions instead of Zig'
    \\complete -c zvm -n '__zvm_using_command clean' -l all -d 'Also remove unused versions'
    \\complete -c zvm -n '__zvm_using_command env' -a '--shell=bash --shell=zsh --shell=fish --shell=powershell' -d 'Specify shell'
    \\complete -c zvm -n '__zvm_using_command completions' -xa '
++ cli_spec.shell_words ++
    \\'
;

const powershell_script =
    \\# zvm PowerShell completion
    \\#
    \\# To install, source this file from your PowerShell profile, e.g.
    \\#   zvm completions powershell | Out-String | Invoke-Expression
    \\
    \\Register-ArgumentCompleter -Native -CommandName zvm -ScriptBlock {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\
    \\    $commands = @(
    \\        @{ Name = 'list';        Description = 'List installed Zig versions' }
    \\        @{ Name = 'list-remote'; Description = 'List available Zig/ZLS versions for download' }
    \\        @{ Name = 'install';     Description = 'Install a version of Zig or ZLS' }
    \\        @{ Name = 'use';         Description = 'Switch to a specific Zig or ZLS version' }
    \\        @{ Name = 'remove';      Description = 'Remove an installed Zig or ZLS version' }
    \\        @{ Name = 'env';         Description = 'Show environment setup instructions' }
    \\        @{ Name = 'clean';       Description = 'Clean up old download artifacts' }
    \\        @{ Name = 'completions'; Description = 'Generate shell completion script' }
    \\        @{ Name = 'list-mirrors';Description = 'List configured download mirrors' }
    \\        @{ Name = 'upgrade';     Description = 'Upgrade zvm' }
    \\        @{ Name = 'version';     Description = 'Show zvm version' }
    \\        @{ Name = 'help';        Description = 'Show help message' }
    \\    )
    \\
    \\    $shells = @('bash', 'zsh', 'fish', 'powershell')
    \\
    \\    $tokens = $commandAst.CommandElements | ForEach-Object { $_.ToString() }
    \\    $tokenCount = $tokens.Count
    \\    $hasTrailingSpace = $cursorPosition -gt $commandAst.Extent.EndOffset - 1
    \\    $effectiveCount = if ($hasTrailingSpace) { $tokenCount + 1 } else { $tokenCount }
    \\
    \\    if ($effectiveCount -le 2) {
    \\        return $commands |
    \\            Where-Object { $_.Name -like "$wordToComplete*" } |
    \\            ForEach-Object {
    \\                [System.Management.Automation.CompletionResult]::new(
    \\                    $_.Name, $_.Name, 'ParameterValue', $_.Description)
    \\            }
    \\    }
    \\
    \\    $subcommand = $tokens[1]
    \\    $previous = if ($tokenCount -ge 2) { $tokens[$tokenCount - 1] } else { '' }
    \\
    \\    switch ($subcommand) {
    \\        { $_ -in 'install', 'use', 'remove' } {
    \\            if ($wordToComplete -like '-*') {
    \\                return @([System.Management.Automation.CompletionResult]::new(
    \\                    '--zls', '--zls', 'ParameterName', 'Apply to ZLS instead of Zig'))
    \\            }
    \\        }
    \\        'list' {
    \\            return @([System.Management.Automation.CompletionResult]::new(
    \\                '--all', '--all', 'ParameterName', 'List Zig and ZLS versions together'))
    \\        }
    \\        'list-remote' {
    \\            return @([System.Management.Automation.CompletionResult]::new(
    \\                '--zls', '--zls', 'ParameterName', 'List ZLS versions instead of Zig'))
    \\        }
    \\        'clean' {
    \\            return @([System.Management.Automation.CompletionResult]::new(
    \\                '--all', '--all', 'ParameterName', 'Also remove unused versions'))
    \\        }
    \\        'env' {
    \\            if ($wordToComplete -like '--shell=*') {
    \\                $prefix = $wordToComplete.Substring('--shell='.Length)
    \\                return $shells |
    \\                    Where-Object { $_ -like "$prefix*" } |
    \\                    ForEach-Object {
    \\                        $completion = "--shell=$_"
    \\                        [System.Management.Automation.CompletionResult]::new(
    \\                            $completion, $completion, 'ParameterValue', "Shell: $_")
    \\                    }
    \\            }
    \\            return @([System.Management.Automation.CompletionResult]::new(
    \\                '--shell=', '--shell=', 'ParameterName', 'Specify shell'))
    \\        }
    \\        'completions' {
    \\            if ($effectiveCount -le 3) {
    \\                return $shells |
    \\                    Where-Object { $_ -like "$wordToComplete*" } |
    \\                    ForEach-Object {
    \\                        [System.Management.Automation.CompletionResult]::new(
    \\                            $_, $_, 'ParameterValue', "Shell: $_")
    \\                    }
    \\            }
    \\        }
    \\    }
    \\}
;

pub fn generate_completions(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CompletionsCommand,
    progress_node: std.Progress.Node,
) !void {
    _ = ctx;
    _ = progress_node;

    const shell_name = @tagName(command.shell);
    assert(shell_name.len > 0);
    const script: []const u8 = switch (command.shell) {
        .zsh => zsh_script,
        .bash => bash_script,
        .fish => fish_script,
        .powershell => powershell_script,
    };
    assert(script.len > 0);
    if (util_output.output_mode() == .machine_json) {
        const fields = [_]util_output.JsonField{
            .{ .key = "shell", .value = .{ .string = shell_name } },
            .{ .key = "script", .value = .{ .string = script } },
        };
        util_output.emit_json(.{ .object = &fields });
        return;
    }

    util_output.emit_json(.{ .text = script });
}

pub fn run(
    ctx: *context.CliContext,
    command: validation.ValidatedCommand.CompletionsCommand,
    progress_node: std.Progress.Node,
) !void {
    try generate_completions(ctx, command, progress_node);
}

pub fn progress_items(command: validation.ValidatedCommand.CompletionsCommand) u16 {
    _ = command;
    return 1;
}

test "completion scripts include every primary command from cli spec" {
    const scripts = [_][]const u8{
        zsh_script,
        bash_script,
        fish_script,
        powershell_script,
    };

    for (cli_spec.primary_command_names) |command_name| {
        for (scripts) |script| {
            try std.testing.expect(std.mem.indexOf(u8, script, command_name) != null);
        }
    }
}

test "completion scripts use attached shell option syntax" {
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "--shell=") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh_script, "--shell=") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish_script, "--shell=") != null);
    try std.testing.expect(std.mem.indexOf(u8, powershell_script, "--shell=") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_script, "prev == \"--shell\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, powershell_script, "previous -eq '--shell'") == null);
}
