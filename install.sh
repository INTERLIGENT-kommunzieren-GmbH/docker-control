#!/bin/bash
set -e

IMAGE="ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest"
CLI_PLUGIN_PATH="$HOME/.docker/cli-plugins"

# Pull only if newer
docker pull "$IMAGE" --quiet > /dev/null 2>&1

if [[ ! -d "$CLI_PLUGIN_PATH" ]]; then
    mkdir -p "$CLI_PLUGIN_PATH"
fi

docker run --rm \
  -v "$CLI_PLUGIN_PATH":/cli-plugins \
  -u "$(id -u):$(id -g)" \
  "$IMAGE" install-plugin </dev/null
