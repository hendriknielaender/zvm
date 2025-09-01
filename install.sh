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

if [[ $# = 0 ]]; then
    if [[ $target == *"windows"* ]]; then
        zvm_uri=$github_repo/releases/latest/download/$target-zvm.zip
    else
        zvm_uri=$github_repo/releases/latest/download/$target-zvm.tar.gz
    fi
else
    if [[ $target == *"windows"* ]]; then
        zvm_uri=$github_repo/releases/download/$1/$target-zvm.zip
    else
        zvm_uri=$github_repo/releases/download/$1/$target-zvm.tar.gz
    fi
fi

# macos/linux cross-compat mktemp
# https://unix.stackexchange.com/questions/30091/fix-or-alternative-for-mktemp-in-os-x
tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'zvm')
install_dir=/usr/local/bin

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

# Check if user can write to install directory
if [[ ! -w $install_dir ]]; then
    info "Saving zvm to $install_dir. You will be prompted for your password."
    sudo mv "$tmpdir/zvm" "$install_dir/zvm"
    success "zvm installed to $install_dir/zvm" 
else 
    mv "$tmpdir/zvm" "$install_dir/zvm"
    success "zvm installed to $install_dir/zvm"
fi