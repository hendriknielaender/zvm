<h1 align="center">
   <img src="logo.png" width="40%" height="40%" alt="zvm logo" title="zvm logo">
  <br><br>
  ⚡ Zig Version Manager (<code>zvm</code>)
</h1>
<div align="center">⚡ Fast and simple zig version manager</div>
<br><br>
zvm is a command-line tool that allows you to easily install, manage, and switch between multiple versions of Zig.

## Features

- List available Zig/zls versions (both remote and local).
- Install specific Zig or zls versions.
- Switch between installed Zig or zls versions.
- Remove installed Zig or zls versions.
- Display the current zvm version and helpful usage information.
- XDG Base Directory Specification support on Linux/macOS.


## Install

To install zvm with Homebrew, aka. `brew`, run the following commands:

```bash
brew tap hendriknielaender/zvm
brew install zvm
```

Run `zvm env` to get the exact PATH configuration for your system:

```bash
$ zvm env
# Add this to your ~/.bashrc, ~/.profile, or ~/.zshrc:
export PATH="/home/user/.local/share/zvm/bin:$PATH"
```

**⚠️ BREAKING CHANGE (zvm 0.14.0)**: zvm now follows the XDG Base Directory Specification on Linux/macOS. Legacy `~/.zm` installations must be migrated manually.

### Windows

#### PowerShell

```ps1
irm https://raw.githubusercontent.com/hendriknielaender/zvm/master/install.ps1 | iex
```

#### Command Prompt

```cmd
powershell -c "irm https://raw.githubusercontent.com/hendriknielaender/zvm/master/install.ps1 | iex"
```

## Shell Completions

`zvm` provides built-in shell completion scripts for both Zsh and Bash. This enhances the command-line experience by allowing tab-completion of subcommands, flags, etc.

### Zsh

 **Generate** the Zsh completion script:
   ```bash
   zvm completions zsh > _zvm
   ```
 **Move** `_zvm` into a directory that Zsh checks for autoloaded completion scripts. For example:
   ```bash
   mkdir -p ~/.zsh/completions
   mv _zvm ~/.zsh/completions
   ```
 **Add** this to your `~/.zshrc`:
   ```bash
   fpath+=(~/.zsh/completions)
   autoload -U compinit && compinit
   ```
 **Reload** your shell:
   ```bash
   source ~/.zshrc
   ```

### Bash

**Generate** the Bash completion script:
   ```bash
   zvm completions bash > zvm.bash
   ```
**Source** it in your `~/.bashrc` (or `~/.bash_profile`):
   ```bash
   echo "source $(pwd)/zvm.bash" >> ~/.bashrc
   source ~/.bashrc
   ```

## Usage

**General Syntax:**
```bash
zvm <command> [arguments]
```

**Available Commands:**
- `zvm ls` or `zvm list`  
  Lists all available versions of Zig or zls remotely by default.  
  Use `--system` to list only locally installed versions.
  ```bash
  zvm ls
  zvm ls --system
  zvm ls zls --system
  ```

- `zvm i` or `zvm install`  
  Installs the specified version of Zig or zls. Zig is the default if no tool is specified.
  ```bash
  zvm install <version>         # Installs Zig for the specified version (default)
  zvm install <version> --debug # Installs with debug output
  zvm install --mirror=0        # Installs Zig with a specified mirror url
  zvm install zig <version>     # Installs only Zig for the specified version (explicit)
  zvm install zls <version>     # Installs only zls for the specified version
  ```

- `zvm use`  
  Switches to using the specified installed version of Zig or zls. Zig is the default if no tool is specified.
  ```bash
  zvm use <version>         # Use this version of Zig (default)
  zvm use zig <version>     # Use this version of Zig (explicit)
  zvm use zls <version>     # Use this version of zls only
  ```

- `zvm remove`  
  Removes the specified installed version of Zig or ZLS. Zig is the default if no tool is specified.
  ```bash
  zvm remove <version>      # Removes this version of Zig (default)
  zvm remove zig <version>  # Removes only the specified Zig version (explicit)
  zvm remove zls <version>  # Removes only the specified zls version
  ```
- `zvm clean`
  Remove old download artifacts.

- `zvm --version`  
  Displays the current version of zvm.

- `zvm --help`  
  Displays detailed usage information.

**Examples:**
```bash
# List all available remote Zig versions
zvm ls

# List all installed local Zig versions
zvm ls --system

# List all installed local zls versions
zvm ls zls --system

# List of available Zig mirrors
zvm ls --mirror

# Install Zig version 0.14.1 (zig is default)
zvm install 0.14.1

# Install Zig version 0.14.1 with debug output
zvm install 0.14.1 --debug

# Install zls version 0.14.0
zvm install zls 0.14.0

# Use Zig version 0.14.1 (zig is default)
zvm use 0.14.1

# Remove Zig version 0.14.1 (zig is default)
zvm remove 0.14.1

# Remove old download artifacts.
zvm clean
```

### Compatibility Notes
Zig is in active development and the APIs can change frequently, making it challenging to support every dev build. This project currently aims to be compatible with stable, non-development builds to provide a consistent experience for the users.

***Supported Version***: As of now, zvm is tested and supported on Zig version ***0.15.1***.

### Contributing
Contributions, issues, and feature requests are welcome!

### Clarification
Please note that our project is **not** affiliated with [ZVM](https://github.com/tristanisham/zvm) maintained by @tristanisham. Both projects operate independently, and any similarities are coincidental.
