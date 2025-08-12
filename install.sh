#!/bin/bash
set -e

docker run --rm -v "$HOME/.docker/cli-plugins":"/cli-plugins" -it -u $(id -u):$(id -g) ik/docker-plugin install-plugin
