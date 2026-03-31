#!/bin/bash

# Example deployment hooks for docker-control
# This file should be placed in:
# - htdocs/.docker-control/deployment-scripts/<env_name>.sh
# OR
# - deployments/scripts/<env_name>.sh
#
# Replace 'prod' with your actual environment name (e.g., staging, production)

# Each hook receives 3 parameters:
# $1: Release Directory Name (e.g., 20240326153000_v1.0.0)
# $2: Console Command for the new release
# $3: Server Root Directory

# --- PRE-DEPLOY HOOK ---
# Executed before cache clearing and migrations
pre_deploy_hook_prod() {
    local release_dir=$1
    local console_new=$2
    local server_root=$3

    echo "Executing pre-deploy hook for prod..."
    echo "Release: $release_dir"

    # Example: Run a custom command on the server using the new exec_ssh function
    # exec_ssh <command>
    exec_ssh "$console_new" --help
}

# --- POST-DEPLOY HOOK ---
# Executed after migrations and COPS integration, but before switching symlink
post_deploy_hook_prod() {
    local release_dir=$1
    local console_new=$2
    local server_root=$3

    echo "Executing post-deploy hook for prod..."

    # Example: Clear some custom cache on the remote server
    exec_ssh "rm -rf $release_dir/data/cache/*"
}

# --- DONE-DEPLOY HOOK ---
# Executed after symlink update and final bytecode cache clear
done_deploy_hook_prod() {
    local release_dir=$1
    local console_new=$2
    local server_root=$3

    echo "Deployment to prod completed!"

    # Example: Send a custom notification or trigger a webhook
    # curl -X POST https://api.example.com/deploy-webhook
}
