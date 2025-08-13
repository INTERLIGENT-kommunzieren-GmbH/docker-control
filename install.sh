#!/bin/bash
set -e

IMAGE="ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest"

# Pull only if newer
docker pull "$IMAGE" --quiet > /dev/null 2>&1

docker run --rm \
  -v "$HOME/.docker/cli-plugins":"/cli-plugins" \
  -u "$(id -u):$(id -g)" \
  "$IMAGE" install-plugin </dev/null
