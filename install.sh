#!/bin/bash
set -e

docker run --rm -e HOME=/home/$USER -v "$HOME":/home/$USER -it -u $(id -u):$(id -g) ik/docker-plugin install-plugin
