#!/bin/bash

set -e

RELEASE="latest"
OS="$(uname -s)"

default_install_dir() {
  if [ -d "$HOME/.zvm" ]; then
    echo "$HOME/.zvm"
  elif [ -n "$XDG_DATA_HOME" ]; then
    echo "$XDG_DATA_HOME/zvm"
  elif [ "$OS" = "Darwin" ]; then
    echo "$HOME/Library/Application Support/zvm"
  else
    echo "$HOME/.local/share/zvm"
  fi
}

INSTALL_DIR=$(default_install_dir)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--install-dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      -s|--skip-shell)
        SKIP_SHELL="true"
        shift
        ;;
      --force-install|--force-no-brew)
        FORCE_INSTALL="true"
        shift
        ;;
      -r|--release)
        RELEASE="$2"
        shift 2
        ;;
      *)
        echo "Unrecognized argument $1"
        exit 1
    esac
  done
}

set_filename() {
  case "$OS" in
    Linux)
      case "$(uname -m)" in
        arm|armv7*)
          FILENAME="zvm-arm32"
          ;;
        aarch*|armv8*)
          FILENAME="zvm-arm64"
          ;;
        *)
          FILENAME="zvm-linux"
      esac
      ;;
    Darwin)
      if [ "$FORCE_INSTALL" = "true" ]; then
        FILENAME="zvm-macos"
        USE_HOMEBREW="false"
      else
        USE_HOMEBREW="true"
      fi
      ;;
    *)
      echo "OS $OS is not supported."
      exit 1
  esac
}

download_zvm() {
  if [ "$USE_HOMEBREW" = "true" ]; then
    brew install zvm
  else
    URL="https://github.com/your-zvm-repo/zvm/releases/${RELEASE}/download/${FILENAME}.zip"

    DOWNLOAD_DIR=$(mktemp -d)
    echo "Downloading $URL..."
    curl --progress-bar --fail -L "$URL" -o "${DOWNLOAD_DIR}/${FILENAME}.zip"
    unzip -q "${DOWNLOAD_DIR}/${FILENAME}.zip" -d "$DOWNLOAD_DIR"
    mv "${DOWNLOAD_DIR}/zvm" "$INSTALL_DIR/zvm"
    chmod u+x "$INSTALL_DIR/zvm"
  fi
}

check_dependencies() {
  DEPENDENCIES=("curl" "unzip")
  [ "$USE_HOMEBREW" = "true" ] && DEPENDENCIES+=("brew")

  for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v $dep &> /dev/null; then
      echo "$dep is required but not installed. Aborting."
      exit 1
    fi
  done
}

setup_shell() {
  case "$(basename "$SHELL")" in
    zsh)
      CONF_FILE="${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      CONF_FILE="$HOME/.config/fish/conf.d/zvm.fish"
      ;;
    bash)
      CONF_FILE="$([ "$OS" = "Darwin" ] && echo "$HOME/.profile" || echo "$HOME/.bashrc")"
      ;;
    *)
      echo "Could not infer shell type. Please set up manually."
      exit 1
  esac

  echo -e "\n# zvm" >> "$CONF_FILE"
  echo 'export PATH="'"$INSTALL_DIR"':$PATH"' >> "$CONF_FILE"
  echo 'eval "`zvm env`"' >> "$CONF_FILE"
  echo "Added zvm setup to $CONF_FILE"
}

parse_args "$@"
set_filename
check_dependencies
download_zvm

if [ "$SKIP_SHELL" != "true" ]; then
  setup_shell
fi

