#!/bin/bash
set -e

IMAGE="ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest"

# Pull only if newer
docker pull "$IMAGE" --quiet || true

docker run --rm \
  -v "$HOME/.docker/cli-plugins":"/cli-plugins" \
  -u "$(id -u):$(id -g)" \
  "$IMAGE" install-plugin </dev/null
