#!/bin/bash

# Example deployment hooks for docker-control
# This file should be placed in:
# - htdocs/.docker-control/deployment-scripts/<env_name>.sh
# OR
# - deployments/scripts/<env_name>.sh
#
# Replace 'prod' with your actual environment name (e.g., staging, production)

# Each hook receives 5 parameters:
# $1: SSH User
# $2: SSH Domain
# $3: Server Root Directory
# $4: Release Directory Name (e.g., 20240326153000_v1.0.0)
# $5: Console Command for the new release

# --- PRE-DEPLOY HOOK ---
# Executed before cache clearing and migrations
pre_deploy_hook_prod() {
    local user=$1
    local domain=$2
    local server_root=$3
    local release_dir=$4
    local console_new=$5

    echo "Executing pre-deploy hook for prod..."
    echo "Release: $release_dir"

    # Example: Run a custom command on the server using the new exec_ssh function
    # exec_ssh <user> <domain> <command>
    exec_ssh "$user" "$domain" "ls -la $server_root/releases/$release_dir"
}

# --- POST-DEPLOY HOOK ---
# Executed after migrations and COPS integration, but before switching symlink
post_deploy_hook_prod() {
    local user=$1
    local domain=$2
    local server_root=$3
    local release_dir=$4
    local console_new=$5

    echo "Executing post-deploy hook for prod..."

    # Example: Clear some custom cache on the remote server
    exec_ssh "$user" "$domain" "rm -rf $server_root/releases/$release_dir/var/cache/custom/*"
}

# --- DONE-DEPLOY HOOK ---
# Executed after symlink update and final bytecode cache clear
done_deploy_hook_prod() {
    local user=$1
    local domain=$2
    local server_root=$3
    local release_dir=$4
    local console_new=$5

    echo "Deployment to prod completed!"

    # Example: Send a custom notification or trigger a webhook
    # curl -X POST https://api.example.com/deploy-webhook
}
