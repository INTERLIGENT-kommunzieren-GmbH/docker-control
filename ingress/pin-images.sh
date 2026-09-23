#!/usr/bin/env bash
# Pins ingress images to immutable digests to prevent supply-chain attacks.
# This script fetches current digests and updates ingress/compose.yml automatically.
#
# SECURITY: The Docker socket mount in these containers grants daemon API access.
# Only run this script after verifying the source images are from trusted publishers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

echo "Fetching and pinning image digests for ingress containers..."
echo ""

# Pull and get digest for nginx proxy
echo "==> Pulling nginxproxy/nginx-proxy:1.6..."
docker pull nginxproxy/nginx-proxy:1.6 >/dev/null 2>&1
NGINX_DIGEST=$(docker inspect nginxproxy/nginx-proxy:1.6 --format='{{index .RepoDigests 0}}' | cut -d'@' -f2)
echo "    Digest: $NGINX_DIGEST"

# Pull and get digest for proxy companion
echo "==> Pulling sebastienheyd/self-signed-proxy-companion:latest..."
docker pull sebastienheyd/self-signed-proxy-companion:latest >/dev/null 2>&1
COMPANION_DIGEST=$(docker inspect sebastienheyd/self-signed-proxy-companion:latest --format='{{index .RepoDigests 0}}' | cut -d'@' -f2)
echo "    Digest: $COMPANION_DIGEST"
echo ""

# Update compose.yml with digests
echo "Updating $COMPOSE_FILE with pinned digests..."

# Backup original
cp "$COMPOSE_FILE" "$COMPOSE_FILE.backup"

# Replace nginx image line (handles both with and without existing digest)
sed -i.tmp "s|image: nginxproxy/nginx-proxy:1.6\(@sha256:[a-f0-9]\{64\}\)\?|image: nginxproxy/nginx-proxy:1.6@$NGINX_DIGEST|" "$COMPOSE_FILE"

# Replace companion image line (handles both with and without :latest and existing digest)
sed -i.tmp "s|image: sebastienheyd/self-signed-proxy-companion\(:latest\)\?\(@sha256:[a-f0-9]\{64\}\)\?|image: sebastienheyd/self-signed-proxy-companion:latest@$COMPANION_DIGEST|" "$COMPOSE_FILE"

# Clean up temp file
rm -f "$COMPOSE_FILE.tmp"

echo "✓ Images pinned to immutable digests"
echo ""
echo "Backup saved to: $COMPOSE_FILE.backup"
echo ""
echo "IMPORTANT: Review the changes and verify the digests before committing:"
echo "  git diff $COMPOSE_FILE"

