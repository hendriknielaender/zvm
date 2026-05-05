#!/usr/bin/env bash
set -euo pipefail

platform=$(uname -ms)

if [[ ${OS:-} = Windows_NT ]]; then
  if [[ $platform != MINGW64* ]]; then
    echo "zvm's install script does not support Windows. Please use PowerShell instead:"
    echo "  irm https://raw.githubusercontent.com/hendriknielaender/zvm/main/install.ps1 | iex"
    echo ""
    echo "Or download a copy of zvm here: https://github.com/hendriknielaender/zvm/releases/latest"
    exit 1
  fi
fi

# Reset
Color_Off=''

# Regular Colors
Red=''
Green=''
Dim='' # White

# Bold
Bold_White=''
Bold_Green=''

if [[ -t 1 ]]; then
    # Reset
    Color_Off='\033[0m' # Text Reset

    # Regular Colors
    Red='\033[0;31m'   # Red
    Green='\033[0;32m' # Green
    Dim='\033[0;2m'    # White

    # Bold
    Bold_Green='\033[1;32m' # Bold Green
    Bold_White='\033[1m'    # Bold White
fi

error() {
    echo -e "${Red}error${Color_Off}:" "$@" >&2
    exit 1
}

info() {
    echo -e "${Dim}$@ ${Color_Off}"
}

info_bold() {
    echo -e "${Bold_White}$@ ${Color_Off}"
}

success() {
    echo -e "${Green}$@ ${Color_Off}"
}

case $platform in
'Darwin x86_64')
    target=x86_64-macos
    ;;
'Darwin arm64')
    target=aarch64-macos
    ;;
'Linux aarch64' | 'Linux arm64')
    target=aarch64-linux
    ;;
'MINGW64'*)
    target=x86_64-windows
    ;;
'Linux x86_64' | *)
    target=x86_64-linux
    ;;
esac

if [[ $target = x86_64-macos ]]; then
    # Is this process running in Rosetta?
    # redirect stderr to devnull to avoid error message when not running in Rosetta
    if [[ $(sysctl -n sysctl.proc_translated 2>/dev/null) = 1 ]]; then
        target=aarch64-macos
        info "Your shell is running in Rosetta 2. Downloading zvm for $target instead"
    fi
fi

GITHUB=${GITHUB-"https://github.com"}
github_repo="$GITHUB/hendriknielaender/zvm"

# Resolve version. No argument selects the latest release; otherwise we install
# the requested tag (e.g. v0.15.0 or zvm-v0.15.0) for rollback or pinning.
if [[ $# = 0 ]]; then
    version="latest"
    release_path="releases/latest/download"
else
    # Strip 'zvm-' prefix if provided so both 'v0.15.0' and 'zvm-v0.15.0' work.
    version="${1#zvm-}"
    release_path="releases/download/$version"
    info "Installing zvm $version (rollback/specific version)"
fi

if [[ $target == *"windows"* ]]; then
    archive_ext="zip"
else
    archive_ext="tar.gz"
fi
zvm_uri="$github_repo/$release_path/$target-zvm.$archive_ext"

# macos/linux cross-compat mktemp
# https://unix.stackexchange.com/questions/30091/fix-or-alternative-for-mktemp-in-os-x
tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'zvm')
install_dir=${HOME}/.local/bin

if [[ $target == *"windows"* ]]; then
    curl --fail --location --progress-bar --output "$tmpdir/zvm.zip" "$zvm_uri" ||
        error "Failed to download zvm from \"$zvm_uri\""
    unzip -q "$tmpdir/zvm.zip" -d "$tmpdir"
    mv "$tmpdir"/*zvm.exe "$tmpdir/zvm"
else
    curl --fail --location --progress-bar --output "$tmpdir/zvm.tar.gz" "$zvm_uri" ||
        error "Failed to download zvm from \"$zvm_uri\""
    tar -xzf "$tmpdir/zvm.tar.gz" -C "$tmpdir"
    mv "$tmpdir"/*zvm "$tmpdir/zvm"
fi
chmod +x "$tmpdir/zvm"

# Create install directory if it doesn't exist
mkdir -p "$install_dir"

# Build a single label so install/success messages share one source of truth.
if [[ $version = "latest" ]]; then
    version_label="zvm"
else
    version_label="zvm $version"
fi

if [[ ! -w $install_dir ]]; then
    info "Installing $version_label to $install_dir. You will be prompted for your password."
    sudo mv "$tmpdir/zvm" "$install_dir/zvm"
else
    mv "$tmpdir/zvm" "$install_dir/zvm"
fi
success "$version_label installed to $install_dir/zvm"

# Check if install directory is in PATH
if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    echo ""
    info "To use zvm, add $install_dir to your PATH:"
    echo "  export PATH=\"$install_dir:\$PATH\""
    echo ""
    echo "For bash: Add to ~/.bashrc or ~/.bash_profile"
    echo "For zsh: Add to ~/.zshrc"
    echo "For fish: Add to ~/.config/fish/config.fish"
    echo ""
    echo "Then reload your shell or run: source ~/.bashrc"
fi
