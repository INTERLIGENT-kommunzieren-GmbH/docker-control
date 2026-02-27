#!/bin/bash
set -e

# Binary name from Cargo.toml
BINARY_NAME="docker-control"
DIST_DIR="dist"

mkdir -p "$DIST_DIR"

# Detect host target
HOST_TARGET=$(rustc -vV | grep host | cut -d ' ' -f2)

echo "Building Docker Control Plugin for host: $HOST_TARGET..."

cargo build --release
cp "target/release/$BINARY_NAME" "$DIST_DIR/${BINARY_NAME}-${HOST_TARGET}"

echo "Copying asset folders to $DIST_DIR..."
cp -r template "$DIST_DIR/"
cp -r ingress "$DIST_DIR/"

echo "✓ Built $DIST_DIR/${BINARY_NAME}-${HOST_TARGET}"
echo ""
echo "Note: For multi-platform builds, please use GitHub Actions or ensure you have"
echo "      cross-compilation toolchains and libraries (like OpenSSL) installed for each target."
echo ""
echo "--- Build Summary ---"
ls -lh "$DIST_DIR"
