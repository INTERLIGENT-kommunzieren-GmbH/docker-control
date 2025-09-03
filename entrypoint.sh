#!/bin/bash
set -e

# Check if this is a metadata request - if so, skip user setup
if [[ "$1" == "docker-cli-plugin-metadata" ]]; then
    exec /app/plugin/docker-control "$@"
fi

# Set up environment without modifying system files
if [[ -n "$UID" && -n "$GID" && -n "$USER" ]]; then
    # Set up home directory in a writable location
    export HOME="/tmp/home-$USER"
    mkdir -p "$HOME" 2>/dev/null || true

    # Set up environment variables that help with user identification
    export USER="$USER"
    export LOGNAME="$USER"

    # Copy Git config if available
    if [[ -f "/.gitconfig" ]]; then
        cp "/.gitconfig" "$HOME/.gitconfig" 2>/dev/null || true
    fi

    # Set up basic Git config if none exists
    if [[ ! -f "$HOME/.gitconfig" ]]; then
        git config --global user.name "$USER" 2>/dev/null || true
        git config --global user.email "$USER@container.local" 2>/dev/null || true
    fi

    # Set up SSH config to auto-accept host keys and reduce verbosity
    mkdir -p "$HOME/.ssh" 2>/dev/null || true
    cat > "$HOME/.ssh/config" 2>/dev/null << EOF || true
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
    ConnectTimeout 10
EOF
    chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
fi

# Run the main application (already running as correct user from Docker)
exec /app/plugin/docker-control "$@"
