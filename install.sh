#!/bin/bash
set -e

REPO="INTERLIGENT-kommunzieren-GmbH/docker-plugin"
BINARY_NAME="docker-control"
CLI_PLUGIN_PATH="$HOME/.docker/cli-plugins"

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     OS_NAME="unknown-linux-musl";;
    Darwin*)    OS_NAME="apple-darwin";;
    *)          echo "Unsupported OS: ${OS}"; exit 1;;
esac

# Detect Architecture
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64*)    ARCH_NAME="x86_64";;
    arm64*|aarch64*) ARCH_NAME="aarch64";;
    *)          echo "Unsupported Architecture: ${ARCH}"; exit 1;;
esac

TARGET="${ARCH_NAME}-${OS_NAME}"
URL="https://github.com/${REPO}/releases/latest/download/${BINARY_NAME}-${TARGET}"

echo "Installing Docker Control Plugin for ${TARGET}..."

if [[ ! -d "$CLI_PLUGIN_PATH" ]]; then
    mkdir -p "$CLI_PLUGIN_PATH"
fi

echo "Downloading from ${URL}..."
if ! curl -L -o "$CLI_PLUGIN_PATH/$BINARY_NAME" "$URL"; then
    echo "Failed to download binary. Please check if the release exists on GitHub."
    exit 1
fi

chmod +x "$CLI_PLUGIN_PATH/$BINARY_NAME"

echo "Installation successful. You can now use: docker control help"
