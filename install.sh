#!/bin/bash
set -e

REPO="INTERLIGENT-kommunzieren-GmbH/docker-control"
BINARY_NAME="docker-control"
CLI_PLUGIN_PATH="$HOME/.docker/cli-plugins"

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     OS_NAME="unknown-linux-musl"; PROJECT_DIR="$HOME/.config/docker-control";;
    Darwin*)    OS_NAME="apple-darwin"; PROJECT_DIR="$HOME/Library/Application Support/com.interligent.docker-control";;
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
TEMPLATE_URL="https://github.com/${REPO}/releases/latest/download/template.tar.gz"
INGRESS_URL="https://github.com/${REPO}/releases/latest/download/ingress.tar.gz"

echo "Installing Docker Control Plugin for ${TARGET}..."

if [[ ! -d "$CLI_PLUGIN_PATH" ]]; then
    mkdir -p "$CLI_PLUGIN_PATH"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    mkdir -p "$PROJECT_DIR"
fi

echo "Downloading binary from ${URL}..."
if ! curl -L -o "$CLI_PLUGIN_PATH/$BINARY_NAME" "$URL"; then
    echo "Failed to download binary. Please check if the release exists on GitHub."
    exit 1
fi

chmod +x "$CLI_PLUGIN_PATH/$BINARY_NAME"

echo "Downloading and extracting assets to ${PROJECT_DIR}..."
if ! curl -L --fail "$TEMPLATE_URL" | tar -xz -C "$PROJECT_DIR"; then
    echo "Failed to download or extract template assets."
    exit 1
fi

if ! curl -L --fail "$INGRESS_URL" | tar -xz -C "$PROJECT_DIR"; then
    echo "Failed to download or extract ingress assets."
    exit 1
fi

echo "Installation successful. You can now use: docker control help"
