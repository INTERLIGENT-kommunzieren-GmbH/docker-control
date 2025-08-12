#!/bin/bash
set -e

docker run --rm -v "$HOME/.docker/cli-plugins":"/cli-plugins" -u $(id -u):$(id -g) ghcr.io/interligent-kommunzieren-gmbh/docker-plugin:latest install-plugin
